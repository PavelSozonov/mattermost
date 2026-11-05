# Repository workflow

Read [README.md](README.md) and the existing [project guidance](CLAUDE.md)
before changing this repository. Keep documentation, comments, commit
messages and pull request text in English. Use Conventional Commits without
attribution trailers.

## Scope and privacy

This repository contains an Ansible deployment for a single-server
Mattermost stack. Keep real hostnames, IP addresses, SSH aliases, key paths,
domains and credentials out of tracked files, examples and commit messages.
Use placeholders; host-specific settings belong in gitignored local
configuration or on the server.

Deployment is an operator action through the documented playbook. Do not
use ad-hoc remote package or container commands, and do not treat a
repository-only change as a request to deploy or inspect a live server.

## Preserve deployment boundaries

- Leave an existing Docker Engine and Compose installation undisturbed.
- The fail2ban configuration manages only its own drop-in. Preserve the ban
  database and existing unrelated configuration.
- Respect `manage_host_baseline: false` and `--no-baseline` when another
  configuration tool owns the host baseline; do not enable competing
  management of the same files.
- Keep `mattermost_edge_enabled: false` as the default. The application
  binds to loopback unless the optional TLS edge is explicitly enabled;
  do not take ports already owned by another reverse proxy.
- PostgreSQL remains on the project-internal network. Only the application
  joins an optional external network for an existing containerized proxy.
- Keep the documented environment-to-role value flow and Compose variable
  substitution. Never expose rendered credentials in output or diffs.
- Versions are pinned, including images and hooks. Upgrade deliberately;
  prefer Mattermost ESR releases.

## Checks and handoff

Run `pre-commit run --all-files` for the normal lint suite. Keep
`.pre-commit-config.yaml` and `.github/workflows/ci.yml` aligned when changing
checks. The Ansible lint hook runs on the whole project even for a
Markdown-only change; review its configuration before running it against
any local inventory.

CI runs the lint hooks, an Ansible syntax check using the example inventory,
and a secret scan. Report which checks actually ran and any unavailable
checks. Lint or syntax success does not establish deployment success or the
health of a running server.
