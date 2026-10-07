# User guide: updating certificates by hand

For the person who runs the tool **manually** from their own Linux machine (or Windows with WSL) when a
certificate is renewed. Nothing here runs by itself: you start it, you read what it is going to do, you
confirm the result. For an unattended, cron-based setup see [SETUP.md](SETUP.md) and
[MANUAL-UPLOAD.md](MANUAL-UPLOAD.md).

1. [What you need](#1-what-you-need)
2. [One-time setup](#2-one-time-setup)
3. [Create the SSH key](#3-create-the-ssh-key)
4. [Authorise the key on each BIG-IP](#4-authorise-the-key-on-each-big-ip)
5. [Save the certificate files](#5-save-the-certificate-files)
6. [Write the configuration](#6-write-the-configuration)
7. [Renewing a certificate: the routine](#7-renewing-a-certificate-the-routine)
8. [If something is wrong: rolling back](#8-if-something-is-wrong-rolling-back)
9. [High-availability pairs](#9-high-availability-pairs)
10. [Quick reference](#10-quick-reference)

---

## 1. What you need

| Need | Notes |
|---|---|
| A Linux machine, or Windows 10/11 with **WSL** (Ubuntu) | The script is a bash script and was tested on Linux. macOS ships an old bash (3.2) that is too old; install a current one with Homebrew and treat it as untested. Plain Windows without WSL is not supported. |
| `bash` 4.2+, `openssl`, `ssh`, `ssh-keygen` | Already on almost every Linux. Check: `bash --version && openssl version && ssh -V` |
| Network access to each BIG-IP's **management** address on TCP 22 | Ask your network team if unsure. |
| The BIG-IP's `root` account (once) | Needed one time, to add your SSH key. After that the tool logs in with the key. |
| The certificate files from your CA | The server certificate, the intermediate (chain) certificate(s) and the private key. |
| An existing client-ssl profile on the BIG-IP | The tool changes the certificate **inside** an existing profile; it does not create one. |

On Windows, open **Ubuntu (WSL)** and do everything below in that window. Keep the files inside the Linux
home folder (`~`), not under `/mnt/c`, so file permissions work.

## 2. One-time setup

```bash
mkdir -p ~/f5-cert-push/certs ~/f5-cert-push/backups
cd ~/f5-cert-push
tar xzf /path/to/f5-cert-push-2.1.2.tar.gz --strip-components=1     # puts f5-cert-push.sh here
chmod 700 ~/f5-cert-push
chmod 750 f5-cert-push.sh
./f5-cert-push.sh --version
```

You end up with:

```
~/f5-cert-push/
    f5-cert-push.sh          the tool
    f5-cert-push.conf        your settings (you create it in section 6)
    certs/
        www/                 one folder per certificate (section 5)
            cert.pem
            chain.pem
            privkey.pem
    backups/                 the tool puts a copy of what it replaced here
```

The private key is the sensitive part. Keep `~/f5-cert-push` readable only by you (`chmod 700`, as above),
and delete the key files from `certs/` once the BIG-IP is updated and you have a backup elsewhere that your
security policy allows. The tool keeps its own backup copies under `backups/`.

## 3. Create the SSH key

The tool logs in to the BIG-IP with an SSH key. Create one for this tool only.

```bash
ssh-keygen -t ecdsa -b 384 -C "f5-cert-push $(whoami)" -f ~/.ssh/f5_push_ecdsa
```

- When asked for a **passphrase**, you may leave it empty (press Enter twice) or set one. An empty
  passphrase is simplest; a key with no passphrase **is root access to the BIG-IP**, so keep the file private
  (`ssh-keygen` already sets mode 600) and never email or copy it around. If you set a passphrase, see
  "Using a passphrase" below.
- **Use ECDSA (or RSA), not ed25519.** BIG-IP's SSH commonly refuses ed25519 keys without telling you why.

Show the **public** half. This one line is what you give the BIG-IP:

```bash
cat ~/.ssh/f5_push_ecdsa.pub
```

It looks like `ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQ... f5-cert-push you`. Never share the file
without `.pub`.

**Using a passphrase.** Start an agent for your session and add the key; the tool then uses the agent:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/f5_push_ecdsa
```

and leave the `ssh_key =` line **out** of the configuration.

## 4. Authorise the key on each BIG-IP

Do this once per BIG-IP. You need a way to run commands as root on it: the console, the web UI's
**Advanced Shell** or an existing admin SSH session.

On the BIG-IP, run these three lines, pasting your `.pub` line inside the quotes:

```bash
echo 'ecdsa-sha2-nistp384 AAAA...your whole public key line... f5-cert-push you' >> /var/ssh/root/authorized_keys
chmod 600 /var/ssh/root/authorized_keys
restorecon -v /var/ssh/root/authorized_keys
```

The `restorecon` line matters: without it the BIG-IP can silently ignore the key.

Then, back on **your** machine, **trust the BIG-IP's identity** (once) and test the login. Replace
`10.0.0.11` with the BIG-IP's management address:

```bash
ssh-keyscan -t ecdsa 10.0.0.11 >> ~/.ssh/known_hosts
ssh-keygen -lf <(ssh-keyscan -t ecdsa 10.0.0.11 2>/dev/null)
```

The second command prints a fingerprint. On the BIG-IP run `ssh-keygen -lf /config/ssh/ssh_host_ecdsa_key.pub`;
the two fingerprints **must be identical**. If they differ, stop and ask who is answering at that address.
Then test the login:

```bash
ssh -i ~/.ssh/f5_push_ecdsa -o IdentitiesOnly=yes root@10.0.0.11 'tmsh show sys version | head -5'
```

You should see the BIG-IP version and **no password prompt**. If you get "Permission denied (publickey)",
check the three lines above ran as root, that the key is the `ecdsa` one, and read
[OPERATIONS.md](OPERATIONS.md) section 8. If the BIG-IP's SSH access is limited by address
(**System > Platform > SSH IP Allow**), your machine's address must be listed.

## 5. Save the certificate files

### 5.1 Where to put them

One folder per certificate, under `~/f5-cert-push/certs/`. The name is your choice (`www`, `api`,
`wildcard`...). Save the three PEM files there with **these names**:

| File | Content |
|---|---|
| `cert.pem` | the server certificate only |
| `chain.pem` | the intermediate certificate(s) from your CA (leave it out if the CA gave none) |
| `privkey.pem` | the private key, **without** a passphrase |

### 5.2 Example: from a download

Your CA usually sends a zip or several files. Typical names are `www_example_com.crt` (your certificate),
`ca-bundle.crt` or `intermediate.crt` (the chain) and `www.example.com.key` (the key you generated with the
request). Copy them into place:

```bash
mkdir -p ~/f5-cert-push/certs/www
cd ~/f5-cert-push/certs/www
cp ~/Downloads/www_example_com.crt   cert.pem
cp ~/Downloads/ca-bundle.crt         chain.pem
cp ~/Downloads/www.example.com.key   privkey.pem
chmod 600 privkey.pem
```

(From Windows, your Downloads folder is at `/mnt/c/Users/<you>/Downloads` inside WSL.)

If the CA gave you **one** file containing the certificate followed by the intermediates (often called
`fullchain.pem` or a "bundle"), save it as `fullchain.pem` instead of `cert.pem` + `chain.pem`; the tool splits
it for you.

### 5.3 What kind of file do I have? Do I need to convert it?

Certificates and keys come in several **formats**, and the file name does not tell you which one you have.
`.crt`, `.cer`, `.pem`, `.key` and `.cert` are only names; the same name can hold different formats, and the
same format can have different names. The tool needs the **PEM** format, which is plain text. If your file is
already PEM you only have to **rename or copy it** to the name in section 5.1 (for example `cp www.crt
cert.pem`). If it is not, it has to be **converted**; renaming a non-PEM file does not work.

**Step 1: look at the file.** Open it in a text editor (Notepad is fine, but do not save it), or run
`head -2 FILE`.

| What you see | Format | What to do |
|---|---|---|
| First line `-----BEGIN CERTIFICATE-----` | PEM certificate | Rename or copy to `cert.pem` (or `chain.pem` for an intermediate). |
| First line `-----BEGIN PRIVATE KEY-----`, `-----BEGIN RSA PRIVATE KEY-----` or `-----BEGIN EC PRIVATE KEY-----` | PEM private key | Rename or copy to `privkey.pem`. |
| `-----BEGIN ENCRYPTED PRIVATE KEY-----`, or a line `Proc-Type: 4,ENCRYPTED` | PEM key **with a passphrase** | Remove the passphrase first (below). The tool refuses these. |
| Several `-----BEGIN CERTIFICATE-----` blocks | PEM bundle | Your certificate first, then the intermediates. Save it as `fullchain.pem`. |
| Unreadable symbols (binary) | DER | Convert it (below). |
| The file is a `.pfx` or `.p12`, or the CA called it a "PKCS#12" or "PFX" bundle | PKCS#12 | Convert it (below). It holds the certificate, the chain and the key together and is protected by a password. |
| First line `-----BEGIN PKCS7-----` or the file is a `.p7b` | PKCS#7 | Convert it (below). Contains certificates only, never the key. |

**Common file types, and what is usually inside**

| Extension | Usually | Check anyway? |
|---|---|---|
| `.pem` | PEM | Rarely wrong, but a `.pem` can hold a cert, a key, or both. Look. |
| `.crt`, `.cert` | PEM certificate, sometimes DER | Yes. |
| `.cer` | DER or PEM, about equally often | **Yes.** |
| `.key` | PEM private key | Yes: it may have a passphrase. |
| `.der` | DER | It is binary: convert. |
| `.pfx`, `.p12` | PKCS#12 | Always convert. |
| `.p7b`, `.p7c` | PKCS#7 (certificates only) | Always convert. |
| `.csr` | A certificate **request**, not a certificate | Not usable here. Do not upload it as `cert.pem`. |

**Step 2: convert if needed.** (`openssl` is installed on Linux and WSL.) These commands read the original
and write a new file; the original is left alone.

```bash
# DER certificate (binary .cer/.crt/.der) -> PEM
openssl x509 -inform der -in site.cer -out cert.pem

# DER private key (binary) -> PEM
openssl pkey -inform der -in site.key -out privkey.pem

# Key with a passphrase -> key without one (asks for the passphrase once)
openssl pkey -in encrypted.key -out privkey.pem

# PFX / PKCS#12 (.pfx, .p12) -> separate PEM files (asks for the bundle's password)
openssl pkcs12 -in site.pfx -nokeys -clcerts -out cert.pem
openssl pkcs12 -in site.pfx -nokeys -cacerts -out chain.pem
openssl pkcs12 -in site.pfx -nocerts -nodes   -out privkey.pem      # -nodes = no passphrase

# PKCS#7 (.p7b) -> PEM certificates (then split: your cert -> cert.pem, the rest -> chain.pem)
openssl pkcs7 -in site.p7b -print_certs -out all-certs.pem
```

If you run `pkcs12` with OpenSSL 3 and see "unsupported" or "legacy" errors on an old `.pfx`, add `-legacy` to
the command.

**Things that trip people up**

- **Keep your certificate first in a bundle.** `fullchain.pem` must start with your server certificate,
  followed by the intermediates. Putting an intermediate first makes the key not match.
- **Do not paste into Notepad and save.** Notepad can add an invisible marker at the start of the file that
  OpenSSL cannot read. If you must copy text, use a plain text editor set to UTF-8 **without** BOM, or rewrite
  the file cleanly: `openssl x509 -in file -out cert.pem`.
- **Include the dashes.** The `-----BEGIN ...-----` and `-----END ...-----` lines are part of the file.
- **Extra text around the PEM blocks** (for example "Bag Attributes" or "subject=" lines, which `openssl
  pkcs12` adds) is best removed, because the tool may refuse it. `openssl x509 -in file -out cert.pem` rewrites
  a certificate cleanly (use `openssl pkey -in file -out privkey.pem` for a key).
- **Never upload a `.csr`.** It is the request you sent to the CA, not the certificate they gave back.
- **Cert and key must belong together.** If you have several of each, 5.4 shows how to check which pair
  matches.

### 5.4 Check the files yourself (optional, and the tool checks again)

```bash
cd ~/f5-cert-push/certs/www
openssl x509 -in cert.pem -noout -subject -issuer -enddate          # right name, right CA, new expiry?
diff <(openssl x509 -in cert.pem -noout -pubkey) <(openssl pkey -in privkey.pem -pubout) && echo "key matches"
openssl verify -untrusted chain.pem cert.pem                        # needs the root in your system store
```

The tool will refuse to continue if the key does not match, the certificate is expired or too close to expiry,
or the chain does not verify.

## 6. Write the configuration

Copy the example and edit it:

```bash
cd ~/f5-cert-push
cp /path/to/f5-cert-push.conf.example f5-cert-push.conf     # the example is in the tarball you unpacked
chmod 600 f5-cert-push.conf
nano f5-cert-push.conf
```

A small, complete configuration for **one BIG-IP, one certificate, one profile**. Replace `YOURNAME` with
your Linux user name (`whoami`) and use your own addresses and names:

```ini
[defaults]
chain_check              = fail        # refuse a chain that does not verify
min_days_valid           = 7
auto_rollback            = yes         # put the old certificate back if the check afterwards fails
strict_host_key_checking = yes         # only talk to BIG-IPs you trusted in section 4
backup_dir_local         = /home/YOURNAME/f5-cert-push/backups
log_file                 = /home/YOURNAME/f5-cert-push/f5-cert-push.log

[f5:prod-a]
host    = 10.0.0.11                    # the BIG-IP management address
ssh_key = /home/YOURNAME/.ssh/f5_push_ecdsa

[cert:www]
cert          = /home/YOURNAME/f5-cert-push/certs/www/cert.pem
chain         = /home/YOURNAME/f5-cert-push/certs/www/chain.pem
key           = /home/YOURNAME/f5-cert-push/certs/www/privkey.pem
object_prefix = www-example            # the name used for the objects on the BIG-IP

[deploy:www]
f5      = prod-a
cert    = www
profile = www-clientssl                # the existing client-ssl profile on the BIG-IP
verify  = 10.1.10.10:443 www.example.com    # after the change, check this virtual server serves the new cert
```

What each part means:

- `[f5:NAME]` is one BIG-IP. Add one per device.
- `[cert:NAME]` is one certificate: where its files are, and `object_prefix`, the name its objects get on the
  BIG-IP (new objects are named `www-example-cert-<date-time>.pem`, so old ones are never overwritten).
- `[deploy:NAME]` says **which profiles on which BIG-IPs get which certificate**. `f5 = prod-a, prod-b`
  deploys to several BIG-IPs. `profile =` may be repeated for several profiles. `verify =` takes
  `address:port server-name` and is repeatable.
- Write **full paths** (`/home/you/...`), not `~`, and avoid spaces in names. If something is wrong the tool
  prints exactly what it does not like and changes nothing.

To find the profile names on the BIG-IP:

```bash
./f5-cert-push.sh --config f5-cert-push.conf --discover --f5 prod-a
```

Many certificates, many BIG-IPs and several environments (`env = prod` / `env = test`) are all just more
sections; every setting is in [CONFIGURATION.md](CONFIGURATION.md) and a full example is in
`f5-cert-push.conf.example`.

## 7. Renewing a certificate: the routine

Do it in a change window, the same way each time. **Nothing changes on the BIG-IP until step 5.** Steps 1 to 4
are read-only. (From the folder `~/f5-cert-push`; add `--config f5-cert-push.conf` if the file is not in
the current folder, which it is here.)

1. **Save the new files** over the old ones in `certs/<name>/` (section 5).

2. **Check the files and the configuration. No network.**

   ```bash
   ./f5-cert-push.sh --validate
   ```

   Look for: the right certificate (subject and expiry), `OK`, and no errors. Fix anything it reports first.

3. **Look at what is on the BIG-IP now. Read-only.**

   ```bash
   ./f5-cert-push.sh --deploy www --check
   ```

   It shows the certificate currently in the profile and whether it differs from the new one.

4. **Rehearse. Prints every step, changes nothing.**

   ```bash
   ./f5-cert-push.sh --deploy www --dry-run
   ```

   Read the list: the BIG-IP, the profile, the objects it would create, the verification it would do.

5. **Do it.**

   ```bash
   ./f5-cert-push.sh --deploy www
   ```

   It backs up what is there (on the BIG-IP in `/shared/cert-backups/` and on your machine under `backups/`),
   uploads and installs the new certificate, switches the profile(s) in one step, saves the configuration,
   and checks that the virtual server now serves the new certificate. It prints a summary at the end.
   If the check fails and `auto_rollback = yes`, it puts the old certificate back by itself and tells you
   (exit code 3).

6. **Confirm from outside** (the summary also states this):

   ```bash
   echo | openssl s_client -connect 10.1.10.10:443 -servername www.example.com 2>/dev/null \
     | openssl x509 -noout -subject -enddate -fingerprint -sha256
   ```

   And open the site in a browser.

7. **Tidy up.** Keep the `backups/` folder. Remove the key from `certs/<name>/` if your policy says so.

Because you run this by hand, there is **no cron job and no automatic push**: the tool does nothing until you
run step 5. Running step 5 again with the same certificate does nothing ("UP TO DATE").

Several deployments at once: `./f5-cert-push.sh --all`, or `--env prod`. Use `--deploy NAME` while you are
learning; it touches exactly one thing.

## 8. If something is wrong: rolling back

Automatic: if the post-change check fails, the tool already rolled back (read its message).

Manual, any time later:

```bash
./f5-cert-push.sh --deploy www --list-backups                 # shows the backup sets, newest first
./f5-cert-push.sh --deploy www --rollback --set 20261005-143015     # choose a set from that list
```

It checks the backup set first (every file present and matching its checksums), puts the previous
certificate back, and then **re-reads the BIG-IP to confirm** every profile and object is exactly as it was:
the summary says `RESTORED` only when that is confirmed. It does not need the new certificate's files, so it
works even if you have already deleted or replaced them. Each backup also contains a
`restore-<time>.sh` you can run directly on the BIG-IP.

## 9. High-availability pairs

Run the tool **once, against the active BIG-IP**, not once per unit. Certificates, keys and profiles are part of
the synchronised configuration, so config-sync carries them to the peer. Refer to
[OPERATIONS.md](OPERATIONS.md) section 5 for the details. In short:

1. Put **only the active unit** in the configuration (`[f5:...]`). The tool refuses a standby unit.
2. Run the routine in section 7.
3. Synchronise the pair as you normally do, from the BIG-IP:

   ```bash
   tmsh run cm config-sync to-group YOUR-DEVICE-GROUP
   ```

   or in the web UI (**Device Management > Overview > Sync**). The tool reminds you when this is needed.
4. Check the peer: `tmsh show cm sync-status` should say **In Sync**, and the same fingerprint should be served
   after a failover test, if you do one.

If the pair is **not** synchronising (sync disabled, or each unit is configured separately), run the routine
against each unit in turn, active first.

## 10. Quick reference

```bash
cd ~/f5-cert-push
./f5-cert-push.sh --validate                          # check files + config (no network)
./f5-cert-push.sh --list                              # what the configuration defines
./f5-cert-push.sh --discover --f5 prod-a              # profiles and their current certificates
./f5-cert-push.sh --deploy www --check                # compare with the BIG-IP (read-only)
./f5-cert-push.sh --deploy www --dry-run              # rehearsal (changes nothing)
./f5-cert-push.sh --deploy www                        # do it
./f5-cert-push.sh --deploy www --list-backups
./f5-cert-push.sh --deploy www --rollback --set TIME
./f5-cert-push.sh --help
```

| Message | Meaning / fix |
|---|---|
| `Permission denied (publickey)` | The key is not authorised on the BIG-IP (section 4), or it is not an ECDSA/RSA key. |
| `Host key verification failed` | You have not trusted the BIG-IP (section 4), or its host key changed. Compare fingerprints before updating `known_hosts`. |
| `private key does not match` | The key is from a different request than the certificate. |
| `does not verify against the supplied chain` | Wrong or old intermediate. Download the current chain from your CA. |
| `expires within min_days_valid` | The new certificate is about to expire; get a longer one. |
| `... is 'standby', not active` | Point the configuration at the active unit (section 9). |
| `another run is in progress` (exit 6) | Someone else (or an earlier run) holds the lock. Wait; if it is stuck, see [OPERATIONS.md](OPERATIONS.md) section 8. |
| exit 3 | The change was rolled back automatically. The BIG-IP is back on the old certificate. |

Exit codes: `0` success, `1` a failure (the message says why), `2` usage error, `3` the change was rolled back,
`4` `--check` found a certificate that is out of date, `5` CRITICAL: the BIG-IP's state could not be
confirmed (follow the printed instructions and call your BIG-IP administrator; see OPERATIONS.md section 8),
`6` another run is in progress, `130` you interrupted it (Ctrl-C) before anything was changed, or after it
had finished. Interrupting it in the middle of a change is safe: it finishes the step and puts the previous
certificate back (exit 3).
