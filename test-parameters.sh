#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/install.sh"
task_dir=$(mktemp -d)
(
  # Isolated subshell declares an independent config path and loads module only.
  bash -s "$SCRIPT_DIR/parameters.sh" "$task_dir" <<'TEST'
set -euo pipefail
source "$1"
CONFIG_FILE="$2/config.json"
DRY_RUN=false
log() { :; }
die() { echo "$*" >&2; exit 1; }
GCP_PROJECT=test-project
BASE_DOMAIN=mikrut.rs
ADMIN_PASSWORD=secret-admin
DOWNLOAD_KEY=secret-download
SALES_KEY=secret-sales
AGENT_KEY=secret-agent
save_parameters
jq -e '.parameters.GCP_PROJECT=="test-project" and .parameters.BASE_DOMAIN=="mikrut.rs"' "$CONFIG_FILE" >/dev/null
! grep -q secret "$CONFIG_FILE"
test "$(stat -c %a "$CONFIG_FILE")" = 600
DRY_RUN=true
GCP_PROJECT=changed
save_parameters
jq -e '.parameters.GCP_PROJECT=="test-project"' "$CONFIG_FILE" >/dev/null
CONFIG_LOADED=true
prompt_choice() { echo 'reuse saved parameters'; }
prompt_secret() { echo replacement-secret; }
validate_fqdn() { :; }
validate_tenant_unit_name() { :; }
validate_cidr() { :; }
validate_secret() { :; }
TOPOLOGY=single-node
INSTALL_MODE=online
INSTALL_TYPE=demo
TLS_MODE='auto-generate (self-signed)'
DRY_RUN=false
save_parameters
GCP_PROJECT=wrong
offer_saved_parameters
test "$GCP_PROJECT" = changed
test "$ADMIN_PASSWORD" = replacement-secret
echo 'PASS: persistence, reuse, permissions, secrets excluded, dry-run unchanged'
TEST
)
