#!/usr/bin/env bash
set -euo pipefail
# Every supported provider defines every contract operation, dispatch follows
# PROVIDER, and the parameter API used by --config behaves as documented.
# No cloud CLI is called.
bash -s "$(cd "$(dirname "$0")" && pwd)" <<'TEST'
set -euo pipefail
err() { echo "$*" >&2; }
source "$1/providers/common.sh"
for p in $PROVIDERS_SUPPORTED; do
  source "$1/providers/$p.sh"
done
missing=""
for p in $PROVIDERS_SUPPORTED; do
  for op in $PROVIDER_CONTRACT_OPS; do
    declare -F "prov_${p}_${op}" >/dev/null || missing="$missing prov_${p}_${op}"
  done
done
if [[ -n "$missing" ]]; then echo "FAIL: missing provider functions:$missing" >&2; exit 1; fi
for op in $PROVIDER_CONTRACT_OPS; do
  declare -F "provider_${op}" >/dev/null || { echo "FAIL: missing dispatcher provider_${op}" >&2; exit 1; }
done
echo 'PASS: every provider implements the whole contract'

unset PROVIDER INSTANA_PROVIDER ACTIVE_PROVIDER
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
CONFIG_FILE="$tmp/config.json" STATE_FILE="$tmp/state.json"
refused() { if resolve_provider "$@" 2>"$tmp/err"; then echo "FAIL: resolve_provider $* was accepted" >&2; exit 1; fi; }
resolve_provider
test "$PROVIDER" = gcp
test "$PROVIDER_LABEL" = GCP
test "$(provider_disk_device_path node0 disk-data)" = /dev/disk/by-id/google-disk-data
PROVIDER=bogus
test "$(provider_label)" = GCP
echo 'PASS: default is gcp; a stray PROVIDER variable does not change the dispatch'

INSTANA_PROVIDER=nope refused
grep -q "Unsupported provider 'nope' (from INSTANA_PROVIDER)" "$tmp/err"
refused nope
grep -q "Unsupported provider 'nope' (from --provider)" "$tmp/err"
test "$(provider_name)" = gcp
echo 'PASS: an unsupported provider is refused with its source; the active provider is unchanged'

echo '{"gcp_project":"p","gcp_zone":"z","vm_a":"created"}' > "$STATE_FILE"
resolve_provider
test "$PROVIDER" = gcp
INSTANA_PROVIDER=ssh refused
grep -q "Provider 'ssh' was requested (INSTANA_PROVIDER) but this folder records provider 'gcp' (.install-state.json)" "$tmp/err"
refused ssh .install-config-input.json
grep -q "requested (.install-config-input.json)" "$tmp/err"
echo '{"parameters":{"PROVIDER":"ssh"}}' > "$CONFIG_FILE"
refused
grep -q "The saved parameters name provider 'ssh'" "$tmp/err"
rm -f "$STATE_FILE"
INSTANA_PROVIDER=gcp refused
grep -q "records provider 'ssh' (.install-config.json)" "$tmp/err"
rm -f "$CONFIG_FILE"
echo 'PASS: a recorded deployment (old state = gcp) wins and never switches silently'

provider_validate_param GCP_PROJECT instana-support-test-account
provider_validate_param PROVIDER_LOCATION europe-west6-b
provider_validate_param GCP_SUBNET default
if provider_validate_param GCP_ZONE europe-west6 2>/dev/null; then echo "FAIL: region accepted as zone" >&2; exit 1; fi
if provider_validate_param GCP_PROJECT Bad_Project 2>/dev/null; then echo "FAIL: invalid project accepted" >&2; exit 1; fi
if provider_validate_param GCP_BOGUS x 2>/dev/null; then echo "FAIL: unknown key accepted" >&2; exit 1; fi
GCP_PROJECT="" PROVIDER_SCOPE=p1 GCP_ZONE=z1 PROVIDER_LOCATION=""
provider_normalize_params
test "$GCP_PROJECT" = p1
test "$PROVIDER_LOCATION" = z1
GCP_PROJECT=a PROVIDER_SCOPE=b
if provider_normalize_params 2>/dev/null; then echo "FAIL: conflicting aliases accepted" >&2; exit 1; fi
echo 'PASS: parameter validation and PROVIDER_*/GCP_* aliases'
TEST

# show_plan records the provider in the state file once the plan is confirmed.
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
cp -R "$(dirname "$0")"/*.sh "$(dirname "$0")"/providers "$TEST_DIR/"
(
  cd "$TEST_DIR"
  export ACTIVE_PROVIDER=bogus
  source ./install.sh
  test -z "$ACTIVE_PROVIDER"
  DRY_RUN=false
  prompt_yes_no() { return 0; }
  TOPOLOGY=single-node INSTALL_TYPE=demo INSTALL_MODE=online UBUNTU_VERSION=ubuntu-2404-lts-amd64
  GCP_PROJECT=test-project GCP_ZONE=us-central1-a MACHINE_TYPE=n2-standard-16 VM_NAME=instana-backend
  BASE_DOMAIN=instana.example.com TENANT_NAME=tenant0 UNIT_NAME=unit0 TLS_MODE=auto SSH_SOURCE_CIDR=203.0.113.10/32
  show_plan > /dev/null
  jq -e '.provider == "gcp" and .gcp_project == "test-project"' .install-state.json > /dev/null
)
echo 'PASS: the confirmed plan records the provider in the state file; ACTIVE_PROVIDER from the environment is ignored'

