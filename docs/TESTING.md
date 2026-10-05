# Testing

There are two suites in `tests/`. Together they are the evidence that the tool behaves as documented.
**Run both after any change to the script.**

| Suite | Needs | Changes anything? | Covers |
|---|---|---|---|
| `tests/offline.sh` | Linux, bash, openssl; **no BIG-IP** | No (works in a temp dir) | Configuration parsing and validation, injection attempts, selection, certificate validation |
| `tests/install.sh` | Linux, bash, openssl; **no BIG-IP** | No (works in a temp dir) | `f5-cert-install.sh`: READY handling, validation and rejection, symlink refusal, atomic install, retention, push retry, locking |
| `tests/f5.sh` | Linux, SSH access to a **lab BIG-IP** | **Yes**: creates and removes `zzz-*` objects | Real deployments, rollback, retention, locking, interruption, partitions, SSH trust |

`tests/lib.sh` holds shared helpers, including a small **test PKI** (root, intermediate, RSA and ECDSA leaves,
expired and not-yet-valid certificates) generated with `openssl ca`, so no real certificate or key is used.

## Running the offline suite

```bash
tests/offline.sh                 # prints PASS / FAIL / SKIP per assertion and a total
T_VERBOSE=1 tests/offline.sh     # show output for failures
```

Exit status is non-zero if any assertion failed. It needs a Linux host: the certificate tests use absolute
paths and GNU tools. (On Windows, Git Bash's native `openssl` cannot open MSYS `/tmp` paths, so the certificate
cases fail there; run the suite on Linux or in WSL.)

What it covers:

- **Command line**: `--version`, `--help`, unknown options, missing values, selector refusal, `--opt=value`.
- **Accepted configuration forms**: minimal, CRLF line endings, quoted values, comma lists, tabs, IPv6, all
  profile and verify syntaxes, non-ASCII in comments.
- **Structural errors**: unknown sections and settings, duplicate sections and settings, settings outside a
  section, garbage lines, byte-order marks, non-ASCII and control characters.
- **Cross-reference errors**: missing host/cert/files, undefined references, two deployments fighting over a
  profile or an object prefix.
- **Value validation and injection**: ~40 hostile values (`;`, `$(...)`, backticks, pipes, leading hyphen,
  spaces, `..`, `//`, braces, out-of-range numbers, bad enumerations). Each must be refused **and must not
  execute anything** (a marker file is checked).
- **File permissions**: world- and group-writable configurations are refused.
- **Selection**: `--deploy`, `--env`, `--f5`, `--lineage`, `--all`, disabled deployments.
- **Certificate validation**: valid RSA, ECDSA, no chain, fullchain-only, mismatched chain (warn / fail / off),
  key mismatch, expired, not yet valid, `min_days_valid`, encrypted key, PKCS#1 key, combined PEM, multi-cert
  `cert`, two keys in one file, garbage, empty and oversized files, certbot-style symlinks, explicit overrides,
  a readable key warning, and that no scratch directory is left behind.

## Running the BIG-IP suite

> **Use a lab device.** The suite creates client-ssl profiles, two virtual servers, certificates and keys,
> one partition and backup directories, all named `zzz-*`, and removes them afterwards (even after a failure).
> It does not touch anything else, but it does change the device while it runs.

Requirements on the BIG-IP: SSH key login for root; two **unused** IP addresses in a subnet the BIG-IP has a
self IP in (used as test virtual-server addresses on port 443; they are probed from the BIG-IP itself).

```bash
export F5_TEST_CONFIRM=yes
export F5_TEST_HOST=10.0.0.11
export F5_TEST_KEY=/root/.ssh/f5_push_ecdsa
export F5_TEST_VS_A=10.1.10.77        # optional; these are the defaults
export F5_TEST_VS_B=10.1.10.78
tests/f5.sh                            # about 20-40 minutes
F5_TEST_ONLY="s2 s9" tests/f5.sh       # just some scenarios
```

The suite refuses to start without `F5_TEST_CONFIRM=yes`. It needs `ssh-keyscan` (to pin the host key for its
own connections) and pins nothing outside its temporary directory.

| Scenario | What it proves |
|---|---|
| **s1** read-only | `--check`, `--dry-run`, `--discover` change nothing and make no backup |
| **s2** first deploy | two profiles switched together; the virtual server serves the new certificate; change saved to `bigip.conf`; backup present on both sides, checksums verified, modes 0700/0600; no staging directory or lock left |
| **s3** idempotence | a second run is a no-op with no new backup; `--force` redeploys |
| **s4** renewal | the old objects are retained; both old and new fingerprints are exactly as expected |
| **s5** manual rollback | restores the previous objects and what the virtual server serves; a missing set fails harmlessly; a **tampered backup is refused** |
| **s6** restore after deletion | rollback **reinstalls** a deleted object from its backup PEM, byte-identical |
| **s7** pre-flight failures | missing profile, inheriting profile, ambiguous multi-entry profile, missing entry, missing partition, expired certificate: each fails **with the BIG-IP provably unchanged** |
| **s8** dual RSA+ECDSA | only the named entry changes; a transaction the BIG-IP rejects leaves every profile unchanged and removes the objects it created |
| **s9** auto-rollback | a wrong certificate on a verify endpoint rolls back (exit 3) and restores what is served; `auto_rollback = no`; unreachable endpoints warn or roll back per `verify_unreachable` |
| **s10** retention | after five deployments with `keep = 2`, exactly two backup sets (both sides), two certificate, chain and key versions remain, and the newest is in use; `keep = 0` disables pruning |
| **s11** locking | a live local lock gives exit 6 and changes nothing; a lock **held on the BIG-IP by another host** gives exit 6, shows its owner and is not removed; read-only runs ignore both; stale locks (local and on the BIG-IP) are cleaned; two simultaneous runs: one wins, one gets exit 6 |
| **s12** interruption | `SIGTERM` at six different moments: no staging directory, no local or BIG-IP lock, every profile still points at existing objects, both profiles agree (atomic), and a normal run afterwards succeeds |
| **s13** objects-only | no profile configured: fixed-name objects replaced in place; idempotent; rollback restores the previous content |
| **s14** fixed names | `fixed_names = yes` alongside a profile |
| **s15** partition | a non-Common partition: bare profile name resolved, objects created in the partition, pruning and rollback work |
| **s16** SSH trust | unknown host key refused; `accept-new` pins; unreachable host fails fast; wrong key and missing key fail |
| **s17** many deployments | one failure does not stop the rest; exit 1; `--fail-fast`; two `[f5:]` names for one device |
| **s18** lineage | `--lineage` deploys the matching certbot-style certificate and exits 0 for an unmanaged one |
| **s20** manual upload | `f5-cert-install.sh` end to end: an upload is installed and served by the virtual server; a renewal; a run with nothing new does not contact the BIG-IP; a bad upload is rejected and the BIG-IP keeps the previous certificate |
| **s19** local verification | `verify_from = local` against a local TLS server: match passes, mismatch rolls back |

## Old platforms (bash 4.2, OpenSSL 1.0.2)

The script targets bash 4.2 or newer (RHEL 7 class) and the BIG-IP-side scripts run under the BIG-IP's bash 4.2.
The BIG-IP itself is such a platform (bash 4.2.46, OpenSSL 1.0.2za), so the suites can be run **on it** to
exercise that claim: copy `f5-cert-push.sh` and `tests/` to `/var/tmp/` and run

```bash
T_SKIP_CERTS=1 bash tests/offline.sh      # config parsing, validation, selection (no PKI needed)
```

`T_SKIP_CERTS=1` skips the certificate cases, because building the test PKI needs OpenSSL 1.1.1 (`req -addext`).
To exercise certificate validation on the old OpenSSL, generate the test PKI on a modern host
(`pki_init` / `pki_leaf` from `tests/lib.sh`), copy it over and run `--validate` against it.

Results when this was done (bash 4.2.46, OpenSSL 1.0.2za): all 193 non-certificate assertions passed; RSA,
ECDSA, fullchain-only, expired and mismatched-key certificates behaved correctly. It also found a real bug that
the modern-platform tests could not: OpenSSL 1.0.x's `verify -partial_chain` accepts a mismatched chain and exits
0 on failure. The chain check is therefore skipped on OpenSSL older than 1.1.0 (warning, or refusal under
`chain_check = fail`) instead of pretending to verify.

## What the suites do **not** cover

Stated plainly so you can decide how much to trust them:

- **BIG-IP in a standby or offline state**, and a device whose **configuration is not loaded**. The refusals
  are implemented (`job_gate`) but were not exercised because the test device is a standalone unit. Test them
  on your own pair before relying on them.
- **HA synchronisation.** The tool does not sync; it prints a reminder.
- **BIG-IP versions other than 17.1.3.4.**
- **Chain verification on OpenSSL older than 1.1.0** (deliberately skipped there; see above).
- **Profiles with a key passphrase** (refused by design; the detection path is not tested against a device).
- **`server-ssl` profiles** (not supported).
- **A very large number of profiles or objects**, or a slow WAN link to the BIG-IP.
- **Concurrent human changes** to the same profiles during a run.
- **Power loss or `kill -9` mid-run.** Cleanup cannot run; the recovery (stale lock removal, staging sweep) is
  described in the operations guide, and the atomic transaction means the BIG-IP is never left half-switched.

## Static analysis

`shellcheck` 0.11.0 over `f5-cert-push.sh`, `f5-cert-install.sh` and `tests/*.sh` reports **no errors**. It reports
13 warnings and 26 notes, all reviewed by hand and none a defect: a few variables that are set but not used
later, `ls | grep` over directory names that are already restricted to `YYYYMMDD-HHMMSS`, `a && b || die`
patterns where the right-hand side is the error exit, a one-item loop kept for readability, and functions that
are only called from traps. Run it yourself: `pip install shellcheck-py` (or your package manager), then
`shellcheck f5-cert-push.sh f5-cert-install.sh tests/*.sh`.

## Adding a test

Both suites use the helpers in `tests/lib.sh`: `run CMD...` captures `OUT` and `RC`; `expect_rc`, `expect_has`,
`expect_lacks`, `expect_eq`, `expect_true`, `expect_false` assert; `t_case` names the current case. A new
hostile-input case for the parser is one line in `offline.sh`:

```bash
inj "host with a newline-ish thing" host "10.0.0.1%0a"
```

A new BIG-IP scenario belongs in `f5.sh` as a `if want sNN; then ... fi` block; **snapshot the BIG-IP
(`snapshot`) before a failure-path test and assert it is unchanged afterwards**; that is the property that matters.
