# Mattermost — Ansible deployment

[![CI](https://github.com/PavelSozonov/mattermost/actions/workflows/ci.yml/badge.svg)](https://github.com/PavelSozonov/mattermost/actions/workflows/ci.yml)

Infrastructure-as-code for deploying a small self-hosted [Mattermost](https://mattermost.com/)
instance (Team Edition) onto a single Ubuntu 24.04 server with Ansible and Docker Compose.

Designed for a personal / small-team server (2 vCPU, 4 GB RAM) that may already run
other services: the playbook is idempotent, never reinstalls an existing Docker Engine,
and by default publishes the app only on the loopback interface so it can sit behind an
existing reverse proxy.

## Stack

| Component | Image | Notes |
|---|---|---|
| Mattermost | `mattermost/mattermost-team-edition` (pinned ESR) | app, published on `127.0.0.1:8065` |
| PostgreSQL | `postgres:16-alpine` | internal network only, no published ports |
| Caddy (optional) | `caddy:2-alpine` | TLS edge with automatic Let's Encrypt, ports 80/443 |
| fail2ban | host package (not a container) | SSH brute-force protection with escalating bans |

```
                       ┌──────────────────────── target host ───────────────────────┐
        HTTPS 443      │  ┌───────────┐        ┌────────────┐       ┌────────────┐  │
  users ──────────────►│  │ Caddy edge│───────►│ Mattermost │──────►│ PostgreSQL │  │
                       │  │ (optional)│        │            │       │            │  │
                       │  └───────────┘        └─────┬──────┘       └────────────┘  │
                       │  or existing reverse ▲      │ 127.0.0.1:8065               │
                       │  proxy on the host ──┘      ▼                              │
                       │                      /opt/mattermost (compose project)     │
                       └────────────────────────────────────────────────────────────┘
```

## Requirements

- **Target server**: Ubuntu 24.04, SSH access with a key, root or passwordless sudo.
  Docker and the Compose plugin are installed automatically if missing (an existing
  installation is left untouched).
- **Your machine**: `gh` (authenticated), `ssh` access to the server. Ansible is only
  needed for local runs — the recommended path deploys from GitHub Actions.
- **DNS**: an A/AAAA record for your Mattermost domain pointing at the server.

## Quick start (deploy from GitHub Actions)

1. Fork or clone this repository and push it to GitHub.

2. Upload deployment secrets (SSH endpoint, host key, domain, generated DB password)
   to the repository — values are read from your local SSH config and never touch
   the working tree:

   ```bash
   scripts/bootstrap-github-secrets.sh --ssh-target <ssh-alias-or-host> --domain chat.example.com
   ```

   Add `--user root` when the target is a plain hostname rather than an alias from
   `~/.ssh/config` (otherwise your local username is assumed), and `--edge true` if
   ports 80/443 on the server are free and you want the built-in Caddy edge with
   automatic HTTPS.

3. Deploy:

   ```bash
   gh workflow run deploy.yml && gh run watch
   ```

4. Create the first admin account (open signup is not enabled):

   ```bash
   ssh <server> docker exec mattermost mmctl --local user create \
     --email you@example.com --username admin --password '<strong-password>' --system-admin
   ```

Open `https://chat.example.com` and log in.

## Local deployment (without CI)

```bash
python3 -m pip install "ansible-core>=2.17,<2.19"
ansible-galaxy collection install -r requirements.yml

cp -r inventories/example inventories/local   # gitignored; put real values here
$EDITOR inventories/local/hosts.yml

ansible-playbook site.yml -i inventories/local/hosts.yml
```

## Configuration

All knobs live in [`roles/mattermost/defaults/main.yml`](roles/mattermost/defaults/main.yml)
and can be overridden per-host or via `--extra-vars`. The important ones:

| Variable | Default | Purpose |
|---|---|---|
| `mattermost_domain` | — (required) | public FQDN, used for the site URL and TLS |
| `mattermost_postgres_password` | — (required) | URL-safe DB password (`openssl rand -hex 32`) |
| `mattermost_edge_enabled` | `false` | deploy the Caddy TLS edge on ports 80/443 |
| `mattermost_bind_address` / `mattermost_http_port` | `127.0.0.1` / `8065` | where the app is published on the host (reverse-proxy target) |
| `mattermost_image_tag` | pinned ESR | Mattermost version; bump deliberately |
| `mattermost_base_dir` | `/opt/mattermost` | compose project and data location on the server |
| `*_mem_limit` | 2g / 1g / 256m | container memory caps sized for a 4 GB host |

SSH hardening lives in [`roles/fail2ban/defaults/main.yml`](roles/fail2ban/defaults/main.yml):

| Variable | Default | Purpose |
|---|---|---|
| `fail2ban_enabled` | `true` | set to `false` if fail2ban on the host is managed elsewhere |
| `fail2ban_maxretry` / `fail2ban_findtime` | `5` / `10m` | failed SSH auths from one IP that trigger a ban |
| `fail2ban_bantime` (+ increment/factor/maxtime) | `1h`, ×2, cap `1w` | first ban duration, doubling for repeat offenders |
| `fail2ban_ignoreip` | loopback only | IPs/CIDRs never banned (add your static IP if desired) |

In CI these are supplied from GitHub Actions secrets (`MM_DOMAIN`,
`MM_POSTGRES_PASSWORD`, `DEPLOY_*`) and the `MM_EDGE_ENABLED` repository variable —
see [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml).

### Running behind an existing reverse proxy

With `mattermost_edge_enabled: false` (the default) nothing binds 80/443; point your
existing proxy at `http://127.0.0.1:8065` and make sure it forwards WebSocket upgrades
(for Caddy: a plain `reverse_proxy 127.0.0.1:8065` is enough).

## Operations

- **Upgrade Mattermost**: bump `mattermost_image_tag` (prefer
  [ESR versions](https://docs.mattermost.com/product-overview/release-policy.html)),
  commit, re-run the deploy workflow. Compose recreates only changed containers.
- **Re-deploy / reconcile**: the playbook is idempotent — re-run it any time.
- **Backups**: application data lives in `/opt/mattermost/volumes/`. Dump the database with
  `docker exec mattermost-postgres pg_dump -U mmuser mattermost | gzip > backup.sql.gz`
  and copy `volumes/mattermost/data` for uploaded files.
- **Logs**: `docker compose -f /opt/mattermost/docker-compose.yml logs -f mattermost`.
- **SSH bans**: `fail2ban-client status sshd` (counters), `fail2ban-client banned`
  (current bans), `fail2ban-client unban <ip>` (release one IP).

## Security model

- No secrets, hostnames, or domains in the repository — everything host-specific is
  a GitHub Actions secret; local inventories are gitignored.
- SSH brute-force protection via fail2ban (systemd/journald backend, aggressive sshd
  jail, escalating ban times). The role only manages its own drop-in in
  `/etc/fail2ban/jail.d/` and never touches the ban database, so an existing
  fail2ban setup and accumulated bans survive re-runs; if the ban policy is managed
  by another tool, set `fail2ban_enabled: false`.
- CI deploys with a pinned SSH host key (`ssh-keyscan` at bootstrap time,
  strict host-key checking on).
- PostgreSQL is reachable only from the compose network; the app binds to loopback
  unless the TLS edge is enabled.
- Containers run with `no-new-privileges`, PID limits, memory caps, and a read-only
  root filesystem where possible; images are version-pinned.
- The rendered `/opt/mattermost/.env` (contains the DB password) is `0600 root:root`.
- `gitleaks` and `detect-private-key` run in pre-commit and CI to keep credentials
  out of the history.

## Development

```bash
python3 -m pip install pre-commit
pre-commit install          # run checks on every commit
pre-commit run --all-files  # run the full suite manually
```

CI runs exactly the same suite (yamllint, ansible-lint, shellcheck, actionlint,
gitleaks, plus an Ansible syntax check).

## License

[MIT](LICENSE)
