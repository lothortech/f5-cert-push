# f5-cert-push

Deploy renewed TLS certificates to one or many **F5 BIG-IP** devices, safely and repeatably.

You describe your BIG-IPs, certificates and deployments once in a configuration file. For each
deployment the tool then:

1. **Validates** the certificate, key and chain locally (they match, not expired, chain verifies).
2. **Reads** the BIG-IP and refuses to touch one whose configuration is not loaded or which is standby.
3. **Backs up** what is there, to the BIG-IP (`/shared`) **and** to the machine running the tool, with
   SHA-256 checksums, and writes a self-verifying **restore script**.
4. **Uploads** the new files to a private staging directory and checks their checksums on the BIG-IP.
5. **Installs** them as new, timestamped objects (the old ones stay untouched).
6. **Switches** every named client-ssl profile to the new objects in **one atomic tmsh transaction**
   (all profiles change together, or none do), then saves the configuration.
7. **Verifies** the result: the profiles reference the new objects, and (optionally) your virtual
   servers really serve the new certificate.
8. **Rolls back automatically** if verification fails, and **verifies the rollback** on the device; a
   state it cannot confirm is reported `CRITICAL`, never as success. A dropped connection, a timeout or a
   Ctrl-C in the middle of a change is recovered the same way.
9. **Prunes** old backups and old certificate versions down to the number you choose.
10. **Reports** a summary, and returns an exit code that automation can act on.

It is a single Bash script plus a configuration file (and an optional wrapper, `f5-cert-install.sh`, for
certificates that people upload by hand). Nothing is installed on the BIG-IP.

```
   your host                                          BIG-IP
  +------------+    ssh (key only)    +-----------------------------------------+
  | f5-cert-   |--------------------->|  /shared/cert-backups/<prefix>/<time>/  |
  | push.sh    |   read state         |  /var/tmp/f5-cert-push.XXXX (staging)   |
  |            |   backup, upload     |  new objects  <prefix>-cert-<time>.pem  |
  | conf file  |   install, switch    |  client-ssl profiles  -> new objects    |
  |            |   verify, rollback   |                                         |
  +------------+                      +-----------------------------------------+
   backups/<bigip>/<prefix>/<time>/
```

## Requirements

| On the machine that runs the tool | |
|---|---|
| OS | Linux |
| Shell | bash 4.2 or newer |
| Tools | `ssh`, `openssl`, GNU `date` / `stat` / `sort` / `timeout`, `awk`, `sed`, `grep`, `sha256sum`, `find`, `mktemp`. **OpenSSL 1.1.0 or newer is recommended**: older versions cannot verify a chain reliably, so the chain check is skipped with a warning (see `chain_check`). Everything else works on 1.0.x. |
| Access | read access to the certificate and key files; an SSH private key trusted by the BIG-IP |

| On the BIG-IP | |
|---|---|
| Version | Developed and tested against **BIG-IP 17.1.3.4**. The `cert-key-chain` syntax it relies on exists from 11.5, but other versions are untested. |
| Account | SSH key login as **root**. The tool needs `tmsh` and read access to `/config/filestore` (to back up the old files). |
| Key types | The BIG-IP's SSH daemon may be restricted (for example FIPS mode accepts only **ECDSA and RSA** keys, not ed25519). Use an ECDSA P-384 key. See [OPERATIONS.md](docs/OPERATIONS.md#1-first-time-setup). |

## Quick start

```bash
# 1. Put the script and the example config somewhere, restrict the config
cp f5-cert-push.conf.example /etc/f5-cert-push.conf
chmod 600 /etc/f5-cert-push.conf
$EDITOR /etc/f5-cert-push.conf                      # describe your BIG-IPs, certs, deployments

# 2. Check the file and the certificate files (no network)
./f5-cert-push.sh --validate

# 3. See which client-ssl profiles exist on a BIG-IP (to fill in 'profile =')
./f5-cert-push.sh --discover --f5 prod-a

# 4. Is anything out of date? (read-only; exit 4 means yes)
./f5-cert-push.sh --env prod --check

# 5. Rehearse, then do it
./f5-cert-push.sh --deploy prod-www --dry-run
./f5-cert-push.sh --deploy prod-www
```

A minimal configuration that updates one profile on one BIG-IP with a Let's Encrypt certificate:

```ini
[f5:prod-a]
host    = 10.0.0.11
ssh_key = /root/.ssh/f5_push_ecdsa

[cert:wildcard]
le_dir        = /etc/letsencrypt/live/example.com
object_prefix = example-wildcard

[deploy:www]
f5      = prod-a
cert    = wildcard
profile = www-clientssl
verify  = 10.1.10.10:443 www.example.com
```

The full, commented example is [`f5-cert-push.conf.example`](f5-cert-push.conf.example); every setting is
documented in [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Choosing what to run

You must say what to act on; there is no "run everything" by accident.

| Flag | Acts on |
|---|---|
| `--deploy NAME` | one `[deploy:NAME]` (repeatable) |
| `--env LABEL` | every deployment with `env = LABEL` (repeatable) |
| `--f5 NAME` | narrows the above to one BIG-IP (repeatable) |
| `--lineage DIR` | deployments whose certificate is `le_dir = DIR`; meant for certbot hooks |
| `--all` | every enabled deployment |

## Actions

| Flag | What it does |
|---|---|
| *(none)* | deploy |
| `--check` | read-only; report whether each BIG-IP is current. **Exit 4** if any is out of date. |
| `--dry-run` | print exactly what a deploy would do; change nothing |
| `--validate` | check the config file and the local certificate files |
| `--list` | show the deployments the config defines |
| `--discover --f5 NAME` | list every client-ssl profile and entry on a BIG-IP, with expiry dates |
| `--list-backups` | list the backup sets for the selected deployments |
| `--rollback --set TS` | restore the state captured just before run `TS` |

Other options: `--force` (redeploy even if current), `--fail-fast` (stop at the first failure),
`--quiet`, `--config FILE`, `--version`, `--help`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, or nothing to do |
| 1 | Error. Normally the BIG-IP was **not** changed. The one exception is `auto_rollback = no` after a failed check: the summary then says `FAILED_CHANGED` and prints the rollback command |
| 2 | Usage or configuration error. Nothing was done |
| 3 | A deployment failed **after** changing the BIG-IP and was **rolled back** (verified) |
| 4 | `--check` found a BIG-IP that is out of date |
| 5 | **CRITICAL:** the BIG-IP's state could not be confirmed (the rollback failed or could not be verified, or a step never reported its outcome). The BIG-IP needs attention; its lock is left in place |
| 6 | Another run (on this host or another) already holds the lock for that BIG-IP |

With several deployments in one run the exit code is the most severe result: 5, then 3, then 1, 6, 4.
A run stopped by a signal exits 130 unless a deployment had something worse to report.

## Manually uploaded certificates

If certificates are bought or issued elsewhere and **uploaded by a person** to the server, use
`f5-cert-install.sh` from cron. Operators drop `cert.pem`, `chain.pem` and `privkey.pem` into
`incoming/<certname>/` and create `READY` last; the wrapper validates the upload (key matches, chain
verifies, not expiring, not older than what is installed, no symlinks or hard links), installs it atomically
and pushes it, retrying the push until it succeeds. The upload folders must be root-owned and sticky (mode
`3770`); the wrapper checks that, because it runs as root in folders other people write to. See [docs/MANUAL-UPLOAD.md](docs/MANUAL-UPLOAD.md) and
[`examples/manual-upload/`](examples/manual-upload/).

## Automating renewals

Run it from certbot after each renewal; it does nothing if the BIG-IP already has the certificate:

```bash
# /etc/letsencrypt/renewal-hooks/deploy/f5-cert-push.sh
#!/usr/bin/env bash
exec /opt/f5-cert-push/f5-cert-push.sh --config /etc/f5-cert-push.conf \
     --lineage "$RENEWED_LINEAGE" --quiet
```

Or monitor drift from cron or your monitoring system: `f5-cert-push.sh --all --check --quiet`
exits 4 when anything is out of date. See [docs/OPERATIONS.md](docs/OPERATIONS.md).

## What it creates

| Where | What |
|---|---|
| BIG-IP objects | `<prefix>-cert-<time>.pem`, `<prefix>-chain-<time>.pem`, `<prefix>-privkey-<time>.pem` per deploy; the newest `keep` sets are retained |
| BIG-IP files | `/shared/cert-backups/<prefix>/<time>/` (old PEMs, `restore-<time>.sh`, `INVENTORY`, `MANIFEST`, and `SHA256SUMS` covering all of them) |
| Local files | `<backup_dir_local>/<bigip>/<prefix>/<time>/` (a verified copy of the same) |
| Temporary | a private scratch directory here (tmpfs when available), and `/var/tmp/f5-cert-push.XXXX` on the BIG-IP; both removed on exit, including on Ctrl-C |

**Backups contain private keys.** Protect `backup_dir_local` accordingly; the tool creates it mode 0700.

## Documentation

| | |
|---|---|
| [docs/USER-GUIDE.md](docs/USER-GUIDE.md) | **For the person running it by hand**: SSH key, saving the certificate files, a small configuration, the renewal routine, rollback |
| [docs/SETUP.md](docs/SETUP.md) | **Start here for a new install**: Linux server, staging folders, SSH key, BIG-IP prerequisites, first run, checklist |
| [docs/MANUAL-UPLOAD.md](docs/MANUAL-UPLOAD.md) | Certificates uploaded by people: `f5-cert-install.sh`, setup, operator procedure, cron |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Every setting, with defaults and examples; how profiles and entries are chosen |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | First-time setup, day-to-day use, rollback, HA pairs, monitoring, troubleshooting |
| [docs/SECURITY.md](docs/SECURITY.md) | Threat model, what the tool protects and does not, hardening checklist |
| [docs/TESTING.md](docs/TESTING.md) | The offline, regression and BIG-IP test suites, and what they do not cover |
| [REVIEW.md](REVIEW.md) | Brief for an independent security and correctness review, and the findings of the first one with their fixes |
| [CHANGELOG.md](CHANGELOG.md) | Version history |

## Known limitations

Short list; the full one is in [docs/OPERATIONS.md](docs/OPERATIONS.md#known-limitations).

- **client-ssl profiles only.** server-ssl profiles and other consumers of certificates are not updated.
- **Passphrase-protected private keys are not supported** (the tool refuses them with an explanation).
- **It does not synchronise an HA pair.** Deploy to the active unit, then sync. It refuses a standby unit.
- Profiles that **inherit** their certificate from a parent (`inherit-certkeychain true`) are refused; update the parent.
- Developed and tested on BIG-IP **17.1.3.4**, standalone. Standby/HA behaviour, and the "configuration not
  loaded" safety gate, are implemented but could not be exercised on the test device.

## Reading the documentation in a browser

Open `html/index.html` (double-click it). Every guide is also there as a single self-contained page with a
side menu, copy buttons on the command blocks, dark-mode and print support, and no network access needed.
After editing a Markdown file, regenerate with `pip install markdown && python tools/build-html.py`.

## License

MIT. See [LICENSE](LICENSE). The tool changes production load balancers: test it on a lab device first.
