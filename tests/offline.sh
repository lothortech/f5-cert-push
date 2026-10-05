#!/usr/bin/env bash
# Offline test suite for f5-cert-push: needs no BIG-IP and no network.
#
#   tests/offline.sh            run everything
#   T_VERBOSE=1 tests/offline.sh    show output for failures
#
# Covers: configuration parsing and validation, injection attempts, deployment
# selection, certificate validation (generated PKI), and command-line handling.

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CF="${TMP}/c.conf"
cfg() { printf '%s' "$1" > "$CF"; chmod 600 "$CF"; }

# reject DESC BODY PATTERN : the config must be refused (exit 2) with PATTERN in the message
reject() { t_case "reject: $1"; cfg "$2"; run "$BIN" --config "$CF" --list; expect_rc 2 "reject: $1 (exit 2)"; expect_has "$3" "reject: $1 (message)"; }
# accept DESC BODY : the config must load (exit 0)
accept() { t_case "accept: $1"; cfg "$2"; run "$BIN" --config "$CF" --list; expect_rc 0 "accept: $1"; }

#######################################################################
echo "== command line"
#######################################################################
run "$BIN" --version;            expect_rc 0 "--version exits 0";                  expect_has "f5-cert-push" "--version names the tool"
run "$BIN" --help;               expect_rc 0 "--help exits 0";                     expect_has "EXIT CODES" "--help documents exit codes"
run "$BIN" --bogus;              expect_rc 2 "unknown option exits 2";             expect_has "unknown option" "unknown option is named"
run "$BIN" --config;             expect_rc 2 "--config without a value exits 2"
run "$BIN" --config /nonexistent/x.conf --list; expect_rc 2 "missing config file exits 2"; expect_has "cannot read" "missing config is reported"
cfg "$BASE_CONF"
run "$BIN" --config "$CF" --dry-run;           expect_rc 2 "a run without a selector is refused";   expect_has "say what to act on" "selector refusal explains itself"
run "$BIN" --config "$CF" --all --dry-run --check; expect_rc 2 "--dry-run with --check is refused"
run "$BIN" --config "$CF" --deploy nope --dry-run; expect_rc 2 "unknown deployment is refused";       expect_has "no such deployment" "unknown deployment is named"
run "$BIN" --config "$CF" --f5 nope --list;    expect_rc 2 "unknown BIG-IP is refused";              expect_has "no such BIG-IP" "unknown BIG-IP is named"
run "$BIN" --config "$CF" --deploy=d --list;   expect_rc 0 "--opt=value form is accepted"
run "$BIN" --config "$CF" --rollback --deploy d --set bogus; expect_rc 2 "--rollback needs a well-formed --set"
run "$BIN" --config "$CF" --discover;          expect_rc 2 "--discover needs exactly one --f5"

#######################################################################
echo "== configuration: accepted forms"
#######################################################################
accept "minimal config"                "$BASE_CONF"
accept "CRLF line endings"             "$(printf '%s' "$BASE_CONF" | sed 's/$/\r/')"$'\n'
accept "comments with non-ASCII text"  "# caf$(printf '\303\251') and notes
${BASE_CONF}"
accept "quoted values"                 '[f5:a]
host = "10.0.0.1"
[cert:c]
cert = '"'"'/etc/x.crt'"'"'
key = /etc/x.key
[deploy:d]
f5 = a
cert = c
'
accept "comma-separated and repeated f5"  "$BASE_CONF
[f5:b]
host = 10.0.0.2
[deploy:e]
f5 = a, b
f5 = a
cert = c
"
accept "tabs around the equals sign"  "$(printf '[f5:a]\nhost\t=\t10.0.0.1\n[cert:c]\ncert = /e/x\nkey = /e/y\n[deploy:d]\nf5 = a\ncert = c\n')"
accept "IPv6 host"                     "[f5:a]
host = 2001:db8::1
[cert:c]
cert = /e/x
key = /e/y
[deploy:d]
f5 = a
cert = c
"
accept "verify endpoints (plain, SNI, IPv6)" "${BASE_CONF}profile = www
verify = 10.1.1.1:443
verify = vs.example.com:8443 www.example.com
verify = [2001:db8::1]:443
"
accept "leading-zero numbers (keep = 08)" "${BASE_CONF}keep = 08
"
accept "profiles: plain, entry, partition-qualified" "${BASE_CONF}profile = a
profile = b:e1
profile = /Part/c
profile = /Part/d:e2
"

#######################################################################
echo "== configuration: structural errors"
#######################################################################
reject "unknown section type"     "[bogus:x]
a = b
"                                                   "unknown section type"
reject "section without a name"   "[f5]
host = 1.2.3.4
"                                                   "needs a name"
reject "[defaults] with a name"   "[defaults:x]
keep = 1
"                                                   "takes no name"
reject "setting outside a section" "host = 1.2.3.4
"                                                   "outside of a valid section"
reject "unknown setting (typo)"   "${BASE_CONF}
[f5:z]
host = 1.2.3.4
hots = 1.2.3.5
"                                                   "unknown setting 'hots'"
reject "setting in the wrong section type" "[f5:z]
host = 1.2.3.4
le_dir = /x
"                                                   "unknown setting 'le_dir'"
reject "duplicate section"        "${BASE_CONF}
[f5:a]
host = 1.2.3.4
"                                                   "duplicate section"
reject "duplicate singleton key"  "[f5:a]
host = 1.2.3.4
host = 1.2.3.5
"                                                   "is set twice"
reject "garbage line"             "[f5:a]
this is not a setting
"                                                   "not a section header"
reject "UTF-8 byte-order mark"    "$(printf '\357\273\277')[f5:a]
host = 1.2.3.4
"                                                   "non-printable or non-ASCII"
reject "non-ASCII value"          "[f5:a]
host = caf$(printf '\303\251').example
"                                                   "non-printable or non-ASCII"
reject "control character in a value" "[f5:a]
host = 1.2.$(printf '\001')3.4
"                                                   "non-printable or non-ASCII"
reject "empty repeatable value"   "${BASE_CONF}profile =
"                                                   "needs a value"

#######################################################################
echo "== configuration: cross-reference errors"
#######################################################################
reject "f5 without a host"        "[f5:a]
port = 22
"                                                   "'host' is required"
reject "cert section without files" "[cert:c]
object_prefix = x
"                                                   "set le_dir, or set key"
reject "cert with 'cert' but no key" "[cert:c]
cert = /e/x
"                                                   "'key' is required"
reject "cert with key but no cert" "[cert:c]
key = /e/x
"                                                   "'cert' or 'fullchain' is required"
reject "deploy without f5"        "[cert:c]
cert = /e/x
key = /e/y
[deploy:d]
cert = c
"                                                   "'f5' is required"
reject "deploy without cert"      "[f5:a]
host = 1.2.3.4
[deploy:d]
f5 = a
"                                                   "'cert' is required"
reject "deploy naming an undefined cert" "[f5:a]
host = 1.2.3.4
[deploy:d]
f5 = a
cert = ghost
"                                                   "has no [cert:ghost] section"
reject "deploy naming an undefined f5"  "[cert:c]
cert = /e/x
key = /e/y
[deploy:d]
f5 = ghost
cert = c
"                                                   "has no [f5:ghost] section"
reject "same profile managed by two deployments" "${BASE_CONF}profile = www
[deploy:e]
f5 = a
cert = c
profile = www
"                                                   "already managed by deployment"
reject "one prefix used by two certificates on a BIG-IP" "[f5:a]
host = 1.2.3.4
[cert:c1]
cert = /e/x
key = /e/y
object_prefix = same
[cert:c2]
cert = /e/p
key = /e/q
object_prefix = same
[deploy:d1]
f5 = a
cert = c1
[deploy:d2]
f5 = a
cert = c2
"                                                   "already used by cert"

#######################################################################
echo "== configuration: value validation and injection attempts"
#######################################################################
PWN="${TMP}/PWNED"
inj() {   # inj DESC KEY VALUE [SECTION-HEADER-SNIPPET]  -> must be refused and must not execute anything
  local sect="$4"
  t_case "injection: $1"
  cfg "$(printf '%s\n%s = %s\n' "${sect:-[f5:a]}" "$2" "$3")
[cert:c]
cert = /e/x
key = /e/y
[deploy:d]
f5 = a
cert = c
"
  run "$BIN" --config "$CF" --list
  expect_rc 2 "injection: $1 is refused"
  if [[ -e "$PWN" ]]; then t_fail "injection: $1 EXECUTED a command"; else t_pass "injection: $1 executed nothing"; fi
}
inj "host with ; and a command"       host  "10.0.0.1;touch ${PWN}"
inj "host with \$(...)"               host  "\$(touch ${PWN})"
inj "host with backticks"             host  "\`touch ${PWN}\`"
inj "host starting with a hyphen"     host  "-oProxyCommand=touch${PWN}"
inj "host with a space"               host  "10.0.0.1 -v"
inj "host with a pipe"                host  "10.0.0.1|cat"
inj "user with a semicolon"           user  "root;id"
inj "user with uppercase/odd chars"   user  "Root\$x"
inj "port out of range"               port  "70000"
inj "port not numeric"                port  "22a"
inj "partition with a slash"          partition "Common/x"
inj "ssh_key relative path"           ssh_key "keys/id"
inj "ssh_key with parent traversal"   ssh_key "/root/../etc/shadow"
inj "ssh_key with a space"            ssh_key "/root/my key"
inj "ssh_key with a semicolon"        ssh_key "/root/k;touch ${PWN}"
inj "ssh_key with a backtick"         ssh_key "/root/\`id\`"
inj "ssh_key with a double slash"     ssh_key "/root//k"
inj "known_hosts_file with \$VAR"     known_hosts_file "/root/\$HOME/kh"
inj "strict_host_key_checking off"    strict_host_key_checking "no"
inj "backup_dir_remote is the root"   backup_dir_remote "/" "[defaults]"
inj "backup_dir_local is the root"    backup_dir_local "/" "[defaults]"
inj "lock_dir is the root"            lock_dir "/" "[defaults]"
inj "remote_lock_stale_minutes zero"  remote_lock_stale_minutes "0"
inj "remote_lock_stale_minutes text"  remote_lock_stale_minutes "soon"
inj "keep negative"                   keep  "-1"
inj "keep not a number"               keep  "lots"
inj "timeout zero"                    connect_timeout "0"
inj "boolean not yes/no"              auto_rollback "maybe"
inj "verify_unreachable bad value"    verify_unreachable "ignore"
inj "chain_check bad value"           chain_check "sometimes"
inj "backup_dir_remote with spaces"   backup_dir_remote "/shared/my backups" "[defaults]"
inj "log_file relative"               log_file "f5.log" "[defaults]"
inj "section name with a slash"       host "1.2.3.4" "[f5:a/b]"
inj "section name starting with a dot" host "1.2.3.4" "[f5:.hidden]"
inj "object_prefix with a slash"      object_prefix "a/b" "[cert:c]"
inj "object_prefix too long"          object_prefix "$(printf 'p%.0s' {1..60})" "[cert:c]"
inj "profile with a semicolon"        profile "www;touch ${PWN}" "[deploy:d]"
inj "profile with \$(...)"            profile "\$(touch ${PWN})" "[deploy:d]"
inj "profile with a space"            profile "a b" "[deploy:d]"
inj "profile with a brace"            profile "a}b" "[deploy:d]"
inj "profile entry with a semicolon"  profile "www:e;id" "[deploy:d]"
inj "profile partition with spaces"   profile "/Bad Part/x" "[deploy:d]"
inj "verify with a command"           verify "10.0.0.1:443;touch ${PWN}" "[deploy:d]"
inj "verify port out of range"        verify "10.0.0.1:99999" "[deploy:d]"
inj "verify without a host"           verify ":443" "[deploy:d]"
inj "verify SNI with a space/shell"   verify "10.0.0.1:443 a\$(id)" "[deploy:d]"
inj "verify_from bad value"           verify_from "remote" "[deploy:d]"
inj "env with a space"                env "prod west" "[deploy:d]"
inj "enabled not a boolean"           enabled "perhaps" "[deploy:d]"

#######################################################################
echo "== configuration file permissions"
#######################################################################
cfg "$BASE_CONF"
chmod 666 "$CF"
if [[ "$(stat -c %a "$CF")" == 666 ]]; then
  run "$BIN" --config "$CF" --list; expect_rc 2 "a world-writable config is refused"; expect_has "writable by group or others" "permission refusal explains itself"
  chmod 620 "$CF"
  run "$BIN" --config "$CF" --list; expect_rc 2 "a group-writable config is refused"
  chmod 600 "$CF"; run "$BIN" --config "$CF" --list; expect_rc 0 "a 0600 config is accepted"
  chmod 644 "$CF"; run "$BIN" --config "$CF" --list; expect_rc 0 "a 0644 config is accepted"
else
  t_skip "config permission checks" "this filesystem does not honour chmod"
fi

#######################################################################
echo "== deployment selection"
#######################################################################
SEL_CONF='[f5:a]
host = 10.0.0.1
[f5:b]
host = 10.0.0.2
[cert:w]
le_dir = /etc/letsencrypt/live/w.example.com
[cert:v]
le_dir = /etc/letsencrypt/live/v.example.com
[deploy:prod-w]
env = prod
f5 = a
f5 = b
cert = w
profile = pw
[deploy:prod-v]
env = prod
f5 = a
cert = v
profile = pv
[deploy:lab-w]
env = lab
f5 = b
cert = w
profile = lw
[deploy:off]
env = prod
enabled = no
f5 = a
cert = v
profile = po
'
cfg "$SEL_CONF"
run "$BIN" --config "$CF" --list --deploy prod-w
expect_has "deployment prod-w" "--deploy selects the named deployment"; expect_lacks "deployment lab-w" "--deploy does not select others"
run "$BIN" --config "$CF" --list --env prod
expect_has "deployment prod-w" "--env prod includes prod-w"; expect_has "deployment prod-v" "--env prod includes prod-v"; expect_lacks "deployment lab-w" "--env prod excludes lab"; expect_lacks "deployment off" "--env prod skips a disabled deployment"
run "$BIN" --config "$CF" --list --all
expect_has "deployment lab-w" "--all includes every enabled deployment"; expect_lacks "deployment off" "--all skips a disabled deployment"
run "$BIN" --config "$CF" --list --env prod --f5 b
expect_has "BIG-IP      b" "--f5 narrows to one BIG-IP"; expect_lacks "BIG-IP      a" "--f5 excludes the other BIG-IP"
run "$BIN" --config "$CF" --list --lineage /etc/letsencrypt/live/v.example.com/
expect_has "deployment prod-v" "--lineage selects by le_dir (trailing slash tolerated)"; expect_lacks "deployment prod-w" "--lineage excludes other certs"
run "$BIN" --config "$CF" --lineage /etc/letsencrypt/live/unmanaged.example.com --dry-run
expect_rc 0 "--lineage for an unmanaged cert exits 0 (a certbot hook must not fail)"; expect_has "nothing to do" "--lineage no-match says so"
run "$BIN" --config "$CF" --deploy off --dry-run
expect_rc 2 "naming only a disabled deployment selects nothing"

#######################################################################
# The certificate cases need a modern openssl (req -addext) to build the test PKI.
# T_SKIP_CERTS=1 skips them, e.g. to run the parser tests on an old platform.
#######################################################################
if [[ "${T_SKIP_CERTS:-}" == 1 ]]; then
  t_skip "certificate validation cases" "T_SKIP_CERTS=1"
else
#######################################################################
echo "== certificates: generated PKI"
#######################################################################
P1="${TMP}/pki1"; P2="${TMP}/pki2"
pki_init "$P1"; pki_init "$P2"
pki_leaf "$P1" good    "good.test"  "DNS:good.test,DNS:*.good.test"
pki_leaf "$P1" ecgood  "ec.test"    "DNS:ec.test" ec
pki_leaf "$P1" old     "old.test"   "DNS:old.test"  rsa 20200101000000Z 20200102000000Z
pki_leaf "$P1" future  "fut.test"   "DNS:fut.test"  rsa 20400101000000Z 20400301000000Z
pki_leaf "$P1" wild    "*.wild.test" "DNS:*.wild.test"
pki_leaf "$P2" other   "other.test" "DNS:other.test"
if [[ ! -s "$P1/good.pem" || ! -s "$P1/ecgood.pem" || ! -s "$P1/old.pem" ]]; then
  t_fail "test PKI generation"; t_summary; exit 1
fi

certconf() {   # certconf "extra lines for [cert:t]"
  cfg "[f5:a]
host = 10.0.0.1
[cert:t]
$1
[deploy:d]
f5 = a
cert = t
"
}
vcert() { run "$BIN" --config "$CF" --validate; }

certconf "cert = $P1/good.pem
key = $P1/good.key
chain = $P1/good.chain.pem"
vcert; expect_rc 0 "valid RSA leaf + chain"; expect_has "sha256" "valid cert is summarised"

certconf "cert = $P1/ecgood.pem
key = $P1/ecgood.key
chain = $P1/ecgood.chain.pem"
vcert; expect_rc 0 "valid ECDSA leaf + chain"; expect_has "id-ecPublicKey" "ECDSA key type is reported"

certconf "cert = $P1/good.pem
key = $P1/good.key"
vcert; expect_rc 0 "leaf and key with no chain at all"

certconf "fullchain = $P1/good.full.pem
key = $P1/good.key"
vcert; expect_rc 0 "fullchain + key only (leaf and chain split automatically)"

certconf "cert = $P1/good.pem
key = $P1/good.key
chain = $P2/other.chain.pem
chain_check = warn"
vcert; expect_rc 0 "a chain that does not match only warns by default"; expect_has "does not verify against the supplied chain" "chain mismatch is reported"

certconf "cert = $P1/good.pem
key = $P1/good.key
chain = $P2/other.chain.pem
chain_check = fail"
vcert; expect_rc 1 "chain_check = fail rejects a mismatched chain"

certconf "cert = $P1/good.pem
key = $P1/good.key
chain = $P2/other.chain.pem
chain_check = off"
vcert; expect_rc 0 "chain_check = off accepts any chain"; expect_lacks "does not verify" "chain_check = off is silent"

certconf "cert = $P1/good.pem
key = $P1/ecgood.key"
vcert; expect_rc 1 "a key that does not match the certificate"; expect_has "does not match the certificate" "mismatch is explained"

certconf "cert = $P1/old.pem
key = $P1/old.key
chain = $P1/old.chain.pem"
vcert; expect_rc 1 "an expired certificate"; expect_has "already expired" "expiry is explained"

certconf "cert = $P1/future.pem
key = $P1/future.key"
vcert; expect_rc 1 "a certificate that is not valid yet"; expect_has "not valid yet" "not-yet-valid is explained"

certconf "cert = $P1/good.pem
key = $P1/good.key
min_days_valid = 200"
vcert; expect_rc 1 "min_days_valid above the remaining lifetime"; expect_has "min_days_valid" "min_days_valid is explained"

certconf "cert = $P1/good.pem
key = $P1/good.key
min_days_valid = 30"
vcert; expect_rc 0 "min_days_valid below the remaining lifetime"

# encrypted key
openssl pkcs8 -topk8 -v2 aes256 -passout pass:secret -in "$P1/good.key" -out "$P1/good.enc.key" >/dev/null 2>&1
certconf "cert = $P1/good.pem
key = $P1/good.enc.key"
vcert; expect_rc 1 "a passphrase-protected key"; expect_has "passphrase-protected" "encrypted key is explained"

# legacy 'RSA PRIVATE KEY' (PKCS#1) format
openssl rsa -in "$P1/good.key" -traditional -out "$P1/good.pkcs1.key" >/dev/null 2>&1
certconf "cert = $P1/good.pem
key = $P1/good.pkcs1.key"
vcert; expect_rc 0 "a traditional (PKCS#1) RSA key"

# key file that also holds the certificate (combined PEM)
cat "$P1/good.pem" "$P1/good.key" > "$P1/good.combined.pem"
certconf "cert = $P1/good.pem
key = $P1/good.combined.pem"
vcert; expect_rc 0 "a combined cert+key PEM used as the key file"

# cert file with two certificates
certconf "cert = $P1/good.full.pem
key = $P1/good.key"
vcert; expect_rc 1 "a 'cert' file holding more than one certificate"; expect_has "exactly one certificate" "multi-cert 'cert' is explained"

# two private keys in one file
cat "$P1/good.key" "$P1/ecgood.key" > "$P1/two.key"
certconf "cert = $P1/good.pem
key = $P1/two.key"
vcert; expect_rc 1 "a key file with two private keys"; expect_has "exactly one PEM private key" "two keys is explained"

# garbage / empty / missing
echo "not a pem" > "$P1/garbage.pem"; : > "$P1/empty.pem"
certconf "cert = $P1/garbage.pem
key = $P1/good.key"
vcert; expect_rc 1 "a garbage certificate file"
certconf "cert = $P1/good.pem
key = $P1/garbage.pem"
vcert; expect_rc 1 "a garbage key file"
certconf "cert = $P1/empty.pem
key = $P1/good.key"
vcert; expect_rc 1 "an empty certificate file"
certconf "cert = $P1/good.pem
key = $P1/nonexistent.key"
vcert; expect_rc 1 "a missing key file"
certconf "cert = $P1/good.pem
key = $P1/good.key
chain = $P1/garbage.pem"
vcert; expect_rc 1 "a garbage chain file"
head -c 2000000 /dev/zero | tr '\0' 'A' > "$P1/huge.pem"
certconf "cert = $P1/huge.pem
key = $P1/good.key"
vcert; expect_rc 1 "an oversized certificate file (over 1 MiB) is refused"

# certbot-style layout: symlinks into an archive directory
mkdir -p "$TMP/le/archive/x.test" "$TMP/le/live/x.test"
cp "$P1/good.pem" "$TMP/le/archive/x.test/cert1.pem"; cp "$P1/good.chain.pem" "$TMP/le/archive/x.test/chain1.pem"
cp "$P1/good.full.pem" "$TMP/le/archive/x.test/fullchain1.pem"; cp "$P1/good.key" "$TMP/le/archive/x.test/privkey1.pem"
chmod 600 "$TMP/le/archive/x.test/privkey1.pem"
for f in cert chain fullchain privkey; do ln -sf "../../archive/x.test/${f}1.pem" "$TMP/le/live/x.test/${f}.pem"; done
certconf "le_dir = $TMP/le/live/x.test"
vcert; expect_rc 0 "a certbot-style le_dir with symlinks"

certconf "le_dir = $TMP/le/live/x.test
chain = $P2/other.chain.pem
chain_check = fail"
vcert; expect_rc 1 "an explicit 'chain' overrides the le_dir file"

certconf "le_dir = $TMP/no/such/dir"
vcert; expect_rc 1 "an le_dir that is not a directory"

# world-readable private key is flagged
cp "$P1/good.key" "$P1/readable.key"; chmod 644 "$P1/readable.key"
if [[ "$(stat -c %a "$P1/readable.key")" == 644 ]]; then
  certconf "cert = $P1/good.pem
key = $P1/readable.key"
  vcert; expect_rc 0 "a readable key is a warning, not an error"; expect_has "readable by other users" "readable key is flagged"
else
  t_skip "world-readable key warning" "this filesystem does not honour chmod"
fi

# --validate covers every cert when no selector is given
cfg "[f5:a]
host = 10.0.0.1
[cert:ok]
cert = $P1/good.pem
key = $P1/good.key
[cert:bad]
cert = $P1/old.pem
key = $P1/old.key
[deploy:d]
f5 = a
cert = ok
"
run "$BIN" --config "$CF" --validate; expect_rc 1 "--validate without a selector checks every certificate"; expect_has "cert 'bad'" "the failing certificate is named"
run "$BIN" --config "$CF" --validate --deploy d; expect_rc 0 "--validate --deploy checks only that deployment's certificate"

# the scratch directory is cleaned up
BEFORE="$(ls -d "${TMPDIR:-/tmp}"/f5-cert-push.* /dev/shm/f5-cert-push.* 2>/dev/null | wc -l)"
run "$BIN" --config "$CF" --validate --deploy d
AFTER="$(ls -d "${TMPDIR:-/tmp}"/f5-cert-push.* /dev/shm/f5-cert-push.* 2>/dev/null | wc -l)"
expect_eq "$AFTER" "$BEFORE" "no scratch directory is left behind after a run"
fi

t_summary
