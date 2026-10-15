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

unset PROVIDER INSTANA_PROVIDER
CONFIG_FILE=/nonexistent STATE_FILE=/nonexistent
resolve_provider
test "$PROVIDER" = gcp
test "$PROVIDER_LABEL" = GCP
test "$(provider_disk_device_path node0 disk-data)" = /dev/disk/by-id/google-disk-data
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo '{"gcp_project":"p","gcp_zone":"z"}' > "$tmp/state.json"
STATE_FILE="$tmp/state.json"; unset PROVIDER
resolve_provider
test "$PROVIDER" = gcp
if INSTANA_PROVIDER=nope resolve_provider 2>/dev/null; then echo "FAIL: unknown provider accepted" >&2; exit 1; fi
test "$PROVIDER" = gcp
echo 'PASS: an existing state file without a provider resolves to gcp; unknown providers are refused'

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
