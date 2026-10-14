# dd-laptop-setup-check

An idempotent audit-and-install script for a Datadog macOS work laptop. It walks the
steps in the internal **Datadog Laptop Setup Guide**, reports what is already in place,
and installs what is missing.

Written because "did the setup actually finish?" is otherwise a half-day of manual
`command -v` checks, and because a few of the steps fail in ways that look like
something else entirely.

## What it reports

Every item prints exactly one status:

| Status        | Meaning                                                        |
| ------------- | -------------------------------------------------------------- |
| `[OK]`        | already installed / already configured — nothing to do           |
| `[INSTALLED]` | was missing, this script installed it                            |
| `[FAILED]`    | was missing, install was attempted and failed                    |
| `[MANUAL]`    | cannot be automated (GUI app, Chrome extension, interactive SSO) |
| `[SKIPPED]`   | skipped by you, or by `--check-only` / `--dry-run`               |
| `[WARN]`      | present, but not in the state the guide expects                  |

It finishes with a per-item summary table, the guide's own validation checklist, and
counts. Exit status is `0` only when nothing is failing, warning, or pending.

## Usage

```bash
./dd-laptop-setup-check.sh                 # audit, then prompt before each install
./dd-laptop-setup-check.sh --check-only    # audit only, never install
./dd-laptop-setup-check.sh --dry-run       # audit, print install commands, run nothing
./dd-laptop-setup-check.sh --yes           # install missing items without prompting
./dd-laptop-setup-check.sh --no-network    # skip every check that hits the network
./dd-laptop-setup-check.sh --sudo-interactive
                                           # also run the guide's literal `sudo ls`
./dd-laptop-setup-check.sh --email first.last@datadoghq.com
                                           # enables the git identity and username checks
./dd-laptop-setup-check.sh --help
```

Safe to re-run. Nothing in it is destructive. Full output is also written to
`~/dd-laptop-setup-check-<timestamp>.log`.

## What it checks

**Preflight** — Slack, AppGate SDP, Self Service and Chrome present; Apple command line
tools; `git`; git `user.email` / `user.name`; and username consistency across `whoami`,
`$USER`, the home folder name and the Google Workspace account name.

**Admin rights** — Datadog laptops grant admin just-in-time through the Privileges app,
so group membership alone is not the answer. The default probe is `sudo -nv`, which never
prompts, and distinguishes *not in sudoers* (a real problem) from *password required*
(normal) from *JIT grant issued*. Note that touching `sudo` at all is what triggers the
Privileges grant.

**AppGate tunnel** — installed is not the same as connected. Checks the client and driver
processes, the `utun` tunnel interface, internal DNS resolution, an actual HTTPS response
from internal hosts, and that the GitLab sign-in flow reaches the identity layer.

**GitHub** — `gh` presence and auth; membership in both orgs and in each org's `dev` team;
read access to a private repo as a direct probe; and whether `git` over SSH and the `gh`
CLI are authenticated as the *same* account, which is a surprisingly easy thing to get
wrong when you have both a personal and a work GitHub identity.

**Laptop baseline** — Homebrew, Node.js 18+, the engineering setup script, `~/.zshrc`
permissions.

**Source control** — `git-config-tool` plus its `doctor` output, SSH keys, GitHub SSH auth.

**GitLab** — a real authenticated check: pulls a token from `ddtool auth gitlab token`
(or `$GITLAB_TOKEN`), then verifies both the API identity and access to the `DataDog`
group, pointing at Request Access on a 403/404.

**Internal access** — `ddtool`, the Vault CLI, and Vault token state.

**Optional tools** — the Doggo Chrome extension, Claude Code, Claude Desktop.

**Engineering track extras** — the Go toolchain, `GOPATH`/`GOBIN`, whether `$GOPATH/bin`
is on `PATH`, a `GODEBUG` sanity check, and the `dda` CLI. The `dda` install command is
read live from the published docs rather than hardcoded, so it does not go stale when the
packaging changes.

## Notes

Interactive and GUI steps are deliberately *not* automated. The script will not run
`git-config-tool setup`, `ddtool auth login`, `ddtool auth gitlab login`, or the
engineering setup script itself; it reports them as `[MANUAL]` with the exact command.
Nor will it install anything that only ships through Self Service or the Chrome Web Store.

One failure mode worth calling out, because it reads as something else: older `vault`
builds set `GODEBUG=x509sha1=1` for themselves, the token helper inherits it, and Go
toolchains that removed the setting abort at startup. `vault token lookup` then looks like
a missing token when it is really a stale `vault` binary. The script detects that specific
error and says so.

## Requirements

macOS, `bash`, and the command line tools. Everything else it will offer to install.
