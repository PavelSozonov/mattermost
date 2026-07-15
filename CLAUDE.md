# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Ansible IaC that deploys a Mattermost stack (PostgreSQL + Mattermost Team Edition + optional Caddy TLS edge) onto a single Ubuntu 24.04 host via Docker Compose. Deployment normally runs from GitHub Actions; all host-specific values live in GitHub Actions secrets, never in the repo.

## Commands

- `pre-commit run --all-files` — the full lint suite (yamllint, ansible-lint, shellcheck, actionlint, gitleaks). CI runs exactly this; when changing checks, keep `.pre-commit-config.yaml` and `.github/workflows/ci.yml` in sync.
- `ansible-playbook --syntax-check -i inventories/example/hosts.yml site.yml` — requires `ansible-core` and `ansible-galaxy collection install -r requirements.yml`.
- `gh workflow run deploy.yml` — deploy to the real server (manual dispatch only).
- `scripts/bootstrap-github-secrets.sh --ssh-target <host> --domain <fqdn>` — (re)create GitHub secrets from local SSH config.

## Architecture

- `site.yml` applies two roles:
  - `docker` — ensures Docker Engine + Compose plugin exist. If both are already present it does nothing; it must never disturb an existing engine (the target is a shared production server).
  - `mattermost` — renders `/opt/mattermost` on the host (`.env` from `templates/env.j2`, `docker-compose.yml`, `Caddyfile`) and reconciles via `community.docker.docker_compose_v2`, then waits for `/api/v4/system/ping`.
- Value flow: GitHub secrets → deploy workflow env → extra-vars JSON → role vars (`roles/mattermost/defaults/main.yml`) → `.env` on the host. The compose template references only `${VARS}` from `.env`; its single piece of Jinja logic is the conditional `caddy` service gated on `mattermost_edge_enabled`.
- Edge toggle: `mattermost_edge_enabled=false` (default) publishes the app on `127.0.0.1:8065` for an existing host reverse proxy; `true` adds Caddy with Let's Encrypt on 80/443. Keep the default `false` — the real target host has another proxy owning those ports.

## Hard rules

- This repo is public. Real hostnames, IPs, SSH aliases, key paths, and the real domain must never appear in code, docs, examples, or commit messages — they live only in GitHub Actions secrets/variables and gitignored `inventories/local/`.
- The target is a production server running unrelated services. Change it only through the playbook — no ad-hoc `docker`/`apt` commands over SSH.
- Versions are pinned everywhere (container images, pre-commit hooks); upgrades are deliberate bumps. For Mattermost prefer ESR releases.
- Conventional commit messages; do not add a `Co-Authored-By` trailer.
