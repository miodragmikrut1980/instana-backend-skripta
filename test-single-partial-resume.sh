#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$(dirname "$0")"/{install.sh,parameters.sh,multinode-online.sh,local-access.sh,multinode-resume.sh,hardware-input.sh,capacity-fallback.sh,progress.sh} "$TEST_DIR/"
(
  cd "$TEST_DIR"
  source ./install.sh
  DRY_RUN=false
  printf '%s\n' '{"disk_instana-backend-analytics":"created"}' > "$STATE_FILE"
  : > calls
  gcloud() {
    case "$*" in
      *"compute disks describe"*) printf '%s\n' '{"name":"instana-backend-analytics","sizeGb":"500","type":"x/pd-ssd","status":"READY","users":[]}' ;;
      *"compute instances describe"*)
        if grep -q attach-disk calls; then
          printf '%s\n' '{"status":"RUNNING","disks":[{"source":"x/instana-backend-analytics","deviceName":"disk-analytics","boot":false}]}'
        else
          printf '%s\n' '{"status":"RUNNING","disks":[]}'
        fi
        ;;
      *"compute instances attach-disk"*) printf '%s\n' "$*" >> calls ;;
      *) return 1 ;;
    esac
  }
  create_and_attach_disk instana-backend instana-backend-analytics 500 us-central1-a test-project disk-analytics
  grep -q 'attach-disk instana-backend' calls
  [[ "$(get_state disk_instana-backend-analytics)" == attached ]]
)
echo 'PASS: recorded existing disk is validated and attached instead of recreated'

(
  cd "$TEST_DIR"
  source ./install.sh
  DRY_RUN=false
  printf '%s\n' '{}' > "$STATE_FILE"
  prompt_yes_no() { echo 'FAIL: mismatched disk must be rejected before adoption prompt' >&2; exit 1; }
  gcloud() {
    case "$*" in
      *"compute disks describe"*) printf '%s\n' '{"name":"instana-backend-analytics","sizeGb":"1200","type":"x/pd-ssd","status":"READY","users":[]}' ;;
      *) return 1 ;;
    esac
  }
  if (create_and_attach_disk instana-backend instana-backend-analytics 500 us-central1-a test-project disk-analytics) >/dev/null 2>&1; then
    echo 'FAIL: mismatched disk was accepted' >&2
    exit 1
  fi
  [[ -z "$(get_state disk_instana-backend-analytics)" ]]
)
echo 'PASS: mismatched unrecorded disk is rejected without adoption or state ownership'
