#!/usr/bin/env bash
set -euo pipefail
# SSH provider: exact ssh/scp arguments, host lookup, parameter checks and the
# ssh-agent preflight (never reads a passphrase; stops explain themselves).
SRC="$(cd "$(dirname "$0")" && pwd)"
source "$SRC/test-ssh-lib.inc"
ssh_fakes_setup
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR" "$FAKE_ROOT"' EXIT
cp -R "$SRC"/*.sh "$SRC/providers" "$TEST_DIR/"
cd "$TEST_DIR"

base() {
  source ./install.sh
  INSTANA_PROVIDER=ssh resolve_provider
  DRY_RUN=false TOPOLOGY=single-node VM_NAME=lab VM_HOST=10.0.0.5 SSH_USER=ubuntu SSH_KEY_PATH="$FAKE_KEY" SSH_PORT=2222
}

(
  base
  test "$(provider_label)" = "existing hosts"
  : > "$SSH_LOG"
  provider_ssh lab "" "" 'sudo bash -lc id'
  expected="ssh -i $FAKE_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$TEST_DIR/.ssh-known-hosts -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o TCPKeepAlive=yes -p 2222 ubuntu@10.0.0.5 -- sudo bash -lc id"
  [[ "$(cat "$SSH_LOG")" == "$expected" ]] || { echo "FAIL: ssh arguments: $(cat "$SSH_LOG")" >&2; exit 1; }
  : > "$SSH_LOG"
  provider_scp /tmp/x.env lab "" "" /tmp/.stanctl.env
  grep -qx "scp -i $FAKE_KEY .* -P 2222 /tmp/x.env ubuntu@10.0.0.5:/tmp/.stanctl.env" "$SSH_LOG"
  : > "$SSH_LOG"
  provider_ssh_probe lab "" "" 20 5 'cat /proc/sys/kernel/random/boot_id' reboot
  grep -q -- '-o ConnectTimeout=5 -p 2222 ubuntu@10.0.0.5 -- cat /proc/sys/kernel/random/boot_id' "$SSH_LOG"
  test "$(provider_get_ip lab "" "" public)" = 10.0.0.5
  SSH_VIA_PRIVATE=true; test "$(provider_get_ip lab "" "" public)" = unknown
  test "$(provider_hint ssh lab "" "" 'df -h /')" = "ssh -i $FAKE_KEY -p 2222 ubuntu@10.0.0.5 'df -h /'"
  test "$(provider_ssh_port)" = 2222
  TOPOLOGY=three-node NODE0_NAME=n0 NODE1_NAME=n1 NODE2_NAME=n2 NODE0_HOST=h0 NODE1_HOST=h1 NODE2_HOST=h2
  test "$(prov_ssh_host_for n1)" = h1
  test "$(prov_ssh_disk_key_for n1 METRICS)" = DISK_DEV_NODE1_METRICS
  DISK_DEV_NODE1_METRICS=/dev/disk/by-id/scsi-0Disk_m
  test "$(provider_disk_device_path n1 disk-metrics)" = /dev/disk/by-id/scsi-0Disk_m
)
echo 'PASS: ssh/scp/probe arguments, host lookup, IP and hints'

(
  base
  provider_validate_param VM_HOST 10.0.0.5
  provider_validate_param VM_HOST instana-0.example.com
  provider_validate_param SSH_PORT 2222
  provider_validate_param SSH_KEY_PATH "$FAKE_KEY"
  provider_validate_param DISK_DEV_DATA /dev/disk/by-id/scsi-0Google_PersistentDisk_data
  for bad in "VM_HOST 999.1.1.1" "SSH_PORT 70000" "SSH_USER Root" "DISK_DEV_DATA /dev/sdb" "SSH_VIA_PRIVATE yes" "GCP_PROJECT x"; do
    if provider_validate_param $bad >/dev/null 2>&1; then echo "FAIL: accepted: $bad" >&2; exit 1; fi
  done
  echo 'not a key' > "$FAKE_ROOT/plain"
  out=$(provider_validate_param SSH_KEY_PATH "$FAKE_ROOT/plain" 2>&1 || true)
  [[ "$out" == *"is not a private SSH key"* ]]
  NODE0_HOST=h0
  out=$(provider_validate_param NODE1_HOST h0 2>&1 || true)
  [[ "$out" == *"already used for NODE0_HOST"* ]]
  provider_uses_param SSH_SOURCE_CIDR && exit 1
  provider_uses_param BASE_DOMAIN
)
echo 'PASS: SSH parameter checks'

agent_case() {
  ( base; export FAKE_KEY_LOCKED="$1" FAKE_AGENT="$2"; SSH_AUTH_SOCK="${3-/tmp/agent.sock}"; provider_check_auth ) > "$FAKE_ROOT/out" 2>&1
}
agent_case no none ""
echo 'PASS: a key without a passphrase needs no agent'
agent_case yes loaded
grep -q 'is loaded in ssh-agent' "$FAKE_ROOT/out"
echo 'PASS: a locked key already in the agent is used'
if agent_case yes none ""; then echo "FAIL: locked key without agent accepted" >&2; exit 1; fi
o=$(sed 's/\x1b\[[0-9;]*m//g' "$FAKE_ROOT/out")
[[ "$o" == *"is protected by a passphrase, and no ssh-agent is running"* ]]
[[ "$o" == *"Why the installation stops:"* ]]
[[ "$o" == *'eval "$(ssh-agent -s)" && ssh-add'* ]]
[[ "$o" == *"How to continue afterwards"* ]]
echo 'PASS: locked key without an agent stops with the ssh-agent commands'
if agent_case yes empty; then echo "FAIL: locked key not in agent accepted without a terminal" >&2; exit 1; fi
o=$(sed 's/\x1b\[[0-9;]*m//g' "$FAKE_ROOT/out")
[[ "$o" == *"could not be loaded into ssh-agent"* && "$o" == *"ssh-add ${FAKE_KEY}"* && "$o" == *"Why the installation stops:"* && "$o" == *"How to continue afterwards"* ]]
if grep -q "ssh-add ${FAKE_KEY}" "$SSH_LOG"; then echo "FAIL: ssh-add ran without a terminal" >&2; exit 1; fi
echo 'PASS: locked key not in the agent: no prompt without a terminal, explained stop'
