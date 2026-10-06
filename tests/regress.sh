#!/usr/bin/env bash
# Regression tests for the findings of the adversarial review of 2.0.0
# (R1-R13 and the additional observations; see REVIEW.md, "Fixed issues").
# Each case reproduces the reported failure and requires the safe outcome.
# Needs no BIG-IP: the script's own functions are loaded and the BIG-IP is
# replaced by a local stand-in that runs the remote scripts with bash, with the
# BIG-IP paths (/var/run/f5-cert-push.lock, /config/filestore) moved into a
# temporary directory and tmsh replaced by a stub.
#
#   tests/regress.sh          T_VERBOSE=1 tests/regress.sh
#
# Some wrapper cases need root (they check real kernel permission behaviour as an
# unprivileged uploader); they are skipped otherwise.

# The cases set globals that the loaded script's functions read, and assign associative-array
# keys (CERT_HAVE_CHAIN[site]=...), which shellcheck reports as unused / unassigned variables.
# shellcheck disable=SC2034,SC2154

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PUSH="${REGRESS_PUSH:-$(cd "${T_DIR}/.." && pwd)/f5-cert-push.sh}"
INSTALL="$(cd "${T_DIR}/.." && pwd)/f5-cert-install.sh"
export PUSH INSTALL

# Run a case function in a subshell; it must exit 0 for the case to pass.
check() {   # check DESC FUNCTION
  local d="$1"; shift
  OUT="$( ( "$@" ) 2>&1 )"; RC=$?
  if (( RC == 0 )); then t_pass "$d"; else t_fail "$d" "case returned ${RC}"; printf '%s\n' "$OUT" | sed 's/^/      | /' | tail -12; fi
}

# Load the push script's functions into this (sub)shell without running main.
load_push() {
  # shellcheck disable=SC1090
  source <(sed -e '$d' -e 's/^declare -a /declare -ga /' -e 's/^declare -A /declare -gA /' "$PUSH")
  trap - EXIT INT TERM HUP
  set +f
  WORK="$(mktemp -d "${TMP}/work.XXXXXX")"
}
load_install() {
  # shellcheck disable=SC1090
  source <(sed -e '$d' -e 's/^declare -a /declare -ga /' "$INSTALL")
  trap - EXIT INT TERM HUP
  set +f
}

# A local stand-in for the BIG-IP (see the header).
emu_init() {
  EMU="$(mktemp -d "${TMP}/emu.XXXXXX")"
  mkdir -p "$EMU/run" "$EMU/fs/files_d/Common_d/certificate_d" "$EMU/fs/files_d/Common_d/certificate_key_d" "$EMU/bin" "$EMU/shared"
  cat > "$EMU/bin/tmsh" <<'EOF'
#!/usr/bin/env bash
# tmsh stub: logs its arguments (and stdin when used as a batch), exits TMSH_RC.
if (( $# == 0 )); then cat >> "${EMU}/tmsh.stdin"; else printf '%s\n' "$*" >> "${EMU}/tmsh.log"; fi
exit "${TMSH_RC:-0}"
EOF
  chmod 755 "$EMU/bin/tmsh"
  export EMU
  REMOTE_TIMEOUT=6
  f5_sh() {
    local s="$1"; shift
    s="${s//\/var\/run\/f5-cert-push.lock/${EMU}/run/f5-cert-push.lock}"
    s="${s//\/var\/run\/f5-cert-push.guard/${EMU}/run/f5-cert-push.guard}"
    s="${s//\/config\/filestore/${EMU}/fs}"
    printf '%s\n' "$s" | PATH="${EMU}/bin:${PATH}" bash -s -- "$@" 2>>"${WORK}/ssh.err"
  }
  f5_get() { cp -- "$1" "$2"; }
  sleep() { :; }
}
emu_lock() {   # take the emulated BIG-IP lock for token $1
  REMOTE_LOCK_TOKEN="$1"
  f5_sh "${R_LOCK}" 30 "$1" "test owner" | grep -q 'LOCK|OK'
}
emu_obj() {   # emu_obj cert|key NAME FILE   (an object in the emulated filestore)
  local sub=certificate_d
  [[ "$1" == key ]] && sub=certificate_key_d
  cp -- "$3" "${EMU}/fs/files_d/Common_d/${sub}/:Common:${2}_1001_1"
}

echo "== setup: test PKI"
# REGRESS_PKI: use a test PKI made elsewhere (by this suite's pki_init / pki_leaf), for
# hosts whose OpenSSL is too old to make one (the BIG-IP itself: OpenSSL 1.0.2).
if [[ -n "${REGRESS_PKI:-}" ]]; then
  P="$REGRESS_PKI"
else
  P="${TMP}/pki"; pki_init "$P"
  pki_leaf "$P" a a.test DNS:a.test
  pki_leaf "$P" b b.test DNS:b.test
fi
export P

#######################################################################
echo "== R1-R3: the upload wrapper's trust boundary"
#######################################################################
r1_failed_symlink() {
  load_install
  INCOMING="${TMP}/r1-in"; mkdir -p "$INCOMING/site"
  printf 'DO NOT OVERWRITE\n' > "${TMP}/r1-victim"
  ln -s "${TMP}/r1-victim" "$INCOMING/site/FAILED"
  reject site 'privkey.pem is missing' >/dev/null 2>&1
  [[ "$(cat "${TMP}/r1-victim")" == 'DO NOT OVERWRITE' ]] || { echo "victim was overwritten"; return 1; }
  [[ -f "$INCOMING/site/FAILED" && ! -L "$INCOMING/site/FAILED" ]] || { echo "FAILED is not a regular file"; return 1; }
  grep -q 'privkey.pem is missing' "$INCOMING/site/FAILED"
}
check "R1: a planted FAILED symlink is replaced, its target is not written" r1_failed_symlink

r2_unlink_race() {
  load_install
  INCOMING="${TMP}/r2-in"; mkdir -p "$INCOMING/site"
  printf 'UPLOADED KEY\n' > "$INCOMING/site/privkey.pem"
  printf 'ROOT FILE TO PRESERVE\n' > "${TMP}/r2-victim"
  # The uploader swaps the file for a link at the worst moment: just before removal.
  # (the wrapper removes uploads from inside the folder, with relative names)
  rm() {
    if [[ "${*: -1}" == ./privkey.pem && -f ./privkey.pem && ! -L ./privkey.pem ]]; then
      command rm -f -- ./privkey.pem; ln -s "${TMP}/r2-victim" ./privkey.pem; touch "${TMP}/r2-swapped"
    fi
    command rm "$@"
  }
  shred() { echo "shred must not be used on uploads" >&2; return 1; }
  clear_upload site
  [[ -e "${TMP}/r2-swapped" ]] || { echo "test setup: the swap did not happen"; return 1; }
  [[ "$(cat "${TMP}/r2-victim")" == 'ROOT FILE TO PRESERVE' ]] || { echo "victim altered"; return 1; }
  [[ ! -e "$INCOMING/site/privkey.pem" && ! -L "$INCOMING/site/privkey.pem" ]]
}
check "R2: removing an upload never writes through a swapped-in link" r2_unlink_race

r3_untrusted_parent() {
  local base="${TMP}/r3" rc=0
  mkdir -p "$base/open/incoming/site" "$base/store"
  chmod 777 "$base/open"                     # writable by anyone, no sticky bit
  : > "$base/open/incoming/site/READY"
  out="$("$INSTALL" --config "${TMP}/none.conf" --incoming "$base/open/incoming" --store "$base/store" --push-bin "$PUSH" --no-push 2>&1)" || rc=$?
  [[ "$rc" == 2 && "$out" == *"refusing to use"* ]] || { echo "rc=$rc out=$out"; return 1; }
}
check "R3: an upload directory below a directory others can write to is refused" r3_untrusted_parent

r3_unsafe_folder() {
  local base="${TMP}/r3b" rc=0
  mkdir -p "$base/incoming/site" "$base/store"
  chmod 777 "$base/incoming/site"            # uploaders could rename things root created
  cp "$P/a.pem" "$base/incoming/site/cert.pem"; cp "$P/a.key" "$base/incoming/site/privkey.pem"
  cp "$P/a.chain.pem" "$base/incoming/site/chain.pem"; : > "$base/incoming/site/READY"
  out="$("$INSTALL" --config "${TMP}/none.conf" --incoming "$base/incoming" --store "$base/store" --push-bin "$PUSH" --no-push 2>&1)" || rc=$?
  [[ "$out" == *"ignoring upload folder site"* && ! -e "$base/store/site" ]] || { echo "rc=$rc out=$out"; return 1; }
}
check "R3: an upload folder that is writable without the sticky bit is not processed" r3_unsafe_folder

r3_folder_swap() {
  # Codex's reproduction: the folder is swapped for a link to a private directory
  # just before the copy. As one user who owns everything the swap itself succeeds
  # (the permission model is what stops a real uploader; see the root case below),
  # so this checks the second line of defence: the copy is made through the folder
  # held as the working directory, which a later rename cannot redirect.
  load_install
  INCOMING="${TMP}/r3s-in"; WORK="${TMP}/r3s-work"; STORE="${TMP}/r3s-store"; DRY_RUN=1
  mkdir -p "$INCOMING/site" "$WORK" "${TMP}/r3s-private"
  printf 'uploader data
' > "$INCOMING/site/cert.pem"
  printf 'ROOT ONLY SOURCE
' > "${TMP}/r3s-private/cert.pem"
  timeout() {
    if [[ ! -e "${TMP}/r3s-swapped" ]]; then
      mv "$INCOMING/site" "$INCOMING/site.old"; ln -s "${TMP}/r3s-private" "$INCOMING/site"; touch "${TMP}/r3s-swapped"
    fi
    command timeout "$@"
  }
  process_upload site >/dev/null 2>&1 || true
  [[ -e "${TMP}/r3s-swapped" ]] || { echo "test setup: the swap did not happen"; return 1; }
  [[ "$(cat "$WORK/site/cert.pem" 2>/dev/null)" != 'ROOT ONLY SOURCE' ]]
}
check "R3: swapping the upload folder during the copy does not redirect it" r3_folder_swap

r3_hardlink() {
  load_install
  INCOMING="${TMP}/r3c-in"; WORK="${TMP}/r3c-work"; STORE="${TMP}/r3c-store"; DRY_RUN=1
  mkdir -p "$INCOMING/site" "$WORK"
  cp "$P/a.key" "${TMP}/r3c-secret.key"
  ln "${TMP}/r3c-secret.key" "$INCOMING/site/privkey.pem"
  process_upload site >/dev/null 2>&1 && return 1
  [[ ! -e "$WORK/site/privkey.pem" ]]
}
check "R3: a hard-linked upload file is refused before it is read" r3_hardlink

if [[ "$(id -u)" == 0 ]] && command -v setpriv >/dev/null 2>&1; then
  # Real permissions, real kernel: the uploader is an unprivileged account in the
  # upload group; the folders are set up as docs/MANUAL-UPLOAD.md says.
  r3_kernel() {
    local base gid=65534 u="setpriv --reuid=65534 --regid=65534 --clear-groups"
    base="$(mktemp -d /srv/f5cp-regress.XXXXXX 2>/dev/null || mktemp -d /var/tmp/f5cp-regress.XXXXXX)"
    chmod 755 "$base"
    install -d -m 750 -o root -g "$gid" "$base/incoming"
    install -d -m 3770 -o root -g "$gid" "$base/incoming/site"
    printf 'ROOT SECRET\n' > "$base/victim"; chmod 600 "$base/victim"
    # 1. the uploader cannot replace the upload folder
    if $u mv "$base/incoming/site" "$base/incoming/site.old" 2>/dev/null; then echo "uploader could rename the folder"; rm -rf "$base"; return 1; fi
    # 2. a FAILED symlink planted by the uploader does not redirect root's write
    $u ln -s "$base/victim" "$base/incoming/site/FAILED"
    ( load_install; INCOMING="$base/incoming"; reject site "test" >/dev/null 2>&1 )
    [[ "$(cat "$base/victim")" == 'ROOT SECRET' ]] || { echo "victim overwritten"; rm -rf "$base"; return 1; }
    # 3. the uploader cannot replace the root-owned FAILED file
    if $u sh -c "rm -f '$base/incoming/site/FAILED' || exit 1; ln -s '$base/victim' '$base/incoming/site/FAILED'" 2>/dev/null; then
      echo "uploader could replace root's FAILED"; rm -rf "$base"; return 1
    fi
    rm -rf "$base"
  }
  check "R1-R3 (as root, real permissions): the uploader cannot swap the folder or root's files" r3_kernel
else
  t_skip "R1-R3 (as root, real permissions)" "needs root and setpriv"
fi

r_chmod_list() {
  ! grep -q '"\${rel}"/\*\.pem' "$INSTALL"
}
check "observation: the wrapper no longer relies on a glob under noglob" r_chmod_list

#######################################################################
echo "== R4: a lost reply is not taken to mean 'unchanged'"
#######################################################################
r4_unknown_is_changed() {
  load_push; emu_init
  J_PREFIX=site; J_TS=20261005-120000; J_PART=Common; J_CERT=site; CERT_HAVE_CHAIN[site]=0
  J_TARGETS=('profile|entry|old-cert|none|old-key'); J_CREATED=(); J_CHANGED=0; J_AUTOROLL=yes
  f5_mut() { return "${ST_UNKNOWN}"; }
  job_switch_profiles >/dev/null 2>&1 && return 1
  [[ "$J_CHANGED" == 1 && "$J_UNKNOWN" == 1 ]] || { echo "J_CHANGED=$J_CHANGED J_UNKNOWN=$J_UNKNOWN"; return 1; }
  job_rollback() { J_CHANGED=0; return 0; }
  job_remove_created() { return 0; }
  job_handle_failure "lost reply" >/dev/null 2>&1
  echo "result=$J_RESULT rc=$J_RC"
  [[ "$J_RESULT" == CRITICAL && "$J_RC" == 5 && "$REMOTE_LOCK_KEEP" == 1 ]]
}
check "R4: an unknown switch outcome counts as changed, and is CRITICAL even after a rollback" r4_unknown_is_changed

r4_outcome_read_back() {
  load_push; emu_init
  J_TS=20261005-120000
  emu_lock tok-A || return 1
  local calls=0 out rc=0
  # The first connection carries the step but loses the reply; the step completes
  # on the "BIG-IP" and its stored result is read back.
  local real; real="$(declare -f f5_sh)"
  eval "emu_sh${real#f5_sh}"
  f5_sh() {
    if [[ "$1" == *'STEPEND|'* && "$1" != *'STEP|NOLOCK'* ]]; then emu_sh "$@" >/dev/null; return 255; fi
    emu_sh "$@"
  }
  out="$(f5_mut 'echo "TXN|OK"; exit 0')" || rc=$?
  echo "rc=$rc out=$out"
  [[ "$rc" == 0 && "$out" == *'TXN|OK'* ]]
}
check "R4: when the reply is lost, the step's real outcome is read back from the BIG-IP" r4_outcome_read_back

r4_never_started() {
  load_push; emu_init
  J_TS=20261005-120000
  emu_lock tok-A || return 1
  local real rc=0; real="$(declare -f f5_sh)"
  eval "emu_sh${real#f5_sh}"
  f5_sh() { if [[ "$1" == *'STEPEND|'* && "$1" != *'STEP|NOLOCK'* ]]; then return 255; fi; emu_sh "$@"; }
  f5_mut 'echo should-not-run' >/dev/null || rc=$?
  [[ "$rc" == "${ST_NOTRUN}" ]]
}
check "R4: a step that never reached the BIG-IP is reported as not run" r4_never_started

r4_failed_txn_confirmed() {
  load_push; emu_init
  J_PREFIX=site; J_TS=20261005-120000; J_PART=Common; J_CERT=site; CERT_HAVE_CHAIN[site]=0
  J_TARGETS=('profile|entry|old-cert|none|old-key'); J_CREATED=(); J_CHANGED=0
  f5_mut() { printf 'TXNOUT|01070000:3: boom\nTXN|FAILED\n'; return 1; }
  # the device still shows the old bindings
  job_probe_profiles() { PR_STATE=([profile]=OK); ENT_LIST=('profile|entry|old-cert|none|old-key|none'); return 0; }
  job_remove_created() { return 0; }
  job_switch_profiles >/dev/null 2>&1 && return 1
  [[ "$J_CHANGED" == 0 ]] || return 1
  # ... but if the device does NOT show the old bindings, it is treated as changed
  job_probe_profiles() { PR_STATE=([profile]=OK); ENT_LIST=('profile|entry|new-cert|none|new-key|none'); return 0; }
  J_CHANGED=0
  job_switch_profiles >/dev/null 2>&1 && return 1
  [[ "$J_CHANGED" == 1 ]]
}
check "R4: a reported transaction failure is confirmed on the device before calling it unchanged" r4_failed_txn_confirmed

#######################################################################
echo "== R5: a rollback must find and match every target"
#######################################################################
r5_missing_entry() {
  load_push; emu_init
  RV_DIR="${TMP}/r5"; mkdir -p "$RV_DIR"
  INV_BIND=('profile|entry|old-cert|none|old-key'); INV_OBJ=(); INV_ABSENT=(); INV_LEGACY=0
  f5_mut() { echo '[+] restored'; return 0; }
  job_probe_profiles() { PR_STATE=(); ENT_LIST=(); return 0; }
  restore_and_verify >/dev/null 2>&1 && { echo "accepted a missing entry"; return 1; }
  job_probe_profiles() { PR_STATE=([profile]=OK); ENT_LIST=('profile|entry|old-cert|none|old-key|none' 'profile|entry|old-cert|none|old-key|none'); return 0; }
  restore_and_verify >/dev/null 2>&1 && { echo "accepted a duplicated entry"; return 1; }
  job_probe_profiles() { PR_STATE=([profile]=OK); ENT_LIST=('profile|entry|old-cert|none|old-key|none'); return 0; }
  restore_and_verify >/dev/null 2>&1
}
check "R5: rollback verification fails on a missing or duplicated entry, passes on an exact match" r5_missing_entry

r5_object_contents() {
  load_push; emu_init
  RV_DIR="${TMP}/r5b"; mkdir -p "$RV_DIR"
  cp "$P/a.pem" "$RV_DIR/cert.1.x"; cp "$P/a.key" "$RV_DIR/key.2.x"
  INV_BIND=(); INV_ABSENT=('cert|gone.pem'); INV_LEGACY=0
  INV_OBJ=('fix|cert|site-cert.pem|cert.1.x' 'fix|key|site-privkey.pem|key.2.x')
  f5_mut() { return 0; }
  emu_obj cert site-cert.pem "$P/b.pem"; emu_obj key site-privkey.pem "$P/a.key"
  # objinfo is answered from the emulated filestore
  objinfo_read() {
    local s n f
    for s in "$@"; do
      n="${s#*:}"
      case "$s" in
        cert:*) f="${EMU}/fs/files_d/Common_d/certificate_d/:Common:${n}_1001_1"
                if [[ -f "$f" ]]; then OBJ_OK["cert:$n"]=1; OBJ_FP[$n]="$(fp_pem <"$f")"; fi ;;
        certall:*) f="${EMU}/fs/files_d/Common_d/certificate_d/:Common:${n}_1001_1"
                if [[ -f "$f" ]]; then OBJ_CERTS[$n]="$(pem_fps_joined "$f")"; fi ;;
        keypub:*) f="${EMU}/fs/files_d/Common_d/certificate_key_d/:Common:${n}_1001_1"
                if [[ -f "$f" ]]; then OBJ_KEYPUB[$n]="$(keypub_of "$f")"; fi ;;
      esac
    done
  }
  restore_and_verify >/dev/null 2>&1 && { echo "accepted the wrong certificate content"; return 1; }
  emu_obj cert site-cert.pem "$P/a.pem"
  emu_obj cert gone.pem "$P/a.pem"
  restore_and_verify >/dev/null 2>&1 && { echo "accepted an object that should not exist"; return 1; }
  rm -f "${EMU}/fs/files_d/Common_d/certificate_d/:Common:gone.pem_1001_1"
  restore_and_verify >/dev/null 2>&1
}
check "R5: rollback verification compares restored object contents and absent objects" r5_object_contents

#######################################################################
echo "== R6: tmsh exit status is checked"
#######################################################################
r6_txn() {
  load_push; emu_init
  local out rc=0
  out="$(printf '%s\n' "$R_LIB" "$R_TXN" | TMSH_RC=1 PATH="${EMU}/bin:${PATH}" bash -s -- bind:p:e:c:none:k)" || rc=$?
  echo "rc=$rc out=$out"
  [[ "$rc" != 0 && "$out" == *'TXN|FAILED'* && "$out" != *'TXN|OK'* ]]
}
check "R6: a transaction whose tmsh exits non-zero is a failure, even with no error text" r6_txn

r6_install() {
  load_push; emu_init
  local out rc=0
  mkdir -p "${TMP}/r6stage"; : > "${TMP}/r6stage/cert.pem"
  out="$(printf '%s\n' "$R_LIB" "$R_INSTALL" | TMSH_RC=1 PATH="${EMU}/bin:${PATH}" bash -s -- "${TMP}/r6stage" new-cert:x.pem:cert.pem)" || rc=$?
  [[ "$rc" != 0 && "$out" == *'FAIL|'* ]]
}
check "R6: an install whose tmsh exits non-zero is a failure" r6_install

r6_save() {
  load_push; emu_init
  local out rc=0
  # transaction succeeds, the save fails without printing anything
  cat > "$EMU/bin/tmsh" <<'EOF'
#!/usr/bin/env bash
if (( $# == 0 )); then cat >/dev/null; exit 0; fi
[[ "$1" == save ]] && exit 1
exit 0
EOF
  out="$(printf '%s\n' "$R_LIB" "$R_TXN" | PATH="${EMU}/bin:${PATH}" bash -s -- bind:p:e:c:none:k)" || rc=$?
  [[ "$rc" == 2 && "$out" == *'SAVE|FAILED'* ]]
}
check "R6: a failed save after the transaction is reported" r6_save

#######################################################################
echo "== R10: backups are complete and verified"
#######################################################################
# A complete backup through the emulated BIG-IP, then the generated restore script.
backup_fixture() {
  load_push; emu_init
  F5_BACKUP_ROOT="${EMU}/shared"; F5_NAME=a; F5_HOST=h; J_PREFIX=site; J_TS=20261005-120000; J_DEP=d
  J_CERT=c; J_FP=TESTFP; J_MODE=atomic; J_FIXED=yes; J_PART=Common
  J_TARGETS=('profile|entry|old-cert.pem|old-chain.pem|old-key.pem')
  J_BDIR_L="${TMP}/bk-local.$RANDOM"
  emu_obj cert old-cert.pem "$P/a.pem"; emu_obj cert old-chain.pem "$P/a.chain.pem"; emu_obj key old-key.pem "$P/a.key"
  emu_obj cert site-cert.pem "$P/b.pem"; emu_obj key site-privkey.pem "$P/b.key"
  OBJ_OK=([cert:site-cert.pem]=1 [key:site-privkey.pem]=1)   # chain/fullchain fixed objects do not exist yet
  emu_lock tok-A || return 1
}
r10_complete() {
  backup_fixture
  job_backup >/dev/null 2>&1 || { cat "${WORK}/ssh.err"; return 1; }
  grep -q '^absent|cert|site-chain.pem$' "$J_BDIR_L/INVENTORY" || return 1
  grep -q '^bind|profile|entry|old-cert.pem|old-chain.pem|old-key.pem$' "$J_BDIR_L/INVENTORY" || return 1
  grep -q "restore-${J_TS}.sh" "$J_BDIR_L/SHA256SUMS" && grep -q ' INVENTORY$' "$J_BDIR_L/SHA256SUMS"
}
check "R10: a complete backup records every item, and its checksums cover the restore script" r10_complete

r10_incomplete() {
  backup_fixture
  f5_mut() { printf 'FILE|restore-20261005-120000.sh\n'; return 0; }
  f5_get() { printf 'not a restore script\n' > "$2"; }
  job_backup >/dev/null 2>&1 && return 1
  return 0
}
check "R10: a backup reply without its checksums, inventory or PEM copies is refused" r10_incomplete

r10_tampered() {
  backup_fixture
  local real; real="$(declare -f f5_get)"
  f5_get() { cp -- "$1" "$2"; [[ "$2" == */key.* ]] && printf 'x' >> "$2"; return 0; }
  job_backup >/dev/null 2>&1 && return 1
  return 0
}
check "R10: a backup whose copy does not match its checksums is refused" r10_tampered

r10_inventory_mismatch() {
  backup_fixture
  # the BIG-IP side "forgets" one of the planned items
  R_BACKUP="$(printf '%s
' "$R_BACKUP" | sed 's/^      echo "obj|\$mode|\$t|\$name|\$out" >> "\$BDIR\/INVENTORY"$/      [ "$t" = cert ] || echo "obj|$mode|$t|$name|$out" >> "$BDIR\/INVENTORY"/')"
  [[ "$R_BACKUP" == *'[ "$t" = cert ] ||'* ]] || { echo "test setup: pattern not found"; return 1; }
  job_backup >/dev/null 2>&1 && return 1
  return 0
}
check "R10: a backup that lacks a planned item is refused (inventory compared with the plan)" r10_inventory_mismatch

r13_restore_save_failure() {
  backup_fixture
  job_backup >/dev/null 2>&1 || return 1
  local rs="${J_BDIR_R}/restore-${J_TS}.sh" out rc=0
  bash -n "$rs" || return 1
  cat > "$EMU/bin/tmsh" <<'EOF'
#!/usr/bin/env bash
if (( $# == 0 )); then cat >/dev/null; exit 0; fi
[[ "$1" == save ]] && exit 1
[[ "$1 $2" == "-q list" ]] && { echo "sys file ssl-cert x {"; exit 0; }
exit 0
EOF
  out="$(PATH="${EMU}/bin:${PATH}" bash "$rs" 2>&1)" || rc=$?
  echo "rc=$rc"
  [[ "$rc" != 0 && "$out" != *'restored the state'* ]]
}
check "R6: the generated restore script fails when the configuration save fails" r13_restore_save_failure

r10_restore_integrity() {
  backup_fixture
  job_backup >/dev/null 2>&1 || return 1
  local rs="${J_BDIR_R}/restore-${J_TS}.sh" rc=0
  printf '# tampered\n' >> "$rs"
  PATH="${EMU}/bin:${PATH}" bash "$rs" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 10 && ! -s "${EMU}/tmsh.log" ]]
}
check "R10: a restore script that was altered refuses to run (exit 10, nothing done)" r10_restore_integrity

r10_restore_full() {
  backup_fixture
  job_backup >/dev/null 2>&1 || return 1
  local rs="${J_BDIR_R}/restore-${J_TS}.sh" rc=0
  # objects exist (ensure), so only the fixed ones are reinstalled; absent ones are removed
  cat > "$EMU/bin/tmsh" <<'EOF'
#!/usr/bin/env bash
if (( $# == 0 )); then cat >> "${EMU}/tmsh.stdin"; exit 0; fi
printf '%s\n' "$*" >> "${EMU}/tmsh.log"
[[ "$1 $2" == "-q list" ]] && { echo "sys file x {"; exit 0; }
exit 0
EOF
  PATH="${EMU}/bin:${PATH}" bash "$rs" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 0 ]] || return 1
  grep -q 'install sys crypto cert site-cert.pem' "${EMU}/tmsh.log" \
    && grep -q 'delete sys crypto cert site-chain.pem' "${EMU}/tmsh.log" \
    && grep -q 'modify ltm profile client-ssl profile cert-key-chain modify { entry { cert old-cert.pem chain old-chain.pem key old-key.pem } }' "${EMU}/tmsh.stdin" \
    && grep -q '^save sys config' "${EMU}/tmsh.log"
}
check "R10: the restore script reinstalls, rebinds, removes new objects and saves" r10_restore_full

#######################################################################
echo "== R7: signals"
#######################################################################
r7_signal_after_change() {
  local rc=0
  bash -c '
    source <(sed "\$d" "$PUSH")
    WORK="$(mktemp -d)"
    J_CHANGED=1; J_AUTOROLL=yes; JOB_ACTIVE=1; J_DEP=d; J_F5=f; J_TS=20261005-120000
    job_rollback() { touch "$WORK/../r7-rolled-back.$$"; J_CHANGED=0; return 0; }
    job_remove_created() { return 0; }
    remote_lock_release() { return 0; }
    kill -TERM "$$"
    sleep 1
    exit 99
  ' >/dev/null 2>&1 || rc=$?
  echo "rc=$rc"
  [[ "$rc" == 3 ]]
}
check "R7: SIGTERM after a change rolls back and exits 3" r7_signal_after_change

r7_signal_codex() {
  # Codex's reproduction verbatim in spirit: only J_CHANGED=1 is set (no job flag).
  local rc=0
  bash -c '
    source <(sed "\$ d" "$PUSH")
    WORK="$(mktemp -d)"
    J_CHANGED=1; J_AUTOROLL=yes
    job_rollback() { touch "$WORK/../r7c-rolled-back"; J_CHANGED=0; return 0; }
    job_remove_created() { return 0; }
    remote_lock_release() { return 0; }
    kill -TERM "$$"; sleep 1; exit 99
  ' >/dev/null 2>&1 || rc=$?
  echo "rc=$rc"
  [[ "$rc" == 3 ]]
}
check "R7: a signal while the BIG-IP may have changed always leads to a rollback (exit 3)" r7_signal_codex

r7_signal_deferred() {
  local rc=0 out
  out="$(bash -c '
    source <(sed "\$d" "$PUSH")
    WORK="$(mktemp -d)"
    J_CHANGED=1; J_AUTOROLL=yes; JOB_ACTIVE=1; J_DEP=d; J_F5=f; J_TS=20261005-120000
    job_rollback() { echo ROLLBACK; J_CHANGED=0; return 0; }
    job_remove_created() { return 0; }
    remote_lock_release() { return 0; }
    mut_begin
    kill -TERM "$$"
    echo STEP-FINISHED
    mut_end
    sig_check
    exit 99
  ' 2>&1)" || rc=$?
  echo "rc=$rc"
  [[ "$rc" == 3 && "$out" == *STEP-FINISHED*ROLLBACK* ]]
}
check "R7: a signal during a BIG-IP step waits for the step, then recovers" r7_signal_deferred

r7_signal_unchanged() {
  local rc=0
  bash -c '
    source <(sed "\$d" "$PUSH")
    WORK="$(mktemp -d)"
    J_CHANGED=0; JOB_ACTIVE=1; J_DEP=d; J_F5=f
    job_remove_created() { return 0; }
    remote_lock_release() { return 0; }
    kill -INT "$$"; sleep 1; exit 99
  ' >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 130 ]]
}
check "R7: a signal before any change exits 130" r7_signal_unchanged

#######################################################################
echo "== R8: the BIG-IP lock is a lease with fencing"
#######################################################################
r8_lease() {
  load_push; emu_init
  local L="${EMU}/run/f5-cert-push.lock" out
  out="$(f5_sh "${R_LOCK}" 30 tok-A 'A')"; [[ "$out" == 'LOCK|OK|new' ]] || return 1
  # A keeps renewing: a directory older than the stale time is NOT taken over
  touch -d '40 minutes ago' "$L"
  out="$(f5_sh "${R_BEAT}" tok-A)"; [[ "$out" == 'BEAT|OK' ]] || return 1
  out="$(f5_sh "${R_LOCK}" 30 tok-B 'B')"; [[ "$out" == LOCK\|BUSY* ]] || { echo "renewed lock taken: $out"; return 1; }
  # A stops renewing: after the stale time B takes over ...
  touch -d '31 minutes ago' "$L/beat"
  out="$(f5_sh "${R_LOCK}" 30 tok-B 'B')"; [[ "$out" == 'LOCK|OK|stale' ]] || { echo "$out"; return 1; }
  # ... and A is fenced: its next step does not run
  J_TS=1; REMOTE_LOCK_TOKEN=tok-A
  local rc=0
  f5_mut 'touch "$EMU/A-ran"' >/dev/null || rc=$?
  [[ "$rc" == "${ST_LOCKLOST}" && ! -e "$EMU/A-ran" ]] || { echo "rc=$rc"; return 1; }
  # A's release does not remove B's lock
  out="$(f5_sh "${R_UNLOCK}" tok-A)"; [[ "$out" == 'UNLOCK|NOTOURS' && "$(sed -n 1p "$L/owner")" == tok-B ]]
}
check "R8: a renewed lock is never taken over; an expired one is, and the old owner is fenced" r8_lease

r8_config() {
  local rc=0 conf="${TMP}/r8.conf"
  mkconf "$conf" <<'EOF'
[f5:a]
host = 10.0.0.1
remote_timeout = 1200
remote_lock_stale_minutes = 30
[cert:c]
cert = /etc/x.crt
key = /etc/x.key
[deploy:d]
f5 = a
cert = c
EOF
  "$PUSH" --config "$conf" --list >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 2 ]]
}
check "R8: a lock lease shorter than the step timeout is a configuration error" r8_config

r8_local_lock() {
  load_push
  F5_NAME=a; F5_HOST=h; F5_PORT=22; CFG[f5:a\|lock_dir]="${TMP}/r8locks"
  lock_acquire || return 1
  ( lock_acquire ) && { echo "second acquire succeeded"; return 1; }
  # a dead owner's lock is taken over
  release_all_locks
  mkdir -p "${TMP}/r8locks/h_22.lock"; echo 999999 > "${TMP}/r8locks/h_22.lock/pid"
  lock_acquire >/dev/null 2>&1 || return 1
  [[ "$(cat "${TMP}/r8locks/h_22.lock/pid")" == "$$" || "$(cat "${TMP}/r8locks/h_22.lock/pid")" == "$BASHPID" ]]
}
check "R8: the local lock excludes a second run and takes over a dead owner's lock" r8_local_lock

#######################################################################
echo "== R9: a failed fixed-name refresh is a failed deployment"
#######################################################################
r9_fixed_failure() {
  load_push
  CFG[deploy:d\|cert]=c
  prepare_cert() { return 0; }
  job_init() { J_MODE=atomic; J_FIXED=yes; J_CERT=c; J_PREFIX=c; J_TS=20261005-120000; J_DEP=d; J_F5=f
               J_RESULT=''; J_RC=0; J_MSG=''; J_CHANGED=0; J_UNKNOWN=0; J_AUTOROLL=yes; J_TARGETS=('p|e|c|none|k'); J_CREATED=(); }
  job_lock() { return 0; }
  job_probe() { X_VERSION=17.1.3.4; X_FAILOVER=active; X_SYNC=standalone; return 0; }
  job_gate() { return 0; }; job_select_targets() { return 0; }; job_objinfo() { return 0; }
  job_report_state() { return 0; }; job_is_current() { return 1; }
  job_backup() { return 0; }; job_stage() { return 0; }; job_install_versioned() { return 0; }
  job_switch_profiles() { J_CHANGED=1; return 0; }; job_verify_bindings() { return 0; }
  job_verify_endpoints() { return 0; }
  job_install_fixed() { J_CHANGED=1; job_fail 1 'partial fixed-name install failed'; }
  job_rollback() { echo ROLLBACK; J_CHANGED=0; return 0; }
  job_remove_created() { return 0; }; job_unstage() { return 0; }; job_prune() { return 0; }
  lock_release() { return 0; }
  CERT_END[c]='test date'
  run_job d f >/dev/null 2>&1
  echo "result=$J_RESULT rc=$J_RC"
  [[ "$J_RESULT" == ROLLED_BACK && "$J_RC" == 3 ]]
}
check "R9: a failed fixed-name refresh rolls back and exits 3 (not UPDATED/0)" r9_fixed_failure

r9_fixed_verify() {
  load_push
  J_CERT=c; J_PREFIX=c; J_PART=Common; J_FP=AAA; CERT_KEYPUB[c]=k1; CERT_HAVE_CHAIN[c]=1; CERT_CHAINFP[c]=CCC; CERT_FULLFP[c]=AAA,CCC
  objinfo_read() { OBJ_CERTS=([c-cert.pem]=AAA [c-fullchain.pem]=AAA,CCC [c-chain.pem]=CCC); OBJ_KEYPUB=([c-privkey.pem]=OLDKEY); }
  job_verify_fixed && { echo "accepted a key that was not replaced"; return 1; }
  objinfo_read() { OBJ_CERTS=([c-cert.pem]=AAA [c-fullchain.pem]=AAA,OLD [c-chain.pem]=CCC); OBJ_KEYPUB=([c-privkey.pem]=k1); }
  job_verify_fixed && { echo "accepted a fullchain whose intermediate was not replaced"; return 1; }
  objinfo_read() { OBJ_CERTS=([c-cert.pem]=AAA [c-fullchain.pem]=AAA,CCC [c-chain.pem]=CCC); OBJ_KEYPUB=([c-privkey.pem]=k1); }
  job_verify_fixed
}
check "R9: the fixed-name objects are read back (a key left behind is caught)" r9_fixed_verify

#######################################################################
echo "== R11: fullchain"
#######################################################################
r11() {
  local conf="${TMP}/r11.conf" rc=0
  mkconf "$conf" <<EOF
[f5:a]
host = 127.0.0.1
[cert:c]
cert = $P/a.pem
key = $P/a.key
chain = $P/a.chain.pem
fullchain = $P/b.full.pem
chain_check = warn
[deploy:d]
f5 = a
cert = c
EOF
  "$PUSH" --config "$conf" --validate >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]] || { echo "mismatched fullchain accepted (rc=$rc)"; return 1; }
  sed -i "s#b.full.pem#a.full.pem#" "$conf"
  "$PUSH" --config "$conf" --validate >/dev/null 2>&1
}
check "R11: a fullchain that does not match cert+chain is refused; a matching one is accepted" r11

#######################################################################
echo "== R12: overlapping targets"
#######################################################################
r12_conf() {   # r12_conf PROFILE-A PROFILE-B [EXTRA-F5-SECTION]
  local conf="${TMP}/r12.conf"
  mkconf "$conf" <<EOF
[f5:a]
host = 10.0.0.1
[f5:alias]
host = 10.0.0.1
[cert:c]
cert = /etc/x.crt
key = /etc/x.key
[cert:b]
cert = /etc/y.crt
key = /etc/y.key
[deploy:one]
f5 = a
cert = c
profile = $1
[deploy:two]
f5 = ${3:-a}
cert = b
profile = $2
EOF
  "$PUSH" --config "$conf" --list >/dev/null 2>&1
}
r12() {
  local rc
  rc=0; r12_conf shared /Common/shared || rc=$?;           [[ "$rc" == 2 ]] || { echo "bare vs qualified accepted"; return 1; }
  rc=0; r12_conf shared shared:rsa || rc=$?;               [[ "$rc" == 2 ]] || { echo "implicit vs explicit entry accepted"; return 1; }
  rc=0; r12_conf shared shared alias || rc=$?;             [[ "$rc" == 2 ]] || { echo "same device via an alias accepted"; return 1; }
  rc=0; r12_conf shared:rsa shared:ecdsa || rc=$?;         [[ "$rc" == 0 ]] || { echo "disjoint RSA/ECDSA entries refused"; return 1; }
  rc=0; r12_conf one /Other/one || rc=$?;                  [[ "$rc" == 0 ]] || { echo "different partitions refused"; return 1; }
}
check "R12: targets are compared by device, partition and entry" r12

#######################################################################
echo "== R13: manual rollback does not need the new certificate"
#######################################################################
r13() {
  local conf="${TMP}/r13.conf" out rc=0
  mkconf "$conf" <<EOF
[f5:a]
host = 127.0.0.1
port = 1
connect_timeout = 3
lock_dir = ${TMP}/r13locks
[cert:c]
cert = ${TMP}/missing-cert.pem
key = ${TMP}/missing-key.pem
[deploy:d]
f5 = a
cert = c
EOF
  out="$("$PUSH" --config "$conf" --all --rollback --set 20261005-120000 2>&1)" || rc=$?
  echo "rc=$rc"; printf '%s\n' "$out" | tail -3
  [[ "$out" != *'unbound variable'* && "$out" == *'lock on the BIG-IP'* ]]
}
check "R13: --rollback reaches the BIG-IP even when the local certificate files are missing" r13

r13_fetch_all_files() {
  # Found by the BIG-IP suite while testing 2.1.0: ssh inside a while-read loop
  # swallowed the rest of the file list, so only the first file was fetched. The
  # real f5_get is used here, with an ssh stand-in that (like ssh) drains stdin.
  load_push; emu_init
  eval "$(sed -n '/^f5_get() {/,/^}/p' "$PUSH")"      # the real f5_get again
  SSH_OPTS=(-T); F5_USER=root; F5_HOST=bigip           # as f5_load would set them
  mkdir -p "${EMU}/sshbin"
  cat > "${EMU}/sshbin/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${@: -1}"
cat >/dev/null
eval "$cmd"
EOF
  chmod 755 "${EMU}/sshbin/ssh"
  PATH="${EMU}/sshbin:${PATH}"
  J_TS=20261005-120000; J_BDIR_R="${EMU}/shared/site/${J_TS}"; mkdir -p "$J_BDIR_R"
  local f
  for f in INVENTORY MANIFEST SHA256SUMS cert.1.a key.2.b "restore-${J_TS}.sh"; do echo "$f" > "${J_BDIR_R}/${f}"; done
  fetch_backup_set "${TMP}/r13-fetch" || { echo "$VB_ERR"; return 1; }
  [[ "$(ls "${TMP}/r13-fetch" | wc -l)" == 6 ]] || { ls "${TMP}/r13-fetch"; return 1; }
  # and f5_get itself never reads its caller's stdin
  local rest
  rest="$(printf 'line1
line2
' | { f5_get "${J_BDIR_R}/MANIFEST" "${TMP}/r13-one"; cat; })"
  [[ "$rest" == $'line1
line2' ]] || { echo "f5_get consumed stdin: '$rest'"; return 1; }
}
check "R13: --rollback copies every file of the backup set from the BIG-IP" r13_fetch_all_files

r13_legacy() {
  load_push
  local d="${TMP}/legacy" ts=20260930-162806
  cp -r "${T_DIR}/fixtures/legacy-2.0.0/${ts}" "$d"
  verify_backup_set "$d" "$ts" || { echo "$VB_ERR"; return 1; }
  [[ "$INV_LEGACY" == 1 && ${#INV_BIND[@]} == 2 && ${#INV_OBJ[@]} == 3 ]] || { echo "binds=${#INV_BIND[@]} objs=${#INV_OBJ[@]}"; return 1; }
  [[ "${INV_BIND[1]}" == 'www-clientssl|e1|site-cert-20260901-120000.pem|site-chain-20260901-120000.pem|site-privkey-20260901-120000.pem' ]]
}
check "R13: a backup set written by 2.0.0 can still be read and verified" r13_legacy

#######################################################################
echo "== Additional observations"
#######################################################################
o_log_lines() {
  load_push
  local out
  out="$(err $'first line\n[+] forged success' 2>&1)"
  [[ "$(printf '%s\n' "$out" | sed -n 2p)" == '    | [+] forged success' ]]
}
check "observation: a multi-line message cannot forge a log record" o_log_lines

o_collect() {
  load_push
  J_PREFIX=site; J_TS=20261005-120000; J_PART=Common; J_CERT=site; CERT_HAVE_CHAIN[site]=0; STAGE_DIR=/var/tmp/f5-cert-push.abcdef
  J_CREATED=()
  f5_mut() { printf 'CREATED|cert|/Common/somebody-elses.pem\n'; return 0; }
  job_install_versioned >/dev/null 2>&1 || return 1
  [[ "${J_CREATED[*]}" == 'key:site-privkey-20261005-120000.pem cert:site-cert-20261005-120000.pem' ]] || { echo "${J_CREATED[*]}"; return 1; }
}
check "observation: only the objects this run asked for are ever recorded as created" o_collect

#######################################################################
echo "== Second review (2.1.0, B1-B10)"
#######################################################################
b1_marker() {
  load_push; emu_init; emu_lock A || return 1; J_TS=20261006-120000
  local real; real="$(declare -f f5_sh)"; eval "emu_sh${real#f5_sh}"
  # the real wrapper runs, but its last reply line is lost; the step's own output
  # imitates an end line
  f5_sh() { if [[ "$1" == *'STEP|NOLOCK'* ]]; then emu_sh "$@"; else emu_sh "$@" | sed '$d'; return 124; fi; }
  local rc=0
  f5_mut $'echo "STEPEND|0"\necho "STEPEND|x|0"\nexit 1' >/dev/null || rc=$?
  echo "returned=$rc"
  [[ "$rc" == 1 ]]
}
check "B1: a step's own output cannot pass for its end line; the recorded status (1) is returned" b1_marker

b2_late_start() {
  load_push; emu_init; emu_lock A || return 1; J_TS=20261006-120000
  local real; real="$(declare -f f5_sh)"; eval "emu_sh${real#f5_sh}"
  # the step is dispatched but held back until after the outcome has been read
  f5_sh() { if [[ "$1" == *'STEP|NOLOCK'* ]]; then emu_sh "$@"; else printf '%s' "$1" > "${EMU}/queued.sh"; return 124; fi; }
  local rc=0
  f5_mut 'touch "${EMU}/late-change"' >/dev/null || rc=$?
  [[ "$rc" == "${ST_NOTRUN}" ]] || { echo "rc=$rc"; return 1; }
  emu_sh "$(cat "${EMU}/queued.sh")" >/dev/null 2>&1      # ... and now it arrives
  [[ ! -e "${EMU}/late-change" ]] || { echo "the cancelled step still ran"; return 1; }
}
check "B2: a step reported as not run is cancelled on the BIG-IP and can never start later" b2_late_start

b3_guard() {
  load_push; emu_init; emu_lock A || return 1
  local L="${EMU}/run/f5-cert-push.lock" out
  touch -d '31 minutes ago' "$L/beat"
  # A is in the middle of a fence check (holds the guard) and renews; C, which saw
  # the expired beat, must wait for the guard and then find the lease renewed.
  ( exec 8>>"${EMU}/run/f5-cert-push.guard"; flock 8; command sleep 2; touch "$L/beat" ) &
  command sleep 0.5
  out="$(f5_sh "${R_LOCK}" 30 C 'C')"
  wait
  echo "C: $out"
  [[ "$out" == LOCK\|BUSY* && "$(sed -n 1p "$L/owner")" == A ]]
}
check "B3: lock take-over is serialised with renewal: a lease renewed during the attempt is not taken" b3_guard

b4_bundle() {
  load_push; emu_init
  RV_DIR="${TMP}/b4"; mkdir -p "$RV_DIR"
  cat "$P/a.pem" "$P/a.chain.pem" > "$RV_DIR/bundle.pem"
  emu_obj cert bundle.pem /dev/null
  cat "$P/a.pem" "$P/b.pem" > "${EMU}/fs/files_d/Common_d/certificate_d/:Common:bundle.pem_1001_1"
  INV_OBJ=('fix|cert|bundle.pem|bundle.pem'); INV_BIND=(); INV_ABSENT=(); INV_LEGACY=0
  f5_mut() { return 0; }
  cat > "${EMU}/bin/tmsh" <<'STUB'
#!/usr/bin/env bash
echo "sys file ssl-cert bundle.pem {"; echo "    fingerprint SHA256/00"; echo "}"
STUB
  restore_and_verify >/dev/null 2>&1 && { echo "accepted a bundle whose second certificate differs"; return 1; }
  cat "$P/a.pem" "$P/a.chain.pem" > "${EMU}/fs/files_d/Common_d/certificate_d/:Common:bundle.pem_1001_1"
  restore_and_verify >/dev/null 2>&1 || { echo "refused an identical bundle"; return 1; }
}
check "B4: rollback verification compares every certificate in a bundle" b4_bundle

b4_backup_parse() {
  load_push
  local d="${TMP}/b4b" ts=20261006-120000
  mkdir -p "$d"; cp "$P/a.pem" "$d/bundle.pem"
  printf '%s\n' '-----BEGIN CERTIFICATE-----' 'bm90LWEtY2VydGlmaWNhdGU=' '-----END CERTIFICATE-----' >> "$d/bundle.pem"
  printf 'obj|fix|cert|bundle.pem|bundle.pem\n' > "$d/INVENTORY"
  echo metadata > "$d/MANIFEST"; echo 'exit 0' > "$d/restore-$ts.sh"
  ( cd "$d" && sha256sum bundle.pem INVENTORY MANIFEST "restore-$ts.sh" > SHA256SUMS )
  verify_backup_set "$d" "$ts" 'obj|fix|cert|bundle.pem' && return 1
  return 0
}
check "B4: a backup whose second certificate does not parse is refused" b4_backup_parse

b5_store() {
  local base="${TMP}/b5" rc=0
  mkdir -p "$base/in" "$base/store"; chmod 1777 "$base/store"
  printf 'KEEP ME\n' > "$base/victim"; ln -s "$base/victim" "$base/store/.lock"
  "$INSTALL" --config "${TMP}/none.conf" --incoming "$base/in" --store "$base/store" --push-bin "$PUSH" --no-push >/dev/null 2>&1 || rc=$?
  echo "rc=$rc"
  [[ "$rc" == 2 && "$(cat "$base/victim")" == 'KEEP ME' ]] || return 1
  # a private store with a planted .lock link is refused too
  rm -f "$base/store/.lock"; chmod 700 "$base/store"; ln -s "$base/victim" "$base/store/.lock"; rc=0
  "$INSTALL" --config "${TMP}/none.conf" --incoming "$base/in" --store "$base/store" --push-bin "$PUSH" --no-push >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 2 && "$(cat "$base/victim")" == 'KEEP ME' ]]
}
check "B5: a store others can write to, or a .lock that is a link, is refused; nothing is written" b5_store

b6_hardlink() {
  load_install
  local d="${TMP}/b6" stg="${TMP}/b6-copy"
  mkdir -p "$d" "$stg"; chmod 3770 "$d"
  printf 'upload\n' > "$d/cert.pem"; printf 'PRIVATE SENTINEL\n' > "${TMP}/b6-victim"
  cd "$d" || return 1
  timeout() { command rm -f cert.pem; command ln "${TMP}/b6-victim" cert.pem; command timeout "$@"; }
  local rc=0 out
  out="$(copy_upload_files "$stg")" || rc=$?
  echo "rc=$rc $out"
  [[ "$rc" == 1 && "$out" == REJECT* ]] || return 1
  ! cmp -s "${TMP}/b6-victim" "$stg/cert.pem"
}
check "B6: a file swapped for a hard link between the check and the open is refused, not copied" b6_hardlink

b7_legacy_edited() {
  load_push
  local d="${TMP}/b7" ts=20260930-162806
  cp -r "${T_DIR}/fixtures/legacy-2.0.0/${ts}" "$d"
  # a profile change spelled differently from 2.0.0's own lines
  printf '%s\n' "printf '%s\\n' 'modify ltm profile client-ssl victim cert-key-chain modify { e { cert new.pem chain none key new.key } }' | tmsh" >> "$d/restore-${ts}.sh"
  verify_backup_set "$d" "$ts" && { echo "an edited 2.0.0 restore script was accepted"; return 1; }
  echo "$VB_ERR"; [[ "$VB_ERR" == *'not exactly what version 2.0.0 generates'* ]]
}
check "B7: a 2.0.0 restore script that is not exactly what 2.0.0 generated is refused" b7_legacy_edited

b8_signal() {
  local rc=0
  bash -c '
    source <(sed "\$ d" "$PUSH")
    WORK="$(mktemp -d)"
    RES_JOB=(previous); RES_RESULT=(CRITICAL); RES_RC=(5); RES_MSG=(uncertain)
    J_CHANGED=1; JOB_ACTIVE=1; J_AUTOROLL=yes; J_DEP=d; J_F5=f
    job_rollback() { J_CHANGED=0; return 0; }
    job_remove_created() { return 0; }
    remote_lock_release() { return 0; }
    kill -TERM "$$"; sleep 1; exit 99
  ' >/dev/null 2>&1 || rc=$?
  echo "rc=$rc"
  [[ "$rc" == 5 ]]
}
check "B8: after a signal the exit code is the worst of the whole run (an earlier CRITICAL stays 5)" b8_signal

b9_unknown_install() {
  load_push
  J_PREFIX=site; J_TS=20261006-120000; J_PART=Common; J_CERT=c
  CERT_HAVE_CHAIN[c]=0; J_CREATED=(); STAGE_DIR=/var/tmp/f5-cert-push.abcdef
  J_CHANGED=0; J_UNKNOWN=0; J_AUTOROLL=yes; J_DEP=d; J_F5=f; REMOTE_LOCK_KEEP=0
  f5_mut() { return "$ST_UNKNOWN"; }
  job_remove_created() { touch "${TMP}/b9-removed"; return 0; }
  job_unstage() { return 0; }
  lock_release() { echo "keep=$REMOTE_LOCK_KEEP" > "${TMP}/b9-release"; }
  job_install_versioned >/dev/null 2>&1 && return 1
  job_abort 'install failed' >/dev/null 2>&1
  echo "result=$J_RESULT rc=$J_RC $(cat "${TMP}/b9-release")"
  [[ "$J_RESULT" == CRITICAL && "$J_RC" == 5 && "$(cat "${TMP}/b9-release")" == keep=1 && ! -e "${TMP}/b9-removed" ]]
}
check "B9: an install that never reported is CRITICAL, keeps the BIG-IP lock and deletes nothing" b9_unknown_install

b10_local_owner_write() {
  load_push
  local l="${TMP}/b10-lock" rc=0
  mv() { return 1; }
  lock_take "$l" 2>/dev/null || rc=$?
  echo "rc=$rc"
  [[ "$rc" == 1 && ! -e "$l" && ${#HELD_LOCKS[@]} == 0 ]]
}
check "B10: a local lock whose owner cannot be recorded is not taken" b10_local_owner_write

echo
t_summary
