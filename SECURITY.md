# Security policy

## Reporting a vulnerability

Please report security problems privately, by email to
**hello@ticketwavehq.com**, and not in a public issue. See also
[ticketwavehq.com/security](https://ticketwavehq.com/security).

Include, where you can:

- the version (`bin/backup-push --version`) and how you ran it;
- what an attacker could do, and what they would need first;
- steps to reproduce, using throwaway keys and example names.

Never send a real private key, a storage credential or real backup data.

## What counts

Anything that breaks the promises in the [threat model](README.md#threat-model),
for example:

- plaintext leaving the backup host, or a way to make `backup-push` upload
  without encrypting;
- a private key or credential written to a log, to the disk or to a process's
  command line;
- `backup-push` reporting success when an upload or a check failed;
- `backup-verify` reporting `OK` for an object that does not decrypt to the
  recorded bytes;
- a config file causing code to run.

The limits listed under "What this does not protect against" are known and
documented, and are not vulnerabilities in themselves. Problems in age, the
AWS CLI or rclone belong with those projects.

## Supported versions

Fixes are made on the latest release.
