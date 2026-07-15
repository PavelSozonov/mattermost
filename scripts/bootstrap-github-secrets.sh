#!/usr/bin/env bash
#
# Populate GitHub Actions secrets/variables required by the deploy workflow.
#
# Reads the SSH connection details for the target host from your local SSH
# configuration (via `ssh -G`), scans the host key, and uploads everything to
# the repository with the `gh` CLI. Secret VALUES never touch the repository
# working tree and are never printed.
#
# Usage:
#   scripts/bootstrap-github-secrets.sh --ssh-target <alias-or-host> --domain <fqdn> [options]
#
# Options:
#   --ssh-target <name>   SSH alias or hostname of the target server (required)
#   --domain <fqdn>       Public domain the Mattermost instance will serve (required)
#   --edge <true|false>   Deploy the built-in Caddy TLS edge (default: false)
#   --repo <owner/name>   GitHub repository (default: repository of the current directory)
#   -h, --help            Show this help
#
# Created secrets:   DEPLOY_HOST, DEPLOY_USER, DEPLOY_PORT, DEPLOY_SSH_PRIVATE_KEY,
#                    DEPLOY_SSH_KNOWN_HOSTS, MM_DOMAIN, MM_POSTGRES_PASSWORD
# Created variables: MM_EDGE_ENABLED

set -euo pipefail

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

ssh_target=""
domain=""
edge="false"
repo=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-target) ssh_target="$2"; shift 2 ;;
    --domain)     domain="$2";     shift 2 ;;
    --edge)       edge="$2";       shift 2 ;;
    --repo)       repo="$2";       shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$ssh_target" || -z "$domain" ]]; then
  echo "Error: --ssh-target and --domain are required." >&2
  usage >&2
  exit 1
fi

if [[ "$edge" != "true" && "$edge" != "false" ]]; then
  echo "Error: --edge must be 'true' or 'false'." >&2
  exit 1
fi

for tool in gh ssh ssh-keyscan openssl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: required tool '$tool' is not installed." >&2
    exit 1
  fi
done

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi
echo "Repository: $repo"

# Resolve the SSH target through the local client configuration so that
# aliases from ~/.ssh/config work transparently.
ssh_config="$(ssh -G "$ssh_target")"
host="$(awk '$1 == "hostname" {print $2; exit}' <<<"$ssh_config")"
user="$(awk '$1 == "user" {print $2; exit}' <<<"$ssh_config")"
port="$(awk '$1 == "port" {print $2; exit}' <<<"$ssh_config")"

key_file=""
while IFS= read -r candidate; do
  candidate="${candidate/#\~/$HOME}"
  if [[ -f "$candidate" ]]; then
    key_file="$candidate"
    break
  fi
done < <(awk '$1 == "identityfile" {print $2}' <<<"$ssh_config")

if [[ -z "$key_file" ]]; then
  echo "Error: no existing SSH private key found for '$ssh_target'." >&2
  exit 1
fi

echo "Resolved SSH target: ${user}@<redacted>:${port} (key: ${key_file})"

echo "Scanning SSH host key..."
known_hosts="$(ssh-keyscan -p "$port" -H "$host" 2>/dev/null)"
if [[ -z "$known_hosts" ]]; then
  echo "Error: ssh-keyscan returned nothing for the target host." >&2
  exit 1
fi

echo "Uploading secrets to $repo..."
gh secret set DEPLOY_HOST --repo "$repo" --body "$host"
gh secret set DEPLOY_USER --repo "$repo" --body "$user"
gh secret set DEPLOY_PORT --repo "$repo" --body "$port"
gh secret set DEPLOY_SSH_PRIVATE_KEY --repo "$repo" < "$key_file"
gh secret set DEPLOY_SSH_KNOWN_HOSTS --repo "$repo" --body "$known_hosts"
gh secret set MM_DOMAIN --repo "$repo" --body "$domain"

# Preserve an existing database password: regenerating it would break an
# already-initialized PostgreSQL volume on the server.
if gh secret list --repo "$repo" --json name --jq '.[].name' | grep -qx 'MM_POSTGRES_PASSWORD'; then
  echo "MM_POSTGRES_PASSWORD already exists — keeping it."
else
  gh secret set MM_POSTGRES_PASSWORD --repo "$repo" --body "$(openssl rand -hex 32)"
  echo "MM_POSTGRES_PASSWORD generated."
fi

gh variable set MM_EDGE_ENABLED --repo "$repo" --body "$edge"

echo
echo "Done. Configured secrets: DEPLOY_HOST, DEPLOY_USER, DEPLOY_PORT,"
echo "DEPLOY_SSH_PRIVATE_KEY, DEPLOY_SSH_KNOWN_HOSTS, MM_DOMAIN, MM_POSTGRES_PASSWORD."
echo "Configured variables: MM_EDGE_ENABLED=$edge"
echo "Deploy with: gh workflow run deploy.yml"
