#!/usr/bin/env bash
set -euo pipefail
# Saved SSH parameters (.install-config.json, reuse / --resume) are checked
# again before use: a hostile value stops the run with an explanation and
# nothing is executed — no ssh call, no local or remote command.
SRC="$(cd "$(dirname "$0")" && pwd)"
source "$SRC/test-ssh-lib.inc"
ssh_fakes_setup
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT" "$FAKE_ROOT"' EXIT
host_facts 10.0.0.5
MARK="$TEST_ROOT/pwned"

# saved_case NAME KEY VALUE — a saved single-node ssh deployment with one hostile value.
saved_case() {
  local name="$1" key="$2" value="$3" dir="$TEST_ROOT/$1"
  mkdir -p "$dir"
  cp -R "$SRC"/*.sh "$SRC/providers" "$dir/"
  jq -n --arg k "$key" --arg v "$value" --arg key "$FAKE_KEY" '{schema_version:1, parameters:({
    PROVIDER:"ssh", TOPOLOGY:"single-node", INSTALL_MODE:"online", INSTALL_TYPE:"demo",
    VM_NAME:"lab", VM_HOST:"10.0.0.5", SSH_USER:"ubuntu", SSH_KEY_PATH:$key, SSH_PORT:"22", SSH_VIA_PRIVATE:"false",
    DISK_DEV_ANALYTICS:"/dev/disk/by-id/scsi-0Disk_10.0.0.5_sdb", DISK_DEV_METRICS:"/dev/disk/by-id/scsi-0Disk_10.0.0.5_sdc",
    DISK_DEV_OBJECTS:"/dev/disk/by-id/scsi-0Disk_10.0.0.5_sdd", DISK_DEV_DATA:"/dev/disk/by-id/scsi-0Disk_10.0.0.5_sde",
    BASE_DOMAIN:"instana.example.com", TENANT_NAME:"tenant0", UNIT_NAME:"unit0", TLS_MODE:"auto-generate (self-signed)",
    UBUNTU_VERSION:"", GCP_PROJECT:"", GCP_REGION:"", GCP_ZONE:"", GCP_NETWORK:"", GCP_SUBNET:"", SSH_SOURCE_CIDR:"",
    NODE0_NAME:"", NODE1_NAME:"", NODE2_NAME:"", VM_CPUS:"16", VM_RAM_GB:"64", NODE_CPUS:"", NODE_RAM_GB:"",
    MACHINE_TYPE:"existing host", TLS_CRT_PATH:"", TLS_KEY_PATH:"", AIRGAP_ARCHIVE:""} + {($k): $v})}' > "$dir/.install-config.json"
  chmod 600 "$dir/.install-config.json"
  : > "$SSH_LOG"
  # Menu: 3 = reuse the saved answers of this folder.
  RC=0
  (cd "$dir" && bash ./install.sh --dry-run <<< $'3\n' > out.raw 2>&1) || RC=$?
  sed 's/\x1b\[[0-9;]*m//g' "$dir/out.raw" > "$dir/out.txt"
  OUT="$dir/out.txt"
}

expect_refused() {
  local name="$1" key="$2" o
  [[ "$RC" != 0 ]] || { echo "FAIL: ${name}: hostile ${key} accepted" >&2; tail -20 "$OUT" >&2; exit 1; }
  o=$(cat "$OUT")
  for part in "The saved parameter ${key} cannot be used:" "Why the installation stops:" "jq -r '.parameters.${key}'" "./install.sh --resume"; do
    [[ "$o" == *"$part"* ]] || { echo "FAIL: ${name}: missing '${part}'" >&2; tail -20 "$OUT" >&2; exit 1; }
  done
  if [[ -s "$SSH_LOG" ]] && grep -q '^ssh \|^scp ' "$SSH_LOG"; then echo "FAIL: ${name}: ssh/scp was called: $(cat "$SSH_LOG")" >&2; exit 1; fi
  if [[ -e "$MARK" ]]; then echo "FAIL: ${name}: a hostile command was executed" >&2; exit 1; fi
  echo "PASS: ${name} is refused before any use"
}

saved_case user SSH_USER "-oProxyCommand=touch $MARK"
expect_refused "saved SSH_USER '-oProxyCommand=…'" SSH_USER

saved_case port SSH_PORT "22;touch $MARK"
expect_refused "saved SSH_PORT '22;…'" SSH_PORT

saved_case disk DISK_DEV_DATA "/dev/disk/by-id/x\$(touch $MARK)"
expect_refused "saved DISK_DEV_DATA with \$(…)" DISK_DEV_DATA

saved_case host VM_HOST "10.0.0.5;touch $MARK"
expect_refused "saved VM_HOST '…;…'" VM_HOST

saved_case empty_disk DISK_DEV_OBJECTS ""
expect_refused "saved deployment without a disk" DISK_DEV_OBJECTS

# Defense in depth: phase 2 checks the values again, whatever set them.
(
  set --
  cd "$TEST_ROOT/user"
  source ./install.sh
  INSTANA_PROVIDER=ssh resolve_provider
  TOPOLOGY=single-node VM_NAME=lab VM_HOST=10.0.0.5 SSH_USER=ubuntu SSH_KEY_PATH="$FAKE_KEY" SSH_PORT='2222 -oProxyCommand=x'
  DISK_DEV_ANALYTICS=/dev/disk/by-id/a DISK_DEV_METRICS=/dev/disk/by-id/b DISK_DEV_OBJECTS=/dev/disk/by-id/c DISK_DEV_DATA=/dev/disk/by-id/d
  : > "$SSH_LOG"
  provider_validate_config
) > "$TEST_ROOT/out2" 2>&1 && { echo "FAIL: phase 2 accepted a hostile SSH_PORT" >&2; exit 1; }
grep -q 'The saved parameter SSH_PORT cannot be used' "$TEST_ROOT/out2"
if grep -q '^ssh ' "$SSH_LOG"; then echo "FAIL: phase 2 called ssh before checking" >&2; exit 1; fi
echo 'PASS: phase 2 re-checks every SSH value before the first ssh call'

# Disk links reported by the host are used only when they are plain stable names.
(
  set --
  cd "$TEST_ROOT/user"
  source ./install.sh
  INSTANA_PROVIDER=ssh resolve_provider
  TOPOLOGY=single-node INSTALL_TYPE=demo VM_NAME=lab VM_HOST=10.0.0.5 SSH_USER=ubuntu SSH_KEY_PATH="$FAKE_KEY" SSH_PORT=22
  EXTRA_FACT_LINES=('LINK=/dev/disk/by-id/evil$(id)|/dev/sdf' 'DISK=/dev/sdf|900000000000|1|||Evil')
  NO_DATA_DISKS=1 host_facts 10.0.0.5
  prov_ssh_gather_facts 10.0.0.5
  if prov_ssh_disk_candidates 10.0.0.5 METRICS DISK_DEV_METRICS | grep -q evil; then echo "FAIL: unsafe link offered" >&2; exit 1; fi
)
echo 'PASS: a disk link with shell characters from the host is never offered'
