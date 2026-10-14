#!/usr/bin/env bash
#
# Run the deploy playbook from an operator machine.
#
# The playbook is run over the operator's own SSH access (normally root). The
# domain and the database password are read from the rendered
# /opt/mattermost/.env on the target host, so nothing host-specific is stored
# next to the repository. Values are held in memory and in a 0600 temporary
# extra-vars file that is removed on exit; they are never printed.
#
# Usage:
#   scripts/deploy-local.sh --host <ssh-host> [options]
#
# Options:
#   --host <name>          SSH host or alias of the target server (required)
#   --user <name>          SSH user (default: root)
#   --port <n>             SSH port (default: 22)
#   --mode <check|apply>   check = dry run with diff, changes nothing (default);
#                          apply = deploy
#   --edge <true|false>    Deploy the built-in Caddy TLS edge (default: false)
#   --edge-network <name>  External Docker network shared with an existing proxy
#   --no-baseline          Do not manage the host baseline (fail2ban, Docker)
#   -h, --help             Show this help
#
# First install (no .env on the host yet): export MM_DOMAIN and
# MM_POSTGRES_PASSWORD (for example `openssl rand -hex 32`) before running.

set -euo pipefail

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

host=""
ssh_user="root"
port="22"
mode="check"
edge="false"
edge_network=""
baseline="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)         host="$2";         shift 2 ;;
    --user)         ssh_user="$2";     shift 2 ;;
    --port)         port="$2";         shift 2 ;;
    --mode)         mode="$2";         shift 2 ;;
    --edge)         edge="$2";         shift 2 ;;
    --edge-network) edge_network="$2"; shift 2 ;;
    --no-baseline)  baseline="false";  shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$host" ]]; then
  echo "Error: --host is required." >&2
  usage >&2
  exit 1
fi
if [[ "$mode" != "check" && "$mode" != "apply" ]]; then
  echo "Error: --mode must be 'check' or 'apply'." >&2
  exit 1
fi
if [[ "$edge" != "true" && "$edge" != "false" ]]; then
  echo "Error: --edge must be 'true' or 'false'." >&2
  exit 1
fi

for tool in ssh python3 ansible-playbook; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: required tool '$tool' is not installed." >&2
    exit 1
  fi
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

domain="${MM_DOMAIN:-}"
password="${MM_POSTGRES_PASSWORD:-}"
if [[ -z "$domain" || -z "$password" ]]; then
  while IFS= read -r line; do
    case "$line" in
      MM_DOMAIN=*)         [[ -n "$domain" ]]   || domain="${line#MM_DOMAIN=}" ;;
      POSTGRES_PASSWORD=*) [[ -n "$password" ]] || password="${line#POSTGRES_PASSWORD=}" ;;
      *) ;;
    esac
  done < <(ssh -p "$port" "${ssh_user}@${host}" \
    "grep -E '^(MM_DOMAIN|POSTGRES_PASSWORD)=' /opt/mattermost/.env" 2>/dev/null || true)
fi
if [[ -z "$domain" || -z "$password" ]]; then
  echo "Error: no domain/password on the host; export MM_DOMAIN and MM_POSTGRES_PASSWORD." >&2
  exit 1
fi

umask 077
extra_vars="$(mktemp)"
trap 'rm -f "$extra_vars"' EXIT

MM_DOMAIN="$domain" MM_POSTGRES_PASSWORD="$password" \
EDGE="$edge" EDGE_NETWORK="$edge_network" BASELINE="$baseline" PORT="$port" \
python3 -c '
import json, os
e = os.environ
print(json.dumps({
    "mattermost_domain": e["MM_DOMAIN"],
    "mattermost_postgres_password": e["MM_POSTGRES_PASSWORD"],
    "ansible_port": int(e["PORT"]),
    "mattermost_edge_enabled": e["EDGE"] == "true",
    "mattermost_edge_external_network": e["EDGE_NETWORK"],
    "manage_host_baseline": e["BASELINE"] != "false",
}))' > "$extra_vars"

check_args=()
if [[ "$mode" != "apply" ]]; then
  # The .env task sets diff: false, so the database password never reaches
  # the terminal.
  check_args=(--check --diff)
fi

cd "$repo_root"
ansible-playbook site.yml "${check_args[@]}" \
  -i "${host}," \
  -u "$ssh_user" \
  -e "@${extra_vars}"
