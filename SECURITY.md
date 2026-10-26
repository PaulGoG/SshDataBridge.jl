# Security policy

## Scope

SshDataBridge automates `ssh` and `rsync` sessions to remote compute nodes with passwords stored in a local TOML file. The threat model is a single-user workstation: the configuration file is readable only by its owner, which the loader enforces, and every process that handles a password runs under that same account. The package does not protect against an attacker who already runs code as that user.

## Handling of credentials

- Passwords are read from `config.toml` into memory and never written to persistent storage by the package.
- Remote commands run as `sshpass -d 0 ...`; the password is written to the standard input of `sshpass` and reaches `ssh` through its password prompt. It is not passed as an argument and not exported into any environment.
- `ssh` runs with public-key authentication disabled, the preferred methods pinned to keyboard-interactive and password, and a single password prompt; the probe, mkdir, and purge commands also use `-n`.
- Diagnostic output (`--dry-run`, log lines, `show` of configuration and result objects) never renders passwords.
- Recursive deletion on a remote host is refused for the filesystem root, `/root`, `/home`, the user's home directory, paths under the standard system directories, paths shallower than two components, and paths containing `..`; on the node the removal script also refuses a symbolic link and a directory that contains the home directory. Every purge outside a dry run requires `--yes`.

## Known limitations

- A process running as the same user can read the configuration file and, while `sshpass` runs, the password pipe through `/proc/<pid>/fd`.
- Host key policy `"no"` disables protection against a substituted host; the default `"accept-new"` trusts a host on first contact.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository, or write to the maintainer address listed in `Project.toml`. Do not open a public issue for an undisclosed vulnerability.
