#!/usr/bin/env bash
# Integration test suite for f5-cert-push: runs REAL deployments against a REAL BIG-IP.
#
# !!  This creates and deletes objects on the BIG-IP. Use a LAB device.  !!
# Everything it creates is named zzz-* (profiles, virtual servers, certificates,
# keys, one partition, and /shared/cert-backups/zzz-*) and is removed at the end,
# even after a failure. It never touches anything else.
#
# Required environment:
#   F5_TEST_CONFIRM=yes          you understand the above
#   F5_TEST_HOST=10.0.0.1        BIG-IP management address
#   F5_TEST_KEY=/root/.ssh/key   SSH private key for root on the BIG-IP
# Optional:
#   F5_TEST_PORT=22   F5_TEST_USER=root
#   F5_TEST_VS_A=10.1.10.77  F5_TEST_VS_B=10.1.10.78
#        two UNUSED addresses in a subnet the BIG-IP has a self IP in, used as
#        test virtual-server addresses (port 443). Probed from the BIG-IP itself.
#   F5_TEST_ONLY="s2 s9"         run only the named scenarios
#   T_VERBOSE=1                  show output for failures
#
# Run it on a Linux host that can reach the BIG-IP over SSH, as a user who can read
# the key. See docs/TESTING.md.

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${F5_TEST_CONFIRM:-}" != yes ]]; then
  echo "Refusing to run: this suite changes a real BIG-IP. Read the header of $0, then set F5_TEST_CONFIRM=yes." >&2
  exit 2
fi
HOST="${F5_TEST_HOST:?set F5_TEST_HOST}"
KEY="${F5_TEST_KEY:?set F5_TEST_KEY}"
PORT="${F5_TEST_PORT:-22}"
BUSER="${F5_TEST_USER:-root}"
VSA="${F5_TEST_VS_A:-10.1.10.77}"
VSB="${F5_TEST_VS_B:-10.1.10.78}"
ONLY="${F5_TEST_ONLY:-}"

KH="${TMP}/known_hosts"
CF="${TMP}/run.conf"
LIVE="${TMP}/live"; mkdir -p "$LIVE"
LOCKS="${TMP}/locks"
BK="${TMP}/backups"
export PUSH_LOG="${TMP}/run.log"

ssh-keyscan -T 10 -t ecdsa,ed25519,rsa -p "$PORT" "$HOST" > "$KH" 2>/dev/null
[[ -s "$KH" ]] || { echo "cannot read the BIG-IP's SSH host keys" >&2; exit 1; }
chmod 600 "$KH"

# The test helper reuses one SSH connection (the BIG-IP's logins are slow). This is a
# test-harness optimisation only; the tool under test opens its own connections.
CM="${TMP}/cm"
F5SSH=(ssh -T -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR
       -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -p "$PORT"
       -o ControlMaster=auto -o ControlPath="$CM" -o ControlPersist=900 "${BUSER}@${HOST}")
f5() { "${F5SSH[@]}" "$@"; }

want() { [[ -z "$ONLY" || " $ONLY " == *" $1 "* ]]; }

#######################################################################
# BIG-IP fixtures and inspection
#######################################################################
f5_cleanup() {
  f5 'bash -s' <<'CLEAN'
# "cd /" makes "recursive" span every partition; names print as Partition/name.
all() { printf '%s\n' 'cd /' "list $1 one-line recursive" | tmsh -q 2>/dev/null | awk -v f="$2" '{print $f}' | grep -E '(^|/)zzz'; }
for v in $(all 'ltm virtual' 3); do tmsh delete ltm virtual "/$v" >/dev/null 2>&1; done
for p in $(all 'ltm profile client-ssl' 4); do tmsh delete ltm profile client-ssl "/$p" >/dev/null 2>&1; done
for c in $(all 'sys file ssl-cert' 4); do tmsh delete sys crypto cert "/$c" >/dev/null 2>&1; done
for k in $(all 'sys file ssl-key' 4); do tmsh delete sys crypto key "/$k" >/dev/null 2>&1; done
if tmsh -q list auth partition zzz-part 2>/dev/null | grep -q '^auth partition'; then tmsh delete auth partition zzz-part >/dev/null 2>&1; fi
rm -rf /shared/cert-backups/zzz-* /var/tmp/zzz-* /var/run/f5-cert-push.lock 2>/dev/null
find /var/tmp -maxdepth 1 -name 'f5-cert-push.*' -exec rm -rf {} + 2>/dev/null
tmsh save sys config >/dev/null 2>&1
exit 0
CLEAN
}

suite_cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then kill "$SERVER_PID" 2>/dev/null; fi
  f5_cleanup
  if [[ -n "$(f5 "printf '%s\n' 'cd /' 'list ltm profile client-ssl one-line recursive' | tmsh -q | awk '{print \$4}' | grep -E '(^|/)zzz'" 2>/dev/null)" ]]; then
    echo "WARNING: zzz-* objects remain on the BIG-IP; remove them by hand" >&2
  fi
  ssh -o ControlPath="$CM" -O exit "${BUSER}@${HOST}" >/dev/null 2>&1 || true
}

# Lines describing a profile's entries: "entry cert chain key"
entries() {   # entries PROFILE
  f5 "tmsh -q list ltm profile client-ssl $1 cert-key-chain" | awk '
    function flush() { if (e != "") print e, c, h, k }
    /^        [^ ].* \{$/ { flush(); e = $1; c = "-"; h = "-"; k = "-"; next }
    /^            cert /  { c = $2 }
    /^            chain / { h = $2 }
    /^            key /   { k = $2 }
    END { flush() }'
}
bound_cert()  { entries "$1" | awk -v e="$2" '$1 == e { print $2 }'; }
bound_chain() { entries "$1" | awk -v e="$2" '$1 == e { print $3 }'; }
bound_key()   { entries "$1" | awk -v e="$2" '$1 == e { print $4 }'; }
obj_fp() {    # fingerprint (hex, no colons) of a certificate object
  f5 "tmsh -q list sys file ssl-cert $1 fingerprint" | awk '$1 == "fingerprint" { print $2 }' | sed 's#.*/##' | tr -d ':' | tr 'a-f' 'A-F'
}
bound_fp() { local c; c="$(bound_cert "$1" "$2")"; [[ -n "$c" ]] && obj_fp "$c"; }
served_fp() { # served_fp IP -> fingerprint the virtual server presents (probed from the BIG-IP)
  f5 "echo | timeout 12 openssl s_client -connect $1:443 -servername zzz.test 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null" | cut -d= -f2 | tr -d ':'
}
obj_count() { # obj_count KIND GLOB-FRAGMENT
  f5 "tmsh -q list sys file ssl-$1 one-line recursive | awk '{print \$4}' | grep -c -- '$2'" 2>/dev/null || true
}
obj_exists() { [[ -n "$(f5 "tmsh -q list sys file ssl-$1 $2 2>/dev/null")" ]]; }
remote_backups() { f5 "ls -1 /shared/cert-backups/$1 2>/dev/null | grep -cE '^[0-9]{8}-[0-9]{6}\$'" 2>/dev/null || true; }
local_backups()  { ls -1 "$BK/t/$1" 2>/dev/null | grep -cE '^[0-9]{8}-[0-9]{6}$' || true; }
stage_left()     { f5 "ls -d /var/tmp/f5-cert-push.* 2>/dev/null | wc -l"; }
newest_backup()  { f5 "ls -1 /shared/cert-backups/$1 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}\$' | sort | tail -1"; }
snapshot() {  # everything a no-op must leave unchanged
  { for p in zzz-t1 zzz-t2 zzz-t3 zzz-t4; do echo "== $p"; entries "$p"; done
    f5 "tmsh -q list sys file ssl-cert one-line recursive | awk '{print \$4}' | grep zzz | sort"
    f5 "tmsh -q list sys file ssl-key one-line recursive | awk '{print \$4}' | grep zzz | sort"; } 2>/dev/null
}

# A certificate set on disk that the tool reads.
use_cert() {  # use_cert NAME  (files from the test PKI)
  cp "$PKI/$1.pem" "$LIVE/cert.pem"; cp "$PKI/$1.key" "$LIVE/key.pem"; cp "$PKI/$1.chain.pem" "$LIVE/chain.pem"
  CUR_FP="$(fp_of "$LIVE/cert.pem")"
}

# Write the tool's config; $1 = extra sections.
conf() {
  cat > "$CF" <<EOF
[defaults]
backup_dir_local = ${BK}
log_file = ${PUSH_LOG}
lock_dir = ${LOCKS}
keep = ${KEEP:-4}
verify_unreachable = ${VUN:-warn}
auto_rollback = ${AUTOROLL:-yes}
connect_timeout = 10
remote_timeout = 120

[f5:t]
host = ${HOST}
port = ${PORT}
user = ${BUSER}
ssh_key = ${KEY}
known_hosts_file = ${KH}
partition = ${PART:-Common}

[f5:t2]
host = ${HOST}
port = ${PORT}
user = ${BUSER}
ssh_key = ${KEY}
known_hosts_file = ${KH}

[cert:zt]
cert = ${LIVE}/cert.pem
key = ${LIVE}/key.pem
chain = ${LIVE}/chain.pem
object_prefix = ${PREFIX:-zzz-cert}

$1
EOF
  chmod 600 "$CF"
}
tool() { run "$BIN" --config "$CF" "$@"; }

#######################################################################
# Setup
#######################################################################
echo "== setup: test PKI and BIG-IP fixtures"
PKI="${TMP}/pki"; pki_init "$PKI"
for n in a b c d e f g h; do pki_leaf "$PKI" "$n" "zzz.test" "DNS:zzz.test"; done
pki_leaf "$PKI" ecleaf "zzz-ec.test" "DNS:zzz-ec.test" ec
pki_leaf "$PKI" old "zzz.test" "DNS:zzz.test" rsa 20200101000000Z 20200102000000Z
[[ -s "$PKI/h.pem" && -s "$PKI/ecleaf.pem" ]] || { echo "PKI generation failed" >&2; exit 1; }
use_cert a

f5_cleanup
# EC certificate for the dual-entry profile.
f5 'cat > /var/tmp/zzz-ec.key' < "$PKI/ecleaf.key"; f5 'cat > /var/tmp/zzz-ec.crt' < "$PKI/ecleaf.pem"
f5 'tmsh install sys crypto key zzz-ec.key from-local-file /var/tmp/zzz-ec.key >/dev/null && tmsh install sys crypto cert zzz-ec.crt from-local-file /var/tmp/zzz-ec.crt >/dev/null; rm -f /var/tmp/zzz-ec.*'
DEF='{ default { cert default.crt key default.key } }'
f5 "tmsh create ltm profile client-ssl zzz-t1 defaults-from clientssl cert-key-chain replace-all-with { e1 { cert default.crt key default.key } }" >/dev/null
f5 "tmsh create ltm profile client-ssl zzz-t2 defaults-from clientssl cert-key-chain replace-all-with { e1 { cert default.crt key default.key } }" >/dev/null
f5 "tmsh create ltm profile client-ssl zzz-t3 defaults-from clientssl cert-key-chain replace-all-with { e_rsa { cert default.crt key default.key } e_ec { cert zzz-ec.crt key zzz-ec.key } }" >/dev/null
f5 "tmsh create ltm profile client-ssl zzz-t4 defaults-from clientssl cert-key-chain replace-all-with { e1 { cert default.crt key default.key } }" >/dev/null
f5 "tmsh create ltm profile client-ssl zzz-other defaults-from clientssl cert-key-chain replace-all-with { e1 { cert default.crt key default.key } }" >/dev/null
f5 "tmsh create ltm profile client-ssl zzz-inh defaults-from clientssl" >/dev/null
f5 "tmsh create ltm virtual zzz-vs1 destination ${VSA}:443 ip-protocol tcp profiles add { tcp { } zzz-t1 { context clientside } }" >/dev/null
f5 "tmsh create ltm virtual zzz-vs2 destination ${VSB}:443 ip-protocol tcp profiles add { tcp { } zzz-other { context clientside } }" >/dev/null
f5 "tmsh save sys config" >/dev/null
DEFFP="$(obj_fp default.crt)"
if [[ -z "$DEFFP" || "$(entries zzz-t3 | wc -l)" != 2 || -z "$(served_fp "$VSA")" ]]; then
  echo "fixture setup failed (default cert fp='$DEFFP', t3 entries=$(entries zzz-t3 | wc -l), vs-a fp='$(served_fp "$VSA")')" >&2
  exit 1
fi
INH="$(f5 "tmsh -q list ltm profile client-ssl zzz-inh inherit-certkeychain" | awk '$1=="inherit-certkeychain"{print $2}')"
echo "fixtures ready (default cert ${DEFFP:0:12}..., zzz-inh inherits: ${INH})"

BASE_DEPLOY="[deploy:basic]
f5 = t
cert = zt
profile = zzz-t1
profile = zzz-t2
verify = ${VSA}:443 zzz.test
"

#######################################################################
if want s1; then
echo "== s1: read-only commands change nothing"
#######################################################################
conf "$BASE_DEPLOY"
S0="$(snapshot)"
tool --deploy basic --check
expect_rc 4 "--check reports out-of-date (exit 4)"; expect_has "OUT OF DATE" "--check names the stale profile"
tool --deploy basic --dry-run
expect_rc 0 "--dry-run exits 0"; expect_has "DRY RUN" "--dry-run prints the plan"; expect_has "repoint zzz-t1 / e1" "--dry-run names the target entries"
expect_eq "$(snapshot)" "$S0" "--check and --dry-run left the BIG-IP untouched"
expect_eq "$(remote_backups zzz-cert)" "0" "no backup was made by read-only commands"
tool --discover --f5 t
expect_rc 0 "--discover exits 0"; expect_has "zzz-t3" "--discover lists the test profiles"; expect_has "e_ec" "--discover lists every entry"
fi

#######################################################################
if want s2; then
echo "== s2: first deployment to two profiles"
#######################################################################
conf "$BASE_DEPLOY"
tool --deploy basic
expect_rc 0 "first deploy exits 0"; expect_has "UPDATED" "summary says UPDATED"; expect_has "single transaction" "profiles were switched in one transaction"
expect_eq "$(bound_fp zzz-t1 e1)" "$CUR_FP" "zzz-t1 now uses the new certificate"
expect_eq "$(bound_fp zzz-t2 e1)" "$CUR_FP" "zzz-t2 now uses the new certificate"
expect_eq "$(served_fp "$VSA")" "$CUR_FP" "the virtual server serves the new certificate"
expect_has "certificate(s) in the chain" "the endpoint check reports the chain depth"
C1="$(bound_cert zzz-t1 e1)"
expect_true "the versioned certificate object exists" obj_exists cert "$C1"
expect_true "the chain object is bound" test -n "$(bound_chain zzz-t1 e1)" -a "$(bound_chain zzz-t1 e1)" != none
expect_true "the change was saved to disk (bigip.conf)" f5 "grep -q '$C1' /config/bigip.conf"
expect_eq "$(remote_backups zzz-cert)" "1" "one backup set on the BIG-IP"
expect_eq "$(local_backups zzz-cert)" "1" "one backup set on this host"
B1="$(newest_backup zzz-cert)"
expect_true "the restore script exists on the BIG-IP" f5 "test -x /shared/cert-backups/zzz-cert/$B1/restore-$B1.sh"
expect_true "the local backup matches its checksums" bash -c "cd '$BK/t/zzz-cert/$B1' && sha256sum -c --quiet SHA256SUMS"
expect_true "the backup holds the old (default) key" test -n "$(ls "$BK/t/zzz-cert/$B1"/key.* 2>/dev/null)"
expect_eq "$(stat -c %a "$BK/t/zzz-cert/$B1")" "700" "the local backup directory is mode 0700"
expect_eq "$(stat -c %a "$BK/t/zzz-cert/$B1/restore-$B1.sh")" "600" "backup files are mode 0600"
expect_eq "$(stage_left)" "0" "no staging directory is left on the BIG-IP"
expect_eq "$(ls -A "$LOCKS" 2>/dev/null | wc -l)" "0" "the lock was released"
expect_true "the BIG-IP-side lock was released" f5 "test ! -d /var/run/f5-cert-push.lock"
expect_eq "$(pgrep -fc 'f5-cert-push\.[A-Za-z0-9]+/cm-' || true)" "0" "no shared SSH connection is left running by the tool"
expect_true "the log file recorded the run" grep -q "UPDATED\|done; rollback" "$PUSH_LOG"
fi

#######################################################################
if want s3; then
echo "== s3: re-running is a no-op until something changes"
#######################################################################
conf "$BASE_DEPLOY"
S0="$(snapshot)"; N0="$(remote_backups zzz-cert)"
tool --deploy basic
expect_rc 0 "second run exits 0"; expect_has "UPTODATE" "second run is UPTODATE"; expect_eq "$(snapshot)" "$S0" "second run changed nothing"
expect_eq "$(remote_backups zzz-cert)" "$N0" "second run made no new backup"
tool --deploy basic --check; expect_rc 0 "--check now exits 0"
tool --deploy basic --force; expect_rc 0 "--force redeploys"; expect_has "UPDATED" "--force reports UPDATED"
expect_eq "$(remote_backups zzz-cert)" "$((N0 + 1))" "--force made a new backup"
fi

#######################################################################
if want s4; then
echo "== s4: a renewed certificate replaces the old one; the old objects remain"
#######################################################################
conf "$BASE_DEPLOY"
OLDC="$(bound_cert zzz-t1 e1)"; OLDFP="$CUR_FP"
use_cert b
tool --deploy basic
expect_rc 0 "renewal deploy exits 0"
expect_eq "$(bound_fp zzz-t1 e1)" "$CUR_FP" "zzz-t1 uses the renewed certificate"
expect_eq "$(served_fp "$VSA")" "$CUR_FP" "the virtual server serves the renewed certificate"
expect_true "the previous certificate object is retained for rollback" obj_exists cert "$OLDC"
expect_eq "$(obj_fp "$OLDC")" "$OLDFP" "the retained object is still the previous certificate"
fi

#######################################################################
if want s5; then
echo "== s5: manual rollback and restore-script integrity"
#######################################################################
conf "$BASE_DEPLOY"
PREVC="$(bound_cert zzz-t1 e1)"
use_cert c
tool --deploy basic; expect_rc 0 "deploy certificate C"
BC="$(newest_backup zzz-cert)"
tool --deploy basic --list-backups; expect_rc 0 "--list-backups exits 0"; expect_has "$BC" "--list-backups lists the newest set"
tool --deploy basic --rollback --set "$BC"
expect_rc 0 "--rollback exits 0"; expect_has "RESTORED" "--rollback reports RESTORED"
expect_eq "$(bound_cert zzz-t1 e1)" "$PREVC" "zzz-t1 is back on its previous certificate object"
expect_eq "$(served_fp "$VSA")" "$(obj_fp "$PREVC")" "the virtual server serves the restored certificate"
tool --deploy basic --rollback --set 19990101-000000
expect_rc 1 "rolling back to a set that does not exist fails"; expect_eq "$(bound_cert zzz-t1 e1)" "$PREVC" "a failed rollback changes nothing"
# tamper with a backed-up file: the restore script must refuse
use_cert d; tool --deploy basic; expect_rc 0 "deploy certificate D"
BD="$(newest_backup zzz-cert)"
f5 "f=\$(ls /shared/cert-backups/zzz-cert/$BD/cert.* | head -1); echo tamper >> \"\$f\""
BEFORE="$(bound_cert zzz-t1 e1)"
tool --deploy basic --rollback --set "$BD"
expect_rc 1 "a tampered backup is refused"; expect_eq "$(bound_cert zzz-t1 e1)" "$BEFORE" "a tampered backup changed nothing"
fi

#######################################################################
if want s6; then
echo "== s6: restore reinstalls an object that was deleted"
#######################################################################
conf "$BASE_DEPLOY"
use_cert e; tool --deploy basic; expect_rc 0 "deploy certificate E"
PREVC="$(bound_cert zzz-t1 e1)"; PREVFP="$(obj_fp "$PREVC")"
use_cert f; tool --deploy basic; expect_rc 0 "deploy certificate F"
BF="$(newest_backup zzz-cert)"
f5 "tmsh modify ltm profile client-ssl zzz-t1 cert-key-chain modify { e1 { cert default.crt chain none key default.key } }; tmsh modify ltm profile client-ssl zzz-t2 cert-key-chain modify { e1 { cert default.crt chain none key default.key } }" >/dev/null
f5 "tmsh delete sys crypto cert $PREVC >/dev/null 2>&1; tmsh delete sys crypto cert $(echo "$PREVC" | sed 's/-cert-/-chain-/') >/dev/null 2>&1; tmsh delete sys crypto key $(echo "$PREVC" | sed 's/-cert-/-privkey-/') >/dev/null 2>&1"
expect_false "the previous certificate object is really gone" obj_exists cert "$PREVC"
tool --deploy basic --rollback --set "$BF"
expect_rc 0 "rollback succeeds although the old objects were deleted"
expect_true "the old certificate object was reinstalled from the backup" obj_exists cert "$PREVC"
expect_eq "$(obj_fp "$PREVC")" "$PREVFP" "the reinstalled certificate is byte-identical to the original"
expect_eq "$(bound_cert zzz-t1 e1)" "$PREVC" "the profile points at the reinstalled object"
fi

#######################################################################
if want s7; then
echo "== s7: problems found before any change leave the BIG-IP untouched"
#######################################################################
use_cert g
S0="$(snapshot)"; N0="$(remote_backups zzz-cert)"
conf "[deploy:x1]
f5 = t
cert = zt
profile = zzz-t1
profile = zzz-nonexistent
"
tool --deploy x1; expect_rc 1 "a missing profile fails the deploy"; expect_has "does not exist" "the missing profile is named"
expect_eq "$(snapshot)" "$S0" "nothing was installed or changed"; expect_eq "$(remote_backups zzz-cert)" "$N0" "no backup was made"
conf "[deploy:x2]
f5 = t
cert = zt
profile = zzz-inh
"
tool --deploy x2; expect_rc 1 "a profile that inherits its certificate is refused"; expect_has "inherits its certificate" "inheritance is explained"
expect_eq "$(snapshot)" "$S0" "inheritance refusal changed nothing"
conf "[deploy:x3]
f5 = t
cert = zt
profile = zzz-t3
"
tool --deploy x3; expect_rc 1 "an ambiguous multi-entry profile is refused"; expect_has "name the entry explicitly" "the fix is explained"
expect_eq "$(snapshot)" "$S0" "the ambiguity refusal changed nothing"
conf "[deploy:x4]
f5 = t
cert = zt
profile = zzz-t3:nosuch
"
tool --deploy x4; expect_rc 1 "a named entry that does not exist is refused"; expect_has "no cert-key-chain entry named" "the missing entry is named"
PART=zzz-missing conf "[deploy:x5]
f5 = t
cert = zt
profile = zzz-t1
"
tool --deploy x5; expect_rc 1 "a missing partition is refused"; expect_has "does not exist on the BIG-IP" "the partition is named"
expect_eq "$(snapshot)" "$S0" "the partition refusal changed nothing"
cp "$PKI/old.pem" "$LIVE/cert.pem"; cp "$PKI/old.key" "$LIVE/key.pem"; cp "$PKI/old.chain.pem" "$LIVE/chain.pem"
conf "$BASE_DEPLOY"
tool --deploy basic; expect_rc 1 "an expired certificate is refused before connecting"; expect_has "already expired" "expiry is reported"
expect_eq "$(snapshot)" "$S0" "the expired-certificate refusal changed nothing"
use_cert g
fi

#######################################################################
if want s8; then
echo "== s8: a dual RSA+ECDSA profile: only the named entry changes"
#######################################################################
use_cert g
conf "[deploy:dual]
f5 = t
cert = zt
profile = zzz-t3:e_rsa
"
EC_BEFORE="$(entries zzz-t3 | awk '$1=="e_ec"')"
tool --deploy dual; expect_rc 0 "deploying to one entry of a dual profile succeeds"
expect_eq "$(bound_fp zzz-t3 e_rsa)" "$CUR_FP" "the RSA entry uses the new certificate"
expect_eq "$(entries zzz-t3 | awk '$1=="e_ec"')" "$EC_BEFORE" "the ECDSA entry is untouched"
# a transaction the BIG-IP rejects: an RSA cert into the EC entry while the RSA entry exists
conf "[deploy:bad]
f5 = t
cert = zt
profile = zzz-t3:e_ec
"
S0="$(snapshot)"
OBJ0="$(obj_count cert zzz-cert-cert-)"
tool --deploy bad --force
expect_rc 1 "a transaction the BIG-IP rejects fails the deploy"; expect_has "transaction failed" "the BIG-IP's refusal is reported"
expect_eq "$(snapshot)" "$S0" "a rejected transaction left every profile unchanged"
expect_eq "$(obj_count cert zzz-cert-cert-)" "$OBJ0" "the objects created for the failed attempt were removed"
expect_eq "$(stage_left)" "0" "the failed attempt left no staging directory"
fi

#######################################################################
if want s9; then
echo "== s9: verification failure rolls back automatically"
#######################################################################
use_cert h
conf "[deploy:rb]
f5 = t
cert = zt
profile = zzz-t1
verify = ${VSB}:443 zzz.test
"
PREV="$(bound_cert zzz-t1 e1)"; PREVFP="$(bound_fp zzz-t1 e1)"; OBJ0="$(obj_count cert zzz-cert-cert-)"
tool --deploy rb --force
expect_rc 3 "a verify mismatch exits 3 (rolled back)"; expect_has "ROLLING BACK" "the rollback is announced"; expect_has "ROLLED_BACK" "the summary says ROLLED_BACK"
expect_eq "$(bound_cert zzz-t1 e1)" "$PREV" "the profile is back on its previous certificate"
expect_eq "$(served_fp "$VSA")" "$PREVFP" "the virtual server serves the previous certificate again"
expect_eq "$(obj_count cert zzz-cert-cert-)" "$OBJ0" "the objects from the failed attempt were removed"
AUTOROLL=no conf "[deploy:rb]
f5 = t
cert = zt
profile = zzz-t1
verify = ${VSB}:443 zzz.test
"
tool --deploy rb --force
expect_rc 1 "with auto_rollback = no a mismatch exits 1"; expect_has "auto_rollback is off" "the manual rollback command is printed"
expect_eq "$(bound_fp zzz-t1 e1)" "$CUR_FP" "the BIG-IP stays on the new certificate when auto_rollback = no"
TSX="$(printf '%s\n' "$OUT" | sed -n 's/.*--rollback --set \([0-9-]*\).*/\1/p' | head -1)"
tool --deploy rb --rollback --set "$TSX"
expect_rc 0 "the printed rollback command works"; expect_eq "$(bound_cert zzz-t1 e1)" "$PREV" "manual rollback restored the previous certificate"
# endpoint that does not answer
conf "[deploy:dead]
f5 = t
cert = zt
profile = zzz-t1
verify = 10.1.10.99:443
"
tool --deploy dead --force
expect_rc 0 "an unreachable endpoint only warns by default"; expect_has "no TLS handshake" "the warning is shown"; expect_eq "$(bound_fp zzz-t1 e1)" "$CUR_FP" "the deploy stood"
VUN=fail conf "[deploy:dead]
f5 = t
cert = zt
profile = zzz-t1
verify = 10.1.10.99:443
"
PREV="$(bound_cert zzz-t1 e1)"
use_cert a
tool --deploy dead --force
expect_rc 3 "verify_unreachable = fail rolls back"; expect_eq "$(bound_cert zzz-t1 e1)" "$PREV" "the previous certificate is restored"
fi

#######################################################################
if want s10; then
echo "== s10: retention keeps only the newest sets"
#######################################################################
PREFIX=zzz-ret KEEP=2 conf "[deploy:ret]
f5 = t
cert = zt
profile = zzz-t4
"
for n in a b c d e; do
  use_cert "$n"; PREFIX=zzz-ret KEEP=2 conf "[deploy:ret]
f5 = t
cert = zt
profile = zzz-t4
"
  tool --deploy ret; expect_rc 0 "retention run with certificate $n"
done
expect_eq "$(remote_backups zzz-ret)" "2" "only 2 backup sets remain on the BIG-IP"
expect_eq "$(local_backups zzz-ret)" "2" "only 2 backup sets remain on this host"
expect_eq "$(obj_count cert zzz-ret-cert-)" "2" "only 2 certificate versions remain"
expect_eq "$(obj_count cert zzz-ret-chain-)" "2" "only 2 chain versions remain"
expect_eq "$(obj_count key zzz-ret-privkey-)" "2" "only 2 key versions remain"
expect_eq "$(bound_fp zzz-t4 e1)" "$CUR_FP" "the newest version is the one in use"
KEEP=0 PREFIX=zzz-ret conf "[deploy:ret]
f5 = t
cert = zt
profile = zzz-t4
"
use_cert f; tool --deploy ret
expect_eq "$(remote_backups zzz-ret)" "3" "keep = 0 disables pruning"
fi

#######################################################################
if want s11; then
echo "== s11: one run at a time per BIG-IP"
#######################################################################
use_cert a
conf "$BASE_DEPLOY"
mkdir -p "$LOCKS"; chmod 700 "$LOCKS"
LK="$LOCKS/$(printf '%s_%s' "$HOST" "$PORT" | tr -c 'A-Za-z0-9._-' '_').lock"
sleep 120 & HOLDER=$!
mkdir -m 700 "$LK"; echo "$HOLDER" > "$LK/pid"
S0="$(snapshot)"
tool --deploy basic --force
expect_rc 6 "a live lock makes the run exit 6"; expect_has "holds the lock" "the lock holder is reported"; expect_eq "$(snapshot)" "$S0" "a locked-out run changed nothing"
tool --deploy basic --check; expect_rc 4 "read-only runs do not need the lock"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
tool --deploy basic --force
expect_rc 0 "a stale lock (dead process) is cleaned up and the run proceeds"; expect_has "stale lock" "the stale lock is reported"
expect_eq "$(ls -A "$LOCKS" | wc -l)" "0" "the lock is gone afterwards"
# a lock held ON THE BIG-IP by another host
S0="$(snapshot)"
f5 "mkdir -m 700 /var/run/f5-cert-push.lock && printf 'tok\nadmin@other-host pid 4242\n' > /var/run/f5-cert-push.lock/owner"
tool --deploy basic --force
expect_rc 6 "a lock held on the BIG-IP by another host gives exit 6"; expect_has "holds the lock on the BIG-IP" "the BIG-IP lock is reported"; expect_has "admin@other-host" "the lock owner is shown"
expect_eq "$(snapshot)" "$S0" "a run locked out by another host changed nothing"
expect_true "the other host's lock was NOT removed" f5 "test -d /var/run/f5-cert-push.lock"
tool --deploy basic --check; expect_rc 0 "read-only runs ignore the BIG-IP lock (and the BIG-IP is current)"
f5 "touch -d '3 hours ago' /var/run/f5-cert-push.lock"
tool --deploy basic --force
expect_rc 0 "a stale BIG-IP lock (older than the limit) is taken over"; expect_has "stale lock on the BIG-IP" "the takeover is reported"
expect_true "the BIG-IP lock is gone afterwards" f5 "test ! -d /var/run/f5-cert-push.lock"
# two runs at once
( "$BIN" --config "$CF" --deploy basic --force >"$TMP/bg1.out" 2>&1; echo $? > "$TMP/bg1.rc" ) &
sleep 2
run "$BIN" --config "$CF" --deploy basic --force
expect_rc 6 "a second concurrent run exits 6"
wait; expect_eq "$(cat "$TMP/bg1.rc")" "0" "the first concurrent run completed normally"
fi

#######################################################################
if want s12; then
echo "== s12: interruption at any point leaves a consistent BIG-IP and no debris"
#######################################################################
use_cert a
conf "$BASE_DEPLOY"
tool --deploy basic --force >/dev/null
for T in 2 4 6 8 11 14; do
  use_cert "$( [[ $((T % 4)) -eq 0 ]] && echo b || echo c )"
  run timeout -s TERM "$T" "$BIN" --config "$CF" --deploy basic --force
  t_case "interrupted after ${T}s"
  LEFT="$(stage_left)"
  expect_eq "$LEFT" "0" "after ${T}s: no staging directory left on the BIG-IP"
  expect_eq "$(ls -A "$LOCKS" 2>/dev/null | wc -l)" "0" "after ${T}s: the lock was released"
  expect_true "after ${T}s: the BIG-IP-side lock was released" f5 "test ! -d /var/run/f5-cert-push.lock"
  sleep 1; expect_eq "$(pgrep -fc 'f5-cert-push\.[A-Za-z0-9]+/cm-' || true)" "0" "after ${T}s: no stray shared SSH connection left by the tool"
  OKALL=1
  for p in zzz-t1 zzz-t2; do
    c="$(bound_cert "$p" e1)"; h="$(bound_chain "$p" e1)"; k="$(bound_key "$p" e1)"
    obj_exists cert "$c" && obj_exists key "$k" && { [[ "$h" == none ]] || obj_exists cert "$h"; } || OKALL=0
  done
  expect_eq "$OKALL" "1" "after ${T}s: every profile still points at objects that exist"
  expect_eq "$(bound_cert zzz-t1 e1 | sed 's/-cert-[0-9].*//')" "zzz-cert" "after ${T}s: zzz-t1 is still on a managed certificate"
  [[ "$(bound_cert zzz-t1 e1)" == "$(bound_cert zzz-t2 e1)" ]] && t_pass "after ${T}s: both profiles agree (transaction was atomic)" || t_fail "after ${T}s: the profiles disagree"
done
use_cert d; tool --deploy basic --force; expect_rc 0 "a normal run succeeds after the interruptions"
fi

#######################################################################
if want s13; then
echo "== s13: no profile configured: fixed-name objects are replaced in place"
#######################################################################
use_cert a
PREFIX=zzz-obj conf "[deploy:objs]
f5 = t
cert = zt
"
tool --deploy objs --dry-run --force
expect_rc 0 "objects-only dry run"; expect_has "overwrite" "the plan says it overwrites the fixed-name objects in place"
tool --deploy objs
expect_rc 0 "objects-only first deploy"
expect_eq "$(obj_fp zzz-obj-cert.pem)" "$CUR_FP" "the fixed-name certificate holds the new certificate"
expect_true "the fixed-name key exists" obj_exists key zzz-obj-privkey.pem
expect_true "the fixed-name chain exists" obj_exists cert zzz-obj-chain.pem
expect_true "the fixed-name fullchain exists" obj_exists cert zzz-obj-fullchain.pem
tool --deploy objs; expect_rc 0 "rerun"; expect_has "UPTODATE" "objects-only rerun is UPTODATE"
FIRST="$CUR_FP"; use_cert b
tool --deploy objs; expect_rc 0 "objects-only renewal"; expect_eq "$(obj_fp zzz-obj-cert.pem)" "$CUR_FP" "the certificate was replaced in place"
BO="$(newest_backup zzz-obj)"
tool --deploy objs --rollback --set "$BO"
expect_rc 0 "objects-only rollback"; expect_eq "$(obj_fp zzz-obj-cert.pem)" "$FIRST" "rollback restored the previous certificate"
fi

#######################################################################
if want s14; then
echo "== s14: fixed_names = yes alongside a profile"
#######################################################################
use_cert c
PREFIX=zzz-fx conf "[deploy:fx]
f5 = t
cert = zt
profile = zzz-t4
fixed_names = yes
"
tool --deploy fx
expect_rc 0 "deploy with fixed_names = yes"
expect_eq "$(bound_fp zzz-t4 e1)" "$CUR_FP" "the profile uses the new certificate"
expect_eq "$(obj_fp zzz-fx-cert.pem)" "$CUR_FP" "the fixed-name certificate was refreshed too"
expect_true "the fixed-name key exists" obj_exists key zzz-fx-privkey.pem
fi

#######################################################################
if want s15; then
echo "== s15: a non-Common partition"
#######################################################################
f5 "tmsh create auth partition zzz-part >/dev/null && tmsh create ltm profile client-ssl /zzz-part/zzz-pp defaults-from /Common/clientssl cert-key-chain replace-all-with { pe { cert /Common/default.crt key /Common/default.key } } >/dev/null && tmsh save sys config >/dev/null"
expect_true "the test partition and profile exist" f5 "tmsh -q list ltm profile client-ssl /zzz-part/zzz-pp | grep -q zzz-pp"
use_cert a
PART=zzz-part PREFIX=zzz-pt KEEP=1 conf "[deploy:part]
f5 = t
cert = zt
profile = zzz-pp
"
tool --deploy part
expect_rc 0 "deploy into a partition (bare profile name is resolved)"
PC="$(f5 "tmsh -q list ltm profile client-ssl /zzz-part/zzz-pp cert-key-chain" | awk '/^            cert /{print $2}')"
expect_has_str() { [[ "$1" == *"$2"* ]] && t_pass "$3" || t_fail "$3" "'$1' lacks '$2'"; }
expect_has_str "$PC" "/zzz-part/zzz-pt-cert-" "the profile uses a certificate object in the partition"
expect_eq "$(f5 "tmsh -q list sys file ssl-cert $PC fingerprint" | awk '$1=="fingerprint"{print $2}' | sed 's#.*/##' | tr -d ':')" "$CUR_FP" "the partition certificate is the new certificate"
use_cert b
PART=zzz-part PREFIX=zzz-pt KEEP=1 conf "[deploy:part]
f5 = t
cert = zt
profile = zzz-pp
"
tool --deploy part; expect_rc 0 "renewal in the partition"
expect_eq "$(f5 "printf '%s\n' 'cd /' 'list sys file ssl-cert one-line recursive' | tmsh -q | awk '{print \$4}' | grep -c '^zzz-part/zzz-pt-cert-'")" "1" "pruning works inside the partition (keep = 1)"
BP="$(newest_backup zzz-pt)"
tool --deploy part --rollback --set "$BP"
expect_rc 0 "rollback in the partition"
fi

#######################################################################
if want s16; then
echo "== s16: SSH trust and reachability"
#######################################################################
use_cert a
: > "${TMP}/empty_kh"
conf "$BASE_DEPLOY"
sed -i "s#^known_hosts_file = ${KH}#known_hosts_file = ${TMP}/empty_kh#" "$CF"
S0="$(snapshot)"
tool --deploy basic --check
expect_rc 1 "an unknown host key is refused by default"; expect_eq "$(snapshot)" "$S0" "nothing changed"
sed -i 's#^connect_timeout = 10#connect_timeout = 10\nstrict_host_key_checking = accept-new#' "$CF"
tool --deploy basic --check
expect_rc 4 "strict_host_key_checking = accept-new trusts a first-seen host"
expect_true "the host key was pinned" test -s "${TMP}/empty_kh"
conf "$BASE_DEPLOY"; sed -i "s#^host = ${HOST}#host = 198.51.100.1#; s#^connect_timeout = 10#connect_timeout = 3#" "$CF"
START=$SECONDS; tool --deploy basic --check; ELAPSED=$((SECONDS - START))
expect_rc 1 "an unreachable BIG-IP fails"; [[ $ELAPSED -lt 40 ]] && t_pass "the unreachable BIG-IP failed fast (${ELAPSED}s)" || t_fail "the unreachable BIG-IP took ${ELAPSED}s"
conf "$BASE_DEPLOY"; ssh-keygen -q -t ecdsa -N '' -f "${TMP}/wrongkey" >/dev/null; sed -i "s#^ssh_key = .*#ssh_key = ${TMP}/wrongkey#" "$CF"
tool --deploy basic --check; expect_rc 1 "a key the BIG-IP does not trust fails"
conf "$BASE_DEPLOY"; sed -i "s#^ssh_key = .*#ssh_key = ${TMP}/no-such-key#" "$CF"
tool --deploy basic --check; expect_rc 1 "a missing ssh key file fails"; expect_has "not readable" "the missing key is reported"
fi

#######################################################################
if want s17; then
echo "== s17: several deployments in one run"
#######################################################################
use_cert e
conf "[deploy:good]
f5 = t
cert = zt
profile = zzz-t1
[deploy:broken]
f5 = t
cert = zt
profile = zzz-doesnotexist
[deploy:also-good]
f5 = t, t2
cert = zt
profile = zzz-t2
"
tool --all
expect_rc 1 "a failing deployment makes the run exit 1"; expect_has "UPDATED" "the good deployments still ran"; expect_has "FAILED" "the failure is in the summary"
expect_eq "$(bound_fp zzz-t1 e1)" "$CUR_FP" "zzz-t1 (good) was updated"; expect_eq "$(bound_fp zzz-t2 e1)" "$CUR_FP" "zzz-t2 (also-good, two BIG-IP names for one device) was updated"
expect_has "also-good@t2" "the second BIG-IP name was processed"
use_cert f
tool --all --fail-fast
expect_rc 1 "--fail-fast exits 1"; expect_has "stopping after the first failure" "--fail-fast stops"; expect_lacks "also-good@t " "deployments after the failure did not run"
fi

#######################################################################
if want s18; then
echo "== s18: certbot-style lineage selection"
#######################################################################
mkdir -p "$TMP/le/archive/zzz.test" "$TMP/le/live/zzz.test"
use_cert a
cp "$PKI/a.pem" "$TMP/le/archive/zzz.test/cert1.pem"; cp "$PKI/a.chain.pem" "$TMP/le/archive/zzz.test/chain1.pem"
cp "$PKI/a.full.pem" "$TMP/le/archive/zzz.test/fullchain1.pem"; cp "$PKI/a.key" "$TMP/le/archive/zzz.test/privkey1.pem"
for f in cert chain fullchain privkey; do ln -sf "../../archive/zzz.test/${f}1.pem" "$TMP/le/live/zzz.test/${f}.pem"; done
cat > "$CF" <<EOF
[defaults]
backup_dir_local = ${BK}
lock_dir = ${LOCKS}
connect_timeout = 10
[f5:t]
host = ${HOST}
port = ${PORT}
ssh_key = ${KEY}
known_hosts_file = ${KH}
[cert:le]
le_dir = ${TMP}/le/live/zzz.test
object_prefix = zzz-le
[deploy:le]
f5 = t
cert = le
profile = zzz-t1
verify = ${VSA}:443
EOF
chmod 600 "$CF"
tool --lineage "${TMP}/le/live/zzz.test"
expect_rc 0 "--lineage selects and deploys the matching certificate"; expect_eq "$(bound_fp zzz-t1 e1)" "$(fp_of "$PKI/a.pem")" "the le_dir certificate is now on the profile"
expect_eq "$(served_fp "$VSA")" "$(fp_of "$PKI/a.pem")" "the virtual server (zzz-t1) serves the le_dir certificate"
tool --lineage "${TMP}/le/live/other.example.com"
expect_rc 0 "--lineage for an unmanaged certificate exits 0"
fi

#######################################################################
if want s19; then
echo "== s19: verifying from the local host (verify_from = local)"
#######################################################################
use_cert b
LPORT=$((20000 + RANDOM % 20000))
openssl s_server -quiet -accept "$LPORT" -cert "$PKI/b.pem" -key "$PKI/b.key" -cert_chain "$PKI/b.chain.pem" >/dev/null 2>&1 &
SERVER_PID=$!; sleep 1
conf "[deploy:lv]
f5 = t
cert = zt
profile = zzz-t4
verify = 127.0.0.1:${LPORT} zzz.test
verify_from = local
"
tool --deploy lv
expect_rc 0 "a local endpoint serving the new certificate verifies"; expect_has "checked from local" "the probe ran locally"
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
openssl s_server -quiet -accept "$LPORT" -cert "$PKI/a.pem" -key "$PKI/a.key" >/dev/null 2>&1 &
SERVER_PID=$!; sleep 1
use_cert c; PREV="$(bound_cert zzz-t4 e1)"
tool --deploy lv
expect_rc 3 "a local endpoint serving a different certificate rolls back"; expect_eq "$(bound_cert zzz-t4 e1)" "$PREV" "the profile was restored"
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""
fi

#######################################################################
if want s20; then
echo "== s20: manual upload -> f5-cert-install.sh -> push to the BIG-IP"
#######################################################################
UPIN="${TMP}/up-incoming"; UPST="${TMP}/up-store"; mkdir -p "$UPIN"
cat > "$CF" <<EOF
[defaults]
backup_dir_local = ${BK}
lock_dir = ${LOCKS}
connect_timeout = 10
chain_check = fail
min_days_valid = 1
[f5:t]
host = ${HOST}
port = ${PORT}
user = ${BUSER}
ssh_key = ${KEY}
known_hosts_file = ${KH}
[cert:up]
le_dir = ${UPST}/up/current
object_prefix = zzz-up
[deploy:up]
f5 = t
cert = up
profile = zzz-t1
verify = ${VSA}:443 zzz.test
EOF
chmod 600 "$CF"
INST="${T_DIR}/../f5-cert-install.sh"
up() { mkdir -p "$UPIN/up"; cp "$PKI/$1.pem" "$UPIN/up/cert.pem"; cp "$PKI/$1.chain.pem" "$UPIN/up/chain.pem"; cp "$PKI/$1.key" "$UPIN/up/privkey.pem"; touch "$UPIN/up/READY"; }
up b
run "$INST" --config "$CF" --incoming "$UPIN" --store "$UPST" --min-days 1
expect_rc 0 "an uploaded certificate is installed and pushed"; expect_has "installed 'up'" "the install is reported"; expect_has "UPDATED" "the push is reported"
expect_eq "$(bound_fp zzz-t1 e1)" "$(fp_of "$PKI/b.pem")" "the profile uses the uploaded certificate"
expect_eq "$(served_fp "$VSA")" "$(fp_of "$PKI/b.pem")" "the virtual server serves the uploaded certificate"
expect_false "no push is pending" test -e "$UPST/.push-pending"
expect_false "the uploaded key was removed" test -e "$UPIN/up/privkey.pem"
run "$INST" --config "$CF" --incoming "$UPIN" --store "$UPST"
expect_rc 0 "a run with no new upload"; expect_lacks "pushing to the BIG-IPs" "does not contact the BIG-IPs"
up c
run "$INST" --config "$CF" --incoming "$UPIN" --store "$UPST" --min-days 1
expect_rc 0 "a second upload (renewal)"; expect_eq "$(served_fp "$VSA")" "$(fp_of "$PKI/c.pem")" "the virtual server serves the renewal"
mkdir -p "$UPIN/up"; cp "$PKI/d.pem" "$UPIN/up/cert.pem"; cp "$PKI/d.chain.pem" "$UPIN/up/chain.pem"; cp "$PKI/a.key" "$UPIN/up/privkey.pem"; touch "$UPIN/up/READY"
run "$INST" --config "$CF" --incoming "$UPIN" --store "$UPST" --min-days 1
expect_rc 1 "a bad upload (wrong key) is rejected"; expect_eq "$(served_fp "$VSA")" "$(fp_of "$PKI/c.pem")" "the BIG-IP still serves the previous certificate"
expect_true "the rejection is explained in FAILED" test -s "$UPIN/up/FAILED"
fi

t_summary
