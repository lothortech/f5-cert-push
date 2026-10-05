#!/usr/bin/env bash
#
# f5-cert-install - install manually uploaded certificates, then push them to the
# BIG-IPs with f5-cert-push.sh. Designed to run from cron.
#
# HOW IT WORKS
#   1. An operator uploads a certificate's files into   <incoming>/<certname>/
#        cert.pem      the leaf certificate          } one of these
#        fullchain.pem leaf followed by intermediates } (or both)
#        chain.pem     the intermediates             (needed unless fullchain.pem has them)
#        privkey.pem   the private key (unencrypted PEM)
#      and then, LAST, creates an empty file named READY.
#      A folder without READY is ignored, so a half-finished upload is never used.
#   2. Each run, for every <certname> folder that has READY:
#        - the files are copied into a private scratch directory (symlinks and
#          non-regular files are refused), and validated with f5-cert-push's own
#          checks: key matches certificate, chain present and verifies, not expired,
#          not expiring within --min-days, not older than the certificate already
#          installed (unless --allow-older);
#        - they are installed as a new release under <store>/<certname>/releases/<UTC time>/
#          and <store>/<certname>/current is switched to it atomically;
#        - the upload folder is emptied (the key is shredded).
#      A folder that fails validation gets a FAILED file explaining why, and its
#      READY file is removed, so it is not retried until someone fixes it and
#      creates READY again.
#   3. If anything was installed (or an earlier push did not succeed), it runs
#        f5-cert-push.sh --config <config> --all     (or --env LABEL ...)
#      and keeps retrying on later runs until that push succeeds.
#
# In f5-cert-push.conf, point each certificate at its "current" directory:
#     [cert:www]
#     le_dir = /etc/f5-certs/www/current
#
# Usage:
#   f5-cert-install.sh [options]
#
# Options:
#   --config FILE       f5-cert-push configuration   (default /etc/f5-cert-push.conf)
#   --incoming DIR      upload folders               (default /srv/f5-certs/incoming)
#   --store DIR         installed certificates       (default /etc/f5-certs)
#   --push-bin FILE     f5-cert-push.sh              (default: next to this script)
#   --env LABEL         push only deployments with this env (repeatable; default --all)
#   --push-when WHEN    changed (default): push only after an install, or to retry
#                       a push that has not succeeded yet; always: push every run
#   --no-push           install only, never push
#   --keep-releases N   installed releases to keep per certificate   (default 3)
#   --min-days N        refuse a certificate expiring within N days  (default 7)
#   --allow-older       accept a certificate that expires before the installed one
#   --allow-no-chain    accept a certificate with no intermediates
#   --dry-run           validate uploads and report; change nothing, push nothing
#   --status            show installed certificates and pending uploads, then exit
#   --quiet             print only what changed, warnings and errors
#   --version, -h|--help
#
# Exit codes: 0 ok; 1 an upload was rejected or a step failed; 2 usage error;
#             6 another run is in progress; 3, 4, 5 passed through from f5-cert-push.
#
set -uo pipefail
set -f
export LC_ALL=C
umask 077

readonly VERSION="2.0.0"
readonly PROG="f5-cert-install"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
  echo "$PROG: bash 4.2 or newer is required" >&2; exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="/etc/f5-cert-push.conf"
INCOMING="/srv/f5-certs/incoming"
STORE="/etc/f5-certs"
PUSH_BIN="${SCRIPT_DIR}/f5-cert-push.sh"
PUSH_WHEN="changed"
DO_PUSH=1
KEEP_RELEASES=3
MIN_DAYS=7
ALLOW_OLDER=0
ALLOW_NO_CHAIN=0
DRY_RUN=0
STATUS=0
QUIET=0
declare -a ENVS=()

WORK=""
declare -a INSTALLED=() REJECTED=()

sanitize() { LC_ALL=C tr -cd '\11\12\40-\176'; }
_out() { printf '%s %s\n' "$1" "$2" | sanitize; }
info() { if (( ! QUIET )); then _out "[*]" "$*"; fi; }
ok()   { _out "[+]" "$*"; }
warn() { _out "[!]" "$*" >&2; }
err()  { _out "[-]" "$*" >&2; }
usage() { awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 && !/^#/ { exit }' "$0"; }
usage_die() { err "$*"; echo "Try: ${PROG} --help" >&2; exit 2; }

cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    find "$WORK" -type f -exec shred -u -- {} + 2>/dev/null || true
    rm -rf -- "$WORK"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'err "interrupted"; exit 130' INT TERM HUP

rx_path='^/[A-Za-z0-9._/+@=,:~-]*$'
is_path() { [[ "$1" =~ $rx_path && "$1" != *"/../"* && "$1" != */.. && "$1" != *"//"* && "$1" != / ]]; }
is_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }
is_uint() { [[ "$1" =~ ^[0-9]{1,5}$ ]]; }

need() { if (( $1 < 2 )) || [[ "$2" == --* ]]; then usage_die "option $3 needs a value"; fi; }

parse_args() {
  local a; local -a args=()
  for a in "$@"; do if [[ "$a" == --*=* ]]; then args+=("${a%%=*}" "${a#*=}"); else args+=("$a"); fi; done
  set -- ${args[@]+"${args[@]}"}
  while (( $# > 0 )); do
    case "$1" in
      --config)         need $# "${2:-}" "$1"; CONFIG="$2"; shift 2 ;;
      --incoming)       need $# "${2:-}" "$1"; INCOMING="$2"; shift 2 ;;
      --store)          need $# "${2:-}" "$1"; STORE="$2"; shift 2 ;;
      --push-bin)       need $# "${2:-}" "$1"; PUSH_BIN="$2"; shift 2 ;;
      --env)            need $# "${2:-}" "$1"; ENVS+=("$2"); shift 2 ;;
      --push-when)      need $# "${2:-}" "$1"; PUSH_WHEN="$2"; shift 2 ;;
      --no-push)        DO_PUSH=0; shift ;;
      --keep-releases)  need $# "${2:-}" "$1"; KEEP_RELEASES="$2"; shift 2 ;;
      --min-days)       need $# "${2:-}" "$1"; MIN_DAYS="$2"; shift 2 ;;
      --allow-older)    ALLOW_OLDER=1; shift ;;
      --allow-no-chain) ALLOW_NO_CHAIN=1; shift ;;
      --dry-run)        DRY_RUN=1; shift ;;
      --status)         STATUS=1; shift ;;
      --quiet)          QUIET=1; shift ;;
      --version)        echo "${PROG} ${VERSION}"; exit 0 ;;
      -h|--help)        usage; exit 0 ;;
      *)                usage_die "unknown option: $1" ;;
    esac
  done
  local p e
  for p in "$CONFIG" "$INCOMING" "$STORE" "$PUSH_BIN"; do
    is_path "$p" || usage_die "not an acceptable absolute path: ${p}"
  done
  for e in ${ENVS[@]+"${ENVS[@]}"}; do
    [[ "$e" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || usage_die "invalid --env label: ${e}"
  done
  [[ "$PUSH_WHEN" == changed || "$PUSH_WHEN" == always ]] || usage_die "--push-when must be changed or always"
  is_uint "$KEEP_RELEASES" && (( 10#$KEEP_RELEASES >= 1 )) || usage_die "--keep-releases must be 1 or more"
  is_uint "$MIN_DAYS" || usage_die "--min-days must be a whole number"
  KEEP_RELEASES=$((10#$KEEP_RELEASES)); MIN_DAYS=$((10#$MIN_DAYS))
}

#######################################################################
# Helpers
#######################################################################
leaf_of() {   # print the leaf certificate PEM of a release/staging directory
  if [[ -s "$1/cert.pem" ]]; then
    awk '/-----BEGIN CERTIFICATE-----/{i++} i==1{print} /-----END CERTIFICATE-----/{if(i==1) exit}' "$1/cert.pem"
  else
    awk '/-----BEGIN CERTIFICATE-----/{i++} i==1{print} /-----END CERTIFICATE-----/{if(i==1) exit}' "$1/fullchain.pem"
  fi
}
fp_of_dir()  { leaf_of "$1" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':'; }
end_of_dir() { leaf_of "$1" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2-; }
count_certs() { local n; n="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$1" 2>/dev/null)" || n=0; printf '%s' "$n"; }

# Mark an upload as rejected: write FAILED, remove READY so it is not retried.
reject() {   # reject NAME REASON
  local name="$1" reason="$2" dir="${INCOMING}/$1"
  err "upload '${name}' rejected: ${reason}"
  REJECTED+=("$name")
  if (( DRY_RUN )); then return 0; fi
  { printf 'Rejected by %s at %s UTC\n\n' "$PROG" "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf '%s\n\n' "$reason"
    printf 'Fix the files in this folder, then create READY again (touch READY).\n'
  } > "${dir}/FAILED" 2>/dev/null || warn "could not write ${dir}/FAILED"
  rm -f -- "${dir}/READY"
}

#######################################################################
# One upload
#######################################################################
process_upload() {   # process_upload NAME
  local name="$1" src="${INCOMING}/$1" stg f sz have_cert=0 have_full=0 have_chain=0 nfull out rc
  local cur="${STORE}/$1/current" new_fp cur_fp new_end cur_end new_e cur_e ts rel

  stg="${WORK}/${name}"
  mkdir -m 700 -- "$stg" || { reject "$name" "internal error: cannot create a scratch directory"; return 1; }

  # Copy into the private scratch directory, THEN inspect the copies: nothing the
  # uploader does after this point can change what is validated and installed.
  # The copy is made with dd so that it can never be steered by the uploader:
  #   iflag=nofollow  refuses a symbolic link at open() time (no check-then-use race)
  #   iflag=nonblock  a FIFO cannot make the run hang waiting for a writer
  #   count=1 of 1 MiB + 1 byte, so a huge file is never copied in full
  #   timeout         a last resort against anything else that blocks
  for f in cert.pem fullchain.pem chain.pem privkey.pem; do
    if [[ -e "${src}/${f}" || -L "${src}/${f}" ]]; then
      if [[ -L "${src}/${f}" ]]; then reject "$name" "${f} is a symbolic link (symbolic links are refused; upload the file itself)"; return 1; fi
      if [[ ! -f "${src}/${f}" ]]; then reject "$name" "${f} is not a regular file"; return 1; fi
      if ! timeout 20 dd if="${src}/${f}" of="${stg}/${f}" iflag=nofollow,nonblock bs=1048577 count=1 status=none 2>/dev/null; then
        reject "$name" "cannot read ${f} (it must be a regular file, not a link)"; return 1
      fi
      sz="$(wc -c < "${stg}/${f}")"; sz="${sz//[[:space:]]/}"
      if (( sz == 0 || sz > 1048576 )); then reject "$name" "${f} is empty or larger than 1 MiB"; return 1; fi
    fi
  done
  [[ -f "${stg}/cert.pem" ]] && have_cert=1
  [[ -f "${stg}/fullchain.pem" ]] && have_full=1
  [[ -f "${stg}/chain.pem" ]] && have_chain=1

  if [[ ! -f "${stg}/privkey.pem" ]]; then reject "$name" "privkey.pem is missing"; return 1; fi
  if (( ! have_cert && ! have_full )); then reject "$name" "neither cert.pem nor fullchain.pem was uploaded"; return 1; fi
  if (( ! ALLOW_NO_CHAIN )); then
    nfull=0
    if (( have_full )); then nfull="$(count_certs "${stg}/fullchain.pem")"; fi
    if (( ! have_chain )) && (( nfull < 2 )); then
      reject "$name" "no intermediate certificates: upload chain.pem (or a fullchain.pem that contains them). Use --allow-no-chain only if the certificate really has none."
      return 1
    fi
  fi

  # Normalise to a complete set (cert.pem + chain.pem + privkey.pem), so the release
  # always holds the intermediates separately, whatever combination was uploaded.
  if (( have_full )); then
    awk '/-----BEGIN CERTIFICATE-----/{i++; on=(i==1)} on{print} /-----END CERTIFICATE-----/{on=0}' "${stg}/fullchain.pem" > "${stg}/.leaf"
    if (( have_cert )); then
      if [[ "$(openssl x509 -in "${stg}/cert.pem" -noout -fingerprint -sha256 2>/dev/null)" != "$(openssl x509 -in "${stg}/.leaf" -noout -fingerprint -sha256 2>/dev/null)" ]]; then
        reject "$name" "cert.pem and the first certificate in fullchain.pem are different certificates"
        return 1
      fi
    else
      mv -- "${stg}/.leaf" "${stg}/cert.pem"; have_cert=1
    fi
    rm -f -- "${stg}/.leaf"
    if (( ! have_chain )) && (( $(count_certs "${stg}/fullchain.pem") >= 2 )); then
      awk '/-----BEGIN CERTIFICATE-----/{i++; on=(i>=2)} on{print} /-----END CERTIFICATE-----/{on=0}' "${stg}/fullchain.pem" > "${stg}/chain.pem"
      have_chain=1
    fi
  fi

  # Validate with f5-cert-push itself, so the rules are exactly the ones used at deploy time.
  local vconf="${WORK}/${name}.validate.conf"
  {
    printf '[f5:validate]\nhost = 127.0.0.1\n\n'
    printf '[cert:%s]\nle_dir = %s\nmin_days_valid = %s\nchain_check = %s\n\n' \
      "$name" "$stg" "$MIN_DAYS" "$( (( ALLOW_NO_CHAIN )) && echo warn || echo fail )"
    printf '[deploy:validate]\nf5 = validate\ncert = %s\n' "$name"
  } > "$vconf"
  chmod 600 "$vconf"
  rc=0
  out="$("$PUSH_BIN" --config "$vconf" --validate 2>&1)" || rc=$?
  if (( rc != 0 )); then
    reject "$name" "$(printf '%s\n' "$out" | grep -E '^\[-\]' | grep -v 'validation failed' | sed 's/^\[-\] *//' | head -3)"
    return 1
  fi

  new_fp="$(fp_of_dir "$stg")"
  new_end="$(end_of_dir "$stg")"
  if [[ -e "${cur}/cert.pem" || -e "${cur}/fullchain.pem" ]]; then
    cur_fp="$(fp_of_dir "$cur")"
    if [[ -n "$cur_fp" && "$cur_fp" == "$new_fp" ]]; then
      info "upload '${name}' is identical to the installed certificate; nothing to install"
      if (( ! DRY_RUN )); then clear_upload "$name"; fi
      return 0
    fi
    cur_end="$(end_of_dir "$cur")"
    new_e="$(date -d "$new_end" +%s 2>/dev/null || echo 0)"
    cur_e="$(date -d "$cur_end" +%s 2>/dev/null || echo 0)"
    if (( ! ALLOW_OLDER && new_e < cur_e )); then
      reject "$name" "the uploaded certificate expires ${new_end}, BEFORE the installed one (${cur_end}). Is this an old file? Use --allow-older if you really mean it."
      return 1
    fi
  fi

  if (( DRY_RUN )); then
    ok "DRY RUN: would install '${name}' (expires ${new_end}, sha256 ${new_fp:0:16}...)"
    return 0
  fi

  # Install as a new release, then switch "current" atomically.
  ts="$(date -u +%Y%m%d-%H%M%S)"
  rel="${STORE}/${name}/releases/${ts}"
  if [[ -e "$rel" ]]; then sleep 1; ts="$(date -u +%Y%m%d-%H%M%S)"; rel="${STORE}/${name}/releases/${ts}"; fi
  mkdir -p -- "${STORE}/${name}/releases" && chmod 700 -- "${STORE}" "${STORE}/${name}" "${STORE}/${name}/releases" \
    || { reject "$name" "cannot create ${STORE}/${name}/releases"; return 1; }
  mkdir -m 700 -- "$rel" || { reject "$name" "cannot create ${rel}"; return 1; }
  for f in cert.pem fullchain.pem chain.pem privkey.pem; do
    if [[ -f "${stg}/${f}" ]]; then cp -- "${stg}/${f}" "${rel}/${f}" || { reject "$name" "cannot write ${rel}/${f}"; return 1; }; fi
  done
  if [[ ! -f "${rel}/fullchain.pem" && -f "${rel}/cert.pem" && -f "${rel}/chain.pem" ]]; then
    cat -- "${rel}/cert.pem" "${rel}/chain.pem" > "${rel}/fullchain.pem"
  fi
  chmod 600 -- "${rel}"/*.pem 2>/dev/null
  # A symlink cannot be replaced atomically in place, so create it beside the old
  # one and rename it over (rename(2) is atomic).
  rm -f -- "${STORE}/${name}/current.new"
  if ! ln -s "releases/${ts}" "${STORE}/${name}/current.new" || ! mv -Tf -- "${STORE}/${name}/current.new" "${STORE}/${name}/current"; then
    reject "$name" "could not switch ${STORE}/${name}/current to the new release"
    return 1
  fi
  if [[ "$(fp_of_dir "${STORE}/${name}/current")" != "$new_fp" ]]; then
    reject "$name" "after installing, ${STORE}/${name}/current does not hold the new certificate"
    return 1
  fi
  ok "installed '${name}': expires ${new_end}, sha256 ${new_fp:0:16}... -> ${rel}"
  INSTALLED+=("$name")
  clear_upload "$name"
  prune_releases "$name"
  return 0
}

clear_upload() {   # remove the uploaded files (shred the key) and the markers
  local name="$1" dir="${INCOMING}/$1" f
  for f in privkey.pem cert.pem fullchain.pem chain.pem READY FAILED; do
    if [[ -f "${dir}/${f}" && ! -L "${dir}/${f}" ]]; then
      shred -u -- "${dir}/${f}" 2>/dev/null || rm -f -- "${dir}/${f}"
    elif [[ -L "${dir}/${f}" ]]; then
      rm -f -- "${dir}/${f}"
    fi
  done
}

prune_releases() {   # keep the newest KEEP_RELEASES releases (never the current one)
  local name="$1" dir="${STORE}/$1/releases" cur d n=0
  cur="$(readlink -- "${STORE}/$1/current" 2>/dev/null)"; cur="${cur##*/}"
  while IFS= read -r d; do
    [[ "$d" =~ ^[0-9]{8}-[0-9]{6}$ && "$d" != "$cur" ]] || continue
    find "${dir:?}/${d}" -type f -exec shred -u -- {} + 2>/dev/null
    rm -rf -- "${dir:?}/${d}"; n=$((n + 1))
  done < <(ls -1 "$dir" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort | head -n -"$KEEP_RELEASES")
  if (( n > 0 )); then info "removed ${n} old release(s) of '${name}'"; fi
}

#######################################################################
# Status
#######################################################################
show_status() {
  local d name cur
  echo "Installed certificates in ${STORE}:"
  while IFS= read -r name; do
    is_name "$name" || continue
    cur="${STORE}/${name}/current"
    if [[ -e "$cur" ]]; then
      printf '  %-28s expires %s  sha256 %s...  release %s\n' "$name" "$(end_of_dir "$cur")" "$(fp_of_dir "$cur" | cut -c1-16)" "$(readlink -- "$cur" | sed 's#releases/##')"
    fi
  done < <(ls -1 "$STORE" 2>/dev/null | sort)
  echo
  echo "Upload folders in ${INCOMING}:"
  while IFS= read -r name; do
    is_name "$name" || continue
    d="${INCOMING}/${name}"
    if [[ -f "$d/READY" ]]; then echo "  ${name}: READY (will be installed on the next run)"
    elif [[ -f "$d/FAILED" ]]; then echo "  ${name}: FAILED - $(sed -n 3p "$d/FAILED" | cut -c1-150)"
    elif [[ -n "$(ls -A "$d" 2>/dev/null)" ]]; then echo "  ${name}: files present, waiting for READY"
    fi
  done < <(find "$INCOMING" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
  if [[ -f "${STORE}/.push-pending" ]]; then echo; echo "A push is PENDING (the last one has not succeeded yet)."; fi
}

#######################################################################
# Main
#######################################################################
main() {
  parse_args "$@"
  local t
  for t in openssl awk sed grep sort head find cp mv ln shred stat date flock readlink dd timeout; do
    command -v "$t" >/dev/null 2>&1 || usage_die "required tool not found: ${t}"
  done
  [[ -x "$PUSH_BIN" ]] || usage_die "f5-cert-push not found or not executable: ${PUSH_BIN}"
  [[ -d "$INCOMING" ]] || usage_die "incoming directory does not exist: ${INCOMING}"

  if (( STATUS )); then show_status; exit 0; fi

  mkdir -p -- "$STORE" && chmod 700 -- "$STORE" || usage_die "cannot use the store directory ${STORE}"
  exec 9>"${STORE}/.lock" || usage_die "cannot open ${STORE}/.lock"
  if ! flock -n 9; then warn "another ${PROG} run is in progress"; exit 6; fi

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROG}.XXXXXXXX")" || { err "cannot create a scratch directory"; exit 1; }
  for d in /dev/shm; do
    if [[ -d "$d" && -w "$d" ]]; then local w; w="$(mktemp -d "$d/${PROG}.XXXXXXXX" 2>/dev/null)" && { rm -rf -- "$WORK"; WORK="$w"; }; fi
  done
  chmod 700 "$WORK"

  # Uploads: only directories with safe names and a READY marker.
  local name n=0
  while IFS= read -r name; do
    if ! is_name "$name"; then warn "ignoring upload folder with an unusable name: ${name}"; continue; fi
    if [[ -L "${INCOMING}/${name}" ]]; then warn "ignoring upload folder that is a symbolic link: ${name}"; continue; fi
    if [[ ! -f "${INCOMING}/${name}/READY" || -L "${INCOMING}/${name}/READY" ]]; then continue; fi
    n=$((n + 1))
    process_upload "$name" || true
  done < <(find "$INCOMING" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -printf '%f\n' 2>/dev/null | sort)
  if (( n == 0 )); then info "no uploads waiting in ${INCOMING}"; fi

  if (( DRY_RUN )); then
    info "dry run: nothing installed, nothing pushed"
    (( ${#REJECTED[@]} == 0 )) && exit 0 || exit 1
  fi

  local push_rc=0 do_it=0
  if (( ${#INSTALLED[@]} > 0 )); then : > "${STORE}/.push-pending"; fi
  if (( DO_PUSH )); then
    if [[ "$PUSH_WHEN" == always || -f "${STORE}/.push-pending" ]]; then do_it=1; fi
  fi
  if (( do_it )); then
    local -a sel=(--all)
    if (( ${#ENVS[@]} > 0 )); then sel=(); for t in "${ENVS[@]}"; do sel+=(--env "$t"); done; fi
    info "pushing to the BIG-IPs: ${PUSH_BIN} --config ${CONFIG} ${sel[*]}"
    local -a q=(); if (( QUIET )); then q=(--quiet); fi
    "$PUSH_BIN" --config "$CONFIG" "${sel[@]}" ${q[@]+"${q[@]}"}; push_rc=$?
    if (( push_rc == 0 )); then
      rm -f -- "${STORE}/.push-pending"
    else
      warn "the push did not fully succeed (exit ${push_rc}); it will be retried on the next run"
      : > "${STORE}/.push-pending"
    fi
  fi

  if (( push_rc == 3 || push_rc == 5 )); then exit "$push_rc"; fi
  if (( ${#REJECTED[@]} > 0 )); then exit 1; fi
  exit "$push_rc"
}

main "$@"
