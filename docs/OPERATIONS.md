# Operations guide

1. [First-time setup](#1-first-time-setup)
2. [Day-to-day use](#2-day-to-day-use)
3. [Automating renewals and monitoring](#3-automating-renewals-and-monitoring)
4. [Rollback](#4-rollback)
5. [HA pairs and multiple BIG-IPs](#5-ha-pairs-and-multiple-big-ips)
6. [Backups, retention and housekeeping](#6-backups-retention-and-housekeeping)
7. [Logs and output](#7-logs-and-output)
8. [Troubleshooting](#8-troubleshooting)
9. [Known limitations](#known-limitations)
10. [Removing the tool](#10-removing-the-tool)

---

## 1. First-time setup

### 1.1 Create a key dedicated to this tool

Give the tool its own SSH key so it can be revoked without affecting anyone else. Use **ECDSA P-384**:
the BIG-IP's SSH daemon is commonly restricted (FIPS-style settings accept only ECDSA and RSA), and an
ed25519 key is then silently ignored.

```bash
ssh-keygen -t ecdsa -b 384 -N '' -C 'f5-cert-push' -f /root/.ssh/f5_push_ecdsa
chmod 600 /root/.ssh/f5_push_ecdsa
cat /root/.ssh/f5_push_ecdsa.pub           # one line starting ecdsa-sha2-nistp384
```

> **A key with no passphrase is root on the BIG-IP.** Whoever can read this file can change the BIG-IP.
> Keep it readable by the account that runs the tool only (mode 600), on a host you trust. If you need a
> passphrase, load the key into an `ssh-agent` and omit `ssh_key` from the config; the tool then uses the agent.

### 1.2 Authorise the key on each BIG-IP

On the BIG-IP (console or an existing admin session), as root:

```bash
echo 'ecdsa-sha2-nistp384 AAAA...paste the .pub line... f5-cert-push' >> /var/ssh/root/authorized_keys
chmod 600 /var/ssh/root/authorized_keys
restorecon -v /var/ssh/root/authorized_keys
```

Notes learned the hard way:

- On BIG-IP, `/root/.ssh/authorized_keys` is a **symlink** to `/var/ssh/root/authorized_keys`. Append to the target.
- The file needs the SELinux label `ssh_home_t`. A wrong label makes sshd ignore every key, **with no error
  in the log**. `restorecon` fixes it; that is what the last command is for.
- If a key is present and correct but login still fails, check `/config/ssh/sshd_config` for
  `PubkeyAcceptedKeyTypes`. The BIG-IP may only accept ECDSA and RSA keys.
- A BIG-IP **license reload** can re-apply SSH hardening, so a key type that worked before may stop working after.

### 1.3 Pin the BIG-IP's host key

The tool defaults to `strict_host_key_checking = yes`, so the BIG-IP's SSH host key must be known first.
Fetch it and **compare the fingerprint with what the BIG-IP itself shows** before trusting it:

```bash
ssh-keyscan -t ecdsa BIGIP_ADDRESS >> /root/.ssh/known_hosts
ssh-keygen -lf <(ssh-keyscan -t ecdsa BIGIP_ADDRESS 2>/dev/null)     # fingerprint to compare
# on the BIG-IP:   ssh-keygen -lf /config/ssh/ssh_host_ecdsa_key.pub
```

(Or set `strict_host_key_checking = accept-new` for a lab to trust first contact and pin it automatically.)

Test the login exactly as the tool will make it:

```bash
ssh -i /root/.ssh/f5_push_ecdsa -o IdentitiesOnly=yes root@BIGIP_ADDRESS 'tmsh show sys version | head -5'
```

### 1.4 Write the configuration

```bash
cp f5-cert-push.conf.example /etc/f5-cert-push.conf
chmod 600 /etc/f5-cert-push.conf
$EDITOR /etc/f5-cert-push.conf
```

Start with one BIG-IP, one certificate, one deployment. Find the profile names with:

```bash
./f5-cert-push.sh --config /etc/f5-cert-push.conf --discover --f5 prod-a
```

### 1.5 Validate, rehearse, deploy

```bash
./f5-cert-push.sh --validate                   # config + certificate files, no network
./f5-cert-push.sh --deploy prod-www --check    # read-only: what is on the BIG-IP now?
./f5-cert-push.sh --deploy prod-www --dry-run  # shows every step it would take
./f5-cert-push.sh --deploy prod-www            # do it
```

On the first real deploy, watch the output and confirm afterwards from outside
(`openssl s_client -connect VIP:443 -servername NAME`).

---

## 2. Day-to-day use

```bash
f5-cert-push.sh --env prod --check        # is anything stale?  (exit 4 = yes)
f5-cert-push.sh --env prod                # deploy everything stale in prod
f5-cert-push.sh --deploy prod-www --force # redeploy even though it is current
f5-cert-push.sh --all --quiet             # everything, terse
```

Deploying is **idempotent**: if every targeted profile entry already uses this exact certificate (compared
by SHA-256 fingerprint), the deployment is skipped with `UPTODATE`, no backup is taken and nothing changes.

### What a deployment does, in order

| # | Step | If it fails |
|---|---|---|
| 1 | Validate the local files | stop; nothing touched |
| 2 | Take the per-BIG-IP locks (on this host, and on the BIG-IP) | exit 6 |
| 3 | Connect; check the BIG-IP is fully loaded, active, and the partition and profiles exist | stop; nothing touched |
| 4 | Decide which entry of each profile to change; compare fingerprints | stop, or `UPTODATE` |
| 5 | **Back up** the current objects to the BIG-IP and here. The set is checked against the list of what it must contain (worked out here, from the plan), every file is checked against `SHA256SUMS`, and the checksums must cover every file including the restore script | stop; nothing touched |
| 6 | Upload to a private staging directory; verify checksums on the BIG-IP | stop; staging removed |
| 7 | **Install** the new objects under versioned names | new objects removed; nothing touched |
| 8 | **Switch** all profiles in one transaction and save | if the BIG-IP reports a failure, the profiles are **re-read** to confirm nothing changed, then the new objects are removed; if it cannot be confirmed, as step 9 |
| 9 | Verify bindings, then the endpoints | **roll back** (exit 3), or exit 1 if `auto_rollback = no` |
| 9a | With `fixed_names = yes`: overwrite the fixed-name objects, then read them back | **roll back** everything (exit 3), as step 9 |
| 10 | Prune old backups and versions | warning only |
| 11 | Summary | |

Steps 1 to 7 cannot alter what the BIG-IP serves. The single moment of change is step 8.

**Every step that changes the BIG-IP is tracked on the BIG-IP.** It runs only if this run still holds the
BIG-IP lock, it keeps going if the SSH connection drops, and its output and exit status are recorded on the
BIG-IP. If the reply is lost (a dropped connection, a timeout), the tool reads the step's real outcome back
instead of guessing, waiting up to `remote_timeout` for a step that is still running; a step that had not yet
started is cancelled on the BIG-IP at that moment, so it can never start later. If the outcome still
cannot be established, the job is treated as **changed**: it is rolled back, and the result is `CRITICAL`
even if the rollback is verified (the step might still complete later).

### Interrupting a run (Ctrl-C, `kill`, a service stop)

A signal never leaves a BIG-IP changed but unverified:

- **During a step on the BIG-IP**, the step is allowed to finish (a profile switch is never cut in half), then
  the tool recovers as below. Further signals are ignored while it recovers.
- **Before anything changed**, the run stops: objects it installed are removed, exit 130.
- **After the profiles (or fixed-name objects) changed**, it rolls back and verifies: exit 3, or 5 if that
  cannot be confirmed. With `auto_rollback = no` it stops with `FAILED_CHANGED` and prints the rollback command.
- **After a deployment was completed and verified** (during pruning), it finishes that deployment, skips the
  rest, and exits 130.

`kill -9` cannot be handled by any program: see [SECURITY.md](SECURITY.md), section 6.

### Reading the summary

```
==================== SUMMARY ====================
  DEPLOYMENT@BIG-IP                  RESULT         DETAIL
  prod-www@prod-a                    UPDATED        deployed; expires Nov 25 02:18:07 2026 GMT
  prod-www@prod-b                    UPTODATE       already serving this certificate
  prod-api@prod-a                    ROLLED_BACK    a verification endpoint is not serving ...
=================================================
```

| Result | Meaning | Exit |
|---|---|---|
| `UPDATED` | Deployed and verified | 0 |
| `UPTODATE` | Already current; nothing done | 0 |
| `DRYRUN` | `--dry-run`; nothing done | 0 |
| `RESTORED` | `--rollback` completed **and verified** on the device | 0 |
| `OUTDATED` | `--check`: needs a deploy | 4 |
| `FAILED` | Failed; see the message. The BIG-IP is unchanged | 1 |
| `FAILED_CHANGED` | Verification failed, `auto_rollback = no`, so the BIG-IP **stays on the new certificate**; the message gives the rollback command | 1 |
| `ROLLED_BACK` | Failed after the switch; put back automatically **and verified** | 3 |
| `CRITICAL` | The BIG-IP's state is **not confirmed**: the rollback (or a `--rollback`) could not be verified, or a step never reported its outcome. Act now; see section 8. The BIG-IP lock is left in place | 5 |
| `LOCKED` | Another run holds the lock | 6 |

An interrupted run that reported nothing worse exits 130.

---

## 3. Automating renewals and monitoring

### 3.1 From certbot

```bash
#!/usr/bin/env bash
# /etc/letsencrypt/renewal-hooks/deploy/f5-cert-push.sh   (chmod 750, owned by root)
exec /opt/f5-cert-push/f5-cert-push.sh --config /etc/f5-cert-push.conf \
     --lineage "$RENEWED_LINEAGE" --quiet
```

`--lineage` selects the deployments whose `[cert:]` has `le_dir` equal to the renewed lineage. A lineage
with no matching deployment exits 0 with a notice, so the hook never fails a renewal for an unrelated
certificate. If a BIG-IP deployment fails, certbot's hook reports the non-zero exit; the renewal itself is
unaffected.

### 3.2 Catch drift: a scheduled check

A renewal can succeed while the push fails (network, a lock, a BIG-IP that was down). Run a read-only check
regularly and alert on exit 4:

```bash
# /etc/cron.d/f5-cert-check
17 6 * * *  root  /opt/f5-cert-push/f5-cert-push.sh --config /etc/f5-cert-push.conf --all --check --quiet \
                  || logger -t f5-cert-push "a BIG-IP is out of date or unreachable (exit $?)"
```

`--check` takes no lock and changes nothing. Exit 4 = out of date; 1 = could not check.

### 3.3 Exit-code contract for other systems

| Exit | Suggested action |
|---|---|
| 0 | none |
| 1 | investigate; the message says why |
| 3 | a deploy was rolled back: the new certificate is **not** live. Investigate the verification failure |
| 4 | schedule a deploy |
| 5 | page someone: the BIG-IP may be in a mixed state; follow the printed restore command |
| 6 | retry later; another run is in progress |

---

## 4. Rollback

### 4.1 Automatic

After switching profiles the tool re-reads them and checks each target entry uses exactly the new
objects, then probes your `verify` endpoints (and, with `fixed_names = yes`, reads the fixed-name objects
back). If anything fails and `auto_rollback = yes` (the default) it runs the restore script and then
**verifies the result on the device** (section 4.4). Result `ROLLED_BACK`, exit 3. The objects created for
the failed attempt are removed. If the result cannot be verified: `CRITICAL`, exit 5.

### 4.2 Manual

```bash
f5-cert-push.sh --deploy prod-www --list-backups
f5-cert-push.sh --deploy prod-www --rollback --set 20260930-162806
```

`--set TS` restores **the state captured just before run `TS`**, which is the state the BIG-IP was in
before that deployment. Every run prints its own rollback command at the end.

A manual rollback does **not** need the certificate that is being undone: the local certificate files may
be missing, expired or invalid. It copies the backup set from the BIG-IP, checks it (every file present and
covered by `SHA256SUMS`, the inventory well-formed, every PEM parses), runs its restore script, and verifies
the result exactly like an automatic rollback. Result `RESTORED` (0), `FAILED` (1, nothing was changed: the
set was missing or failed its checks) or `CRITICAL` (5, the restore ran but could not be verified).

Sets written by version 2.0.0 have no inventory and their restore script is not covered by their checksums;
they can still be restored: their contents are read from the restore script itself (only the exact lines 2.0.0
wrote are accepted), the configuration is saved again afterwards (2.0.0's script ignored a failed save), and
the result is verified the same way. The tool says when it is restoring a 2.0.0 set.

You can also run the script directly on the BIG-IP without the tool:

```bash
bash /shared/cert-backups/<object_prefix>/<TS>/restore-<TS>.sh
echo $?      # 0 restored and saved; 10 integrity check failed, nothing changed; other: failed part-way
```

### 4.3 What the restore script does

`restore-<TS>.sh` is generated for each run and lists exactly what to undo:

1. **Verifies the whole set against `SHA256SUMS`** (the PEM copies, the inventory, the manifest and the restore
   script itself). If the checksum list is missing or anything does not match, it changes nothing and exits 10.
2. Re-installs any old certificate or key **object that no longer exists** (for example one removed by
   pruning) from the backed-up PEM. Objects that still exist are left alone.
3. Re-installs the **fixed-name** objects from backup (these were overwritten in place).
4. Repoints every profile entry to its previous certificate, chain and key, in **one transaction**.
5. Deletes fixed-name objects that **did not exist** before that run (they were created by it).
6. Saves the configuration.

Every `tmsh` command's exit status is checked as well as its output; any failure stops the script with a
non-zero exit (a failed save included).

Backups contain **private keys**; the restore script and PEMs are mode 0600 in a 0700 directory.

### 4.4 How a rollback is verified

The device is the authority, not the restore script's exit status. After a restore the tool re-reads the
BIG-IP and requires, for every item in the backup's `INVENTORY`:

- each profile exists and has **exactly one** entry of that name, bound to exactly the old certificate, chain
  and key;
- each backed-up certificate object holds the backed-up certificate (SHA-256 fingerprint), and each backed-up
  key object holds the backed-up key (compared by the SHA-256 of its public key);
- each object that did not exist before does not exist now.

Anything else (including a profile or entry that is missing) is reported as not restored.

---

## 5. HA pairs and multiple BIG-IPs

**The tool does not synchronise a device group.** For an HA pair:

1. Deploy to the **active** unit. The tool refuses a standby unit (`allow_standby = no`).
2. Synchronise as you normally do (for example `tmsh run cm config-sync to-group NAME`).
3. After a successful run on a BIG-IP that is not standalone, the tool prints a reminder to synchronise.

Objects are created in the device group's synced folders (`/Common`), so the sync carries them to the peer.
Alternatively list **both** units as separate `[f5:]` sections with `allow_standby = yes`, but then the next
config-sync can overwrite what you pushed to the standby. The first approach is safer.

For many BIG-IPs (separate environments, data centres, tenants) define one `[f5:]` per device and one
`[deploy:]` per certificate-to-devices mapping; see [CONFIGURATION.md](CONFIGURATION.md#recipes). Deployments
run **sequentially**; two runs against the same BIG-IP cannot overlap (the lock), and a failure in one
deployment does not stop the others unless you pass `--fail-fast`.

---

## 6. Backups, retention and housekeeping

- **Two copies of every backup**: on the BIG-IP (`/shared/cert-backups/<prefix>/<time>/`) and here
  (`<backup_dir_local>/<bigip>/<prefix>/<time>/`). The local copy is compared to the BIG-IP's checksums before
  the tool proceeds.
- **Retention** (`keep`, default 4) applies to backup sets on both sides and to certificate versions on the
  BIG-IP. Only directories or objects that match the tool's timestamp pattern are ever removed.
- **Space**: a set is a few kilobytes per certificate.
- **Protect the local backup directory.** It contains private keys. Consider it as sensitive as the
  certificate store itself; include it in your secret-handling and backup policy.
- **A certificate version a profile still uses is never deleted**; the BIG-IP refuses.
- **Leftover staging directories** on the BIG-IP (`/var/tmp/f5-cert-push.*`, from a run killed with `kill -9`
  or a lost connection) are swept automatically by the next run once they are two hours old.
- **Locks.** The local lock records its process; a lock whose process no longer exists is taken over at once.
  The lock on the BIG-IP (`/var/run/f5-cert-push.lock`) is a **lease**: it records its owner and is renewed at
  every step of the run that holds it, and every step that changes the BIG-IP first checks that its run still
  holds it (a run that has lost its lock stops at once, without changing anything more). A lock that has not
  been renewed for `remote_lock_stale_minutes` (default 30) belongs to a run that died, and may be taken over.
  The configuration is refused if `remote_lock_stale_minutes` is too short for `remote_timeout` (it must be at
  least `(2 x remote_timeout + 300)` seconds, rounded up to minutes). Every operation on the lock is serialised
  by a kernel lock on the BIG-IP, `/var/run/f5-cert-push.guard` (an empty file; leave it in place).
- **After a `CRITICAL` result the BIG-IP lock is deliberately left in place**, so that no other run touches the
  device until someone has looked at it (it expires by itself after `remote_lock_stale_minutes`). Once you
  have checked the device (`--check`, or `tmsh list ltm profile client-ssl NAME cert-key-chain`) and restored it
  if needed, remove it: `rm -rf /var/run/f5-cert-push.lock` on the BIG-IP.

---

## 7. Logs and output

Set `log_file` to keep a timestamped record of every run (mode 0600). Every line is prefixed with
`[deployment@bigip]`. Nothing secret is logged: no key material, no passphrases, no file contents;
certificate subjects and fingerprints are logged. Text that came from a remote system is stripped of control
characters before it is printed or logged, and when a message spans several lines (for example the BIG-IP's
own error text), every line after the first is indented and marked `    | `, so it can never be mistaken for
a record of its own.

`--quiet` prints only warnings, errors and the summary (the log file still gets everything).

---

## 8. Troubleshooting

| You see | Cause and fix |
|---|---|
| `Permission denied (publickey...)` | The BIG-IP did not accept the key. Check in this order: the key is in `/var/ssh/root/authorized_keys`; that file has label `ssh_home_t` (`restorecon -v`); the key type is allowed (`grep PubkeyAcceptedKeyTypes /config/ssh/sshd_config`, use ECDSA); you are offering the right key (`ssh_key`). |
| `Host key verification failed` | The BIG-IP's host key is not in known_hosts (or changed). Pin it (section 1.3). If it **changed unexpectedly**, stop and find out why. |
| `refusing to use ... writable by group or others` | `chmod 600` the config file. |
| `the BIG-IP configuration is not fully loaded (phase ..., last load ...)` | The BIG-IP is mid-restart or its config failed to load (for example after a license change). Fix that first. The tool will not change a BIG-IP in that state. |
| `this BIG-IP is 'standby', not active` | Deploy to the active unit, or set `allow_standby = yes`. |
| `profile '...' does not exist on the BIG-IP` | Wrong name or partition; `--discover --f5 NAME` lists what exists. |
| `inherits its certificate from its parent profile` | Update the parent profile, or set `inherit-certkeychain false` on this one. |
| `has N cert-key-chain entries ... name the entry explicitly` | Use `profile = NAME:ENTRY`. |
| `the certificate does not match the key` / `private key does not match` | The files are from different issuances; check `cert`/`key` paths. |
| `passphrase-protected` | Decrypt a copy of the key: `openssl pkey -in KEY -out KEY.plain`, and point `key` at that copy. |
| `the tmsh transaction failed ... (tmsh transactions are all-or-nothing)` | The BIG-IP rejected the change and nothing changed. The message includes the BIG-IP's reason, commonly: the profile already holds a certificate of the same key type in another entry. |
| `another run holds the lock` (exit 6) | Another run is in progress, here or on another host (the message says which, and who). If none is, a local lock with a dead PID is removed automatically, and a BIG-IP lock expires after `remote_lock_stale_minutes`; or remove `/var/run/f5-cert-push.lock` on the BIG-IP by hand. |
| `no TLS handshake` from a verify endpoint | The probe could not connect. With `verify_from = f5`, the address must be reachable **from the BIG-IP**; with `local`, from this host. |
| `serves sha256 ... expected ...` | The endpoint is using another profile or virtual server, or the BIG-IP is caching. Check which profile the virtual server really uses. |
| Summary `CRITICAL` | The BIG-IP's state is not confirmed. 1) Look: `f5-cert-push.sh --deploy NAME --check`, or `tmsh list ltm profile client-ssl <name> cert-key-chain` on the BIG-IP. 2) Restore if needed with the printed `--rollback --set TS` command (or `bash restore-<TS>.sh` on the BIG-IP; every old PEM is in the backup directory). 3) Remove the BIG-IP lock the run left in place: `rm -rf /var/run/f5-cert-push.lock`. |
| `an earlier step never reported its outcome` | The BIG-IP stopped answering in the middle of a change for longer than `remote_timeout`. The tool rolled back and verified, but the stalled step might still complete. Check the device as for `CRITICAL`. |
| `no complete reply from the BIG-IP ...; reading the outcome of the step` | The connection dropped during a step. Not an error by itself: the outcome is read back from the BIG-IP and the run continues. |
| `this run no longer holds the lock on the BIG-IP` | Another run took over the BIG-IP lock (this run had not renewed it for `remote_lock_stale_minutes`: a stalled host or network). This run stopped before changing anything more. Find out which run holds it (`cat /var/run/f5-cert-push.lock/owner`). |
| `the backup is incomplete or does not verify (...)` | The backup set that came back from the BIG-IP is missing an item, has an unexpected file, or does not match its checksums. Nothing was changed. Check space and permissions on `backup_dir_remote` on the BIG-IP. |
| `remote_lock_stale_minutes (...) must be at least ...` | Raise `remote_lock_stale_minutes`, or lower `remote_timeout`. |
| `backup set ... cannot be used: ...` | `--rollback` found the set missing, incomplete, or not matching its checksums, and changed nothing. |
| `cannot read the BIG-IP (ssh/tmsh failed, rc=124)` | A step exceeded `remote_timeout`; raise it, and check the BIG-IP's load. |

Run with `--dry-run` first; it reads everything a deploy would and prints the plan.

---

## Known limitations

- **client-ssl profiles only.** `server-ssl` profiles, APM, iRules that reference certificates by name, and
  other consumers are not updated. The optional fixed-name objects exist for those.
- **Private keys must be unencrypted.** Encrypted keys are refused.
- **HA synchronisation is manual** (section 5).
- **"Up to date" is decided by the leaf certificate's fingerprint** for profiles. If only the chain
  (intermediates) changes while the leaf stays the same, the tool sees nothing to do; use `--force` to
  redeploy. The fixed-name objects (`fixed_names = yes`, or no profile configured) are compared completely:
  certificate, chain, fullchain and key.
- **A BIG-IP that stops answering in the middle of a change** for longer than `remote_timeout` leaves an
  outcome the tool cannot know. It is reported `CRITICAL` (section 2), never as success.
- **Dual RSA+ECDSA profiles**: update one entry per deployment; the tool does not infer which certificate is
  which key type. Verification probes whichever certificate the default handshake selects.
- **SNI-multi-entry profiles** with several same-type entries cannot exist on the BIG-IP; the tool's entry
  selection is for RSA+ECDSA pairs.
- **Fixed-name objects are overwritten in place** (not atomic), by design and only when requested. They
  are read back afterwards; a failed or partial overwrite fails the deployment and is rolled back.
- **Tested on BIG-IP 17.1.3.4, standalone.** The standby refusal and "configuration not loaded" refusal are
  implemented but could not be exercised; see [TESTING.md](TESTING.md).
- **Chain verification needs OpenSSL 1.1.0 or newer** on the host running the tool. With 1.0.x it is skipped (with
  a warning, or refused under `chain_check = fail`).
- **Root SSH to the BIG-IP is required** (it must read `/config/filestore` for backups).
- **Linux only** (GNU tools). The BIG-IP-side scripts run under the BIG-IP's bash 4.2.

---

## 10. Removing the tool

1. Delete the tool's key from each BIG-IP: remove its line from `/var/ssh/root/authorized_keys`.
2. Delete the private key on the host, the configuration file and (if you no longer need them) the local
   backup directory and log.
3. On the BIG-IP, old backups can be removed with `rm -rf /shared/cert-backups/<prefix>`. Certificate
   objects named `<prefix>-*-<time>.pem` can be deleted once no profile uses them (the BIG-IP refuses to delete
   one that is in use).
