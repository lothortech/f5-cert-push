# Changelog

## 2.2.0

### HA pairs: config-sync, with verification
- After a deployment to the **active** unit, the tool now **synchronises its device group** and waits until
  every member reports **In Sync with the same last commit**: proof that the peers loaded this unit's
  configuration, not just a status line. `sync = auto` (the default) picks the one sync-failover device group
  the unit shares with another device; `sync_group = NAME` (in `[f5:]`) names it, and `sync = no` turns this
  off. `sync_timeout` (default 120 s) bounds the wait. A group with auto-sync is not synced again, only waited on.
- **Refuses to start unless the group is already In Sync.** A config-sync copies the unit's whole
  configuration, so syncing on top of someone else's pending change would publish it too. A pair showing
  `Changes Pending` (or anything but In Sync) stops the deployment before the backup, with the reason.
- **List both units** of a pair in a deployment (`f5 = dc1-a, dc1-b`). Whichever is active is deployed to and
  synchronised; the standby is not changed directly, and is checked **after** the sync (read-only): it must
  now serve the new certificate. A failover between runs needs no configuration change. A standby listed
  first waits for its active unit's job.
- New results: `IN_SYNC` (standby has the new certificate), `NOT_SYNCED` (it does not), `SKIPPED` (its active
  unit's deployment did not complete), `STANDBY` (no active unit of its group was in the run),
  `SYNC_FAILED` (deployed and verified on the active unit, but the sync did not complete: exit 1, with the
  command to run).
- A failed deployment that was rolled back (or an interrupted one) re-synchronises the group if it was In Sync
  before, so the next run is not refused. Not after `CRITICAL`: an unknown state is never copied to the peers.
- `--rollback` synchronises the group after a verified restore, if it was In Sync before; a standby listed in
  the rollback is skipped (it receives the rollback by the sync).
- `--check` also compares a standby unit (read-only).

### Discovery and a draft configuration
- `--discover` now shows, for each BIG-IP (`--f5 NAME`, repeatable; default: every one in the configuration):
  the device, its failover state, **its device groups with type, members, auto-sync and sync status**, and
  every client-ssl profile entry with its **certificate (CN, expiry), chain and key, and the virtual servers
  that use it**. Profiles on the default certificate are summarised on one line.
- `--discover --write-config FILE` writes your configuration **plus suggested `[cert:]` and `[deploy:]`
  sections** for every profile entry that no deployment covers yet: one deployment per certificate and per
  pair (both units listed), entries named where a profile has several, `verify` lines from the virtual
  servers that use the profile, and certificate paths to fill in. The suggested deployments are
  `enabled = no` until you review them. It never overwrites a file.

### Other
- New dependency on the host: `paste` (coreutils).
- **(config)** `sync = auto` is the default: a deployment to a unit in a sync-failover group now synchronises
  the group, and refuses to start if the group is not In Sync. Set `sync = no` to keep the old behaviour.
  Standalone units are unaffected.

## 2.1.2

Fixes for every finding of the third independent review (of 2.1.1; `F1`-`F5`, report summarised in `REVIEW.md`
section 7c). Each has a regression test in `tests/regress.sh` that fails against 2.1.1 and passes now.

- **Upload wrapper store (F2).** The `.push-pending` marker is now written like `FAILED`: a new private file
  renamed into place, so a link planted at that name is replaced, never followed (2.1.1 checked `.lock` but
  still wrote through `.push-pending`). And before using the store, the wrapper now checks **everything already
  in it**: each entry must be owned by root, not writable by group or others, a directory, a regular file with a
  single link, or a `NAME/current` link into `releases/`. Anything else (what another account could have left
  while the store was writable) makes the wrapper refuse to run and name the entry. **(config)** see below.
- **Unknown install outcome (F1).** When an install step never reports its outcome, its staging directory on the
  BIG-IP is now left in place (the install may still be reading it); 2.1.1 kept the lock but deleted the stage.
  The next run that stages on that BIG-IP removes staging directories older than two hours, as before.
- **Unknown pruning outcome (F3).** If pruning old backups or old certificate objects on the BIG-IP never reports
  its outcome, the deployment (already verified) is reported `CRITICAL` (exit 5) and the BIG-IP lock is kept,
  because the pruning may still be running; the object pruning is not started after an unknown backup pruning.
  In 2.1.1 this was only a warning, the run reported `UPDATED` and released the lock.
- **Reading the certificate files (F4).** Each configured file is opened once: the type check, the 1 MiB limit
  and the copy all apply to that one open file (2.1.1 measured the path, then opened it again to copy).
- **Refusal messages (F5)** from the upload wrapper's directory checks name the directory that is unsafe again
  (the name was lost in a subshell and printed blank).
- Tests: the regression suite's BIG-IP stand-in now also moves the tool's `/var/tmp` scratch paths, so the B4 case
  no longer depends on `/var/tmp` being writable.
- **(config)** An existing store that holds anything the wrapper did not make (for example files owned by
  another account, a group-writable directory, or an extra symlink) is now refused with the name of the entry.
  Stores set up as documented and only written by the wrapper are unaffected; so is repointing `NAME/current`
  by hand (`ln -sfn releases/TS NAME/current`, as root).

## 2.1.1

Fixes for every finding of the second independent review (of 2.1.0; `B1`-`B10`, report summarised in
`REVIEW.md` section 7b). Each has a regression test in `tests/regress.sh` built from the reviewer's own
demonstration, inverted to require the safe outcome; the reviewer's demonstrations no longer show any of them.

- **Tracked steps (B1, B2).** A step's reply now ends with `STEPEND|<step id>|<status>`, where the id is random
  per call and the line must be the last one: a step's own output, or a truncated reply, can no longer pass for
  it. Every step **claims** its id on the BIG-IP before it runs; when its reply is lost, the tool claims the id
  itself if the step has not, which cancels it for good. "The step did not run" is now a fact on the device,
  not an inference from two empty answers.
- **Lock serialisation (B3).** Every operation on the BIG-IP lock (take, take over, renew, release, the fence
  check and claim of a step, reading a step's result) runs under one kernel lock on the BIG-IP (`flock` on
  `/var/run/f5-cert-push.guard`). A take-over can no longer interleave with a renewal, and the lock path is never
  briefly empty. The rename-and-put-back take-over is gone.
- **Whole-bundle comparison (B4).** Backups, rollback verification and the fixed-name objects compare **every**
  certificate in a chain or fullchain, in order (read from the BIG-IP's stored file), not just the first; a
  backed-up bundle with any certificate that does not parse is refused.
- **Upload wrapper store (B5).** The store directory must not be writable by anyone else at all (a sticky
  world-writable store was accepted), and its `.lock` must be a regular file owned by the account running it;
  otherwise the wrapper refuses to run. (config: see below)
- **Upload copy (B6).** Each upload is opened once and the **opened** file is checked (through
  `/proc/self/fd`): same file as checked, regular, exactly one link. A swap for a hard link, a link or a FIFO
  between the check and the open is refused.
- **2.0.0 backup sets (B7).** A 2.0.0 restore script is only run if it is byte-for-byte what 2.0.0 generates for
  the contents it lists; an edited one is refused. (A genuine 2.0.0 set is in `tests/fixtures/` for this.)
- **Exit code after a signal (B8)** is the most severe result of the whole run, as without a signal; 130 only if
  nothing worse happened.
- **Unknown install outcome (B9).** An install step that never reported its outcome is `CRITICAL`, keeps the
  BIG-IP lock and deletes nothing (it was a plain failure that released the lock and removed objects the
  still-running install might be creating). Any removal whose outcome is unknown keeps the lock too.
- **Local lock (B10).** A local lock whose owner cannot be recorded is not taken; locks are only removed by the
  process recorded in them.
- New dependency: `cmp` (diffutils) on the host running the tool; `flock` on the BIG-IP (present on BIG-IP 17.1).
- **(config)** An upload-wrapper store (`--store`, default `/etc/f5-certs`) that is group- or world-writable is
  now refused. The documented `install -d -m 700` setup is unaffected.

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
