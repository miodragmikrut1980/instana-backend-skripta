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

# Never offered: a whole disk mounted at /data, a partitioned unmounted disk,
# an LVM member — all large enough and with stable names.
EXTRA_FACT_LINES=(
  "DISK=/dev/sdf|2000000000000|1|/data|ext4|Mounted" "LINK=/dev/disk/by-id/scsi-0Disk_h1_sdf|/dev/sdf"
  "DISK=/dev/sdg|2000000000000|2||gpt|Parted" "LINK=/dev/disk/by-id/scsi-0Disk_h1_sdg|/dev/sdg"
  "DISK=/dev/sdh|2000000000000|1||LVM2_member|Lvm" "LINK=/dev/disk/by-id/scsi-0Disk_h1_sdh|/dev/sdh")
host_facts h1
(
  init
  mapfile -t c < <(prov_ssh_disk_candidates h1 ANALYTICS DISK_DEV_ANALYTICS)
  for d in sdf sdg sdh; do
    if printf '%s\n' "${c[@]}" | grep -q "/dev/$d\$"; then echo "FAIL: /dev/$d offered" >&2; exit 1; fi
  done
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
EXTRA_FACT_LINES=()
echo 'PASS: one disk per role from unused whole disks (not mounted, not partitioned, not LVM), stable by-id paths, a disk is never offered twice'

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
stop_ok "no usable disk" "Host h1: its unused whole disks (/dev/sda 300 GB, mounted at /boot/efi/, partitioned) cannot hold one dedicated disk each for analytics 1200 GB, metrics 1000 GB, objects 1000 GB, data 500 GB." \
  "Attach empty disks of those sizes to h1"

host_facts h1
if ( init; INPUT_NONINTERACTIVE=1; prov_ssh_collect_host_params ) < /dev/null > "$OUT" 2>&1; then echo "FAIL: chose a disk without a terminal" >&2; exit 1; fi
stop_ok "no disk and no terminal" "Host h1: no disk is chosen for the Instana analytics directory (DISK_DEV_ANALYTICS is missing or not usable) and there is no terminal to ask." \
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

# Phase 9 on existing hosts: a disk without a filesystem signature is formatted
# only when its first and last megabyte are zeros.
host_facts h1
( init; base_disks; prov_ssh_check_blank_disk lab disk-data ) > "$OUT" 2>&1
grep -q 'blockdev --getsize64' "$SSH_LOG"
echo SIGNED > "$SCEN/h1.zero"
( init; base_disks; prov_ssh_check_blank_disk lab disk-data ) > "$OUT" 2>&1
echo ZEROCHECK:512:0 > "$SCEN/h1.zero"
if ( init; base_disks; prov_ssh_check_blank_disk lab disk-data ) > "$OUT" 2>&1; then echo "FAIL: non-zero disk accepted" >&2; exit 1; fi
stop_ok "non-zero data without a signature" "Host h1: the disk /dev/disk/by-id/scsi-0Disk_h1_sde has no filesystem signature, but its first or last MiB is not empty (512:0 non-zero bytes)." \
  "sudo wipefs -a /dev/disk/by-id/scsi-0Disk_h1_sde && sudo dd if=/dev/zero of=/dev/disk/by-id/scsi-0Disk_h1_sde bs=1M count=10"
plain | grep -q 'may hold data without a filesystem signature'
rm -f "$SCEN/h1.zero"

# The check runs before mkfs in the single-node flow; a stop there formats nothing.
(
  init; base_disks
  : > "$FAKE_ROOT/calls"
  remote_exec() { echo "$4" >> "$FAKE_ROOT/calls"; [[ "$4" == *"blkid"*"EXISTING_EMPTY"* ]] && echo BLANK; return 0; }
  provider_check_blank_disk() { echo CHECKED >> "$FAKE_ROOT/calls"; exit 3; }
  format_and_mount_disk lab "" "" disk-data /mnt/instana/stanctl/data
) > "$OUT" 2>&1 && { echo "FAIL: format went on after a failed check" >&2; exit 1; }
grep -q CHECKED "$FAKE_ROOT/calls"
if grep -q mkfs "$FAKE_ROOT/calls"; then echo "FAIL: mkfs ran after a failed zero check" >&2; exit 1; fi
echo 'PASS: the zero check runs before mkfs and a failure formats nothing'

# Three-node: the zero check also guards the mount step of node 1 (resume_mount).
three() {
  INSTANA_PROVIDER=ssh resolve_provider
  DRY_RUN=false RESUME=false TOPOLOGY=three-node INSTALL_TYPE=production
  SSH_USER=ubuntu SSH_KEY_PATH="$FAKE_KEY" SSH_PORT=22
  NODE0_NAME=n0 NODE1_NAME=n1 NODE2_NAME=n2 NODE0_HOST=h0 NODE1_HOST=h1 NODE2_HOST=h2
  DISK_DEV_NODE1_DATA=/dev/disk/by-id/scsi-0Disk_h1_sdb GCP_ZONE="" GCP_PROJECT=""
}
echo ZEROCHECK:0:7 > "$SCEN/h1.zero"
: > "$SSH_LOG"
if ( three; resume_mount n1 disk-data /mnt/instana/stanctl/data ) > "$OUT" 2>&1; then echo "FAIL: three-node mount went on over non-zero data" >&2; exit 1; fi
stop_ok "three-node non-zero data" "Host h1: the disk /dev/disk/by-id/scsi-0Disk_h1_sdb has no filesystem signature, but its first or last MiB is not empty (0:7 non-zero bytes)." "sudo wipefs -a /dev/disk/by-id/scsi-0Disk_h1_sdb"
if grep -q mkfs "$SSH_LOG"; then echo "FAIL: mkfs reached the host" >&2; exit 1; fi
rm -f "$SCEN/h1.zero"
( three; resume_mount n1 disk-data /mnt/instana/stanctl/data ) > "$OUT" 2>&1
grep -q mkfs "$SSH_LOG"
echo 'PASS: three-node mount step: non-zero data stops before mkfs, zeros continue'

# A failing read is a stop, never "blank".
echo 1 > "$SCEN/h1.zerorc"
if ( init; base_disks; prov_ssh_check_blank_disk lab disk-data ) > "$OUT" 2>&1; then echo "FAIL: unreadable disk accepted" >&2; exit 1; fi
stop_ok "unreadable disk" "Host h1: the data disk /dev/disk/by-id/scsi-0Disk_h1_sde could not be read before formatting." "sudo blockdev --getsize64 /dev/disk/by-id/scsi-0Disk_h1_sde"
rm -f "$SCEN/h1.zerorc"

# The remote script itself, run against image files: the very last bytes are
# read even when the size is not a multiple of 1 MiB (GPT backup header).
(
  init; base_disks
  remote_exec() { printf '%s' "$4" > "$FAKE_ROOT/zero.sh"; echo ZEROCHECK:0:0; }
  prov_ssh_check_blank_disk lab disk-data > /dev/null 2>&1
)
zero_run() {
  sed -e "s#/dev/disk/by-id/scsi-0Disk_h1_sde#$1#" -e 's#test -b#test -f#' -e 's#blkid "$dev"#false#' \
      -e 's#blockdev --getsize64 "$dev"#stat -c %s "$dev"#' "$FAKE_ROOT/zero.sh" > "$FAKE_ROOT/zero-run.sh"
  bash "$FAKE_ROOT/zero-run.sh" | tail -n 1
}
img="$FAKE_ROOT/disk.img"
head -c 5767168 /dev/zero > "$img"                      # 5.5 MiB, all zeros
test "$(zero_run "$img")" = ZEROCHECK:0:0
printf '\x01' | dd of="$img" bs=1 seek=5600000 conv=notrunc 2>/dev/null   # inside the last 0.5 MiB
test "$(zero_run "$img")" = ZEROCHECK:0:1
head -c 5767168 /dev/zero > "$img"
printf '\x01' | dd of="$img" bs=1 seek=4000 conv=notrunc 2>/dev/null
test "$(zero_run "$img")" = ZEROCHECK:1:0
echo 'PASS: the zero check reads the first MiB and the last MiB by byte offset (5.5 MiB image)'

# Three-node node 1: largest role first, and only disks that keep a complete
# assignment are offered (s4: a 1300 GB disk listed first and smaller ones).
three_disks() {
  EXTRA_FACT_LINES=("$@")
  NO_DATA_DISKS=1 host_facts h1
  EXTRA_FACT_LINES=()
}
three_init() {
  INSTANA_PROVIDER=ssh resolve_provider
  DRY_RUN=false RESUME=false TOPOLOGY=three-node INSTALL_TYPE=production
  SSH_USER=ubuntu SSH_KEY_PATH="$FAKE_KEY" SSH_PORT=22
  NODE0_NAME=n0 NODE1_NAME=n1 NODE2_NAME=n2 NODE0_HOST=h0 NODE1_HOST=h1 NODE2_HOST=h2
  DISK_DEV_NODE0_OBJECTS=/dev/disk/by-id/scsi-0Disk_h0_sdc
  host_facts h0; prov_ssh_gather_facts h0; prov_ssh_gather_facts h1
}
three_disks "DISK=/dev/sdb|1300000000000|1|||Big" "LINK=/dev/disk/by-id/scsi-0Disk_h1_sdb|/dev/sdb" \
            "DISK=/dev/sdc|1050000000000|1|||Mid" "LINK=/dev/disk/by-id/scsi-0Disk_h1_sdc|/dev/sdc" \
            "DISK=/dev/sdd|600000000000|1|||Small" "LINK=/dev/disk/by-id/scsi-0Disk_h1_sdd|/dev/sdd"
( three_init
  # Answer 1 everywhere: in the old order "data" took the 1300 GB disk and analytics was impossible.
  # Node 0 (objects) is asked first, then node 1.
  prov_ssh_collect_host_params < <(printf '1\n1\n1\n1\n') > "$OUT" 2>&1
  test "$DISK_DEV_NODE1_ANALYTICS" = /dev/disk/by-id/scsi-0Disk_h1_sdb
  test "$DISK_DEV_NODE1_METRICS" = /dev/disk/by-id/scsi-0Disk_h1_sdc
  test "$DISK_DEV_NODE1_DATA" = /dev/disk/by-id/scsi-0Disk_h1_sdd )
plain | grep -q 'Disk for analytics on n1'
echo 'PASS: three-node node 1: largest role first, every pick keeps a complete assignment (s4 completes)'

# Two disks fit analytics; only the choice that leaves metrics possible is offered.
three_disks "DISK=/dev/sdb|1250000000000|1|||A" "LINK=/dev/disk/by-id/scsi-0Disk_h1_sdb|/dev/sdb" \
            "DISK=/dev/sdc|2000000000000|1|||B" "LINK=/dev/disk/by-id/scsi-0Disk_h1_sdc|/dev/sdc" \
            "DISK=/dev/sdd|1100000000000|1|||C" "LINK=/dev/disk/by-id/scsi-0Disk_h1_sdd|/dev/sdd" \
            "DISK=/dev/sde|600000000000|1|||D" "LINK=/dev/disk/by-id/scsi-0Disk_h1_sde|/dev/sde"
( three_init
  mapfile -t c < <(prov_ssh_disk_candidates h1 ANALYTICS DISK_DEV_NODE1_ANALYTICS)
  test "${#c[@]}" = 2 )
echo 'PASS: a disk is offered only if the remaining roles still fit'

three_disks "DISK=/dev/sdb|1300000000000|1|||Big" "LINK=/dev/disk/by-id/scsi-0Disk_h1_sdb|/dev/sdb" \
            "DISK=/dev/sdc|900000000000|1|||Mid" "LINK=/dev/disk/by-id/scsi-0Disk_h1_sdc|/dev/sdc" \
            "DISK=/dev/sdd|600000000000|1|||Small" "LINK=/dev/disk/by-id/scsi-0Disk_h1_sdd|/dev/sdd"
: > "$SSH_LOG"
if ( three_init; prov_ssh_collect_host_params ) < /dev/null > "$OUT" 2>&1; then echo "FAIL: impossible assignment accepted" >&2; exit 1; fi
stop_ok "no complete assignment" "Host h1: its unused whole disks (/dev/sda 300 GB, mounted at /boot/efi/, partitioned; /dev/sdb 1300 GB; /dev/sdc 900 GB; /dev/sdd 600 GB) cannot hold one dedicated disk each for analytics 1200 GB, metrics 1000 GB, data 500 GB." "Attach empty disks of those sizes to h1"
if plain | grep -q '^? Disk for'; then echo "FAIL: a pick was asked before the stop" >&2; exit 1; fi
echo 'PASS: without any complete assignment the run stops before the first pick'
plain | grep -vq 'data data' && ! plain | grep -q 'data data'

