# Security policy

## Scope

SshDataBridge automates `ssh` and `rsync` sessions to remote compute nodes, authenticated with passwords stored in a local TOML file or by `ssh` itself with keys. It assumes a single-user workstation: the loader refuses a configuration file that anyone but its owner can access, and every process that handles a password runs under that same account. It does not protect against an attacker who already runs code as that user.

## Handling of credentials

- Passwords are read from `config.toml` into memory and never written to persistent storage by the package.
- Remote commands of a password target run as `sshpass -d 0 ...`; the password is written to the standard input of `sshpass` and reaches `ssh` through its password prompt. It is not passed as an argument and not exported into any environment.
- For a password target `ssh` runs with public-key authentication disabled, the preferred methods pinned to keyboard-interactive and password, and a single password prompt. The probe, claim, and purge commands of every target use `-n`.
- A key target hands the package no secret. Its commands run with `BatchMode=yes` and with `SSH_ASKPASS=false`, `SSH_ASKPASS_REQUIRE=force` in their environment, which the ssh of a jump host inherits, so that no prompt on the route reaches the terminal or a desktop dialog. A configured identity file is checked for its mode and never read.
- Diagnostic output (`--dry-run`, log lines, error messages, `show` of configuration and result objects) never renders passwords. A syntax error in the configuration file is reported by its line number, without the line.

## Remote deletion

Recursive deletion on a remote host is refused for the filesystem root, `/root`, `/home`, `/home/<user>`, paths under the standard system directories, paths shallower than two components, and paths containing `..`. On the node the removal script also refuses a symbolic link, a path it cannot enter, a directory that contains the home directory, and a path at, above, or below which lies the ownership marker (`.sshdatabridge-target`) of another target, which catches nodes that share storage. A push into a directory that another target has claimed is refused as well. On the command line every purge outside a dry run requires `--yes`. The library functions do not ask: `clean_remote_target` purges when called, and `pull_target` purges when `clean_remote_after_pull` is set.

## Known limitations

- A process running as the same user can read the configuration file and, while `sshpass` runs, the password pipe through `/proc/<pid>/fd`.
- Host key policy `"no"` disables protection against a substituted host; the default `"accept-new"` trusts a host on first contact.
- `sshpass` answers the first password prompt it sees. `proxy_jump` is refused on a password target, and the driver warns when `~/.ssh/config` routes one through a jump host, but it does not stop it: if that jump host asks for a password, it receives the target's.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository, or write to me at the address in `Project.toml`. Please do not open a public issue for an undisclosed vulnerability.
