#!/usr/bin/env bash
# build-lab.sh - build the f5-cert-push training lab on a BIG-IP (or an HA pair).
#
# Run it on any Linux machine that can reach the BIG-IPs' management addresses over SSH
# as root (key or password; with a password you are asked once per unit). Without
# --host it asks for the management IPs of the active and the standby unit. It:
#
#   1. shows each unit's SSH host key fingerprint and, once you confirm it matches the
#      one the BIG-IP shows on its console, pins it in ~/.ssh/known_hosts; only then
#      logs in, and checks the BIG-IP: active, configuration loaded, no lab items yet,
#      and (for an HA pair) its sync-failover device group In Sync, with --peer the
#      other member of it;
#   2. sets up the SSH key f5-cert-push will use: creates ~/.ssh/f5_push_ecdsa (comment
#      f5-cert-push-lab) unless it exists, authorises it for root on every unit, and
#      tests a login with it;
#   3. makes a throwaway lab CA and certificates on THIS machine, in --out DIR;
#   4. installs the "current" certificates on the BIG-IP, creates three client-ssl
#      profiles (one holding an RSA and an ECDSA certificate) and three virtual servers,
#      plus two certificates that no profile uses;
#   5. synchronises the device group (HA pair) and checks what each virtual server serves;
#   6. leaves the "renewed" certificates for the trainee in DIR/received/, the way a CA
#      delivers them (one of them as a .pfx), plus some bad ones in DIR/received/bad/,
#      and DIR/lab-env.sh, which sets A, B and VS1-VS3 for the guide's commands.
#
# Everything it creates on the BIG-IP is named lab-* (and everything f5-cert-push creates
# during the lab is too). Remove it all, the tool's key included, with
# remove-lab.sh --cleanup, even half way through. It creates no f5-cert-push configuration: that is the
# trainee's job (docs/LAB.md).
#
#   ./build-lab.sh                                  (asks for the addresses)
#   ./build-lab.sh --host 192.0.2.10 --peer 192.0.2.11 [--key ~/.ssh/admin_key]
#
# Options:
#   --host H          the BIG-IP (for a pair: the ACTIVE unit)   (asked for if not given)
#   --peer H          the other unit of an HA pair (the standby); the tool's key is
#                     authorised there too                       (asked for with --host)
#   --host-fp FP      the expected host key fingerprint (SHA256:...) of a unit, as the
#                     BIG-IP shows it (ssh-keygen -lf /config/ssh/ssh_host_ecdsa_key.pub);
#                     repeatable. A new host key that matches one is not asked about;
#                     with --yes, every new host key must match one
#   --tool-key FILE   the key f5-cert-push will use (default ~/.ssh/f5_push_ecdsa;
#                     created if missing, and must have the comment f5-cert-push-lab)
#   --user U          SSH user (default root: tmsh and the filestore are needed)
#   --port P          SSH port (default 22)
#   --key FILE        YOUR SSH private key for root (default: your ssh defaults, or
#                     a password)
#   --out DIR         where to put the lab CA and the trainee's certificates
#                     (default ~/f5-cert-push-lab; must not exist yet)
#   --vs-ips A,B,C    three unused addresses for the virtual servers (default: .201-.203,
#                     or the next free ones, in the subnet of the BIG-IP's first IPv4
#                     self IP, which must be a /24 for the automatic choice)
#   --no-sync         do not synchronise an HA pair (objects stay on this unit only)
#   --yes             do not ask for confirmation (then --host is required)
#   -h, --help        this help
set -euo pipefail

VERSION="2.2.3"
HM="${HOME:-$(cd ~ 2>/dev/null && pwd || echo .)}"
HOST="" PEER="" PORT=22 BUSER=root KEY="" OUT="$HM/f5-cert-push-lab" VSIPS="" DOSYNC=1 YES=0
TKEY="$HM/.ssh/f5_push_ecdsa" TCOMMENT="f5-cert-push-lab"
declare -a HOSTFP=()

die()  { printf 'build-lab: %s\n' "$*" >&2; exit 1; }
info() { printf '[*] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while (( $# )); do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    --peer) PEER="${2:?}"; shift 2 ;;
    --tool-key) TKEY="${2:?}"; shift 2 ;;
    --host-fp) HOSTFP+=("${2:?}"); shift 2 ;;
    --user) BUSER="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --key)  KEY="${2:?}"; shift 2 ;;
    --out)  OUT="${2:?}"; shift 2 ;;
    --vs-ips) VSIPS="${2:?}"; shift 2 ;;
    --no-sync) DOSYNC=0; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) usage 0 ;;
    --version) echo "build-lab $VERSION"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
for t in ssh ssh-keygen ssh-keyscan openssl awk sed mktemp; do command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"; done
REPLACE=0
if [[ -e "$OUT" ]]; then
  # Say what is there; offer to replace it only if build-lab.sh made it.
  echo "$OUT already exists:"
  if [[ -f "$OUT/lab-info.txt" ]]; then
    sed -n '1,3s/^/    /p' "$OUT/lab-info.txt"
    mine=1
  elif [[ -f "$OUT/pki/ca.cnf" ]]; then
    echo "    a lab build that stopped half way (lab CA made, no lab-info.txt)"
    mine=1
  else
    echo "    NOT made by build-lab.sh"
    mine=0
  fi
  echo "    contents: $(ls -A "$OUT" 2>/dev/null | head -12 | paste -sd' ' -)$( (( $(ls -A "$OUT" 2>/dev/null | wc -l) > 12 )) && printf ' ...')"
  echo "    size:     $(du -sh "$OUT" 2>/dev/null | cut -f1)"
  (( mine )) && echo "  If that lab may still be on a BIG-IP, remove it there too:  ./lab/remove-lab.sh --cleanup"
  echo "  To delete only this directory yourself:  rm -rf $OUT"
  (( mine )) || die "not replacing a directory build-lab.sh did not make: check it, delete or move it yourself, or give another --out"
  (( ! YES )) || die "not replacing it with --yes: remove it first, or give another --out"
  read -r -p "Delete it and build a new lab there? (it is deleted only once you confirm the build) [y/N] " a || a=""
  [[ "$a" == [yY]* ]] || die "left as it is; nothing was changed"
  REPLACE=1
fi
# The tool's key: reused if it is the lab key, created later (after the confirmation) if missing.
if [[ -e "$TKEY" ]]; then
  [[ -f "$TKEY.pub" ]] || die "$TKEY exists but $TKEY.pub does not: give --tool-key FILE for another file"
  [[ "$(awk '{print $NF; exit}' "$TKEY.pub")" == "$TCOMMENT" ]] \
    || die "$TKEY exists but is not the lab's key (its comment is not $TCOMMENT): give --tool-key FILE for another file"
  TACT="existing"
else
  TACT="new"
fi
if [[ -z "$HOST" ]]; then
  (( ! YES )) || die "--host is required with --yes"
  read -r -p "Management IP of the ACTIVE BIG-IP: " HOST || HOST=""
  [[ -n "$HOST" ]] || die "no address given; nothing was changed"
  if [[ -z "$PEER" ]]; then
    read -r -p "Management IP of the STANDBY BIG-IP (press Enter for a standalone BIG-IP): " PEER || PEER=""
  fi
fi
[[ "$HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.:_-]*$ ]] || die "--host: not a host name or address: $HOST"
[[ -z "$PEER" || "$PEER" =~ ^[A-Za-z0-9][A-Za-z0-9.:_-]*$ ]] || die "--peer: not a host name or address: $PEER"
[[ "$PEER" != "$HOST" ]] || die "--peer is the same address as --host"
[[ "$BUSER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "--user: not a plain account name"
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "--port: not a port number"
UNITS=("$HOST"); [[ -n "$PEER" ]] && UNITS+=("$PEER")

# One SSH connection per unit for everything (a password, if needed, is asked for once per unit).
CMD="$(mktemp -d "${TMPDIR:-/tmp}/build-lab.XXXXXXXX")"; chmod 700 "$CMD"
cleanup() {
  local h
  for h in "${UNITS[@]}"; do ssh -o ControlPath="$CMD/cm-$h" -O exit "$BUSER@$h" >/dev/null 2>&1 || true; done
  rm -rf "$CMD"
}
trap cleanup EXIT
SSHO=(-p "$PORT" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$HM/.ssh/known_hosts" -o ControlMaster=auto -o ControlPersist=600 -o ConnectTimeout=15 -o LogLevel=ERROR)
[[ -n "$KEY" ]] && SSHO+=(-i "$KEY" -o IdentitiesOnly=yes)
on() { local h="$1"; shift; ssh "${SSHO[@]}" -o ControlPath="$CMD/cm-$h" "$BUSER@$h" "$@"; }
f5() { on "$HOST" "$@"; }

# Host keys: before any login (a password must only go to the real BIG-IP), each unit's
# key must already be in ~/.ssh/known_hosts, or you confirm its fingerprint (or give it
# with --host-fp) and it is pinned there, as docs/LAB.md describes doing by hand.
KH="$HM/.ssh/known_hosts"
declare -A HKFP=() HKLINE=()
NEWK=()
for h in "${UNITS[@]}"; do
  kn="$h"; [[ "$PORT" == 22 ]] || kn="[$h]:$PORT"
  k="$(ssh-keyscan -T 10 -p "$PORT" -t ecdsa "$h" 2>/dev/null | grep -v '^#')" || k=""
  [[ -n "$k" ]] || die "$h: no answer on TCP $PORT (check the address, and that this machine can reach it); nothing was changed"
  HKFP[$h]="$(ssh-keygen -lf <(printf '%s
' "$k") | awk '{print $2; exit}')"
  blob="$(printf '%s
' "$k" | awk '{print $3; exit}')"
  if [[ -f "$KH" ]] && ssh-keygen -F "$kn" -f "$KH" 2>/dev/null | grep -q ' ecdsa-sha2-'; then
    ssh-keygen -F "$kn" -f "$KH" 2>/dev/null | grep -qF " $blob"       || die "$h: its host key (${HKFP[$h]}) is not the one in $KH. If the BIG-IP was rebuilt, remove the old entry (ssh-keygen -R $kn) and run this again; otherwise find out why"
  else
    NEWK+=("$h"); HKLINE[$h]="$k"
  fi
done
if (( ${#NEWK[@]} )); then
  ASK=()
  for h in "${NEWK[@]}"; do
    [[ " ${HOSTFP[*]-} " == *" ${HKFP[$h]} "* ]] || ASK+=("$h")
  done
  if (( ${#ASK[@]} )); then
    echo
    echo "  New SSH host keys (not in $KH yet):"
    for h in "${ASK[@]}"; do printf '    %-18s %s
' "$h" "${HKFP[$h]}"; done
    if (( YES )); then
      die "with --yes, confirm each new host key with --host-fp (after comparing it with the BIG-IP's own); nothing was changed"
    fi
    echo "  Compare each with the fingerprint the BIG-IP itself shows, from its console (or an SSH"
    echo "  session you already trust), as root in bash:  ssh-keygen -lf /config/ssh/ssh_host_ecdsa_key.pub"
    read -r -p "Do they match? Trust them and continue? [y/N] " a || a=""
    [[ "$a" == [yY]* ]] || die "host keys not trusted; nothing was changed"
  fi
  mkdir -p "$HM/.ssh"; chmod 700 "$HM/.ssh"
  for h in "${NEWK[@]}"; do
    printf '%s
' "${HKLINE[$h]}" >> "$KH"
    info "pinned the host key of $h (${HKFP[$h]}) in $KH"
  done
fi

for h in "${UNITS[@]}"; do
  info "connecting to $BUSER@$h"
  on "$h" true </dev/null || die "cannot log in to $BUSER@$h over SSH"
done

# ---- 1. the BIG-IP --------------------------------------------------------------
PROBE="$(f5 'bash -s' <<'EOF'
echo "VERSION|$(tmsh -q show sys version 2>/dev/null | awk '/^  Version/{print $2; exit}')"
echo "MCP|$(tmsh -q show sys mcp-state field-fmt 2>/dev/null | awk '$1=="phase"{p=$2} $1=="last-load"{l=$2} END{print p "|" l}')"
echo "FAILOVER|$(tmsh -q show sys failover 2>/dev/null | head -1 | awk '{print tolower($2)}')"
echo "SELF|$(tmsh -q list cm device one-line 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "self-device" && $(i+1) == "true") { print $3; exit }}')"
for g in $(tmsh -q list cm device-group one-line 2>/dev/null | awk '$1 == "cm" && $2 == "device-group" {print $3}'); do
  tmsh -q list cm device-group "$g" devices type 2>/dev/null | awk -v G="$g" '
    $1 == "type" { t = $2 }
    /^    devices \{/ { d = 1; next }
    d && /^    \}/ { d = 0; next }
    d && /^        [^ ]+ \{ \}$/ { m = m (m == "" ? "" : ",") $1 }
    END { print "DG|" G "|" t "|" m }'
done
tmsh -q show cm sync-status field-fmt 2>/dev/null | sed -n 's/^ *details\.[0-9]*\.details \([^ ]*\) (\([^)]*\)): .*/DGSTATUS|\1|\2/p'
tmsh -q list net self one-line 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "address") print "SELFIP|" $(i+1)}'
tmsh -q list ltm virtual-address one-line 2>/dev/null | awk '{print "VADDR|" $3}'
n=0
for k in "ltm virtual" "ltm profile client-ssl" "sys file ssl-cert" "sys file ssl-key"; do
  c="$(tmsh -q list $k one-line 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "{") { print $(i-1); break }}' | grep -c '^lab-')" || c=0
  n=$((n + c))
done
[ -d /shared/cert-backups ] && n=$((n + $(ls -1 /shared/cert-backups 2>/dev/null | grep -c '^lab-')))
echo "LABITEMS|$n"
EOF
)" || die "cannot read the BIG-IP"
val() { printf '%s\n' "$PROBE" | awk -F'|' -v k="$1" '$1 == k {print $2; exit}'; }
VER="$(val VERSION)"; FO="$(val FAILOVER)"; SELF="$(val SELF)"
[[ -n "$VER" ]] || die "the BIG-IP did not return a version (is tmsh available to $BUSER?)"
[[ "$(printf '%s\n' "$PROBE" | awk -F'|' '$1=="MCP"{print $2 "|" $3}')" == "running|full-config-load-succeed" ]] || die "the BIG-IP configuration is not fully loaded"
[[ "$FO" == active ]] || die "$HOST is '$FO', not active: build the lab on the active unit"
LAB="$(val LABITEMS)"
(( ${LAB:-0} == 0 )) || die "$HOST already has $LAB lab item(s) (lab-*): remove them first with remove-lab.sh --host $HOST"

# The sync-failover group this unit shares with another device, if any.
GROUP=""; PEERS=""
while IFS='|' read -r tag g t m; do
  [[ "$tag" == DG && "$t" == sync-failover && ",$m," == *",$SELF,"* && "$m" == *,* ]] || continue
  [[ -z "$GROUP" ]] || die "$HOST is in several sync-failover groups ($GROUP, $g): this script handles one"
  GROUP="$g"; PEERS="$(printf '%s\n' "${m//,/ }" | tr ' ' '\n' | grep -vx "$SELF" | paste -sd, -)"
done <<<"$PROBE"
PFO=""
if [[ -n "$PEER" ]]; then
  [[ -n "$GROUP" ]] || die "--peer $PEER given, but $HOST shares no sync-failover device group with another device"
  pinfo="$(on "$PEER" 'bash -s' <<'EOF'
printf '%s|%s\n' "$(tmsh -q list cm device one-line 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "self-device" && $(i+1) == "true") { print $3; exit }}')" \
  "$(tmsh -q show sys failover 2>/dev/null | head -1 | awk '{print tolower($2)}')"
EOF
)" || die "cannot read $PEER"
  PSELF="${pinfo%%|*}"; PFO="${pinfo#*|}"
  [[ ",$PEERS," == *",$PSELF,"* ]] || die "$PEER is ${PSELF:-unknown}, which is not in device group $GROUP with $HOST ($PEERS)"
  [[ "$PFO" != active ]] || die "$PEER is active as well as $HOST: check the pair first"
fi
GSTAT=""
if [[ -n "$GROUP" ]]; then
  GSTAT="$(printf '%s\n' "$PROBE" | awk -F'|' -v g="$GROUP" '$1 == "DGSTATUS" && $2 == g {print $3; exit}')"
  if (( DOSYNC )) && [[ "$GSTAT" != "In Sync" ]]; then
    die "device group $GROUP is '${GSTAT:-unknown}', not In Sync. Synchronising the lab would also copy whatever else is pending. Resolve it first, or use --no-sync"
  fi
fi

# ---- the virtual server addresses -------------------------------------------------
used="$(printf '%s\n' "$PROBE" | awk -F'|' '$1 == "VADDR" || $1 == "SELFIP" {sub(/\/.*/, "", $2); sub(/%.*/, "", $2); print $2}')"
if [[ -n "$VSIPS" ]]; then
  IFS=, read -r -a VS <<<"$VSIPS"
  (( ${#VS[@]} == 3 )) || die "--vs-ips needs exactly three addresses (A,B,C)"
else
  sip="$(printf '%s\n' "$PROBE" | awk -F'|' '$1 == "SELFIP" && $2 ~ /^[0-9.]+(%[0-9]+)?\/24$/ {print $2; exit}')"
  [[ -n "$sip" ]] || die "no IPv4 /24 self IP found to choose virtual server addresses from: give --vs-ips A,B,C"
  base="${sip%%[/%]*}"; base="${base%.*}"
  VS=()
  for h in $(seq 201 250); do
    a="${base}.${h}"
    printf '%s\n' "$used" | grep -qx "$a" && continue
    VS+=("$a"); (( ${#VS[@]} == 3 )) && break
  done
  (( ${#VS[@]} == 3 )) || die "could not find three free addresses in ${base}.201-250: give --vs-ips A,B,C"
fi
for a in "${VS[@]}"; do
  [[ "$a" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "not an IPv4 address: $a"
  printf '%s\n' "$used" | grep -qx "$a" && die "$a is already used on the BIG-IP (a virtual address or self IP)"
done

echo
echo "  BIG-IP          $HOST ($SELF), BIG-IP $VER, $FO"
if [[ -n "$GROUP" ]]; then
  echo "  HA pair         device group $GROUP with $PEERS${PEER:+ ($PEER, $PFO)}: ${GSTAT}$( (( DOSYNC )) || printf ' (NOT synchronised: --no-sync)')"
  [[ -n "$PEER" ]] || warn "no --peer: the tool's key is authorised on $HOST only (give --peer for the other unit)"
else
  echo "  HA pair         none (standalone, or no sync-failover group shared with another device)"
fi
echo "  virtual servers lab-vs1 ${VS[0]}:443, lab-vs2 ${VS[1]}:443, lab-vs3 ${VS[2]}:443"
echo "  tool's SSH key  $TKEY ($TACT), authorised for root on ${UNITS[*]}"
echo "  local files     $OUT$( (( REPLACE )) && printf ' (the existing one is deleted first)')"
echo
if (( ! YES )); then
  read -r -p "Build the lab on $HOST? [y/N] " a || a=""
  [[ "$a" == [yY]* ]] || die "cancelled; nothing was changed (apart from the host keys you confirmed, pinned in $KH)"
fi

# ---- the tool's SSH key ------------------------------------------------------------------
if [[ "$TACT" == new ]]; then
  ssh-keygen -q -t ecdsa -b 384 -N '' -C "$TCOMMENT" -f "$TKEY" </dev/null || die "could not create $TKEY"
  ok "created the tool's key $TKEY"
fi
for h in "${UNITS[@]}"; do
  res="$(on "$h" 'bash -s' -- "$(cat "$TKEY.pub")" <<'EOF'
f=/var/ssh/root/authorized_keys
if [ -f "$f" ] && awk -v b="$2" '$2 == b {x = 1} END {exit !x}' "$f"; then echo present; exit 0; fi
printf '%s\n' "$*" >> "$f" && chmod 600 "$f" && restorecon "$f" && echo added
EOF
)" || die "could not authorise the tool's key on $h"
  if [[ "$res" == added ]]; then ok "authorised the tool's key for root on $h"; else info "the tool's key was already authorised on $h"; fi
  t="$(ssh -p "$PORT" -i "$TKEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KH" -o ControlPath=none -o ConnectTimeout=15 -o LogLevel=ERROR \
        "root@$h" 'tmsh -q show sys failover | head -1' </dev/null)" || die "logging in to $h with the tool's key failed"
  ok "login with the tool's key works on $h: $t"
done

# ---- 2. the lab PKI (on this machine) ------------------------------------------------
if (( REPLACE )); then rm -rf -- "$OUT" && info "deleted the old $OUT"; fi
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
P="$OUT/pki"; R="$OUT/received"; mkdir -p "$P" "$R/bad"
chmod 700 "$OUT" "$P"
info "making the lab CA and certificates in $P"
(
  cd "$P"
  cat > ca.cnf <<'EOF'
[ca]
default_ca = d
[d]
dir = .
database = index.txt
new_certs_dir = .
serial = serial
default_md = sha256
policy = p
copy_extensions = none
unique_subject = no
[p]
commonName = supplied
organizationName = optional
[v3_int]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
EOF
  : > index.txt; echo 1000 > serial
  openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.pem -days 3650 -subj "/O=f5-cert-push lab/CN=Lab Root CA" 2>/dev/null
  openssl req -new -newkey rsa:2048 -nodes -keyout int.key -out int.csr -subj "/O=f5-cert-push lab/CN=Lab Issuing CA" 2>/dev/null
  openssl ca -config ca.cnf -batch -notext -cert root.pem -keyfile root.key -in int.csr -out int.pem -days 1825 -extensions v3_int 2>/dev/null
) || die "could not make the lab CA (openssl)"

leaf() {   # leaf NAME CN SAN rsa|ec DAYS | START END
  local n="$1" cn="$2" san="$3" kt="$4"; shift 4
  ( cd "$P"
    if [[ "$kt" == ec ]]; then openssl ecparam -name prime256v1 -genkey -noout -out "$n.key" 2>/dev/null
    else openssl genrsa -out "$n.key" 2048 2>/dev/null; fi
    openssl req -new -key "$n.key" -out "$n.csr" -subj "/O=f5-cert-push lab/CN=${cn}" 2>/dev/null
    { cat ca.cnf; printf '[v3_leaf]\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$san"; } > "$n.cnf"
    local -a d=(-days "$1"); (( $# == 2 )) && d=(-startdate "$1" -enddate "$2")
    openssl ca -config "$n.cnf" -batch -notext -cert int.pem -keyfile int.key -in "$n.csr" -out "$n.pem" "${d[@]}" -extensions v3_leaf 2>/dev/null
    rm -f "$n.csr" "$n.cnf"
  ) || die "could not make certificate $n"
}
W='DNS:*.lab.test,DNS:lab.test'
# installed on the BIG-IP now
leaf cur-app1   app1.lab.test   DNS:app1.lab.test   rsa 60
leaf cur-app2   app2.lab.test   DNS:app2.lab.test   rsa 60
leaf cur-wild   '*.lab.test'    "$W"                rsa 60
leaf cur-wildec '*.lab.test'    "$W"                ec  60
leaf cur-spare  spare.lab.test  DNS:spare.lab.test  rsa 200
leaf cur-legacy legacy.lab.test DNS:legacy.lab.test rsa 20
# the renewals the trainee deploys
leaf new-app1   app1.lab.test   DNS:app1.lab.test   rsa 397
leaf new-app2   app2.lab.test   DNS:app2.lab.test   rsa 397
leaf new-wild   '*.lab.test'    "$W"                rsa 397
leaf new-wildec '*.lab.test'    "$W"                ec  397
# bad material
leaf bad-expired app1.lab.test  DNS:app1.lab.test   rsa 20250101000000Z 20250401000000Z
leaf bad-short   app2.lab.test  DNS:app2.lab.test   rsa 3

# As a CA would deliver them: a certificate, its key and the intermediate, named by host.
mkdir -p "$R/app1" "$R/app2" "$R/wildcard" "$R/wildcard-ec"
cp "$P/new-app1.pem" "$R/app1/app1.lab.test.crt"; cp "$P/new-app1.key" "$R/app1/app1.lab.test.key"; cp "$P/int.pem" "$R/app1/intermediate.crt"
openssl pkcs12 -export -inkey "$P/new-app2.key" -in "$P/new-app2.pem" -certfile "$P/int.pem" -name app2.lab.test \
  -passout pass:lab -out "$R/app2/app2.lab.test.pfx" 2>/dev/null || die "could not make the .pfx"
cp "$P/new-wild.pem" "$R/wildcard/star.lab.test.crt"; cp "$P/new-wild.key" "$R/wildcard/star.lab.test.key"; cp "$P/int.pem" "$R/wildcard/intermediate.crt"
cp "$P/new-wildec.pem" "$R/wildcard-ec/star.lab.test-ecdsa.crt"; cp "$P/new-wildec.key" "$R/wildcard-ec/star.lab.test-ecdsa.key"; cp "$P/int.pem" "$R/wildcard-ec/intermediate.crt"
mkdir -p "$R/bad/expired" "$R/bad/wrong-key" "$R/bad/expires-soon" "$R/bad/encrypted-key"
cp "$P/bad-expired.pem" "$R/bad/expired/cert.pem"; cp "$P/bad-expired.key" "$R/bad/expired/privkey.pem"; cp "$P/int.pem" "$R/bad/expired/chain.pem"
cp "$P/new-app1.pem" "$R/bad/wrong-key/cert.pem"; cp "$P/new-app2.key" "$R/bad/wrong-key/privkey.pem"; cp "$P/int.pem" "$R/bad/wrong-key/chain.pem"
cp "$P/bad-short.pem" "$R/bad/expires-soon/cert.pem"; cp "$P/bad-short.key" "$R/bad/expires-soon/privkey.pem"; cp "$P/int.pem" "$R/bad/expires-soon/chain.pem"
cp "$P/new-app1.pem" "$R/bad/encrypted-key/cert.pem"; cp "$P/int.pem" "$R/bad/encrypted-key/chain.pem"
openssl pkey -in "$P/new-app1.key" -aes256 -passout pass:lab -out "$R/bad/encrypted-key/privkey.pem" 2>/dev/null
find "$R" -type d -exec chmod 700 {} +; find "$R" -type f -exec chmod 600 {} +

# ---- 3. the BIG-IP objects -------------------------------------------------------------
info "installing the current lab certificates on $HOST"
up() { f5 "umask 077; cat > /var/tmp/lab-upload.$2" < "$1"; }
for pair in cur-app1:lab-app1 cur-app2:lab-app2 cur-wild:lab-wild cur-wildec:lab-wild-ec cur-spare:lab-spare cur-legacy:lab-legacy; do
  src="${pair%%:*}"; obj="${pair#*:}"
  up "$P/$src.key" "$obj.key"; up "$P/$src.pem" "$obj.crt"
  f5 "tmsh install sys crypto key $obj.key from-local-file /var/tmp/lab-upload.$obj.key && tmsh install sys crypto cert $obj.crt from-local-file /var/tmp/lab-upload.$obj.crt" >/dev/null \
    || die "installing $obj failed"
done
up "$P/int.pem" lab-issuing-ca.crt
f5 'tmsh install sys crypto cert lab-issuing-ca.crt from-local-file /var/tmp/lab-upload.lab-issuing-ca.crt' >/dev/null || die "installing the lab CA failed"
f5 'rm -f /var/tmp/lab-upload.*'

info "creating the client-ssl profiles and virtual servers"
f5 'bash -s' -- "${VS[@]}" <<'EOF' || die "creating the lab profiles and virtual servers failed"
set -e
tmsh create ltm profile client-ssl lab-app1-clientssl defaults-from clientssl cert-key-chain replace-all-with { app1 { cert lab-app1.crt key lab-app1.key chain lab-issuing-ca.crt } }
tmsh create ltm profile client-ssl lab-app2-clientssl defaults-from clientssl cert-key-chain replace-all-with { app2 { cert lab-app2.crt key lab-app2.key chain lab-issuing-ca.crt } }
tmsh create ltm profile client-ssl lab-wild-clientssl defaults-from clientssl cert-key-chain replace-all-with { rsa { cert lab-wild.crt key lab-wild.key chain lab-issuing-ca.crt } ecdsa { cert lab-wild-ec.crt key lab-wild-ec.key chain lab-issuing-ca.crt } }
tmsh create ltm virtual lab-vs1 destination "$1:443" ip-protocol tcp profiles add { tcp { } lab-app1-clientssl { context clientside } }
tmsh create ltm virtual lab-vs2 destination "$2:443" ip-protocol tcp profiles add { tcp { } lab-app2-clientssl { context clientside } }
tmsh create ltm virtual lab-vs3 destination "$3:443" ip-protocol tcp profiles add { tcp { } lab-wild-clientssl { context clientside } }
tmsh save sys config >/dev/null
EOF

# ---- 4. sync, and check ------------------------------------------------------------------
if [[ -n "$GROUP" ]] && (( DOSYNC )); then
  info "synchronising device group $GROUP to $PEERS"
  f5 "tmsh run cm config-sync to-group $GROUP" || die "config-sync to $GROUP failed"
  st=""
  for _ in $(seq 1 40); do
    st="$(f5 'tmsh -q show cm sync-status field-fmt' | sed -n "s/^ *details\.[0-9]*\.details $GROUP (\([^)]*\)).*/\1/p")"
    [[ "$st" == "In Sync" ]] && break; sleep 3
  done
  [[ "$st" == "In Sync" ]] || die "device group $GROUP did not return to In Sync (status: ${st:-unknown}); check it on the BIG-IP"
  ok "device group $GROUP is In Sync"
fi
info "what the virtual servers serve (checked from the BIG-IP):"
for i in 0 1 2; do
  for c in aRSA aECDSA; do
    [[ $i != 2 && $c == aECDSA ]] && continue
    s="$(f5 "echo | timeout 10 openssl s_client -connect ${VS[$i]}:443 -cipher $c 2>/dev/null | openssl x509 -noout -subject -enddate 2>/dev/null")" || s=""
    s="$(printf '%s\n' "$s" | sed -n 's/.*CN *= *\([^/,]*\).*/\1/p; s/^notAfter=/expires /p' | paste -sd' ' -)"
    printf '      lab-vs%d %s:443 %-7s %s\n' "$((i + 1))" "${VS[$i]}" "$( [[ $i == 2 ]] && printf '(%s)' "${c#a}" )" "${s:-NO ANSWER}"
  done
done

cat > "$OUT/lab-info.txt" <<EOF
f5-cert-push lab, built $(date -u '+%Y-%m-%d %H:%M UTC') by build-lab $VERSION
BIG-IP:        $HOST ($SELF), BIG-IP $VER
device group:  ${GROUP:-none}${PEERS:+ (peer(s): $PEERS)}
virtual servers: lab-vs1 ${VS[0]}:443 (lab-app1-clientssl), lab-vs2 ${VS[1]}:443 (lab-app2-clientssl),
                 lab-vs3 ${VS[2]}:443 (lab-wild-clientssl: entries rsa and ecdsa)
unused certificates: lab-spare.crt, lab-legacy.crt
renewed certificates for the trainee: $R
  app1/        app1.lab.test.crt, app1.lab.test.key, intermediate.crt
  app2/        app2.lab.test.pfx  (PFX password: lab)
  wildcard/    star.lab.test.crt, star.lab.test.key, intermediate.crt          (RSA)
  wildcard-ec/ star.lab.test-ecdsa.crt, star.lab.test-ecdsa.key, intermediate.crt (ECDSA)
  bad/         expired, wrong-key, expires-soon (3 days), encrypted-key (passphrase: lab)
tool's SSH key: $TKEY (authorised for root on ${UNITS[*]})
Remove everything:  remove-lab.sh --cleanup   (reads $OUT/lab-env.sh; finds both units)
EOF
cat > "$OUT/lab-env.sh" <<EOF
# Sets the addresses docs/LAB.md uses. Load it in each new terminal:  . $OUT/lab-env.sh
A=$HOST
B=$PEER
VS1=${VS[0]}
VS2=${VS[1]}
VS3=${VS[2]}
TOOLKEY=$TKEY
EOF
echo
ok "the lab is ready. Summary in $OUT/lab-info.txt"
echo "    Load the addresses for the guide's commands:  . $OUT/lab-env.sh"
echo "    Next: docs/LAB.md, section 2."
