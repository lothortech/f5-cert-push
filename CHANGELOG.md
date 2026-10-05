# Changelog

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
