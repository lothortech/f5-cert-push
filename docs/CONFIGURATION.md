# Configuration reference

The configuration file describes your BIG-IPs, your certificates and the deployments that connect
them. Everything the tool does is driven by it. An annotated starting point is in
[`f5-cert-push.conf.example`](../f5-cert-push.conf.example).

Jump to: [File format](#file-format) - [defaults](#defaults) - [f5](#f5) - [cert](#cert) -
[deploy](#deploy) - [Profiles and entries](#profiles-and-entries) - [Verification](#verification-endpoints) -
[Object naming](#object-naming) - [Precedence](#precedence) - [Validation rules](#validation-rules) -
[Recipes](#recipes)

## File format

```ini
# a comment (whole line only)
[section:name]
key = value
key = another value     # NOT a comment: everything after "=" is the value
```

- **INI style.** `[type:name]` section headers, `key = value` lines, blank lines and `#` or `;` comment lines.
- **The file is parsed, never executed.** It is not a shell script and nothing in it is expanded:
  `$HOME`, backticks and `$(...)` are just characters, and they are rejected by validation.
- **Comments must be whole lines.** Text after a value is part of the value.
- **Quotes are optional.** One matching pair of `"..."` or `'...'` around a value is removed.
- **Repeatable settings** (`f5`, `profile`, `verify` in a deployment) may appear on several lines.
  All other settings may appear once per section.
- **Printable ASCII only** in settings. Comments may contain anything. A UTF-8 byte-order mark
  (some Windows editors add one) is rejected with a clear message; save the file without it.
- **Unknown settings are errors.** A typo such as `hots = ...` stops the run instead of being ignored.
- **Permissions.** The file must not be writable by group or others, and must be owned by you or root.
  `chmod 600` it.
- Where to look for it: `--config FILE`, else `./f5-cert-push.conf`, else `/etc/f5-cert-push.conf`.

**Names** (section names, object prefixes, partitions, profile names, entry names) may contain only
letters, digits, dot, underscore and hyphen, must start with a letter or digit, and section names are at
most 64 characters.

**Paths** must be absolute, contain only letters, digits and `. _ / + @ = , : ~ -` (no spaces), and
contain no `..` and no `//`.

## `[defaults]`

Applies to everything. Any of these can also be set in a more specific section where noted.

| Setting | Default | Also in | Meaning |
|---|---|---|---|
| `keep` | `4` | f5, deploy | Backup sets and certificate versions to retain per certificate on each BIG-IP. Older ones are deleted. `0` disables pruning. A version a profile still uses is never deleted: the BIG-IP refuses. |
| `backup_dir_remote` | `/shared/cert-backups` | f5 | Directory **on the BIG-IP** for backups: `<dir>/<object_prefix>/<time>/`. |
| `backup_dir_local` | `/var/backups/f5-cert-push` | | Directory **on this host** for the verified copy: `<dir>/<f5 name>/<object_prefix>/<time>/`. Created mode 0700. |
| `strict_host_key_checking` | `yes` | f5 | `yes`: the BIG-IP's SSH host key must already be known. `accept-new`: trust a BIG-IP the first time it is seen, then pin it. |
| `known_hosts_file` | ssh default | f5 | Use this file instead of `~/.ssh/known_hosts`. Useful to keep the tool's trust separate. |
| `connect_timeout` | `15` | f5 | Seconds to wait for the SSH connection. |
| `remote_timeout` | `300` | f5 | Longest any single step on the BIG-IP may run, in seconds. |
| `connection_reuse` | `yes` | f5 | Reuse one SSH connection for all the steps of a job (faster, and far fewer logins in the BIG-IP's logs). `no` opens a fresh connection per step. |
| `remote_lock_stale_minutes` | `30` | f5 | The tool takes a lock **on the BIG-IP** (`/var/run/f5-cert-push.lock`) so two hosts cannot push to it at once. A lock older than this many minutes is assumed abandoned (a killed run) and is taken over. A normal run takes a few minutes; keep this comfortably above that. |
| `min_days_valid` | `1` | cert | Refuse a certificate that expires within this many days. |
| `auto_rollback` | `yes` | deploy | If a check fails after the profiles were switched, put everything back automatically. |
| `verify_unreachable` | `warn` | deploy | What to do when a verify endpoint gives no TLS answer at all: `warn` or `fail`. |
| `chain_check` | `warn` | cert | Whether the certificate must verify against the supplied chain: `off`, `warn` or `fail`. **Needs OpenSSL 1.1.0+**: older versions cannot do this reliably (their `verify -partial_chain` accepts a mismatched chain), so there the check is skipped with a warning, and `fail` is refused. |
| `fixed_names` | `no` | deploy | Also maintain the four fixed-name objects `<prefix>-cert.pem`, `-chain.pem`, `-fullchain.pem`, `-privkey.pem`. See [Object naming](#object-naming). |
| `allow_standby` | `no` | f5 | Permit deploying to a BIG-IP that reports STANDBY. |
| `log_file` | none | | Append a timestamped log of every run (created mode 0600). |
| `lock_dir` | see right | f5 | Where the per-BIG-IP lock lives. Default `/var/lock/f5-cert-push` for root, otherwise `$XDG_RUNTIME_DIR` or `/tmp`. |

Booleans accept `yes`/`no` (also `true`/`false`, `on`/`off`, `1`/`0`).

## `[f5:NAME]`

One BIG-IP. `NAME` is how deployments refer to it and appears in backup paths and logs.

| Setting | Default | Meaning |
|---|---|---|
| `host` | **required** | Management address or hostname. IPv4, IPv6 and DNS names are accepted. |
| `port` | `22` | SSH port. |
| `user` | `root` | SSH account. It must be able to run `tmsh` **and** read `/config/filestore`; in practice `root`. |
| `ssh_key` | ssh default | Private key file. Used with `IdentitiesOnly`, so only this key is offered. Prefer a key dedicated to this tool. |
| `partition` | `Common` | The BIG-IP partition that holds the certificates and profiles. |
| `known_hosts_file`, `strict_host_key_checking`, `connect_timeout`, `remote_timeout`, `backup_dir_remote`, `keep`, `allow_standby` | from `[defaults]` | Per-BIG-IP overrides. |

Two `[f5:]` sections that point at the same `host:port` are treated as one device for locking: their
deployments run one after another, never at once. The lock exists both on this host and **on the BIG-IP
itself**, so different machines running the tool against the same BIG-IP cannot interleave either.

## `[cert:NAME]`

One certificate: where its files are and what to call it on the BIG-IP.

| Setting | Meaning |
|---|---|
| `le_dir` | A certbot `live/<domain>` directory. Fills in `cert.pem`, `privkey.pem`, `chain.pem`, `fullchain.pem`. |
| `cert` | The **leaf** certificate only (exactly one certificate). |
| `key` | The private key (PEM, unencrypted). |
| `chain` | The intermediate certificates (optional). Leave it out if there are none. |
| `fullchain` | Leaf followed by intermediates. If you give `fullchain` and `key` but no `cert`, the leaf and the chain are split out for you. |
| `object_prefix` | The name used for objects on the BIG-IP. Defaults to the section name. At most 48 characters. |
| `min_days_valid`, `chain_check` | Overrides of the defaults. |

Give **either** `le_dir` **or** explicit files. With `le_dir`, an explicit file setting overrides just that
one file. You need at minimum a key and one of `cert` / `fullchain`.

What is checked (all locally, before the BIG-IP is contacted):

- every file is readable, non-empty and under 1 MiB;
- the key is a single unencrypted PEM private key and **matches the leaf's public key** (RSA and EC);
- the leaf is one certificate, currently valid, not expiring within `min_days_valid`;
- every chain certificate parses, and (per `chain_check`) the leaf verifies against the chain;
- a key file readable by other users produces a warning.

The files are copied once into a private scratch directory and **those copies** are validated and uploaded,
so a renewal landing mid-run cannot make the tool upload something it did not validate.

## `[deploy:NAME]`

Connects one certificate to one or more BIG-IPs and says what to update there.

| Setting | Default | Meaning |
|---|---|---|
| `f5` | **required** | BIG-IP name(s). Repeat the line, or separate with commas. One job runs per BIG-IP. |
| `cert` | **required** | The `[cert:]` section to deploy. |
| `profile` | none | client-ssl profile(s) to update. Repeat for several. See [Profiles and entries](#profiles-and-entries). **Omit entirely** to replace only the fixed-name objects, touching no profile. |
| `verify` | none | After the change, connect here and confirm the new certificate is served. Repeatable. See [Verification](#verification-endpoints). |
| `verify_from` | `f5` | `f5`: probe from the BIG-IP itself. `local`: probe from the host running the tool. |
| `env` | none | A label for `--env`. |
| `enabled` | `yes` | `no` skips the deployment even with `--all`. |
| `keep`, `auto_rollback`, `fixed_names`, `verify_unreachable` | from `[defaults]` | Per-deployment overrides. |

Two enabled deployments may not manage the same profile (or the same profile entry) on the same BIG-IP, and
may not use the same `object_prefix` for different certificates on the same BIG-IP. The tool refuses such a
file at load time.

## Profiles and entries

A client-ssl profile holds one or more **cert-key-chain entries**. Most profiles have exactly one; a
profile can hold both an RSA and an ECDSA entry (a profile cannot hold two of the same key type).

| `profile =` | Means |
|---|---|
| `www-clientssl` | The profile in the BIG-IP partition named by the `[f5:]` section. If it has one entry, that entry is updated. If it has several, the entries whose certificate is named like this certificate's objects (`<prefix>-cert[-<time>].pem`) are candidates; exactly one must match, or the tool stops and asks you to name the entry. |
| `www-clientssl:rsa_entry` | That specific entry. Use this for dual RSA+ECDSA profiles. The other entries are **not touched**. |
| `/Part/www-clientssl` | A profile in another partition. |
| `/Part/www-clientssl:rsa_entry` | Both. |

Run `--discover --f5 NAME` to list every profile and entry with its current certificate and expiry.

The tool updates the entry's certificate, chain and key, and keeps its entry name. If the certificate has
no chain, the entry's chain is set to `none`.

It **refuses**, with an explanation and before changing anything:

- a profile that does not exist;
- a profile that **inherits** its certificate from a parent (`inherit-certkeychain true`): update the parent instead;
- an entry that does not exist;
- an ambiguous multi-entry profile with no entry named;
- an entry protected by a key **passphrase**.

## Verification endpoints

```ini
verify = 10.1.10.10:443                      # HOST:PORT
verify = 10.1.10.11:443 www.example.com      # HOST:PORT SNI-NAME
verify = [2001:db8::1]:443 api.example.com   # IPv6 in brackets
```

After the profiles are switched the tool connects to each endpoint, reads the certificate it presents and
compares its SHA-256 fingerprint with the one just deployed. It retries three times (a few seconds apart) to
allow for the virtual server picking up the change.

- **Wrong certificate served:** always a failure (and rolled back if `auto_rollback = yes`).
- **No TLS answer:** a warning, or a failure with `verify_unreachable = fail`.
- **SNI:** the name after the address if given, otherwise the certificate's first non-wildcard DNS name, otherwise its CN, otherwise none.
- **`verify_from = f5`** runs `openssl s_client` on the BIG-IP, which reaches virtual-server addresses that
  are not routable from your host. **`local`** runs it on the host running the tool, for addresses you can reach directly.
- A dual RSA+ECDSA profile presents one or the other depending on the client; the probe sees whichever the
  default handshake negotiates.

## Object naming

For a certificate with `object_prefix = P`, each deployment creates, stamped with the run time `T` in **UTC**
(`YYYYMMDD-HHMMSS`; UTC so the names sort chronologically through daylight-saving changes):

```
P-cert-T.pem    P-chain-T.pem (only if there is a chain)    P-privkey-T.pem
```

and repoints the profiles at them. The previous objects are left alone, which is what makes rollback
instant and safe. Only the newest `keep` sets are retained; the BIG-IP itself refuses to delete one that a
profile still references.

If a deployment lists **no profile**, or sets `fixed_names = yes`, the tool also maintains
`P-cert.pem`, `P-chain.pem`, `P-fullchain.pem` and `P-privkey.pem`, **overwriting them in place**. Use this
only for consumers that reference those fixed names (another system, iRules, an APM policy). Overwriting is
not atomic: a profile bound directly to a fixed-name object can briefly see a new key with the old
certificate. That is why fixed names are optional and off by default, and why profile deployments use
versioned names.

In a non-Common partition, objects are created in that partition (`/Part/P-cert-T.pem`).

## Precedence

For each setting the first value found wins:

`[deploy:]` &rarr; `[f5:]` or `[cert:]` (whichever defines that setting) &rarr; `[defaults]` &rarr; built-in default.

Command-line options choose *what* to run; they do not override settings, with the exceptions of `--force`,
`--dry-run` and `--fail-fast`, which change behaviour for that run.

## Validation rules

Everything is validated when the file is loaded, and **all** problems are reported together, each with its
file and line number, before anything runs. Exit code 2 means the file was not used.

The list of what is enforced: unknown sections and settings; duplicate sections and duplicate single-valued
settings; settings outside a section; required settings; references to undefined `[f5:]` / `[cert:]`
sections; value formats (hosts, users, ports, paths, names, numbers, booleans, enumerations, profile and
verify syntax); non-printable or non-ASCII characters; and the conflict rules above. Shell metacharacters,
spaces, `..`, `$`, quotes, backticks and newlines are not permitted in any value that reaches ssh or tmsh.

## Recipes

**Two BIG-IPs, same certificate, same profile names**

```ini
[f5:a]
host = 10.0.0.11
ssh_key = /root/.ssh/f5_push_ecdsa
[f5:b]
host = 10.0.0.12
ssh_key = /root/.ssh/f5_push_ecdsa

[deploy:www]
f5 = a, b
cert = wildcard
profile = www-clientssl
```

**One certificate for many profiles, atomically**

```ini
[deploy:www]
f5 = a
cert = wildcard
profile = www-clientssl
profile = api-clientssl
profile = /Common/legacy-clientssl
```
All three switch in a single transaction; if any one cannot, none changes.

**A dual RSA + ECDSA profile: update only the RSA certificate**

```ini
[cert:rsa]
cert = /etc/pki/site-rsa.crt
key  = /etc/pki/site-rsa.key
[deploy:site-rsa]
f5 = a
cert = rsa
profile = site-clientssl:rsa_entry
```

**A certificate you only have as a fullchain**

```ini
[cert:partner]
fullchain = /etc/pki/partner/fullchain.pem
key       = /etc/pki/partner/privkey.pem
```

**Environments: rehearse in the lab, then production**

```ini
[deploy:www-lab]
env = lab
...
[deploy:www-prod]
env = prod
...
```
```bash
f5-cert-push.sh --env lab
f5-cert-push.sh --env prod --check
f5-cert-push.sh --env prod
```

**Verify from the host, for a virtual server you can reach directly**

```ini
verify = 203.0.113.10:443 www.example.com
verify_from = local
verify_unreachable = fail
```

**Keep more history for one important certificate**

```ini
[deploy:payments]
keep = 10
```
