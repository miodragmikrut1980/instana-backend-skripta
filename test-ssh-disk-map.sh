#!/usr/bin/env bash
set -euo pipefail
# SSH provider data disks: which disks are offered per role, stable paths,
# values from an input file, and the explained stops of phase 4.
SRC="$(cd "$(dirname "$0")" && pwd)"
source "$SRC/test-ssh-lib.inc"
ssh_fakes_setup
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR" "$FAKE_ROOT"' EXIT
cp -R "$SRC"/*.sh "$SRC/providers" "$TEST_DIR/"
cd "$TEST_DIR"
OUT="$FAKE_ROOT/out"

# install.sh is sourced at the top level of each subshell (its declare -A
# arrays would become local inside a function); init sets the deployment.
set --
source ./install.sh
init() {
  INSTANA_PROVIDER=ssh resolve_provider
  DRY_RUN=false RESUME=false TOPOLOGY=single-node INSTALL_TYPE=demo
  SSH_USER=ubuntu SSH_KEY_PATH="$FAKE_KEY" SSH_PORT=22 VM_NAME=lab VM_HOST=h1
  prov_ssh_gather_facts h1
}
plain() { sed 's/\x1b\[[0-9;]*m//g' "$OUT"; }

host_facts h1
(
  init
  mapfile -t c < <(prov_ssh_disk_candidates h1 ANALYTICS DISK_DEV_ANALYTICS)
  test "${#c[@]}" = 4
  test "${c[0]}" = "/dev/disk/by-id/scsi-0Disk_h1_sdb|600|PersistentDisk|/dev/sdb"
  # The root disk (partitions, mounted) is never offered.
  if printf '%s\n' "${c[@]}" | grep -q sda; then echo "FAIL: root disk offered" >&2; exit 1; fi
  prov_ssh_collect_host_params < <(printf '1\n1\n1\n1\n') > "$OUT" 2>&1
  test "$DISK_DEV_ANALYTICS" = /dev/disk/by-id/scsi-0Disk_h1_sdb
  test "$DISK_DEV_METRICS" = /dev/disk/by-id/scsi-0Disk_h1_sdc
  test "$DISK_DEV_OBJECTS" = /dev/disk/by-id/scsi-0Disk_h1_sdd
  test "$DISK_DEV_DATA" = /dev/disk/by-id/scsi-0Disk_h1_sde
  test "$(provider_disk_device_path lab disk-objects)" = /dev/disk/by-id/scsi-0Disk_h1_sdd
  prov_ssh_ensure_disks > "$OUT" 2>&1
  grep -q 'lab: analytics → /dev/disk/by-id/scsi-0Disk_h1_sdb (600 GB, now /dev/sdb)' "$OUT"
)
echo 'PASS: one disk per role from unused whole disks, stable by-id paths, a disk is never offered twice'

(
  init
  PARAMS_SOURCE=import; IMPORTED=([DISK_DEV_ANALYTICS]=/dev/disk/by-id/wwn-0x5000_sdd [DISK_DEV_METRICS]=/dev/sdc)
  prov_ssh_collect_host_params < <(printf '1\n1\n1\n') > "$OUT" 2>&1
  test "$DISK_DEV_ANALYTICS" = /dev/disk/by-id/wwn-0x5000_sdd
  plain | grep -q "DISK_DEV_METRICS from the input file cannot be used"
  test "$DISK_DEV_METRICS" = /dev/disk/by-id/scsi-0Disk_h1_sdb
)
echo 'PASS: a valid path from the input file is taken (any by-id name of the disk); /dev/sdX is refused and asked'

stop_ok() {
  local name="$1" found="$2" fix="$3" o
  o=$(plain)
  for part in "$found" "Why the installation stops:" "$fix" "How to continue afterwards:"; do
    [[ "$o" == *"$part"* ]] || { echo "FAIL: ${name}: missing '${part}'" >&2; echo "$o" | tail -15 >&2; exit 1; }
  done
  echo "PASS: ${name} stops with an explanation"
}

NO_DATA_DISKS=1 host_facts h1
if ( init; INSTALL_TYPE=production; prov_ssh_collect_host_params ) < /dev/null > "$OUT" 2>&1; then echo "FAIL: no disk accepted" >&2; exit 1; fi
stop_ok "no usable disk" "Host h1: no unused disk of at least 1200 GB is available for the analytics data (/dev/sda 300 GB, mounted at /boot/efi/, partitioned)." \
  "Attach an empty disk of at least 1200 GB to h1"

host_facts h1
if ( init; INPUT_NONINTERACTIVE=1; prov_ssh_collect_host_params ) < /dev/null > "$OUT" 2>&1; then echo "FAIL: chose a disk without a terminal" >&2; exit 1; fi
stop_ok "no disk and no terminal" "Host h1: no disk is chosen for the analytics data (DISK_DEV_ANALYTICS is missing or not usable) and there is no terminal to ask." \
  '"DISK_DEV_ANALYTICS": /dev/disk/by-id/scsi-0Disk_h1_sdb'

base_disks() { DISK_DEV_ANALYTICS=/dev/disk/by-id/scsi-0Disk_h1_sdb DISK_DEV_METRICS=/dev/disk/by-id/scsi-0Disk_h1_sdc DISK_DEV_OBJECTS=/dev/disk/by-id/scsi-0Disk_h1_sdd DISK_DEV_DATA=/dev/disk/by-id/scsi-0Disk_h1_sde; }
if ( init; base_disks; DISK_DEV_DATA=/dev/disk/by-id/scsi-0Disk_gone; prov_ssh_ensure_disks ) > "$OUT" 2>&1; then echo "FAIL: missing disk accepted" >&2; exit 1; fi
stop_ok "chosen disk missing" "Host h1: the disk chosen for data (DISK_DEV_DATA=/dev/disk/by-id/scsi-0Disk_gone) is not present" \
  "Reattach that disk to h1"

EXTRA_FACT_LINES=()
host_facts h1
edit_facts() { sed "$1" "$SCEN/h1.facts" > "$SCEN/h1.tmp" && mv "$SCEN/h1.tmp" "$SCEN/h1.facts"; }
edit_facts 's#^DISK=/dev/sdc|1100000000000|1|||#DISK=/dev/sdc|1100000000000|1|/srv/old|ext4|#'
if ( init; base_disks; prov_ssh_ensure_disks ) > "$OUT" 2>&1; then echo "FAIL: mounted disk accepted" >&2; exit 1; fi
stop_ok "chosen disk mounted elsewhere" "Host h1: the disk for metrics (/dev/disk/by-id/scsi-0Disk_h1_sdc, now /dev/sdc) is mounted at /srv/old." \
  "lsblk -p /dev/sdc"

edit_facts 's#|/srv/old|ext4|#|/mnt/instana/stanctl/metrics|ext4|#'
( init; base_disks; RESUME=true; prov_ssh_ensure_disks ) > "$OUT" 2>&1
echo 'PASS: on resume a disk already mounted at its own Instana path is accepted'
