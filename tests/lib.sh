#!/usr/bin/env bash
# Shared helpers for the f5-cert-push test suites. Source this file; do not run it.
#
#   BIN   path to f5-cert-push.sh under test (default: ../f5-cert-push.sh)
#   TMP   private scratch directory, removed on exit
#
# Test output: one line per assertion, PASS / FAIL / SKIP, and a final tally.
# The suites exit non-zero if any assertion failed.

LC_ALL=C; export LC_ALL
# Git Bash on Windows rewrites arguments that start with '/' (openssl -subj); harmless elsewhere.
MSYS2_ARG_CONV_EXCL='*'; export MSYS2_ARG_CONV_EXCL
umask 077

T_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${BIN:-${T_DIR}/../f5-cert-push.sh}"
T_PASS=0; T_FAIL=0; T_SKIP=0
T_CASE=""
OUT=""; RC=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/f5cp-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
t_cleanup() {
  if declare -F suite_cleanup >/dev/null 2>&1; then suite_cleanup || true; fi
  rm -rf -- "$TMP"
}
trap t_cleanup EXIT
trap 'exit 130' INT TERM HUP   # so the EXIT trap (cleanup) also runs on signals

t_case() { T_CASE="$1"; }

t_pass() { T_PASS=$((T_PASS + 1)); printf 'PASS  %s\n' "${1:-$T_CASE}"; }
t_fail() {
  T_FAIL=$((T_FAIL + 1)); printf 'FAIL  %s\n' "${1:-$T_CASE}"
  if [[ -n "${2:-}" ]]; then printf '      %s\n' "$2"; fi
  if [[ -n "${OUT:-}" && "${T_VERBOSE:-0}" == 1 ]]; then printf '%s\n' "$OUT" | sed 's/^/      | /' | head -40; fi
}
t_skip() { T_SKIP=$((T_SKIP + 1)); printf 'SKIP  %s  (%s)\n' "${1:-$T_CASE}" "${2:-}"; }

# run CMD...  -> OUT (stdout+stderr), RC
run() { OUT="$("$@" 2>&1)"; RC=$?; }

expect_rc() {       # expect_rc N [DESC]
  if [[ "$RC" == "$1" ]]; then t_pass "${2:-$T_CASE}"; else t_fail "${2:-$T_CASE}" "expected exit $1, got $RC"; printf '%s\n' "$OUT" | sed 's/^/      | /' | head -15; fi
}
expect_has() {      # expect_has PATTERN [DESC]   (fixed string)
  if [[ "$OUT" == *"$1"* ]]; then t_pass "${2:-$T_CASE}"; else t_fail "${2:-$T_CASE}" "output lacks: $1"; printf '%s\n' "$OUT" | sed 's/^/      | /' | head -15; fi
}
expect_lacks() {    # expect_lacks PATTERN [DESC]
  if [[ "$OUT" != *"$1"* ]]; then t_pass "${2:-$T_CASE}"; else t_fail "${2:-$T_CASE}" "output unexpectedly has: $1"; printf '%s\n' "$OUT" | sed 's/^/      | /' | head -15; fi
}
expect_eq() {       # expect_eq ACTUAL EXPECTED [DESC]
  if [[ "$1" == "$2" ]]; then t_pass "${3:-$T_CASE}"; else t_fail "${3:-$T_CASE}" "expected '$2', got '$1'"; fi
}
expect_true() {     # expect_true DESC CMD...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then t_pass "$d"; else t_fail "$d" "command failed: $*"; fi
}
expect_false() {    # expect_false DESC CMD...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then t_fail "$d" "command unexpectedly succeeded: $*"; else t_pass "$d"; fi
}

t_summary() {
  echo
  printf 'RESULT: %d passed, %d failed, %d skipped\n' "$T_PASS" "$T_FAIL" "$T_SKIP"
  if (( T_FAIL > 0 )); then return 1; fi
  return 0
}

#######################################################################
# Test PKI: root -> intermediate -> leaf, using openssl ca so validity
# dates can be set arbitrarily (expired / not-yet-valid certificates).
#######################################################################
pki_init() {   # pki_init DIR
  local d="$1"
  mkdir -p "$d"; ( cd "$d" || exit 1
    : > index.txt; echo 1000 > serial
    cat > ca.cnf <<'CNF'
[ca]
default_ca = CA_default
[CA_default]
dir = .
database = index.txt
new_certs_dir = .
serial = serial
default_md = sha256
unique_subject = no
policy = pol
copy_extensions = none
[pol]
commonName = supplied
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[v3_leaf]
basicConstraints = CA:FALSE
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.pem -subj "/CN=Test Root CA" -days 3650 \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
    openssl req -new -newkey rsa:2048 -nodes -keyout int.key -out int.csr -subj "/CN=Test Intermediate CA" >/dev/null 2>&1
    openssl ca -config ca.cnf -batch -notext -cert root.pem -keyfile root.key -in int.csr -out int.pem \
      -days 3000 -extensions v3_ca >/dev/null 2>&1
  )
}

# pki_leaf DIR NAME CN SAN [rsa|ec] [START END]
#   writes NAME.key, NAME.pem (leaf only), NAME.chain.pem (intermediate), NAME.full.pem
pki_leaf() {
  local d="$1" n="$2" cn="$3" san="$4" kt="${5:-rsa}" start="${6:-}" end="${7:-}"
  ( cd "$d" || exit 1
    if [[ "$kt" == ec ]]; then
      openssl ecparam -name prime256v1 -genkey -noout -out "$n.key" 2>/dev/null
    else
      openssl genrsa -out "$n.key" 2048 >/dev/null 2>&1
    fi
    openssl req -new -key "$n.key" -out "$n.csr" -subj "/CN=${cn}" >/dev/null 2>&1
    printf 'subjectAltName=%s\n' "$san" > "$n.ext"
    local -a dates=(-days 90)
    if [[ -n "$start" ]]; then dates=(-startdate "$start" -enddate "$end"); fi
    cat ca.cnf > "$n.cnf"; printf '[v3_leaf_san]\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$san" >> "$n.cnf"
    openssl ca -config "$n.cnf" -batch -notext -cert int.pem -keyfile int.key -in "$n.csr" -out "$n.pem" \
      "${dates[@]}" -extensions v3_leaf_san >/dev/null 2>&1
    cp int.pem "$n.chain.pem"
    cat "$n.pem" int.pem > "$n.full.pem"
  )
}

fp_of() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'a-f' 'A-F'; }

# A minimal valid config file: mkconf FILE (body on stdin); sets mode 600.
mkconf() { cat > "$1"; chmod 600 "$1"; }

# Drop-in base config used by many cases; callers append sections.
BASE_CONF='[f5:a]
host = 10.0.0.1
[cert:c]
cert = /etc/x.crt
key = /etc/x.key
[deploy:d]
f5 = a
cert = c
'
