#!/usr/bin/env bash
#
# f5-cert-push - deploy TLS certificates to F5 BIG-IP devices, safely.
#
# Reads one INI-style configuration file describing your BIG-IP devices,
# certificates and deployments, then for each selected deployment: backs up what
# is on the BIG-IP (to the BIG-IP and to this host), installs the new
# certificate under versioned names, repoints the named client-ssl profiles in a
# single tmsh transaction, verifies the result, rolls back automatically if
# verification fails, and prunes old versions.
#
# Documentation: README.md and docs/ (CONFIGURATION, OPERATIONS, SECURITY,
# TESTING). Run with --help for the command-line summary.
#
# Design notes that matter to a reviewer:
#   * The configuration file is PARSED, never sourced. Every value is validated
#     against a strict character set before it can reach ssh or tmsh.
#   * errexit (set -e) is deliberately NOT used: its semantics are suppressed
#     inside functions called from conditionals, which is exactly how the job
#     stages are called. Every external command whose failure matters is checked
#     explicitly, and stage functions return non-zero on failure.
#   * Private keys are only ever written to a private (0700) tmpfs directory,
#     and to a private staging directory on the BIG-IP; both are removed on exit.
#
set -uo pipefail
# No pathname expansion: several values (certificate SANs, names) are expanded unquoted
# for word-splitting, and must never be treated as glob patterns.
set -f
export LC_ALL=C
umask 077

readonly VERSION="2.0.0"
readonly PROG="f5-cert-push"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
  echo "$PROG: bash 4.2 or newer is required (found ${BASH_VERSION})" >&2
  exit 2
fi

# Exit codes (documented in docs/OPERATIONS.md).
readonly EX_OK=0 EX_ERR=1 EX_USAGE=2 EX_ROLLED_BACK=3 EX_OUTDATED=4 EX_CRITICAL=5 EX_LOCKED=6

#######################################################################
# Global state
#######################################################################
CONFIG_FILE=""
ACTION="run"            # run | validate | list | discover | list-backups | rollback
DRY_RUN=0
CHECK_ONLY=0
FORCE=0
FAIL_FAST=0
QUIET=0
SEL_ALL=0
ROLLBACK_SET=""
declare -a SEL_DEPLOY=() SEL_ENV=() SEL_F5=() SEL_LINEAGE=()

WORK=""                 # private scratch directory (tmpfs when available)
LOG_FILE=""
JOB_TAG=""
declare -a HELD_LOCKS=()

# Remote staging directory currently in use (removed by cleanup).
STAGE_DIR=""

readonly NAME_RX='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'

#######################################################################
# Logging
#######################################################################
# Everything that came from a remote system or a file is passed through
# sanitize() before it is printed or logged, so a hostile value cannot inject
# terminal escape sequences or forge log lines.
sanitize() { LC_ALL=C tr -cd '\11\12\40-\176'; }

_logfile() {
  [[ -n "${LOG_FILE}" ]] || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"${LOG_FILE}" 2>/dev/null || true
}

_fmt() { local tag="$1"; shift; printf '%s %s%s' "$tag" "${JOB_TAG:+[${JOB_TAG}] }" "$*" | sanitize; }

info() { local l; l="$(_fmt '[*]' "$@")"; _logfile "$l"; if (( ! QUIET )); then printf '%s\n' "$l"; fi; }
ok()   { local l; l="$(_fmt '[+]' "$@")"; _logfile "$l"; if (( ! QUIET )); then printf '%s\n' "$l"; fi; }
warn() { local l; l="$(_fmt '[!]' "$@")"; _logfile "$l"; printf '%s\n' "$l" >&2; }
err()  { local l; l="$(_fmt '[-]' "$@")"; _logfile "$l"; printf '%s\n' "$l" >&2; }
die()  { err "$@"; exit "${EX_ERR}"; }
usage_die() { err "$@"; echo "Try: ${PROG} --help" >&2; exit "${EX_USAGE}"; }

#######################################################################
# Cleanup and signal handling
#######################################################################
wipe_dir() {
  local d="$1"
  [[ -n "$d" && -d "$d" ]] || return 0
  if command -v shred >/dev/null 2>&1; then
    find "$d" -type f -exec shred -u -- {} + 2>/dev/null || true
  fi
  rm -rf -- "$d"
}

release_all_locks() {
  local l
  for l in ${HELD_LOCKS[@]+"${HELD_LOCKS[@]}"}; do
    rm -rf -- "$l" 2>/dev/null || true
  done
  HELD_LOCKS=()
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [[ -n "${STAGE_DIR}" ]]; then
    remote_remove_stage || warn "could not remove remote staging directory ${STAGE_DIR}; remove it by hand"
  fi
  remote_lock_release || warn "could not release the lock on the BIG-IP; it expires by itself"
  f5_close
  release_all_locks
  wipe_dir "${WORK}"
  exit "$rc"
}
trap cleanup EXIT
trap 'err "interrupted"; exit 130' INT TERM HUP

#######################################################################
# Built-in defaults (every one can be overridden in [defaults] or a section)
#######################################################################
declare -A BUILTIN=(
  [keep]=4
  [backup_dir_local]=/var/backups/f5-cert-push
  [backup_dir_remote]=/shared/cert-backups
  [strict_host_key_checking]=yes
  [connect_timeout]=15
  [remote_timeout]=300
  [remote_lock_stale_minutes]=30
  [connection_reuse]=yes
  [min_days_valid]=1
  [auto_rollback]=yes
  [verify_unreachable]=warn
  [chain_check]=warn
  [fixed_names]=no
  [allow_standby]=no
  [port]=22
  [user]=root
  [partition]=Common
  [verify_from]=f5
  [enabled]=yes
)

usage() {
  cat <<'USAGE_EOF'
f5-cert-push - deploy TLS certificates to F5 BIG-IP devices, safely.

USAGE
  f5-cert-push.sh --config FILE SELECTOR [ACTION] [OPTIONS]

SELECTORS  (what to act on; one or more are required for run/check/rollback)
  --deploy NAME      a [deploy:NAME] section (repeatable)
  --env LABEL        every deployment whose env = LABEL (repeatable)
  --f5 NAME          restrict to one BIG-IP (repeatable; narrows the above)
  --lineage DIR      deployments using a cert whose le_dir is DIR
                     (for certbot --deploy-hook: --lineage "$RENEWED_LINEAGE")
  --all              every enabled deployment

ACTIONS  (default: deploy)
  --check            read-only: report whether each BIG-IP is current.
                     Exit 4 if anything is out of date.
  --dry-run          show exactly what a deploy would do; change nothing
  --validate         check the config file and local certificate files only
  --list             show the deployments the config defines
  --discover         list client-ssl profiles and their certificates on --f5 NAME
  --list-backups     list backup sets for the selected deployments
  --rollback --set TS
                     restore the BIG-IP state captured just before run TS

OPTIONS
  --config FILE      configuration file (default: ./f5-cert-push.conf, then
                     /etc/f5-cert-push.conf)
  --force            deploy even if the BIG-IP already has this certificate
  --fail-fast        stop after the first deployment that fails
  --quiet            print only warnings, errors and the final summary
  --version          print the version
  -h, --help         this text

EXIT CODES
  0  success, or nothing to do        3  failed after a change; rolled back
  1  error; BIG-IP unchanged          4  --check found something out of date
  2  usage or configuration error     5  CRITICAL: failed and could not roll back
  6  another run holds the lock

Full documentation: README.md and docs/.
USAGE_EOF
}

#######################################################################
# Configuration: parsing
#######################################################################
declare -A CFG=()        # "section|key" -> value  (repeatable keys: newline-joined)
declare -A SECT_SEEN=()  # "type:name" -> 1
declare -a F5S=() CERTS=() DEPLOYS=()
CFG_ERRORS=0

cfg_err() {   # cfg_err LINENO MESSAGE
  CFG_ERRORS=$((CFG_ERRORS + 1))
  printf '%s:%s: %s\n' "${CONFIG_FILE}" "$1" "$2" | sanitize >&2
}

cfg_err_sec() {  # errors found after parsing, attributed to a section
  CFG_ERRORS=$((CFG_ERRORS + 1))
  printf '%s: [%s] %s\n' "${CONFIG_FILE}" "$1" "$2" | sanitize >&2
}

key_allowed() {   # key_allowed TYPE KEY
  case "$1" in
    defaults)
      case "$2" in
        keep|backup_dir_local|backup_dir_remote|strict_host_key_checking|known_hosts_file|connect_timeout|remote_timeout|remote_lock_stale_minutes|connection_reuse|log_file|lock_dir|min_days_valid|auto_rollback|verify_unreachable|chain_check|fixed_names|allow_standby) return 0 ;;
      esac ;;
    f5)
      case "$2" in
        host|port|user|ssh_key|partition|known_hosts_file|strict_host_key_checking|backup_dir_remote|connect_timeout|remote_timeout|remote_lock_stale_minutes|connection_reuse|allow_standby|keep) return 0 ;;
      esac ;;
    cert)
      case "$2" in
        le_dir|cert|key|chain|fullchain|object_prefix|min_days_valid|chain_check) return 0 ;;
      esac ;;
    deploy)
      case "$2" in
        f5|cert|profile|verify|verify_from|env|enabled|keep|auto_rollback|fixed_names|verify_unreachable) return 0 ;;
      esac ;;
  esac
  return 1
}

key_is_multi() {
  case "$1|$2" in
    "deploy|f5"|"deploy|profile"|"deploy|verify") return 0 ;;
  esac
  return 1
}

parse_config() {
  local file="$1" line n=0 sect="" type name key val sk
  local rx_sect='^\[([a-z0-9]+)(:([A-Za-z0-9][A-Za-z0-9._-]{0,63}))?\]$'
  local rx_kv='^([a-z_0-9]+)[[:space:]]*=[[:space:]]*(.*)$'
  local rx_dq='^"(.*)"$'
  local rx_sq="^'(.*)'\$"

  if [[ ! -r "$file" || ! -f "$file" ]]; then
    echo "${PROG}: cannot read config file: ${file}" >&2
    exit "${EX_USAGE}"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    line="${line//$'\t'/ }"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "$line" || "${line:0:1}" == "#" || "${line:0:1}" == ";" ]]; then continue; fi

    # Printable ASCII only. An explicit range, not [:print:], so the result does
    # not depend on the locale (some C locales treat UTF-8 bytes as printable).
    if [[ "$line" =~ [^\ -~] ]]; then
      cfg_err "$n" "line contains non-printable or non-ASCII characters"
      continue
    fi

    if [[ "$line" =~ $rx_sect ]]; then
      type="${BASH_REMATCH[1]}"; name="${BASH_REMATCH[3]}"
      case "$type" in
        defaults)
          if [[ -n "$name" ]]; then cfg_err "$n" "[defaults] takes no name"; sect=""; continue; fi
          sect="defaults" ;;
        f5|cert|deploy)
          if [[ -z "$name" ]]; then cfg_err "$n" "[${type}] needs a name, e.g. [${type}:example]"; sect=""; continue; fi
          sect="${type}:${name}" ;;
        *)
          cfg_err "$n" "unknown section type '${type}' (use defaults, f5, cert or deploy)"; sect=""; continue ;;
      esac
      if [[ -n "${SECT_SEEN[$sect]+x}" ]]; then
        cfg_err "$n" "duplicate section [${sect}]"; sect=""; continue
      fi
      SECT_SEEN[$sect]=1
      case "$type" in
        f5) F5S+=("$name") ;;
        cert) CERTS+=("$name") ;;
        deploy) DEPLOYS+=("$name") ;;
      esac
      continue
    fi

    if [[ "$line" =~ $rx_kv ]]; then
      if [[ -z "$sect" ]]; then cfg_err "$n" "setting outside of a valid section"; continue; fi
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
      val="${val%"${val##*[![:space:]]}"}"
      if [[ "$val" =~ $rx_dq ]] || [[ "$val" =~ $rx_sq ]]; then val="${BASH_REMATCH[1]}"; fi
      type="${sect%%:*}"
      if ! key_allowed "$type" "$key"; then
        cfg_err "$n" "unknown setting '${key}' in [${sect}]"
        continue
      fi
      sk="${sect}|${key}"
      if key_is_multi "$type" "$key"; then
        if [[ -z "$val" ]]; then cfg_err "$n" "'${key}' needs a value"; continue; fi
        CFG[$sk]="${CFG[$sk]+${CFG[$sk]}$'\n'}${val}"
      else
        if [[ -n "${CFG[$sk]+x}" ]]; then cfg_err "$n" "'${key}' is set twice in [${sect}]"; continue; fi
        CFG[$sk]="$val"
      fi
      continue
    fi

    cfg_err "$n" "not a section header or a 'key = value' line"
  done <"$file"
}

# The config is data, but it names keys and paths that are used with the
# invoking user's privileges, so nobody else may be able to edit it.
check_config_permissions() {
  local f="$1" mode owner me
  mode="$(stat -c '%a' -- "$f" 2>/dev/null)" || return 0
  owner="$(stat -c '%u' -- "$f" 2>/dev/null)" || return 0
  me="$(id -u)"
  if (( (8#${mode} & 8#022) != 0 )); then
    echo "${PROG}: refusing to use ${f}: it is writable by group or others (mode ${mode}). Run: chmod 600 ${f}" >&2
    exit "${EX_USAGE}"
  fi
  if [[ "$owner" != "0" && "$owner" != "$me" ]]; then
    echo "${PROG}: refusing to use ${f}: it is owned by uid ${owner}, which is neither you nor root" >&2
    exit "${EX_USAGE}"
  fi
}

#######################################################################
# Configuration: value validation
#######################################################################
rx_path='^/[A-Za-z0-9._/+@=,:~-]*$'
is_path()    { [[ "$1" =~ $rx_path && "$1" != *"/../"* && "$1" != */.. && "$1" != *"//"* ]]; }
is_name()    { [[ "$1" =~ $NAME_RX ]]; }
is_host()    { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.:_-]{0,252}$ ]]; }
is_user()    { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
is_uint()    { [[ "$1" =~ ^[0-9]{1,6}$ ]]; }
is_label()   { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]]; }
is_profile() { [[ "$1" =~ ^(/[A-Za-z0-9][A-Za-z0-9._-]*/)?[A-Za-z0-9][A-Za-z0-9._-]*(:[A-Za-z0-9][A-Za-z0-9._-]*)?$ ]]; }
is_verify() {
  local rx='^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9][A-Za-z0-9.-]*):([0-9]{1,5})([[:space:]]+[A-Za-z0-9*][A-Za-z0-9._*-]*)?$'
  [[ "$1" =~ $rx ]] || return 1
  (( 10#${BASH_REMATCH[2]} >= 1 && 10#${BASH_REMATCH[2]} <= 65535 ))
}

norm_bool() {   # accept yes/no/true/false/1/0/on/off; print yes|no, or nothing if invalid
  case "${1,,}" in
    yes|true|1|on) echo yes ;;
    no|false|0|off) echo no ;;
  esac
}

# Validate one value. On failure prints a message and returns 1.
check_value() {   # check_value KEY VALUE
  local key="$1" val="$2"
  [[ -z "$val" ]] && return 0      # an empty value means "unset"
  case "$key" in
    host)
      is_host "$val" || { echo "'host' must be a hostname or IP address"; return 1; } ;;
    port)
      if ! is_uint "$val" || (( 10#$val < 1 || 10#$val > 65535 )); then echo "'port' must be 1-65535"; return 1; fi ;;
    user)
      is_user "$val" || { echo "'user' must be a plain account name"; return 1; } ;;
    partition)
      is_name "$val" || { echo "'partition' may contain only letters, digits, dot, underscore and hyphen"; return 1; } ;;
    backup_dir_local|backup_dir_remote|lock_dir)
      if ! is_path "$val" || [[ "$val" == / ]]; then echo "'${key}' must be an absolute directory other than / (letters, digits and . _ / + @ = , : ~ - only; no spaces, no '..')"; return 1; fi ;;
    ssh_key|known_hosts_file|log_file|le_dir|cert|key|chain|fullchain)
      is_path "$val" || { echo "'${key}' must be an absolute path using only letters, digits and . _ / + @ = , : ~ - (no spaces, no '..')"; return 1; } ;;
    strict_host_key_checking)
      [[ "$val" == yes || "$val" == accept-new ]] || { echo "'strict_host_key_checking' must be yes or accept-new"; return 1; } ;;
    keep|min_days_valid)
      is_uint "$val" || { echo "'${key}' must be a non-negative whole number"; return 1; } ;;
    connect_timeout|remote_timeout|remote_lock_stale_minutes)
      if ! is_uint "$val" || (( 10#$val < 1 )); then echo "'${key}' must be a positive number of seconds"; return 1; fi ;;
    auto_rollback|fixed_names|allow_standby|enabled|connection_reuse)
      [[ -n "$(norm_bool "$val")" ]] || { echo "'${key}' must be yes or no"; return 1; } ;;
    verify_unreachable)
      [[ "$val" == warn || "$val" == fail ]] || { echo "'verify_unreachable' must be warn or fail"; return 1; } ;;
    chain_check)
      [[ "$val" == off || "$val" == warn || "$val" == fail ]] || { echo "'chain_check' must be off, warn or fail"; return 1; } ;;
    verify_from)
      [[ "$val" == f5 || "$val" == local ]] || { echo "'verify_from' must be f5 or local"; return 1; } ;;
    object_prefix)
      if ! is_name "$val" || (( ${#val} > 48 )); then echo "'object_prefix' may contain only letters, digits, dot, underscore and hyphen, at most 48 characters"; return 1; fi ;;
    env)
      is_label "$val" || { echo "'env' must be a short label (letters, digits, . _ -)"; return 1; } ;;
  esac
  return 0
}

# Effective value: each listed section in order, then [defaults], then built-in.
eff() {   # eff KEY SECTION...
  local key="$1"; shift
  local s v
  for s in "$@"; do
    v="${CFG[$s|$key]-}"
    if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
  done
  v="${CFG[defaults|$key]-}"
  if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
  printf '%s' "${BUILTIN[$key]-}"
}

eff_bool() { norm_bool "$(eff "$@")"; }

deploy_f5s() {   # deploy_f5s NAME -> space-separated BIG-IP names (repeatable key; commas allowed)
  local v="${CFG[deploy:$1|f5]-}"
  v="${v//,/ }"
  v="${v//$'\n'/ }"
  printf '%s' "$v"
}

cert_prefix() { local p="${CFG[cert:$1|object_prefix]-}"; printf '%s' "${p:-$1}"; }

validate_config() {
  local s type key val line msg f c d p e f5n certn prefix pk le ex
  local -A prefix_owner=() prof_owner=()

  # Per-key value checks, for every section that exists.
  for s in "${!SECT_SEEN[@]}"; do
    type="${s%%:*}"
    for key in host port user ssh_key partition known_hosts_file strict_host_key_checking \
               backup_dir_remote backup_dir_local log_file lock_dir le_dir cert key chain fullchain \
               object_prefix keep min_days_valid connect_timeout remote_timeout remote_lock_stale_minutes connection_reuse auto_rollback \
               verify_unreachable chain_check fixed_names allow_standby verify_from env enabled; do
      val="${CFG[$s|$key]-}"
      [[ -n "$val" ]] || continue
      # 'cert' is a file path in [cert:*] but a section name in [deploy:*].
      if [[ "$type" == deploy && "$key" == cert ]]; then continue; fi
      if ! msg="$(check_value "$key" "$val")"; then cfg_err_sec "$s" "$msg"; fi
    done
  done

  # Repeatable keys.
  for d in ${DEPLOYS[@]+"${DEPLOYS[@]}"}; do
    s="deploy:${d}"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      is_profile "$line" || cfg_err_sec "$s" "invalid profile '${line}' (use NAME, NAME:ENTRY, /Partition/NAME or /Partition/NAME:ENTRY)"
    done <<<"${CFG[$s|profile]-}"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      is_verify "$line" || cfg_err_sec "$s" "invalid verify endpoint '${line}' (use HOST:PORT or HOST:PORT SNI-NAME)"
    done <<<"${CFG[$s|verify]-}"
  done

  # Required keys and references.
  for f in ${F5S[@]+"${F5S[@]}"}; do
    [[ -n "${CFG[f5:${f}|host]-}" ]] || cfg_err_sec "f5:${f}" "'host' is required"
  done
  for c in ${CERTS[@]+"${CERTS[@]}"}; do
    s="cert:${c}"
    le="${CFG[$s|le_dir]-}"; ex=0
    if [[ -n "${CFG[$s|cert]-}${CFG[$s|key]-}${CFG[$s|chain]-}${CFG[$s|fullchain]-}" ]]; then ex=1; fi
    if [[ -z "$le" && $ex -eq 0 ]]; then
      cfg_err_sec "$s" "set le_dir, or set key together with cert (or fullchain)"
    elif [[ -z "$le" ]]; then
      [[ -n "${CFG[$s|key]-}" ]] || cfg_err_sec "$s" "'key' is required when le_dir is not set"
      [[ -n "${CFG[$s|cert]-}${CFG[$s|fullchain]-}" ]] || cfg_err_sec "$s" "'cert' or 'fullchain' is required when le_dir is not set"
    fi
  done
  for d in ${DEPLOYS[@]+"${DEPLOYS[@]}"}; do
    s="deploy:${d}"
    if [[ -z "${CFG[$s|f5]-}" ]]; then cfg_err_sec "$s" "'f5' is required"; fi
    if [[ -z "${CFG[$s|cert]-}" ]]; then
      cfg_err_sec "$s" "'cert' is required"
    elif [[ -z "${SECT_SEEN[cert:${CFG[$s|cert]}]+x}" ]]; then
      cfg_err_sec "$s" "cert '${CFG[$s|cert]}' has no [cert:${CFG[$s|cert]}] section"
    fi
    for f5n in $(deploy_f5s "$d"); do
      is_name "$f5n" || { cfg_err_sec "$s" "invalid f5 name '${f5n}'"; continue; }
      [[ -n "${SECT_SEEN[f5:${f5n}]+x}" ]] || cfg_err_sec "$s" "f5 '${f5n}' has no [f5:${f5n}] section"
    done
  done

  # Two deployments must not manage the same objects or profiles on one BIG-IP.
  for d in ${DEPLOYS[@]+"${DEPLOYS[@]}"}; do
    s="deploy:${d}"
    [[ "$(eff_bool enabled "$s")" == yes ]] || continue
    certn="${CFG[$s|cert]-}"
    [[ -n "$certn" && -n "${SECT_SEEN[cert:${certn}]+x}" ]] || continue
    prefix="$(cert_prefix "$certn")"
    for f5n in $(deploy_f5s "$d"); do
      pk="${f5n}|${prefix}"
      if [[ -n "${prefix_owner[$pk]+x}" && "${prefix_owner[$pk]}" != "$certn" ]]; then
        cfg_err_sec "$s" "object prefix '${prefix}' on f5 '${f5n}' is already used by cert '${prefix_owner[$pk]}'"
      fi
      prefix_owner[$pk]="$certn"
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        p="${line%%:*}"
        e=""
        if [[ "$line" == *:* ]]; then e="${line#*:}"; fi
        pk="${f5n}|${p}|${e}"
        if [[ -n "${prof_owner[$pk]+x}" && "${prof_owner[$pk]}" != "$d" ]]; then
          cfg_err_sec "$s" "profile '${line}' on f5 '${f5n}' is already managed by deployment '${prof_owner[$pk]}'"
        fi
        prof_owner[$pk]="$d"
      done <<<"${CFG[$s|profile]-}"
    done
  done
}

#######################################################################
# Local certificate preparation and validation
#######################################################################
OPENSSL_VERSION="" OPENSSL_OLD=0
declare -A CERT_STATE=() CERT_DIR=() CERT_FP=() CERT_SUBJ=() CERT_SAN=() CERT_END=()
declare -A CERT_DAYS=() CERT_HAVE_CHAIN=() CERT_HAVE_FULL=() CERT_SNI=() CERT_ALGO=()

# Print PEM CERTIFICATE blocks FROM..TO (1-based, TO=0 means "to the end").
# Anything that is not a CERTIFICATE block (comments, bag attributes) is dropped.
pem_range() {   # pem_range FILE FROM TO
  awk -v from="$2" -v to="$3" '
    /-----BEGIN CERTIFICATE-----/ { i++; on = (i >= from && (to == 0 || i <= to)) }
    on { print }
    /-----END CERTIFICATE-----/   { on = 0 }
  ' "$1"
}

pem_count() {
  local n
  n="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$1" 2>/dev/null)" || n=0
  printf '%s' "$n"
}

# Copy a source file into the private work dir, refusing empty or absurdly
# large files, so validation and upload operate on the same bytes.
copy_src() {   # copy_src SRC DST
  local src="$1" dst="$2" sz
  [[ -f "$src" && -r "$src" ]] || return 1
  sz="$(wc -c <"$src" 2>/dev/null)" || return 1
  sz="${sz//[[:space:]]/}"
  (( sz > 0 && sz <= 1048576 )) || return 1
  cat -- "$src" >"$dst"
}

epoch_of() { date -d "$1" +%s 2>/dev/null; }

prepare_cert() {   # prepare_cert NAME   -> 0 if usable; result cached per cert
  local name="$1" s="cert:$1"
  if [[ -n "${CERT_STATE[$name]+x}" ]]; then [[ "${CERT_STATE[$name]}" == ok ]]; return; fi
  CERT_STATE[$name]=fail

  local le="${CFG[$s|le_dir]-}" p_cert="${CFG[$s|cert]-}" p_key="${CFG[$s|key]-}"
  local p_chain="${CFG[$s|chain]-}" p_full="${CFG[$s|fullchain]-}"
  local tag="cert '${name}'"

  if [[ -n "$le" ]]; then
    if [[ ! -d "$le" ]]; then err "${tag}: le_dir is not a directory: ${le}"; return 1; fi
    if [[ -z "$p_cert"  && -e "$le/cert.pem"      ]]; then p_cert="$le/cert.pem"; fi
    if [[ -z "$p_key"   && -e "$le/privkey.pem"   ]]; then p_key="$le/privkey.pem"; fi
    if [[ -z "$p_chain" && -e "$le/chain.pem"     ]]; then p_chain="$le/chain.pem"; fi
    if [[ -z "$p_full"  && -e "$le/fullchain.pem" ]]; then p_full="$le/fullchain.pem"; fi
  fi
  if [[ -z "$p_key" ]]; then err "${tag}: no private key file found"; return 1; fi
  if [[ -z "$p_cert" && -z "$p_full" ]]; then err "${tag}: no certificate file found (need cert or fullchain)"; return 1; fi

  local d="${WORK}/cert.${name}"
  mkdir -m 700 -- "$d" || { err "${tag}: cannot create scratch directory"; return 1; }

  # ---- private key -------------------------------------------------
  if ! copy_src "$p_key" "$d/in.key"; then
    err "${tag}: cannot read the private key (missing, empty, unreadable, or larger than 1 MiB): ${p_key}"; return 1
  fi
  if grep -q -E 'ENCRYPTED|Proc-Type:.*ENCRYPTED' "$d/in.key"; then
    err "${tag}: the private key is passphrase-protected. Encrypted keys are not supported; decrypt a copy first (openssl pkey -in KEY -out KEY.plain)."
    return 1
  fi
  local kn
  kn="$(grep -c -E '^-----BEGIN (RSA |EC )?PRIVATE KEY-----' "$d/in.key")" || kn=0
  if [[ "$kn" != 1 ]]; then
    err "${tag}: the key file must contain exactly one PEM private key (found ${kn})"; return 1
  fi
  awk '
    /^-----BEGIN (RSA |EC )?PRIVATE KEY-----/ { on = 1 }
    on { print }
    /^-----END (RSA |EC )?PRIVATE KEY-----/   { on = 0 }
  ' "$d/in.key" >"$d/key.pem"
  if ! openssl pkey -in "$d/key.pem" -noout >/dev/null 2>&1; then
    err "${tag}: the private key does not parse"; return 1
  fi
  local km
  km="$(stat -L -c '%a' -- "$p_key" 2>/dev/null)" || km=""
  if [[ -n "$km" ]] && (( (8#${km} & 8#044) != 0 )); then
    # certbot's live/ entries are symlinks into a 0600 archive; stat follows them.
    warn "${tag}: the private key file is readable by other users (mode ${km}): ${p_key}"
  fi

  # ---- certificate and chain ---------------------------------------
  local n
  if [[ -n "$p_cert" ]]; then
    if ! copy_src "$p_cert" "$d/in.cert"; then err "${tag}: cannot read the certificate: ${p_cert}"; return 1; fi
    n="$(pem_count "$d/in.cert")"
    if [[ "$n" != 1 ]]; then
      err "${tag}: 'cert' must contain exactly one certificate (the leaf); found ${n}. Put the intermediates in 'chain', or set 'fullchain' instead."
      return 1
    fi
    pem_range "$d/in.cert" 1 1 >"$d/cert.pem"
  else
    if ! copy_src "$p_full" "$d/in.full"; then err "${tag}: cannot read the fullchain: ${p_full}"; return 1; fi
    n="$(pem_count "$d/in.full")"
    if (( n < 1 )); then err "${tag}: the fullchain file contains no certificate"; return 1; fi
    pem_range "$d/in.full" 1 1 >"$d/cert.pem"
    pem_range "$d/in.full" 2 0 >"$d/chain.split"
  fi

  : >"$d/chain.pem"
  if [[ -n "$p_chain" ]]; then
    if ! copy_src "$p_chain" "$d/in.chain"; then err "${tag}: cannot read the chain: ${p_chain}"; return 1; fi
    pem_range "$d/in.chain" 1 0 >"$d/chain.pem"
    if [[ ! -s "$d/chain.pem" ]]; then err "${tag}: the chain file contains no certificate: ${p_chain}"; return 1; fi
  elif [[ -s "$d/chain.split" ]]; then
    cp -- "$d/chain.split" "$d/chain.pem"
  fi

  # Every certificate must parse on its own.
  local i cn
  if ! openssl x509 -in "$d/cert.pem" -noout >/dev/null 2>&1; then err "${tag}: the certificate does not parse"; return 1; fi
  cn="$(pem_count "$d/chain.pem")"
  for (( i = 1; i <= cn; i++ )); do
    if ! pem_range "$d/chain.pem" "$i" "$i" | openssl x509 -noout >/dev/null 2>&1; then
      err "${tag}: certificate ${i} of the chain does not parse"; return 1
    fi
  done

  # fullchain object (only used when fixed_names = yes): supplied, or leaf+chain.
  if [[ -n "$p_full" && -f "$d/in.full" ]]; then
    pem_range "$d/in.full" 1 0 >"$d/fullchain.pem"
  elif [[ -n "$p_full" ]]; then
    if copy_src "$p_full" "$d/in.full"; then pem_range "$d/in.full" 1 0 >"$d/fullchain.pem"; else : >"$d/fullchain.pem"; fi
  else
    cat -- "$d/cert.pem" "$d/chain.pem" >"$d/fullchain.pem"
  fi
  CERT_HAVE_CHAIN[$name]=0
  if [[ -s "$d/chain.pem" ]]; then CERT_HAVE_CHAIN[$name]=1; fi
  CERT_HAVE_FULL[$name]=0
  if [[ -s "$d/fullchain.pem" ]]; then CERT_HAVE_FULL[$name]=1; fi

  # ---- consistency and validity ------------------------------------
  local cpub kpub
  cpub="$(openssl x509 -in "$d/cert.pem" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}')"
  kpub="$(openssl pkey -in "$d/key.pem" -pubout 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}')"
  if [[ -z "$cpub" || "$cpub" != "$kpub" ]]; then
    err "${tag}: the private key does not match the certificate"; return 1
  fi

  if ! openssl x509 -in "$d/cert.pem" -noout -checkend 0 >/dev/null 2>&1; then
    err "${tag}: the certificate has already expired"; return 1
  fi
  local nb_s na_s nb na now days mind
  nb_s="$(openssl x509 -in "$d/cert.pem" -noout -startdate | cut -d= -f2-)"
  na_s="$(openssl x509 -in "$d/cert.pem" -noout -enddate   | cut -d= -f2-)"
  nb="$(epoch_of "$nb_s")" || nb=""
  na="$(epoch_of "$na_s")" || na=""
  if [[ -z "$nb" || -z "$na" ]]; then err "${tag}: cannot read the certificate validity dates"; return 1; fi
  now="$(date +%s)"
  if (( nb > now + 300 )); then err "${tag}: the certificate is not valid yet (starts ${nb_s})"; return 1; fi
  days=$(( (na - now) / 86400 ))
  mind="$(eff min_days_valid "$s")"
  if (( days < 10#${mind} )); then
    err "${tag}: the certificate expires in ${days} day(s); min_days_valid is ${mind}"; return 1
  fi

  local cc
  cc="$(eff chain_check "$s")"
  if [[ -s "$d/chain.pem" && "$cc" != off && "${OPENSSL_OLD}" == 1 ]]; then
    # OpenSSL older than 1.1.0 cannot do this check: its "verify -partial_chain"
    # reports OK even for a chain that does not match (it skips the signature check
    # when the issuer is found by name), and exits 0 on failure. Say so rather than
    # claim a verification that did not happen.
    if [[ "$cc" == fail ]]; then
      err "${tag}: chain_check = fail needs OpenSSL 1.1.0 or newer (this host has ${OPENSSL_VERSION}), which is required to verify a chain reliably; use a newer OpenSSL or set chain_check = off"
      return 1
    fi
    warn "${tag}: the chain was NOT verified: OpenSSL ${OPENSSL_VERSION} is too old to do it reliably (need 1.1.0+). Set chain_check = off to silence this."
  elif [[ -s "$d/chain.pem" && "$cc" != off ]]; then
    # Read the result from the output, not the exit status (older OpenSSL versions
    # exit 0 even when verification fails).
    local vout
    vout="$(openssl verify -partial_chain -CAfile "$d/chain.pem" "$d/cert.pem" 2>&1)" || true
    if [[ "$vout" != *": OK"* || "$vout" == *[Ee]rror* ]]; then
      if [[ "$cc" == fail ]]; then
        err "${tag}: the certificate does not verify against the supplied chain (chain_check = fail)"; return 1
      fi
      warn "${tag}: the certificate does not verify against the supplied chain; check that the chain holds the right intermediates (chain_check = warn)"
    fi
  fi

  CERT_DIR[$name]="$d"
  CERT_FP[$name]="$(openssl x509 -in "$d/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'a-f' 'A-F')"
  CERT_SUBJ[$name]="$(openssl x509 -in "$d/cert.pem" -noout -subject | sed 's/^subject= *//')"
  CERT_SAN[$name]="$(openssl x509 -in "$d/cert.pem" -noout -text 2>/dev/null | awk '/Subject Alternative Name/{getline; gsub(/^ +/, ""); print; exit}')"
  CERT_END[$name]="$na_s"
  CERT_DAYS[$name]="$days"
  CERT_ALGO[$name]="$(openssl x509 -in "$d/cert.pem" -noout -text 2>/dev/null | awk '/Public Key Algorithm/{print $NF; exit}')"

  # SNI for verification probes: the first non-wildcard DNS name, else the CN.
  local sni="" cand
  for cand in $(printf '%s' "${CERT_SAN[$name]}" | tr ',' ' ' | tr -s ' '); do
    case "$cand" in
      DNS:\**) ;;
      DNS:*) if [[ -z "$sni" ]]; then sni="${cand#DNS:}"; fi ;;
    esac
  done
  if [[ -z "$sni" ]]; then
    sni="$(printf '%s' "${CERT_SUBJ[$name]}" | sed -n 's/.*CN *= *\([^,\/]*\).*/\1/p' | tr -d ' ')"
    case "$sni" in *'*'*) sni="" ;; esac
  fi
  CERT_SNI[$name]="$sni"

  CERT_STATE[$name]=ok
  ok "${tag}: ${CERT_SUBJ[$name]}; ${CERT_ALGO[$name]}; expires ${CERT_END[$name]} (${days} days); sha256 ${CERT_FP[$name]:0:16}..."
  return 0
}

#######################################################################
# BIG-IP access
#######################################################################
F5_NAME="" F5_HOST="" F5_PORT="" F5_USER="" F5_PART="" F5_KEY=""
F5_BACKUP_ROOT="" F5_BACKUP_LOCAL=""
SSH_MUX=0
declare -a SSH_OPTS=()
REMOTE_TIMEOUT=300

f5_load() {   # f5_load NAME   (sets the F5_* globals and the ssh options)
  local s="f5:$1" shk kh ct
  F5_NAME="$1"
  F5_HOST="${CFG[$s|host]}"
  F5_PORT="$(eff port "$s")"
  F5_USER="$(eff user "$s")"
  F5_PART="$(eff partition "$s")"
  F5_KEY="${CFG[$s|ssh_key]-}"
  shk="$(eff strict_host_key_checking "$s")"
  kh="$(eff known_hosts_file "$s")"
  ct="$(eff connect_timeout "$s")"
  REMOTE_TIMEOUT="$(eff remote_timeout "$s")"
  SSH_OPTS=(-T -p "$F5_PORT"
    -o BatchMode=yes -o "ConnectTimeout=${ct}" -o ServerAliveInterval=15 -o ServerAliveCountMax=3
    -o "StrictHostKeyChecking=${shk}" -o LogLevel=ERROR
    -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes
    -o PreferredAuthentications=publickey -o PasswordAuthentication=no)
  # One SSH connection is reused for all the steps of a job (BIG-IP logins are slow
  # and each one is logged). The control socket lives in the private scratch
  # directory (mode 0700) and is closed again by f5_close.
  SSH_MUX=0
  if [[ "$(eff_bool connection_reuse "$s")" == yes ]]; then
    SSH_OPTS+=(-o ControlMaster=auto -o "ControlPath=${WORK}/cm-%C" -o ControlPersist=120)
    SSH_MUX=1
  else
    SSH_OPTS+=(-o ControlMaster=no -o ControlPath=none)
  fi
  if [[ -n "$F5_KEY" ]]; then SSH_OPTS+=(-i "$F5_KEY" -o IdentitiesOnly=yes); fi
  if [[ -n "$kh" ]]; then SSH_OPTS+=(-o "UserKnownHostsFile=${kh}"); fi
}

# Run a script (first argument) on the BIG-IP with the remaining arguments as
# its positional parameters. ssh joins its arguments into a single string that
# the remote shell re-parses, so every argument is shell-quoted here.
# stdout is the script's stdout; stderr is kept in ${WORK}/ssh.err.
f5_sh() {
  local script="$1" a q="" rc=0
  shift
  for a in "$@"; do q+=" $(printf '%q' "$a")"; done
  printf '%s\n' "$script" \
    | timeout "${REMOTE_TIMEOUT}" ssh "${SSH_OPTS[@]}" -- "${F5_USER}@${F5_HOST}" "bash -s --${q}" 2>"${WORK}/ssh.err" \
    || rc=$?
  return "$rc"
}

remote_err() { head -c 1500 "${WORK}/ssh.err" 2>/dev/null | sanitize; }

f5_put() {   # f5_put LOCALFILE REMOTEPATH
  local src="$1" dst="$2" rc=0
  timeout "${REMOTE_TIMEOUT}" ssh "${SSH_OPTS[@]}" -- "${F5_USER}@${F5_HOST}" \
    "umask 077; cat > $(printf '%q' "$dst")" <"$src" 2>"${WORK}/ssh.err" || rc=$?
  return "$rc"
}

f5_get() {   # f5_get REMOTEPATH LOCALFILE
  local src="$1" dst="$2" rc=0
  timeout "${REMOTE_TIMEOUT}" ssh "${SSH_OPTS[@]}" -- "${F5_USER}@${F5_HOST}" \
    "cat -- $(printf '%q' "$src")" >"$dst" 2>"${WORK}/ssh.err" || rc=$?
  return "$rc"
}

# Close the shared connection (if any) to the BIG-IP currently loaded.
f5_close() {
  (( SSH_MUX )) || return 0
  timeout 10 ssh "${SSH_OPTS[@]}" -O exit -- "${F5_USER}@${F5_HOST}" >/dev/null 2>&1 || true
  return 0
}

define() { IFS= read -r -d '' "$1" || true; }

#######################################################################
# Remote scripts (bash 4.2 compatible; run on the BIG-IP)
#######################################################################
define R_LIB <<'REMOTE_EOF'
# A tmsh error carries an 8-hex-digit code and a severity (0-3 = error or worse).
tmsh_failed() {
  printf '%s\n' "$1" | grep -Eq '^[0-9a-fA-F]{8}:[0-3]:|transaction failed|Syntax Error|Unexpected Error'
}

# Split an object name into partition (OP) and base name (OB). Names shown
# without a leading /Partition/ live in Common.
split_obj() {
  case "$1" in
    /*) OP="${1#/}"; OP="${OP%%/*}"; OB="${1#/${OP}/}" ;;
    *)  OP=Common; OB="$1" ;;
  esac
}

# Print the newest filestore file backing a certificate or key object.
# kind = cert|key. The filestore name carries a _<id>_<rev> suffix.
find_pem() {
  local kind="$1" sub=certificate_d f best="" base escn escp
  if [ "$kind" = key ]; then sub=certificate_key_d; fi
  split_obj "$2"
  escn="${OB//./\\.}"; escp="${OP//./\\.}"
  for f in "/config/filestore/files_d/${OP}_d/${sub}/:${OP}:${OB}"_*; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    [[ "$base" =~ ^:${escp}:${escn}_[0-9]+_[0-9]+$ ]] || continue
    if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best="$f"; fi
  done
  if [ -n "$best" ]; then printf '%s\n' "$best"; fi
  return 0
}

# Run tmsh commands from stdin as one transaction. Prints tmsh's output;
# returns 1 if the transaction failed.
run_txn() {
  local out
  out="$( { echo "create cli transaction"; cat; echo "submit cli transaction"; } | tmsh 2>&1 )"
  printf '%s\n' "$out"
  if tmsh_failed "$out"; then return 1; fi
  return 0
}
REMOTE_EOF

define R_PROBE <<'REMOTE_EOF'
# args: PARTITION [PROFILE...]
PART="$1"; shift
echo "VERSION|$(tmsh -q show sys version 2>/dev/null | awk '/^  Version/{print $2; exit}')"
echo "MCP|$(tmsh -q show sys mcp-state field-fmt 2>/dev/null | awk '$1=="phase"{p=$2} $1=="last-load"{l=$2} END{print p "|" l}')"
echo "FAILOVER|$(tmsh -q show sys failover 2>/dev/null | head -1 | awk '{print tolower($2)}')"
echo "SYNC|$(tmsh -q show cm sync-status 2>/dev/null | awk '$1=="Mode"{print $2; exit}')"
if tmsh -q list auth partition "$PART" 2>&1 | grep -q '^auth partition'; then
  echo "PARTITION|OK"
else
  echo "PARTITION|MISSING"
fi
for p in "$@"; do
  out="$(tmsh -q list ltm profile client-ssl "$p" inherit-certkeychain cert-key-chain 2>/dev/null)" || out=""
  if [ -z "$out" ]; then echo "PROFILE|$p|MISSING"; continue; fi
  inh="$(printf '%s\n' "$out" | awk '$1=="inherit-certkeychain"{print $2}')"
  echo "PROFILE|$p|OK|${inh:-false}"
  printf '%s\n' "$out" | awk -v P="$p" '
    function flush() { print "ENTRY|" P "|" e "|" c "|" h "|" k "|" pp }
    /^        [^ ].* \{$/ { if (e != "") flush(); e = $1; c = "none"; h = "none"; k = "none"; pp = "none"; next }
    /^            cert /       { c = $2 }
    /^            chain /      { h = $2 }
    /^            key /        { k = $2 }
    /^            passphrase / { pp = $2 }
    END { if (e != "") flush() }'
done
REMOTE_EOF

define R_OBJINFO <<'REMOTE_EOF'
# args: cert:NAME | key:NAME ...
for spec in "$@"; do
  kind="${spec%%:*}"; name="${spec#*:}"
  if [ "$kind" = cert ]; then
    o="$(tmsh -q list sys file ssl-cert "$name" fingerprint expiration-date 2>/dev/null)" || o=""
    if [ -z "$o" ]; then echo "OBJ|cert|$name|MISSING"; continue; fi
    fp="$(printf '%s\n' "$o" | awk '$1=="fingerprint"{print $2}')"
    ex="$(printf '%s\n' "$o" | awk '$1=="expiration-date"{print $2}')"
    fp="$(printf '%s' "${fp#*/}" | tr -d ':' | tr 'a-f' 'A-F')"
    echo "OBJ|cert|$name|OK|$fp|$ex"
  else
    o="$(tmsh -q list sys file ssl-key "$name" key-type 2>/dev/null)" || o=""
    if [ -n "$o" ]; then echo "OBJ|key|$name|OK"; else echo "OBJ|key|$name|MISSING"; fi
  fi
done
REMOTE_EOF

define R_BACKUP <<'REMOTE_EOF'
# args: BDIR TS SPEC...
#   SPEC = meta:KEY=VALUE | keep-cert:NAME | keep-key:NAME | fix-cert:NAME | fix-key:NAME
#        | bind:PROFILE:ENTRY:CERT:CHAIN:KEY
# keep-*  the old object stays on the BIG-IP; restore only reinstalls it if missing
# fix-*   the object will be overwritten in place; restore always reinstalls it
set -u
BDIR="$1"; TS="$2"; shift 2
umask 077
mkdir -p "$(dirname "$BDIR")" || { echo "ERR|cannot create $(dirname "$BDIR")"; exit 1; }
mkdir "$BDIR" || { echo "ERR|backup directory already exists: $BDIR"; exit 1; }
R="$BDIR/restore-$TS.sh"
BODY="$BDIR/.body"; TXN="$BDIR/.txn"
: > "$BODY"; : > "$TXN"; : > "$BDIR/MANIFEST"
files=""

for spec in "$@"; do
  kind="${spec%%:*}"; rest="${spec#*:}"
  case "$kind" in
    meta)
      printf '%s\n' "$rest" >> "$BDIR/MANIFEST" ;;
    keep-cert|keep-key|fix-cert|fix-key)
      t="${kind#*-}"; name="$rest"
      path="$(find_pem "$t" "$name")"
      if [ -z "$path" ]; then
        case "$kind" in
          keep-*) echo "ERR|cannot locate the file behind $t object $name"; exit 1 ;;
          *)      echo "NOTE|$t object $name has no file to back up"; continue ;;
        esac
      fi
      safe="${name#/}"; safe="${safe//\//__}"
      out="$t.$safe"
      cat -- "$path" > "$BDIR/$out" || { echo "ERR|cannot copy $path"; exit 1; }
      [ -s "$BDIR/$out" ] || { echo "ERR|backup of $name is empty"; exit 1; }
      files="$files $out"
      case "$kind" in
        keep-*) printf "ensure %s '%s' \"\$D/%s\"\n" "$t" "$name" "$out" >> "$BODY" ;;
        fix-*)  printf "force %s '%s' \"\$D/%s\"\n" "$t" "$name" "$out" >> "$BODY" ;;
      esac ;;
    bind)
      IFS=: read -r _ p e c h k <<< "$spec"
      printf 'modify ltm profile client-ssl %s cert-key-chain modify { %s { cert %s chain %s key %s } }\n' "$p" "$e" "$c" "$h" "$k" >> "$TXN" ;;
  esac
done

{
  echo '#!/bin/bash'
  echo "# Generated by f5-cert-push. Restores the BIG-IP state captured just before run $TS."
  echo "# Run on the BIG-IP as root:   bash restore-$TS.sh"
  cat <<'HDR'
set -u
D="$(cd "$(dirname "$0")" && pwd)"
if [ -s "$D/SHA256SUMS" ]; then
  ( cd "$D" && sha256sum -c --quiet SHA256SUMS ) || { echo "backup integrity check FAILED; nothing was changed" >&2; exit 1; }
fi
failed() { printf '%s\n' "$1" | grep -Eq '^[0-9a-fA-F]{8}:[0-3]:|transaction failed|Syntax Error|Unexpected Error'; }
inst() {
  out="$(tmsh install sys crypto "$1" "$2" from-local-file "$3" 2>&1)"
  if failed "$out"; then echo "install of $1 $2 FAILED: $out" >&2; exit 1; fi
  echo "    reinstalled $1 $2"
}
exists() { [ -n "$(tmsh -q list sys file "$1" "$2" 2>/dev/null)" ]; }
ensure() {
  if [ "$1" = key ]; then c=ssl-key; else c=ssl-cert; fi
  if exists "$c" "$2"; then echo "    $1 $2 still present"; else inst "$1" "$2" "$3"; fi
}
force() { inst "$1" "$2" "$3"; }
HDR
  cat "$BODY"
  if [ -s "$TXN" ]; then
    echo 'OUT="$({'
    echo 'echo "create cli transaction"'
    while IFS= read -r l; do printf "echo '%s'\n" "$l"; done < "$TXN"
    echo 'echo "submit cli transaction"'
    echo '} | tmsh 2>&1)"'
    echo 'printf "%s\n" "$OUT"'
    echo 'if failed "$OUT"; then echo "restoring the profiles FAILED" >&2; exit 1; fi'
    echo 'echo "    profiles repointed"'
  fi
  echo 'tmsh save sys config > /dev/null'
  echo "echo '[+] restored the state captured before run $TS'"
} > "$R"
chmod 700 "$R"
rm -f "$BODY" "$TXN"

if [ -n "$files" ]; then
  ( cd "$BDIR" && sha256sum -- $files > SHA256SUMS ) || { echo "ERR|cannot checksum the backup"; exit 1; }
else
  : > "$BDIR/SHA256SUMS"
fi
for f in $files "restore-$TS.sh" MANIFEST SHA256SUMS; do echo "FILE|$f"; done
REMOTE_EOF

define R_STAGE <<'REMOTE_EOF'
# Remove abandoned staging directories (older than two hours), then make a new one.
find /var/tmp -maxdepth 1 -type d -name 'f5-cert-push.*' -mmin +120 -exec rm -rf -- {} + 2>/dev/null
d="$(mktemp -d /var/tmp/f5-cert-push.XXXXXXXX)" || exit 1
chmod 700 "$d"
echo "STAGE|$d"
REMOTE_EOF

define R_STAGE_CHECK <<'REMOTE_EOF'
# args: STAGE FILE...   -> SUM|file|sha256
cd "$1" || exit 1
shift
for f in "$@"; do
  echo "SUM|$f|$(sha256sum -- "$f" | awk '{print $1}')"
done
REMOTE_EOF

define R_INSTALL <<'REMOTE_EOF'
# args: STAGE SPEC...   SPEC = new-key|new-cert|set-key|set-cert : NAME : FILE
# new-*  installs a fresh object (removed again by the caller if a later step fails)
# set-*  overwrites an existing object in place
STAGE="$1"; shift
for spec in "$@"; do
  mode="${spec%%:*}"; rest="${spec#*:}"; name="${rest%%:*}"; file="${rest#*:}"
  case "$mode" in
    new-key|set-key)   kind=key ;;
    new-cert|set-cert) kind=cert ;;
    *) echo "FAIL|bad install spec $spec"; exit 1 ;;
  esac
  out="$(tmsh install sys crypto "$kind" "$name" from-local-file "$STAGE/$file" 2>&1)"
  if tmsh_failed "$out"; then
    echo "FAIL|install of $kind $name: $(printf '%s' "$out" | tr '\n|' '  ' | head -c 300)"
    exit 1
  fi
  case "$mode" in
    new-*) echo "CREATED|$kind|$name" ;;
    set-*) echo "SET|$kind|$name" ;;
  esac
done
REMOTE_EOF

define R_TXN <<'REMOTE_EOF'
# args: bind:PROFILE:ENTRY:CERT:CHAIN:KEY ...   (one transaction for all of them)
out="$( for spec in "$@"; do
  IFS=: read -r _ p e c h k <<< "$spec"
  printf 'modify ltm profile client-ssl %s cert-key-chain modify { %s { cert %s chain %s key %s } }
' "$p" "$e" "$c" "$h" "$k"
done | run_txn )"
rc=$?
printf '%s' "$out" | tr '
|' '  ' | head -c 600 | sed 's/^/TXNOUT|/'; echo
if [ $rc -ne 0 ]; then echo "TXN|FAILED"; exit 1; fi
out="$(tmsh save sys config 2>&1)"
if tmsh_failed "$out"; then echo "SAVE|FAILED"; exit 2; fi
echo "TXN|OK"
REMOTE_EOF

define R_DELETE <<'REMOTE_EOF'
# args: cert:NAME | key:NAME ...   best-effort removal of objects we created
for spec in "$@"; do
  kind="${spec%%:*}"; name="${spec#*:}"
  out="$(tmsh delete sys crypto "$kind" "$name" 2>&1)"
  if tmsh_failed "$out"; then echo "KEPT|$kind|$name"; else echo "DELETED|$kind|$name"; fi
done
tmsh save sys config >/dev/null 2>&1
REMOTE_EOF

define R_PRUNE_BACKUPS <<'REMOTE_EOF'
# args: ROOT KEEP
ROOT="$1"; KEEP="$2"
[ -d "$ROOT" ] || exit 0
ls -1 "$ROOT" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort | head -n -"$KEEP" | while read -r d; do
  rm -rf -- "${ROOT:?}/$d" && echo "REMOVED|$d"
done
exit 0
REMOTE_EOF

define R_PRUNE_OBJECTS <<'REMOTE_EOF'
# args: PARTITION PREFIX KEEP
# Removes timestamped object sets older than the newest KEEP. The BIG-IP refuses
# to delete an object that a profile still references, so a set in use survives
# even if this count were wrong.
# NOTE: "recursive" from the default folder only covers /Common. After "cd /" it
# spans every partition, and names are printed as Partition/name.
PART="$1"; PREFIX="$2"; KEEP="$3"
names="$(printf '%s\n' 'cd /' 'list sys file ssl-cert one-line recursive' | tmsh -q 2>/dev/null | awk '{print $4}')"
[ -n "$names" ] || exit 0
stamps=""
for n in $names; do
  case "$n" in */*) dir="${n%/*}"; b="${n##*/}" ;; *) continue ;; esac
  [ "$dir" = "$PART" ] || continue
  case "$b" in
    "$PREFIX"-cert-*.pem)
      s="${b#"$PREFIX"-cert-}"; s="${s%.pem}"
      case "$s" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) stamps="${stamps}${s}
" ;;
      esac ;;
  esac
done
stamps="$(printf '%s' "$stamps" | sort -u)"
[ -n "$stamps" ] || exit 0
total="$(printf '%s\n' "$stamps" | wc -l)"
if [ "$total" -le "$KEEP" ]; then echo "NOTE|$total object set(s), keeping $KEEP"; exit 0; fi
if [ "$PART" = Common ]; then pfx=""; else pfx="/$PART/"; fi
printf '%s\n' "$stamps" | head -n -"$KEEP" | while read -r s; do
  [ -n "$s" ] || continue
  for o in "cert:${pfx}${PREFIX}-cert-${s}.pem" "cert:${pfx}${PREFIX}-chain-${s}.pem" "key:${pfx}${PREFIX}-privkey-${s}.pem"; do
    kind="${o%%:*}"; nm="${o#*:}"
    out="$(tmsh delete sys crypto "$kind" "$nm" 2>&1)"
    if tmsh_failed "$out"; then echo "KEPT|$kind|$nm"; else echo "DELETED|$kind|$nm"; fi
  done
done
tmsh save sys config >/dev/null 2>&1
exit 0
REMOTE_EOF

define R_ENDPOINT <<'REMOTE_EOF'
# args: HOST PORT SNI   -> ENDPOINT|sha256hex|chain-depth   (empty fingerprint = no handshake)
host="$1"; port="$2"; sni="$3"
set -- -connect "$host:$port" -showcerts
if [ -n "$sni" ]; then set -- "$@" -servername "$sni"; fi
pem="$(echo | timeout 15 openssl s_client "$@" 2>/dev/null)"
depth="$(printf '%s\n' "$pem" | grep -c 'BEGIN CERTIFICATE')"
fp="$(printf '%s\n' "$pem" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2- | tr -d ':')"
echo "ENDPOINT|$fp|$depth"
REMOTE_EOF

define R_LISTB <<'REMOTE_EOF'
# args: ROOT
ROOT="$1"
[ -d "$ROOT" ] || exit 0
ls -1 "$ROOT" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort | while read -r d; do
  echo "SET|$d|$(ls -1 "$ROOT/$d" 2>/dev/null | grep -c '\.')"
done
REMOTE_EOF

define R_RESTORE <<'REMOTE_EOF'
# args: BDIR TS
BDIR="$1"; TS="$2"
[ -f "$BDIR/restore-$TS.sh" ] || { echo "no restore script at $BDIR/restore-$TS.sh" >&2; exit 1; }
bash "$BDIR/restore-$TS.sh"
REMOTE_EOF

define R_LOCK <<'REMOTE_EOF'
# args: STALE_MINUTES TOKEN OWNER-TEXT      -> LOCK|OK|new, LOCK|OK|stale or LOCK|BUSY|<owner>
stale="$1"; token="$2"; owner="$3"
L=/var/run/f5-cert-push.lock
take() { printf '%s\n%s\n' "$token" "$owner" > "$L/owner" && echo "LOCK|OK|$1"; }
if mkdir -m 700 "$L" 2>/dev/null; then take new; exit 0; fi
if [ -n "$(find "$L" -maxdepth 0 -mmin +"$stale" 2>/dev/null)" ]; then
  rm -rf "$L"
  if mkdir -m 700 "$L" 2>/dev/null; then take stale; exit 0; fi
fi
echo "LOCK|BUSY|$(sed -n 2p "$L/owner" 2>/dev/null | head -c 120 | tr '|' ' ')"
exit 0
REMOTE_EOF

define R_UNLOCK <<'REMOTE_EOF'
# args: TOKEN      (removes the lock only if we still own it)
L=/var/run/f5-cert-push.lock
if [ "$(sed -n 1p "$L/owner" 2>/dev/null)" = "$1" ]; then rm -rf "$L"; echo "UNLOCK|OK"; else echo "UNLOCK|NOTOURS"; fi
REMOTE_EOF

define R_DISCOVER <<'REMOTE_EOF'
# Lists every client-ssl profile entry in every partition. ("cd /" makes the
# recursive listing span partitions; names then print as Partition/name.)
for p in $(printf '%s\n' 'cd /' 'list ltm profile client-ssl one-line recursive' | tmsh -q 2>/dev/null | awk '{print $4}'); do
  tmsh -q list ltm profile client-ssl "/$p" cert-key-chain 2>/dev/null | awk -v P="/$p" '
    function flush() { if (e != "") print "DP|" P "|" e "|" c "|" h "|" k }
    /^        [^ ].* \{$/ { flush(); e = $1; c = "none"; h = "none"; k = "none"; next }
    /^            cert /   { c = $2 }
    /^            chain /  { h = $2 }
    /^            key /    { k = $2 }
    END { flush() }'
done
REMOTE_EOF

#######################################################################
# Locking (one run at a time per BIG-IP)
#######################################################################
lock_dir() {
  local d
  d="$(eff lock_dir "f5:${F5_NAME}")"
  if [[ -z "$d" ]]; then
    if [[ "$(id -u)" == 0 ]]; then d="/var/lock/f5-cert-push"; else d="${XDG_RUNTIME_DIR:-/tmp}/f5-cert-push-$(id -u)"; fi
  fi
  printf '%s' "$d"
}

# Returns 0 if acquired, 2 if another live run holds it, 1 on error.
lock_acquire() {
  local dir key lk pid
  dir="$(lock_dir)"
  mkdir -p -- "$dir" 2>/dev/null && chmod 700 -- "$dir" 2>/dev/null || { err "cannot create lock directory ${dir}"; return 1; }
  key="$(printf '%s_%s' "$F5_HOST" "$F5_PORT" | tr -c 'A-Za-z0-9._-' '_')"
  lk="${dir}/${key}.lock"
  if mkdir -m 700 -- "$lk" 2>/dev/null; then
    printf '%s\n' "$$" >"$lk/pid"; HELD_LOCKS+=("$lk"); return 0
  fi
  pid="$(cat -- "$lk/pid" 2>/dev/null)" || pid=""
  if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
    warn "removing stale lock left by process ${pid}"
    rm -rf -- "$lk"
    if mkdir -m 700 -- "$lk" 2>/dev/null; then
      printf '%s\n' "$$" >"$lk/pid"; HELD_LOCKS+=("$lk"); return 0
    fi
  fi
  return 2
}

lock_release() { remote_lock_release || true; release_all_locks; }

# The BIG-IP-side lock makes the "one run at a time" rule hold across hosts: two
# machines that both push to one BIG-IP cannot interleave.
REMOTE_LOCK_TOKEN=""

# 0 acquired, 2 busy, 1 error
remote_lock_acquire() {
  local out rc=0 tag a b stale token owner
  stale="$(eff remote_lock_stale_minutes "f5:${J_F5}")"
  token="${PROG}.$$.${RANDOM}.$(date +%s)"
  owner="$(id -un 2>/dev/null)@$(hostname -s 2>/dev/null) pid $$ $(date '+%F %T')"
  owner="$(printf '%s' "$owner" | sanitize | tr -d "'\"|" | tr -d '\\')"
  # The token is recorded BEFORE the call: if a signal arrives after the BIG-IP has
  # created the lock but before its reply is read, cleanup must still release it.
  # Releasing is safe even when we never got the lock: the BIG-IP only removes a
  # lock whose token matches.
  REMOTE_LOCK_TOKEN="$token"
  out="$(f5_sh "${R_LOCK}" "$stale" "$token" "$owner")" || rc=$?
  if (( rc != 0 )); then
    err "cannot take the lock on the BIG-IP: $(remote_err)"
    remote_lock_release || true
    return 1
  fi
  while IFS='|' read -r tag a b; do
    [[ "$tag" == LOCK ]] || continue
    case "$a" in
      OK)
        if [[ "$b" == stale ]]; then warn "removed a stale lock on the BIG-IP (older than ${stale} minutes)"; fi
        return 0 ;;
      BUSY)
        REMOTE_LOCK_TOKEN=""
        warn "another f5-cert-push run holds the lock on the BIG-IP (${b})"
        return 2 ;;
    esac
  done <<<"$out"
  err "unexpected reply while taking the lock on the BIG-IP"
  remote_lock_release || true
  return 1
}

remote_lock_release() {
  [[ -n "${REMOTE_LOCK_TOKEN}" ]] || return 0
  local t="${REMOTE_LOCK_TOKEN}"
  REMOTE_LOCK_TOKEN=""
  f5_sh "${R_UNLOCK}" "$t" >/dev/null 2>&1
}

# Both locks: this host's, then the BIG-IP's. Returns 0, 2 (busy) or 1 (error).
job_lock() {
  local rc
  lock_acquire; rc=$?
  if (( rc != 0 )); then return "$rc"; fi
  remote_lock_acquire; rc=$?
  if (( rc != 0 )); then release_all_locks; return "$rc"; fi
  return 0
}

#######################################################################
# Per-job state
#######################################################################
J_DEP="" J_F5="" J_CERT="" J_PREFIX="" J_PART="" J_TS="" J_KEEP=4
J_AUTOROLL=yes J_FIXED=no J_VUNREACH=warn J_VFROM=f5 J_FP="" J_MODE=""
J_RC=0 J_MSG="" J_RESULT="" J_CHANGED=0 J_BDIR_R="" J_BDIR_L=""
declare -a J_PROF=() J_VERIFY=() J_TARGETS=() J_CREATED=()
X_VERSION="" X_PHASE="" X_LASTLOAD="" X_FAILOVER="" X_SYNC="" X_PARTITION=""
declare -A PR_STATE=() PR_INH=() OBJ_FP=() OBJ_EXP=() OBJ_OK=()
declare -a ENT_LIST=()
LAST_TS=""

job_fail() {   # job_fail CODE MESSAGE  (always returns 1)
  J_RC="$1"; J_MSG="$2"
  err "$2"
  return 1
}

norm_name() { printf '%s' "${1#/Common/}"; }

# Names read back from the BIG-IP end up in tmsh command lines and in the generated
# restore script, so they get the same strict treatment as names from the config.
safe_obj() { [[ "$1" =~ ^(/[A-Za-z0-9][A-Za-z0-9._-]*/)?[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
qual() { if [[ "$J_PART" == Common ]]; then printf '%s' "$1"; else printf '/%s/%s' "$J_PART" "$1"; fi; }
profile_fq() {   # qualify a bare profile name with the job's partition
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  if [[ "$J_PART" == Common ]]; then printf '%s' "$1"; else printf '/%s/%s' "$J_PART" "$1"; fi ;;
  esac
}

hex_to_date() { date -u -d "@$1" '+%Y-%m-%d' 2>/dev/null || printf 'unknown'; }   # UTC, like the certificate itself

job_init() {   # job_init DEPLOY F5NAME
  local d="$1" f="$2" sd="deploy:$1" line
  J_DEP="$d"; J_F5="$f"
  J_CERT="${CFG[$sd|cert]}"
  J_PREFIX="$(cert_prefix "$J_CERT")"
  J_KEEP=$(( 10#$(eff keep "$sd" "f5:$f") ))
  J_AUTOROLL="$(eff_bool auto_rollback "$sd")"
  J_FIXED="$(eff_bool fixed_names "$sd")"
  J_VUNREACH="$(eff verify_unreachable "$sd")"
  J_VFROM="$(eff verify_from "$sd")"
  J_RC=0; J_MSG=""; J_RESULT=""; J_CHANGED=0; J_BDIR_R=""; J_BDIR_L=""
  J_PROF=(); J_VERIFY=(); J_TARGETS=(); J_CREATED=()
  while IFS= read -r line; do [[ -n "$line" ]] && J_PROF+=("$line"); done <<<"${CFG[$sd|profile]-}"
  while IFS= read -r line; do [[ -n "$line" ]] && J_VERIFY+=("$line"); done <<<"${CFG[$sd|verify]-}"
  if (( ${#J_PROF[@]} > 0 )); then J_MODE=atomic; else J_MODE=objects; fi
  f5_load "$f"
  J_PART="$F5_PART"
  J_FP="${CERT_FP[$J_CERT]}"
  # Unique, sortable run id; never reuse one within this process.
  # UTC, so names sort chronologically through daylight-saving changes and across
  # time zones (retention relies on the sort order).
  J_TS="$(date -u +%Y%m%d-%H%M%S)"
  if [[ "$J_TS" == "$LAST_TS" ]]; then sleep 1; J_TS="$(date -u +%Y%m%d-%H%M%S)"; fi
  LAST_TS="$J_TS"
  return 0
}

#######################################################################
# Reading the BIG-IP
#######################################################################
job_probe() {
  local -a pn=()
  local sp out rc=0 tag a b c d e f nc nh nk bad=0
  for sp in ${J_PROF[@]+"${J_PROF[@]}"}; do pn+=("$(profile_fq "${sp%%:*}")"); done
  out="$(f5_sh "${R_PROBE}" "${F5_PART}" ${pn[@]+"${pn[@]}"})" || rc=$?
  if (( rc != 0 )); then
    job_fail "${EX_ERR}" "cannot read the BIG-IP (ssh/tmsh failed, rc=${rc}): $(remote_err)"; return 1
  fi
  X_VERSION=""; X_PHASE=""; X_LASTLOAD=""; X_FAILOVER=""; X_SYNC=""; X_PARTITION=""
  PR_STATE=(); PR_INH=(); ENT_LIST=()
  while IFS='|' read -r tag a b c d e f; do
    case "$tag" in
      VERSION)   X_VERSION="$a" ;;
      MCP)       X_PHASE="$a"; X_LASTLOAD="$b" ;;
      FAILOVER)  X_FAILOVER="$a" ;;
      SYNC)      X_SYNC="$a" ;;
      PARTITION) X_PARTITION="$a" ;;
      PROFILE)   PR_STATE[$a]="$b"; PR_INH[$a]="${c:-false}" ;;
      ENTRY)
        nc="$(norm_name "$c")"; nh="$(norm_name "$d")"; nk="$(norm_name "$e")"
        if safe_obj "$a" && safe_obj "$b" && safe_obj "$nc" && safe_obj "$nh" && safe_obj "$nk"; then
          ENT_LIST+=("${a}|${b}|${nc}|${nh}|${nk}|${f}")
        else
          bad=1
        fi ;;
    esac
  done <<<"$out"
  if (( bad )); then
    job_fail "${EX_ERR}" "the BIG-IP returned a profile, entry or object name containing unexpected characters; refusing to continue (only letters, digits, . _ - and /Partition/ prefixes are accepted)"
    return 1
  fi
  return 0
}

job_gate() {
  if [[ -z "$X_VERSION" ]]; then job_fail "${EX_ERR}" "the BIG-IP did not return a version; is tmsh available to ${F5_USER}?"; return 1; fi
  if [[ "$X_PHASE" != running || "$X_LASTLOAD" != full-config-load-succeed ]]; then
    job_fail "${EX_ERR}" "the BIG-IP configuration is not fully loaded (phase '${X_PHASE}', last load '${X_LASTLOAD}'); refusing to change it"; return 1
  fi
  if [[ "$X_FAILOVER" != active ]]; then
    if [[ "$X_FAILOVER" == standby && "$(eff_bool allow_standby "f5:${J_F5}")" == yes ]]; then
      warn "this BIG-IP is STANDBY; proceeding because allow_standby = yes"
    else
      job_fail "${EX_ERR}" "this BIG-IP is '${X_FAILOVER:-unknown}', not active; deploy to the active unit (or set allow_standby = yes)"; return 1
    fi
  fi
  if [[ "$X_PARTITION" != OK ]]; then job_fail "${EX_ERR}" "partition '${F5_PART}' does not exist on the BIG-IP"; return 1; fi
  return 0
}

# Decide which cert-key-chain entry of each configured profile to update.
job_select_targets() {
  local sp p e ent en pick c h k pp rx cnt stem
  J_TARGETS=()
  for sp in ${J_PROF[@]+"${J_PROF[@]}"}; do
    p="$(profile_fq "${sp%%:*}")"; e=""
    if [[ "$sp" == *:* ]]; then e="${sp#*:}"; fi
    if [[ "${PR_STATE[$p]:-}" != OK ]]; then job_fail "${EX_ERR}" "profile '${p}' does not exist on the BIG-IP"; return 1; fi
    if [[ "${PR_INH[$p]:-false}" != false ]]; then
      job_fail "${EX_ERR}" "profile '${p}' inherits its certificate from its parent profile (inherit-certkeychain true); update the parent, or set inherit-certkeychain false on this profile"; return 1
    fi
    local -a ents=()
    for ent in ${ENT_LIST[@]+"${ENT_LIST[@]}"}; do
      if [[ "${ent%%|*}" == "$p" ]]; then ents+=("$ent"); fi
    done
    pick=""
    if [[ -n "$e" ]]; then
      for ent in ${ents[@]+"${ents[@]}"}; do
        IFS='|' read -r _ en _ <<<"$ent"
        if [[ "$en" == "$e" ]]; then pick="$ent"; fi
      done
      if [[ -z "$pick" ]]; then job_fail "${EX_ERR}" "profile '${p}' has no cert-key-chain entry named '${e}'"; return 1; fi
    elif (( ${#ents[@]} == 1 )); then
      pick="${ents[0]}"
    elif (( ${#ents[@]} == 0 )); then
      job_fail "${EX_ERR}" "profile '${p}' has no cert-key-chain entry to update; create one first"; return 1
    else
      rx="^${J_PREFIX//./\\.}-cert(-[0-9]{8}-[0-9]{6})?\\.pem\$"
      cnt=0
      for ent in "${ents[@]}"; do
        IFS='|' read -r _ en c _ <<<"$ent"
        stem="${c##*/}"
        if [[ "$stem" =~ $rx ]]; then pick="$ent"; cnt=$((cnt + 1)); fi
      done
      if (( cnt != 1 )); then
        job_fail "${EX_ERR}" "profile '${p}' has ${#ents[@]} cert-key-chain entries and ${cnt} of them match this certificate; name the entry explicitly: profile = ${sp%%:*}:ENTRYNAME"; return 1
      fi
    fi
    IFS='|' read -r _ en c h k pp <<<"$pick"
    if [[ -n "$pp" && "$pp" != none ]]; then
      job_fail "${EX_ERR}" "entry '${en}' of profile '${p}' has a key passphrase set; passphrase-protected keys are not supported"; return 1
    fi
    J_TARGETS+=("${p}|${en}|${c}|${h}|${k}")
  done
  return 0
}

fixed_cert_obj() { qual "${J_PREFIX}-cert.pem"; }
fixed_key_obj()  { qual "${J_PREFIX}-privkey.pem"; }
fixed_chain_obj() { qual "${J_PREFIX}-chain.pem"; }
fixed_full_obj()  { qual "${J_PREFIX}-fullchain.pem"; }

# Fingerprint/expiry for the certificates the plan depends on.
job_objinfo() {
  local -a specs=()
  local t c h k out rc=0 tag a b cc d e
  OBJ_FP=(); OBJ_EXP=(); OBJ_OK=()
  for t in ${J_TARGETS[@]+"${J_TARGETS[@]}"}; do
    IFS='|' read -r _ _ c h k <<<"$t"
    specs+=("cert:${c}" "key:${k}")
    if [[ "$h" != none ]]; then specs+=("cert:${h}"); fi
  done
  if [[ "$J_MODE" == objects || "$J_FIXED" == yes ]]; then
    specs+=("cert:$(fixed_cert_obj)" "key:$(fixed_key_obj)" "cert:$(fixed_chain_obj)" "cert:$(fixed_full_obj)")
  fi
  if (( ${#specs[@]} == 0 )); then return 0; fi
  out="$(f5_sh "${R_OBJINFO}" "${specs[@]}")" || rc=$?
  if (( rc != 0 )); then job_fail "${EX_ERR}" "cannot read certificate objects on the BIG-IP: $(remote_err)"; return 1; fi
  while IFS='|' read -r tag a b cc d e; do
    [[ "$tag" == OBJ ]] || continue
    # OBJ|kind|name|OK|fp|expiry   or   OBJ|kind|name|MISSING
    if [[ "$cc" == OK ]]; then
      OBJ_OK["${a}:${b}"]=1
      if [[ "$a" == cert ]]; then OBJ_FP["$b"]="$d"; OBJ_EXP["$b"]="$e"; fi
    fi
  done <<<"$out"
  return 0
}

job_is_current() {
  local t c
  if (( ${#J_TARGETS[@]} > 0 )); then
    for t in "${J_TARGETS[@]}"; do
      IFS='|' read -r _ _ c _ <<<"$t"
      [[ "${OBJ_FP[$c]:-}" == "$J_FP" ]] || return 1
    done
    return 0
  fi
  [[ "${OBJ_FP[$(fixed_cert_obj)]:-}" == "$J_FP" && -n "${OBJ_OK[key:$(fixed_key_obj)]+x}" ]]
}

job_report_state() {
  local t p e c h k fp state
  if (( ${#J_TARGETS[@]} > 0 )); then
    for t in "${J_TARGETS[@]}"; do
      IFS='|' read -r p e c h k <<<"$t"
      fp="${OBJ_FP[$c]:-}"
      if [[ "$fp" == "$J_FP" ]]; then state="up to date"; else state="OUT OF DATE"; fi
      info "${p} / ${e}: uses ${c}, expires $(hex_to_date "${OBJ_EXP[$c]:-0}"), ${state}"
    done
  else
    c="$(fixed_cert_obj)"
    fp="${OBJ_FP[$c]:-}"
    if [[ -z "$fp" ]]; then state="not installed"; elif [[ "$fp" == "$J_FP" ]]; then state="up to date"; else state="OUT OF DATE"; fi
    info "object ${c}: ${state}"
  fi
}

#######################################################################
# Changing the BIG-IP
#######################################################################
job_backup() {
  local root="${F5_BACKUP_ROOT}/${J_PREFIX}" out rc=0 tag a b line
  local -a specs=() files=()
  local t p e c h k seen=" "

  specs+=("meta:tool=${PROG} ${VERSION}" "meta:run=${J_TS}" "meta:deployment=${J_DEP}" "meta:bigip=${F5_NAME}"
          "meta:new_sha256=${J_FP}" "meta:cert=${J_CERT}")
  for t in ${J_TARGETS[@]+"${J_TARGETS[@]}"}; do
    IFS='|' read -r p e c h k <<<"$t"
    if [[ "$seen" != *" key:${k} "* ]]; then specs+=("keep-key:${k}"); seen+="key:${k} "; fi
    if [[ "$seen" != *" cert:${c} "* ]]; then specs+=("keep-cert:${c}"); seen+="cert:${c} "; fi
    if [[ "$h" != none && "$seen" != *" cert:${h} "* ]]; then specs+=("keep-cert:${h}"); seen+="cert:${h} "; fi
  done
  if [[ "$J_MODE" == objects || "$J_FIXED" == yes ]]; then
    if [[ -n "${OBJ_OK[key:$(fixed_key_obj)]+x}" ]]; then specs+=("fix-key:$(fixed_key_obj)"); fi
    for c in "$(fixed_cert_obj)" "$(fixed_chain_obj)" "$(fixed_full_obj)"; do
      if [[ -n "${OBJ_OK[cert:${c}]+x}" ]]; then specs+=("fix-cert:${c}"); fi
    done
  fi
  for t in ${J_TARGETS[@]+"${J_TARGETS[@]}"}; do specs+=("bind:${t//|/:}"); done

  info "backing up current state to ${F5_HOST}:${root}/${J_TS}/ and ${J_BDIR_L}/"
  out="$(f5_sh "${R_LIB}"$'\n'"${R_BACKUP}" "${root}/${J_TS}" "${J_TS}" "${specs[@]}")" || rc=$?
  J_BDIR_R="${root}/${J_TS}"
  while IFS='|' read -r tag a b; do
    case "$tag" in
      FILE) files+=("$a") ;;
      NOTE) info "backup: ${a}" ;;
      ERR)  job_fail "${EX_ERR}" "backup failed on the BIG-IP: ${a}"; return 1 ;;
    esac
  done <<<"$out"
  if (( rc != 0 )); then job_fail "${EX_ERR}" "backup failed on the BIG-IP (rc=${rc}): $(remote_err)"; return 1; fi
  if (( ${#files[@]} == 0 )); then job_fail "${EX_ERR}" "backup produced no files"; return 1; fi

  mkdir -p -- "${J_BDIR_L}" || { job_fail "${EX_ERR}" "cannot create ${J_BDIR_L}"; return 1; }
  chmod 700 -- "${J_BDIR_L}" 2>/dev/null || true
  for line in "${files[@]}"; do
    if [[ ! "$line" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then job_fail "${EX_ERR}" "backup returned an unsafe file name"; return 1; fi
    if ! f5_get "${J_BDIR_R}/${line}" "${J_BDIR_L}/${line}"; then
      job_fail "${EX_ERR}" "cannot copy ${line} from the BIG-IP: $(remote_err)"; return 1
    fi
    chmod 600 -- "${J_BDIR_L}/${line}" 2>/dev/null || true
  done
  if [[ -s "${J_BDIR_L}/SHA256SUMS" ]]; then
    if ! ( cd "${J_BDIR_L}" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1 ); then
      job_fail "${EX_ERR}" "the local copy of the backup does not match its checksums; nothing was changed on the BIG-IP"; return 1
    fi
  fi
  ok "backup verified: ${#files[@]} file(s), checksums match, restore script included"
  return 0
}

job_stage() {
  local out rc=0 tag a b f local_sum
  local -a up=(key.pem cert.pem)
  local -A want=() got=()
  local d="${CERT_DIR[$J_CERT]}"

  out="$(f5_sh "${R_STAGE}")" || rc=$?
  if (( rc != 0 )); then job_fail "${EX_ERR}" "cannot create a staging directory on the BIG-IP: $(remote_err)"; return 1; fi
  while IFS='|' read -r tag a; do [[ "$tag" == STAGE ]] && STAGE_DIR="$a"; done <<<"$out"
  if [[ ! "$STAGE_DIR" =~ ^/var/tmp/f5-cert-push\.[A-Za-z0-9]{6,12}$ ]]; then
    STAGE_DIR=""; job_fail "${EX_ERR}" "the BIG-IP returned an unexpected staging path"; return 1
  fi
  if [[ "${CERT_HAVE_CHAIN[$J_CERT]}" == 1 ]]; then up+=(chain.pem); fi
  if [[ ( "$J_MODE" == objects || "$J_FIXED" == yes ) && "${CERT_HAVE_FULL[$J_CERT]}" == 1 ]]; then up+=(fullchain.pem); fi

  for f in "${up[@]}"; do
    if ! f5_put "${d}/${f}" "${STAGE_DIR}/${f}"; then
      job_fail "${EX_ERR}" "cannot upload ${f} to the BIG-IP: $(remote_err)"; return 1
    fi
    local_sum="$(sha256sum -- "${d}/${f}" | awk '{print $1}')"
    want[$f]="$local_sum"
  done
  rc=0
  out="$(f5_sh "${R_STAGE_CHECK}" "${STAGE_DIR}" "${up[@]}")" || rc=$?
  if (( rc != 0 )); then job_fail "${EX_ERR}" "cannot verify the staged files: $(remote_err)"; return 1; fi
  while IFS='|' read -r tag a b; do
    if [[ "$tag" == SUM ]]; then got[$a]="$b"; fi
  done <<<"$out"
  for f in "${up[@]}"; do
    if [[ "${got[$f]:-}" != "${want[$f]}" ]]; then
      job_fail "${EX_ERR}" "the uploaded ${f} does not match the local copy (transfer corrupted); nothing was changed"; return 1
    fi
  done
  ok "uploaded and verified ${#up[@]} file(s) on the BIG-IP"
  return 0
}

# Parse CREATED|kind|name lines into J_CREATED.
collect_created() {
  local tag a b
  while IFS='|' read -r tag a b; do
    if [[ "$tag" == CREATED ]]; then J_CREATED+=("${a}:${b}"); fi
  done <<<"$1"
}

# Remove objects this run created. Best effort; the BIG-IP refuses to delete any
# object a profile still references.
job_remove_created() {
  (( ${#J_CREATED[@]} > 0 )) || return 0
  local out rc=0
  out="$(f5_sh "${R_LIB}"$'\n'"${R_DELETE}" "${J_CREATED[@]}")" || rc=$?
  if (( rc != 0 )); then warn "could not remove the objects created by this run: $(remote_err)"; return 1; fi
  info "removed ${#J_CREATED[@]} object(s) created by this run"
  J_CREATED=()
  return 0
}

job_install_versioned() {
  local out rc=0 tag a b
  local v_key v_cert v_chain
  v_key="$(qual "${J_PREFIX}-privkey-${J_TS}.pem")"
  v_cert="$(qual "${J_PREFIX}-cert-${J_TS}.pem")"
  v_chain="$(qual "${J_PREFIX}-chain-${J_TS}.pem")"
  local -a specs=("new-key:${v_key}:key.pem" "new-cert:${v_cert}:cert.pem")
  if [[ "${CERT_HAVE_CHAIN[$J_CERT]}" == 1 ]]; then specs+=("new-cert:${v_chain}:chain.pem"); fi
  out="$(f5_sh "${R_LIB}"$'\n'"${R_INSTALL}" "${STAGE_DIR}" "${specs[@]}")" || rc=$?
  collect_created "$out"
  while IFS='|' read -r tag a b; do
    if [[ "$tag" == FAIL ]]; then
      job_fail "${EX_ERR}" "installing the new certificate failed: ${a}. The profiles were not touched."
      job_remove_created || true
      return 1
    fi
  done <<<"$out"
  if (( rc != 0 )); then
    job_fail "${EX_ERR}" "installing the new certificate failed (rc=${rc}): $(remote_err). The profiles were not touched."
    job_remove_created || true
    return 1
  fi
  ok "installed ${#specs[@]} new object(s): ${v_cert##*/} and its key$( [[ "${CERT_HAVE_CHAIN[$J_CERT]}" == 1 ]] && printf ' and chain')"
  return 0
}

job_install_fixed() {   # overwrite the fixed-name objects in place
  local out rc=0 tag a b
  local -a specs=("set-key:$(fixed_key_obj):key.pem" "set-cert:$(fixed_cert_obj):cert.pem")
  if [[ "${CERT_HAVE_CHAIN[$J_CERT]}" == 1 ]]; then specs+=("set-cert:$(fixed_chain_obj):chain.pem"); fi
  if [[ "${CERT_HAVE_FULL[$J_CERT]}" == 1 ]]; then specs+=("set-cert:$(fixed_full_obj):fullchain.pem"); fi
  out="$(f5_sh "${R_LIB}"$'\n'"${R_INSTALL}" "${STAGE_DIR}" "${specs[@]}")" || rc=$?
  while IFS='|' read -r tag a b; do
    if [[ "$tag" == FAIL ]]; then job_fail "${EX_ERR}" "updating the fixed-name objects failed: ${a}"; return 1; fi
  done <<<"$out"
  if (( rc != 0 )); then job_fail "${EX_ERR}" "updating the fixed-name objects failed (rc=${rc}): $(remote_err)"; return 1; fi
  ok "updated ${#specs[@]} fixed-name object(s)"
  return 0
}

# One transaction repointing every target entry to the new objects.
job_switch_profiles() {
  local t p e c h k out rc=0 tag a b
  local v_key v_cert v_chain
  v_key="$(qual "${J_PREFIX}-privkey-${J_TS}.pem")"
  v_cert="$(qual "${J_PREFIX}-cert-${J_TS}.pem")"
  v_chain="none"
  if [[ "${CERT_HAVE_CHAIN[$J_CERT]}" == 1 ]]; then v_chain="$(qual "${J_PREFIX}-chain-${J_TS}.pem")"; fi
  local -a specs=()
  for t in "${J_TARGETS[@]}"; do
    IFS='|' read -r p e _ _ _ <<<"$t"
    specs+=("bind:${p}:${e}:${v_cert}:${v_chain}:${v_key}")
  done
  info "switching ${#specs[@]} profile entr$( (( ${#specs[@]} == 1 )) && printf 'y' || printf 'ies') in a single transaction"
  out="$(f5_sh "${R_LIB}"$'\n'"${R_TXN}" "${specs[@]}")" || rc=$?
  local txn="" txnout=""
  while IFS='|' read -r tag a b; do
    case "$tag" in
      TXN) txn="$a" ;;
      TXNOUT) txnout="$a" ;;
      SAVE) txn="SAVEFAILED" ;;
    esac
  done <<<"$out"
  if [[ "$txn" == OK ]]; then
    J_CHANGED=1
    ok "profiles switched; configuration saved"
    return 0
  fi
  if [[ "$txn" == SAVEFAILED ]]; then
    # The running configuration changed but could not be saved.
    J_CHANGED=1
    job_fail "${EX_ERR}" "the profiles were switched but 'tmsh save sys config' failed, so the change would not survive a restart"
    return 1
  fi
  job_fail "${EX_ERR}" "the tmsh transaction failed, so no profile was changed (tmsh transactions are all-or-nothing). ${txnout:+BIG-IP said: ${txnout}}"
  job_remove_created || true
  return 1
}

# Re-read the profiles and confirm each target entry uses exactly what we set.
job_verify_bindings() {
  local t p e v_key v_cert v_chain ent en c h k ok_all=1 found
  v_key="$(qual "${J_PREFIX}-privkey-${J_TS}.pem")"
  v_cert="$(qual "${J_PREFIX}-cert-${J_TS}.pem")"
  v_chain="none"
  if [[ "${CERT_HAVE_CHAIN[$J_CERT]}" == 1 ]]; then v_chain="$(qual "${J_PREFIX}-chain-${J_TS}.pem")"; fi
  v_key="$(norm_name "$v_key")"; v_cert="$(norm_name "$v_cert")"; v_chain="$(norm_name "$v_chain")"
  job_probe || return 1
  for t in "${J_TARGETS[@]}"; do
    IFS='|' read -r p e _ _ _ <<<"$t"
    found=0
    for ent in ${ENT_LIST[@]+"${ENT_LIST[@]}"}; do
      IFS='|' read -r ep en c h k _ <<<"$ent"
      if [[ "$ep" == "$p" && "$en" == "$e" ]]; then
        found=1
        if [[ "$c" != "$v_cert" || "$h" != "$v_chain" || "$k" != "$v_key" ]]; then ok_all=0; fi
      fi
    done
    if (( found == 0 )); then ok_all=0; fi
  done
  (( ok_all == 1 ))
}

# Returns 0 when every endpoint serves the new certificate; 1 on a mismatch (or
# on no answer when verify_unreachable = fail); warnings otherwise.
job_verify_endpoints() {
  local ep hp sni host port attempt fp depth out tag a b rc status=0
  (( ${#J_VERIFY[@]} > 0 )) || return 0
  for ep in "${J_VERIFY[@]}"; do
    hp="${ep%%[[:space:]]*}"; sni=""
    if [[ "$ep" == *[[:space:]]* ]]; then sni="${ep##*[[:space:]]}"; fi
    if [[ -z "$sni" ]]; then sni="${CERT_SNI[$J_CERT]}"; fi
    host="${hp%:*}"; port="${hp##*:}"
    fp=""; depth=0
    for attempt in 1 2 3; do
      fp=""; depth=0; rc=0
      if [[ "$J_VFROM" == local ]]; then
        out="$(endpoint_local "$host" "$port" "$sni")" || rc=$?
      else
        out="$(f5_sh "${R_ENDPOINT}" "$host" "$port" "$sni")" || rc=$?
      fi
      while IFS='|' read -r tag a b; do
        if [[ "$tag" == ENDPOINT ]]; then fp="$a"; depth="${b:-0}"; fi
      done <<<"$out"
      if [[ "$fp" == "$J_FP" ]]; then break; fi
      sleep 3
    done
    if [[ -z "$fp" ]]; then
      if [[ "$J_VUNREACH" == fail ]]; then err "endpoint ${hp}: no TLS handshake (verify_unreachable = fail)"; status=1
      else warn "endpoint ${hp}: no TLS handshake; could not confirm it serves the new certificate"; fi
    elif [[ "$fp" != "$J_FP" ]]; then
      err "endpoint ${hp}${sni:+ (SNI ${sni})} serves sha256 ${fp:0:16}..., expected ${J_FP:0:16}..."
      status=1
    else
      ok "endpoint ${hp}${sni:+ (SNI ${sni})} serves the new certificate (${depth} certificate(s) in the chain, checked from ${J_VFROM})"
      if [[ "${CERT_HAVE_CHAIN[$J_CERT]}" == 1 ]] && (( depth < 2 )); then
        warn "endpoint ${hp} sent only ${depth} certificate; the chain may not be reaching clients"
      fi
    fi
  done
  return "$status"
}

endpoint_local() {   # endpoint_local HOST PORT SNI -> ENDPOINT|fp|depth
  local host="$1" port="$2" sni="$3" pem depth fp
  local -a args=(-connect "${host}:${port}" -showcerts)
  if [[ -n "$sni" ]]; then args+=(-servername "$sni"); fi
  pem="$(timeout 15 openssl s_client "${args[@]}" </dev/null 2>/dev/null)" || true
  depth="$(printf '%s\n' "$pem" | grep -c 'BEGIN CERTIFICATE')" || depth=0
  fp="$(printf '%s\n' "$pem" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2- | tr -d ':')" || fp=""
  printf 'ENDPOINT|%s|%s\n' "$fp" "$depth"
}

# Restore the state captured before this run. Returns 0 only if the BIG-IP is
# confirmed to be back on its previous configuration.
job_rollback() {
  local reason="$1" out rc=0 ok_all=1 t p e c h k ent ep en ec eh ek
  warn "ROLLING BACK: ${reason}"
  if [[ -z "$J_BDIR_R" ]]; then err "no backup exists to roll back to"; return 1; fi
  out="$(f5_sh "${R_RESTORE}" "${J_BDIR_R}" "${J_TS}")" || rc=$?
  if (( rc != 0 )); then
    err "the restore script failed (rc=${rc}): $(remote_err)"
    printf '%s\n' "$out" | sanitize | head -20 >&2
    return 1
  fi
  job_probe || return 1
  for t in ${J_TARGETS[@]+"${J_TARGETS[@]}"}; do
    IFS='|' read -r p e c h k <<<"$t"
    for ent in ${ENT_LIST[@]+"${ENT_LIST[@]}"}; do
      IFS='|' read -r ep en ec eh ek _ <<<"$ent"
      if [[ "$ep" == "$p" && "$en" == "$e" ]]; then
        if [[ "$ec" != "$c" || "$eh" != "$h" || "$ek" != "$k" ]]; then ok_all=0; fi
      fi
    done
  done
  if (( ok_all == 0 )); then err "after the restore, the profiles do not match their previous bindings"; return 1; fi
  ok "rollback complete: profiles are back on their previous certificate"
  J_CHANGED=0
  return 0
}

job_prune() {
  (( J_KEEP > 0 )) || return 0
  local out tag a b n=0 root="${F5_BACKUP_ROOT}/${J_PREFIX}" d
  info "pruning to the newest ${J_KEEP} backup set(s) and certificate version(s)"
  if out="$(f5_sh "${R_PRUNE_BACKUPS}" "$root" "${J_KEEP}")"; then
    while IFS='|' read -r tag a b; do
      if [[ "$tag" == REMOVED ]]; then n=$((n + 1)); fi
    done <<<"$out"
    if (( n > 0 )); then info "removed ${n} old backup set(s) from the BIG-IP"; fi
  else
    warn "pruning backups on the BIG-IP failed: $(remote_err)"
  fi
  n=0
  if [[ -d "${F5_BACKUP_LOCAL}" ]]; then
    while IFS= read -r d; do
      [[ "$d" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
      rm -rf -- "${F5_BACKUP_LOCAL:?}/${d}"; n=$((n + 1))
    done < <(ls -1 "${F5_BACKUP_LOCAL}" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort | head -n -"${J_KEEP}")
    if (( n > 0 )); then info "removed ${n} old local backup set(s)"; fi
  fi
  if [[ "$J_MODE" == atomic ]]; then
    n=0
    if out="$(f5_sh "${R_LIB}"$'\n'"${R_PRUNE_OBJECTS}" "${F5_PART}" "${J_PREFIX}" "${J_KEEP}")"; then
      while IFS='|' read -r tag a b; do
        if [[ "$tag" == DELETED ]]; then n=$((n + 1)); fi
      done <<<"$out"
      if (( n > 0 )); then info "removed ${n} old certificate object(s) from the BIG-IP"; fi
    else
      warn "pruning old certificate objects failed: $(remote_err)"
    fi
  fi
  return 0
}

#######################################################################
# Running one deployment on one BIG-IP
#######################################################################
job_unstage() {
  if [[ -n "${STAGE_DIR}" ]]; then
    remote_remove_stage || warn "could not remove the staging directory ${STAGE_DIR} on the BIG-IP; remove it by hand"
  fi
}

remote_remove_stage() {
  local d="${STAGE_DIR}"
  if [[ ! "$d" =~ ^/var/tmp/f5-cert-push\.[A-Za-z0-9]{6,12}$ ]]; then STAGE_DIR=""; return 0; fi
  # shellcheck disable=SC2016
  f5_sh 'case "$1" in /var/tmp/f5-cert-push.*) find "$1" -type f -exec shred -u -- {} + 2>/dev/null; rm -rf -- "$1" ;; esac' "$d" >/dev/null 2>&1 || return 1
  STAGE_DIR=""
  return 0
}

# A step failed after the BIG-IP may have been changed: roll back if allowed.
job_handle_failure() {   # job_handle_failure REASON
  local reason="$1"
  if (( J_CHANGED == 0 )); then
    J_RESULT=FAILED
    return 0
  fi
  if [[ "$J_AUTOROLL" == yes ]]; then
    if job_rollback "$reason"; then
      job_remove_created || true
      J_RC="${EX_ROLLED_BACK}"; J_RESULT=ROLLED_BACK
      J_MSG="${reason}; rolled back to the previous certificate"
      return 0
    fi
    J_RC="${EX_CRITICAL}"; J_RESULT=CRITICAL
    J_MSG="${reason}; AND THE ROLLBACK FAILED. Restore by hand: ssh ${F5_USER}@${F5_HOST} bash ${J_BDIR_R}/restore-${J_TS}.sh"
    err "${J_MSG}"
    return 0
  fi
  J_RC="${EX_ERR}"; J_RESULT=FAILED_CHANGED
  J_MSG="${reason}; auto_rollback is off, so the BIG-IP is still on the new certificate. Roll back with: ${PROG} --config ${CONFIG_FILE} --deploy ${J_DEP} --f5 ${J_F5} --rollback --set ${J_TS}"
  err "${J_MSG}"
  return 0
}

job_print_plan() {
  local t p e
  info "DRY RUN: a deploy would now:"
  info "  1. back up the current objects to ${F5_HOST}:${F5_BACKUP_ROOT}/${J_PREFIX}/${J_TS}/ and ${F5_BACKUP_LOCAL}/${J_TS}/"
  if [[ "$J_MODE" == atomic ]]; then
    info "  2. install ${J_PREFIX}-cert-${J_TS}.pem, ${J_PREFIX}-privkey-${J_TS}.pem$( [[ "${CERT_HAVE_CHAIN[$J_CERT]}" == 1 ]] && printf ', %s-chain-%s.pem' "$J_PREFIX" "$J_TS")"
    for t in "${J_TARGETS[@]}"; do IFS='|' read -r p e _ <<<"$t"; info "  3. repoint ${p} / ${e}"; done
    info "     (all in one transaction, then: tmsh save sys config)"
    if [[ "$J_FIXED" == yes ]]; then info "  4. refresh the fixed-name objects ${J_PREFIX}-{cert,chain,fullchain,privkey}.pem"; fi
  else
    info "  2. overwrite ${J_PREFIX}-{cert,chain,fullchain,privkey}.pem in place (no profiles configured)"
  fi
  if (( ${#J_VERIFY[@]} > 0 )); then info "  then verify: ${J_VERIFY[*]} (from ${J_VFROM}); roll back automatically on a mismatch: ${J_AUTOROLL}"; fi
  if (( J_KEEP > 0 )); then info "  finally prune to the newest ${J_KEEP} backup set(s) and certificate version(s)"; fi
}

run_job() {   # run_job DEPLOY F5NAME   -> sets J_RESULT, J_RC, J_MSG
  local dep="$1" f5="$2" rc readonly_run=0
  JOB_TAG="${dep}@${f5}"
  if ! prepare_cert "${CFG[deploy:${dep}|cert]}"; then
    J_RC="${EX_ERR}"; J_RESULT=FAILED; J_MSG="certificate '${CFG[deploy:${dep}|cert]}' failed validation"
    return 0
  fi
  job_init "$dep" "$f5"
  F5_BACKUP_ROOT="$(eff backup_dir_remote "deploy:${dep}" "f5:${f5}")"
  F5_BACKUP_LOCAL="$(eff backup_dir_local)/${f5}/${J_PREFIX}"
  J_BDIR_L="${F5_BACKUP_LOCAL}/${J_TS}"
  if (( DRY_RUN || CHECK_ONLY )); then readonly_run=1; fi

  if [[ -n "$F5_KEY" && ! -r "$F5_KEY" ]]; then
    job_fail "${EX_ERR}" "ssh key is not readable: ${F5_KEY}"; J_RESULT=FAILED; return 0
  fi

  if (( ! readonly_run )); then
    job_lock; rc=$?
    if (( rc == 2 )); then
      J_RC="${EX_LOCKED}"; J_RESULT=LOCKED; J_MSG="another run holds the lock for ${F5_HOST}"
      warn "${J_MSG}"; return 0
    elif (( rc != 0 )); then
      J_RC="${EX_ERR}"; J_RESULT=FAILED; J_MSG="cannot take the per-BIG-IP lock"; return 0
    fi
  fi

  info "connecting to ${F5_USER}@${F5_HOST} (partition ${F5_PART}); mode: ${J_MODE}"
  if ! { job_probe && job_gate && job_select_targets && job_objinfo; }; then
    J_RESULT=FAILED; lock_release; return 0
  fi
  ok "BIG-IP ${X_VERSION}, ${X_FAILOVER}, sync mode ${X_SYNC:-unknown}, configuration loaded"
  job_report_state

  if job_is_current && (( ! FORCE )); then
    J_RESULT=UPTODATE; J_MSG="already serving this certificate"
    ok "nothing to do: the BIG-IP already has this certificate (use --force to redeploy)"
    lock_release; return 0
  fi
  if (( CHECK_ONLY )); then
    J_RESULT=OUTDATED; J_RC="${EX_OUTDATED}"; J_MSG="out of date"
    warn "out of date: the BIG-IP does not have the current certificate"
    return 0
  fi
  if (( DRY_RUN )); then
    job_print_plan; J_RESULT=DRYRUN; J_MSG="dry run"; return 0
  fi

  # ---- apply --------------------------------------------------------
  if ! job_backup; then J_RESULT=FAILED; job_unstage; lock_release; return 0; fi
  if ! job_stage;  then J_RESULT=FAILED; job_unstage; lock_release; return 0; fi

  if [[ "$J_MODE" == atomic ]]; then
    if ! job_install_versioned; then J_RESULT=FAILED; job_unstage; lock_release; return 0; fi
    if ! job_switch_profiles; then
      job_handle_failure "switching the profiles failed"
      job_unstage; lock_release; return 0
    fi
    if ! job_verify_bindings; then
      job_handle_failure "the profiles do not reference the new objects after the switch"
      job_unstage; lock_release; return 0
    fi
    ok "verified: every target entry uses the new certificate, chain and key"
    if ! job_verify_endpoints; then
      job_handle_failure "a verification endpoint is not serving the new certificate"
      job_unstage; lock_release; return 0
    fi
    if [[ "$J_FIXED" == yes ]]; then
      job_install_fixed || warn "the fixed-name objects could not be refreshed; the profiles are unaffected"
    fi
  else
    J_CHANGED=1
    if ! job_install_fixed; then
      job_handle_failure "overwriting the certificate objects failed"
      job_unstage; lock_release; return 0
    fi
    job_objinfo || true
    if [[ "${OBJ_FP[$(fixed_cert_obj)]:-}" != "$J_FP" ]]; then
      job_handle_failure "the installed certificate object does not match"
      job_unstage; lock_release; return 0
    fi
    ok "verified: $(fixed_cert_obj) now holds the new certificate"
    if ! job_verify_endpoints; then
      job_handle_failure "a verification endpoint is not serving the new certificate"
      job_unstage; lock_release; return 0
    fi
  fi

  job_unstage
  job_prune
  if [[ "$X_SYNC" != standalone && -n "$X_SYNC" ]]; then
    warn "this BIG-IP is in a sync group (mode ${X_SYNC}); synchronise the configuration to its peers"
  fi
  J_RESULT=UPDATED; J_RC="${EX_OK}"; J_MSG="deployed; expires ${CERT_END[$J_CERT]}"
  ok "done; rollback with: ssh ${F5_USER}@${F5_HOST} bash ${J_BDIR_R}/restore-${J_TS}.sh"
  lock_release
  return 0
}

#######################################################################
# Job selection
#######################################################################
declare -a JOBS=()

in_list() {   # in_list NEEDLE LIST...
  local n="$1" x; shift
  for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done
  return 1
}

select_jobs() {
  local d f5n match cert le lin sel
  JOBS=()
  for d in ${SEL_DEPLOY[@]+"${SEL_DEPLOY[@]}"}; do
    [[ -n "${SECT_SEEN[deploy:${d}]+x}" ]] || usage_die "no such deployment: ${d}"
  done
  for f5n in ${SEL_F5[@]+"${SEL_F5[@]}"}; do
    [[ -n "${SECT_SEEN[f5:${f5n}]+x}" ]] || usage_die "no such BIG-IP: ${f5n}"
  done
  for d in ${DEPLOYS[@]+"${DEPLOYS[@]}"}; do
    match=0
    if (( SEL_ALL )); then match=1; fi
    if in_list "$d" ${SEL_DEPLOY[@]+"${SEL_DEPLOY[@]}"}; then match=1; fi
    if (( ${#SEL_ENV[@]} > 0 )) && in_list "${CFG[deploy:${d}|env]-}" "${SEL_ENV[@]}"; then match=1; fi
    cert="${CFG[deploy:${d}|cert]-}"
    le="${CFG[cert:${cert}|le_dir]-}"; le="${le%/}"
    for lin in ${SEL_LINEAGE[@]+"${SEL_LINEAGE[@]}"}; do
      lin="${lin%/}"
      if [[ -n "$le" && "$le" == "$lin" ]]; then match=1; fi
    done
    (( match )) || continue
    if [[ "$(eff_bool enabled "deploy:${d}")" != yes ]]; then
      if in_list "$d" ${SEL_DEPLOY[@]+"${SEL_DEPLOY[@]}"}; then warn "deployment '${d}' is disabled (enabled = no); skipping"; fi
      continue
    fi
    for f5n in $(deploy_f5s "$d"); do
      if (( ${#SEL_F5[@]} > 0 )) && ! in_list "$f5n" "${SEL_F5[@]}"; then continue; fi
      JOBS+=("${d}|${f5n}")
    done
  done
}

#######################################################################
# Actions
#######################################################################
declare -a RES_JOB=() RES_RESULT=() RES_RC=() RES_MSG=()

record_result() {   # record_result JOB
  RES_JOB+=("$1"); RES_RESULT+=("${J_RESULT:-FAILED}"); RES_RC+=("${J_RC}"); RES_MSG+=("${J_MSG}")
}

overall_exit() {
  local rc has5=0 has3=0 has1=0 has6=0 has4=0
  for rc in ${RES_RC[@]+"${RES_RC[@]}"}; do
    case "$rc" in
      5) has5=1 ;; 3) has3=1 ;; 1) has1=1 ;; 6) has6=1 ;; 4) has4=1 ;;
    esac
  done
  if (( has5 )); then return "${EX_CRITICAL}"; fi
  if (( has3 )); then return "${EX_ROLLED_BACK}"; fi
  if (( has1 )); then return "${EX_ERR}"; fi
  if (( has6 )); then return "${EX_LOCKED}"; fi
  if (( has4 )); then return "${EX_OUTDATED}"; fi
  return 0
}

print_summary() {
  local i
  (( ${#RES_JOB[@]} > 0 )) || return 0
  echo
  echo "==================== SUMMARY ===================="
  printf '  %-34s %-14s %s\n' "DEPLOYMENT@BIG-IP" "RESULT" "DETAIL"
  for i in "${!RES_JOB[@]}"; do
    printf '  %-34s %-14s %s\n' "${RES_JOB[$i]}" "${RES_RESULT[$i]}" "$(printf '%s' "${RES_MSG[$i]}" | sanitize | cut -c1-110)"
  done
  echo "================================================="
}

run_jobs() {   # run a prepared job list through run_job and record the results
  local j dep f5
  for j in "${JOBS[@]}"; do
    dep="${j%%|*}"; f5="${j##*|}"
    J_RC=0; J_MSG=""; J_RESULT=""
    run_job "$dep" "$f5"
    f5_close
    record_result "${dep}@${f5}"
    JOB_TAG=""
    if (( FAIL_FAST )) && [[ "${J_RC}" != 0 && "${J_RC}" != "${EX_OUTDATED}" ]]; then
      warn "stopping after the first failure (--fail-fast)"
      break
    fi
  done
}

action_validate() {
  local c d j
  local -A want=()
  if (( SEL_ALL )) || (( ${#JOBS[@]} == 0 )); then
    for c in ${CERTS[@]+"${CERTS[@]}"}; do want[$c]=1; done
  else
    for j in "${JOBS[@]}"; do d="${j%%|*}"; want[${CFG[deploy:${d}|cert]}]=1; done
  fi
  local bad=0
  for c in "${!want[@]}"; do
    JOB_TAG=""
    if ! prepare_cert "$c"; then bad=1; fi
  done
  if (( bad )); then err "validation failed"; return "${EX_ERR}"; fi
  ok "configuration and certificate files are valid (${#DEPLOYS[@]} deployment(s), ${#F5S[@]} BIG-IP(s), ${#CERTS[@]} certificate(s))"
  return 0
}

action_list() {
  local d f5n s prof ver j filtered=0
  local -A chosen=()
  if (( SEL_ALL || ${#SEL_DEPLOY[@]} > 0 || ${#SEL_ENV[@]} > 0 || ${#SEL_LINEAGE[@]} > 0 || ${#SEL_F5[@]} > 0 )); then
    filtered=1
    for j in ${JOBS[@]+"${JOBS[@]}"}; do chosen[${j%%|*}]=1; done
  fi
  echo "Configuration: ${CONFIG_FILE}"
  echo
  for d in ${DEPLOYS[@]+"${DEPLOYS[@]}"}; do
    if (( filtered )) && [[ -z "${chosen[$d]+x}" ]]; then continue; fi
    s="deploy:${d}"
    printf 'deployment %s%s
' "$d" "$([[ "$(eff_bool enabled "$s")" == yes ]] || printf '  (DISABLED)')"
    printf '    env         %s
' "${CFG[$s|env]:--}"
    printf '    certificate %s (object prefix %s)
' "${CFG[$s|cert]}" "$(cert_prefix "${CFG[$s|cert]}")"
    for f5n in $(deploy_f5s "$d"); do
      if (( ${#SEL_F5[@]} > 0 )) && ! in_list "$f5n" "${SEL_F5[@]}"; then continue; fi
      printf '    BIG-IP      %s -> %s@%s:%s, partition %s
' "$f5n" "$(eff user "f5:${f5n}")" "${CFG[f5:${f5n}|host]}" "$(eff port "f5:${f5n}")" "$(eff partition "f5:${f5n}")"
    done
    prof="${CFG[$s|profile]-}"
    if [[ -n "$prof" ]]; then printf '    profiles    %s
' "${prof//$'
'/, }"; else printf '    profiles    (none: only the fixed-name objects are replaced)
'; fi
    ver="${CFG[$s|verify]-}"
    if [[ -n "$ver" ]]; then printf '    verify      %s (from %s)
' "${ver//$'
'/, }" "$(eff verify_from "$s")"; else printf '    verify      (none)
'; fi
  done
  return 0
}

action_discover() {
  local f5n out rc=0 tag a b c d e cn
  local -A seen=()
  local -a specs=() rows=()
  if (( ${#SEL_F5[@]} != 1 )); then usage_die "--discover needs exactly one --f5 NAME"; fi
  f5n="${SEL_F5[0]}"
  JOB_TAG="$f5n"
  f5_load "$f5n"
  info "reading client-ssl profiles on ${F5_USER}@${F5_HOST}"
  out="$(f5_sh "${R_DISCOVER}")" || rc=$?
  if (( rc != 0 )); then err "cannot read the BIG-IP: $(remote_err)"; return "${EX_ERR}"; fi
  while IFS='|' read -r tag a b c d e; do
    [[ "$tag" == DP ]] || continue
    rows+=("$(norm_name "$a")|${b}|$(norm_name "$c")|$(norm_name "$d")|$(norm_name "$e")")
    cn="$(norm_name "$c")"
    if [[ -z "${seen[$cn]+x}" && "$cn" != none ]]; then seen[$cn]=1; specs+=("cert:${cn}"); fi
  done <<<"$out"
  local -A exp=()
  if (( ${#specs[@]} > 0 )); then
    out="$(f5_sh "${R_OBJINFO}" "${specs[@]}")" || true
    while IFS='|' read -r tag a b c d e; do
      if [[ "$tag" == OBJ && "$c" == OK ]]; then exp[$b]="$(hex_to_date "$e")"; fi
    done <<<"$out"
  fi
  echo
  printf '  %-32s %-22s %-40s %s\n' "PROFILE" "ENTRY" "CERTIFICATE" "EXPIRES"
  local r p en cc hh kk
  for r in ${rows[@]+"${rows[@]}"}; do
    IFS='|' read -r p en cc hh kk <<<"$r"
    printf '  %-32s %-22s %-40s %s\n' "$p" "$en" "$cc" "${exp[$cc]:--}" | sanitize
  done
  echo
  f5_close
  info "use these names in a [deploy:NAME] section as:  profile = PROFILE   (or PROFILE:ENTRY for multi-entry profiles)"
  return 0
}

action_list_backups() {
  local j dep f5 out tag a b rc
  for j in "${JOBS[@]}"; do
    dep="${j%%|*}"; f5="${j##*|}"
    JOB_TAG="${dep}@${f5}"
    prepare_cert "${CFG[deploy:${dep}|cert]}" >/dev/null 2>&1 || true
    f5_load "$f5"
    local prefix root
    prefix="$(cert_prefix "${CFG[deploy:${dep}|cert]}")"
    root="$(eff backup_dir_remote "deploy:${dep}" "f5:${f5}")/${prefix}"
    info "backup sets on ${F5_HOST}:${root}"
    rc=0
    out="$(f5_sh "${R_LISTB}" "$root")" || rc=$?
    if (( rc != 0 )); then err "cannot list: $(remote_err)"; continue; fi
    while IFS='|' read -r tag a b; do
      if [[ "$tag" == SET ]]; then info "  ${a}  (${b} files)"; fi
    done <<<"$out"
    f5_close
    info "local copies in $(eff backup_dir_local)/${f5}/${prefix}:"
    ls -1 "$(eff backup_dir_local)/${f5}/${prefix}" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sed 's/^/  /' || true
  done
  JOB_TAG=""
  return 0
}

action_rollback() {
  local j dep f5 rc prefix root
  [[ "$ROLLBACK_SET" =~ ^[0-9]{8}-[0-9]{6}$ ]] || usage_die "--set must look like 20260930-162806 (see --list-backups)"
  for j in "${JOBS[@]}"; do
    dep="${j%%|*}"; f5="${j##*|}"
    JOB_TAG="${dep}@${f5}"
    J_RC=0; J_MSG=""; J_RESULT=""
    prepare_cert "${CFG[deploy:${dep}|cert]}" >/dev/null 2>&1 || true
    job_init "$dep" "$f5"
    J_TS="$ROLLBACK_SET"
    prefix="$(cert_prefix "${CFG[deploy:${dep}|cert]}")"
    root="$(eff backup_dir_remote "deploy:${dep}" "f5:${f5}")/${prefix}"
    J_BDIR_R="${root}/${ROLLBACK_SET}"
    job_lock; rc=$?
    if (( rc != 0 )); then J_RC="${EX_LOCKED}"; J_RESULT=LOCKED; J_MSG="cannot take the lock"; record_result "$JOB_TAG"; continue; fi
    if ! { job_probe && job_gate; }; then J_RESULT=FAILED; lock_release; record_result "$JOB_TAG"; continue; fi
    warn "restoring the state captured before run ${ROLLBACK_SET}"
    local out rc2=0
    out="$(f5_sh "${R_RESTORE}" "${J_BDIR_R}" "${ROLLBACK_SET}")" || rc2=$?
    printf '%s\n' "$out" | sanitize
    if (( rc2 != 0 )); then
      J_RC="${EX_ERR}"; J_RESULT=FAILED; J_MSG="the restore script failed: $(remote_err)"; err "${J_MSG}"
    else
      J_RC=0; J_RESULT=RESTORED; J_MSG="restored the state before ${ROLLBACK_SET}"; ok "${J_MSG}"
    fi
    lock_release
    f5_close
    record_result "$JOB_TAG"
  done
  JOB_TAG=""
}

#######################################################################
# Command line
#######################################################################
need_value() {   # need_value OPTION COUNT_OF_REMAINING_ARGS NEXT
  if (( $2 < 2 )) || [[ "$3" == --* ]]; then usage_die "option $1 needs a value"; fi
}

parse_args() {
  local a
  local -a args=()
  for a in "$@"; do
    if [[ "$a" == --*=* ]]; then args+=("${a%%=*}" "${a#*=}"); else args+=("$a"); fi
  done
  set -- ${args[@]+"${args[@]}"}
  while (( $# > 0 )); do
    case "$1" in
      --config)       need_value "$1" $# "${2:-}"; CONFIG_FILE="$2"; shift 2 ;;
      --deploy)       need_value "$1" $# "${2:-}"; SEL_DEPLOY+=("$2"); shift 2 ;;
      --env)          need_value "$1" $# "${2:-}"; SEL_ENV+=("$2"); shift 2 ;;
      --f5)           need_value "$1" $# "${2:-}"; SEL_F5+=("$2"); shift 2 ;;
      --lineage)      need_value "$1" $# "${2:-}"; SEL_LINEAGE+=("$2"); shift 2 ;;
      --all)          SEL_ALL=1; shift ;;
      --set)          need_value "$1" $# "${2:-}"; ROLLBACK_SET="$2"; shift 2 ;;
      --check)        CHECK_ONLY=1; shift ;;
      --dry-run)      DRY_RUN=1; shift ;;
      --validate)     ACTION=validate; shift ;;
      --list)         ACTION=list; shift ;;
      --discover)     ACTION=discover; shift ;;
      --list-backups) ACTION=list-backups; shift ;;
      --rollback)     ACTION=rollback; shift ;;
      --force)        FORCE=1; shift ;;
      --fail-fast)    FAIL_FAST=1; shift ;;
      --quiet)        QUIET=1; shift ;;
      --version)      echo "${PROG} ${VERSION}"; exit 0 ;;
      -h|--help)      usage; exit 0 ;;
      *)              usage_die "unknown option: $1" ;;
    esac
  done
}

check_dependencies() {
  local t missing=""
  for t in ssh openssl awk sed grep timeout sha256sum mktemp stat date tr cut sort head find id wc cat; do
    command -v "$t" >/dev/null 2>&1 || missing+=" ${t}"
  done
  if [[ -n "$missing" ]]; then
    echo "${PROG}: required tools not found:${missing}" >&2
    exit "${EX_USAGE}"
  fi
  # Reliable "openssl verify -partial_chain" needs 1.1.0 or newer.
  OPENSSL_VERSION="$(openssl version 2>/dev/null | awk '{print $2}')"
  OPENSSL_OLD=0
  if [[ "$OPENSSL_VERSION" =~ ^([0-9]+)\.([0-9]+) ]]; then
    if (( BASH_REMATCH[1] < 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] < 1) )); then OPENSSL_OLD=1; fi
  fi
  if ! date -d '2020-01-01' +%s >/dev/null 2>&1; then
    echo "${PROG}: GNU date (date -d) is required" >&2
    exit "${EX_USAGE}"
  fi
}

make_work_dir() {
  # Prefer tmpfs so key material never touches disk; fall back if that fails.
  local base
  for base in /dev/shm "${TMPDIR:-}" /tmp; do
    [[ -n "$base" && -d "$base" && -w "$base" ]] || continue
    if WORK="$(mktemp -d "${base}/${PROG}.XXXXXXXX" 2>/dev/null)"; then
      chmod 700 "$WORK"
      return 0
    fi
  done
  WORK=""
  echo "${PROG}: cannot create a private scratch directory" >&2
  exit "${EX_ERR}"
}

main() {
  parse_args "$@"
  check_dependencies

  if [[ -z "$CONFIG_FILE" ]]; then
    local c
    for c in "./f5-cert-push.conf" "/etc/f5-cert-push.conf"; do
      if [[ -r "$c" ]]; then CONFIG_FILE="$c"; break; fi
    done
    [[ -n "$CONFIG_FILE" ]] || usage_die "no configuration file: use --config FILE (see f5-cert-push.conf.example)"
  fi
  check_config_permissions "$CONFIG_FILE"
  parse_config "$CONFIG_FILE"
  validate_config
  if (( CFG_ERRORS > 0 )); then
    echo "${PROG}: ${CFG_ERRORS} problem(s) found in ${CONFIG_FILE}; nothing was done" >&2
    exit "${EX_USAGE}"
  fi
  LOG_FILE="$(eff log_file)"
  if [[ -n "$LOG_FILE" ]]; then
    if ! { : >>"$LOG_FILE"; } 2>/dev/null; then echo "${PROG}: cannot write the log file ${LOG_FILE}" >&2; exit "${EX_USAGE}"; fi
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  fi

  make_work_dir
  select_jobs

  local need_sel=0
  case "$ACTION" in
    run|list-backups|rollback) need_sel=1 ;;
  esac
  if (( DRY_RUN || CHECK_ONLY )) && [[ "$ACTION" != run ]]; then usage_die "--check and --dry-run apply to deploys only"; fi
  if (( DRY_RUN && CHECK_ONLY )); then usage_die "use --check or --dry-run, not both"; fi
  if (( need_sel )); then
    if (( ! SEL_ALL && ${#SEL_DEPLOY[@]} == 0 && ${#SEL_ENV[@]} == 0 && ${#SEL_LINEAGE[@]} == 0 )); then
      usage_die "say what to act on: --deploy NAME, --env LABEL, --lineage DIR or --all"
    fi
    if (( ${#JOBS[@]} == 0 )); then
      if (( ${#SEL_LINEAGE[@]} > 0 && ! SEL_ALL && ${#SEL_DEPLOY[@]} == 0 && ${#SEL_ENV[@]} == 0 )); then
        warn "no deployment is configured for lineage ${SEL_LINEAGE[*]}; nothing to do"
        exit 0
      fi
      usage_die "the selection matched no enabled deployment"
    fi
  fi

  local rc=0
  case "$ACTION" in
    validate)      action_validate; rc=$? ;;
    list)          action_list; rc=$? ;;
    discover)      action_discover; rc=$? ;;
    list-backups)  action_list_backups; rc=$? ;;
    rollback)      action_rollback; print_summary; overall_exit; rc=$? ;;
    run)
      info "${PROG} ${VERSION}: $( (( CHECK_ONLY )) && printf 'checking' || { (( DRY_RUN )) && printf 'dry run of' || printf 'deploying'; } ) ${#JOBS[@]} job(s)"
      run_jobs
      print_summary
      overall_exit; rc=$? ;;
  esac
  exit "$rc"
}

main "$@"
