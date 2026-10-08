# Setup guide: Linux server and BIG-IP

This is the one-time build-out for the manual-upload workflow: a Linux server that people upload certificates
to, which pushes them to one or more BIG-IPs from cron. Follow it top to bottom, once per server and once per
BIG-IP. Day-to-day use is in [MANUAL-UPLOAD.md](MANUAL-UPLOAD.md); the settings are in
[CONFIGURATION.md](CONFIGURATION.md); SSH troubleshooting is in [OPERATIONS.md](OPERATIONS.md) section 1.

1. [What you are building](#1-what-you-are-building)
2. [Requirements](#2-requirements)
3. [Where files live](#3-where-files-live)
4. [Linux server setup](#4-linux-server-setup)
5. [SSH key and trust](#5-ssh-key-and-trust)
6. [BIG-IP setup](#6-big-ip-setup)
7. [Configuration file](#7-configuration-file)
8. [First run: prove it, then schedule it](#8-first-run-prove-it-then-schedule-it)
9. [Checklist](#9-checklist)

---

## 1. What you are building

```
 people (SFTP)                Linux server                                   BIG-IP(s)
 -------------     /srv/f5-certs/incoming/<cert>/   (staging, uploaders write here)
   cert.pem  ---->            |  cron every 15 min: f5-cert-install.sh
   chain.pem                  v
   privkey.pem       /etc/f5-certs/<cert>/current   (installed copy, root only)
   READY (last)               |  f5-cert-push.sh  --- SSH (TCP 22, key) --->  tmsh: install new
                              |                                               versioned objects,
                              +--> /var/backups/f5-cert-push  (local backup)  switch the profiles,
                                                                              backup in /shared
```

Two machines, one network path: the Linux server opens SSH to each BIG-IP's management address. Nothing on the
BIG-IP connects back, and the BIG-IP needs no agent or add-on.

## 2. Requirements

**Linux server**

| Need | Notes |
|---|---|
| bash 4.2 or newer | Any current distribution. |
| OpenSSL, OpenSSH client | OpenSSL **1.1.0 or newer** to verify the chain (`chain_check = fail` needs it). |
| `flock`, `dd`, `shred`, `sha256sum`, `timeout`, standard coreutils | Normally present. |
| cron (or a systemd timer) | To run the installer. |
| root access for the admin | Installing the tools, the config and the cron job. |
| Network | TCP 22 from this server to every BIG-IP's **management** address. |

**BIG-IP**

| Need | Notes |
|---|---|
| Tested on 17.1.3.4 | Other versions are untested. |
| Root SSH login with a **key** | `root` is what the tool is tested with. See section 6.1. |
| Existing **client-ssl profile(s)** | The tool updates profiles; it does not create them. Section 6.2. |
| Free space in `/shared` | Backups of old certificates are kept there. |
| Active, config-loaded device | The tool refuses a standby or not-loaded unit. For a pair, target the **active** unit and sync (section 6.4). |

## 3. Where files live

| Purpose | Path | Owner / mode | Who writes it |
|---|---|---|---|
| Tool scripts | `/opt/f5-cert-push/f5-cert-push.sh`, `f5-cert-install.sh` | root, 750 | admin |
| Configuration | `/etc/f5-cert-push.conf` | root, **600** | admin |
| **Staging: uploads land here** | `/srv/f5-certs/incoming/<cert>/` (in `incoming`, root:certupload 0750) | root:certupload, **3770** (sticky) | operators (SFTP) |
| **Installed certificates** | `/etc/f5-certs/<cert>/releases/<UTC time>/` and `.../current` | root, 700 / files 600 | installer |
| Tool's own SSH key | `/root/.ssh/f5_push_ecdsa` (+ `.pub`) | root, 600 | admin |
| Pinned BIG-IP host keys | `/root/.ssh/known_hosts` | root, 600 | admin |
| Local backups | `/var/backups/f5-cert-push/` | root, 700 | tool |
| Log | `/var/log/f5-cert-push.log` | root | tool |
| Cron job | `/etc/cron.d/f5-cert-install` | root, 644 | admin |
| Locks and scratch | `/var/lock` / private tmpfs | root | tool (removed on exit) |
| On each BIG-IP: new objects | the BIG-IP's certificate/key store, named like `<prefix>-cert-<UTC time>.pem`, `-chain-`, `-privkey-` | | tool |
| On each BIG-IP: backups | `/shared/cert-backups/<prefix>/` (default; last `keep` sets) | root, 700 | tool |

### Staging: one folder per certificate, three files in it

Staging is **one folder per certificate**, and the folder name is the certificate name used in the config
(`[cert:www]` reads `/srv/f5-certs/incoming/www/`). Inside each folder the operator puts the pieces under
fixed names:

```
/srv/f5-certs/incoming/www/
    cert.pem        the server (leaf) certificate only
    chain.pem       the intermediate certificate(s)
    privkey.pem     the private key, not password-protected
    READY           empty file, created LAST
```

You do not need separate places for the cert, key and chain. They go together in one folder so that a renewal
is always replaced as a set. (A `fullchain.pem` may be uploaded instead of `cert.pem` + `chain.pem`.) If the
customer has many certificates, make many folders, one per `[cert:NAME]`.

Do not point `le_dir` at the staging folder. `le_dir` points at the **installed** copy
(`/etc/f5-certs/<cert>/current`), which only the installer changes and which only root can read.

Keep staging and the installed store on the **same filesystem** if you can: it is not required, but the
installer then never has to copy a key across devices.

## 4. Linux server setup

Run as root.

### 4.1 Install the tools

```bash
tar xzf f5-cert-push-2.2.0.tar.gz && cd f5-cert-push
install -d -m 755 /opt/f5-cert-push
install -m 750 f5-cert-push.sh f5-cert-install.sh /opt/f5-cert-push/
sha256sum -c SHA256SUMS 2>/dev/null | grep -E 'f5-cert-(push|install)\.sh'   # optional: verify the copy
```

### 4.2 Create the directories

```bash
# Installed store (root only) and local backups
install -d -m 700 /etc/f5-certs
install -d -m 700 /var/backups/f5-cert-push

# Staging: a group for the people who upload, one folder per certificate.
groupadd certupload
install -d -m 0755 -o root -g root       /srv/f5-certs
install -d -m 0750 -o root -g certupload /srv/f5-certs/incoming
for c in www api; do                                   # one per [cert:NAME] in the config
    install -d -m 3770 -o root -g certupload /srv/f5-certs/incoming/$c
done
```

- `incoming` (0750, root:certupload): uploaders can enter it but cannot create, rename or remove anything in it.
- each upload folder (**3770**, root:certupload): members of the group can create files in it (setgid keeps new
  files in the group), and the **sticky bit** stops them renaming or removing anything they did not create:
  the folder itself, and the `FAILED` file root writes. Everyone else has no access.

The installer checks this before it does anything: it refuses to run unless every directory from `/` down to
`incoming` can only be changed by root, and it skips (with a warning) an upload folder that is not owned by
root or that is group-writable without the sticky bit. These checks are what make it safe for root to work
in folders other people write to.

Keep `fs.protected_hardlinks = 1` (the default on current distributions): with it, an uploader cannot hard-link
a file they do not own (the installer also refuses any upload file with more than one link). Check with
`sysctl fs.protected_hardlinks`.

Uploaded files are deleted after a successful install, not overwritten (overwriting would mean root writing
through a path the uploader controls). If the uploaded key must not linger on disk, mount `/srv/f5-certs` on
tmpfs or an encrypted filesystem.

### 4.3 Create the upload account(s)

Operators need to put files in their folders and nothing else. Prefer an SFTP-only account over a shell:

```bash
useradd -m -s /usr/sbin/nologin -G certupload certop        # one per person is better than a shared account
passwd -l certop                                            # key login only
install -d -m 700 -o certop -g certop /home/certop/.ssh
# put the operator's public key in /home/certop/.ssh/authorized_keys (owner certop, mode 600)
```

In `/etc/ssh/sshd_config` (then `systemctl reload sshd`), confine the group to SFTP and to the staging tree:

```
Match Group certupload
    ChrootDirectory /srv/f5-certs
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication no
```

A chroot requires `/srv/f5-certs` itself to be owned by root and not writable by anyone else (`chown root:root
/srv/f5-certs; chmod 755 /srv/f5-certs`), which is what the layout above gives. The operator then sees
`/incoming/www/`. Note that operators log in with a **different** SSH key from the tool's key in section 5.

If you do not use SFTP-only accounts, any other upload method works as long as it ends with the three files in
the right folder and `READY` created last, by a user in `certupload`.

### 4.4 Time, logging and mail

- **Time** must be correct (NTP). Certificate validity checks and the UTC-timestamped object names depend on it.
- **Log rotation**: add `/etc/logrotate.d/f5-cert-push` for `/var/log/f5-cert-push.log` (weekly, rotate 8,
  compress, `create 600 root root`).
- **Mail**: cron mails any output. Because the installer prints only changes, warnings and errors under
  `--quiet`, set `MAILTO=` in the cron file (section 8.4) to a mailbox someone reads, and confirm the server
  can send mail.

## 5. SSH key and trust

The tool logs in to each BIG-IP as root with a key that is used for nothing else.

### 5.1 Create the key (on the Linux server, as root)

```bash
ssh-keygen -t ecdsa -b 384 -N '' -C 'f5-cert-push' -f /root/.ssh/f5_push_ecdsa
chmod 600 /root/.ssh/f5_push_ecdsa
cat /root/.ssh/f5_push_ecdsa.pub        # one line: ecdsa-sha2-nistp384 AAAA... f5-cert-push
```

**Use ECDSA (or RSA), not ed25519.** A BIG-IP's SSH daemon commonly accepts only ECDSA and RSA keys and
silently ignores an ed25519 key. One key can be authorised on every BIG-IP, or create one per BIG-IP if the
customer wants to revoke them separately; the config names the key per `[f5:]` section.

A key without a passphrase is root on the BIG-IP: protect the file (mode 600, root only, a trusted host), and
back it up the way you back up other secrets. If policy requires a passphrase, load the key into an
`ssh-agent` for the cron user and leave `ssh_key` out of the config; unattended cron runs are then harder.

### 5.2 Authorise the key on each BIG-IP

On the BIG-IP, as root (console, or an existing admin session, for example `bash` from tmsh):

```bash
echo 'ecdsa-sha2-nistp384 AAAA...paste the whole .pub line... f5-cert-push' >> /var/ssh/root/authorized_keys
chmod 600 /var/ssh/root/authorized_keys
restorecon -v /var/ssh/root/authorized_keys
```

Three BIG-IP details that cause "Permission denied" with no useful log line:

1. `/root/.ssh/authorized_keys` is a **symlink** to `/var/ssh/root/authorized_keys`. Append to the target.
2. The file must carry the SELinux label `ssh_home_t`. A wrong label makes sshd ignore every key silently.
   `restorecon` fixes it.
3. `PubkeyAcceptedKeyTypes` in `/config/ssh/sshd_config` may exclude your key type. A license reload can
   re-apply hardening, so a key that worked can stop working afterwards.

Also confirm root SSH login is permitted at all: **System > Platform > SSH** and, in the sshd configuration,
`PermitRootLogin` (the default `prohibit-password` is fine for key login). If the BIG-IP restricts SSH by
source address (**System > Platform > SSH IP Allow**), add the Linux server's address.

### 5.3 Pin each BIG-IP's host key

The recommended configuration is `strict_host_key_checking = yes`: cron cannot answer "trust this host?", and
you do not want it to trust a stranger. Fetch and verify the host key once, from the Linux server:

```bash
ssh-keyscan -t ecdsa 10.0.0.11 >> /root/.ssh/known_hosts
ssh-keygen -lf <(ssh-keyscan -t ecdsa 10.0.0.11 2>/dev/null)      # fingerprint seen from the network
# on the BIG-IP, compare with:   ssh-keygen -lf /config/ssh/ssh_host_ecdsa_key.pub
```

The two fingerprints must match before you keep the entry. Repeat for every BIG-IP address in the config. If a
BIG-IP is rebuilt or replaced its host key changes and the tool will (correctly) refuse until you update
`known_hosts`.

### 5.4 Test the login exactly as the tool makes it

```bash
ssh -i /root/.ssh/f5_push_ecdsa -o IdentitiesOnly=yes root@10.0.0.11 'tmsh show sys version | head -5'
```

You should get the version with no prompt. If it fails, run `ssh -vvv` and see
[OPERATIONS.md](OPERATIONS.md) section 8, or on the BIG-IP `tail /var/log/secure`.

## 6. BIG-IP setup

Do these on each BIG-IP (or on the active unit of a pair).

### 6.1 Access

Sections 5.2 and 5.3 above. Management reachability: from the Linux server,
`nc -zv 10.0.0.11 22` must succeed. Firewalls between the server and the BIG-IP's management interface must
allow TCP 22 from the server.

### 6.2 The client-ssl profile(s) must already exist

The tool changes the certificate, chain and key **inside existing client-ssl profiles**. Create each one first
(**Local Traffic > Profiles > SSL > Client**, or `tmsh create ltm profile client-ssl ...`) and attach it to its
virtual server. The profile must:

- have its **own** certificate/key/chain entry, not inherit one from a parent profile
  (`inherit-certkeychain` must be `false`);
- use a key **without a passphrase** (the tool refuses a passphrase-protected entry);
- be in a partition you can name (`partition` in the `[f5:]` section, default `Common`).

For the first deployment, give the profile a working placeholder certificate (a self-signed one is fine).
The tool replaces it with the first uploaded certificate and keeps the entry name.

If a profile holds both an RSA and an ECDSA entry, name the entry in the config
(`profile = site-clientssl:rsa_entry`); see [CONFIGURATION.md](CONFIGURATION.md), "Profiles and entries".

List what exists and what the tool sees:

```bash
/opt/f5-cert-push/f5-cert-push.sh --config /etc/f5-cert-push.conf --discover --f5 dc1-a
```

(Run it after the configuration exists, section 7.)

### 6.3 Objects the tool creates (nothing to prepare)

You do **not** pre-create certificates or keys. On each deployment the tool imports new, versioned objects:

```
<prefix>-cert-<UTC time>.pem   <prefix>-chain-<UTC time>.pem   <prefix>-privkey-<UTC time>.pem
```

switches the profiles to them in one all-or-nothing transaction, saves the configuration, and prunes versions
older than `keep` (never one that is in use; BIG-IP refuses to delete in-use objects). The previous set stays
on the device until pruned, so a rollback is instant.

Backups of the objects being replaced go to `/shared/cert-backups/<prefix>/` on the BIG-IP and to
`backup_dir_local` on the Linux server, each with a checksum and a generated restore script.
`/shared` is the large volume; make sure it has space (a few KB per set).

### 6.4 Pairs, partitions, sync

- **Pair (active/standby):** define both units as `[f5:]` sections and list both in each deployment. The tool
  deploys to the active one, runs config-sync, confirms both units loaded it, and checks the standby. The pair
  must be **In Sync** before a run. Authorise the SSH key on **both** units: `authorized_keys` is not synchronised.
  (`sync = no` if you prefer to sync yourself; then list only the active unit.)
- **Partitions:** set `partition = Name` in `[f5:]`, or write profiles as `/Part/profile`. The objects are
  created in the same partition as the profile.
- **Config not loaded / unit offline / standby:** the tool stops with a clear error. Fix the device first.

### 6.5 Check before you rely on it

```bash
# from the Linux server
ssh -i /root/.ssh/f5_push_ecdsa root@10.0.0.11 \
  'tmsh list ltm profile client-ssl www-clientssl cert-key-chain; df -h /shared | tail -1'
```

Expect an entry with a cert, key and chain, and free space on `/shared`.

## 7. Configuration file

Start from the manual-upload example:

```bash
install -m 600 /dev/null /etc/f5-cert-push.conf          # root-only before it has content
cat examples/manual-upload/f5-cert-push.conf > /etc/f5-cert-push.conf
$EDITOR /etc/f5-cert-push.conf
```

For each BIG-IP add an `[f5:NAME]` section (address, key), for each certificate a `[cert:NAME]` section whose
`le_dir = /etc/f5-certs/NAME/current`, and for each set of profiles a `[deploy:NAME]` section. The tool refuses
a configuration file that others can write.

Every `[cert:NAME]` must have a matching upload folder `/srv/f5-certs/incoming/NAME/`. A deploy can list many
BIG-IPs and many profiles. `env = prod` / `env = test` labels let you push one environment (`--env`).

## 8. First run: prove it, then schedule it

### 8.1 Validate the configuration (no network)

```bash
/opt/f5-cert-push/f5-cert-push.sh --config /etc/f5-cert-push.conf --list
```

This prints every BIG-IP, certificate and deployment it understood. Fix anything it rejects.

> `--validate` checks the certificate files as well, so it needs a certificate already installed under
> `/etc/f5-certs/<cert>/current`. On a brand-new server there is none yet; use `--list` first and `--validate`
> after the first upload.

### 8.2 Prove it can reach and read each BIG-IP (read-only)

```bash
/opt/f5-cert-push/f5-cert-push.sh --config /etc/f5-cert-push.conf --discover --f5 dc1-a
/opt/f5-cert-push/f5-cert-install.sh --status
```

Nothing is changed. If this works, SSH, the key, the pinned host key and `tmsh` access are all good.

### 8.3 Do one real upload by hand, in a test environment

1. As an operator, upload a certificate to a folder whose deployment is `env = test`, then create `READY`.
2. Rehearse: `sudo /opt/f5-cert-push/f5-cert-install.sh --dry-run` (validates, changes nothing).
3. Do it: `sudo /opt/f5-cert-push/f5-cert-install.sh --env test`.
4. Confirm from outside:

   ```bash
   echo | openssl s_client -connect VIP:443 -servername www.example.com 2>/dev/null \
     | openssl x509 -noout -subject -enddate -fingerprint -sha256
   ```

5. Confirm the folder is empty, the backup exists on the BIG-IP (`ls /shared/cert-backups/<prefix>/`) and locally
   (`ls /var/backups/f5-cert-push/`), and that `--status` shows the new release.
6. Practise a rollback (section 5 of [MANUAL-UPLOAD.md](MANUAL-UPLOAD.md)) before you need one.

### 8.4 Schedule it

```bash
install -m 644 examples/manual-upload/f5-cert-install.cron /etc/cron.d/f5-cert-install
$EDITOR /etc/cron.d/f5-cert-install          # set MAILTO, paths and the interval
```

A cron file in `/etc/cron.d` needs the user field (`root`) and must not be writable by others. The shipped file
runs the installer every 15 minutes with `--quiet`, plus an optional daily `--check` of every BIG-IP to catch
drift (a profile changed by hand). Confirm that cron ran it: `grep f5-cert /var/log/cron` (or
`journalctl -u cron`), and the log `/var/log/f5-cert-push.log`.

## 9. Checklist

**Linux server**

- [ ] Scripts in `/opt/f5-cert-push/`, mode 750, owned by root
- [ ] `/etc/f5-cert-push.conf` mode 600, `--list` accepts it
- [ ] `/srv/f5-certs/incoming` is root:certupload 0750; `/srv/f5-certs/incoming/<cert>/` exists for every `[cert:]`, owned by root, group `certupload`, mode 3770 (sticky)
- [ ] `/etc/f5-certs` and `/var/backups/f5-cert-push` exist, mode 700
- [ ] Upload accounts are SFTP-only, key login, members of `certupload`; they have no access outside staging
- [ ] `fs.protected_hardlinks = 1`; clock synchronised
- [ ] Log rotation and `MAILTO` configured
- [ ] Cron file installed

**SSH**

- [ ] ECDSA (or RSA) key at `/root/.ssh/f5_push_ecdsa`, mode 600, used for nothing else
- [ ] Public key in `/var/ssh/root/authorized_keys` on every BIG-IP, mode 600, `restorecon` run
- [ ] Every BIG-IP host key pinned in `known_hosts` after comparing fingerprints
- [ ] The test login in 5.4 works with no prompt, from this server, for every BIG-IP

**Every BIG-IP**

- [ ] Client-ssl profile exists, attached to a virtual server, owns its cert/key/chain, key has no passphrase
- [ ] Device is active and its configuration is loaded
- [ ] `/shared` has free space
- [ ] SSH allowed from the Linux server (network and the BIG-IP's SSH allow list)

**Proof**

- [ ] `--discover` lists the profiles; `--status` runs
- [ ] One test upload was installed, served correctly and rolled back successfully
