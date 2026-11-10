# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-10

First public release.

### Added

- `backup-push`: encrypts each finished file with age to every recipient in
  the recipients file and uploads it once as `<name>.age`, with its SHA-256
  as `.<name>.sha256.age`, also encrypted. Skips what is already stored,
  leaves recently changed files and dotfiles for later, checks every upload
  at its exact size, and fails closed when age or a usable recipients file
  is missing. Refuses a recipients file that holds a private key or fewer
  than `BACKUP_MIN_RECIPIENTS` recipients. Fails if any object under its
  prefix is not encrypted, optionally only for uploads since
  `BACKUP_ENCRYPTED_SINCE`. Ends with `N ok, M failed` and a non-zero exit
  status on any failure.
- `backup-verify`: downloads, decrypts and hashes every encrypted object in a
  stream, and compares it with its recorded SHA-256 or, for archives from
  before encryption, with its plaintext original. Takes the private key from
  a file or from standard input, keeping it in memory. Lists and reads only.
- Storage backends: the AWS CLI (any S3-compatible endpoint), rclone, and a
  local directory.
- Configuration from the environment or a `KEY=VALUE` file that is parsed,
  never executed.
- An offline test suite in plain bash, with a stub for the AWS CLI, run in CI
  on Ubuntu and macOS.
- Documentation: threat model, configuration reference, restore drill and a
  key-handling guide.

[1.0.0]: https://github.com/TicketWaveHQ/age-offsite-backups/releases/tag/v1.0.0
