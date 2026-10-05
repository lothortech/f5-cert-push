#!/usr/bin/env bash
# Test suite for f5-cert-install.sh (the manual-upload wrapper). Needs no BIG-IP:
# the push step is replaced by a stand-in that records how it was called.
# The real push is exercised by tests/f5.sh (scenario s20).
#
#   tests/install.sh          T_VERBOSE=1 tests/install.sh

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INST="${T_DIR}/../f5-cert-install.sh"
IN="${TMP}/incoming"; ST="${TMP}/store"; CF="${TMP}/f5-cert-push.conf"
FAKE="${TMP}/fake-push.sh"; PLOG="${TMP}/push.log"; PRC="${TMP}/push.rc"
mkdir -p "$IN"; : > "$CF"; chmod 600 "$CF"; echo 0 > "$PRC"

# Stand-in for f5-cert-push.sh: --validate is delegated to the real script (the
# wrapper relies on it); anything else is recorded and answered with push.rc.
cat > "$FAKE" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do if [[ "\$a" == --validate ]]; then exec "${T_DIR}/../f5-cert-push.sh" "\$@"; fi; done
printf '%s\n' "\$*" >> "${PLOG}"
exit "\$(cat "${PRC}")"
EOF
chmod 700 "$FAKE"

inst() { : > "$PLOG"; run "$INST" --config "$CF" --incoming "$IN" --store "$ST" --push-bin "$FAKE" "$@"; }
pushed()  { [[ -s "$PLOG" ]]; }
upload() {   # upload NAME FILE:SOURCE ...   then READY
  local n="$1"; shift; mkdir -p "$IN/$n"
  local spec; for spec in "$@"; do cp "${spec#*:}" "$IN/$n/${spec%%:*}"; done
  touch "$IN/$n/READY"
}
cur_fp() { local d="$ST/$1/current"; openssl x509 -in "$d/cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':'; }
releases() { ls -1 "$ST/$1/releases" 2>/dev/null | grep -cE '^[0-9]{8}-[0-9]{6}$' || true; }

echo "== setup: test PKI"
P="${TMP}/pki"; pki_init "$P"
for n in a b c d e f; do pki_leaf "$P" "$n" "www.test" "DNS:www.test"; sleep 1; done
pki_leaf "$P" ecc "www.test" "DNS:www.test" ec
pki_leaf "$P" soonish "www.test" "DNS:www.test" rsa 20260101000000Z "$(date -u -d '+3 days' +%Y%m%d%H%M%SZ)"
pki_leaf "$P" earlier "www.test" "DNS:www.test" rsa 20260101000000Z "$(date -u -d '+40 days' +%Y%m%d%H%M%SZ)"
pki_leaf "$P" expired "www.test" "DNS:www.test" rsa 20200101000000Z 20200201000000Z
openssl pkcs8 -topk8 -v2 aes256 -passout pass:x -in "$P/a.key" -out "$P/a.enc.key" >/dev/null 2>&1
[[ -s "$P/f.pem" && -s "$P/earlier.pem" ]] || { echo "PKI generation failed" >&2; exit 1; }

#######################################################################
echo "== command line"
run "$INST" --version; expect_rc 0 "--version"
run "$INST" --help; expect_rc 0 "--help"; expect_has "READY" "--help explains the READY marker"
run "$INST" --bogus; expect_rc 2 "unknown option exits 2"
run "$INST" --incoming relative/path --push-bin "$FAKE"; expect_rc 2 "a relative path is refused"
run "$INST" --incoming "/tmp/a b" --push-bin "$FAKE"; expect_rc 2 "a path with a space is refused"
run "$INST" --env 'bad env' --incoming "$IN" --store "$ST" --push-bin "$FAKE"; expect_rc 2 "a bad --env label is refused"
run "$INST" --incoming "$IN" --store "$ST" --push-bin "$FAKE" --keep-releases 0; expect_rc 2 "--keep-releases 0 is refused"

#######################################################################
echo "== nothing to do"
inst; expect_rc 0 "an empty incoming directory is fine"; expect_has "no uploads waiting" "says so"
expect_false "no push without an install" pushed
mkdir -p "$IN/www"; cp "$P/a.pem" "$IN/www/cert.pem"; cp "$P/a.key" "$IN/www/privkey.pem"
inst; expect_rc 0 "an upload without READY is left alone"
expect_true "its files are untouched" test -f "$IN/www/privkey.pem"
expect_false "nothing was installed" test -e "$ST/www/current"
rm -rf "$IN/www"

#######################################################################
echo "== a good upload"
upload www cert.pem:"$P/a.pem" chain.pem:"$P/a.chain.pem" privkey.pem:"$P/a.key"
inst
expect_rc 0 "a valid upload installs"; expect_has "installed 'www'" "the install is reported"
expect_eq "$(cur_fp www)" "$(fp_of "$P/a.pem")" "current holds the uploaded certificate"
expect_true "current is a symbolic link to a release" test -L "$ST/www/current"
expect_true "the release has cert, chain, key and a generated fullchain" bash -c "cd '$ST/www/current' && test -s cert.pem -a -s chain.pem -a -s privkey.pem -a -s fullchain.pem"
expect_eq "$(grep -c 'BEGIN CERTIFICATE' "$ST/www/current/fullchain.pem")" "2" "the generated fullchain is leaf + intermediate"
expect_eq "$(stat -c %a "$ST/www/current/privkey.pem")" "600" "the installed key is mode 0600"
expect_eq "$(stat -c %a "$ST/www/releases/$(readlink "$ST/www/current" | sed 's#releases/##')")" "700" "the release directory is mode 0700"
expect_false "the uploaded key was removed from incoming" test -e "$IN/www/privkey.pem"
expect_false "READY was removed" test -e "$IN/www/READY"
expect_true "the push ran" pushed; expect_eq "$(cat "$PLOG")" "--config $CF --all" "the push used --all"
expect_false "no push is pending after success" test -e "$ST/.push-pending"
inst; expect_rc 0 "a run with nothing new"; expect_false "does not push again (push-when changed)" pushed

#######################################################################
echo "== push retries"
echo 1 > "$PRC"
upload www cert.pem:"$P/b.pem" chain.pem:"$P/b.chain.pem" privkey.pem:"$P/b.key"
inst; expect_rc 1 "a failed push makes the run fail"; expect_has "will be retried" "the retry is announced"
expect_true "a push is pending" test -e "$ST/.push-pending"
expect_eq "$(cur_fp www)" "$(fp_of "$P/b.pem")" "the certificate is installed locally even though the push failed"
inst; expect_true "the next run retries the push" pushed
echo 3 > "$PRC"; inst; expect_rc 3 "a rolled-back push (exit 3) is passed through"
echo 0 > "$PRC"; inst; expect_rc 0 "the retry succeeds"; expect_false "nothing is pending after success" test -e "$ST/.push-pending"
inst --push-when always; expect_true "--push-when always pushes every run" pushed
inst --push-when always --env prod --env lab; expect_eq "$(cat "$PLOG")" "--config $CF --env prod --env lab" "--env selects instead of --all"
upload www cert.pem:"$P/c.pem" chain.pem:"$P/c.chain.pem" privkey.pem:"$P/c.key"
inst --no-push; expect_rc 0 "--no-push installs"; expect_false "--no-push does not push" pushed
expect_true "--no-push leaves a push pending for the next run" test -e "$ST/.push-pending"
inst; expect_true "the next run pushes it" pushed

#######################################################################
echo "== upload forms"
upload www cert.pem:"$P/c.pem" chain.pem:"$P/c.chain.pem" privkey.pem:"$P/c.key"
N="$(releases www)"; inst
expect_rc 0 "re-uploading the installed certificate"; expect_has "identical to the installed" "is recognised as identical"
expect_eq "$(releases www)" "$N" "no new release for an identical upload"; expect_false "the upload folder is cleared" test -e "$IN/www/privkey.pem"
upload www fullchain.pem:"$P/d.full.pem" privkey.pem:"$P/d.key"
inst; expect_rc 0 "fullchain + key only"
expect_eq "$(cur_fp www)" "$(fp_of "$P/d.pem")" "the leaf was taken from the fullchain"
expect_eq "$(grep -c 'BEGIN CERTIFICATE' "$ST/www/current/chain.pem")" "1" "chain.pem was split out of the fullchain"
upload www cert.pem:"$P/e.pem" fullchain.pem:"$P/e.full.pem" privkey.pem:"$P/e.key"
inst; expect_rc 0 "cert + fullchain (no chain.pem)"
expect_true "chain.pem was derived from the fullchain" test -s "$ST/www/current/chain.pem"
upload ecsite cert.pem:"$P/ecc.pem" chain.pem:"$P/ecc.chain.pem" privkey.pem:"$P/ecc.key"
inst; expect_rc 0 "an ECDSA certificate"; expect_eq "$(cur_fp ecsite)" "$(fp_of "$P/ecc.pem")" "the ECDSA certificate is installed"

#######################################################################
echo "== rejected uploads leave everything as it was"
reject_case() {   # reject_case DESC EXPECTED-TEXT  (upload already staged)
  local before; before="$(cur_fp www)"
  inst
  expect_rc 1 "rejected: $1"; expect_has "$2" "rejected: $1 (reason)"
  expect_eq "$(cur_fp www)" "$before" "rejected: $1 (installed certificate unchanged)"
  expect_true "rejected: $1 (FAILED written)" test -s "$IN/www/FAILED"
  expect_false "rejected: $1 (READY removed so it is not retried)" test -e "$IN/www/READY"
  expect_false "rejected: $1 (nothing pushed)" pushed
  rm -rf "$IN/www"
}
upload www cert.pem:"$P/f.pem" chain.pem:"$P/f.chain.pem" privkey.pem:"$P/a.key"
reject_case "key does not match" "does not match the certificate"
upload www cert.pem:"$P/f.pem" privkey.pem:"$P/f.key"
reject_case "no chain" "no intermediate certificates"
upload www cert.pem:"$P/f.pem" chain.pem:"$P/f.chain.pem"
reject_case "no key" "privkey.pem is missing"
upload www chain.pem:"$P/f.chain.pem" privkey.pem:"$P/f.key"
reject_case "no certificate" "neither cert.pem nor fullchain.pem"
upload www cert.pem:"$P/f.pem" fullchain.pem:"$P/a.full.pem" privkey.pem:"$P/f.key"
reject_case "cert.pem and fullchain.pem disagree" "are different certificates"
upload www cert.pem:"$P/f.pem" chain.pem:"$P/f.chain.pem" privkey.pem:"$P/a.enc.key"
reject_case "encrypted key" "passphrase-protected"
upload www cert.pem:"$P/expired.pem" chain.pem:"$P/expired.chain.pem" privkey.pem:"$P/expired.key"
reject_case "expired certificate" "already expired"
upload www cert.pem:"$P/soonish.pem" chain.pem:"$P/soonish.chain.pem" privkey.pem:"$P/soonish.key"
reject_case "expires within --min-days" "min_days_valid"
upload www cert.pem:"$P/earlier.pem" chain.pem:"$P/earlier.chain.pem" privkey.pem:"$P/earlier.key"
reject_case "older than the installed certificate" "BEFORE the installed one"
mkdir -p "$IN/www"; cp "$P/f.pem" "$IN/www/cert.pem"; cp "$P/f.chain.pem" "$IN/www/chain.pem"
echo "secret-root-file" > "${TMP}/not-a-key"; ln -s "${TMP}/not-a-key" "$IN/www/privkey.pem"; touch "$IN/www/READY"
reject_case "a symbolic link instead of a file" "symbolic links are refused"
expect_false "the symlink target was not copied into the store" grep -rq "secret-root-file" "$ST"
mkdir -p "$IN/www"; cp "$P/f.pem" "$IN/www/cert.pem"; cp "$P/f.chain.pem" "$IN/www/chain.pem"; : > "$IN/www/privkey.pem"; touch "$IN/www/READY"
reject_case "an empty key file" "empty or larger than 1 MiB"
mkdir -p "$IN/www"; cp "$P/f.pem" "$IN/www/cert.pem"; cp "$P/f.chain.pem" "$IN/www/chain.pem"; mkfifo "$IN/www/privkey.pem"; touch "$IN/www/READY"
START=$SECONDS
reject_case "a FIFO instead of a file" "not a regular file"
(( SECONDS - START < 15 )) && t_pass "a FIFO does not make the run hang" || t_fail "a FIFO made the run take $((SECONDS - START))s"
mkdir -p "$IN/www"; head -c 3000000 /dev/zero | tr ' ' 'A' > "$IN/www/cert.pem"; cp "$P/f.chain.pem" "$IN/www/chain.pem"; cp "$P/f.key" "$IN/www/privkey.pem"; touch "$IN/www/READY"
reject_case "a file larger than 1 MiB" "larger than 1 MiB"
upload www cert.pem:"$P/f.pem" chain.pem:"$P/f.chain.pem" privkey.pem:"$P/f.key"
rm "$IN/www/READY"; echo "fixed" >/dev/null
inst; expect_rc 0 "a rejected folder is not retried without READY"
upload www cert.pem:"$P/earlier.pem" chain.pem:"$P/earlier.chain.pem" privkey.pem:"$P/earlier.key"
inst --allow-older; expect_rc 0 "--allow-older accepts an older certificate"; expect_eq "$(cur_fp www)" "$(fp_of "$P/earlier.pem")" "the older certificate is installed"
upload nochain cert.pem:"$P/f.pem" privkey.pem:"$P/f.key"
inst --allow-no-chain; expect_rc 0 "--allow-no-chain accepts a certificate without intermediates"

#######################################################################
echo "== folder hygiene"
mkdir -p "$IN/bad name" "$IN/.hidden"; touch "$IN/bad name/READY" "$IN/.hidden/READY"
inst; expect_has "unusable name" "a folder with an unusable name is reported"; expect_rc 0 "and ignored"
rm -rf "$IN/bad name" "$IN/.hidden"
mkdir -p "${TMP}/elsewhere"; cp "$P/f.pem" "${TMP}/elsewhere/cert.pem"; cp "$P/f.chain.pem" "${TMP}/elsewhere/chain.pem"; cp "$P/f.key" "${TMP}/elsewhere/privkey.pem"; touch "${TMP}/elsewhere/READY"
ln -s "${TMP}/elsewhere" "$IN/linked"
inst; expect_has "symbolic link" "an upload folder that is a symlink is reported"; expect_false "and not installed" test -e "$ST/linked"
rm -f "$IN/linked"
mkdir -p "$IN/www"; cp "$P/f.pem" "$IN/www/cert.pem"; cp "$P/f.chain.pem" "$IN/www/chain.pem"; cp "$P/f.key" "$IN/www/privkey.pem"; ln -s /etc/hostname "$IN/www/READY"
inst; expect_false "a READY that is a symlink does not trigger an install" grep -q "installed 'www'" <<<"$OUT"
rm -rf "$IN/www"

#######################################################################
echo "== dry run, retention, status, locking"
upload www cert.pem:"$P/f.pem" chain.pem:"$P/f.chain.pem" privkey.pem:"$P/f.key"
BEFORE="$(cur_fp www)"
inst --dry-run; expect_rc 0 "--dry-run"; expect_has "DRY RUN: would install 'www'" "--dry-run reports what it would install"
expect_eq "$(cur_fp www)" "$BEFORE" "--dry-run installs nothing"; expect_true "--dry-run leaves READY" test -e "$IN/www/READY"; expect_false "--dry-run pushes nothing" pushed
rm -rf "$IN/www"
for n in b c d e f; do
  upload ret cert.pem:"$P/$n.pem" chain.pem:"$P/$n.chain.pem" privkey.pem:"$P/$n.key"
  inst --keep-releases 2 --allow-older; sleep 1
done
expect_eq "$(releases ret)" "2" "only 2 releases are kept"
expect_eq "$(cur_fp ret)" "$(fp_of "$P/f.pem")" "current is the newest release"
mkdir -p "$IN/broken"; cp "$P/f.pem" "$IN/broken/cert.pem"; touch "$IN/broken/READY"; inst
run "$INST" --incoming "$IN" --store "$ST" --push-bin "$FAKE" --status
expect_rc 0 "--status"; expect_has "ret" "--status lists installed certificates"; expect_has "broken: FAILED" "--status shows a rejected upload"
( exec 9>"$ST/.lock"; flock 9; sleep 6 ) & HOLD=$!; sleep 1
inst; expect_rc 6 "a second concurrent run exits 6"
wait "$HOLD"

t_summary
