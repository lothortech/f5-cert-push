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
#        - the files are copied into a private scratch directory (symlinks, hard
#          links and non-regular files are refused), and validated with
#          f5-cert-push's own checks: key matches certificate, chain present and
#          verifies, not expired, not expiring within --min-days, not older than
#          the certificate already installed (unless --allow-older);
#        - they are installed as a new release under <store>/<certname>/releases/<UTC time>/
#          and <store>/<certname>/current is switched to it atomically;
#        - the upload folder is emptied (the uploaded files are deleted; the
#          private copies are shredded).
#      A folder that fails validation gets a FAILED file explaining why, and its
#      READY file is removed, so it is not retried until someone fixes it and
#      creates READY again.
#
# TRUST BOUNDARY: this runs as root over folders that other people can write to.
# It refuses to run unless <incoming> and every directory above it can be changed
# only by root (or the user running it), and it skips an upload folder that is not
# owned by root with the sticky bit set (mode 3770): with the sticky bit, uploaders
# can add files but cannot rename or replace the folder, or anything root created
# in it. Root never opens a path in an upload folder for writing: FAILED is written
# to a new private file and renamed into place, and uploads are removed with
# unlink(), which never follows a link.
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

readonly VERSION="2.1.2"
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
# Continuation lines of a multi-line message are marked, so they cannot pass for
# messages of their own.
_out() { printf '%s %s\n' "$1" "$2" | sanitize | awk '{ printf "%s%s\n", (NR > 1 ? "    | " : ""), $0 }'; }
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

# ---- trust checks -----------------------------------------------------
ME_UID="$(id -u)"
TRUST_BAD=""
# One directory, not following links: owned by root or by us, and not writable by
# group or others unless the sticky bit is set.
dir_safe() {   # dir_safe PATH
  local st uid mode
  [[ -d "$1" && ! -L "$1" ]] || return 1
  st="$(stat -c '%u %a' -- "$1" 2>/dev/null)" || return 1
  uid="${st% *}"; mode="${st#* }"
  [[ "$uid" == 0 || "$uid" == "$ME_UID" ]] || return 1
  if (( (8#$mode & 8#022) != 0 && (8#$mode & 8#1000) == 0 )); then return 1; fi
  return 0
}
# A path, its real location and every directory above it are dir_safe: nobody
# else can change where it leads. Sets TRUST_REAL to the real path, or TRUST_BAD
# to the offending directory. (Do not call it in $(...): the globals would be lost.)
TRUST_REAL=""
trusted_tree() {   # trusted_tree PATH
  local real p="" c
  TRUST_REAL=""; TRUST_BAD=""
  real="$(readlink -f -- "$1" 2>/dev/null)" || { TRUST_BAD="$1"; return 1; }
  [[ "$real" == /* ]] || { TRUST_BAD="$1"; return 1; }
  dir_safe / || { TRUST_BAD=/; return 1; }
  local IFS=/
  for c in ${real#/}; do
    p="${p}/${c}"
    dir_safe "$p" || { TRUST_BAD="$p"; return 1; }
  done
  TRUST_REAL="$real"
}
# Everything already inside the store must look like what this wrapper makes:
# owned by root (or us), not writable by group or others, and only directories,
# regular files with a single link, and NAME/current links into releases/.
# Sets TRUST_BAD to the first offending entry. This is what catches a store that
# once was writable by others: whatever they left in it (a planted symlink, a
# hard link to a system file) is owned by them, writable, has a second link, or
# is a link the wrapper never makes.
store_tree_ok() {   # store_tree_ok DIR
  local bad
  TRUST_BAD=""
  bad="$(cd -- "$1" && find . -mindepth 1 \( \( ! -uid 0 ! -uid "$ME_UID" \) \
           -o \( ! -type l -perm /022 \) -o \( -type f -links +1 \) \
           -o \( -type l ! \( -path './*/current' ! -path './*/*/*' -lname 'releases/*' ! -lname '*..*' \) \) \
           -o \( ! -type f ! -type d ! -type l \) \) -print -quit 2>/dev/null)" \
    || { TRUST_BAD="$1"; return 1; }
  [[ -z "$bad" ]] || { TRUST_BAD="$1/${bad#./}"; return 1; }
}
# Set the "push pending" marker without following whatever is at its name: a new
# private file renamed over it (rename replaces a link, never the link's target).
mark_pending() {
  local tmp
  tmp="$(mktemp "${STORE}/.push-pending.XXXXXXXX" 2>/dev/null)" || return 1
  if ! chmod 600 -- "$tmp" || ! mv -fT -- "$tmp" "${STORE}/.push-pending"; then
    rm -f -- "$tmp"; return 1
  fi
}
# An upload folder: a real directory directly in INCOMING, owned by root (or us),
# and, if uploaders can write to it, with the sticky bit set.
upload_dir_ok() {   # upload_dir_ok NAME
  local d="${INCOMING}/$1" st uid
  dir_safe "$d" || return 1
  st="$(stat -c '%u' -- "$d" 2>/dev/null)" || return 1
  [[ "$st" == 0 || "$st" == "$ME_UID" ]]
}

# Run a command INSIDE an upload folder, holding it as the working directory: the
# folder is checked (upload_dir_ok), its device:inode recorded, then entered
# without following links, and the directory actually entered must be that same
# inode. From then on the command uses relative paths, which resolve through the
# held directory: renaming or replacing the folder's name afterwards cannot
# redirect them. (Defence in depth: with the documented permissions an uploader
# cannot rename the folder at all.) Runs in a subshell; returns the command's status,
# or 90 if the folder could not be entered safely.
in_upload_dir() {   # in_upload_dir NAME COMMAND...
  local name="$1"; shift
  (
    d="${INCOMING}/${name}"
    upload_dir_ok "$name" || exit 90
    want="$(stat -c '%d:%i' -- "$d" 2>/dev/null)" || exit 90
    cd -P -- "$d" 2>/dev/null || exit 90
    [[ "$(stat -c '%d:%i' . 2>/dev/null)" == "$want" ]] || exit 90
    dir_safe . || exit 90
    "$@"
  )
}

# Write FAILED without ever opening an uploader-controlled path for writing: the
# report goes into a new file (mktemp: O_EXCL, so a planted name cannot be
# followed), which is then renamed over whatever FAILED is (rename replaces the
# directory entry; it does not follow a symlink). In a sticky folder the uploader
# cannot touch the root-owned temporary file meanwhile.
write_failed() {   # write_failed TEXT    (run inside the upload folder: in_upload_dir)
  local tmp
  tmp="$(mktemp ./.FAILED.XXXXXXXX 2>/dev/null)" || return 1
  if ! printf '%s' "$1" >"$tmp" || ! chmod 644 -- "$tmp" || ! mv -fT -- "$tmp" ./FAILED; then
    rm -f -- "$tmp"; return 1
  fi
  rm -f -- ./READY
  return 0
}

# Mark an upload as rejected: write FAILED, remove READY so it is not retried.
reject() {   # reject NAME REASON
  local name="$1" reason="$2"
  err "upload '${name}' rejected: ${reason}"
  REJECTED+=("$name")
  if (( DRY_RUN )); then return 0; fi
  in_upload_dir "$name" write_failed "$(printf 'Rejected by %s at %s UTC\n\n%s\n\nFix the files in this folder, then create READY again (touch READY).\n' \
      "$PROG" "$(date -u '+%Y-%m-%d %H:%M:%S')" "$reason")" || warn "could not write ${INCOMING}/${name}/FAILED"
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
  # The folder itself cannot be swapped (upload_dir_ok: root-owned, sticky, in a
  # trusted tree), so only the last path component is uploader-controlled, and dd
  # opens it so that it can never be steered:
  #   iflag=nofollow  refuses a symbolic link at open() time (no check-then-use race)
  #   iflag=nonblock  a FIFO cannot make the run hang waiting for a writer
  #   count=1 of 1 MiB + 1 byte, so a huge file is never copied in full
  #   timeout         a last resort against anything else that blocks
  # A hard link is refused too (with fs.protected_hardlinks=1 an uploader can only
  # link files they own anyway). The copy is made from inside the folder, held as
  # the working directory (in_upload_dir), so not even a swap of the folder itself
  # can redirect it.
  local cout crc=0
  cout="$(in_upload_dir "$name" copy_upload_files "$stg")" || crc=$?
  if (( crc != 0 )); then
    if [[ "$cout" == REJECT\ * ]]; then reject "$name" "${cout#REJECT }"
    else reject "$name" "the upload folder could not be entered safely (it must be a directory owned by root with the sticky bit set)"; fi
    return 1
  fi
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
  for f in cert.pem fullchain.pem chain.pem privkey.pem; do
    if [[ -f "${rel}/${f}" ]]; then chmod 600 -- "${rel}/${f}" || { reject "$name" "cannot set the mode of ${rel}/${f}"; return 1; }; fi
  done
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

# Remove the uploaded files and the markers. unlink() only: it removes the
# directory entry and never follows a link, so whatever the uploader has put there
# meanwhile, nothing outside the folder is touched. (The uploaded files are not
# overwritten first: that would mean opening an uploader-controlled path for
# writing. The private copies are shredded, and docs/SECURITY.md explains how to
# keep the upload area off persistent storage.)
clear_upload() {   # clear_upload NAME
  in_upload_dir "$1" remove_upload_files || warn "could not empty the upload folder ${INCOMING}/$1"
}
remove_upload_files() {   # (run inside the upload folder: in_upload_dir)
  local f
  for f in privkey.pem cert.pem fullchain.pem chain.pem READY FAILED; do
    rm -f -- "./${f}" 2>/dev/null || true
  done
  return 0
}

# Copy the uploaded files into the private scratch directory STG (run inside the
# upload folder: in_upload_dir). Prints "REJECT <reason>" and returns 1 on refusal.
copy_upload_files() {   # copy_upload_files STG
  local stg="$1" f sz pre rc
  for f in cert.pem fullchain.pem chain.pem privkey.pem; do
    if [[ -e "./${f}" || -L "./${f}" ]]; then
      if [[ -L "./${f}" ]]; then echo "REJECT ${f} is a symbolic link (symbolic links are refused; upload the file itself)"; return 1; fi
      if [[ ! -f "./${f}" ]]; then echo "REJECT ${f} is not a regular file"; return 1; fi
      pre="$(stat -c '%h:%d:%i' -- "./${f}" 2>/dev/null)" || pre=""
      if [[ "${pre%%:*}" != 1 ]]; then echo "REJECT ${f} is a hard link to another file (upload the file itself)"; return 1; fi
      # Open the file once, then check what was OPENED (its descriptor, through
      # /proc/self/fd), not the name: it must be the same file that was checked, a
      # regular file with exactly one link. Swapping the name for a link, a hard
      # link or a FIFO between the check and the open is therefore caught; a swap
      # after the open does not matter, the open file is what is copied. The
      # timeout covers a FIFO swapped in just before the open (open would block).
      rc=0
      timeout 20 bash -c '
        exec 3<"./$1" || exit 2
        got="$(stat -L -c "%F:%h:%d:%i" /proc/self/fd/3 2>/dev/null)"
        [ "$got" = "regular file:$2" ] || [ "$got" = "regular empty file:$2" ] || exit 3
        exec dd bs=1048577 count=1 status=none of="$3" <&3
      ' copy "$f" "$pre" "${stg}/${f}" 2>/dev/null || rc=$?
      case "$rc" in
        0) ;;
        3) echo "REJECT ${f} changed while it was being read (it must be a plain file with a single link)"; return 1 ;;
        *) echo "REJECT cannot read ${f} (it must be a regular file, not a link)"; return 1 ;;
      esac
      sz="$(wc -c < "${stg}/${f}")"; sz="${sz//[[:space:]]/}"
      if (( sz == 0 || sz > 1048576 )); then echo "REJECT ${f} is empty or larger than 1 MiB"; return 1; fi
    fi
  done
  return 0
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
    if ! upload_dir_ok "$name"; then echo "  ${name}: NOT USED - the folder must be owned by root with the sticky bit set (chmod 3770)"
    elif [[ -f "$d/READY" ]]; then echo "  ${name}: READY (will be installed on the next run)"
    elif [[ -f "$d/FAILED" && ! -L "$d/FAILED" ]]; then
      echo "  ${name}: FAILED - $(timeout 5 dd if="$d/FAILED" iflag=nofollow,nonblock bs=4096 count=1 status=none 2>/dev/null | sed -n 3p | sanitize | cut -c1-150)"
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
  trusted_tree "$INCOMING" \
    || usage_die "refusing to use ${INCOMING}: ${TRUST_BAD} can be changed by someone other than root. Every directory from / down to the upload directory must be owned by root and not writable by group or others (the upload folders inside it: owned by root, mode 3770). See docs/MANUAL-UPLOAD.md."
  INCOMING="$TRUST_REAL"

  if (( STATUS )); then show_status; exit 0; fi

  if [[ ! -d "$STORE" ]]; then mkdir -p -- "$STORE" || usage_die "cannot create the store directory ${STORE}"; fi
  trusted_tree "$STORE" \
    || usage_die "refusing to use ${STORE}: ${TRUST_BAD} can be changed by someone other than root"
  STORE="$TRUST_REAL"
  # The store holds private keys and is written by root: unlike an upload folder it
  # must not be writable by anyone else at all (no sticky-bit allowance). Such a
  # store is refused rather than "repaired" with chmod, because whatever others
  # left in it would stay; and everything already in it must be ours (store_tree_ok).
  local smode
  smode="$(stat -c '%a' -- "$STORE" 2>/dev/null)" || usage_die "cannot use the store directory ${STORE}"
  if (( (8#$smode & 8#022) != 0 )); then
    usage_die "refusing to use ${STORE}: it is writable by group or others (mode ${smode}). It holds private keys: create it as 'install -d -m 700 ${STORE}' (and check what is already in it)"
  fi
  chmod 700 -- "$STORE" || usage_die "cannot use the store directory ${STORE}"
  store_tree_ok "$STORE" \
    || usage_die "refusing to use ${STORE}: ${TRUST_BAD} was not made by this wrapper (it is not owned by root, is writable by group or others, is a hard link or is a special file). Someone else may have had write access to the store: check everything in it before using it"
  if [[ -L "${STORE}/.lock" ]] || { [[ -e "${STORE}/.lock" ]] && { [[ ! -f "${STORE}/.lock" ]] || [[ ! -O "${STORE}/.lock" ]]; }; }; then
    usage_die "refusing to use ${STORE}/.lock: it is not a regular file owned by you"
  fi
  exec 9>>"${STORE}/.lock" || usage_die "cannot open ${STORE}/.lock"
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
    if ! upload_dir_ok "$name"; then
      warn "ignoring upload folder ${name}: it must be a directory owned by root, not writable by group or others unless the sticky bit is set (install -d -m 3770 -o root -g GROUP ...)"
      continue
    fi
    n=$((n + 1))
    process_upload "$name" || true
  done < <(find "$INCOMING" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -printf '%f\n' 2>/dev/null | sort)
  if (( n == 0 )); then info "no uploads waiting in ${INCOMING}"; fi

  if (( DRY_RUN )); then
    info "dry run: nothing installed, nothing pushed"
    (( ${#REJECTED[@]} == 0 )) && exit 0 || exit 1
  fi

  local push_rc=0 do_it=0
  if (( ${#INSTALLED[@]} > 0 )); then
    mark_pending || warn "could not write ${STORE}/.push-pending: if this run's push fails, it is retried only by a run with --push-when always"
  fi
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
      mark_pending || warn "could not write ${STORE}/.push-pending: the push is retried only by a run with --push-when always"
    fi
  fi

  if (( push_rc == 3 || push_rc == 5 )); then exit "$push_rc"; fi
  if (( ${#REJECTED[@]} > 0 )); then exit 1; fi
  exit "$push_rc"
}

main "$@"
