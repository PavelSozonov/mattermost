# Repository workflow

Read [README.md](README.md) and applicable nested AGENTS.md before changing
this repository. Current complete AGENTS.md text already supplied for the
same path and scope counts as read; rereading or hashing it only to prove
loading is unnecessary. Keep documentation, comments, commit messages,
pull request titles, descriptions and comments in English. Use Conventional
Commits without attribution trailers.

## Scope and privacy

This repository contains an Ansible deployment for a single-server
Mattermost Team Edition, PostgreSQL and optional Caddy TLS edge on Ubuntu
24.04 through Docker Compose. No CI deployment key exists; deployment uses
the operator's own access. Keep real hostnames, IP addresses, SSH aliases,
key paths,
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

## Architecture and commands

`site.yml` applies the `fail2ban`, `docker` and `mattermost` roles. The first
uses the journald backend, an aggressive SSH jail and escalating bans; it
can be disabled with `fail2ban_enabled: false`. The host roles run only
when `manage_host_baseline` is true (the default).

The application role renders the environment file from `templates/env.j2`,
the Compose file and the Caddyfile in the configured application directory.
It reconciles with `community.docker.docker_compose_v2` and waits for the
application `/api/v4/system/ping` endpoint. Values flow from the server's environment file
(or `MM_DOMAIN` and `MM_POSTGRES_PASSWORD` on first installation), through
`scripts/deploy-local.sh` and temporary extra-vars JSON, to role variables
in `roles/mattermost/defaults/main.yml` and the rendered environment file.
The Compose template uses environment variable substitution; its only
Jinja conditional gates the Caddy service on `mattermost_edge_enabled`.
Enabling that service adds automatic Let's Encrypt TLS on ports 80/443.
The optional external network is selected by
`mattermost_edge_external_network` (`--edge-network <name>` in the script).

- `ansible-playbook --syntax-check -i inventories/example/hosts.yml site.yml`
  checks syntax with the example inventory. It requires `ansible-core` and
  the collections from `ansible-galaxy collection install -r requirements.yml`.
- `scripts/deploy-local.sh --host <server> --mode check` is the operator's
  dry run with `--check --diff` (also the default mode). `--mode apply`
  deploys. These commands require separate authorization for the server.

## Checks and handoff

Run `pre-commit run --all-files` for the normal lint suite. Keep
`.pre-commit-config.yaml` and `.github/workflows/ci.yml` aligned when changing
checks. CI checks pull request files on a PR and all files on a push to
`main`. The Ansible lint hook runs on the whole project even for a
Markdown-only change; review its configuration before running it against
any local inventory.

CI runs the lint hooks, an Ansible syntax check using the example inventory,
and a secret scan. Report which checks actually ran and any unavailable
checks. Lint or syntax success does not establish deployment success or the
health of a running server.
