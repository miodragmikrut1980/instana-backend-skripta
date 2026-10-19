#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/gcloud" <<'GCLOUD'
#!/usr/bin/env bash
case "$*" in
  *"auth list"*) echo tester@example.com ;;
  *"regions describe"*) printf '%s\n' '{"quotas":[{"metric":"CPUS","limit":999,"usage":0}]}' ;;
  *"instances describe"*) exit 1 ;;
  *) exit 0 ;;
esac
GCLOUD
chmod +x "$TEST_ROOT/bin/gcloud"

cat > "$TEST_ROOT/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo 203.0.113.10
CURL
chmod +x "$TEST_ROOT/bin/curl"

# Minimal archive with the layout produced by 'stanctl air-gapped package'.
mkdir -p "$TEST_ROOT/pkg/airgapped/config" "$TEST_ROOT/pkg/airgapped/buildmeta"
printf '#!/bin/sh\necho stanctl version 1.10.9\n' > "$TEST_ROOT/pkg/airgapped/stanctl"
printf 'instana-version: 3.285.123-0\nregistry:\n  url: artifact-public.instana.io\n' > "$TEST_ROOT/pkg/airgapped/config/instana.yaml"
printf 'version: 1.10.9\ncommitDate: 2026-01-01\ncommitHash: abc\n' > "$TEST_ROOT/pkg/airgapped/buildmeta/buildmeta.yaml"
tar -czf "$TEST_ROOT/instana-airgapped.tar.gz" -C "$TEST_ROOT/pkg" airgapped

# Existing hosts (PROVIDER ssh): fake ssh/scp answer for the hosts (test-ssh-lib.inc).
source "$SCRIPT_DIR/test-ssh-lib.inc"
ssh_fakes_setup
trap 'rm -rf "$TEST_ROOT" "$FAKE_ROOT"' EXIT
for h in 10.0.0.5 10.0.0.11 10.0.0.12 10.0.0.13; do host_facts "$h"; done

run_case() {
  local name="$1" input="$2" provider="${3:-}"
  local case_dir="$TEST_ROOT/$name"
  mkdir -p "$case_dir"
  cp -R "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/providers" "$case_dir/"
  (
    cd "$case_dir"
    if ! INSTANA_PROVIDER="$provider" PATH="$TEST_ROOT/bin:$PATH" bash ./install.sh --dry-run <<< "$input" > output.txt 2>&1; then
      cat output.txt >&2
      return 1
    fi
    grep -q "Installation Plan" output.txt
    grep -q "DRY-RUN MODE" output.txt
    grep -q '\[PHASE 1/12\]' output.txt
    grep -q '\[PHASE 12/12\]' output.txt
    grep -q 'Installation checklist' output.txt
    grep -q '100% complete' output.txt
    grep -q 'Enter Y and press Enter to run the dry-run simulation' output.txt
    grep -q 'Enter N, or press Enter without typing anything, to cancel without starting' output.txt
    grep -q 'sudo kubectl get nodes' output.txt
    grep -q 'sudo kubectl get pods -A' output.txt
    grep -q 'Dry-run complete — nothing was created or changed' output.txt
    if grep -q 'Installation Complete!\|External IP:.*DRY-RUN\|^DRY-RUN ' output.txt; then echo "FAIL: $name: dry-run shows a completed installation or a fake IP" >&2; exit 1; fi
    if grep -q "download-secret" output.txt; then echo "FAIL: test-dry-run.sh:62: unexpected match" >&2; exit 1; fi
    if grep -q "agent-secret" output.txt; then echo "FAIL: test-dry-run.sh:63: unexpected match" >&2; exit 1; fi
    if [[ "$name" == single_airgapped_to_online ]]; then
      grep -q 'Air-gapped installation package' output.txt
      grep -q 'Switched to an online installation' output.txt
      grep -q -- "--instana-version 'DRY-RUN-COMPATIBLE-SELECTION'" output.txt
      if grep -q 'import backend' output.txt; then echo "FAIL: test-dry-run.sh:68: unexpected match" >&2; exit 1; fi
    elif [[ "$name" == *airgapped || "$name" == *airgapped_ssh ]]; then
      grep -q 'Air-gapped installation package' output.txt
      grep -q 'stanctl 1.10.9 → Instana backend 3.285.123-0' output.txt
      grep -q 'extract stanctl 1.10.9 from it and import backend 3.285.123-0' output.txt
      if grep -q 'instana-version' output.txt; then echo "FAIL: test-dry-run.sh:73: unexpected match" >&2; exit 1; fi
      if grep -q 'dpkg' output.txt; then echo "FAIL: test-dry-run.sh:74: unexpected match" >&2; exit 1; fi
      # The package explanation itself says no separate stanctl .deb is needed; any other .deb is a failure.
      if awk '/\.deb/ && !/No separate stanctl \.deb package is needed/ {found=1} END {exit !found}' output.txt; then echo "FAIL: test-dry-run.sh:76: unexpected .deb in the air-gapped output" >&2; exit 1; fi
    else
      grep -q -- "--instana-version 'DRY-RUN-COMPATIBLE-SELECTION'" output.txt
    fi
    if [[ "$name" == *_ssh ]]; then
      if grep -q 'gcloud\|GCP Project\|SSH source CIDR\|Creating VM' output.txt; then echo "FAIL: $name: GCP step in an existing-host run" >&2; exit 1; fi
      grep -q '\[PHASE 3/12\] Host checks (OS, CPU, RAM, sudo)' output.txt
      grep -q '\[PHASE 4/12\] Data disk mapping' output.txt
      grep -q '\[PHASE 5/12\] Network port checklist' output.txt
      grep -q 'Install on:                    existing host(s), nothing is created or deleted' output.txt
      grep -q 'REBOOT of each host' output.txt
      if grep -q 'GCP\|Ubuntu version:\|Capacity check and virtual machines\|Dedicated data disks' output.txt; then echo "FAIL: $name: GCP wording in an existing-host run: $(grep -m3 'GCP\|Ubuntu version:\|Capacity check\|Dedicated data disks' output.txt)" >&2; exit 1; fi
      grep -q 'Dry-run mode — nothing will be changed on the hosts' output.txt
      grep -q '  \[ \] 3/12 Host checks (OS, CPU, RAM, sudo)' output.txt
    fi
    if [[ "$name" == single_online_ssh ]]; then
      grep -q 'ufw allow 2222/tcp' output.txt
      grep -q 'analytics disk:              /dev/disk/by-id/scsi-0Disk_10.0.0.5_sdb → /mnt/instana/stanctl/analytics' output.txt
      grep -q 'ssh .* -p 2222 -l ubuntu -- 10.0.0.5 ' "$SSH_LOG"
    fi
    if [[ "$name" == multi_airgapped_ssh ]]; then
      grep -q 'objects disk:                /dev/disk/by-id/scsi-0Disk_10.0.0.11_sdc → /mnt/instana/stanctl/objects' output.txt
      grep -q 'analytics disk:              /dev/disk/by-id/scsi-0Disk_10.0.0.12_sdd → /mnt/instana/stanctl/analytics' output.txt
      test "$(grep -c '\[INFO\].*Formatting and mounting' output.txt)" -eq 4
    fi
    if [[ "$name" == multi_online ]]; then
      test "$(grep -c '\[INFO\].*Creating VM:' output.txt)" -eq 3
      test "$(grep -c '\[INFO\].*Creating disk ' output.txt)" -eq 4
      test "$(grep -c '\[INFO\].*Formatting and mounting' output.txt)" -eq 4
      grep -q 'lab-instana-0' output.txt
      grep -q '270GB' output.txt
    fi
  )
  echo "PASS: $name"
}

# Input order: parameter-source menu (1 = enter manually), then the questions.
COMMON_SINGLE=$'1\n1\n1\n1\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-backend\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\ny'
run_case single_online "$COMMON_SINGLE"

COMMON_MULTI=$'1\n2\n1\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-0\ninstana-1\ninstana-2\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\ny'
run_case multi_online "$COMMON_MULTI"

AIR_SINGLE=$'1\n1\n2\n1\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-backend\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\n'"$TEST_ROOT/instana-airgapped.tar.gz"$'\n1\ny'
run_case single_airgapped "$AIR_SINGLE"

AIR_MULTI=$'1\n2\n2\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-0\ninstana-1\ninstana-2\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\n'"$TEST_ROOT/instana-airgapped.tar.gz"$'\n1\ny'
run_case multi_airgapped "$AIR_MULTI"

# Air-gapped selected, no package available: the operator switches to online from the package menu.
AIR_TO_ONLINE=$'1\n1\n2\n1\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-backend\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n3\n1\ny'
run_case single_airgapped_to_online "$AIR_TO_ONLINE"

# Existing hosts: no Ubuntu image, SSH CIDR or size questions; one disk per data directory.
SSH_SINGLE=$'1\n1\n1\n1\n10.0.0.5\nubuntu\n'"$FAKE_KEY"$'\n2222\nlab-host\n1\n1\n1\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\ny'
run_case single_online_ssh "$SSH_SINGLE" ssh

SSH_AIR_MULTI=$'1\n2\n2\n10.0.0.11\n10.0.0.12\n10.0.0.13\nubuntu\n'"$FAKE_KEY"$'\n22\n1\nnode-a\nnode-b\nnode-c\n1\n1\n1\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\n'"$TEST_ROOT/instana-airgapped.tar.gz"$'\n1\ny'
run_case multi_airgapped_ssh "$SSH_AIR_MULTI" ssh

echo "All dry-run smoke tests passed."
