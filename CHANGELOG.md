# Changelog

## 2.1.0

Fixes for every finding of the adversarial review of 2.0.0 (R1-R13 and the additional observations). Each
finding has a regression test in `tests/regress.sh`; `REVIEW.md` section 7 maps findings to fixes and tests.
Configuration files from 2.0.0 work unchanged, except for the two new checks marked **(config)** below.
Backup sets written by 2.0.0 can still be restored with `--rollback`.

### Upload wrapper (`f5-cert-install.sh`): trust boundary (R1, R2, R3)
- Root never acts through a path an uploader can redirect:
  - `FAILED` is written to a new private file and renamed into place (a planted symlink is replaced, never
    followed);
  - uploads are removed with `unlink` and no longer overwritten in place (`shred` on an uploader-controlled
    path could be redirected by a swapped-in symlink);
  - upload files with more than one link (hard links) are refused.
- The wrapper refuses to run unless the upload directory and every directory above it can only be changed by
  root, and skips an upload folder that is not root-owned and sticky. **Upload folders must now be mode
  `3770` (root:GROUP, sticky)**, and `incoming` itself `0750` (see `docs/MANUAL-UPLOAD.md`). (config)
- `chmod` of an installed release no longer relies on a glob (which `set -f` disabled).

### Truthful outcomes and recovery (R4, R5, R6, R7, R9)
- Every step that changes the BIG-IP now runs **tracked**: it checks the lock first (fencing), keeps running
  if the connection drops, and records its output and exit status on the BIG-IP. A lost reply is answered by
  reading that record back; an outcome that still cannot be established is treated as changed and reported
  `CRITICAL`. (R4)
- A reported transaction failure is confirmed by re-reading the profiles before the BIG-IP is called
  unchanged. (R4)
- Rollback is verified on the device against the backup's inventory: every profile entry must exist exactly
  once with exactly its old certificate, chain and key; every backed-up object must hold the backed-up
  certificate (fingerprint) or key (public-key hash); objects that did not exist before must not exist. The
  same verification is used by `--rollback`. (R5)
- The exit status of every `tmsh` command that changes something is checked, in the tool and in the generated
  restore script; a failed `tmsh save sys config` now fails the restore script. (R6)
- Signals: while a step is running on the BIG-IP a signal is deferred until it finishes; after a change the job
  is rolled back and verified (exit 3, or 5) instead of exiting 130 with an unverified certificate live. (R7)
- A failed or partial fixed-name refresh is a failed deployment and is rolled back (it was `UPDATED`, exit 0).
  The fixed-name objects are read back after every overwrite (certificate, chain, fullchain, key). (R9)
- After `CRITICAL`, the BIG-IP lock is left in place until it expires or an administrator removes it.

### Locking (R8)
- The BIG-IP lock is a lease: renewed at every step, taken over only when it has not been renewed for
  `remote_lock_stale_minutes`, with atomic take-over and release (rename, then check the owner). Every change
  is fenced: it runs only if its run still holds the lock.
- **`remote_lock_stale_minutes` must be at least `(2 x remote_timeout + 300)` seconds** (rounded up to
  minutes); a shorter value is a configuration error. (config)
- The local lock's stale take-over is atomic too.

### Backups (R10, R13)
- Each backup set now has an `INVENTORY`. What the set must contain is worked out locally from the plan, and
  the set is refused unless it matches exactly, every file is present and parses, and `SHA256SUMS` (strictly
  parsed) covers **every** file, including the restore script, the inventory and the manifest.
- The restore script refuses to run (exit 10, nothing changed) if `SHA256SUMS` is missing or does not match.
- Fixed-name objects that did not exist before a run are recorded as absent and removed by the restore.
- `--rollback` no longer needs the certificate being undone (it failed when the local files were missing or
  invalid): it copies the set from the BIG-IP, checks it, restores, and verifies. (R13)

### Inputs and targets (R11, R12)
- A `fullchain` given together with `cert`/`chain` must match them exactly, and the fullchain object is always
  built from the validated certificate and chain. (R11)
- Overlapping deployments are detected by what the names mean on the device: BIG-IPs by host and port, profiles
  fully qualified with their partition, and a profile without an entry overlapping every entry. (R12)

### Other
- Multi-line messages mark their continuation lines (`    | `) so remote text cannot forge a log record.
- Only the objects a run asked to create are ever deleted again; a reply cannot add others.
- `--discover` skips (and counts) names in unexpected forms; `--list-backups` exits 1 if a listing failed;
  `--rollback` reports a lock held by another run as exit 6 and other lock errors as exit 1.
- `lock_dir` is accepted in `[f5:]` sections, as documented.
- `f5_get` no longer lets `ssh` read the caller's standard input.
- Tests: `tests/regress.sh` (regressions for every finding, including a real-permission uploader check when run
  as root); `tests/f5.sh` adds s21 (reply lost after the switch committed) and s22 (lock taken over mid-run)
  and s23 (SIGTERM during the switch: rolled back, exit 3), and requires the previous certificate after an
  interruption (s12). Results are in `docs/TESTING.md`, "Results for 2.1.0".

## 2.0.0

A rewrite for multi-device, multi-certificate use. Not backwards compatible with 1.x: the shell-sourced
`*.conf` of the earlier script is replaced by the INI format described in `docs/CONFIGURATION.md`.

### Added
- Configuration file with `[defaults]`, `[f5:NAME]`, `[cert:NAME]` and `[deploy:NAME]` sections:
  many BIG-IPs, many certificates, many deployments, environments (`env`), per-section overrides.
- Selection by `--deploy`, `--env`, `--f5`, `--lineage` (certbot) and `--all`; no accidental fleet run.
- Several profiles per deployment, updated in **one tmsh transaction**; entry-level updates
  (`profile = NAME:ENTRY`) that leave other entries untouched, so dual RSA+ECDSA profiles work.
- Profiles in other partitions (`/Partition/NAME`) and a per-BIG-IP `partition`.
- Optional chain; a `fullchain` + key can be given alone and is split automatically.
- `--check` (exit 4 when out of date), `--dry-run`, `--validate`, `--list`, `--discover`,
  `--list-backups`, `--rollback --set TS`.
- Automatic rollback when verification fails; exit code 3; `CRITICAL` (exit 5) if the rollback fails.
- Verification endpoints, probed from the BIG-IP or from the local host, with SNI support.
- Backups on the BIG-IP and locally with SHA-256 checksums; a **self-verifying restore script** that also
  reinstalls objects that were pruned or deleted.
- Retention (`keep`) for backup sets and for certificate versions.
- Locking on this host **and on the BIG-IP**, so different hosts cannot interleave.
- Refusal to act on a BIG-IP whose configuration is not fully loaded, or which is standby.
- Distinct exit codes; a summary table; optional log file.
- `f5-cert-install.sh` for manually uploaded certificates: `READY`-marker uploads, validation and rejection
  with a `FAILED` explanation, symlink refusal, atomic release switch, retention, push retry, `--status`.
- Offline test suites (236 + 154 assertions) and a BIG-IP integration suite (20 scenarios).

### Security
- The configuration is parsed, never sourced; every value is validated against a strict character set.
- Names read back from the BIG-IP are validated before use.
- Chain verification is skipped (warn) or refused (`chain_check = fail`) on OpenSSL older than 1.1.0, whose
  `verify -partial_chain` is unreliable.
- Private keys only touch a private tmpfs scratch directory, a private staging directory on the BIG-IP
  (`mktemp -d`, removed on exit and on signals) and mode-0600 backups.
- Host keys are verified by default; public-key authentication only; no forwarding.
- No pathname expansion (`set -f`); no `eval`; arguments to remote scripts are individually shell-quoted.

### Changed
- Object and backup timestamps are **UTC**. (If you have 1.x objects named in local time, their order relative to
  new names depends on your offset from UTC; they age out under `keep` like any other.)
- Object names are versioned (`<prefix>-cert-<time>.pem`) and profiles are repointed atomically; the
  fixed-name objects are optional (`fixed_names = yes`, or when no profile is listed).
- Fingerprints and expiry are read from the BIG-IP with tmsh rather than by reading the filestore.

## 1.x

Single-host shell script with a sourced configuration and one certificate. Superseded by 2.0.0.
