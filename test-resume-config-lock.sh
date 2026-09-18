#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

run_case() {
  local topology="$1" vm_name="$2"
  local case_dir="$TEST_DIR/$topology"
  mkdir -p "$case_dir"
  bash -s "$SCRIPT_DIR/parameters.sh" "$case_dir" "$topology" "$vm_name" <<'TEST'
set -euo pipefail
source "$1"
CONFIG_FILE="$2/.install-config.json"
STATE_FILE="$2/.install-state.json"
DRY_RUN=false
RESUME=false
log() { :; }
die() { echo "$*" >&2; exit 1; }
prompt_secret() { printf '%s\n' replacement-secret; }
prompt_choice() { echo 'FAIL: resume must not offer parameter editing' >&2; exit 1; }
validate_fqdn() { :; }
validate_tenant_unit_name() { :; }
validate_cidr() { :; }
validate_secret() { :; }

TOPOLOGY="$3"
INSTALL_MODE=online
INSTALL_TYPE=production
UBUNTU_VERSION=ubuntu-2404-lts-amd64
GCP_PROJECT=instana-support-test-account
GCP_REGION=us-central1
GCP_ZONE=us-central1-a
GCP_NETWORK=default
GCP_SUBNET=default
SSH_SOURCE_CIDR=203.0.113.10/32
VM_NAME="$4"
NODE0_NAME=instana-0
NODE1_NAME=instana-1
NODE2_NAME=instana-2
VM_CPUS=28
VM_RAM_GB=112
NODE_CPUS=12
NODE_RAM_GB=48
MACHINE_TYPE=n2-standard-32
BASE_DOMAIN=mikrut.rs
TENANT_NAME=mikrut
UNIT_NAME=miodrag
TLS_MODE='auto-generate (self-signed)'
TLS_CRT_PATH=''
TLS_KEY_PATH=''
AIRGAP_STANCTL_DEB=''
AIRGAP_ARCHIVE=''
save_parameters
before=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')

RESUME=true
GCP_PROJECT=wrong-project
GCP_ZONE=wrong-zone
VM_NAME=wrong-vm
offer_saved_parameters
test "$GCP_PROJECT" = instana-support-test-account
test "$GCP_ZONE" = us-central1-a
test "$VM_NAME" = "$4"
save_parameters
after=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
test "$before" = "$after"
test "$ADMIN_PASSWORD" = replacement-secret
TEST
  echo "PASS: $topology resume parameters are automatically reused and immutable"
}

run_case single-node mikrut-backend
run_case three-node unused-single-name

if bash -s "$SCRIPT_DIR/parameters.sh" "$TEST_DIR/missing" <<'TEST' >/dev/null 2>&1
set -euo pipefail
source "$1"
CONFIG_FILE="$2/.install-config.json"
DRY_RUN=false
RESUME=true
die() { exit 1; }
offer_saved_parameters
TEST
then
  echo 'FAIL: resume without original config was accepted' >&2
  exit 1
fi
echo 'PASS: resume without original config fails closed'
