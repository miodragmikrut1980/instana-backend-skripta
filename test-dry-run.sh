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

run_case() {
  local name="$1" input="$2"
  local case_dir="$TEST_ROOT/$name"
  mkdir -p "$case_dir"
  cp "$SCRIPT_DIR/install.sh" "$case_dir/install.sh"
  cp "$SCRIPT_DIR/parameters.sh" "$case_dir/parameters.sh"
  cp "$SCRIPT_DIR/multinode-online.sh" "$case_dir/multinode-online.sh"
  cp "$SCRIPT_DIR/local-access.sh" "$case_dir/local-access.sh"
  cp "$SCRIPT_DIR/multinode-resume.sh" "$case_dir/multinode-resume.sh"
  cp "$SCRIPT_DIR/hardware-input.sh" "$case_dir/hardware-input.sh"
  cp "$SCRIPT_DIR/capacity-fallback.sh" "$case_dir/capacity-fallback.sh"
  cp "$SCRIPT_DIR/progress.sh" "$case_dir/progress.sh"
  (
    cd "$case_dir"
    if ! PATH="$TEST_ROOT/bin:$PATH" bash ./install.sh --dry-run <<< "$input" > output.txt 2>&1; then
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
    grep -q 'Ready-to-copy /etc/hosts entries' output.txt
    ! grep -q "download-secret" output.txt
    ! grep -q "agent-secret" output.txt
    if [[ "$name" == single_airgapped_to_online ]]; then
      grep -q 'Air-gapped installation package' output.txt
      grep -q 'Switched to an online installation' output.txt
      grep -q -- "--instana-version 'DRY-RUN-COMPATIBLE-SELECTION'" output.txt
      ! grep -q 'import backend' output.txt
    elif [[ "$name" == *airgapped ]]; then
      grep -q 'Air-gapped installation package' output.txt
      grep -q 'stanctl 1.10.9 → Instana backend 3.285.123-0' output.txt
      grep -q 'extract stanctl 1.10.9 from it and import backend 3.285.123-0' output.txt
      ! grep -q 'instana-version' output.txt
      ! grep -q 'dpkg' output.txt
      ! grep -q '\.deb' output.txt
    else
      grep -q -- "--instana-version 'DRY-RUN-COMPATIBLE-SELECTION'" output.txt
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

COMMON_SINGLE=$'1\n1\n1\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-backend\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nsales-secret\nagent-secret\n1\ny'
run_case single_online "$COMMON_SINGLE"

COMMON_MULTI=$'2\n1\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-0\ninstana-1\ninstana-2\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nsales-secret\nagent-secret\n1\ny'
run_case multi_online "$COMMON_MULTI"

AIR_SINGLE=$'1\n2\n1\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-backend\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nsales-secret\nagent-secret\n1\n'"$TEST_ROOT/instana-airgapped.tar.gz"$'\n1\ny'
run_case single_airgapped "$AIR_SINGLE"

AIR_MULTI=$'2\n2\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-0\ninstana-1\ninstana-2\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nsales-secret\nagent-secret\n1\n'"$TEST_ROOT/instana-airgapped.tar.gz"$'\n1\ny'
run_case multi_airgapped "$AIR_MULTI"

# Air-gapped selected, no package available: the operator switches to online from the package menu.
AIR_TO_ONLINE=$'1\n2\n1\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-backend\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nsales-secret\nagent-secret\n3\n1\ny'
run_case single_airgapped_to_online "$AIR_TO_ONLINE"

echo "All dry-run smoke tests passed."
