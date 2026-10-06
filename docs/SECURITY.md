# Security

This document states what `f5-cert-push` protects, what it assumes, and what it does **not** defend
against, so that you can judge it and review it. For the code-level brief see [REVIEW.md](../REVIEW.md).

## 1. What the tool is, security-wise

It is a privileged automation: it holds an SSH credential that is **root on your BIG-IPs**, reads your
certificates' **private keys**, and writes them to the BIG-IPs and to local backup files. The design goal is
that this privilege cannot be turned against you by a typo, a hostile value, a network attacker or a
half-finished run.

## 2. Assets

| Asset | Where it lives | Sensitivity |
|---|---|---|
| The tool's SSH private key | the host running the tool | **Critical.** Root on every BIG-IP it is authorised on |
| Certificate private keys | source files; a private scratch dir during a run; a staging dir on the BIG-IP during a run; BIG-IP objects; **backups on the BIG-IP and on the host** | **Critical** |
| The configuration file | the host | Moderate: it names keys, paths and addresses, but contains no secrets |
| The BIG-IP configuration | the BIG-IP | High: the tool changes it |

## 3. Trust boundaries and assumptions

1. **The host running the tool is trusted.** Anyone who is root there, or who can read the SSH key, is root
   on the BIG-IPs. Harden and monitor it accordingly.
2. **The BIG-IP is trusted** to report honest state, but its output is treated as untrusted *data*: it is
   parsed strictly, validated before use in paths, and sanitised before display (see 4.4).
3. **The network is not trusted.** All traffic is SSH; the BIG-IP's host key is checked (see 4.3).
4. **The configuration file's author is trusted to choose targets**, but not to execute code: the file is
   parsed, never sourced, and every value is validated (see 4.1).
5. **Other local users are not trusted.** Files are created private (umask 077, modes 0600/0700).

## 4. Controls

### 4.1 Input handling

- The configuration is an INI file **read by a parser**. It is never `source`d or `eval`'d.
- Every value is checked against a strict character set *when the file is loaded*, before anything runs:
  hosts (no leading hyphen, so a value cannot become an `ssh` option), users, ports, absolute paths
  (no spaces, no `..`, no `//`), object and profile names, verify endpoints, numbers, enumerations. Shell
  metacharacters, quotes, backticks, `$`, braces, spaces and non-ASCII are rejected.
- Values that cross to the BIG-IP (object names, profile names, paths) are additionally passed as
  **positional arguments, each shell-quoted with `printf %q`**, to fixed scripts; they are never
  interpolated into command text. (`ssh` joins its arguments into one string that the remote shell
  re-parses; this is why the quoting matters and is tested.)
- tmsh command lines that contain names are built only from values that passed validation.
- The offline test suite includes injection attempts (command substitution, semicolons, pipes, leading
  hyphens, traversal) and asserts a marker file is **not** created.

### 4.2 Secrets handling

- Private keys are copied once into a private scratch directory (mode 0700, on **tmpfs** `/dev/shm` when
  available, so they do not reach disk), validated there, and uploaded from there. The scratch directory is
  shredded and removed on exit, including on Ctrl-C and on `SIGTERM`.
- The staging directory on the BIG-IP is created with `mktemp -d` (unpredictable name), mode 0700, files
  0600; it is shredded and removed on exit, and a run also sweeps abandoned ones older than two hours.
- **Upload integrity**: SHA-256 of each staged file is compared to the local file before anything is installed.
- **Backups are created private** (directory 0700, files 0600) on both sides, and contain private keys.
  They are *necessary* for a safe rollback and are therefore the tool's largest standing secret store.
- Nothing secret is written to logs: no key material, no file contents, no passphrases. Only paths,
  certificate subjects, dates and fingerprints.
- Passphrase-protected keys are refused rather than handled, so the tool never sees a passphrase.

### 4.3 Authentication and transport

- SSH is run with `BatchMode`, **public-key authentication only**, `IdentitiesOnly` (only the configured key
  is offered), no agent or X11 forwarding, no port forwarding, `ServerAlive` keepalives and a connect timeout.
- **Connection reuse** (`connection_reuse = yes`, the default): the steps of a job share one SSH connection,
  because BIG-IP logins are slow and each is logged. The control socket is created inside the private scratch
  directory (mode 0700, tmpfs when available), is closed after each BIG-IP and on exit, and `ControlPersist` is
  120 seconds as a backstop. Set `connection_reuse = no` to open a fresh connection for every step.
- **Host keys are verified** (`StrictHostKeyChecking=yes` by default). `accept-new` is available for labs and
  pins on first use. A changed host key fails the run.
- No password is ever requested or accepted.

### 4.4 Treating BIG-IP output as data

Everything read from the BIG-IP is parsed with fixed `awk` programs into fixed fields. Profile, entry and
object names that come back from it are re-checked against the same strict pattern as names in the
configuration before they are used to build tmsh commands or the generated restore script, and file names
returned by a backup are checked before being used to build a local path. Names that a step reports back
are never trusted to say what it created: the tool records the exact objects it asked for, and only those
are ever deleted again. Text is stripped to printable ASCII before it is shown or logged, so a hostile value
cannot inject terminal escape sequences; a message that spans several lines has every continuation line
indented and marked `    | `, so remote text cannot pass for a log record of its own.

The device, not a reply, is the authority on what happened: a failed transaction is confirmed by re-reading
the profiles before the BIG-IP is called unchanged, a rollback is verified by re-reading the profiles and the
objects' contents (fingerprints and key identities), and the exit status of every `tmsh` command that changes
something is checked in addition to its output.

### 4.5 Making unsafe states hard to reach

- No "run everything" default: you must name a deployment, environment, lineage or `--all`.
- The BIG-IP is refused unless its configuration is **fully loaded** and the unit is **active** (or standby
  with an explicit opt-in).
- Nothing on the BIG-IP changes until the **backup is complete and verified**: the set must contain exactly
  the items planned (an inventory compared with a list worked out locally), and its checksums must cover
  every file, the restore script included. The new files are installed under **new names**. The live
  configuration changes in **one transaction**.
- After the change the result is **verified and rolled back automatically** on failure, and the rollback is
  itself verified on the device. A state that cannot be confirmed is reported `CRITICAL`, never success.
- **Lost replies are not guessed at.** Each change runs on the BIG-IP immune to a dropped connection, with its
  outcome recorded there; a lost reply is answered by reading that record.
- **Signals** (Ctrl-C, `kill`) are deferred while a change is running on the BIG-IP and then lead to a verified
  rollback if the BIG-IP had changed.
- **Per-BIG-IP locking**, both on this host and **on the BIG-IP itself**, prevents two runs (even from different
  hosts) from interleaving. The BIG-IP lock is a lease: it records its owner, is renewed at every step, can only
  be taken over once it has not been renewed for `remote_lock_stale_minutes`, and take-over and release are
  atomic (rename, then check). **Fencing**: every change first checks, on the BIG-IP, that its run still holds
  the lock; a run that has lost it stops.
- The configuration file must not be group- or world-writable.
- Pruning only ever removes directories and objects matching the tool's own timestamp pattern, and the BIG-IP
  itself refuses to delete an object that a profile still uses.

### 4.6 Least privilege (what you can and cannot reduce)

The tool needs `tmsh` and read access to `/config/filestore` on the BIG-IP, which in practice means **root**.
You can reduce exposure by: a dedicated key; restricting where the key may be used from
(`from="10.0.0.5"` in `authorized_keys`); running the tool as a dedicated local account; and keeping
`backup_dir_local` on an encrypted filesystem. A forced-command wrapper on the BIG-IP is not practical
because the tool runs several different commands.

### 4.7 The upload wrapper (`f5-cert-install.sh`)

The wrapper runs as root over an upload directory that other people can write to, so it treats every upload
as hostile. The rule it follows: **root never acts through a path an uploader can redirect.**

- **The directories are part of the boundary, and are checked.** The wrapper refuses to run unless the upload
  directory and every directory above it (its real path, from `/`) are owned by root (or the account running
  it) and not writable by group or others unless the sticky bit is set. An upload folder is used only if it is
  a real directory owned by root and, if uploaders can write to it, has the **sticky bit** (mode `3770`). With
  the sticky bit an uploader can add and change their own files, but cannot rename or replace the folder, nor
  remove or replace anything root created in it. So the only uploader-controlled part of any path root uses is
  the last component.
- **Reading**: each file is copied into a private directory with `dd iflag=nofollow,nonblock`, at most 1 MiB + 1
  byte, under a timeout: a symbolic link is refused when it is opened (no check-then-use race), a FIFO cannot
  make the run hang, and a huge file is never copied in full. A file with more than one link (a hard link) is
  refused. What is validated and installed is that private copy, so the uploader cannot change it afterwards.
- **Writing**: root never opens an uploader-controlled path for writing. The `FAILED` report is written to a
  new file created with `mktemp` (exclusive create: a planted name cannot be followed) and then renamed over
  `FAILED`, which replaces the directory entry rather than following it, even if the uploader planted a
  symbolic link there.
- **Removing**: uploaded files are removed with `unlink(2)` (`rm -f`), which removes the directory entry and
  never follows a link. They are **not** overwritten first (that would mean opening the uploader's path for
  writing, which a swapped-in link could redirect). The tool's own private copies are shredded. If the uploaded
  key must not linger on disk, put the upload area on `tmpfs` or an encrypted filesystem (see the checklist).
- Validation is f5-cert-push's own (`--validate`), plus: the chain is required, and a certificate older than
  the installed one is refused.
- Installed releases are root-only (0700 directories, 0600 files). The switch to a new release is one atomic
  `rename(2)` of the `current` symlink.
- A rejected upload's files stay in the uploader's folder (they put them there); the `FAILED` file contains
  only the tool's message, never file contents.
- Hard links: keep `fs.protected_hardlinks = 1` (the default on current distributions), so an uploader cannot
  hard-link a file they do not own; the wrapper additionally refuses any upload file with more than one link.

The `tests/regress.sh` suite checks this as an unprivileged uploader against the real kernel when run as root.

## 5. What the tool does **not** protect against

| Not defended | Why / what to do |
|---|---|
| A compromised host running the tool | It holds a root credential and key material. Treat that host as critical infrastructure. |
| A malicious or compromised BIG-IP | It is trusted with the keys it is given. |
| Someone who can read the local backups | They contain private keys. Protect the directory, encrypt the disk, limit retention (`keep`). |
| An SSH key with no passphrase being stolen | Use a dedicated, restricted key; rotate it; use `from=` restrictions; consider an agent with a passphrase. |
| Wrong certificate chosen by you | The tool verifies the key matches and the chain verifies; it cannot know the certificate is the one you *meant*. `--dry-run` shows what it will deploy. |
| Time-of-check/time-of-use on the BIG-IP | A concurrent administrator changing the same profiles during a run. The locks only serialise runs of this tool. The switch is a single transaction, and the verification step catches surprises, but it cannot prevent a human changing the same objects at the same moment. |
| Denial of service by a hostile config author | Out of scope: the config author is trusted to choose targets. |

## 6. Residual risks you should know about

1. **Backups of private keys exist indefinitely up to `keep` runs**, on the BIG-IP and locally. Lower `keep`
   if that is unacceptable, at the cost of a shorter rollback window.
2. **`kill -9` or power loss** cannot run cleanup. A staging directory holding a key can remain on the BIG-IP
   (swept by the next run after two hours; you can remove it by hand: `rm -rf /var/tmp/f5-cert-push.*`), and
   a scratch directory can remain locally if tmpfs is not used (it is removed on reboot when it is).
3. **The BIG-IP's own copy of a key** (the installed object, and the filestore) is, of course, on the BIG-IP.
4. **Clock changes** affect the timestamped names and expiry arithmetic; the tool assumes a sane clock.
5. **A stalled run can lose its lock.** If a run stops renewing the BIG-IP lock for `remote_lock_stale_minutes`
   (a frozen host, a long network outage), another run may take it over. The first run is fenced at its next
   step, but a step that was already running on the BIG-IP at that moment completes. The configuration check on
   `remote_lock_stale_minutes` keeps this to a stall far longer than any single step can take.
6. **A BIG-IP that stops answering mid-change** for longer than `remote_timeout` (twice: the step, then the
   read-back) leaves an outcome the tool cannot know; it is reported `CRITICAL` and the lock is kept.
7. **Uploaded keys are unlinked, not overwritten** (section 4.7). On persistent storage the freed blocks remain
   until reused (as they would with `shred` on journalling filesystems and SSDs anyway).
8. **A weakened SSH configuration on the BIG-IP** (accepting password logins, old algorithms) is outside the
   tool's control; `PasswordAuthentication` and the accepted key types are set on the device.

## 7. Hardening checklist

- [ ] Dedicated ECDSA P-384 key for this tool, mode 600, used by nothing else.
- [ ] Key restricted on the BIG-IP: `from="<host ip>" ecdsa-sha2-nistp384 AAAA... f5-cert-push`.
- [ ] BIG-IP host key pinned after comparing its fingerprint with the device's own.
- [ ] `strict_host_key_checking = yes` (the default) in production.
- [ ] Configuration file mode 600, owned by the account that runs the tool.
- [ ] `backup_dir_local` on an encrypted filesystem, mode 0700, with a retention you can defend.
- [ ] Tool run by a dedicated account or root from a hardened host; the host is patched and monitored.
- [ ] `log_file` set, and shipped to your log system. Alert on exit codes 3 and 5.
- [ ] A scheduled `--check` alerts on exit 4 so a failed push is noticed.
- [ ] Old tool keys removed from the BIG-IP when people, hosts or keys change (section 10 of the operations guide).
- [ ] For manual uploads: an SFTP-only, chrooted upload account; `incoming/` owned by root, mode 0750
      (group `certupload`); each upload folder owned by root, mode **3770** (group `certupload`, sticky);
      `/etc/f5-certs` mode 0700 root; `fs.protected_hardlinks = 1`; ideally the upload area on tmpfs or an
      encrypted filesystem.
- [ ] The test suite (docs/TESTING.md) run against a lab BIG-IP after any change to the script.

## 8. Reporting a problem

If you find a security issue, report it privately to the maintainers of your copy of the tool before
publishing details. Include the script version (`--version`), the BIG-IP version, and the exact steps.
