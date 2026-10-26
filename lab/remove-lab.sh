#!/usr/bin/env bash
# remove-lab.sh - remove every f5-cert-push lab item from a BIG-IP (or an HA pair).
#
# Safe to run at any point of the lab, including after quitting half way: it looks for
# everything the lab can have created, whoever created it (build-lab.sh, or
# f5-cert-push while following docs/LAB.md), and removes what it finds:
#
#   on the ACTIVE unit (the configuration; synchronised to the peers afterwards):
#     - virtual servers named lab-*            - client-ssl profiles named lab-*
#     - certificates and keys named lab-*      (the lab's own, and every version
#                                                f5-cert-push installed: lab-*-cert-<time>.pem ...)
#   on EVERY unit given (files, not part of the synchronised configuration):
#     - backup sets /shared/cert-backups/lab-*
#     - the lab trainee's SSH key: authorized_keys lines whose comment is f5-cert-push-lab
#     - with --remove-stale: f5-cert-push staging directories older than 2 hours, and a
#       f5-cert-push lock on the BIG-IP (only use it when no f5-cert-push run is going on)
#   on this machine, with --local DIR: the lab directory build-lab.sh made
#
# It reports, and leaves alone, anything outside the lab that still uses a lab item
# (for example a lab certificate attached to one of your own profiles).
#
#   ./remove-lab.sh --host 192.0.2.10 [--peer 192.0.2.11] [--key FILE] [--dry-run]
#
# Options:
#   --host H        a unit of the BIG-IP / pair (if it is the standby and --peer is the
#                   active unit, they are swapped)                        (required)
#   --peer H        the other unit(s) of the pair (repeatable): their files are cleaned too
#   --user U        SSH user (default root)       --port P   SSH port (default 22)
#   --key FILE      SSH private key
#   --prefix P      lab object prefix (default lab)
#   --key-comment C comment of the trainee's SSH key to remove (default f5-cert-push-lab;
#                   --key-comment '' keeps every key)
#   --sync          synchronise the device group afterwards even if it was not In Sync
#                   before (normally it is only synchronised if it was)
#   --remove-stale  also remove stale f5-cert-push staging directories and lock (see above)
#   --local DIR     also delete the local lab directory (only if it holds lab-info.txt)
#   --dry-run       show what would be removed; change nothing
#   --yes           do not ask for confirmation
set -euo pipefail

VERSION="2.2.2"
HOST="" PORT=22 BUSER=root KEY="" PREFIX=lab KCOMMENT="f5-cert-push-lab" FORCESYNC=0 STALE=0 LOCAL="" DRY=0 YES=0
declare -a PEERS=()

die()  { printf 'remove-lab: %s\n' "$*" >&2; exit 1; }
info() { printf '[*] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while (( $# )); do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    --peer) PEERS+=("${2:?}"); shift 2 ;;
    --user) BUSER="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --key)  KEY="${2:?}"; shift 2 ;;
    --prefix) PREFIX="${2:?}"; shift 2 ;;
    --key-comment) KCOMMENT="${2-}"; shift 2 ;;
    --sync) FORCESYNC=1; shift ;;
    --remove-stale) STALE=1; shift ;;
    --local) LOCAL="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) usage 0 ;;
    --version) echo "remove-lab $VERSION"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
[[ -n "$HOST" ]] || { warn "--host is required"; usage 1; }
for h in "$HOST" ${PEERS[@]+"${PEERS[@]}"}; do [[ "$h" =~ ^[A-Za-z0-9][A-Za-z0-9.:_-]*$ ]] || die "not a host name or address: $h"; done
[[ "$PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9_]{0,15}$ ]] || die "--prefix: letters, digits and _ only"
[[ -z "$KCOMMENT" || "$KCOMMENT" =~ ^[A-Za-z0-9][A-Za-z0-9@._-]{2,63}$ ]] || die "--key-comment: letters, digits and @ . _ - only"
[[ "$BUSER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "--user: not a plain account name"
command -v ssh >/dev/null || die "ssh not found"

CMD="$(mktemp -d "${TMPDIR:-/tmp}/remove-lab.XXXXXXXX")"; chmod 700 "$CMD"
ALL=("$HOST" ${PEERS[@]+"${PEERS[@]}"})
cleanup() { local h; for h in "${ALL[@]}"; do ssh -o ControlPath="$CMD/cm-$h" -O exit "$BUSER@$h" >/dev/null 2>&1 || true; done; rm -rf "$CMD"; }
trap cleanup EXIT
on() {   # on HOST COMMAND...   (one SSH connection per unit)
  local h="$1"; shift
  local -a o=(-p "$PORT" -o ControlMaster=auto -o ControlPath="$CMD/cm-$h" -o ControlPersist=600 -o ConnectTimeout=15 -o LogLevel=ERROR)
  [[ -n "$KEY" ]] && o+=(-i "$KEY" -o IdentitiesOnly=yes)
  ssh "${o[@]}" "$BUSER@$h" "$@"
}
for h in "${ALL[@]}"; do on "$h" true || die "cannot log in to $BUSER@$h over SSH"; done

state() { on "$1" "tmsh -q show sys failover 2>/dev/null | head -1 | awk '{print tolower(\$2)}'"; }
ACTIVE="$HOST"
if [[ "$(state "$HOST")" != active ]]; then
  ACTIVE=""
  for h in ${PEERS[@]+"${PEERS[@]}"}; do [[ "$(state "$h")" == active ]] && ACTIVE="$h"; done
  [[ -n "$ACTIVE" ]] || die "$HOST is not active, and no --peer is: give the active unit (the configuration is removed there and synchronised)"
  info "$HOST is standby; using the active unit $ACTIVE for the configuration"
fi

# ---- inventory --------------------------------------------------------------------
# The configuration, on the active unit. One line per item: KIND|NAME|DETAIL
INV="$(on "$ACTIVE" 'bash -s' -- "$PREFIX" <<'EOF'
P="$1-"
names() { tmsh -q list $1 one-line 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "{") { print $(i-1); break }}'; }
for v in $(names "ltm virtual"); do
  prof="$(tmsh -q list ltm virtual "$v" profiles 2>/dev/null | awk '/^        [^ ]+ \{/ {print $1}' | paste -sd, -)"
  case "$v" in "$P"*) echo "VS|$v|$prof" ;;
    *) for p in ${prof//,/ }; do case "$p" in "$P"*) echo "OTHERVS|$v|$p" ;; esac; done ;;
  esac
done
for p in $(names "ltm profile client-ssl"); do
  objs="$(tmsh -q list ltm profile client-ssl "$p" cert-key-chain 2>/dev/null | awk '$1 == "cert" || $1 == "key" || $1 == "chain" {print $2}' | sed 's#^/Common/##' | sort -u | paste -sd, -)"
  case "$p" in "$P"*) echo "PROFILE|$p|$objs" ;;
    *) for o in ${objs//,/ }; do case "$o" in "$P"*) echo "OTHERPROF|$p|$o" ;; esac; done ;;
  esac
done
for c in $(names "sys file ssl-cert"); do case "$c" in "$P"*) echo "CERT|$c|" ;; esac; done
for k in $(names "sys file ssl-key"); do case "$k" in "$P"*) echo "KEY|$k|" ;; esac; done
self="$(tmsh -q list cm device one-line 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "self-device" && $(i+1) == "true") { print $3; exit }}')"
for g in $(tmsh -q list cm device-group one-line 2>/dev/null | awk '$1 == "cm" && $2 == "device-group" {print $3}'); do
  tmsh -q list cm device-group "$g" devices type 2>/dev/null | awk -v G="$g" -v S="$self" '
    $1 == "type" { t = $2 }
    /^    devices \{/ { d = 1; next }
    d && /^    \}/ { d = 0; next }
    d && /^        [^ ]+ \{ \}$/ { m = m (m == "" ? "" : ",") $1 }
    END { if (t == "sync-failover" && ("," m ",") ~ ("," S ",") && m ~ /,/) print "GROUP|" G "|" m }'
done
tmsh -q show cm sync-status field-fmt 2>/dev/null | sed -n 's/^ *details\.[0-9]*\.details \([^ ]*\) (\([^)]*\)): .*/GSTAT|\1|\2/p'
EOF
)" || die "cannot read the configuration on $ACTIVE"

# The files, on every unit. One line per item: KIND|HOST|NAME|DETAIL
files_on() {   # files_on HOST
  on "$1" 'bash -s' -- "$PREFIX" "$KCOMMENT" <<'EOF' | sed "s/^\([A-Z]*\)|/\1|$1|/"
P="$1-"; C="$2"
for d in /shared/cert-backups/"$P"*; do [ -d "$d" ] && echo "BACKUP|$d|$(ls -1 "$d" | wc -l) set(s)"; done
if [ -n "$C" ] && [ -f /var/ssh/root/authorized_keys ]; then
  n="$(awk -v c="$C" '$NF == c' /var/ssh/root/authorized_keys | wc -l)"
  [ "$n" -gt 0 ] && echo "SSHKEY|/var/ssh/root/authorized_keys|$n line(s) with comment $C"
fi
for d in /var/tmp/f5-cert-push.*; do
  [ -d "$d" ] || continue
  if [ -n "$(find "$d" -maxdepth 0 -mmin +120)" ]; then echo "STAGE|$d|older than 2 hours"; else echo "STAGENEW|$d|recent: a run may be using it"; fi
done
[ -d /var/run/f5-cert-push.lock ] && echo "LOCK|/var/run/f5-cert-push.lock|$(cat /var/run/f5-cert-push.lock/owner 2>/dev/null | head -1)"
exit 0
EOF
}
FILES=""
for h in "${ALL[@]}"; do FILES+="$(files_on "$h")"$'\n'; done

count() { printf '%s\n' "$1" | grep -c "^$2|" || true; }
GROUP="$(printf '%s\n' "$INV" | awk -F'|' '$1 == "GROUP" {print $2; exit}')"
GMEM="$(printf '%s\n' "$INV" | awk -F'|' '$1 == "GROUP" {print $3; exit}')"
GPRE=""; [[ -n "$GROUP" ]] && GPRE="$(printf '%s\n' "$INV" | awk -F'|' -v g="$GROUP" '$1 == "GSTAT" && $2 == g {print $3; exit}')"

echo
echo "Lab items (prefix ${PREFIX}-) found:"
echo "  on the active unit $ACTIVE (configuration${GROUP:+, synchronised in $GROUP: ${GPRE:-unknown}}):"
printf '    %-28s %s\n' "virtual servers" "$(count "$INV" VS)" "client-ssl profiles" "$(count "$INV" PROFILE)" \
  "certificates" "$(count "$INV" CERT)" "keys" "$(count "$INV" KEY)"
printf '%s\n' "$INV" | awk -F'|' '$1 == "VS" || $1 == "PROFILE" {printf "      %-8s %s\n", tolower($1), $2}'
for h in "${ALL[@]}"; do
  echo "  files on $h:"
  printf '%s\n' "$FILES" | awk -F'|' -v h="$h" '$2 == h && $1 != "" {printf "      %-8s %s  (%s)\n", tolower($1), $3, $4}'
done
BLOCK="$(printf '%s\n' "$INV" | grep -E '^(OTHERVS|OTHERPROF)\|' || true)"
if [[ -n "$BLOCK" ]]; then
  echo
  warn "used OUTSIDE the lab (left alone, and keeps the lab item it uses):"
  printf '%s\n' "$BLOCK" | awk -F'|' '
    $1 == "OTHERVS"   {printf "      virtual server %s uses lab profile %s\n", $2, $3}
    $1 == "OTHERPROF" {printf "      profile %s uses lab object %s\n", $2, $3}' >&2
fi
if [[ -n "$GROUP" ]]; then
  if (( ${#PEERS[@]} == 0 )); then
    warn "$ACTIVE is in device group $GROUP ($GMEM): give the other unit(s) with --peer to clean their files (backups, SSH key) too"
  fi
fi
printf '%s\n' "$FILES" | grep -q '^STAGENEW|' && warn "a recent f5-cert-push staging directory exists: is a run going on? (not removed)"
if printf '%s\n' "$FILES" | grep -qE '^(STAGE|LOCK)\|' && (( ! STALE )); then
  warn "stale f5-cert-push staging directories or a lock exist (listed above): not removed without --remove-stale"
fi
if [[ -n "$LOCAL" ]]; then
  if [[ -f "$LOCAL/lab-info.txt" ]]; then echo "  local: $LOCAL (the lab directory)"; else die "--local $LOCAL: not a lab directory (no lab-info.txt); not touching it"; fi
fi

TOTAL=$(( $(count "$INV" VS) + $(count "$INV" PROFILE) + $(count "$INV" CERT) + $(count "$INV" KEY) ))
NF=$(printf '%s\n' "$FILES" | grep -cE '^(BACKUP|SSHKEY)\|' || true)
(( STALE )) && NF=$(( NF + $(printf '%s\n' "$FILES" | grep -cE '^(STAGE|LOCK)\|' || true) ))
echo
if (( TOTAL == 0 && NF == 0 )) && [[ -z "$LOCAL" ]]; then ok "no lab items found: nothing to do"; exit 0; fi
if (( DRY )); then info "dry run: nothing was changed"; exit 0; fi
if (( ! YES )); then
  read -r -p "Remove these lab items? [y/N] " a
  [[ "$a" == [yY]* ]] || die "cancelled; nothing was changed"
fi

# ---- removal: the configuration, on the active unit -----------------------------------
if (( TOTAL > 0 )); then
  info "removing the lab configuration on $ACTIVE"
  on "$ACTIVE" 'bash -s' -- "$PREFIX" <<'EOF' || warn "some items could not be removed (see above)"
P="$1-"; rc=0
names() { tmsh -q list $1 one-line 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "{") { print $(i-1); break }}' | grep "^$P"; }
del() { out="$(tmsh delete "$@" 2>&1)" || { echo "    could not delete $*: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; rc=1; }; }
for v in $(names "ltm virtual"); do del ltm virtual "$v"; done
for p in $(names "ltm profile client-ssl"); do del ltm profile client-ssl "$p"; done
for c in $(names "sys file ssl-cert"); do del sys crypto cert "$c"; done
for k in $(names "sys file ssl-key"); do del sys crypto key "$k"; done
tmsh save sys config >/dev/null || { echo "    tmsh save sys config failed"; rc=1; }
exit "$rc"
EOF
fi

# ---- removal: files, on every unit ------------------------------------------------------
for h in "${ALL[@]}"; do
  on "$h" 'bash -s' -- "$PREFIX" "$KCOMMENT" "$STALE" <<'EOF' || warn "cleaning files on $h failed"
P="$1-"; C="$2"; S="$3"
rm -rf /shared/cert-backups/"$P"*
if [ -n "$C" ] && [ -f /var/ssh/root/authorized_keys ] && awk -v c="$C" '$NF == c {f = 1} END {exit !f}' /var/ssh/root/authorized_keys; then
  # rewrite in place (keeps the file's owner, mode and SELinux label)
  t="$(mktemp)"; awk -v c="$C" '$NF != c' /var/ssh/root/authorized_keys > "$t" && cat "$t" > /var/ssh/root/authorized_keys; rm -f "$t"
fi
if [ "$S" = 1 ]; then
  find /var/tmp -maxdepth 1 -type d -name 'f5-cert-push.*' -mmin +120 -exec rm -rf -- {} + 2>/dev/null
  rm -rf /var/run/f5-cert-push.lock
fi
exit 0
EOF
done

# ---- synchronise ------------------------------------------------------------------------------
if [[ -n "$GROUP" ]] && (( TOTAL > 0 )); then
  if [[ "$GPRE" == "In Sync" || "$FORCESYNC" == 1 ]]; then
    info "synchronising device group $GROUP"
    on "$ACTIVE" "tmsh run cm config-sync to-group $GROUP" || warn "config-sync to $GROUP failed"
    st=""
    for _ in $(seq 1 40); do
      st="$(on "$ACTIVE" 'tmsh -q show cm sync-status field-fmt' | sed -n "s/^ *details\.[0-9]*\.details $GROUP (\([^)]*\)).*/\1/p")"
      [[ "$st" == "In Sync" ]] && break; sleep 3
    done
    [[ "$st" == "In Sync" ]] && ok "device group $GROUP is In Sync" || warn "device group $GROUP is '${st:-unknown}': check it on the BIG-IP"
  else
    warn "device group $GROUP was '${GPRE:-unknown}' before the removal, so it was NOT synchronised (that would also copy whatever else is pending). Check it, then sync it yourself, or rerun with --sync"
  fi
fi

# ---- check -------------------------------------------------------------------------------
left="$(on "$ACTIVE" 'bash -s' -- "$PREFIX" <<'EOF'
P="$1-"; n=0
for k in "ltm virtual" "ltm profile client-ssl" "sys file ssl-cert" "sys file ssl-key"; do
  c="$(tmsh -q list $k one-line 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "{") { print $(i-1); break }}' | grep -c "^$P")"; n=$((n + c))
done
echo "$n"
EOF
)"
fl=0
for h in "${ALL[@]}"; do
  c="$(files_on "$h" | grep -cE '^(BACKUP|SSHKEY)\|' || true)"; fl=$((fl + c))
done
if [[ -n "$LOCAL" ]]; then rm -rf -- "$LOCAL" && ok "removed the local lab directory $LOCAL"; fi
if (( ${left:-1} == 0 && fl == 0 )); then
  ok "all lab items are gone"
else
  warn "${left:-?} lab configuration item(s) and $fl lab file item(s) remain (see the messages above)"
  exit 1
fi
