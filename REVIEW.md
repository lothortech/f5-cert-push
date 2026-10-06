# Review brief: f5-cert-push

This brief is for an **independent, adversarial review** of `f5-cert-push.sh` (a Bash tool that deploys
TLS certificates to F5 BIG-IP devices). It says what the tool is for, what it must guarantee, where the
risk concentrates, and how to run the evidence. **Please try to break it.** A finding with a reproducer is
worth more than a style remark.

Version under review: see `./f5-cert-push.sh --version`.

## 1. Orientation (10 minutes)

| Read | For |
|---|---|
| `README.md` | what it does, exit codes |
| `docs/SECURITY.md` | threat model and stated controls: **the claims to falsify** |
| `docs/CONFIGURATION.md` | config semantics |
| `f5-cert-push.sh` | the code (one file, about 2,900 lines) |
| `f5-cert-install.sh` | the upload wrapper (runs as root over uploader-writable folders) |
| `tests/offline.sh`, `tests/install.sh`, `tests/regress.sh`, `tests/f5.sh`, `tests/lib.sh` | the evidence |
| Section 7 below | the findings of the first adversarial review (2.0.0) and how each was fixed and tested |

Shape of the script, top to bottom: header and globals; logging and cleanup traps; built-in defaults;
**config parser** (`parse_config`); **config validation** (`check_value`, `validate_config`);
**local certificate preparation** (`prepare_cert`); **BIG-IP access** (`f5_load`, `f5_sh`, `f5_put`, `f5_get`)
and the **remote scripts** (`define R_*`, bash 4.2 code that runs on the BIG-IP); **per-job stages**
(`job_probe`, `job_gate`, `job_select_targets`, `job_backup`, `job_stage`, `job_install_*`,
`job_switch_profiles`, `job_verify_*`, `job_rollback`, `restore_and_verify`, `job_prune`); the **job
runner** (`run_job`, `job_abort`, `job_handle_failure`); **selection and actions**; **CLI** (`parse_args`, `main`).

Since 2.1.0 every step that changes the BIG-IP goes through **`f5_mut`**: the remote side ignores
HUP/PIPE; under the **guard** (a kernel `flock` on `/var/run/f5-cert-push.guard` that serialises every lock
operation) it checks that the run still holds the BIG-IP lock (fencing) and **claims** its random step id
(`mkdir`, once); it records the step's output and exit status in the lock directory and ends its reply with
`STEPEND|<step id>|<rc>` as the last line. A lost reply is resolved by polling `R_STEPRESULT`, which cancels a
step that has not claimed its id (by claiming it itself). (2.1.1) Signals are handled by `on_signal` / `signal_finish` / `sig_check`, deferred while
`IN_MUTATION` is non-zero (`mut_begin`/`mut_end`, nestable).

## 2. What the tool must guarantee (the invariants)

Try to violate each. A violation is a bug even if no exploit follows.

| # | Invariant |
|---|---|
| **I1** | **No value from the config file, the command line, a certificate, or the BIG-IP is ever interpreted as code** on the local host or on the BIG-IP, and none can become an option to `ssh`, `openssl`, `tmsh`, `rm`, `find`, etc. |
| **I2** | **Until the backup is complete and verified, nothing on the BIG-IP that affects traffic or configuration changes.** (The only writes before that point are the backup directory, the staging directory and the BIG-IP-side lock.) |
| **I3** | **All profile changes for one job happen in one tmsh transaction**: all or none. There is no moment where one profile has the new certificate and another (of the same job) does not, and no moment where a profile has a new key with an old certificate. |
| **I4** | **After any failure that occurs once profiles may have changed**, either the profiles are confirmed back on their previous certificate/chain/key (exit 3), or the tool reports `CRITICAL` (exit 5). It must never report success or a plain error while leaving the new certificate live unintentionally (except `auto_rollback = no`, which reports `FAILED_CHANGED` and says so). |
| **I5** | **Private key material is written only to:** the private scratch dir (0700, tmpfs if available), the BIG-IP staging dir (0700, `mktemp -d`), the BIG-IP key objects, and the backups (0700/0600). It is **never logged, printed or placed in a command line.** |
| **I6** | **Cleanup on every exit path**, including `SIGINT`/`SIGTERM`/`SIGHUP`: scratch dir shredded and removed, staging dir removed, both locks released. |
| **I7** | **Pruning only ever removes** backup directories matching `^[0-9]{8}-[0-9]{6}$` under the tool's own backup root, and certificate objects named `<prefix>-(cert|chain|privkey)-<timestamp>.pem`; never an object a profile still uses. |
| **I8** | **Mutual exclusion**: two runs against the same BIG-IP (same host or different hosts) cannot interleave their changes. (The BIG-IP lock is a renewed lease with fencing; the residual case is stated in SECURITY.md section 6, item 5.) |
| **I9** | **Exit codes are truthful** and follow the documented severity order. |
| **I10** | **Idempotence**: if every target already has this exact certificate, nothing changes and no backup is made. |
| **I11** | **No accidental fleet run**: nothing deploys without an explicit selector. |
| **I12** | **Refusal to act on a BIG-IP that is not in a known-good state** (config not fully loaded; not active). |

## 3. Attack surface, by function

| Surface | Where | What to try |
|---|---|---|
| Config file parsing | `parse_config`, `key_allowed`, `check_config_permissions` | Lines that confuse the regexes; CR/LF/tab/NUL-adjacent bytes; quotes; very long lines; repeated keys; a section header as a value; BOM; locale effects |
| Value validation | `check_value`, `is_*`, `validate_config` | A value that passes a regex but is dangerous downstream (see section 4); bash `[[ =~ ]]` pitfalls (anchoring, `.` and `*` in patterns, locale ranges); integer handling (`10#`, octal, empty, huge) |
| Remote argument passing | `f5_sh` (`printf %q`), every `R_*` call site | Any argument that could be re-parsed by the remote shell; empty arguments; arguments that start with `-`; arguments containing `:` or `|` (used as field separators in specs and replies) |
| **Remote scripts** | `R_LIB`, `R_BACKUP`, `R_INSTALL`, `R_TXN`, `R_PRUNE_*`, `R_LOCK`, `R_STAGE` | Word-splitting, globbing, unquoted expansions, `set -u` gaps, **the generated `restore-<TS>.sh`** (built from names; is every name provably safe inside its single-quoted `echo` lines and heredocs?), field-separator collisions, quoting of `rm -rf` targets |
| tmsh output parsing | `R_PROBE`, `R_OBJINFO`, `R_DISCOVER`, `job_probe`, `job_objinfo` | Hostile or unusual profile/entry/object names returned by a (compromised or quirky) BIG-IP; names containing `|`; partition-qualified names; output format differences between BIG-IP versions |
| Local file writes from remote data | `job_backup` (`f5_get` destinations), `job_prune` (local `rm -rf`) | Path traversal via a returned file name; symlinks in the backup dir; the validation of returned names |
| Key material handling | `prepare_cert`, `copy_src`, `job_stage`, `wipe_dir`, `make_work_dir`, `cleanup` | Any path where a key lands outside the declared locations; leaks through `ps`, logs, error messages or `set -x`; tmpfs fallback behaviour; race between validation and upload |
| Locking | `lock_acquire`, `lock_take`, `remote_lock_acquire`, `remote_lock_beat`, `R_LOCK`, `R_UNLOCK`, `R_BEAT`, the fence in `f5_mut` | Races in take-over and release (rename-then-check), lease renewal gaps, PID reuse, a displaced owner continuing, behaviour when the BIG-IP is unreachable during release, the lock deliberately kept after `CRITICAL` |
| Tracked steps | `f5_mut`, `R_STEPRESULT` | A reply that is lost, truncated, duplicated or forged; a `STEPEND` line inside a step's own output; a step that never starts vs one that is still running; the poll deadline |
| State machine | `run_job`, `job_abort`, `job_handle_failure`, `job_switch_profiles`, `job_rollback`, `restore_and_verify`, `check_bindings` | A failure ordering that leaves the BIG-IP changed but reported as success or plain error; rollback that "succeeds" without actually restoring; double-fault paths; `J_CHANGED` / `J_UNKNOWN` transitions |
| Backup integrity | `job_backup`, `verify_backup_set`, `parse_inventory` (including the 2.0.0 fallback), `fetch_backup_set`, `R_BACKUP`, `R_LISTFILES` | A set that passes with an item missing, an extra file, a checksum list that does not cover everything, an inventory that disagrees with the plan, a legacy restore script with crafted lines |
| SSH connection reuse | `f5_load`, `f5_close` | The control socket (private scratch dir): can another local user reach it? Is it always closed? What if the master dies mid-job, or `timeout` kills a client during master set-up? |
| Interrupts | `cleanup`, traps | Signals at each stage; `kill -9` (what is left, and is it recoverable); `set -u` with empty arrays on bash 4.2 |
| **Upload wrapper** | `f5-cert-install.sh`: `trusted_tree`, `dir_safe`, `upload_dir_ok`, `write_failed`, `process_upload`, `clear_upload`, `prune_releases`, `main` | Runs as root over folders **writable by uploaders**. The trust model is now: every directory down to `incoming` changeable only by root; upload folders root-owned and sticky; root never opens an uploader-controlled path for writing (`mktemp` + rename for `FAILED`, `unlink` for removal); reads via `dd iflag=nofollow,nonblock` with link-count check. Try: a configuration of permissions the checks accept but that still lets an uploader redirect root; `readlink -f` edge cases; a race the sticky bit does not cover |
| Selection | `select_jobs`, `parse_args`, `main` | Ways to run more than intended; `--lineage` edge cases (trailing slash, symlinks, empty); disabled deployments |

## 4. Specific hypotheses worth testing

These are the places the author is least sure about. They are leads, not claims.

1. **Field separators.** Specs and replies use `:` and `|`. Object/profile/entry names are validated to
   `[A-Za-z0-9._-]` (plus a leading `/Partition/`), both when they come from the config and when they come
   back from the BIG-IP (`safe_obj`, applied in `job_probe` before anything enters `ENT_LIST`). Confirm that
   nothing *else* can reach those fields.
2. **`restore-<TS>.sh` generation.** It embeds names from the BIG-IP (old binding) into `echo '...'` lines and
   `ensure`/`force` calls. The names came from the BIG-IP's own `tmsh` output. If a hostile name contained a
   single quote, would the generated script be injectable? (A BIG-IP would have to be hostile or the admin
   already powerful, but the restore script runs as root later, possibly from a cron or by a different operator.)
3. **`find_pem` on the BIG-IP** reconstructs a filestore path from an object name and matches it with a regex
   built from that name. Can a name cause it to read an unintended file?
4. **`R_PRUNE_BACKUPS` / local prune**: `rm -rf -- "${ROOT:?}/$d"`. `ROOT` comes from `backup_dir_remote` +
   prefix. Is there a config that makes `ROOT` dangerous? (`/` alone is rejected; what about `/shared/`, `/etc`?)
5. **Bash 4.2 compatibility** (RHEL 7): empty-array expansion under `set -u`, `${var,,}`, `[[ -v ]]`,
   associative-array edge cases. The script targets 4.2+.
6. **`sanitize` and log forging**: is every value that originates remotely or from a certificate passed
   through it before being printed or logged?
7. **SNI derivation** from a certificate's SAN/CN (attacker-influenced data if a third party issued the
   certificate): does it reach a command line unquoted, or the BIG-IP?
8. **Time-of-check/time-of-use** between `prepare_cert` and the upload (mitigated by copying once into the
   scratch dir; is the mitigation complete? what about the `le_dir` symlink targets?).
9. **Verification weaknesses**: can `job_verify_endpoints` report success without actually proving the
   virtual server serves the new certificate (for example a fingerprint read from the wrong handshake, a
   stale cached response, or an empty result compared to an empty expectation)?
10. **`job_is_current`** compares the leaf fingerprint only. A renewal that keeps the leaf but changes the chain
    is ignored (documented; `--force` redeploys). Is there any case where the same leaf fingerprint could
    still mean a different key or profile binding that matters?
11. **Transaction failure detection** relies on matching tmsh error text/codes in `tmsh_failed` and then
    **re-reading** state. Are there tmsh failure modes it does not match?
12. **Exit-code aggregation** (`overall_exit`) and `--fail-fast`: any mix of results that returns 0 incorrectly?
13. **Interaction of `set -f` (noglob)** with the rest of the local script: anything that silently relies on
    globbing?
14. **The upload wrapper's trust boundary.** An uploader can write anything into their folder at any time.
    Can they get root to read a file they cannot (via a hard link on a system without
    `fs.protected_hardlinks`), install something that was not validated, delete or overwrite outside their
    folder, or leak content through `FAILED`? Can a crafted folder name or `READY` cause harm?
15. **Tracked steps (2.1.1).** `f5_mut` accepts an outcome only from a final `STEPEND|<id>|n` line with its own
    random id, then from `R_STEPRESULT`; a step that has not claimed its id is cancelled by the poller claiming
    it. Can a step's own output, a partial reply, or a slow BIG-IP still make it report a wrong outcome? Is there
    any path in which a step runs after being reported as not run?
16. **The lease (2.1.1).** All lock operations, fence checks, claims and result reads are serialised by the
    guard `flock`. What does it **not** cover (the step body runs outside it, after its fence)? Is there an
    interleaving in which two runs both pass fence checks while each believes it holds the lock?
17. **Rollback verification (2.1.0).** `restore_and_verify` compares certificate objects by the fingerprint
    `tmsh` reports, and keys by the SHA-256 of their public key computed on the BIG-IP from the filestore file
    (`find_pem`). Can a restore that did not really restore pass these checks?
18. **2.0.0 backup sets** are read by parsing their restore script (`parse_inventory`). Can a crafted 2.0.0-style
    script make the parser accept a line that the script would execute differently?

## 5. Running the evidence

```bash
tests/offline.sh                      # no BIG-IP needed; Linux; about a minute
tests/install.sh                      # the upload wrapper; no BIG-IP
tests/regress.sh                      # one or more cases per finding of the first review; run as root for all of them
shellcheck f5-cert-push.sh f5-cert-install.sh tests/*.sh   # see docs/TESTING.md, "Static analysis"
# with a LAB BIG-IP you may modify (creates and removes zzz-* objects only):
F5_TEST_CONFIRM=yes F5_TEST_HOST=... F5_TEST_KEY=... tests/f5.sh
```

See `docs/TESTING.md`. **Do not run `tests/f5.sh` against a production BIG-IP.**

To reproduce a hostile-config finding without a BIG-IP: write the config, run
`./f5-cert-push.sh --config FILE --list` (parses and validates only). For a finding that needs a BIG-IP
response, describe the exact tmsh output; the remote scripts can be fed canned input.

## 6. Out of scope (stated limitations and non-goals)

- A compromised host running the tool or a compromised BIG-IP is **not** defended against (see SECURITY.md
  section 5). Findings that begin "if the attacker is root on the host" are out of scope; findings that
  begin "a hostile BIG-IP reply can make the tool do X on the host" are **in** scope.
- Supporting encrypted private keys, `server-ssl` profiles, HA synchronisation (documented non-goals).
- BIG-IP versions other than 17.1.3.4 (untested); please note version-specific assumptions you spot.
- Windows / macOS hosts.

## 6a. Known gaps (already noted by the author; still worth your view)

- The standby refusal and "configuration not loaded" refusal (`job_gate`) were **never exercised against a
  real device in those states** (the lab unit is standalone and healthy). Review them by reading.
- `shellcheck` 0.11.0 reports no errors. Its 13 warnings were reviewed by hand (unused variables, `ls | grep` over names already restricted to digits and a hyphen, a deliberate one-item loop); none is a defect.
- Tests do not cover `kill -9` or power loss.

## 7. Issues the author already found and fixed during development

Listed so they are not re-reported, and because each shows a class of mistake worth probing for elsewhere.

| Class | Issue (fixed) |
|---|---|
| Argument re-parsing | `ssh host bash -s -- a b` does not preserve argument boundaries; a `|` separator became a pipe. Fixed by `printf %q` on every argument. |
| Output-format assumption | `tmsh list sys crypto cert one-line` prints nothing (silently); retention did nothing while reporting success. Fixed; uses `sys file ssl-cert`. |
| Format mismatch | Fingerprints compared with and without colons, so every run looked out of date. Found by a live read-only run. |
| Locale dependence | `[[ =~ [^[:print:]] ]]` let UTF-8 (a BOM) through in a locale where high bytes count as printable. Fixed with an explicit byte range. |
| Environment assumption | `/dev/shm` writable-test passed but `mktemp` failed there. Fixed with fallback. |
| Symlink mode | `stat` reported a symlink's mode (777), a false "world-readable key" warning. Fixed with `stat -L`. |
| Precedence | A config `le_dir` silently back-filled files when the command line named others. Fixed. |
| Parsing | A naive `awk /chain /` matched the `cert-key-chain {` header. Anchored on indentation. |
| Dangling octal | `keep = 08` would break `(( ))`. Normalised with `10#`. |
| Glob expansion | Unquoted expansion of SAN text. Fixed with `set -f`. |
| Platform behaviour | OpenSSL 1.0.x `verify -partial_chain` accepts a mismatched chain and exits 0 on failure. Chain verification is skipped on OpenSSL < 1.1.0 rather than claimed. Found by running the tests on the BIG-IP's own bash 4.2 / OpenSSL 1.0.2. |
| Listing scope | `tmsh list ... recursive` stays inside `/Common` unless preceded by `cd /`; partition pruning and `--discover` missed other partitions. Fixed. |
| Signal during lock acquisition | A `SIGTERM` between the BIG-IP creating its lock and the reply being read leaked the lock. The token is now recorded before the call. |
| Time zones | Object and backup names were local time; now UTC so they sort chronologically through DST changes. |
| Cross-host races | The lock was local only. Added a BIG-IP-side lock with an owner token. |
| Unvalidated remote data | Names read back from the BIG-IP (used in rollback specs and the restore script) were not re-validated. Added `safe_obj`. |

### 7a. Findings of the first adversarial review (2.0.0), fixed in 2.1.0

Each was reproduced independently before it was fixed (all 14 reproductions confirmed). Against 2.1.0 the
review's own harness reproduces 13 of the 14 no longer; the 14th (`backup_without_integrity`) asserts only that
no local `SHA256SUMS` was written, which is also true when the backup is refused, as it now is. Each has at least
one case in `tests/regress.sh` that sets up the reported failure and requires the safe outcome. Where the BIG-IP
itself matters, `tests/f5.sh` covers it too.

| # | Finding (severity) | Fix | Tests |
|---|---|---|---|
| R1 | Rejection followed an uploader-planted `FAILED` symlink (high) | `write_failed`: report written to a `mktemp` file in the folder, then `mv -T` over `FAILED` (replaces the entry, never follows it). Folders must be root-owned and sticky, so the temporary file cannot be touched meanwhile | regress R1; R1-R3 as root with a real unprivileged uploader |
| R2 | Upload cleanup could `shred` a swapped-in symlink's target (high) | Uploads are removed with `unlink` only; never opened for writing. Private copies are still shredded | regress R2 |
| R3 | `nofollow` did not protect the upload folder or its ancestors (high) | `trusted_tree`: the real path of `incoming` and every ancestor must be changeable only by root (or the invoking user); `upload_dir_ok`: an upload folder must be root-owned and, if writable, sticky. Hard-linked upload files are refused | regress R3 (three cases) and the root case |
| R4 | A lost reply after a commit was treated as "unchanged" (high) | `f5_mut` tracked steps; `J_CHANGED=1` before dispatch; an explicit failure is confirmed by `check_bindings`; an unknown outcome sets `J_UNKNOWN` and ends `CRITICAL` even after a verified rollback; created objects are only removed once the state is confirmed | regress R4 (four cases); f5 s21 |
| R5 | Rollback could confirm success with a target missing (high) | `restore_and_verify` + `check_bindings`: every profile exists with exactly one matching entry and exact bindings; object contents compared by fingerprint / public-key hash; absent objects must be absent. Used by automatic and manual rollback | regress R5 (two cases); f5 s5, s6, s9 |
| R6 | `tmsh` exit status ignored; restore ignored a failed save (high) | `tmsh_ok` / `run_txn` require exit 0 **and** no error text; the restore script checks every command including the save | regress R6 (four cases) |
| R7 | Signals after a change exited without rollback (high) | `on_signal` defers during a BIG-IP step (`IN_MUTATION`), then `signal_finish` rolls back and verifies (3 / 5); before any change 130 | regress R7 (four cases); f5 s12 now requires the previous certificate unless `UPDATED`; f5 s23 (SIGTERM during the switch on a real BIG-IP: switch finishes, rolled back, exit 3) |
| R8 | A live run's BIG-IP lock could expire and be stolen (high) | Lease renewed at every step (`beat`); atomic take-over and release (rename, check owner, put back); fencing in every tracked step; `remote_lock_stale_minutes` must exceed `2 x remote_timeout + 300 s`; local stale take-over made atomic too | regress R8 (three cases); f5 s11, s22 |
| R9 | A partial fixed-name refresh reported `UPDATED`/0 (high) | A fixed-name failure is a failed deployment (`job_abort` -> rollback); `job_verify_fixed` reads back certificate, chain, fullchain and key | regress R9 (two cases); f5 s13, s14 |
| R10 | Backup accepted without its files or checksum coverage (medium) | Inventory planned locally and compared exactly; `SHA256SUMS` strictly parsed and covering every file (restore script, inventory, manifest included); every PEM parses; restore script exits 10 on a missing or mismatched checksum list | regress R10 (seven cases); f5 s2, s5 |
| R11 | Explicit fullchain not validated (medium) | A supplied fullchain must equal cert + chain (by fingerprints); the uploaded fullchain object is always built from the validated parts | regress R11 |
| R12 | Conflicts compared spellings, not targets (medium) | Compared by device (host:port), fully qualified profile, and entry overlap (an implicit entry overlaps all) | regress R12 (five configurations) |
| R13 | Manual rollback needed the new local certificate (medium) | `job_init_restore` needs only the target configuration; the set is fetched from the BIG-IP and checked; 2.0.0 sets still restorable | regress R13 (two cases); f5 s5 |
| obs | Multi-line messages could look like records | Continuation lines are prefixed `    | ` | regress (log lines) |
| obs | `job_is_current` ignored fixed-name drift | Fixed-name objects compared completely (certificate, chain, fullchain, key) | f5 s13, s14 |
| obs | Local stale-lock race | Rename-then-check take-over | regress R8 (local) |
| obs | `--list-backups` / `--rollback` exit codes | Listing failures exit 1; lock busy 6, lock error 1 | - |
| obs | Wrapper `chmod` relied on a glob under `set -f` | Explicit file list | regress (chmod) |
| obs | `collect_created` / discovery trusted reply names | Only the objects requested are recorded as created; discovery skips names in unexpected forms | regress (created objects) |
| (found while testing the fixes) | `lock_dir` was documented for `[f5:]` but rejected there | Accepted | regress R13 |
| (found by the BIG-IP suite while testing the fixes) | The new `--rollback` fetch called `ssh` inside a `while read` loop; `ssh` swallowed the rest of the file list, so only one file was copied (and the set was then, correctly, refused) | `f5_get` reads stdin from `/dev/null`; the list is collected before any transfer | regress R13 (fails without the fix); f5 s5 |

### 7b. Findings of the second review (of 2.1.0), fixed in 2.1.1

The second review (Codex, `gpt-6.1-sol`, sandboxed, no network, no BIG-IP) rated R1, R2, R6, R9, R11, R12 and R13
fixed and R3, R4, R5, R7, R8, R10 partly fixed, and demonstrated ten remaining defects with eleven tests. All
were confirmed independently (outside the sandbox) before being fixed. Its tests, run against 2.1.1, no longer
demonstrate any of them; `tests/regress.sh` holds an inverted version of each.

| # | Finding (severity given) | Fix | Test |
|---|---|---|---|
| B1 | A truncated reply could make a step's own `STEPEND\|0` line pass for success (high) | End line carries a random per-call step id and must be the reply's last line | regress B1 |
| B2 | Two `STEP\|NONE` answers were read as "never started", but a delayed step could still start (high) | Steps claim their id under the guard; the poller cancels an unclaimed step by claiming it; a cancelled step cannot start | regress B2 |
| B3 | A failed stale take-over (rename, put back) left a gap in which a third run could take the lock while the renewing owner kept going (high) | Every lock operation, fence check, claim and result read runs under one kernel `flock` on the BIG-IP; take-over is a plain remove-and-create inside it | regress B3 |
| B4 | Backup, rollback and fixed-name checks compared only the first certificate of a bundle (high) | `certall`: the fingerprints of every certificate in the stored file, in order, compared with the backup / expected chain; every certificate in a backed-up file must parse | regress B4 (two cases); f5 s13, s14 |
| B5 | The wrapper accepted a sticky world-writable store, so a planted `.lock` link was followed (high) | Store must not be writable by anyone else; `.lock` must be a regular file owned by the runner; otherwise refused | regress B5 |
| B6 | Hard-link / type checks were made on the name before `dd` opened it (medium) | The file is opened once and the opened descriptor is checked via `/proc/self/fd` (same inode, regular, one link) | regress B6 |
| B7 | A crafted 2.0.0 restore script could run unparsed changes (medium) | A 2.0.0 script must equal, byte for byte, what 2.0.0 generates for its parsed contents | regress B7; R13 (genuine 2.0.0 fixture accepted) |
| B8 | A signal's exit code ignored earlier results in the run (medium) | `signal_exit` uses the run's most severe result; 130 only if nothing worse | regress B8 |
| B9 | An install with an unknown outcome released the lock as a plain failure (medium) | `J_UNKNOWN` for the install; `CRITICAL`, lock kept, nothing deleted | regress B9 |
| B10 | The local lock was "taken" even if its owner could not be recorded (low) | Not taken unless recorded; locks only removed by their recorded owner | regress B10 |

The review also noted, without demonstrating, that the documented residual case of a run whose lease expires
while one of its steps is still running is real (a step body runs outside the guard, after its fence), and that
`R_UNLOCK`/`R_BEAT` deserved the same treatment as `R_LOCK` (they now run under the guard). The first is stated in
SECURITY.md section 6, item 5.

## 8. How to report

For each finding please give: **title; severity (critical / high / medium / low); the invariant or claim it
breaks (I1..I12 or a SECURITY.md sentence); a reproducer** (config + command, or canned remote output); the
code location (function name); and a suggested fix. Also welcome: parts of the code you found **hard to
reason about**; those are risks in themselves.
