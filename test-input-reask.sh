#!/usr/bin/env bash
# Interactive input must never abort silently: an empty or invalid answer is
# re-asked, and the installer stops only after the operator confirms.
# Note: bash prints read -p prompts only on a terminal, so assertions use the
# installer's own messages, not the prompt texts.
set -euo pipefail
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$(dirname "$0")"/{install.sh,parameters.sh,multinode-online.sh,local-access.sh,multinode-resume.sh,hardware-input.sh,capacity-fallback.sh,progress.sh} "$TEST_DIR/"
cd "$TEST_DIR"

run() {  # run INPUT COMMAND...
  local input="$1"; shift
  (
    cmd=("$@"); set --
    source ./install.sh
    "${cmd[@]}"
  ) <<< "$input"
}

# 1. Empty answer, keep going, then a valid value.
out=$(run $'\nn\nmy-project-1\n' eval 'prompt_required GCP_PROJECT "GCP Project ID" "" validate_gcp_project_id; echo RESULT=$GCP_PROJECT' 2>err.txt)
grep -q 'RESULT=my-project-1' <<< "$out"
grep -q 'Continuing; please answer the question again' err.txt
echo "PASS: empty answer is re-asked and a later valid value is accepted"

# 2. Invalid value, keep going, then a valid value.
out=$(run $'BAD_ID\nn\nvalid-project\n' eval 'prompt_required GCP_PROJECT "GCP Project ID" "" validate_gcp_project_id; echo RESULT=$GCP_PROJECT' 2>err.txt)
grep -q 'RESULT=valid-project' <<< "$out"
grep -q 'Invalid GCP Project ID' <<< "$out"
echo "PASS: invalid value is re-asked with the reason"

# 3. Empty answer and confirmed cancellation stops with a clear message, exit 1.
if run $'\ny\n' eval 'prompt_required BASE_DOMAIN "Base domain" "" validate_fqdn; echo RESULT=$BASE_DOMAIN' >out.txt 2>err.txt; then
  echo "FAIL: confirmed cancellation did not stop"; exit 1
fi
grep -q 'cancelled by the operator' err.txt out.txt
! grep -q 'RESULT=' out.txt
echo "PASS: confirmed cancellation stops the installer"

# 4. Closed input (non-interactive) stops instead of looping forever.
if timeout 10 bash -c 'set --; source ./install.sh; prompt_required VM_NAME "VM name" ""' </dev/null >out.txt 2>err.txt; then
  echo "FAIL: closed input did not stop"; exit 1
fi
grep -q 'Input ended' out.txt err.txt
echo "PASS: closed input stops with a message"

# 5. Secrets: empty, continue, then a value.
out=$(run $'\nn\ns3cret\n' eval 'prompt_secret_required SALES_KEY "Sales key" "Sales key"; echo LEN=${#SALES_KEY}' 2>err.txt)
grep -q 'LEN=6' <<< "$out"
! grep -q 's3cret' err.txt
echo "PASS: secret is re-asked and never echoed"

# 6. Air-gapped archive: wrong path, continue, then the real archive; versions land in globals.
mkdir -p pkg/airgapped/config pkg/airgapped/buildmeta
printf 'x' > pkg/airgapped/stanctl
printf 'instana-version: 3.290.1-0\n' > pkg/airgapped/config/instana.yaml
printf 'version: 1.11.0\n' > pkg/airgapped/buildmeta/buildmeta.yaml
tar -czf instana-airgapped.tar.gz -C pkg airgapped
out=$(run $'/nonexistent.tar.gz\nn\n'"$TEST_DIR/instana-airgapped.tar.gz"$'\n' eval '
  while true; do
    prompt_required AIRGAP_ARCHIVE "Archive" "" validate_file_exists "Air-gapped archive"
    inspect_airgapped_archive "$AIRGAP_ARCHIVE" && break
    confirm_cancel
  done
  echo "RESULT=$BACKEND_VERSION/$STANCTL_CLI_VERSION"' 2>err.txt)
grep -q 'RESULT=3.290.1-0/1.11.0' <<< "$out"
echo "PASS: air-gapped archive path is re-asked and versions are detected"

echo "All input re-ask tests passed."
