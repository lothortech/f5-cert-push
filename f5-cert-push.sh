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

readonly VERSION="2.2.1"
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
WRITE_CONFIG=""         # --discover --write-config FILE
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
# terminal escape sequences. A message that spans several lines has every line
# after the first indented and marked with "|", so it can never look like a
# record of its own (see quote_lines).
sanitize() { LC_ALL=C tr -cd '\11\12\40-\176'; }
quote_lines() { sanitize | awk '{ printf "%s%s\n", (NR > 1 ? "    | " : ""), $0 }'; }
indent_block() { sanitize | awk '{ printf "    | %s\n", $0 }'; }

_logfile() {
  [[ -n "${LOG_FILE}" ]] || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"${LOG_FILE}" 2>/dev/null || true
}

_fmt() { local tag="$1"; shift; printf '%s %s%s\n' "$tag" "${JOB_TAG:+[${JOB_TAG}] }" "$*" | quote_lines; }

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
    # only a lock that still records this process (never one taken over meanwhile)
    if [[ "$(cat -- "$l/pid" 2>/dev/null)" == "$$" ]]; then rm -rf -- "$l" 2>/dev/null || true; fi
  done
  HELD_LOCKS=()
}

cleanup() {
  local rc=$?
  trap - EXIT
  trap '' INT TERM HUP
  job_unstage
  remote_lock_release || warn "could not release the lock on the BIG-IP; it expires by itself"
  f5_close
  release_all_locks
  wipe_dir "${WORK}"
  exit "$rc"
}

# Signals. A signal must never leave the BIG-IP changed but unverified:
#   - while a step is running on the BIG-IP (IN_MUTATION), the signal is only
#     recorded; the step finishes, and the job then recovers at the next check;
#   - otherwise, if this job may have changed the BIG-IP, it is rolled back (or
#     reported CRITICAL) before the process exits with the job's own exit code;
#   - otherwise the run stops with exit code 130.
# Further signals are ignored while recovering.
SIGNALLED=""
IN_MUTATION=0
JOB_ACTIVE=0

on_signal() {
  SIGNALLED="$1"
  trap '' INT TERM HUP
  if (( IN_MUTATION )); then
    warn "received SIG$1: letting the current step on the BIG-IP finish, then recovering"
    return 0
  fi
  err "interrupted (SIG$1)"
  signal_finish
}

# J_CHANGED is 1 exactly while the current job may have changed the BIG-IP and that
# change is neither verified (deployment complete) nor already dealt with (rolled
# back, or reported): it alone decides whether a signal triggers a rollback.
signal_finish() {
  if (( J_CHANGED )); then
    job_handle_failure "interrupted by SIG${SIGNALLED} after the BIG-IP was changed"
    J_CHANGED=0; JOB_ACTIVE=0
    signal_resync
    record_result "${J_DEP}@${J_F5}"
  elif (( JOB_ACTIVE )); then
    JOB_ACTIVE=0
    job_remove_created || true
    J_RESULT=FAILED; J_RC=130; J_MSG="interrupted by SIG${SIGNALLED}; the profiles were not changed"
    signal_resync
    record_result "${J_DEP}@${J_F5}"
  fi
  JOB_TAG=""
  print_summary
  signal_exit
}

# After an interrupted job has recovered: leave its device group In Sync, as
# job_abort does (objects may have been created and removed). Not after CRITICAL.
signal_resync() {
  if [[ -n "${J_SYNC_G:-}" ]] && (( J_SYNC_PRE && ! REMOTE_LOCK_KEEP )) && [[ "$J_RESULT" != CRITICAL ]]; then
    local src=0
    job_sync ifneeded || src=$?
    if (( src == 2 )); then sync_unknown_after_recovery
    elif (( src != 0 )); then J_MSG+="; and device group ${J_SYNC_G} could not be synchronised afterwards (${SYNC_ERR})"; fi
  fi
}

# A recovery's config-sync did not report its outcome: it may still be copying this
# unit's configuration. CRITICAL, and the BIG-IP lock is kept.
sync_unknown_after_recovery() {
  J_RESULT=CRITICAL; J_RC="${EX_CRITICAL}"; REMOTE_LOCK_KEEP=1; J_UNKNOWN=1
  J_MSG+="; and the config-sync of device group ${J_SYNC_G} afterwards did not report its outcome (${SYNC_ERR}). The BIG-IP lock is left in place; check 'tmsh show cm sync-status'"
  err "${J_MSG}"
}

# Exit after a signal with the most severe result of the whole run (as main does),
# or 130 if nothing worse than an interruption happened.
signal_exit() {
  local rc=0
  overall_exit || rc=$?
  if (( rc == 0 || rc == EX_OUTDATED )); then rc=130; fi
  exit "$rc"
}

sig_check() { if [[ -n "$SIGNALLED" ]] && (( ! IN_MUTATION )); then signal_finish; fi; }
# Nestable: a rollback (itself several steps) runs inside a failure handler.
mut_begin() { IN_MUTATION=$((IN_MUTATION + 1)); }
mut_end()   { if (( IN_MUTATION > 0 )); then IN_MUTATION=$((IN_MUTATION - 1)); fi; }

trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

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
  [sync]=auto
  [sync_timeout]=120
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
  --discover         show each BIG-IP (--f5 NAME, repeatable; default: all): its device
                     groups and sync state, every client-ssl profile with its certificate,
                     chain, key and expiry, and the virtual servers that use it
  --write-config F   with --discover: write the configuration plus suggested [cert:] and
                     [deploy:] sections for every profile not yet covered (to a new file F)
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
        keep|backup_dir_local|backup_dir_remote|strict_host_key_checking|known_hosts_file|connect_timeout|remote_timeout|remote_lock_stale_minutes|connection_reuse|log_file|lock_dir|min_days_valid|auto_rollback|verify_unreachable|chain_check|fixed_names|allow_standby|sync|sync_timeout) return 0 ;;
      esac ;;
    f5)
      case "$2" in
        host|port|user|ssh_key|partition|known_hosts_file|strict_host_key_checking|backup_dir_remote|connect_timeout|remote_timeout|remote_lock_stale_minutes|connection_reuse|allow_standby|keep|lock_dir|sync|sync_group|sync_timeout) return 0 ;;
      esac ;;
    cert)
      case "$2" in
        le_dir|cert|key|chain|fullchain|object_prefix|min_days_valid|chain_check) return 0 ;;
      esac ;;
    deploy)
      case "$2" in
        f5|cert|profile|verify|verify_from|env|enabled|keep|auto_rollback|fixed_names|verify_unreachable|sync) return 0 ;;
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
    connect_timeout|remote_timeout|remote_lock_stale_minutes|sync_timeout)
      if ! is_uint "$val" || (( 10#$val < 1 )); then echo "'${key}' must be a positive number of seconds"; return 1; fi ;;
    sync)
      [[ "$val" == auto || "$val" == no ]] || { echo "'sync' must be auto or no"; return 1; } ;;
    sync_group)
      is_name "$val" || { echo "'sync_group' must be a device group name (letters, digits, . _ -)"; return 1; } ;;
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
               verify_unreachable chain_check fixed_names allow_standby verify_from env enabled \
               sync sync_group sync_timeout; do
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

  # The BIG-IP lock must outlive the longest single step plus the time spent
  # reading back that step's outcome when its reply is lost (see f5_mut).
  local st rt need
  for f in ${F5S[@]+"${F5S[@]}"}; do
    st="$(eff remote_lock_stale_minutes "f5:${f}")"; rt="$(eff remote_timeout "f5:${f}")"
    is_uint "$st" && is_uint "$rt" || continue
    need=$(( (2 * 10#$rt + 300 + 59) / 60 ))
    if (( 10#$st < need )); then
      cfg_err_sec "f5:${f}" "remote_lock_stale_minutes (${st}) must be at least ${need} with remote_timeout = ${rt}: the lock on the BIG-IP must outlive a step that runs for the whole timeout"
    fi
  done

  # Two deployments must not manage the same objects or profiles on one BIG-IP.
  # Targets are compared by what they are on the device, not by how they are
  # spelled: the BIG-IP is identified by host and port (two [f5:] sections can
  # name the same device), profiles are fully qualified with their partition, and
  # a profile named without an entry overlaps every entry of that profile.
  local dev part pq od oe of r
  for d in ${DEPLOYS[@]+"${DEPLOYS[@]}"}; do
    s="deploy:${d}"
    [[ "$(eff_bool enabled "$s")" == yes ]] || continue
    certn="${CFG[$s|cert]-}"
    [[ -n "$certn" && -n "${SECT_SEEN[cert:${certn}]+x}" ]] || continue
    prefix="$(cert_prefix "$certn")"
    for f5n in $(deploy_f5s "$d"); do
      [[ -n "${SECT_SEEN[f5:${f5n}]+x}" ]] || continue
      dev="$(printf '%s' "${CFG[f5:${f5n}|host]-}" | tr 'A-Z' 'a-z')|$(eff port "f5:${f5n}")"
      part="$(eff partition "f5:${f5n}")"
      pk="${dev}|${part}|${prefix}"
      if [[ -n "${prefix_owner[$pk]+x}" && "${prefix_owner[$pk]}" != "$certn" ]]; then
        cfg_err_sec "$s" "object prefix '${prefix}' on the BIG-IP at ${dev%|*} (f5 '${f5n}', partition ${part}) is already used by cert '${prefix_owner[$pk]}'"
      fi
      prefix_owner[$pk]="$certn"
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        p="${line%%:*}"
        e=""
        if [[ "$line" == *:* ]]; then e="${line#*:}"; fi
        case "$p" in /*) pq="$p" ;; *) pq="/${part}/${p}" ;; esac
        pk="${dev}|${pq}"
        while IFS= read -r r; do
          [[ -n "$r" ]] || continue
          IFS='|' read -r od oe of <<<"$r"
          if [[ -z "$oe" || -z "$e" || "$oe" == "$e" ]]; then
            if [[ "$od" != "$d" ]]; then
              cfg_err_sec "$s" "profile '${line}' on f5 '${f5n}' overlaps ${pq}${oe:+:${oe}} on f5 '${of}', already managed by deployment '${od}'"
            elif [[ "$of" == "$f5n" ]]; then
              cfg_err_sec "$s" "profile '${line}' is listed more than once for f5 '${f5n}' (it overlaps ${pq}${oe:+:${oe}})"
            fi
          fi
        done <<<"${prof_owner[$pk]-}"
        prof_owner[$pk]="${prof_owner[$pk]-}${d}|${e}|${f5n}"$'\n'
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
declare -A CERT_KEYPUB=() CERT_CHAINFP=() CERT_FULLFP=()

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

# SHA-256 fingerprint of a certificate (upper-case hex, no colons), the form used
# everywhere: CERT_FP, the BIG-IP object listing, the verify endpoints.
fp_pem() { openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':' | tr 'a-f' 'A-F'; }

# Fingerprint of every certificate in a PEM file ("-" = stdin), one per line.
pem_fps() {
  local f="$1" tmp i n
  if [[ "$f" == - ]]; then tmp="$(mktemp "${WORK}/fps.XXXXXXXX")" || return 1; cat >"$tmp"; f="$tmp"; fi
  n="$(pem_count "$f")"
  for (( i = 1; i <= n; i++ )); do pem_range "$f" "$i" "$i" | fp_pem; done
  if [[ -n "${tmp:-}" ]]; then rm -f -- "$tmp"; fi
}

# All fingerprints of a PEM file, comma-joined: the R_OBJINFO "certall" form.
# A certificate that does not parse is INVALID, so it can never match.
pem_fps_joined() {
  local f="$1" i n fp out=""
  n="$(pem_count "$f")"
  for (( i = 1; i <= n; i++ )); do
    fp="$(pem_range "$f" "$i" "$i" | fp_pem)"
    out="${out:+$out,}${fp:-INVALID}"
  done
  printf '%s' "$out"
}

# SHA-256 of a private key's public half (DER), lower-case hex: identifies a key
# without exposing it. The BIG-IP computes the same value (R_OBJINFO keypub:).
keypub_of() { openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}'; }
readonly EMPTY_SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

# Copy a source file into the private work dir, refusing empty or absurdly
# large files, so validation and upload operate on the same bytes. The file is
# opened once: the type check, the size limit and the copy all apply to that one
# file even if the path is changed meanwhile (timeout: in case a FIFO is swapped in).
copy_src() {   # copy_src SRC DST
  local src="$1" dst="$2" sz
  [[ -f "$src" && -r "$src" ]] || return 1
  # shellcheck disable=SC2016
  if ! timeout 20 bash -c 'exec 3<"$1" || exit 1
      [[ "$(stat -L -c %F /proc/self/fd/3 2>/dev/null)" == "regular file" ]] || exit 1
      exec head -c 1048577 <&3' copy_src "$src" >"$dst" 2>/dev/null; then
    rm -f -- "$dst"; return 1
  fi
  sz="$(wc -c <"$dst" 2>/dev/null)" || { rm -f -- "$dst"; return 1; }
  sz="${sz//[[:space:]]/}"
  (( sz > 0 && sz <= 1048576 )) || { rm -f -- "$dst"; return 1; }
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

  # A fullchain given together with a cert is read too, so that it can be checked
  # against the cert and chain below (it is never used unchecked).
  if [[ -n "$p_full" && ! -f "$d/in.full" ]]; then
    if ! copy_src "$p_full" "$d/in.full"; then err "${tag}: cannot read the fullchain: ${p_full}"; return 1; fi
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

  # A supplied fullchain must be exactly this leaf followed by this chain.
  if [[ -f "$d/in.full" ]]; then
    local fn
    fn="$(pem_count "$d/in.full")"
    for (( i = 1; i <= fn; i++ )); do
      if ! pem_range "$d/in.full" "$i" "$i" | openssl x509 -noout >/dev/null 2>&1; then
        err "${tag}: certificate ${i} of the fullchain does not parse"; return 1
      fi
    done
    if [[ "$(pem_fps "$d/in.full")" != "$(cat -- "$d/cert.pem" "$d/chain.pem" | pem_fps -)" ]]; then
      err "${tag}: the fullchain does not match the certificate and chain (it must be the certificate followed by exactly the intermediates in the chain)"
      return 1
    fi
  fi

  # The fullchain object (fixed_names) is always built from the validated parts.
  cat -- "$d/cert.pem" "$d/chain.pem" >"$d/fullchain.pem"
  CERT_HAVE_CHAIN[$name]=0
  if [[ -s "$d/chain.pem" ]]; then CERT_HAVE_CHAIN[$name]=1; fi
  CERT_HAVE_FULL[$name]=1

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
  CERT_FP[$name]="$(fp_pem <"$d/cert.pem")"
  CERT_KEYPUB[$name]="$(keypub_of "$d/key.pem")"
  CERT_CHAINFP[$name]=""
  if [[ -s "$d/chain.pem" ]]; then CERT_CHAINFP[$name]="$(pem_fps_joined "$d/chain.pem")"; fi
  CERT_FULLFP[$name]="$(pem_fps_joined "$d/fullchain.pem")"
  if [[ -z "${CERT_FP[$name]}" || -z "${CERT_KEYPUB[$name]}" || "${CERT_KEYPUB[$name]}" == "${EMPTY_SHA256}" ]]; then
    err "${tag}: cannot compute the certificate fingerprint or the key identity"; return 1
  fi
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
  # stdin from /dev/null: ssh would otherwise read (and swallow) the caller's
  # stdin, for example the rest of a list being read in a while-loop.
  timeout "${REMOTE_TIMEOUT}" ssh "${SSH_OPTS[@]}" -- "${F5_USER}@${F5_HOST}" \
    "cat -- $(printf '%q' "$src")" >"$dst" 2>"${WORK}/ssh.err" </dev/null || rc=$?
  return "$rc"
}

# Close the shared connection (if any) to the BIG-IP currently loaded.
f5_close() {
  (( SSH_MUX )) || return 0
  timeout 10 ssh "${SSH_OPTS[@]}" -O exit -- "${F5_USER}@${F5_HOST}" >/dev/null 2>&1 || true
  return 0
}

define() { IFS= read -r -d '' "$1" || true; }

# Every step that changes the BIG-IP runs through f5_mut. On the BIG-IP the step
#   1. ignores SIGHUP/SIGPIPE, so a dropped connection cannot stop it half way;
#   2. under the guard (a kernel flock on /var/run/f5-cert-push.guard, which also
#      serialises every lock operation: R_LOCK, R_UNLOCK, R_BEAT, R_STEPRESULT):
#      checks that this run still holds the BIG-IP lock (fencing) and renews it,
#      then CLAIMS its step id (mkdir: exactly once). A step that cannot claim its
#      id has been cancelled by a poller (see below) and never runs;
#   3. runs, with its output and exit status recorded in the lock directory;
#   4. ends its reply with STEPEND|<step id>|<status>, the last line.
# The step id is random per call, so a step's own output cannot imitate that line.
# If the reply is lost (connection dropped, timeout), the outcome is read back
# from the BIG-IP (R_STEPRESULT) instead of being guessed. A step that has not
# claimed its id by then is cancelled atomically by the poller (it claims the id
# itself and marks it cancelled), so "it never ran" is a fact, not an inference.
# Returns the step's own exit status, or one of:
readonly ST_NOTRUN=96     # the step did not run on the BIG-IP, and never will
readonly ST_LOCKLOST=97   # this run no longer holds the BIG-IP lock; the step did not run
readonly ST_UNKNOWN=98    # the outcome could not be established
readonly F5_GUARD=/var/run/f5-cert-push.guard

# Print the payload of a reply and set MUT_RC, if the reply is complete: its last
# non-empty line is STEPEND|ID|N for this step's ID. Returns 1 otherwise.
MUT_RC=0
mut_complete() {   # mut_complete ID REPLY
  local id="$1" reply="$2" last
  last="$(printf '%s\n' "$reply" | awk 'NF { l = $0 } END { print l }')"
  [[ "$last" =~ ^STEPEND\|([A-Za-z0-9.-]+)\|([0-9]{1,3})$ && "${BASH_REMATCH[1]}" == "$id" ]] || return 1
  (( 10#${BASH_REMATCH[2]} <= 255 )) || return 1
  MUT_RC=$(( 10#${BASH_REMATCH[2]} ))
  printf '%s\n' "$reply" | awk -v m="$last" '$0 != m'
  return 0
}

f5_mut() {   # f5_mut SCRIPT ARGS...   (stdout: the step's output)
  local script="$1"; shift
  local id out rc=0 r deadline first
  trap '' INT TERM HUP      # (this is a subshell) the parent decides what a signal means
  id="${J_TS:-0}.$$.${RANDOM}${RANDOM}${RANDOM}"
  out="$(f5_sh "$(printf '%s\n' \
      "trap '' HUP PIPE" \
      "_FL=/var/run/f5-cert-push.lock" \
      "_FT='${REMOTE_LOCK_TOKEN}'" \
      "_ID='${id}'" \
      '_FS="$_FL/step.$_ID"' \
      "exec 8>>${F5_GUARD} && flock -w 60 8 || { echo 'STEP|NOGUARD'; exit 96; }" \
      'if [ -z "$_FT" ] || [ "$(sed -n 1p "$_FL/owner" 2>/dev/null)" != "$_FT" ]; then echo "FENCE|LOST"; exit 97; fi' \
      'if ! mkdir "$_FS.claim" 2>/dev/null; then echo "STEP|CANCELLED"; exit 96; fi' \
      'if ! touch "$_FL/beat" "$_FS.start"; then touch "$_FS.claim/cancelled" 2>/dev/null; echo "STEP|NORECORD"; exit 96; fi' \
      'flock -u 8; exec 8>&-' \
      '(' "$script" ') >"$_FS.out" 2>"$_FS.err" </dev/null' \
      '_RC=$?' \
      'echo "$_RC" >"$_FS.rc.tmp" && mv -f "$_FS.rc.tmp" "$_FS.rc"' \
      'cat "$_FS.out"; head -c 4000 "$_FS.err" >&2' \
      'echo "STEPEND|$_ID|$_RC"')" "$@")" || rc=$?
  if mut_complete "$id" "$out"; then return "$MUT_RC"; fi
  first="$(printf '%s\n' "$out" | awk 'NF { print; exit }')"
  case "$first" in
    'FENCE|LOST') return "${ST_LOCKLOST}" ;;
    'STEP|NOGUARD'|'STEP|CANCELLED'|'STEP|NORECORD') return "${ST_NOTRUN}" ;;
  esac
  warn "no complete reply from the BIG-IP (rc=${rc}); reading the outcome of the step from the BIG-IP"
  deadline=$(( $(date +%s) + REMOTE_TIMEOUT ))
  while :; do
    sleep 5
    r="$(f5_sh "${R_STEPRESULT}" "${REMOTE_LOCK_TOKEN}" "$id" 2>/dev/null)" || r=""
    if mut_complete "$id" "$r"; then return "$MUT_RC"; fi
    case "$(printf '%s\n' "$r" | awk 'NF { print; exit }')" in
      'STEP|CANCELLED') return "${ST_NOTRUN}" ;;     # cancelled: it can never start now
      'STEP|NOLOCK')    return "${ST_UNKNOWN}" ;;
      *) : ;;                                        # RUNNING, BUSY, no answer: keep reading
    esac
    if (( $(date +%s) >= deadline )); then return "${ST_UNKNOWN}"; fi
  done
}

# A plain-language description of f5_mut's special return values.
mut_status_text() {
  case "$1" in
    "${ST_NOTRUN}")   printf 'the step never started on the BIG-IP' ;;
    "${ST_LOCKLOST}") printf 'this run no longer holds the lock on the BIG-IP, so the step was not run' ;;
    "${ST_UNKNOWN}")  printf 'the BIG-IP did not report the outcome of the step' ;;
    *)                printf 'rc=%s' "$1" ;;
  esac
}

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
# returns 1 if the transaction failed: tmsh exited non-zero, or printed an error.
run_txn() {
  local out rc
  out="$( { echo "create cli transaction"; cat; echo "submit cli transaction"; } | tmsh 2>&1 )"
  rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ] || tmsh_failed "$out"; then return 1; fi
  return 0
}

# Run one tmsh command; succeed only if it exits 0 and prints no error.
# The output is left in TMSH_OUT.
tmsh_ok() {
  local rc
  TMSH_OUT="$(tmsh "$@" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] && ! tmsh_failed "$TMSH_OUT"
}
REMOTE_EOF

define R_PROBE <<'REMOTE_EOF'
# args: PARTITION [PROFILE...]
PART="$1"; shift
echo "VERSION|$(tmsh -q show sys version 2>/dev/null | awk '/^  Version/{print $2; exit}')"
echo "MCP|$(tmsh -q show sys mcp-state field-fmt 2>/dev/null | awk '$1=="phase"{p=$2} $1=="last-load"{l=$2} END{print p "|" l}')"
echo "FAILOVER|$(tmsh -q show sys failover 2>/dev/null | head -1 | awk '{print tolower($2)}')"
echo "SYNC|$(tmsh -q show cm sync-status 2>/dev/null | awk '$1=="Mode"{print $2; exit}')"
# This device, its device groups (members, type, auto-sync) and their sync state.
echo "SELF|$(tmsh -q list cm device one-line 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "self-device" && $(i+1) == "true") { print $3; exit }}')"
for g in $(tmsh -q list cm device-group one-line 2>/dev/null | awk '$1 == "cm" && $2 == "device-group" {print $3}'); do
  tmsh -q list cm device-group "$g" auto-sync devices type 2>/dev/null | awk -v G="$g" '
    $1 == "auto-sync" { a = $2 }
    $1 == "type"      { t = $2 }
    /^    devices \{/  { d = 1; next }
    d && /^    \}/     { d = 0; next }
    d && /^        [^ ]+ \{ \}$/ { m = m (m == "" ? "" : ",") $1 }
    END { print "DG|" G "|" t "|" a "|" m }'
done
tmsh -q show cm sync-status field-fmt 2>/dev/null | sed -n 's/^ *details\.[0-9]*\.details \([^ ]*\) (\([^)]*\)): .*/DGSTATUS|\1|\2/p'
tmsh -q show cm device-group field-fmt 2>/dev/null | awk '
  $1 == "cm" && $2 == "device-group-device" { k = $3; o = ""; next }
  $1 == "commit-id-originator" { o = $2 }
  $1 == "commit-id-time"       { print "DGCID|" k "|" o "|" $2 "_" $3 }'
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
# (needs R_LIB) args: cert:NAME | key:NAME | keypub:NAME ...
#   cert:   OBJ|cert|NAME|OK|FINGERPRINT|EXPIRY      or OBJ|cert|NAME|MISSING
#   key:    OBJ|key|NAME|OK                          or OBJ|key|NAME|MISSING
#   keypub: OBJ|keypub|NAME|OK|SHA256-OF-PUBLIC-KEY  or OBJ|keypub|NAME|MISSING
#   certall: OBJ|certall|NAME|OK|FP1,FP2,...         or OBJ|certall|NAME|MISSING
#            (the fingerprint of EVERY certificate in the stored file, in order;
#             INVALID for one that does not parse)
for spec in "$@"; do
  kind="${spec%%:*}"; name="${spec#*:}"
  case "$kind" in
    cert)
      o="$(tmsh -q list sys file ssl-cert "$name" fingerprint expiration-date 2>/dev/null)" || o=""
      if [ -z "$o" ]; then echo "OBJ|cert|$name|MISSING"; continue; fi
      fp="$(printf '%s\n' "$o" | awk '$1=="fingerprint"{print $2}')"
      ex="$(printf '%s\n' "$o" | awk '$1=="expiration-date"{print $2}')"
      fp="$(printf '%s' "${fp#*/}" | tr -d ':' | tr 'a-f' 'A-F')"
      echo "OBJ|cert|$name|OK|$fp|$ex" ;;
    key)
      o="$(tmsh -q list sys file ssl-key "$name" key-type 2>/dev/null)" || o=""
      if [ -n "$o" ]; then echo "OBJ|key|$name|OK"; else echo "OBJ|key|$name|MISSING"; fi ;;
    certall)
      o="$(tmsh -q list sys file ssl-cert "$name" fingerprint 2>/dev/null)" || o=""
      f=""; fps=""
      if [ -n "$o" ]; then f="$(find_pem cert "$name")"; fi
      if [ -n "$f" ] && t="$(mktemp -d /var/tmp/f5-cert-push.objinfo.XXXXXXXX)"; then
        awk -v d="$t" '/-----BEGIN CERTIFICATE-----/ { n++ } n { print > (d "/c" n) }' "$f"
        i=1
        while [ -f "$t/c$i" ]; do
          fp="$(openssl x509 -in "$t/c$i" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':' | tr 'a-f' 'A-F')"
          fps="${fps:+$fps,}${fp:-INVALID}"
          i=$((i + 1))
        done
        rm -rf "$t"
      fi
      if [ -n "$fps" ]; then echo "OBJ|certall|$name|OK|$fps"; else echo "OBJ|certall|$name|MISSING"; fi ;;
    keypub)
      o="$(tmsh -q list sys file ssl-key "$name" key-type 2>/dev/null)" || o=""
      f=""; h=""
      if [ -n "$o" ]; then f="$(find_pem key "$name")"; fi
      if [ -n "$f" ]; then h="$(openssl pkey -in "$f" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"; fi
      if [ -n "$h" ] && [ "$h" != e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]; then
        echo "OBJ|keypub|$name|OK|$h"
      else
        echo "OBJ|keypub|$name|MISSING"
      fi ;;
  esac
done
REMOTE_EOF

define R_BACKUP <<'REMOTE_EOF'
# (needs R_LIB) args: BDIR TS SPEC...
#   SPEC = meta:KEY=VALUE | keep-cert:NAME | keep-key:NAME | fix-cert:NAME | fix-key:NAME
#        | absent-cert:NAME | absent-key:NAME | bind:PROFILE:ENTRY:CERT:CHAIN:KEY
# keep-*    the old object stays on the BIG-IP; restore reinstalls it only if missing
# fix-*     the object will be overwritten in place; restore always reinstalls it
# absent-*  the object does not exist yet; restore deletes it if it exists then
# Writes the PEM copies, INVENTORY (what the set contains, one line per item),
# MANIFEST, restore-TS.sh and SHA256SUMS (covering every other file in the set).
set -u
BDIR="$1"; TS="$2"; shift 2
umask 077
mkdir -p "$(dirname "$BDIR")" || { echo "ERR|cannot create $(dirname "$BDIR")"; exit 1; }
mkdir "$BDIR" || { echo "ERR|backup directory already exists: $BDIR"; exit 1; }
R="restore-$TS.sh"
BODY="$BDIR/.body"; TXN="$BDIR/.txn"; ABS="$BDIR/.absent"
: > "$BODY"; : > "$TXN"; : > "$ABS"; : > "$BDIR/MANIFEST"; : > "$BDIR/INVENTORY"
files=""
n=0

for spec in "$@"; do
  kind="${spec%%:*}"; rest="${spec#*:}"
  case "$kind" in
    meta)
      printf '%s\n' "$rest" >> "$BDIR/MANIFEST" ;;
    keep-cert|keep-key|fix-cert|fix-key)
      mode="${kind%%-*}"; t="${kind#*-}"; name="$rest"
      path="$(find_pem "$t" "$name")"
      if [ -z "$path" ]; then echo "ERR|cannot locate the file behind $t object $name"; exit 1; fi
      n=$((n + 1))
      safe="${name#/}"; safe="${safe//\//__}"
      out="$t.$n.$safe"
      cat -- "$path" > "$BDIR/$out" || { echo "ERR|cannot copy $path"; exit 1; }
      [ -s "$BDIR/$out" ] || { echo "ERR|backup of $name is empty"; exit 1; }
      files="$files $out"
      echo "obj|$mode|$t|$name|$out" >> "$BDIR/INVENTORY"
      case "$mode" in
        keep) printf "ensure %s '%s' \"\$D/%s\"\n" "$t" "$name" "$out" >> "$BODY" ;;
        fix)  printf "force %s '%s' \"\$D/%s\"\n" "$t" "$name" "$out" >> "$BODY" ;;
      esac ;;
    absent-cert|absent-key)
      t="${kind#*-}"; name="$rest"
      echo "absent|$t|$name" >> "$BDIR/INVENTORY"
      printf "remove %s '%s'\n" "$t" "$name" >> "$ABS" ;;
    bind)
      IFS=: read -r _ p e c h k <<< "$spec"
      echo "bind|$p|$e|$c|$h|$k" >> "$BDIR/INVENTORY"
      printf 'modify ltm profile client-ssl %s cert-key-chain modify { %s { cert %s chain %s key %s } }\n' "$p" "$e" "$c" "$h" "$k" >> "$TXN" ;;
    *)
      echo "ERR|unknown backup item $kind"; exit 1 ;;
  esac
done

{
  echo '#!/bin/bash'
  echo "# Generated by f5-cert-push. Restores the BIG-IP state captured just before run $TS."
  echo "# Run on the BIG-IP as root:   bash restore-$TS.sh"
  echo "# Exit status: 0 restored and saved; 10 the backup failed its integrity check"
  echo "# (nothing was changed); anything else: a step failed part-way."
  cat <<'HDR'
set -u
D="$(cd "$(dirname "$0")" && pwd)"
if [ ! -s "$D/SHA256SUMS" ] || ! ( cd "$D" && sha256sum -c --quiet SHA256SUMS ) >/dev/null 2>&1; then
  echo "backup integrity check FAILED (SHA256SUMS missing or not matching); nothing was changed" >&2
  exit 10
fi
failed() { printf '%s\n' "$1" | grep -Eq '^[0-9a-fA-F]{8}:[0-3]:|transaction failed|Syntax Error|Unexpected Error'; }
inst() {
  out="$(tmsh install sys crypto "$1" "$2" from-local-file "$3" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] || failed "$out"; then echo "install of $1 $2 FAILED (rc=$rc): $out" >&2; exit 1; fi
  echo "    reinstalled $1 $2"
}
cls() { if [ "$1" = key ]; then echo ssl-key; else echo ssl-cert; fi; }
exists() { [ -n "$(tmsh -q list sys file "$(cls "$1")" "$2" 2>/dev/null)" ]; }
ensure() { if exists "$1" "$2"; then echo "    $1 $2 still present"; else inst "$1" "$2" "$3"; fi; }
force() { inst "$1" "$2" "$3"; }
remove() {
  if exists "$1" "$2"; then
    out="$(tmsh delete sys crypto "$1" "$2" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] || failed "$out"; then echo "removing $1 $2 FAILED (rc=$rc): $out" >&2; exit 1; fi
    echo "    removed $1 $2 (it did not exist before)"
  fi
}
HDR
  cat "$BODY"
  if [ -s "$TXN" ]; then
    echo 'OUT="$({'
    echo 'echo "create cli transaction"'
    while IFS= read -r l; do printf "echo '%s'\n" "$l"; done < "$TXN"
    echo 'echo "submit cli transaction"'
    echo '} | tmsh 2>&1)"; RC=$?'
    echo 'printf "%s\n" "$OUT"'
    echo 'if [ "$RC" -ne 0 ] || failed "$OUT"; then echo "restoring the profiles FAILED (rc=$RC)" >&2; exit 1; fi'
    echo 'echo "    profiles repointed"'
  fi
  cat "$ABS"
  echo 'OUT="$(tmsh save sys config 2>&1)"; RC=$?'
  echo 'if [ "$RC" -ne 0 ] || failed "$OUT"; then echo "saving the configuration FAILED (rc=$RC): $OUT" >&2; exit 1; fi'
  echo "echo '[+] restored the state captured before run $TS'"
} > "$BDIR/$R"
chmod 700 "$BDIR/$R"
rm -f "$BODY" "$TXN" "$ABS"

( cd "$BDIR" && sha256sum -- $files "$R" INVENTORY MANIFEST > SHA256SUMS.tmp && mv -f SHA256SUMS.tmp SHA256SUMS ) \
  || { echo "ERR|cannot checksum the backup"; exit 1; }
for f in $files "$R" INVENTORY MANIFEST SHA256SUMS; do echo "FILE|$f"; done
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
  if ! tmsh_ok install sys crypto "$kind" "$name" from-local-file "$STAGE/$file"; then
    echo "FAIL|install of $kind $name: $(printf '%s' "$TMSH_OUT" | tr '\n|' '  ' | head -c 300)"
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
if ! tmsh_ok save sys config; then echo "SAVE|FAILED"; exit 2; fi
echo "TXN|OK"
REMOTE_EOF

define R_DELETE <<'REMOTE_EOF'
# (needs R_LIB) args: cert:NAME | key:NAME ...   best-effort removal of objects we created
for spec in "$@"; do
  kind="${spec%%:*}"; name="${spec#*:}"
  if [ "$kind" = key ]; then c=ssl-key; else c=ssl-cert; fi
  if [ -z "$(tmsh -q list sys file "$c" "$name" 2>/dev/null)" ]; then echo "ABSENT|$kind|$name"; continue; fi
  if tmsh_ok delete sys crypto "$kind" "$name"; then echo "DELETED|$kind|$name"; else echo "KEPT|$kind|$name"; fi
done
if ! tmsh_ok save sys config; then echo "SAVE|FAILED"; exit 2; fi
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
    if [ "$kind" = key ]; then c=ssl-key; else c=ssl-cert; fi
    [ -n "$(tmsh -q list sys file "$c" "$nm" 2>/dev/null)" ] || continue
    if tmsh_ok delete sys crypto "$kind" "$nm"; then echo "DELETED|$kind|$nm"; else echo "KEPT|$kind|$nm"; fi
  done
done
if ! tmsh_ok save sys config; then echo "SAVE|FAILED"; exit 2; fi
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
# args: BDIR TS     exit status: the restore script's (10 = integrity check failed, nothing changed)
BDIR="$1"; TS="$2"
[ -f "$BDIR/restore-$TS.sh" ] || { echo "no restore script at $BDIR/restore-$TS.sh" >&2; exit 11; }
bash "$BDIR/restore-$TS.sh"
exit $?
REMOTE_EOF

define R_SAVE <<'REMOTE_EOF'
# (needs R_LIB)
if tmsh_ok save sys config; then echo "SAVE|OK"; else echo "SAVE|FAILED"; exit 1; fi
REMOTE_EOF

define R_LISTFILES <<'REMOTE_EOF'
# args: BDIR   -> FILE|name for every regular file (names only of the safe form)
[ -d "$1" ] || { echo "NODIR"; exit 0; }
for f in "$1"/*; do
  b="${f##*/}"
  if [ -f "$f" ] && [ ! -L "$f" ]; then echo "FILE|$b"; elif [ -e "$f" ] || [ -L "$f" ]; then echo "OTHER|$b"; fi
done
REMOTE_EOF

# The BIG-IP lock is a lease: a directory holding the owner's token, renewed by
# touching "beat" at every step (f5_mut, R_BEAT, R_STEPRESULT). A lock whose beat
# is older than remote_lock_stale_minutes is abandoned and may be taken over.
# Every operation on the lock (take, take over, renew, release, the fence check of
# a step, reading a step's result) runs under one kernel lock, the guard (flock on
# /var/run/f5-cert-push.guard), so they are serialised: a take-over cannot
# interleave with a renewal or a fence check, and the lock path is never briefly
# empty while someone still holds the lease. A run that loses its lock finds out at
# its next step (fencing) and stops.
define R_LOCK <<'REMOTE_EOF'
# args: STALE_MINUTES TOKEN OWNER-TEXT      -> LOCK|OK|new, LOCK|OK|stale or LOCK|BUSY|<owner>
stale="$1"; token="$2"; owner="$3"
L=/var/run/f5-cert-push.lock
exec 8>>/var/run/f5-cert-push.guard && flock -w 60 8 || { echo "LOCK|BUSY|(the lock guard is busy)"; exit 0; }
take() {
  printf '%s\n%s\n' "$token" "$owner" > "$L/owner.tmp" && mv -f "$L/owner.tmp" "$L/owner" && touch "$L/beat" \
    && echo "LOCK|OK|$1"
}
is_stale() {   # no renewal for more than $stale minutes
  local ref="$L/beat"
  [ -e "$ref" ] || ref="$L"
  [ -n "$(find "$ref" -maxdepth 0 -mmin +"$stale" 2>/dev/null)" ]
}
if mkdir -m 700 "$L" 2>/dev/null; then take new || { rm -rf "$L"; echo "LOCK|BUSY|(cannot record the owner)"; }; exit 0; fi
if is_stale; then
  rm -rf "$L"
  if mkdir -m 700 "$L" 2>/dev/null; then take stale || { rm -rf "$L"; echo "LOCK|BUSY|(cannot record the owner)"; }; exit 0; fi
fi
echo "LOCK|BUSY|$(sed -n 2p "$L/owner" 2>/dev/null | head -c 120 | tr '|' ' ')"
exit 0
REMOTE_EOF

define R_UNLOCK <<'REMOTE_EOF'
# args: TOKEN      (removes the lock only if we still own it)
L=/var/run/f5-cert-push.lock
exec 8>>/var/run/f5-cert-push.guard && flock -w 60 8 || { echo "UNLOCK|BUSY"; exit 0; }
if [ "$(sed -n 1p "$L/owner" 2>/dev/null)" = "$1" ]; then rm -rf "$L"; echo "UNLOCK|OK"; else echo "UNLOCK|NOTOURS"; fi
REMOTE_EOF

define R_BEAT <<'REMOTE_EOF'
# args: TOKEN   -> BEAT|OK (lease renewed) or BEAT|LOST
L=/var/run/f5-cert-push.lock
exec 8>>/var/run/f5-cert-push.guard && flock -w 60 8 || { echo "BEAT|BUSY"; exit 0; }
if [ "$(sed -n 1p "$L/owner" 2>/dev/null)" = "$1" ] && touch "$L/beat"; then echo "BEAT|OK"; else echo "BEAT|LOST"; fi
REMOTE_EOF

define R_STEPRESULT <<'REMOTE_EOF'
# args: TOKEN ID   -> the step's stored output and STEPEND|ID|rc, or STEP|RUNNING,
#                     STEP|CANCELLED (it never ran, and now never will), STEP|NOLOCK, STEP|BUSY
L=/var/run/f5-cert-push.lock
case "$2" in *[!A-Za-z0-9.-]*|'') echo "STEP|NOLOCK"; exit 0 ;; esac
S="$L/step.$2"
exec 8>>/var/run/f5-cert-push.guard && flock -w 60 8 || { echo "STEP|BUSY"; exit 0; }
if [ "$(sed -n 1p "$L/owner" 2>/dev/null)" != "$1" ]; then echo "STEP|NOLOCK"; exit 0; fi
touch "$L/beat"
if [ -f "$S.rc" ]; then
  cat "$S.out" 2>/dev/null
  echo "STEPEND|$2|$(cat "$S.rc")"
elif [ -d "$S.claim" ]; then
  if [ -e "$S.claim/cancelled" ]; then echo "STEP|CANCELLED"; else echo "STEP|RUNNING"; fi
elif mkdir "$S.claim" 2>/dev/null && touch "$S.claim/cancelled"; then
  echo "STEP|CANCELLED"           # claimed here: the step can no longer start
else
  echo "STEP|RUNNING"
fi
REMOTE_EOF

define R_SYNCSTATE <<'REMOTE_EOF'
# The sync status of every device group, and each member's last commit id.
tmsh -q show cm sync-status field-fmt 2>/dev/null | sed -n 's/^ *details\.[0-9]*\.details \([^ ]*\) (\([^)]*\)): .*/DGSTATUS|\1|\2/p'
tmsh -q show cm device-group field-fmt 2>/dev/null | awk '
  $1 == "cm" && $2 == "device-group-device" { k = $3; o = ""; next }
  $1 == "commit-id-originator" { o = $2 }
  $1 == "commit-id-time"       { print "DGCID|" k "|" o "|" $2 "_" $3 }'
REMOTE_EOF

define R_SYNC <<'REMOTE_EOF'
# (needs R_LIB) args: DEVICE-GROUP. Push this unit's configuration to the group.
out="$(tmsh -q run cm config-sync to-group "$1" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] || tmsh_failed "$out"; then
  echo "FAIL|$(printf '%s' "$out" | tr '\n|' '  ' | cut -c1-400)"
  exit 1
fi
echo "SYNC|STARTED"
REMOTE_EOF

define R_DISCOVER <<'REMOTE_EOF'
# Every client-ssl profile entry in every partition, the virtual servers and the
# profiles they use, and the details of every certificate a profile uses.
# ("cd /" makes recursive listings span partitions; names then print as Partition/name.)
#   DP|/Part/profile|entry|cert|chain|key|inherit
#   VS|/Part/virtual|destination|/Part/profile,...
#   CERT|name|FINGERPRINT|EXPIRY-EPOCH|CN
certs=""
for p in $(printf '%s\n' 'cd /' 'list ltm profile client-ssl one-line recursive' | tmsh -q 2>/dev/null | awk '{print $4}'); do
  o="$(tmsh -q list ltm profile client-ssl "/$p" inherit-certkeychain cert-key-chain 2>/dev/null)"
  inh="$(printf '%s\n' "$o" | awk '$1=="inherit-certkeychain"{print $2}')"
  printf '%s\n' "$o" | awk -v P="/$p" -v I="${inh:-false}" '
    function flush() { if (e != "") print "DP|" P "|" e "|" c "|" h "|" k "|" I }
    /^        [^ ].* \{$/ { flush(); e = $1; c = "none"; h = "none"; k = "none"; next }
    /^            cert /   { c = $2 }
    /^            chain /  { h = $2 }
    /^            key /    { k = $2 }
    END { flush() }'
  certs="$certs $(printf '%s\n' "$o" | awk '/^            cert /{print $2}')"
done
printf '%s\n' 'cd /' 'list ltm virtual recursive destination profiles' | tmsh -q 2>/dev/null | awk '
  function flush() { if (v != "") print "VS|/" v "|" d "|" pl }
  /^ltm virtual / { flush(); v = $3; d = ""; pl = ""; inp = 0; next }
  /^    destination / { d = $2; next }
  /^    profiles \{/ { inp = 1; next }
  inp && /^    \}/ { inp = 0; next }
  inp && /^        [^ ]+ \{/ { pl = pl (pl == "" ? "" : ",") "/" $1 }
  END { flush() }'
for c in $(printf '%s\n' $certs | sort -u); do
  [ "$c" = none ] && continue
  o="$(tmsh -q list sys file ssl-cert "$c" fingerprint expiration-date subject 2>/dev/null)" || continue
  fp="$(printf '%s\n' "$o" | awk '$1=="fingerprint"{print $2}')"; fp="$(printf '%s' "${fp#*/}" | tr -d ':' | tr 'a-f' 'A-F')"
  ex="$(printf '%s\n' "$o" | awk '$1=="expiration-date"{print $2}')"
  cn="$(printf '%s\n' "$o" | sed -n 's/^ *subject .*CN=\([^,"]*\).*/\1/p' | head -1)"
  echo "CERT|$c|$fp|$ex|$cn"
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
  if [[ ! -O "$dir" || -L "$dir" ]]; then err "lock directory ${dir} is not a directory owned by you"; return 1; fi
  key="$(printf '%s_%s' "$F5_HOST" "$F5_PORT" | tr -c 'A-Za-z0-9._-' '_')"
  lk="${dir}/${key}.lock"
  if lock_take "$lk"; then return 0; fi
  pid="$(cat -- "$lk/pid" 2>/dev/null)" || pid=""
  if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
    # Take over atomically: rename the dead owner's lock away (only one contender
    # can), and only discard it if it is still the one we judged dead.
    local g="${lk}.stale.$$"
    if mv -T -- "$lk" "$g" 2>/dev/null; then
      if [[ "$(cat -- "$g/pid" 2>/dev/null)" == "$pid" ]]; then
        warn "removing stale lock left by process ${pid}"
        rm -rf -- "$g"
        if lock_take "$lk"; then return 0; fi
      else
        mv -T -- "$g" "$lk" 2>/dev/null || rm -rf -- "$g"
      fi
    fi
  fi
  return 2
}

lock_take() {   # create the lock directory with our pid in it, atomically
  local lk="$1"
  mkdir -m 700 -- "$lk" 2>/dev/null || return 1
  if ! { printf '%s\n' "$$" >"$lk/pid.tmp" && mv -f -- "$lk/pid.tmp" "$lk/pid"; }; then
    # A lock without a recorded owner could never be recognised as stale: do not keep it.
    rm -rf -- "$lk"
    err "cannot record the owner of the lock ${lk}"
    return 1
  fi
  HELD_LOCKS+=("$lk")
  return 0
}

lock_release() { remote_lock_release || true; release_all_locks; }

# The BIG-IP-side lock makes the "one run at a time" rule hold across hosts: two
# machines that both push to one BIG-IP cannot interleave.
REMOTE_LOCK_TOKEN=""
REMOTE_LOCK_KEEP=0

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
  if (( REMOTE_LOCK_KEEP )); then
    # After a CRITICAL result a step may still be running on the BIG-IP, or its
    # state is unknown: keep other runs out until it expires (no renewal) or an
    # administrator has checked the device.
    REMOTE_LOCK_KEEP=0
    warn "the lock on the BIG-IP (/var/run/f5-cert-push.lock) is left in place: no other run can change this BIG-IP until it expires after remote_lock_stale_minutes, or an administrator removes it after checking the device"
    return 0
  fi
  f5_sh "${R_UNLOCK}" "$t" >/dev/null 2>&1
}

# Renew the lease on the BIG-IP lock; fails if this run no longer holds it.
remote_lock_beat() {
  [[ -n "${REMOTE_LOCK_TOKEN}" ]] || return 1
  local out
  out="$(f5_sh "${R_BEAT}" "${REMOTE_LOCK_TOKEN}" 2>/dev/null)" || true
  [[ "$out" == *'BEAT|OK'* ]] && return 0
  [[ "$out" == *'BEAT|LOST'* ]] && { err "this run no longer holds the lock on the BIG-IP"; return 1; }
  return 0     # no answer: the next step's fence decides
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
# J_CHANGED: 1 from the moment a step that changes the profiles or the fixed-name
# objects is dispatched, until the BIG-IP is confirmed to be back on (or never to
# have left) its previous state. J_UNKNOWN: a step's outcome could not be read
# back, so even a verified rollback is reported CRITICAL.
J_RC=0 J_MSG="" J_RESULT="" J_CHANGED=0 J_UNKNOWN=0 J_BDIR_R="" J_BDIR_L=""
declare -a J_PROF=() J_VERIFY=() J_TARGETS=() J_CREATED=()
X_VERSION="" X_PHASE="" X_LASTLOAD="" X_FAILOVER="" X_SYNC="" X_PARTITION="" X_SELF=""
# Device groups as read by the probe: type, auto-sync, members (comma separated),
# sync status, and each "GROUP:DEVICE" member's last commit id.
declare -A DG_TYPE=() DG_AUTO=() DG_MEM=() DG_STAT=() DG_CID=()
# Config-sync: the device group this job synchronises (empty: none), whether it was
# In Sync before this run changed anything, and what each active unit's job left
# for its peers: PEER_DONE["DEPLOY|DEVICE"] = "synced|F5" "uptodate|F5" "failed|F5".
J_SYNC_G="" J_SYNC_PRE=0 J_SYNC_BASE="" SYNC_ERR="" PEER_PASS=0
declare -A PEER_DONE=()
declare -A PR_STATE=() PR_INH=() OBJ_FP=() OBJ_EXP=() OBJ_OK=() OBJ_KEYPUB=() OBJ_CERTS=()
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
  J_RC=0; J_MSG=""; J_RESULT=""; J_CHANGED=0; J_UNKNOWN=0; J_BDIR_R=""; J_BDIR_L=""
  J_PROF=(); J_VERIFY=(); J_TARGETS=(); J_CREATED=()
  J_SYNC_G=""; J_SYNC_PRE=0; J_SYNC_BASE=""; SYNC_ERR=""
  while IFS= read -r line; do [[ -n "$line" ]] && J_PROF+=("$line"); done <<<"${CFG[$sd|profile]-}"
  while IFS= read -r line; do [[ -n "$line" ]] && J_VERIFY+=("$line"); done <<<"${CFG[$sd|verify]-}"
  if (( ${#J_PROF[@]} > 0 )); then J_MODE=atomic; else J_MODE=objects; fi
  f5_load "$f"
  J_PART="$F5_PART"
  # The new certificate's fingerprint. Empty for a restore (--rollback), which
  # must not depend on the certificate being replaced.
  J_FP="${CERT_FP[$J_CERT]-}"
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
  local sp
  for sp in ${J_PROF[@]+"${J_PROF[@]}"}; do pn+=("$(profile_fq "${sp%%:*}")"); done
  job_probe_profiles ${pn[@]+"${pn[@]}"}
}

job_probe_profiles() {   # job_probe_profiles PROFILE...   (fully qualified or Common names)
  local out rc=0 tag a b c d e f nc nh nk bad=0
  out="$(f5_sh "${R_PROBE}" "${F5_PART}" "$@")" || rc=$?
  if (( rc != 0 )); then
    job_fail "${EX_ERR}" "cannot read the BIG-IP (ssh/tmsh failed, rc=${rc}): $(remote_err)"; return 1
  fi
  X_VERSION=""; X_PHASE=""; X_LASTLOAD=""; X_FAILOVER=""; X_SYNC=""; X_PARTITION=""
  PR_STATE=(); PR_INH=(); ENT_LIST=()
  parse_sync_lines "$out"
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

# Device-group lines (SELF, DG, DGSTATUS, DGCID) from R_PROBE / R_SYNCSTATE. Names
# that are not plain names are dropped: they are only compared and printed.
parse_sync_lines() {   # parse_sync_lines OUTPUT [state]   (state: only the status and commit lines)
  local tag a b c d m ok
  if [[ "${2:-}" != state ]]; then X_SELF=""; DG_TYPE=(); DG_AUTO=(); DG_MEM=(); fi
  DG_STAT=(); DG_CID=()
  while IFS='|' read -r tag a b c d; do
    case "$tag" in
      SELF) if is_name "$a"; then X_SELF="$a"; fi ;;
      DG)
        is_name "$a" || continue
        ok=1
        for m in ${d//,/ }; do is_name "$m" || ok=0; done
        (( ok )) || continue
        DG_TYPE[$a]="$b"; DG_AUTO[$a]="${c:-disabled}"; DG_MEM[$a]="$d" ;;
      DGSTATUS) if is_name "$a" && [[ "$b" =~ ^[A-Za-z\ ]{1,40}$ ]]; then DG_STAT[$a]="$b"; fi ;;
      DGCID) if [[ "$a" =~ ^[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$ ]]; then DG_CID[$a]="${b}|${c}"; fi ;;
    esac
  done <<<"$1"
}

csv_has() { [[ ",$2," == *",$1,"* ]]; }   # csv_has ITEM A,B,C

# The members of the job's device group other than this unit, comma separated.
sync_peers() {
  local m out=""
  for m in ${DG_MEM[$J_SYNC_G]//,/ }; do [[ "$m" == "$X_SELF" ]] || out+="${out:+,}${m}"; done
  printf '%s' "$out"
}

# Choose the device group to synchronise after a change (J_SYNC_G), or none.
#   sync = no                          none
#   sync_group = NAME (in [f5:])       that group; this unit must be a member
#   otherwise                          the one sync-failover group this unit shares
#                                      with another device (several: name one)
sync_select() {
  local g n=0 pick="" want
  J_SYNC_G=""
  if [[ "$(eff sync "deploy:${J_DEP}" "f5:${J_F5}")" == no ]]; then return 0; fi
  want="$(eff sync_group "f5:${J_F5}")"
  if [[ -n "$want" ]]; then
    if [[ -z "${DG_TYPE[$want]+x}" ]]; then job_fail "${EX_ERR}" "sync_group '${want}' does not exist on this BIG-IP (tmsh list cm device-group)"; return 1; fi
    if [[ -z "$X_SELF" ]] || ! csv_has "$X_SELF" "${DG_MEM[$want]}"; then job_fail "${EX_ERR}" "this BIG-IP (${X_SELF:-unknown}) is not a member of sync_group '${want}'"; return 1; fi
    J_SYNC_G="$want"; return 0
  fi
  [[ -n "$X_SELF" ]] || return 0
  for g in "${!DG_TYPE[@]}"; do
    [[ "${DG_TYPE[$g]}" == sync-failover ]] || continue
    csv_has "$X_SELF" "${DG_MEM[$g]}" || continue
    [[ "${DG_MEM[$g]}" == *,* ]] || continue
    n=$((n + 1)); pick="$g"
  done
  if (( n > 1 )); then
    job_fail "${EX_ERR}" "this BIG-IP is in ${n} sync-failover device groups; set sync_group = NAME in its [f5:${J_F5}] section (or sync = no)"; return 1
  fi
  J_SYNC_G="$pick"
  return 0
}

# Before changing anything: the group must be In Sync. Otherwise the sync after the
# deployment would also copy whatever else is pending on this unit to its peers.
sync_precheck() {
  local st
  [[ -n "$J_SYNC_G" ]] || return 0
  if ! sync_baseline; then
    st="${SS_STATUS:-unknown}"
    if [[ "$st" == "In Sync" ]]; then st="In Sync, but its members report different last commits"; fi
    job_fail "${EX_ERR}" "device group ${J_SYNC_G} is '${st}', not In Sync. Synchronising after this deployment would also copy whatever else is pending to $(sync_peers). Resolve the group first (check what differs, then sync from the unit whose configuration is right: tmsh run cm config-sync to-group ${J_SYNC_G}), or set sync = no for this deployment"
    return 1
  fi
  J_SYNC_PRE=1
  return 0
}

# Read the group now; succeed only if it is In Sync with the same last commit on
# every member, and remember this unit's commit (J_SYNC_BASE): the sync after a
# change must show a NEWER commit everywhere, never this one.
sync_baseline() {
  J_SYNC_BASE=""
  sync_state "$J_SYNC_G" || return 1
  [[ "$SS_STATUS" == "In Sync" && "$SS_SAME" == 1 && -n "$SS_SELF" ]] || return 1
  J_SYNC_BASE="$SS_SELF"
  return 0
}

# Read the group's state now: SS_STATUS, and SS_SAME=1 when every member reports
# the same last commit (the peers have loaded exactly this unit's configuration).
sync_state() {   # sync_state GROUP   -> SS_STATUS, SS_SAME, SS_SELF (this unit's last commit)
  local g="$1" out k m first="" same=1 n=0
  SS_STATUS=""; SS_SAME=0; SS_SELF=""
  out="$(f5_sh "${R_SYNCSTATE}" 2>/dev/null)" || return 1
  parse_sync_lines "$out" state
  SS_STATUS="${DG_STAT[$g]:-}"
  SS_SELF="${DG_CID[${g}:${X_SELF}]:-}"
  for m in ${DG_MEM[$g]//,/ }; do
    k="${DG_CID[${g}:${m}]:-}"
    [[ -n "$k" ]] || { same=0; continue; }
    n=$((n + 1))
    if [[ -z "$first" ]]; then first="$k"; elif [[ "$k" != "$first" ]]; then same=0; fi
  done
  (( n >= 2 && same )) && SS_SAME=1
  return 0
}

# Synchronise the job's device group and wait until every member has this unit's
# configuration: In Sync, every member on the same last commit, and that commit is
# NEWER than the one recorded before the change (J_SYNC_BASE), so an old snapshot
# can never pass. "always" after a deployment; "ifneeded" after a recovery (sync only
# if the members differ now).
# Returns 0 synchronised, 1 not (SYNC_ERR says why), 2 the config-sync step did not
# report its outcome and the group never showed the new commit: it may still be
# running, so the caller reports CRITICAL and keeps the BIG-IP lock.
job_sync() {   # job_sync always|ifneeded
  local g="$J_SYNC_G" out rc=0 limit deadline
  SYNC_ERR=""
  [[ -n "$g" ]] || return 0
  # Without the commit recorded before the change there is nothing to prove the sync
  # against: never claim success then (callers always record it first).
  if [[ -z "$J_SYNC_BASE" ]]; then SYNC_ERR="no commit was recorded for device group ${g} before the change; not synchronising it"; return 1; fi
  limit=$(( 10#$(eff sync_timeout "f5:${J_F5}") ))
  if [[ "$1" == ifneeded ]] && sync_state "$g" && [[ "$SS_STATUS" == "In Sync" && "$SS_SAME" == 1 ]]; then
    return 0
  fi
  if [[ "${DG_AUTO[$g]:-disabled}" == enabled ]]; then
    info "device group ${g} synchronises automatically; waiting for $(sync_peers)"
  else
    info "synchronising device group ${g} to $(sync_peers)"
    mut_begin
    out="$(f5_mut "${R_LIB}"$'\n'"${R_SYNC}" "$g")" || rc=$?
    mut_end
    if (( rc != 0 && rc != ST_UNKNOWN )); then
      local why
      why="$(printf '%s\n' "$out" | sed -n 's/^FAIL|//p' | head -1 | sanitize)"
      SYNC_ERR="config-sync to ${g} failed ($(mut_status_text "$rc")): ${why:-$(remote_err)}"; return 1
    fi
  fi
  deadline=$(( SECONDS + limit ))
  while :; do
    if sync_state "$g" && [[ "$SS_STATUS" == "In Sync" && "$SS_SAME" == 1 && -n "$SS_SELF" && "$SS_SELF" != "$J_SYNC_BASE" ]]; then
      ok "device group ${g} is In Sync: $(sync_peers) loaded this unit's new configuration"
      return 0
    fi
    (( SECONDS < deadline )) || break
    sleep 3
  done
  if (( rc == ST_UNKNOWN )); then
    SYNC_ERR="the config-sync to ${g} did not report its outcome, and the group did not show the new configuration on every member within ${limit}s (last status: ${SS_STATUS:-unknown}); the sync may still be running"
    return 2
  fi
  SYNC_ERR="device group ${g} did not report In Sync with this unit's new commit on every member within ${limit}s (last status: ${SS_STATUS:-unknown})"
  return 1
}

# Tell the peers' jobs (later in this run) what happened on their active unit.
peer_mark() {   # peer_mark synced|uptodate|failed
  local m
  [[ -n "$J_SYNC_G" ]] || return 0
  for m in ${DG_MEM[$J_SYNC_G]//,/ }; do
    [[ "$m" == "$X_SELF" ]] || PEER_DONE["${J_DEP}|${m}"]="${1}|${J_F5}"
  done
}

# A STANDBY unit listed in a deployment whose device group is synchronised: it is
# not changed directly. It receives the change from its active unit by config-sync,
# and this job checks that it did. Read-only.
peer_job() {
  local st from
  if (( DRY_RUN )); then
    J_RESULT=DRYRUN; J_MSG="standby: receives this deployment by config-sync from its active unit"
    info "this BIG-IP is standby: it is not changed directly; it receives the deployment by config-sync from its active unit, and is then checked"
    return 0
  fi
  st="${PEER_DONE[${J_DEP}|${X_SELF}]-}"
  if [[ -z "$st" && "$PEER_PASS" == 0 ]]; then J_RESULT=DEFER; return 0; fi
  from="${st#*|}"
  case "${st%%|*}" in
    synced|uptodate)
      if ! { job_select_targets && job_objinfo; }; then J_RESULT=FAILED; return 0; fi
      if job_is_current; then
        J_RESULT=IN_SYNC; J_RC=0
        J_MSG="standby; has the new certificate (by config-sync from ${from})"
        ok "${J_MSG}"
      else
        J_RESULT=NOT_SYNCED; J_RC="${EX_ERR}"
        J_MSG="standby; does NOT have the new certificate, although ${from} $( [[ "${st%%|*}" == synced ]] && printf 'reported its device group In Sync' || printf 'already had it'). Check: tmsh show cm sync-status"
        err "${J_MSG}"
      fi ;;
    failed)
      J_RESULT=SKIPPED; J_RC=0
      J_MSG="standby; not checked: the deployment on its active unit ${from} did not complete (see that line)"
      warn "${J_MSG}" ;;
    *)
      J_RESULT=STANDBY; J_RC="${EX_ERR}"
      J_MSG="standby, and no active unit of its device group was deployed in this run: add the active unit to this deployment's f5 list"
      err "${J_MSG}" ;;
  esac
  return 0
}

job_gate_loaded() {
  if [[ -z "$X_VERSION" ]]; then job_fail "${EX_ERR}" "the BIG-IP did not return a version; is tmsh available to ${F5_USER}?"; return 1; fi
  if [[ "$X_PHASE" != running || "$X_LASTLOAD" != full-config-load-succeed ]]; then
    job_fail "${EX_ERR}" "the BIG-IP configuration is not fully loaded (phase '${X_PHASE}', last load '${X_LASTLOAD}'); refusing to change it"; return 1
  fi
  if [[ "$X_PARTITION" != OK ]]; then job_fail "${EX_ERR}" "partition '${F5_PART}' does not exist on the BIG-IP"; return 1; fi
  return 0
}

job_gate() {
  job_gate_loaded || return 1
  # --check only reads: a standby unit can be compared too.
  if [[ "$X_FAILOVER" != active ]] && ! { (( CHECK_ONLY )) && [[ "$X_FAILOVER" == standby ]]; }; then
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
  OBJ_FP=(); OBJ_EXP=(); OBJ_OK=(); OBJ_KEYPUB=(); OBJ_CERTS=()
  for t in ${J_TARGETS[@]+"${J_TARGETS[@]}"}; do
    IFS='|' read -r _ _ c h k <<<"$t"
    specs+=("cert:${c}" "key:${k}")
    if [[ "$h" != none ]]; then specs+=("cert:${h}"); fi
  done
  if [[ "$J_MODE" == objects || "$J_FIXED" == yes ]]; then
    specs+=("cert:$(fixed_cert_obj)" "certall:$(fixed_cert_obj)" "key:$(fixed_key_obj)" "keypub:$(fixed_key_obj)"
            "cert:$(fixed_chain_obj)" "certall:$(fixed_chain_obj)" "cert:$(fixed_full_obj)" "certall:$(fixed_full_obj)")
  fi
  if (( ${#specs[@]} == 0 )); then return 0; fi
  objinfo_read "${specs[@]}" || { job_fail "${EX_ERR}" "cannot read certificate objects on the BIG-IP: $(remote_err)"; return 1; }
  return 0
}

# Read objects into OBJ_OK / OBJ_FP / OBJ_EXP / OBJ_KEYPUB (adding to what is there).
objinfo_read() {   # objinfo_read SPEC...
  local out rc=0 tag a b cc d e
  out="$(f5_sh "${R_LIB}"$'\n'"${R_OBJINFO}" "$@")" || rc=$?
  (( rc == 0 )) || return 1
  while IFS='|' read -r tag a b cc d e; do
    [[ "$tag" == OBJ ]] || continue
    # OBJ|kind|name|OK|...   or   OBJ|kind|name|MISSING
    safe_obj "$b" || continue
    if [[ "$cc" == OK ]]; then
      case "$a" in
        cert)   OBJ_OK["cert:${b}"]=1; OBJ_FP["$b"]="$d"; OBJ_EXP["$b"]="$e" ;;
        key)    OBJ_OK["key:${b}"]=1 ;;
        keypub) OBJ_KEYPUB["$b"]="$d" ;;
        certall) [[ "$d" =~ ^[A-Z0-9,]+$ ]] && OBJ_CERTS["$b"]="$d" ;;
      esac
    else
      case "$a" in
        cert)   unset "OBJ_OK[cert:${b}]" "OBJ_FP[$b]" "OBJ_EXP[$b]" ;;
        key)    unset "OBJ_OK[key:${b}]" ;;
        keypub) unset "OBJ_KEYPUB[$b]" ;;
        certall) unset "OBJ_CERTS[$b]" ;;
      esac
    fi
  done <<<"$out"
  return 0
}

# The fixed-name objects hold exactly the new certificate, chain, fullchain and key
# (every certificate of the chain and fullchain objects is compared, in order).
fixed_is_current() {
  [[ "${OBJ_CERTS[$(fixed_cert_obj)]:-}" == "$J_FP" ]] || return 1
  [[ "${OBJ_KEYPUB[$(fixed_key_obj)]:-}" == "${CERT_KEYPUB[$J_CERT]}" ]] || return 1
  [[ "${OBJ_CERTS[$(fixed_full_obj)]:-}" == "${CERT_FULLFP[$J_CERT]}" ]] || return 1
  if [[ "${CERT_HAVE_CHAIN[$J_CERT]}" == 1 ]]; then
    [[ "${OBJ_CERTS[$(fixed_chain_obj)]:-}" == "${CERT_CHAINFP[$J_CERT]}" ]] || return 1
  fi
  return 0
}

job_is_current() {
  local t c
  for t in ${J_TARGETS[@]+"${J_TARGETS[@]}"}; do
    IFS='|' read -r _ _ c _ <<<"$t"
    [[ "${OBJ_FP[$c]:-}" == "$J_FP" ]] || return 1
  done
  if [[ "$J_MODE" == objects || "$J_FIXED" == yes ]]; then fixed_is_current || return 1; fi
  return 0
}

job_report_state() {
  local t p e c h k fp state
  for t in ${J_TARGETS[@]+"${J_TARGETS[@]}"}; do
    IFS='|' read -r p e c h k <<<"$t"
    fp="${OBJ_FP[$c]:-}"
    if [[ "$fp" == "$J_FP" ]]; then state="up to date"; else state="OUT OF DATE"; fi
    info "${p} / ${e}: uses ${c}, expires $(hex_to_date "${OBJ_EXP[$c]:-0}"), ${state}"
  done
  if [[ "$J_MODE" == objects || "$J_FIXED" == yes ]]; then
    c="$(fixed_cert_obj)"
    if [[ -z "${OBJ_FP[$c]:-}" ]]; then state="not installed"
    elif fixed_is_current; then state="up to date (certificate, chain, fullchain and key)"
    else state="OUT OF DATE"; fi
    info "fixed-name objects ${J_PREFIX}-{cert,chain,fullchain,privkey}.pem: ${state}"
  fi
}

#######################################################################
# Changing the BIG-IP
#######################################################################
job_backup() {
  local root="${F5_BACKUP_ROOT}/${J_PREFIX}" out rc=0 tag a b f o kind name
  local -a specs=() files=() expect=()
  local t p e c h k seen=" "
  local -A got=()

  specs+=("meta:tool=${PROG} ${VERSION}" "meta:run=${J_TS}" "meta:deployment=${J_DEP}" "meta:bigip=${F5_NAME}"
          "meta:new_sha256=${J_FP}" "meta:cert=${J_CERT}")
  # What the backup must contain is decided HERE, from the plan, and the set that
  # comes back is checked against it (verify_backup_set).
  for t in ${J_TARGETS[@]+"${J_TARGETS[@]}"}; do
    IFS='|' read -r p e c h k <<<"$t"
    if [[ "$seen" != *" key:${k} "* ]]; then specs+=("keep-key:${k}"); expect+=("obj|keep|key|${k}"); seen+="key:${k} "; fi
    if [[ "$seen" != *" cert:${c} "* ]]; then specs+=("keep-cert:${c}"); expect+=("obj|keep|cert|${c}"); seen+="cert:${c} "; fi
    if [[ "$h" != none && "$seen" != *" cert:${h} "* ]]; then specs+=("keep-cert:${h}"); expect+=("obj|keep|cert|${h}"); seen+="cert:${h} "; fi
  done
  if [[ "$J_MODE" == objects || "$J_FIXED" == yes ]]; then
    for o in "key:$(fixed_key_obj)" "cert:$(fixed_cert_obj)" "cert:$(fixed_chain_obj)" "cert:$(fixed_full_obj)"; do
      kind="${o%%:*}"; name="${o#*:}"
      if [[ -n "${OBJ_OK[${kind}:${name}]+x}" ]]; then
        specs+=("fix-${kind}:${name}"); expect+=("obj|fix|${kind}|${name}")
      else
        specs+=("absent-${kind}:${name}"); expect+=("absent|${kind}|${name}")
      fi
    done
  fi
  for t in ${J_TARGETS[@]+"${J_TARGETS[@]}"}; do specs+=("bind:${t//|/:}"); expect+=("bind|${t}"); done

  info "backing up current state to ${F5_HOST}:${root}/${J_TS}/ and ${J_BDIR_L}/"
  mut_begin
  out="$(f5_mut "${R_LIB}"$'\n'"${R_BACKUP}" "${root}/${J_TS}" "${J_TS}" "${specs[@]}")" || rc=$?
  mut_end
  J_BDIR_R="${root}/${J_TS}"
  while IFS='|' read -r tag a b; do
    case "$tag" in
      FILE) files+=("$a") ;;
      ERR)  job_fail "${EX_ERR}" "backup failed on the BIG-IP: ${a}"; return 1 ;;
    esac
  done <<<"$out"
  if (( rc != 0 )); then job_fail "${EX_ERR}" "backup failed on the BIG-IP ($(mut_status_text "$rc")): $(remote_err)"; return 1; fi

  mkdir -p -- "${J_BDIR_L}" || { job_fail "${EX_ERR}" "cannot create ${J_BDIR_L}"; return 1; }
  chmod 700 -- "${J_BDIR_L}" 2>/dev/null || true
  for f in ${files[@]+"${files[@]}"}; do
    if [[ ! "$f" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || -n "${got[$f]+x}" ]]; then
      job_fail "${EX_ERR}" "the backup on the BIG-IP returned an unsafe or duplicate file name"; return 1
    fi
    got[$f]=1
    if ! f5_get "${J_BDIR_R}/${f}" "${J_BDIR_L}/${f}"; then
      job_fail "${EX_ERR}" "cannot copy ${f} from the BIG-IP: $(remote_err)"; return 1
    fi
    chmod 600 -- "${J_BDIR_L}/${f}" 2>/dev/null || true
  done
  if ! verify_backup_set "${J_BDIR_L}" "${J_TS}" ${expect[@]+"${expect[@]}"}; then
    job_fail "${EX_ERR}" "the backup is incomplete or does not verify (${VB_ERR}); nothing was changed on the BIG-IP"; return 1
  fi
  ok "backup verified: ${#files[@]} file(s), every item present, checksums match, restore script included"
  return 0
}

# Read a backup set's INVENTORY into INV_BIND ("p|e|c|h|k"), INV_OBJ
# ("mode|kind|name|file"), INV_ABSENT ("kind|name") and INV_ITEMS (normalised
# lines for comparison). A set written by 2.0.0 has no INVENTORY: its contents
# are then read from the restore script it carries (INV_LEGACY=1).
declare -a INV_BIND=() INV_OBJ=() INV_ABSENT=() INV_ITEMS=()
INV_LEGACY=0
VB_ERR=""
inv_name_ok() { safe_obj "$1"; }
parse_inventory() {   # parse_inventory DIR TS
  local dir="$1" ts="$2" line t1 t2 t3 t4 t5 t6 rx_e rx_b
  INV_BIND=(); INV_OBJ=(); INV_ABSENT=(); INV_ITEMS=(); INV_LEGACY=0
  if [[ -f "${dir}/INVENTORY" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      IFS='|' read -r t1 t2 t3 t4 t5 t6 <<<"$line"
      case "$t1" in
        obj)
          [[ ( "$t2" == keep || "$t2" == fix ) && ( "$t3" == cert || "$t3" == key ) && -z "$t6" ]] \
            && inv_name_ok "$t4" && [[ "$t5" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { VB_ERR="bad INVENTORY line"; return 1; }
          INV_OBJ+=("${t2}|${t3}|${t4}|${t5}"); INV_ITEMS+=("obj|${t2}|${t3}|${t4}") ;;
        absent)
          [[ ( "$t2" == cert || "$t2" == key ) && -z "$t4" ]] && inv_name_ok "$t3" || { VB_ERR="bad INVENTORY line"; return 1; }
          INV_ABSENT+=("${t2}|${t3}"); INV_ITEMS+=("absent|${t2}|${t3}") ;;
        bind)
          [[ "$line" =~ ^bind\|[^|]+\|[^|]+\|[^|]+\|[^|]+\|[^|]+$ ]] && inv_name_ok "$t2" && is_name "$t3" \
            && inv_name_ok "$t4" && { [[ "$t5" == none ]] || inv_name_ok "$t5"; } && inv_name_ok "$t6" \
            || { VB_ERR="bad INVENTORY line"; return 1; }
          INV_BIND+=("${t2}|${t3}|${t4}|${t5}|${t6}"); INV_ITEMS+=("bind|${t2}|${t3}|${t4}|${t5}|${t6}") ;;
        *) VB_ERR="bad INVENTORY line"; return 1 ;;
      esac
    done <"${dir}/INVENTORY"
    return 0
  fi
  # 2.0.0 set: read the restore script, accepting only the exact lines 2.0.0 wrote.
  [[ -f "${dir}/restore-${ts}.sh" ]] || { VB_ERR="no INVENTORY and no restore script"; return 1; }
  INV_LEGACY=1
  rx_e="^(ensure|force) (cert|key) '([^']+)' \"\\\$D/([A-Za-z0-9][A-Za-z0-9._-]*)\"\$"
  rx_b="^echo 'modify ltm profile client-ssl ([^ ]+) cert-key-chain modify \\{ ([^ ]+) \\{ cert ([^ ]+) chain ([^ ]+) key ([^ ]+) \\} \\}'\$"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $rx_e ]]; then
      t2="${BASH_REMATCH[1]}"; t3="${BASH_REMATCH[2]}"; t4="${BASH_REMATCH[3]}"; t5="${BASH_REMATCH[4]}"
      if [[ "$t2" == ensure ]]; then t2=keep; else t2=fix; fi
      inv_name_ok "$t4" || { VB_ERR="unexpected name in the 2.0.0 restore script"; return 1; }
      INV_OBJ+=("${t2}|${t3}|${t4}|${t5}"); INV_ITEMS+=("obj|${t2}|${t3}|${t4}")
    elif [[ "$line" =~ $rx_b ]]; then
      t2="${BASH_REMATCH[1]}"; t3="${BASH_REMATCH[2]}"; t4="${BASH_REMATCH[3]}"; t5="${BASH_REMATCH[4]}"; t6="${BASH_REMATCH[5]}"
      inv_name_ok "$t2" && is_name "$t3" && inv_name_ok "$t4" && { [[ "$t5" == none ]] || inv_name_ok "$t5"; } && inv_name_ok "$t6" \
        || { VB_ERR="unexpected name in the 2.0.0 restore script"; return 1; }
      INV_BIND+=("${t2}|${t3}|${t4}|${t5}|${t6}"); INV_ITEMS+=("bind|${t2}|${t3}|${t4}|${t5}|${t6}")
    fi
  done <"${dir}/restore-${ts}.sh"
  return 0
}

# The restore script that version 2.0.0 generated for the contents parsed from a
# 2.0.0 set (INV_OBJ, INV_BIND, in their order), byte for byte. A 2.0.0 set is
# only accepted if its script is exactly this: then running it does precisely what
# its parsed contents say, and the verification afterwards checks exactly that.
# (Any other line, however harmless it looks, would run unchecked.)
legacy_script_text() {   # legacy_script_text TS
  local ts="$1" x mode kind name f p e c h k
  echo '#!/bin/bash'
  echo "# Generated by f5-cert-push. Restores the BIG-IP state captured just before run ${ts}."
  echo "# Run on the BIG-IP as root:   bash restore-${ts}.sh"
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
  for x in ${INV_OBJ[@]+"${INV_OBJ[@]}"}; do
    IFS='|' read -r mode kind name f <<<"$x"
    if [[ "$mode" == keep ]]; then printf "ensure %s '%s' \"\$D/%s\"\n" "$kind" "$name" "$f"
    else printf "force %s '%s' \"\$D/%s\"\n" "$kind" "$name" "$f"; fi
  done
  if (( ${#INV_BIND[@]} > 0 )); then
    echo 'OUT="$({'
    echo 'echo "create cli transaction"'
    for x in "${INV_BIND[@]}"; do
      IFS='|' read -r p e c h k <<<"$x"
      printf "echo '%s'\n" "modify ltm profile client-ssl ${p} cert-key-chain modify { ${e} { cert ${c} chain ${h} key ${k} } }"
    done
    echo 'echo "submit cli transaction"'
    echo '} | tmsh 2>&1)"'
    echo 'printf "%s\n" "$OUT"'
    echo 'if failed "$OUT"; then echo "restoring the profiles FAILED" >&2; exit 1; fi'
    echo 'echo "    profiles repointed"'
  fi
  echo 'tmsh save sys config > /dev/null'
  echo "echo '[+] restored the state captured before run ${ts}'"
}

# Check a downloaded backup set: every file present, nothing unexpected, the
# checksum list strictly formed and covering every other file, the checksums
# matching, every backed-up PEM parsing, and (when EXPECTED items are given) the
# inventory being exactly what was planned. Sets VB_ERR on failure.
verify_backup_set() {   # verify_backup_set DIR TS [EXPECTED-ITEM...]
  local dir="$1" ts="$2"; shift 2
  local f line name x kind
  local -A listed=() referenced=()
  VB_ERR=""
  for f in SHA256SUMS MANIFEST "restore-${ts}.sh"; do
    [[ -s "${dir}/${f}" ]] || { VB_ERR="${f} is missing or empty"; return 1; }
  done
  parse_inventory "$dir" "$ts" || return 1
  if (( ! INV_LEGACY )); then [[ -f "${dir}/INVENTORY" ]] || { VB_ERR="INVENTORY is missing"; return 1; }; fi
  if (( INV_LEGACY )) && ! cmp -s -- "${dir}/restore-${ts}.sh" <(legacy_script_text "$ts"); then
    VB_ERR="the 2.0.0 restore script is not exactly what version 2.0.0 generates for the contents it lists (it has been edited, or was not made by 2.0.0); refusing to run it"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([0-9a-f]{64})\ \ ([A-Za-z0-9][A-Za-z0-9._-]*)$ ]] || { VB_ERR="SHA256SUMS has a malformed line"; return 1; }
    name="${BASH_REMATCH[2]}"
    [[ -z "${listed[$name]+x}" && "$name" != SHA256SUMS ]] || { VB_ERR="SHA256SUMS lists ${name} twice"; return 1; }
    listed[$name]=1
  done <"${dir}/SHA256SUMS"
  while IFS= read -r f; do
    [[ "$f" == SHA256SUMS ]] && continue
    if (( INV_LEGACY )) && [[ "$f" == "restore-${ts}.sh" || "$f" == MANIFEST ]]; then continue; fi
    [[ -n "${listed[$f]+x}" ]] || { VB_ERR="${f} is not covered by SHA256SUMS"; return 1; }
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\n')
  if [[ -n "$(find "$dir" -mindepth 1 -maxdepth 1 ! -type f -printf x)" ]]; then VB_ERR="the set contains something that is not a regular file"; return 1; fi
  ( cd "$dir" && sha256sum -c --quiet SHA256SUMS ) >/dev/null 2>&1 || { VB_ERR="checksums do not match"; return 1; }
  for x in ${INV_OBJ[@]+"${INV_OBJ[@]}"}; do
    IFS='|' read -r _ kind name f <<<"$x"
    [[ -z "${referenced[$f]+x}" ]] || { VB_ERR="${f} is referenced twice"; return 1; }
    referenced[$f]=1
    [[ -s "${dir}/${f}" && -n "${listed[$f]+x}" ]] || { VB_ERR="backup of ${name} (${f}) is missing"; return 1; }
    if [[ "$kind" == cert ]]; then
      # every certificate in the file, not only the first
      [[ "$(pem_count "${dir}/${f}")" -ge 1 && "$(pem_fps_joined "${dir}/${f}")" != *INVALID* ]]         || { VB_ERR="backup of ${name} does not parse (every certificate in it must)"; return 1; }
    else
      openssl pkey -in "${dir}/${f}" -noout >/dev/null 2>&1 || { VB_ERR="backup of ${name} does not parse"; return 1; }
    fi
  done
  for f in "${!listed[@]}"; do
    case "$f" in INVENTORY|MANIFEST|"restore-${ts}.sh") continue ;; esac
    [[ -n "${referenced[$f]+x}" ]] || { VB_ERR="${f} is in the set but not in its inventory"; return 1; }
  done
  if (( $# > 0 )); then
    if [[ "$(printf '%s\n' "$@" | sort)" != "$(printf '%s\n' ${INV_ITEMS[@]+"${INV_ITEMS[@]}"} | sort)" ]]; then
      VB_ERR="the inventory does not match what was to be backed up"; return 1
    fi
  fi
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

# Remove objects this run created. Best effort; the BIG-IP refuses to delete any
# object a profile still references. Only ever called when the profiles are known
# not to use them (never switched, or switched back and verified).
job_remove_created() {
  (( ${#J_CREATED[@]} > 0 )) || return 0
  local out rc=0 tag a b n=0
  mut_begin
  out="$(f5_mut "${R_LIB}"$'\n'"${R_DELETE}" "${J_CREATED[@]}")" || rc=$?
  mut_end
  if (( rc == ST_UNKNOWN )); then REMOTE_LOCK_KEEP=1; fi
  if (( rc != 0 )); then warn "could not remove the objects created by this run ($(mut_status_text "$rc")); they are pruned by a later run"; return 1; fi
  while IFS='|' read -r tag a b; do [[ "$tag" == DELETED ]] && n=$((n + 1)); done <<<"$out"
  info "removed ${n} object(s) created by this run"
  J_CREATED=()
  return 0
}

job_install_versioned() {
  local out rc=0 tag a b s
  local v_key v_cert v_chain
  v_key="$(qual "${J_PREFIX}-privkey-${J_TS}.pem")"
  v_cert="$(qual "${J_PREFIX}-cert-${J_TS}.pem")"
  v_chain="$(qual "${J_PREFIX}-chain-${J_TS}.pem")"
  local -a specs=("new-key:${v_key}:key.pem" "new-cert:${v_cert}:cert.pem")
  if [[ "${CERT_HAVE_CHAIN[$J_CERT]}" == 1 ]]; then specs+=("new-cert:${v_chain}:chain.pem"); fi
  # Whatever happens from here, these are the only objects this step can have
  # created; remembering all of them (not what the reply claims) means a lost or
  # hostile reply cannot make us delete anything else.
  for s in "${specs[@]}"; do s="${s#new-}"; J_CREATED+=("${s%:*}"); done
  mut_begin
  out="$(f5_mut "${R_LIB}"$'\n'"${R_INSTALL}" "${STAGE_DIR}" "${specs[@]}")" || rc=$?
  mut_end
  if (( rc == ST_UNKNOWN )); then
    # The install may still be running on the BIG-IP: do not delete what it may be
    # creating, and keep other runs out (job_handle_failure: CRITICAL, lock kept).
    J_UNKNOWN=1; J_CREATED=()
    job_fail "${EX_ERR}" "installing the new certificate did not report its outcome ($(mut_status_text "$rc")); the profiles were not switched, but the install may still complete"
    return 1
  fi
  if (( rc != 0 )); then
    while IFS='|' read -r tag a b; do [[ "$tag" == FAIL ]] && warn "BIG-IP: ${a}"; done <<<"$out"
    job_fail "${EX_ERR}" "installing the new certificate failed ($(mut_status_text "$rc")): $(remote_err). The profiles were not touched."
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
  J_CHANGED=1
  mut_begin
  out="$(f5_mut "${R_LIB}"$'\n'"${R_INSTALL}" "${STAGE_DIR}" "${specs[@]}")" || rc=$?
  mut_end
  if (( rc == ST_UNKNOWN )); then J_UNKNOWN=1; fi
  if (( rc != 0 )); then
    while IFS='|' read -r tag a b; do [[ "$tag" == FAIL ]] && warn "BIG-IP: ${a}"; done <<<"$out"
    job_fail "${EX_ERR}" "updating the fixed-name objects failed ($(mut_status_text "$rc")): $(remote_err)"
    return 1
  fi
  ok "updated ${#specs[@]} fixed-name object(s)"
  return 0
}

# Read the fixed-name objects back: certificate, chain, fullchain and key must be
# exactly the new ones (a partial overwrite is caught here).
job_verify_fixed() {
  local -a specs=("certall:$(fixed_cert_obj)" "keypub:$(fixed_key_obj)" "certall:$(fixed_full_obj)")
  if [[ "${CERT_HAVE_CHAIN[$J_CERT]}" == 1 ]]; then specs+=("certall:$(fixed_chain_obj)"); fi
  objinfo_read "${specs[@]}" || return 1
  fixed_is_current
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
  # From the moment the transaction is dispatched the BIG-IP may have changed,
  # whatever the reply says (or fails to say), until shown otherwise.
  J_CHANGED=1
  mut_begin
  out="$(f5_mut "${R_LIB}"$'\n'"${R_TXN}" "${specs[@]}")" || rc=$?
  mut_end
  local txn="" txnout=""
  while IFS='|' read -r tag a b; do
    case "$tag" in
      TXN) txn="$a" ;;
      TXNOUT) txnout="$a" ;;
      SAVE) txn="SAVEFAILED" ;;
    esac
  done <<<"$out"
  if (( rc == 0 )) && [[ "$txn" == OK ]]; then
    ok "profiles switched; configuration saved"
    return 0
  fi
  if [[ "$txn" == SAVEFAILED ]]; then
    job_fail "${EX_ERR}" "the profiles were switched but 'tmsh save sys config' failed, so the change would not survive a restart"
    return 1
  fi
  if (( rc == ST_NOTRUN || rc == ST_LOCKLOST )); then
    J_CHANGED=0
    job_fail "${EX_ERR}" "the profile switch did not run: $(mut_status_text "$rc"). No profile was changed."
    job_remove_created || true
    return 1
  fi
  if (( rc == ST_UNKNOWN )); then
    J_UNKNOWN=1
    job_fail "${EX_ERR}" "the outcome of the profile switch is unknown ($(mut_status_text "$rc")); treating the BIG-IP as changed"
    return 1
  fi
  # The step reported a failure. tmsh transactions are all-or-nothing, but that is
  # confirmed on the device rather than assumed.
  if check_bindings ${J_TARGETS[@]+"${J_TARGETS[@]}"}; then
    J_CHANGED=0
    job_fail "${EX_ERR}" "the tmsh transaction failed; every profile is confirmed unchanged. ${txnout:+BIG-IP said: ${txnout}}"
    job_remove_created || true
    return 1
  fi
  job_fail "${EX_ERR}" "the tmsh transaction reported a failure (rc=${rc}) and the profiles are no longer on their previous objects; treating the BIG-IP as changed. ${txnout:+BIG-IP said: ${txnout}}"
  return 1
}

# check_bindings "PROFILE|ENTRY|CERT|CHAIN|KEY"...
# Re-reads those profiles. Succeeds only if every profile exists, has exactly one
# entry of that name, and that entry uses exactly that cert, chain and key.
check_bindings() {
  local -a profs=()
  local x p e c h k ent ep en ec eh ek n bad=0
  (( $# > 0 )) || return 0
  for x in "$@"; do p="${x%%|*}"; in_list "$p" ${profs[@]+"${profs[@]}"} || profs+=("$p"); done
  job_probe_profiles "${profs[@]}" || return 1
  for x in "$@"; do
    IFS='|' read -r p e c h k <<<"$x"
    if [[ "${PR_STATE[$p]:-}" != OK ]]; then warn "profile ${p} does not exist"; bad=1; continue; fi
    n=0
    for ent in ${ENT_LIST[@]+"${ENT_LIST[@]}"}; do
      IFS='|' read -r ep en ec eh ek _ <<<"$ent"
      [[ "$ep" == "$p" && "$en" == "$e" ]] || continue
      n=$((n + 1))
      if [[ "$ec" != "$(norm_name "$c")" || "$eh" != "$(norm_name "$h")" || "$ek" != "$(norm_name "$k")" ]]; then bad=1; fi
    done
    if (( n != 1 )); then warn "profile ${p} has ${n} entries named ${e} (expected exactly one)"; bad=1; fi
  done
  (( bad == 0 ))
}

# Re-read the profiles and confirm each target entry uses exactly what we set.
job_verify_bindings() {
  local t p e v_key v_cert v_chain
  local -a wantb=()
  v_key="$(norm_name "$(qual "${J_PREFIX}-privkey-${J_TS}.pem")")"
  v_cert="$(norm_name "$(qual "${J_PREFIX}-cert-${J_TS}.pem")")"
  v_chain="none"
  if [[ "${CERT_HAVE_CHAIN[$J_CERT]}" == 1 ]]; then v_chain="$(norm_name "$(qual "${J_PREFIX}-chain-${J_TS}.pem")")"; fi
  for t in "${J_TARGETS[@]}"; do
    IFS='|' read -r p e _ _ _ <<<"$t"
    wantb+=("${p}|${e}|${v_cert}|${v_chain}|${v_key}")
  done
  check_bindings "${wantb[@]}"
}

# Returns 0 when every endpoint serves the new certificate; 1 on a mismatch (or
# on no answer when verify_unreachable = fail); warnings otherwise.
job_verify_endpoints() {
  local ep hp sni host port attempt fp depth out tag a b rc status=0
  (( ${#J_VERIFY[@]} > 0 )) || return 0
  for ep in "${J_VERIFY[@]}"; do
    remote_lock_beat || return 1
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
  local reason="$1"
  warn "ROLLING BACK: ${reason}"
  if [[ -z "$J_BDIR_R" || ! -s "${J_BDIR_L}/SHA256SUMS" ]]; then err "no verified backup exists to roll back to"; return 1; fi
  if ! parse_inventory "${J_BDIR_L}" "${J_TS}"; then err "the local copy of the backup cannot be read (${VB_ERR})"; return 1; fi
  RV_DIR="${J_BDIR_L}"
  restore_and_verify || return 1
  ok "rollback complete: the BIG-IP is back on its previous certificate (verified)"
  J_CHANGED=0
  return 0
}

# Run the restore script of backup set J_TS in J_BDIR_R on the BIG-IP, then
# check the result against the inventory already loaded (parse_inventory):
#   - every profile entry exists exactly once and uses exactly its old cert, chain, key;
#   - every backed-up certificate object has the backed-up certificate's fingerprint
#     and every backed-up key object has the backed-up key (compared by public key);
#   - every object that did not exist before does not exist now.
# Returns 0 restored and verified; 10 the backup failed its integrity check on the
# BIG-IP (nothing was changed); 1 anything else (the state is not confirmed).
# RV_DIR is the local copy of the set (for the expected fingerprints).
RV_DIR=""
restore_and_verify() {
  local out rc=0 x mode kind name f want specs_ok=1
  local -a specs=()
  mut_begin
  out="$(f5_mut "${R_RESTORE}" "${J_BDIR_R}" "${J_TS}")" || rc=$?
  mut_end
  if [[ -n "$out" ]]; then printf '%s\n' "$out" | indent_block; fi
  if (( rc == 10 )); then err "the backup on the BIG-IP failed its integrity check; the restore changed nothing"; return 10; fi
  if (( rc == ST_LOCKLOST || rc == ST_NOTRUN )); then err "the restore did not run: $(mut_status_text "$rc")"; return 1; fi
  if (( rc != 0 )); then warn "the restore script reported a failure ($(mut_status_text "$rc")): $(remote_err)"; fi
  if (( INV_LEGACY )) && (( rc == 0 )); then
    # A 2.0.0 restore script ignores a failed save: save again, and check it.
    local sv=0 so
    mut_begin
    so="$(f5_mut "${R_LIB}"$'\n'"${R_SAVE}")" || sv=$?
    mut_end
    if (( sv != 0 )); then err "saving the configuration after the restore failed ($(mut_status_text "$sv"))"; rc=1; fi
  fi

  # Verify, whatever the script said: the device is the authority.
  if (( ${#INV_BIND[@]} > 0 )) && ! check_bindings "${INV_BIND[@]}"; then
    err "after the restore, the profiles do not match their previous bindings"; return 1
  fi
  for x in ${INV_OBJ[@]+"${INV_OBJ[@]}"}; do
    IFS='|' read -r mode kind name f <<<"$x"
    if [[ "$kind" == cert ]]; then specs+=("certall:${name}"); else specs+=("keypub:${name}"); fi
  done
  for x in ${INV_ABSENT[@]+"${INV_ABSENT[@]}"}; do
    IFS='|' read -r kind name <<<"$x"
    specs+=("${kind}:${name}")
  done
  OBJ_FP=(); OBJ_EXP=(); OBJ_OK=(); OBJ_KEYPUB=(); OBJ_CERTS=()
  if (( ${#specs[@]} > 0 )) && ! objinfo_read "${specs[@]}"; then err "cannot read the certificate objects back after the restore"; return 1; fi
  for x in ${INV_OBJ[@]+"${INV_OBJ[@]}"}; do
    IFS='|' read -r mode kind name f <<<"$x"
    if [[ "$kind" == cert ]]; then
      want="$(pem_fps_joined "${RV_DIR}/${f}")"
      if [[ -z "$want" || "$want" == *INVALID* || "${OBJ_CERTS[$name]:-}" != "$want" ]]; then err "after the restore, ${name} does not hold the backed-up certificate(s)"; specs_ok=0; fi
    else
      want="$(keypub_of "${RV_DIR}/${f}")"
      if [[ -z "$want" || "$want" == "${EMPTY_SHA256}" || "${OBJ_KEYPUB[$name]:-}" != "$want" ]]; then err "after the restore, ${name} does not hold the backed-up key"; specs_ok=0; fi
    fi
  done
  for x in ${INV_ABSENT[@]+"${INV_ABSENT[@]}"}; do
    IFS='|' read -r kind name <<<"$x"
    if [[ -n "${OBJ_OK[${kind}:${name}]+x}" ]]; then err "after the restore, ${name} still exists (it did not exist before)"; specs_ok=0; fi
  done
  (( specs_ok )) || return 1
  if (( rc != 0 )); then err "the restore script failed even though the state reads back as restored; check the configuration was saved"; return 1; fi
  return 0
}

# Returns 1 only if a pruning step on the BIG-IP never reported its outcome (it
# may still be running): the caller then keeps the BIG-IP lock and reports it.
# Ordinary pruning failures are only warnings; a later run prunes again.
job_prune() {
  (( J_KEEP > 0 )) || return 0
  local out tag a b n=0 root="${F5_BACKUP_ROOT}/${J_PREFIX}" d brc=0
  info "pruning to the newest ${J_KEEP} backup set(s) and certificate version(s)"
  out="$(f5_mut "${R_PRUNE_BACKUPS}" "$root" "${J_KEEP}")" || brc=$?
  if (( brc == 0 )); then
    while IFS='|' read -r tag a b; do
      if [[ "$tag" == REMOVED ]]; then n=$((n + 1)); fi
    done <<<"$out"
    if (( n > 0 )); then info "removed ${n} old backup set(s) from the BIG-IP"; fi
  elif (( brc == ST_UNKNOWN )); then
    warn "pruning backups on the BIG-IP did not report its outcome ($(mut_status_text "$brc")); it may still be running"
    return 1
  else
    warn "pruning backups on the BIG-IP failed ($(mut_status_text "$brc")): $(remote_err)"
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
    local prc=0
    out="$(f5_mut "${R_LIB}"$'\n'"${R_PRUNE_OBJECTS}" "${F5_PART}" "${J_PREFIX}" "${J_KEEP}")" || prc=$?
    while IFS='|' read -r tag a b; do
      if [[ "$tag" == DELETED ]]; then n=$((n + 1)); fi
    done <<<"$out"
    if (( n > 0 )); then info "removed ${n} old certificate object(s) from the BIG-IP"; fi
    if (( prc == ST_UNKNOWN )); then
      warn "pruning old certificate objects did not report its outcome ($(mut_status_text "$prc")); it may still be running"
      return 1
    fi
    if (( prc != 0 )); then warn "pruning old certificate objects did not complete ($(mut_status_text "$prc")): $(remote_err)"; fi
  fi
  return 0
}

#######################################################################
# Running one deployment on one BIG-IP
#######################################################################
job_unstage() {
  [[ -n "${STAGE_DIR}" ]] || return 0
  if (( J_UNKNOWN || REMOTE_LOCK_KEEP )); then
    # A step whose outcome is unknown may still be running, and may still be reading
    # the staged files (an install reads them one by one): leave them. The next run
    # that stages on this BIG-IP removes staging directories older than two hours.
    warn "the staging directory ${STAGE_DIR} on the BIG-IP is left in place, because a step that may still be running could be using it; a later run removes it once it is two hours old"
    STAGE_DIR=""
    return 0
  fi
  remote_remove_stage || warn "could not remove the staging directory ${STAGE_DIR} on the BIG-IP; remove it by hand"
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
  if (( J_CHANGED == 0 && ! J_UNKNOWN )); then
    J_RESULT=FAILED
    if [[ "${J_RC}" == 0 ]]; then J_RC="${EX_ERR}"; fi
    if [[ -z "${J_MSG}" ]]; then J_MSG="$reason"; fi
    return 0
  fi
  local manual="${PROG} --config ${CONFIG_FILE} --deploy ${J_DEP} --f5 ${J_F5} --rollback --set ${J_TS}"
  if (( J_CHANGED == 0 && J_UNKNOWN )); then
    # Nothing was switched, but a step never reported its outcome: it may still be
    # running. Keep other runs out until it is understood.
    J_RC="${EX_CRITICAL}"; J_RESULT=CRITICAL; REMOTE_LOCK_KEEP=1
    J_MSG="${reason}; the profiles were not switched, but a step on the BIG-IP never reported its outcome and may still be running. Check the BIG-IP (--check) before running again"
    err "${J_MSG}"
    return 0
  fi
  if [[ "$J_AUTOROLL" == yes ]]; then
    if job_rollback "$reason"; then
      job_remove_created || true
      if (( J_UNKNOWN )); then
        # Restored and verified, but an earlier step's outcome was never reported:
        # it may still have been running and could change the device again.
        J_RC="${EX_CRITICAL}"; J_RESULT=CRITICAL; REMOTE_LOCK_KEEP=1
        J_MSG="${reason}; rolled back and verified, but an earlier step never reported its outcome and may still complete. Check the BIG-IP now (--check), and roll back again if needed: ${manual}"
        err "${J_MSG}"
        return 0
      fi
      J_RC="${EX_ROLLED_BACK}"; J_RESULT=ROLLED_BACK
      J_MSG="${reason}; rolled back to the previous certificate (verified)"
      return 0
    fi
    J_RC="${EX_CRITICAL}"; J_RESULT=CRITICAL; REMOTE_LOCK_KEEP=1
    J_MSG="${reason}; AND THE ROLLBACK COULD NOT BE CONFIRMED. The BIG-IP may be on the new certificate, the old one, or a mix. Restore with: ${manual}  (or on the BIG-IP: bash ${J_BDIR_R}/restore-${J_TS}.sh)"
    err "${J_MSG}"
    return 0
  fi
  if (( J_UNKNOWN )); then
    J_RC="${EX_CRITICAL}"; J_RESULT=CRITICAL; REMOTE_LOCK_KEEP=1
    J_MSG="${reason}; the outcome is unknown and auto_rollback is off. Check the BIG-IP (--check); roll back with: ${manual}"
    err "${J_MSG}"
    return 0
  fi
  J_RC="${EX_ERR}"; J_RESULT=FAILED_CHANGED
  J_MSG="${reason}; auto_rollback is off, so the BIG-IP is still on the new certificate. Roll back with: ${manual}"
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
  if [[ -n "$J_SYNC_G" ]]; then
    info "  and synchronise device group ${J_SYNC_G} to $(sync_peers) (now: ${DG_STAT[$J_SYNC_G]:-unknown}; it must be In Sync before the change), waiting until they have loaded it"
  fi
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
  if ! job_probe; then J_RESULT=FAILED; lock_release; return 0; fi
  # A standby unit of a synchronised pair is not changed directly (peer_job).
  if [[ "$X_FAILOVER" == standby && "$(eff_bool allow_standby "f5:${f5}")" != yes ]] && (( ! CHECK_ONLY )) \
     && [[ "$(eff sync "deploy:${dep}" "f5:${f5}")" != no ]]; then
    if job_gate_loaded; then peer_job; else J_RESULT=FAILED; fi
    lock_release; return 0
  fi
  if ! { job_gate && sync_select && job_select_targets && job_objinfo; }; then
    J_RESULT=FAILED; lock_release; return 0
  fi
  ok "BIG-IP ${X_VERSION}, ${X_FAILOVER}, sync mode ${X_SYNC:-unknown}, configuration loaded"
  if [[ -n "$J_SYNC_G" ]]; then
    info "device group ${J_SYNC_G} (${DG_TYPE[$J_SYNC_G]}, auto-sync ${DG_AUTO[$J_SYNC_G]:-disabled}) with $(sync_peers): ${DG_STAT[$J_SYNC_G]:-unknown}"
  fi
  job_report_state

  if job_is_current && (( ! FORCE )); then
    J_RESULT=UPTODATE; J_MSG="already serving this certificate"
    ok "nothing to do: the BIG-IP already has this certificate (use --force to redeploy)"
    if (( ! CHECK_ONLY )); then peer_mark uptodate; fi
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
  if ! sync_precheck; then J_RESULT=FAILED; peer_mark failed; lock_release; return 0; fi

  # ---- apply --------------------------------------------------------
  # From here a signal is handled by signal_finish (roll back if changed).
  JOB_ACTIVE=1
  if ! job_backup; then job_abort "the backup failed"; return 0; fi
  sig_check
  if ! job_stage;  then job_abort "staging the files failed"; return 0; fi
  sig_check

  if [[ "$J_MODE" == atomic ]]; then
    if ! job_install_versioned; then job_abort "installing the new certificate failed"; return 0; fi
    sig_check
    if ! job_switch_profiles; then job_abort "switching the profiles failed"; return 0; fi
    sig_check
    if ! job_verify_bindings; then job_abort "the profiles do not reference the new objects after the switch"; return 0; fi
    ok "verified: every target entry uses the new certificate, chain and key"
    sig_check
    if ! job_verify_endpoints; then job_abort "a verification endpoint is not serving the new certificate"; return 0; fi
    sig_check
    if [[ "$J_FIXED" == yes ]]; then
      # The fixed-name objects are part of what was asked for: a failure here is a
      # failed deployment, recovered like any other (the backup holds them).
      if ! job_install_fixed; then job_abort "refreshing the fixed-name objects failed"; return 0; fi
      sig_check
      if ! job_verify_fixed; then job_abort "the fixed-name objects do not hold the new certificate, chain and key after the refresh"; return 0; fi
      ok "verified: the fixed-name objects hold the new certificate, chain, fullchain and key"
    fi
  else
    if ! job_install_fixed; then job_abort "overwriting the certificate objects failed"; return 0; fi
    sig_check
    if ! job_verify_fixed; then job_abort "the certificate objects do not hold the new certificate, chain and key after the overwrite"; return 0; fi
    ok "verified: $(fixed_cert_obj) and its key, chain and fullchain hold the new certificate"
    sig_check
    if ! job_verify_endpoints; then job_abort "a verification endpoint is not serving the new certificate"; return 0; fi
  fi
  sig_check

  # Deployed and verified. Nothing below can make the deployment fail; a signal
  # now just ends the run after this job.
  J_CHANGED=0; JOB_ACTIVE=0
  J_CREATED=()
  local pruned=1
  mut_begin
  job_unstage
  job_prune || pruned=0
  mut_end
  if (( pruned )); then
    J_RESULT=UPDATED; J_RC="${EX_OK}"; J_MSG="deployed; expires ${CERT_END[$J_CERT]}"
    if [[ -n "$J_SYNC_G" ]]; then
      local src=0
      job_sync always || src=$?
      if (( src == 0 )); then
        J_MSG+="; synchronised to $(sync_peers)"
        peer_mark synced
      elif (( src == 2 )); then
        # The sync may still be running: keep other runs out, like any unresolved step.
        J_RESULT=CRITICAL; J_RC="${EX_CRITICAL}"; REMOTE_LOCK_KEEP=1; J_UNKNOWN=1
        J_MSG="deployed and verified on this unit (expires ${CERT_END[$J_CERT]}), but the device group was not confirmed synchronised: ${SYNC_ERR}. The BIG-IP lock is left in place. Check 'tmsh show cm sync-status' on this unit"
        err "${J_MSG}"
        peer_mark failed
      else
        # Live and verified here; the peers still have the previous certificate.
        J_RESULT=SYNC_FAILED; J_RC="${EX_ERR}"
        J_MSG="deployed and verified on this unit (expires ${CERT_END[$J_CERT]}), but NOT synchronised: ${SYNC_ERR}. Its peers ($(sync_peers)) still have the previous certificate: on this unit run 'tmsh run cm config-sync to-group ${J_SYNC_G}', then check 'tmsh show cm sync-status'"
        err "${J_MSG}"
        peer_mark failed
      fi
    elif [[ "$X_SYNC" != standalone && -n "$X_SYNC" ]]; then
      warn "this BIG-IP is in a sync group (mode ${X_SYNC}) and sync = no: synchronise the configuration to its peers yourself"
    fi
  else
    # The deployment itself is verified, but a pruning step may still be deleting
    # old objects or backups: keep other runs out until it is understood.
    J_RESULT=CRITICAL; J_RC="${EX_CRITICAL}"; REMOTE_LOCK_KEEP=1
    J_MSG="deployed and verified (expires ${CERT_END[$J_CERT]}), but pruning old backups or objects on the BIG-IP never reported its outcome and may still be running. Check the BIG-IP (--check) before running again"
    err "${J_MSG}"
  fi
  ok "done; rollback with: ${PROG} --config ${CONFIG_FILE} --deploy ${J_DEP} --f5 ${J_F5} --rollback --set ${J_TS}"
  lock_release
  return 0
}

# A step failed: recover (job_handle_failure), then clean up this job. Signals
# are deferred throughout: recovery is never interrupted half way.
job_abort() {   # job_abort REASON
  mut_begin
  job_handle_failure "$1"
  J_CHANGED=0; JOB_ACTIVE=0     # the outcome is decided and reported; nothing more to recover
  job_unstage
  # The BIG-IP is back where it was (or never left), but objects may have been created
  # and removed: synchronise so the group is In Sync again for the next run. Not after
  # CRITICAL: the state is not known, and must not be copied to the peers.
  if [[ -n "$J_SYNC_G" ]] && (( J_SYNC_PRE && ! REMOTE_LOCK_KEEP )) && [[ "$J_RESULT" != CRITICAL ]]; then
    local src=0
    job_sync ifneeded || src=$?
    if (( src == 2 )); then sync_unknown_after_recovery
    elif (( src != 0 )); then
      J_MSG+="; and device group ${J_SYNC_G} could not be synchronised afterwards (${SYNC_ERR}): check 'tmsh show cm sync-status'"
      warn "device group ${J_SYNC_G} could not be synchronised after the recovery: ${SYNC_ERR}"
    fi
  fi
  peer_mark failed
  lock_release
  mut_end
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
  local rc has5=0 has3=0 has1=0 has6=0 has4=0 has130=0
  for rc in ${RES_RC[@]+"${RES_RC[@]}"}; do
    case "$rc" in
      5) has5=1 ;; 3) has3=1 ;; 1) has1=1 ;; 6) has6=1 ;; 4) has4=1 ;; 130) has130=1 ;;
    esac
  done
  if (( has5 )); then return "${EX_CRITICAL}"; fi
  if (( has3 )); then return "${EX_ROLLED_BACK}"; fi
  if (( has1 )); then return "${EX_ERR}"; fi
  if (( has6 )); then return "${EX_LOCKED}"; fi
  if (( has130 )); then return 130; fi
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
    printf '  %-34s %-14s %s\n' "${RES_JOB[$i]}" "${RES_RESULT[$i]}" "$(printf '%s' "${RES_MSG[$i]}" | tr '\n\t' '  ' | sanitize | cut -c1-160)"
  done
  echo "================================================="
}

run_jobs() {   # run a prepared job list through run_job and record the results
  local j dep f5
  local -a todo=("${JOBS[@]}") deferred=()
  PEER_PASS=0
  while (( ${#todo[@]} > 0 )); do
  for j in "${todo[@]}"; do
    dep="${j%%|*}"; f5="${j##*|}"
    J_RC=0; J_MSG=""; J_RESULT=""
    run_job "$dep" "$f5"
    f5_close
    if [[ "$J_RESULT" == DEFER ]]; then
      # a standby unit: checked after its active unit's job (later in this run)
      deferred+=("$j"); JOB_TAG=""; continue
    fi
    record_result "${dep}@${f5}"
    JOB_TAG=""
    if [[ -n "$SIGNALLED" ]]; then
      warn "stopping: interrupted (SIG${SIGNALLED}); the remaining deployments were not run"
      break
    fi
    if (( FAIL_FAST )) && [[ "${J_RC}" != 0 && "${J_RC}" != "${EX_OUTDATED}" ]]; then
      warn "stopping after the first failure (--fail-fast)"
      deferred=()
      break
    fi
  done
  if [[ -n "$SIGNALLED" ]] || (( PEER_PASS )); then break; fi
  todo=(${deferred[@]+"${deferred[@]}"}); deferred=(); PEER_PASS=1
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

# A virtual server destination as HOST:PORT for a verify line ("" if not usable):
# drops the partition and route domain, and maps the common service names.
dest_hostport() {   # dest_hostport DESTINATION
  local d="${1##*/}" h pt
  if [[ "$d" == *:*:* ]]; then h="${d%.*}"; pt="${d##*.}"      # IPv6: ADDR.PORT
  else h="${d%:*}"; pt="${d##*:}"; fi
  h="${h%%\%*}"
  case "$pt" in https) pt=443 ;; http) pt=80 ;; any|0) return 0 ;; esac
  [[ "$pt" =~ ^[0-9]{1,5}$ ]] || return 0
  if [[ "$h" == *:* ]]; then printf '[%s]:%s' "$h" "$pt"; else printf '%s:%s' "$h" "$pt"; fi
}

# Discovery results, per BIG-IP name: D_SELF, D_FO (failover state), D_VER, and
# rows. D_PAIR is the device-group key that links the units of one pair.
declare -A D_SELF=() D_FO=() D_VER=() D_PAIR=() D_NENT=()
declare -a D_ROWS=() D_VS=() D_CERTS=()

discover_one() {   # discover_one F5NAME   -> prints the report; appends to D_ROWS/D_VS/D_CERTS
  local f5n="$1" out rc=0 tag a b c d e f g key m pa
  JOB_TAG="$f5n"
  f5_load "$f5n"
  J_F5="$f5n"; J_DEP=""
  info "reading ${F5_USER}@${F5_HOST}"
  out="$(f5_sh "${R_PROBE}" "${F5_PART}")" || rc=$?
  if (( rc != 0 )); then err "cannot read ${f5n}: $(remote_err)"; return 1; fi
  parse_sync_lines "$out"
  while IFS='|' read -r tag a b; do
    case "$tag" in VERSION) D_VER[$f5n]="$a" ;; FAILOVER) D_FO[$f5n]="$a" ;; esac
  done <<<"$out"
  D_SELF[$f5n]="$X_SELF"
  echo
  echo "== ${f5n} (${F5_HOST}): ${X_SELF:-unknown device}, BIG-IP ${D_VER[$f5n]:-?}, ${D_FO[$f5n]:-unknown}" | sanitize
  # The sync-failover group this unit shares with others (what a deployment syncs).
  key="standalone|${f5n}"
  local nsf=0
  for g in $(printf '%s\n' "${!DG_TYPE[@]}" | sort); do
    csv_has "$X_SELF" "${DG_MEM[$g]}" || continue
    printf '   device group %-22s %-14s auto-sync %-9s %-16s members: %s\n' "$g" "${DG_TYPE[$g]}" "${DG_AUTO[$g]:-disabled}" "${DG_STAT[$g]:-(status unknown)}" "${DG_MEM[$g]//,/, }" | sanitize
    if [[ "${DG_TYPE[$g]}" == sync-failover && "${DG_MEM[$g]}" == *,* ]]; then
      nsf=$((nsf + 1))
      # shellcheck disable=SC2086   # the member list is split on purpose
      key="${g}|$(printf '%s\n' ${DG_MEM[$g]//,/ } | sort | paste -sd, -)"
    fi
  done
  if (( nsf > 1 )); then
    warn "${f5n} is in ${nsf} sync-failover device groups: set sync_group in its [f5:] section; the draft treats it on its own"
    key="standalone|${f5n}"
  fi
  D_PAIR[$f5n]="$key"

  out="$(f5_sh "${R_DISCOVER}")" || rc=$?
  if (( rc != 0 )); then err "cannot read the profiles on ${f5n}: $(remote_err)"; return 1; fi
  local -A cn=() exp=() fpr=() used=()
  local -a rows=()
  local skipped=0 ca ha ka n_def=0 defs=""
  while IFS='|' read -r tag a b c d e f; do
    case "$tag" in
      CERT)
        ca="$(norm_name "$a")"
        safe_obj "$ca" || continue
        [[ "$b" =~ ^[0-9A-F]{64}$ ]] && fpr[$ca]="$b"
        [[ "$c" =~ ^[0-9]+$ ]] && exp[$ca]="$(hex_to_date "$c")"
        [[ "$d" =~ ^[A-Za-z0-9.*_\ -]{1,100}$ ]] && cn[$ca]="$d"
        D_CERTS+=("${f5n}|${ca}|${fpr[$ca]:-}|${exp[$ca]:-}|${cn[$ca]:-}") ;;
      VS)
        pa="$(norm_name "$a")"
        safe_obj "$pa" || continue
        for m in ${c//,/ }; do
          m="$(norm_name "$m")"; safe_obj "$m" || continue
          used[$m]+="${used[$m]:+, }${pa} ($(dest_hostport "$b"))"
          D_VS+=("${f5n}|${m}|${pa}|$(dest_hostport "$b")")
        done ;;
    esac
  done <<<"$out"
  while IFS='|' read -r tag a b c d e f; do
    [[ "$tag" == DP ]] || continue
    pa="$(norm_name "$a")"; ca="$(norm_name "$c")"; ha="$(norm_name "$d")"; ka="$(norm_name "$e")"
    D_NENT[$f5n|$pa]=$(( ${D_NENT[$f5n|$pa]:-0} + 1 ))
    if ! safe_obj "$pa" || ! is_name "$b" || ! { [[ "$ca" == none ]] || safe_obj "$ca"; } \
       || ! { [[ "$ha" == none ]] || safe_obj "$ha"; } || ! { [[ "$ka" == none ]] || safe_obj "$ka"; }; then
      skipped=$((skipped + 1)); continue
    fi
    if [[ "$ca" == default.crt || "$ca" == none || "$f" == true ]]; then
      n_def=$((n_def + 1)); defs+="${defs:+, }${pa}"; continue
    fi
    rows+=("${pa}|${b}|${ca}|${ha}|${ka}")
    D_ROWS+=("${f5n}|${pa}|${b}|${ca}|${ha}|${ka}")
  done <<<"$out"
  echo
  local r p en cc hh kk
  for r in ${rows[@]+"${rows[@]}"}; do
    IFS='|' read -r p en cc hh kk <<<"$r"
    {
      printf '   profile %s   (entry %s)\n' "$p" "$en"
      printf '      cert   %s   %s, expires %s\n' "$cc" "${cn[$cc]:+CN ${cn[$cc]}}" "${exp[$cc]:-?}"
      printf '      chain  %s\n' "$hh"
      printf '      key    %s\n' "$kk"
      printf '      used by %s\n' "${used[$p]:-(no virtual server)}"
    } | sanitize
  done
  if (( ${#rows[@]} == 0 )); then echo "   (no client-ssl profile with its own certificate)"; fi
  if (( n_def > 0 )); then
    printf '   %d profile entr%s use the default certificate or inherit it, and are not listed: %s\n' "$n_def" "$( (( n_def == 1 )) && printf 'y' || printf 'ies')" "$defs" | sanitize | cut -c1-400
  fi
  if (( skipped > 0 )); then warn "skipped ${skipped} profile entr$( (( skipped == 1 )) && printf 'y' || printf 'ies') whose names contain unexpected characters"; fi
  f5_close
  return 0
}

action_discover() {
  local f5n status=0
  local -a which=()
  if (( ${#SEL_F5[@]} > 0 )); then
    for f5n in "${SEL_F5[@]}"; do [[ -n "${SECT_SEEN[f5:${f5n}]+x}" ]] || usage_die "no such BIG-IP: ${f5n}"; which+=("$f5n"); done
  else
    for f5n in ${F5S[@]+"${F5S[@]}"}; do which+=("$f5n"); done
  fi
  (( ${#which[@]} > 0 )) || usage_die "--discover: the configuration defines no [f5:NAME] section"
  if [[ -n "$WRITE_CONFIG" && -e "$WRITE_CONFIG" ]]; then usage_die "--write-config: ${WRITE_CONFIG} already exists; give a new file name"; fi
  for f5n in "${which[@]}"; do discover_one "$f5n" || status=1; done
  JOB_TAG=""
  echo
  info "use these names in a [deploy:NAME] section as:  profile = PROFILE   (or PROFILE:ENTRY for multi-entry profiles)"
  if [[ -n "$WRITE_CONFIG" ]]; then
    if (( status )); then err "not writing ${WRITE_CONFIG}: a BIG-IP could not be read"; return "${EX_ERR}"; fi
    write_draft_config "$WRITE_CONFIG" "${which[@]}" || return "${EX_ERR}"
  fi
  return "$(( status ? EX_ERR : 0 ))"
}

# A section name from an object name: www-example-cert-20260101-120000.pem -> www-example
draft_base() {   # draft_base OBJECTNAME
  local b="${1##*/}"
  b="${b%.pem}"; b="${b%.crt}"; b="${b%.cer}"
  b="$(printf '%s' "$b" | sed -E 's/-cert(-[0-9]{8}-[0-9]{6})?$//; s/[^A-Za-z0-9._-]+/-/g; s/^[^A-Za-z0-9]+//' | cut -c1-40)"
  printf '%s' "${b:-cert}"
}

# Write the configuration plus suggested [cert:] and [deploy:] sections for every
# profile entry found that no deployment covers yet. One deployment per certificate
# and per pair (all the pair's units listed: the standby is checked after the sync),
# disabled until reviewed.
write_draft_config() {   # write_draft_config FILE F5NAME...
  local file="$1"; shift
  local f5n r src pairkey p en cc hh kk fp nm d covered cnv ex sni hp
  local -A pair_units=() pair_src=() cert_of_fp=() used_names=() vlines=()
  local -a pairs=() body=()
  for f5n in "$@"; do
    pairkey="${D_PAIR[$f5n]}"
    if [[ -z "${pair_units[$pairkey]+x}" ]]; then pairs+=("$pairkey"); pair_units[$pairkey]=""; fi
    pair_units[$pairkey]+="${pair_units[$pairkey]:+, }${f5n}"
    if [[ -z "${pair_src[$pairkey]:-}" || "${D_FO[$f5n]}" == active ]]; then pair_src[$pairkey]="$f5n"; fi
  done
  for d in "${!SECT_SEEN[@]}"; do used_names[$d]=1; done
  for pairkey in "${pairs[@]}"; do
    src="${pair_src[$pairkey]}"
    local -A by_cert=()
    local -a order=()
    for r in ${D_ROWS[@]+"${D_ROWS[@]}"}; do
      IFS='|' read -r f5n p en cc hh kk <<<"$r"
      [[ "$f5n" == "$src" ]] || continue
      # already covered by a deployment for one of this pair's units?
      covered=0
      for d in ${DEPLOYS[@]+"${DEPLOYS[@]}"}; do
        local u
        for u in $(deploy_f5s "$d"); do
          [[ ", ${pair_units[$pairkey]}," == *", ${u},"* ]] || continue
          # a bare profile covers all its entries; PROFILE:ENTRY covers that entry only
          while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            [[ "$(profile_fq "${line%%:*}")" == "$(profile_fq "$p")" ]] || continue
            if [[ "$line" != *:* || "${line#*:}" == "$en" ]]; then covered=1; fi
          done <<<"${CFG[deploy:$d|profile]-}"
        done
      done
      (( covered )) && continue
      if [[ -z "${by_cert[$cc]+x}" ]]; then order+=("$cc"); by_cert[$cc]=""; fi
      by_cert[$cc]+="${p}|${en}"$'\n'
    done
    for cc in ${order[@]+"${order[@]}"}; do
      fp=""; cnv=""; ex=""
      for r in ${D_CERTS[@]+"${D_CERTS[@]}"}; do
        IFS='|' read -r f5n d fp2 ex2 cn2 <<<"$r"
        if [[ "$f5n" == "$src" && "$d" == "$cc" ]]; then fp="$fp2"; ex="$ex2"; cnv="$cn2"; fi
      done
      if [[ -n "$fp" && -n "${cert_of_fp[$fp]:-}" ]]; then
        nm="${cert_of_fp[$fp]}"
      else
        nm="$(draft_base "$cc")"
        local base="$nm" k=2
        while [[ -n "${used_names[cert:$nm]:-}" ]]; do nm="${base}-${k}"; k=$((k + 1)); done
        used_names[cert:$nm]=1
        [[ -n "$fp" ]] && cert_of_fp[$fp]="$nm"
        body+=("" "# Currently on ${src}: ${cc}${cnv:+, CN ${cnv}}${ex:+, expires ${ex}}"
               "# CHANGE the three paths to where you save this certificate's files (section 5 of USER-GUIDE)."
               "[cert:${nm}]"
               "cert          = /path/to/certs/${nm}/cert.pem"
               "chain         = /path/to/certs/${nm}/chain.pem"
               "key           = /path/to/certs/${nm}/privkey.pem"
               "object_prefix = ${nm}")
      fi
      local dn="${nm}-${src}" k=2 pl en2 multi
      while [[ -n "${used_names[deploy:$dn]:-}" ]]; do dn="${nm}-${src}-${k}"; k=$((k + 1)); done
      used_names[deploy:$dn]=1
      body+=("" "# Review, then set enabled = yes. A standby unit listed here is not changed directly:"
             "# it gets the change by config-sync from the active unit, and is then checked.")
      if [[ "$pairkey" != standalone\|* ]]; then
        local mem missing=""
        local members="${pairkey#*|}"
        for mem in ${members//,/ }; do
          local known=0 u2
          for u2 in "$@"; do [[ "${D_SELF[$u2]}" == "$mem" ]] && known=1; done
          (( known )) || missing+="${missing:+, }${mem}"
        done
        if [[ -n "$missing" ]]; then
          body+=("# ${missing}: also in device group ${pairkey%%|*}, but not in this configuration. Add an"
                 "# [f5:] section for it and list it below, so that it is checked after the sync.")
        fi
      fi
      body+=("[deploy:${dn}]" "enabled = no" "f5      = ${pair_units[$pairkey]}" "cert    = ${nm}")
      vlines=()
      while IFS='|' read -r pl en2; do
        [[ -n "$pl" ]] || continue
        # a profile with several entries needs the entry named
        multi="${D_NENT[$src|$pl]:-1}"
        if (( multi > 1 )); then body+=("profile = ${pl#/Common/}:${en2}"); else body+=("profile = ${pl#/Common/}"); fi
        for r in ${D_VS[@]+"${D_VS[@]}"}; do
          IFS='|' read -r f5n d _ hp <<<"$r"
          [[ "$f5n" == "$src" && "$d" == "$pl" && -n "$hp" ]] || continue
          sni=""; [[ "$cnv" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] && sni=" ${cnv}"
          [[ -n "${vlines[$hp]:-}" ]] && continue
          vlines[$hp]=1
          body+=("verify  = ${hp}${sni}")
        done
      done <<<"${by_cert[$cc]}"
    done
    unset by_cert order
  done
  if (( ${#body[@]} == 0 )); then
    info "every profile entry found is already covered by a deployment; not writing ${file}"
    return 0
  fi
  # Written to a new private file beside the target, then hard-linked to the
  # target name: link(2) fails if ANYTHING is there (a file or a symlink planted
  # meanwhile) and never follows it.
  local dir tmp
  dir="$(dirname -- "$file")"
  tmp="$(umask 077; mktemp "${dir}/.f5-cert-push-draft.XXXXXXXX" 2>/dev/null)" || { err "cannot create a file in ${dir}"; return 1; }
  if ! {
      cat -- "$CONFIG_FILE"
      echo
      echo "############################################################################"
      echo "# Suggested by ${PROG} --discover on $(date -u '+%Y-%m-%d %H:%M UTC')"
      echo "# for every client-ssl profile entry that no deployment covered yet."
      echo "############################################################################"
      printf '%s\n' "${body[@]}"
    } > "$tmp"; then
    rm -f -- "$tmp"; err "cannot write ${file}"; return 1
  fi
  if ! ln -- "$tmp" "$file" 2>/dev/null; then
    rm -f -- "$tmp"; err "not writing ${file}: something already exists at that name"; return 1
  fi
  rm -f -- "$tmp"
  ok "wrote ${file}: your configuration plus the suggested sections. Edit the certificate paths, review each deployment, set enabled = yes, then: ${PROG} --config ${file} --validate"
  return 0
}

action_list_backups() {
  local j dep f5 out tag a b rc status=0
  for j in "${JOBS[@]}"; do
    dep="${j%%|*}"; f5="${j##*|}"
    JOB_TAG="${dep}@${f5}"
    f5_load "$f5"
    local prefix root
    prefix="$(cert_prefix "${CFG[deploy:${dep}|cert]}")"
    root="$(eff backup_dir_remote "deploy:${dep}" "f5:${f5}")/${prefix}"
    info "backup sets on ${F5_HOST}:${root}"
    rc=0
    out="$(f5_sh "${R_LISTB}" "$root")" || rc=$?
    if (( rc != 0 )); then err "cannot list: $(remote_err)"; status="${EX_ERR}"; f5_close; continue; fi
    while IFS='|' read -r tag a b; do
      if [[ "$tag" == SET && "$a" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then info "  ${a}  (${b} files)"; fi
    done <<<"$out"
    f5_close
    info "local copies in $(eff backup_dir_local)/${f5}/${prefix}:"
    ls -1 "$(eff backup_dir_local)/${f5}/${prefix}" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sed 's/^/  /' || true
  done
  JOB_TAG=""
  return "$status"
}

# Restore needs only the target configuration and the backup set: never the new
# certificate (which may be missing, expired or the very thing being undone).
job_init_restore() {   # job_init_restore DEPLOY F5NAME SET
  local d="$1" f="$2" sd="deploy:$1"
  J_DEP="$d"; J_F5="$f"
  J_CERT="${CFG[$sd|cert]}"
  J_PREFIX="$(cert_prefix "$J_CERT")"
  J_AUTOROLL=no; J_FIXED=no; J_FP=""; J_MODE=restore
  J_RC=0; J_MSG=""; J_RESULT=""; J_CHANGED=0; J_UNKNOWN=0
  J_PROF=(); J_VERIFY=(); J_TARGETS=(); J_CREATED=()
  f5_load "$f"
  J_PART="$F5_PART"
  J_TS="$3"
  J_BDIR_R="$(eff backup_dir_remote "$sd" "f5:${f}")/${J_PREFIX}/${J_TS}"
  J_BDIR_L="$(eff backup_dir_local)/${f}/${J_PREFIX}/${J_TS}"
}

# Copy backup set J_BDIR_R from the BIG-IP into the scratch directory and check it
# (the copy that will actually be applied is the one on the BIG-IP).
fetch_backup_set() {   # fetch_backup_set LOCALDIR
  local dst="$1" out rc=0 tag a f n=0
  out="$(f5_sh "${R_LISTFILES}" "${J_BDIR_R}")" || rc=$?
  if (( rc != 0 )); then VB_ERR="cannot list the backup set on the BIG-IP: $(remote_err)"; return 1; fi
  if [[ "$out" == NODIR ]]; then VB_ERR="there is no backup set ${J_TS} on the BIG-IP (${J_BDIR_R})"; return 1; fi
  mkdir -m 700 -- "$dst" || { VB_ERR="cannot create ${dst}"; return 1; }
  local -a names=()
  while IFS='|' read -r tag a; do
    case "$tag" in
      FILE)
        [[ "$a" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { VB_ERR="the backup set contains an unexpected file name"; return 1; }
        names+=("$a") ;;
      OTHER) VB_ERR="the backup set contains something that is not a regular file"; return 1 ;;
    esac
  done <<<"$out"
  (( ${#names[@]} > 0 )) || { VB_ERR="the backup set ${J_TS} is empty"; return 1; }
  for f in "${names[@]}"; do
    f5_get "${J_BDIR_R}/${f}" "${dst}/${f}" || { VB_ERR="cannot copy ${f} from the BIG-IP: $(remote_err)"; return 1; }
    n=$((n + 1))
  done
  return 0
}

action_rollback() {
  local j dep f5 rc d vrc
  [[ "$ROLLBACK_SET" =~ ^[0-9]{8}-[0-9]{6}$ ]] || usage_die "--set must look like 20260930-162806 (see --list-backups)"
  for j in "${JOBS[@]}"; do
    dep="${j%%|*}"; f5="${j##*|}"
    JOB_TAG="${dep}@${f5}"
    job_init_restore "$dep" "$f5" "$ROLLBACK_SET"
    job_lock; rc=$?
    if (( rc == 2 )); then J_RC="${EX_LOCKED}"; J_RESULT=LOCKED; J_MSG="another run holds the lock for ${F5_HOST}"; record_result "$JOB_TAG"; continue; fi
    if (( rc != 0 )); then J_RC="${EX_ERR}"; J_RESULT=FAILED; J_MSG="cannot take the lock"; record_result "$JOB_TAG"; continue; fi
    if ! job_probe; then J_RESULT=FAILED; lock_release; f5_close; record_result "$JOB_TAG"; continue; fi
    if [[ "$X_FAILOVER" == standby && "$(eff_bool allow_standby "f5:${f5}")" != yes && "$(eff sync "deploy:${dep}" "f5:${f5}")" != no ]]; then
      J_RC=0; J_RESULT=SKIPPED; J_MSG="standby; receives the rollback by config-sync from its active unit"
      info "${J_MSG}"; lock_release; f5_close; record_result "$JOB_TAG"; continue
    fi
    if ! { job_gate && sync_select; }; then J_RESULT=FAILED; lock_release; f5_close; record_result "$JOB_TAG"; continue; fi
    local pre_ok=0
    if [[ -n "$J_SYNC_G" ]] && sync_baseline; then pre_ok=1; fi
    d="${WORK}/restore.${f5}.${J_PREFIX}.${J_TS}"
    if ! fetch_backup_set "$d" || ! verify_backup_set "$d" "$J_TS"; then
      job_fail "${EX_ERR}" "backup set ${J_TS} cannot be used: ${VB_ERR}. Nothing was changed."
      J_RESULT=FAILED; lock_release; f5_close; record_result "$JOB_TAG"; continue
    fi
    if (( INV_LEGACY )); then warn "backup set ${J_TS} was written by version 2.0.0: its restore script is not covered by its checksums; its contents were read from the script itself"; fi
    warn "restoring the state captured before run ${J_TS} ($(( ${#INV_BIND[@]} )) profile entr$( (( ${#INV_BIND[@]} == 1 )) && printf 'y' || printf 'ies'), $(( ${#INV_OBJ[@]} + ${#INV_ABSENT[@]} )) object(s))"
    RV_DIR="$d"
    J_CHANGED=1
    vrc=0
    mut_begin
    restore_and_verify || vrc=$?
    mut_end
    if (( vrc == 0 )); then
      J_CHANGED=0; J_RC=0; J_RESULT=RESTORED; J_MSG="restored the state before ${J_TS} (verified)"; ok "${J_MSG}"
      if [[ -n "$J_SYNC_G" ]]; then
        local src=0
        if (( ! pre_ok )); then
          J_MSG+="; NOT synchronised: device group ${J_SYNC_G} was not In Sync (with the same commit on every member) before the rollback, so syncing could copy other changes. Check it and sync it yourself"
          warn "device group ${J_SYNC_G} was not In Sync before the rollback; not synchronising it"
        else
          job_sync ifneeded || src=$?
          if (( src == 0 )); then
            J_MSG+="; synchronised to $(sync_peers)"
          elif (( src == 2 )); then
            J_RC="${EX_CRITICAL}"; J_RESULT=CRITICAL; REMOTE_LOCK_KEEP=1
            J_MSG+="; but the config-sync did not report its outcome (${SYNC_ERR}). The BIG-IP lock is left in place; check 'tmsh show cm sync-status'"
            err "${J_MSG}"
          else
            J_RC="${EX_ERR}"; J_RESULT=NOT_SYNCED
            J_MSG+="; but NOT synchronised: ${SYNC_ERR}. On this unit run 'tmsh run cm config-sync to-group ${J_SYNC_G}'"
            err "${J_MSG}"
          fi
        fi
      fi
    elif (( vrc == 10 )); then
      J_CHANGED=0; J_RC="${EX_ERR}"; J_RESULT=FAILED; J_MSG="the backup on the BIG-IP failed its integrity check; nothing was changed"
    else
      J_RC="${EX_CRITICAL}"; J_RESULT=CRITICAL; REMOTE_LOCK_KEEP=1
      J_MSG="the restore of ${J_TS} could not be confirmed: the BIG-IP may be partly restored. Check it (--check) and retry"
      err "${J_MSG}"
    fi
    J_CHANGED=0     # reported; a later signal must not try to "recover" it
    lock_release
    f5_close
    record_result "$JOB_TAG"
    if [[ -n "$SIGNALLED" ]]; then warn "stopping: interrupted (SIG${SIGNALLED})"; break; fi
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
      --write-config) need_value "$1" $# "${2:-}"; WRITE_CONFIG="$2"; shift 2 ;;
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
  for t in ssh openssl awk sed grep timeout sha256sum mktemp stat date tr cut sort head find id wc cat cmp paste; do
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
  # Interrupted, and nothing worse to report: say so.
  if [[ -n "$SIGNALLED" ]] && (( rc == 0 || rc == EX_OUTDATED )); then rc=130; fi
  exit "$rc"
}

main "$@"
