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

touch "$TEST_ROOT/stanctl.deb" "$TEST_ROOT/instana-airgapped.tar.gz"

run_case() {
  local name="$1" input="$2"
  local case_dir="$TEST_ROOT/$name"
  mkdir -p "$case_dir"
  cp "$SCRIPT_DIR/install.sh" "$case_dir/install.sh"
  (
    cd "$case_dir"
    if ! PATH="$TEST_ROOT/bin:$PATH" bash ./install.sh --dry-run <<< "$input" > output.txt 2>&1; then
      cat output.txt >&2
      return 1
    fi
    grep -q "Installation Plan" output.txt
    grep -q "DRY-RUN MODE" output.txt
    ! grep -q "download-secret" output.txt
    ! grep -q "agent-secret" output.txt
  )
  echo "PASS: $name"
}

COMMON_SINGLE=$'1\n1\n1\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-backend\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nsales-secret\nagent-secret\n1\ny'
run_case single_online "$COMMON_SINGLE"

COMMON_MULTI=$'2\n1\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-0\ninstana-1\ninstana-2\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nsales-secret\nagent-secret\n1\ny'
run_case multi_online "$COMMON_MULTI"

AIR_SINGLE=$'1\n2\n1\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-backend\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nsales-secret\nagent-secret\n'"$TEST_ROOT/stanctl.deb"$'\n'"$TEST_ROOT/instana-airgapped.tar.gz"$'\n1\ny'
run_case single_airgapped "$AIR_SINGLE"

AIR_MULTI=$'2\n2\n1\ntest-project\nus-central1\nus-central1-a\ndefault\ndefault\n203.0.113.10/32\ninstana-0\ninstana-1\ninstana-2\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nsales-secret\nagent-secret\n'"$TEST_ROOT/stanctl.deb"$'\n'"$TEST_ROOT/instana-airgapped.tar.gz"$'\n1\ny'
run_case multi_airgapped "$AIR_MULTI"

echo "All dry-run smoke tests passed."
