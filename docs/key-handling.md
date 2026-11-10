# Key handling

The encryption is only as good as the custody of the private keys. These are
the rules this toolkit is built around.

## 1. Two recipients, always

Every backup is encrypted to two public keys, and either matching private key
decrypts it on its own. One key can then be lost, destroyed or locked away
without losing the backups. `backup-push` refuses to run with fewer than
`BACKUP_MIN_RECIPIENTS` distinct recipients (default 2). Lower it only if you
have decided, on purpose, that one key is enough.

Make each key on the machine where it will live, or on a trusted offline
machine, and never on the backup host:

```sh
age-keygen -o restore-key-1.txt
# age-keygen prints the public key ("Public key: age1...") on standard error.
# Later, on the same machine: age-keygen -y restore-key-1.txt
```

Copy only the public `age1...` lines to the backup host's recipients file
([example](../examples/recipients.txt.example)). Public keys are not secret.

## 2. Where each private key lives

Keep the two private keys apart, so that no single loss, theft or fire takes
both:

| | Restore key 1 | Restore key 2 |
| --- | --- | --- |
| Purpose | routine verification and the first choice in a recovery | the fall-back if key 1 is lost or exposed |
| Held by | the person responsible for restores | someone else, or the same person in a different place |
| Kept | on the recovery machine, on encrypted storage, or passphrase-protected with `age -p` | offline: an encrypted USB stick or a paper copy in a safe or another site |

An age private key is one short line, so a paper copy works and does not
depend on any device still working. Whatever you choose, write down where
each key is, and make sure more than one person can find out.

To keep a key passphrase-protected and still use it without writing it to
disk in the clear:

```sh
age -p -o restore-key-1.txt.age restore-key-1.txt   # once, then destroy the plain copy
age -d restore-key-1.txt.age | bin/backup-verify --config verify.conf --identity-stdin
```

## 3. Never on the backup host

The backup host holds the recipients file (public keys) and the write-only
storage credentials. It must never hold a private key. With no private key
there, an attacker who takes the host and its storage credentials still
cannot read what is already stored. `backup-push` refuses to run if a private
key (`AGE-SECRET-KEY-...`) is in the recipients file. If one ever was, treat
that key as exposed (see section 5).

Also keep private keys out of the bucket, out of the same password-manager
entry or envelope as the storage credentials, and out of the repository that
configures the backup host.

## 4. Test restores regularly

A key nobody has used for a year is a key nobody knows works. Run
`backup-verify` on the recovery machine on a schedule, monthly to start with,
and do the full [restore drill](../README.md#restore-drill). Alternate between
key 1 and key 2, so each one is proved in turn. Record the date, the key and
the result.

During a verify, the key should be in memory or on a tmpfs, never on an
ordinary disk: pipe it in with `--identity-stdin`, or point `--identity` at a
file on a tmpfs or removable media, and remove that file afterwards.

## 5. Replacing a key

Old backups stay encrypted to the keys they were made with: changing the
recipients file only affects new uploads, and this toolkit does not
re-encrypt anything.

- **Routine replacement:** make the new key, add its public key to the
  recipients file, remove the old one, and keep the old private key for as
  long as backups made with it are retained.
- **A lost key:** replace it as above. Until the old backups age out, they
  rest on the remaining key alone, so check that key works today.
- **An exposed key:** replace it at once. Anyone holding it can read every
  backup made with it, so consider whether those backups must be deleted, or
  re-made under the new keys, before they reach the end of their retention.
