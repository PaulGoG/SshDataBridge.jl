# Security policy

## Scope

SshDataBridge automates `ssh` and `rsync` sessions to remote compute nodes using passwords stored in a local TOML file. The threat model is a single-user workstation: the configuration file is readable only by its owner, and every process that handles a password runs under that same account. The package does not protect against an attacker who already runs code as that user.

## Handling of credentials

- Passwords are read from `config.toml` into memory and are never written to persistent storage by the package.
- Remote commands are executed as `sshpass -d 0 ...`; the password is written to the standard input of `sshpass` and reaches `ssh` through its password prompt. It is not passed as an argument and not exported into any environment.
- Diagnostic output (`--dry-run`, log lines, `show` of configuration and result objects) never renders passwords.
- Every ssh invocation uses `-n` and allows a single password prompt.
- Recursive deletion on a remote host is refused for the filesystem root, `/root`, `/home`, the user's home directory, paths under the standard system directories, paths shallower than two components, and paths containing `..`. Deleting from the command line requires `--yes`.

## Known limitations

- Any process running under the same user can read the configuration file and can inspect `sshpass` while it runs.
- Host key policy `"no"` disables protection against a substituted host; the default `"accept-new"` trusts a host on first contact.
- The password is delivered over a pipe; a process running as the same user can inspect that pipe through `/proc/<pid>/fd` while `sshpass` runs.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository, or write to the maintainer address listed in `Project.toml`. Please do not open a public issue for an undisclosed vulnerability.
