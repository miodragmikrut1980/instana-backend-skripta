#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$(dirname "$0")"/{install.sh,parameters.sh,multinode-online.sh,local-access.sh,multinode-resume.sh,hardware-input.sh,capacity-fallback.sh,progress.sh} "$TEST_DIR/"

(
  cd "$TEST_DIR"
  source ./install.sh
  DRY_RUN=false
  : > calls
  prompt_yes_no() { return 0; }
  remote_exec() {
    local command="$4"
    printf '%s\n' "$command" >> calls
    case "$command" in
      *"EXISTING_NONEMPTY:ext4"*) printf '%s\n' 'EXISTING_EMPTY:ext4:1111-2222' ;;
      *) printf '%s\n' '/dev/sdb /mnt/instana/stanctl/analytics ext4 rw' ;;
    esac
  }
  format_and_mount_disk node0 zone-a project-a disk-analytics /mnt/instana/stanctl/analytics
  grep -q "UUID=1111-2222" calls
  grep -q "mount '/mnt/instana/stanctl/analytics'" calls
  ! grep -q 'mkfs.ext4' calls
)
echo 'PASS: interrupted empty ext4 is adopted without formatting'

(
  cd "$TEST_DIR"
  source ./install.sh
  DRY_RUN=false
  prompt_yes_no() { echo 'FAIL: non-empty filesystem must not prompt for adoption' >&2; exit 1; }
  remote_exec() { printf '%s\n' 'EXISTING_NONEMPTY:ext4:3333-4444'; }
  if (format_and_mount_disk node0 zone-a project-a disk-analytics /mnt/instana/stanctl/analytics) >/dev/null 2>&1; then
    echo 'FAIL: non-empty filesystem was accepted' >&2
    exit 1
  fi
)
echo 'PASS: non-empty ext4 remains blocked and unchanged'
