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
| `f5-cert-push.sh` | the code (one file, about 2,300 lines) |
| `tests/offline.sh`, `tests/f5.sh`, `tests/lib.sh` | the evidence |

Shape of the script, top to bottom: header and globals; logging and cleanup traps; built-in defaults;
**config parser** (`parse_config`); **config validation** (`check_value`, `validate_config`);
**local certificate preparation** (`prepare_cert`); **BIG-IP access** (`f5_load`, `f5_sh`, `f5_put`, `f5_get`)
and the **remote scripts** (`define R_*`, bash 4.2 code that runs on the BIG-IP); **per-job stages**
(`job_probe`, `job_gate`, `job_select_targets`, `job_backup`, `job_stage`, `job_install_*`,
`job_switch_profiles`, `job_verify_*`, `job_rollback`, `job_prune`); the **job runner** (`run_job`);
**selection and actions**; **CLI** (`parse_args`, `main`).

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
| **I8** | **Mutual exclusion**: two runs against the same BIG-IP (same host or different hosts) cannot interleave their changes. |
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
| Locking | `lock_acquire`, `remote_lock_acquire`, `R_LOCK`, `R_UNLOCK` | Races (check-then-act), stale-lock logic, PID reuse, lock release by a non-owner, behaviour when the BIG-IP is unreachable during release |
| State machine | `run_job`, `job_handle_failure`, `job_rollback` | A failure ordering that leaves the BIG-IP changed but reported as success or plain error; rollback that "succeeds" without actually restoring; double-fault paths |
| SSH connection reuse | `f5_load`, `f5_close` | The control socket (private scratch dir): can another local user reach it? Is it always closed? What if the master dies mid-job, or `timeout` kills a client during master set-up? |
| Interrupts | `cleanup`, traps | Signals at each stage; `kill -9` (what is left, and is it recoverable); `set -u` with empty arrays on bash 4.2 |
| **Upload wrapper** | `f5-cert-install.sh`: `process_upload`, `clear_upload`, `prune_releases`, `main` | Runs as root over a directory **writable by uploaders**. Symlinks, hard links, FIFOs, devices or races planted in `incoming/`; the `dd iflag=nofollow,nonblock`-then-inspect copy; names of folders; the atomic `current` switch (`ln` + `mv -T`); what a hostile upload can make root read, write or print (the `FAILED` file is written into the uploader-writable folder) |
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

## 5. Running the evidence

```bash
tests/offline.sh                      # no BIG-IP needed; Linux; about a minute
shellcheck f5-cert-push.sh f5-cert-install.sh tests/*.sh   # 0.11.0: no errors; 13 warnings, reviewed, none a defect (see docs/TESTING.md)
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

## 8. How to report

For each finding please give: **title; severity (critical / high / medium / low); the invariant or claim it
breaks (I1..I12 or a SECURITY.md sentence); a reproducer** (config + command, or canned remote output); the
code location (function name); and a suggested fix. Also welcome: parts of the code you found **hard to
reason about**; those are risks in themselves.
