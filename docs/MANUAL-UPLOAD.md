# Manually uploaded certificates

> New install? Follow [SETUP.md](SETUP.md) first (server, SSH key, BIG-IP prerequisites).

Use this when certificates are **not** issued on the server by certbot, but bought or issued elsewhere and
**uploaded by a person** to a Linux server, which then pushes them to the BIG-IPs from cron (or on demand).

`f5-cert-install.sh` sits in front of `f5-cert-push.sh`:

```
 operator                     Linux server (cron, every 15 min)                              BIG-IPs
 --------                     ----------------------------------------------------------     -------
 uploads cert.pem    --->  /srv/f5-certs/incoming/www/   (ignored until READY exists)
         chain.pem
         privkey.pem
 then:   touch READY  --->  f5-cert-install.sh
                              copy privately, refuse symlinks
                              validate (key matches, chain verifies, not expiring,
                                        not older than what is installed)
                              /etc/f5-certs/www/releases/<time>/   (new release)
                              /etc/f5-certs/www/current  -> releases/<time>  (atomic switch)
                              shred the upload
                              f5-cert-push.sh --all   ------------------------------------>  profiles updated
                              (retried on later runs until it succeeds)
```

Why the extra step instead of pointing `f5-cert-push.sh` straight at the upload folder:

| Risk with manual uploads | How it is handled |
|---|---|
| Cron runs while files are half-uploaded | Nothing happens until the operator creates `READY`, which they do last |
| Only some files replaced (new cert, old key) | The key must match the certificate, or the upload is rejected |
| Chain forgotten, or the old chain left in place | `chain.pem` (or a fullchain containing it) is required and must verify against the certificate |
| The wrong file uploaded (an old certificate) | Rejected if it expires **before** the one already installed (override with `--allow-older`) |
| A certificate about to expire | Rejected if it expires within `--min-days` (default 7) |
| A symlink planted in the upload folder | Files are copied without following links and anything that is not a plain file is refused |
| Keys left lying around | The upload is shredded after a successful install; installed files are root-only (0600 in 0700 directories) |
| A failed push forgotten | A pending marker makes every later run retry the push until it succeeds |
| A rejected upload retried every 15 minutes | `READY` is removed and the reason written to `FAILED`; it waits for a person |

## 1. One-time setup (administrator)

Run as root on the Linux server.

```bash
# 1. The tools
install -d -m 755 /opt/f5-cert-push
install -m 750 f5-cert-push.sh f5-cert-install.sh /opt/f5-cert-push/

# 2. The configuration (see examples/manual-upload/f5-cert-push.conf)
install -m 600 examples/manual-upload/f5-cert-push.conf /etc/f5-cert-push.conf
$EDITOR /etc/f5-cert-push.conf

# 3. Where people upload: a group of uploaders, one folder per certificate.
groupadd certupload                                 # add the operators to this group
install -d -m 2770 -o root -g certupload /srv/f5-certs/incoming
install -d -m 2770 -o root -g certupload /srv/f5-certs/incoming/www
install -d -m 2770 -o root -g certupload /srv/f5-certs/incoming/api
# (one folder per [cert:NAME] in the config; the folder name IS the cert name)

# 4. Where certificates are installed: root only.
install -d -m 700 /etc/f5-certs

# 5. SSH to the BIG-IPs: a dedicated ECDSA key, authorised on each BIG-IP, host keys pinned.
#    See docs/OPERATIONS.md section 1.

# 6. Check, then schedule
/opt/f5-cert-push/f5-cert-push.sh --config /etc/f5-cert-push.conf --list
/opt/f5-cert-push/f5-cert-push.sh --config /etc/f5-cert-push.conf --all --check
install -m 644 examples/manual-upload/f5-cert-install.cron /etc/cron.d/f5-cert-install
```

Each `[cert:NAME]` in the config points at the installed copy:

```ini
[cert:www]
le_dir        = /etc/f5-certs/www/current
object_prefix = www-example
```

and is used by one or more `[deploy:]` sections that list the BIG-IPs and client-ssl profiles (see
[CONFIGURATION.md](CONFIGURATION.md)). Recommended `[defaults]` for uploaded certificates:

```ini
[defaults]
chain_check              = fail     # the chain must verify (needs OpenSSL 1.1.0+)
min_days_valid           = 7
auto_rollback            = yes
strict_host_key_checking = yes      # cron cannot approve a new host key
log_file                 = /var/log/f5-cert-push.log
```

**Upload access.** Give operators the narrowest access that works: an SFTP-only account in the `certupload`
group (for example `ForceCommand internal-sftp` and a `ChrootDirectory`) is better than a shell. They need
write access to their folders under `/srv/f5-certs/incoming/` and nothing else. They never need root, and
never need access to `/etc/f5-certs`.

## 2. Uploading a certificate (operator)

1. Copy the files into the certificate's folder, named exactly:

   | File | Content |
   |---|---|
   | `cert.pem` | the server certificate (leaf) only |
   | `chain.pem` | the intermediate certificate(s), PEM |
   | `privkey.pem` | the private key, PEM, **not** password-protected |

   Alternatives: `fullchain.pem` (leaf followed by intermediates) instead of `cert.pem` + `chain.pem`;
   or all of them. Other files are ignored.

   ```bash
   sftp upload@certserver
   sftp> cd incoming/www
   sftp> put www.example.com.crt cert.pem
   sftp> put intermediate.crt chain.pem
   sftp> put www.example.com.key privkey.pem
   ```

2. **Last**, create an empty file named `READY`:

   ```bash
   sftp> put /dev/null READY          # or: touch READY
   ```

3. Within 15 minutes it is installed and pushed. The folder is then empty. If it was rejected, the folder
   still holds your files plus a `FAILED` file that says why; fix the problem and create `READY` again.

To see what is installed and what is waiting:

```bash
sudo /opt/f5-cert-push/f5-cert-install.sh --status
```

```
Installed certificates in /etc/f5-certs:
  www     expires Dec 29 23:20:06 2026 GMT  sha256 6EA59495D7A191EC...  release 20260930-224211
  api     expires Mar  3 12:00:00 2027 GMT  sha256 1F03FA098E2A4ADD...  release 20260901-080000

Upload folders in /srv/f5-certs/incoming:
  www: READY (will be installed on the next run)
  api: FAILED - the private key does not match the certificate
```

### Common rejections

| `FAILED` says | Fix |
|---|---|
| the private key does not match the certificate | The key is from a different request. Upload the key that goes with this certificate. |
| no intermediate certificates | Upload `chain.pem` (from your CA's download), or a `fullchain.pem`. |
| does not verify against the supplied chain | The chain is the wrong one (often an old intermediate). Download the current chain from the CA. |
| passphrase-protected | Remove the passphrase: `openssl pkey -in key.pem -out privkey.pem` (do this on a trusted machine). |
| expires ... BEFORE the installed one | You uploaded an older certificate. If that is intended, an administrator runs with `--allow-older`. |
| min_days_valid | The certificate expires too soon to deploy. |
| is not a regular file (symbolic links are refused) | Upload the file itself, not a link. |

## 3. Running it by hand

```bash
# validate what is waiting, change nothing
sudo /opt/f5-cert-push/f5-cert-install.sh --dry-run
# install what is waiting and push now
sudo /opt/f5-cert-push/f5-cert-install.sh
# push only the 'prod' deployments
sudo /opt/f5-cert-push/f5-cert-install.sh --env prod
# check every BIG-IP without changing anything
sudo /opt/f5-cert-push/f5-cert-push.sh --config /etc/f5-cert-push.conf --all --check
```

Both scripts lock: a manual run and a cron run cannot overlap (the second exits 6).

## 4. Options

| Option | Default | |
|---|---|---|
| `--config FILE` | `/etc/f5-cert-push.conf` | f5-cert-push configuration |
| `--incoming DIR` | `/srv/f5-certs/incoming` | upload folders |
| `--store DIR` | `/etc/f5-certs` | installed certificates |
| `--push-bin FILE` | next to the script | `f5-cert-push.sh` |
| `--env LABEL` | (push `--all`) | push only deployments with this `env`; repeatable |
| `--push-when changed\|always` | `changed` | `changed`: push only after an install, or to retry a push that has not succeeded. `always`: push every run (also catches drift, but logs in to every BIG-IP every run) |
| `--no-push` | | install only |
| `--keep-releases N` | 3 | installed releases kept per certificate |
| `--min-days N` | 7 | refuse a certificate expiring within N days |
| `--allow-older` | | accept a certificate that expires before the installed one |
| `--allow-no-chain` | | accept a certificate with no intermediates |
| `--dry-run` | | validate and report only |
| `--status` | | show installed certificates and upload folders |
| `--quiet` | | print only changes, warnings and errors (for cron) |

Exit codes: 0 ok; 1 an upload was rejected or a push failed; 2 usage error; 6 another run is in progress;
3, 4 and 5 are passed through from `f5-cert-push.sh` (3 = a push was rolled back, 5 = a rollback failed).

## 5. Going back to a previous certificate

**On the BIG-IPs** (what clients see), use the backups f5-cert-push keeps for every push:

```bash
f5-cert-push.sh --config /etc/f5-cert-push.conf --deploy www --list-backups
f5-cert-push.sh --config /etc/f5-cert-push.conf --deploy www --rollback --set 20260930-224211
```

**On the server** (so cron does not push the new one again), point `current` back at an older release, or
upload the previous files again with `--allow-older`:

```bash
ls /etc/f5-certs/www/releases/
ln -sfn releases/20260901-080000 /etc/f5-certs/www/current
```

Do both, or the next push will deploy whatever `current` points at.

## 6. What it does not do

- It does not issue or renew certificates; it installs what people upload.
- It does not convert formats (PKCS#12/PFX, DER). Convert to PEM before uploading:
  `openssl pkcs12 -in site.pfx -nokeys -clcerts -out cert.pem` etc.
- One folder holds one certificate. A certificate used by many profiles or BIG-IPs is still one upload;
  the `[deploy:]` sections fan it out.
