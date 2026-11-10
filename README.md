# age-offsite-backups

Encrypt backup files with [age](https://age-encryption.org) on the machine
that makes them, upload them to S3-compatible object storage, and prove on a
separate machine that every one of them still decrypts to the original bytes.

It is two bash scripts:

- **`backup-push`** runs on the backup host. It encrypts each finished file to
  two public keys, uploads it once, checks the upload, and fails loudly if
  anything unencrypted ever appears in its part of the bucket. The backup host
  holds public keys only, so it can write backups it cannot read.
- **`backup-verify`** runs on a recovery machine that holds a private key. It
  downloads every encrypted object, decrypts it, and compares its SHA-256 with
  the one recorded when it was pushed.

**Who it is for:** people who already produce backup files (database dumps,
tarballs, archive segments) and want an off-site copy that the storage
provider, and anyone who gets hold of the storage credentials, cannot read.
It suits a small team or a single operator who would rather read about a
thousand lines of commented bash than trust a larger system.

**What it is not:** a backup program. It does not choose what to back up,
deduplicate, take snapshots or prune old copies. It ships finished files and
proves they can be restored. If you want all of that in one tool, restic, Borg
and Kopia are built for it.

Restoring needs nothing from this repository: any copy can be fetched with the
AWS CLI or rclone and decrypted with `age -d`.

## 60-second start

No cloud account needed: this uses the `local` backend, which writes to a
directory. You need bash, age and a clone of this repository.

```sh
git clone https://github.com/TicketWaveHQ/age-offsite-backups.git
cd age-offsite-backups

mkdir -p /tmp/aob-demo/keys /tmp/aob-demo/data /tmp/aob-demo/offsite
echo "hello" > /tmp/aob-demo/data/example.txt

# Two restore keys. In real use these are made on trusted machines, never on
# the backup host; see docs/key-handling.md.
age-keygen -o /tmp/aob-demo/keys/one.txt 2>/dev/null
age-keygen -o /tmp/aob-demo/keys/two.txt 2>/dev/null
{ age-keygen -y /tmp/aob-demo/keys/one.txt; age-keygen -y /tmp/aob-demo/keys/two.txt; } > /tmp/aob-demo/recipients.txt

export BACKUP_BACKEND=local BACKUP_LOCAL_DIR=/tmp/aob-demo/offsite BACKUP_PREFIX=demo
export BACKUP_RECIPIENTS_FILE=/tmp/aob-demo/recipients.txt BACKUP_SETTLE_MINUTES=0

bin/backup-push /tmp/aob-demo/data
bin/backup-verify --identity /tmp/aob-demo/keys/two.txt
```

You should see:

```text
  /tmp/aob-demo/data -> 1 encrypted and uploaded, 0 left for the next run, 2 objects stored
[2026-11-10T21:37:08Z] backup-push: 1 ok, 0 failed
objects: 2; encrypted files: 1; checksums: 1; plaintext: 0, of which 0 have no encrypted copy
OK demo/tmp/aob-demo/data/example.txt.age
mismatch: 0; error: 0; no checksum: 0; missing: 0
[2026-11-10T21:37:09Z] backup-verify: 1 ok, 0 failed
```

The file was encrypted with key one and key two as recipients, and decrypted
with key two alone. Run `backup-push` again and it uploads nothing. Delete
`/tmp/aob-demo` when you are done: it holds private keys.

### Moving to real storage

1. Make two restore keys on trusted machines, not on the backup host
   ([key handling](docs/key-handling.md)).
2. On the backup host, put the two **public** keys in
   `/etc/age-offsite-backups/recipients.txt`
   ([example](examples/recipients.txt.example)).
3. Copy [`examples/backup.conf.example`](examples/backup.conf.example) to
   `/etc/age-offsite-backups/backup.conf` and set the bucket, endpoint and
   source directories. Give the AWS CLI credentials that can list and write
   the bucket, and no more ([storage credentials](#storage-credentials)).
4. Run `bin/backup-push` by hand once, then [on a schedule](#running-on-a-schedule).
5. On a recovery machine, run `bin/backup-verify` with read-only credentials
   ([example](examples/verify.conf.example)) and one of the private keys. Then
   do the [restore drill](#restore-drill).

## How it works

### Object layout

For a file `/srv/backups/postgres/2026-11-10.sql.gz` on a host whose prefix
is `backup-host-1`:

```text
backup-host-1/srv/backups/postgres/2026-11-10.sql.gz.age           the file, encrypted
backup-host-1/srv/backups/postgres/.2026-11-10.sql.gz.sha256.age   its SHA-256, encrypted
```

The key is the prefix, then the source directory's absolute path, then the
file's path inside it. The checksum object's name starts with a dot because
`backup-push` never uploads dotfiles, so no backup file can ever be stored
under that name. That keeps checksums apart from real files such as
`dump.sql.gz.sha256`.

The checksum object holds one line in `sha256sum` format
(`<64 hex digits>  <file name>`). It is encrypted too, because a plain hash
lets anyone who can list the bucket confirm a guess about a file's contents.

### What `backup-push` does

1. **Fail closed.** Before anything is listed or uploaded it checks that age
   is installed, that the recipients file exists, holds no private key, is
   accepted by age (it encrypts an empty input to it) and lists at least
   `BACKUP_MIN_RECIPIENTS` distinct recipients (default 2). If any check
   fails, nothing is uploaded and the run fails. There is no plaintext
   fallback.
2. **List what is stored** under the source's prefix. A failed listing fails
   that source; it is never taken to mean "nothing stored yet".
3. **Decide what is needed.** For every regular file under the source
   directory:
   - a dotfile, or anything under a dot-directory, is skipped (these are
     usually temporary files still being written, such as rsync's);
   - a file with both objects stored is done;
   - a file changed in the last `BACKUP_SETTLE_MINUTES` (default 15) is left
     for the next run, so a dump still being written is not shipped half
     done;
   - otherwise whichever of the two objects is missing is made.
4. **Encrypt into a staging directory**, never in place, with
   `age -R recipients.txt`. Encryption happens on this machine; plaintext
   never leaves it.
5. **Upload the staging directory**, then **list again** and check that every
   staged object is stored at its exact size. The upload command's exit
   status alone is not taken as proof.
6. **Check for plaintext.** It lists the machine's whole prefix and fails if
   any object there does not end in `.age`. If you are adopting this tool on a
   prefix that already holds plaintext, set `BACKUP_ENCRYPTED_SINCE`: then only
   plaintext uploaded at or after that time fails the run, and older plaintext
   is reported as a note. A return to plaintext (an old script restored, a
   hand-made upload) becomes an alarm on the next run.
7. **Report.** One line per source, then
   `[<UTC time>] backup-push: N ok, M failed`, where N counts sources pushed
   cleanly and M counts failures. The exit status is 1 if anything failed.
   After a clean run it writes the time to `BACKUP_HEARTBEAT_FILE`, if set.

It never deletes or replaces anything in storage. A file that is changed
after it was uploaded is **not** uploaded again, so give each backup a new
name (a date in the file name is the usual way).

### What `backup-verify` does

1. Loads one private key: from a file you name (`--identity`), or from
   standard input (`--identity-stdin`), in which case the key stays in the
   process's memory and reaches age through a pipe, never through a file
   this tool writes. It never appears in a command line.
2. Lists everything under the prefixes you give (default: the whole bucket).
3. For every `<name>.age`, streams download, decryption and hashing in one
   pipe, so decrypted data never touches the disk, and compares the hash with
   the decrypted `.<name>.sha256.age`. If there is no checksum object but a
   plaintext `<name>` is stored (an archive from before encryption), it
   compares with that instead.
4. Prints one line per object and a summary:

   | Line | Meaning |
   | --- | --- |
   | `OK <key>` | decrypted, and the SHA-256 matches |
   | `MISMATCH <key>` | decrypted, but the SHA-256 differs |
   | `ERROR <key> (...)` | could not be downloaded or decrypted, or its checksum could not be read |
   | `NOSUM <key>` | decrypts, but there is nothing to compare it with |
   | `MISSING <key>` | its checksum is stored, the encrypted file is not |

   Report lines go to standard output, so `backup-verify ... > report.txt`
   gives a clean record. The header and the summary
   `backup-verify: N ok, M failed` go to standard error. The exit status is 0
   only if every object is `OK` and at least one was checked: finding nothing
   to verify is a failure, because it usually means the wrong bucket or
   prefix.

It only lists and reads. It never writes to, replaces or deletes from storage.

## Threat model

### What this protects against

- **Reading the backups from storage.** The storage provider, its staff,
  anyone who obtains a copy of the bucket, and anyone holding any credential
  for it, including the read-only recovery credential, see only age
  ciphertext. Encryption happens before upload, on the backup host.
- **Stealing the backup host's storage credentials.** The backup host has no
  private key, so its credentials do not unlock what is already stored.
- **Losing one private key.** Every object is encrypted to at least two
  recipients, and either private key decrypts on its own.
- **A quiet return to plaintext.** Any unencrypted object under the host's
  prefix fails the next run.
- **Silent damage.** Uploads are checked at their exact size. age encryption
  is authenticated, so a changed or truncated object fails to decrypt, and
  `backup-verify` checks every object against its recorded SHA-256.
- **Discovering, during a disaster, that restores do not work.** Running
  `backup-verify` regularly on the recovery machine proves the key, the
  credentials, the tools and the data together.

### What this does not protect against

- **A compromised backup host.** An attacker there can read the plaintext
  backups on its disk, change what is backed up from then on, and use its
  storage credentials. This tool protects the off-site copy, not the source.
- **Anyone who can write to the bucket.** Public keys are public. Anyone with
  write access can upload a validly encrypted file, with a matching checksum
  object, in place of a real one, and `backup-verify` will report it as `OK`.
  Encryption gives confidentiality, not proof of who made the file. Use
  bucket versioning or object lock where your provider offers it, keep write
  credentials on the backup host only, and do not give them permission to
  delete.
- **Deletion and lock-out.** A provider outage, a closed account or a deleted
  bucket loses this copy. Keep at least one other copy somewhere else.
- **Losing both private keys.** Then the backups are gone. See
  [key handling](docs/key-handling.md).
- **Metadata.** Object names, sizes, upload times and counts are visible to
  anyone who can list the bucket. The names include your file names and
  directory paths. Choose names that do not themselves reveal what you need
  to keep private.
- **Plaintext with a `.age` name.** The plaintext check looks at names, not
  contents, because the backup host's credentials should not be able to read
  objects back. A plaintext file uploaded by hand under a `.age` name passes
  that check, though `backup-verify` will report it as `ERROR`.
- **Quantum computers.** Ordinary age keys use X25519, which a large enough
  quantum computer could break, so ciphertext stored today could be read
  then. Recent age releases (1.3.2 was checked) can make post-quantum hybrid
  keys with `age-keygen -pq`. age refuses to mix post-quantum and classic
  recipients in one file, so either both restore keys are post-quantum or
  neither is, and every machine involved needs an age version that supports
  them.

## Configuration reference

Settings come from the environment and from a config file: `--config FILE`,
else `$BACKUP_CONFIG`, else `/etc/age-offsite-backups/backup.conf` if it
exists. The file holds `KEY=VALUE` lines and whole-line `#` comments. It is
parsed, not executed: values are taken literally, with optional surrounding
quotes removed, and an unknown key is an error, so a typo cannot silently do
nothing. A setting in the environment wins over the file.

| Setting | Used by | Default | Meaning |
| --- | --- | --- | --- |
| `BACKUP_BACKEND` | both | `aws` | `aws`, `rclone` or `local` |
| `BACKUP_BUCKET` | both (aws) | none | bucket name, e.g. `my-backups-bucket` (no `s3://`, no path) |
| `BACKUP_S3_ENDPOINT` | both (aws) | none (AWS S3) | endpoint URL for S3-compatible storage, e.g. `https://s3.example.com` |
| `BACKUP_RCLONE_REMOTE` | both (rclone) | none | remote and bucket, e.g. `offsite:my-backups-bucket` |
| `BACKUP_LOCAL_DIR` | both (local) | none | target directory, which must exist |
| `BACKUP_PREFIX` | push | short host name | key prefix for this machine |
| `BACKUP_SOURCES` | push | none | space-separated directories, used when none are given as arguments |
| `BACKUP_RECIPIENTS_FILE` | push | `/etc/age-offsite-backups/recipients.txt` | age recipients file: public keys only |
| `BACKUP_MIN_RECIPIENTS` | push | `2` | refuse to run with fewer distinct recipients |
| `BACKUP_SETTLE_MINUTES` | push | `15` | leave files changed more recently than this |
| `BACKUP_ENCRYPTED_SINCE` | push | none | `YYYY-MM-DD` or `YYYY-MM-DD HH:MM:SS`, UTC; see step 6 above. Unset: any plaintext fails |
| `BACKUP_STAGING_DIR` | push | `$TMPDIR`, else `/var/tmp` | where encrypted copies are staged; needs room for one run's new files |
| `BACKUP_HEARTBEAT_FILE` | push | none | written with the Unix time after each clean run |
| `BACKUP_IDENTITY_FILE` | verify | none | private key file, if `--identity` is not given |
| `BACKUP_VERIFY_JOBS` | verify | `4` | objects checked in parallel (1 to 64) |
| `BACKUP_AGE` | both | `age` | the age command |
| `AWS_PROFILE`, `AWS_REGION`, `AWS_DEFAULT_REGION`, `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE` | both (aws) | none | passed to the AWS CLI |
| `RCLONE_CONFIG` | both (rclone) | none | passed to rclone |

This toolkit never reads a storage credential. The AWS CLI and rclone find
their own, in their usual places (their configuration files, environment
variables or an instance role), so credentials are not accepted in this
config file.

Command lines:

```text
backup-push   [--config FILE] [SOURCE_DIR ...]
backup-verify [--config FILE] (--identity FILE | --identity-stdin) [--jobs N] [PREFIX ...]
```

Both accept `--help` and `--version`. Exit status: 0 success, 1 a failure,
2 a usage or configuration error.

## Storage backends

- **`aws` (primary):** the [AWS CLI](https://aws.amazon.com/cli/), using
  `aws s3 ls --recursive` and `aws s3 cp`. Set `BACKUP_S3_ENDPOINT` for any
  S3-compatible provider. Listing times are read in UTC.
- **`rclone`:** any [rclone](https://rclone.org) remote. Listing uses
  `--use-server-modtime`, so the plaintext check sees when an object was
  uploaded rather than the source file's time that rclone stores with it.
  Uploads use `--immutable`, so an existing object is never replaced.
- **`local`:** a directory, such as a mounted disk. Files are copied into a
  holding directory and renamed into place, so an interrupted copy never
  leaves a short file under its final name. The plaintext check uses file
  modification times, which whoever writes the directory can change. The
  offline tests use this backend.

## Storage credentials

Give each machine the least it needs. Providers name permissions differently;
on AWS S3 these are the actions involved.

| Machine | Needs | AWS S3 actions | Must not have |
| --- | --- | --- | --- |
| backup host | list the bucket, write objects | `s3:ListBucket`, `s3:PutObject` | read, delete |
| recovery machine | list the bucket, read objects | `s3:ListBucket`, `s3:GetObject` | write, delete |

The backup host needs no read access: it decides what to skip from the
listing alone. Where your provider supports bucket versioning or object lock,
turn it on, so that a credential that can write still cannot destroy what is
already stored.

## Running on a schedule

`backup-push` exits non-zero on any failure, so connect that to whatever
already alerts you. With cron, after the job that writes your backups:

```cron
30 2 * * *  /opt/age-offsite-backups/bin/backup-push >> /var/log/backup-push.log 2>&1 || echo "backup-push failed" | mail -s "backup-push failed" ops@example.com
```

With systemd, run it from a service unit with `OnFailure=` pointing at your
alerting unit. In both cases also alarm on `BACKUP_HEARTBEAT_FILE` getting
old, which catches the job that silently stopped running at all.

Do not run two pushes for the same prefix at the same time.

## Restore drill

A checksum proves the bytes came back. It does not prove the backup is
usable. Do this drill on a schedule (monthly is a reasonable start) and after
any change to keys, credentials or the backup format, and alternate between
the two private keys so that both are known to work.

1. **On the recovery machine**, not the backup host, install age and the
   AWS CLI (or rclone), and configure the read-only credentials
   ([example](examples/verify.conf.example)).
2. **Bring one private key** without copying it to the disk, for example from
   a passphrase-encrypted copy:

   ```sh
   age -d restore-key-1.txt.age | bin/backup-verify --config verify.conf --identity-stdin > verify-report.txt
   ```

   Every line of `verify-report.txt` should start with `OK`, and the summary
   should read `M failed` with M = 0.
3. **Restore one real file** with plain tools, as you would in a disaster
   with this repository unavailable:

   ```sh
   aws --endpoint-url https://s3.example.com s3 cp \
     s3://my-backups-bucket/backup-host-1/srv/backups/postgres/2026-11-10.sql.gz.age - \
     | age -d -i restore-key-1.txt > 2026-11-10.sql.gz
   ```

   (With rclone: `rclone cat offsite:my-backups-bucket/<key> | age -d -i ...`.)
   Here the key is read from a file: keep that file on encrypted or removable
   storage or a tmpfs, and delete it afterwards.
4. **Use it.** Load the dump into a scratch database, unpack the archive, open
   the files. Check that the data is as recent as you expect.
5. **Write it down:** the date, which key was used, the verify summary, what
   was restored and how long it took. The next drill, and the real recovery,
   start from those notes.
6. **Clean up** the restored data and any key material on the recovery
   machine.

## Requirements

- bash 4 or later. The scripts keep to what the bash 3.2 shipped with macOS
  also runs, and the tests pass there.
- [age](https://age-encryption.org) (development and tests used 1.3.2).
- The AWS CLI, or rclone, for real storage.
- Standard tools found on any Linux or macOS system: `awk`, `find`, `sort`,
  `comm`, `cut`, `sed`, `grep`, `mktemp`, and one of `sha256sum`, `shasum` or
  `openssl`. GNU and BSD versions both work.

No installation step is needed: run the scripts from a clone, or symlink
`bin/backup-push` and `bin/backup-verify` into your `PATH`. They find `lib/`
through the symlink.

## Tests

```sh
tests/run.sh            # everything
tests/run.sh verify     # only tests whose name contains "verify"
```

The suite is plain bash with no test framework to install, and it runs
offline: it needs age and age-keygen and nothing else. Each test gets a fresh
temporary directory and freshly generated throwaway keys, deleted when it
ends. No private key is stored in this repository.

- The `local` backend is exercised directly.
- The `aws` backend runs against [`tests/stub/aws`](tests/stub/aws), a
  stand-in that implements the two AWS CLI commands the scripts use, with
  injectable failures (a failed listing, a failed upload, a truncated
  upload). It is not the real AWS CLI, so it shows the scripts' logic, not a
  given provider's behaviour.
- The `rclone` tests run if rclone is installed, against a local directory,
  and are skipped otherwise.

The tests cover encryption to both keys, skip-existing, settling, dotfiles,
every fail-closed path, plaintext detection, upload failures and redaction,
truncated uploads, config parsing (including that the file is never
executed), and every `backup-verify` outcome. CI runs them on Ubuntu and
macOS ([workflow](.github/workflows/ci.yml)).

## Limitations

- No retention or pruning: nothing is ever deleted. Use your provider's
  lifecycle rules.
- No restore command: restoring is `aws s3 cp` (or `rclone cat`) piped into
  `age -d`, on purpose.
- A file is uploaded once. If it changes afterwards, the change is not
  uploaded.
- Symbolic links under a source directory are not followed, and files with a
  newline in their name are refused.
- No locking: do not run two pushes for the same prefix at once.
- Each push lists its prefix in full, so very large prefixes make for long
  listings.

## Contributing, security and licence

- [CONTRIBUTING.md](CONTRIBUTING.md): how to run the tests and what a change
  needs.
- [SECURITY.md](SECURITY.md): how to report a vulnerability privately.
- [CHANGELOG.md](CHANGELOG.md).
- Released under the [MIT License](LICENSE). If you cite it, see
  [CITATION.cff](CITATION.cff).

Maintained by [TicketWave HQ](https://ticketwavehq.com), a UK company (Companies House 17143167).
