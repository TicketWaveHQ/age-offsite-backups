# Contributing

Thank you for helping. This is a small tool that guards other people's
backups, so changes are judged first on whether they keep its promises:
nothing leaves the machine unencrypted, failures are never hidden, and
nothing in storage is deleted or replaced.

## Before you open a pull request

1. Run the tests. They are offline and need only age:

   ```sh
   tests/run.sh
   ```

2. Add a test for any change in behaviour, in `tests/test_push.sh` or
   `tests/test_verify.sh`. A test is a `test_*` function. It passes by
   returning 0, and any failing command ends it. `tests/helpers.sh` sets up
   throwaway keys, a source directory and storage for each test.
3. For a change to a failure path, check that the test fails without your
   change, not only that it passes with it.
4. Run [ShellCheck](https://www.shellcheck.net) on what you changed if you
   have it.

## How the code is written

- **Portable bash.** bash 4 or later is the target, but the scripts also run
  on the bash 3.2 shipped with macOS. Do not use associative arrays,
  `mapfile`, `${var,,}` or other features newer than bash 3.2, and guard
  empty arrays under `set -u`.
- **GNU and BSD alike.** Avoid options that exist on only one of them, such
  as `find -printf`, `stat -c` and `sed -i` without a suffix.
- **No new dependencies.** age, plus the AWS CLI or rclone, plus standard
  tools. Anything else needs a strong reason.
- **Fail closed.** When in doubt, refuse and exit non-zero. "Could not check"
  must never be read as "nothing to do".
- **No secrets in output.** Never print a key, a credential or a decrypted
  file. Pass a private key to age through a pipe or a file, never as a
  command-line argument.
- **Text.** UK English, and no em-dashes in anything a user reads.

## Reporting problems

Open an issue with what you ran, what you expected and what happened. Use
example names (`my-backups-bucket`, `s3.example.com`) and **never paste a
private key, a credential, or a real bucket listing** into an issue.

Security problems go privately, not in an issue: see [SECURITY.md](SECURITY.md).

By contributing you agree that your contribution is released under the
project's [MIT License](LICENSE).
