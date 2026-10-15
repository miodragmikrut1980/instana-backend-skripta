#!/usr/bin/env bash
# Air-gapped phase 10 (install_stanctl_airgapped) against a mocked VM: a
# finished import is recognised by the VM marker plus the exact stanctl
# version and never repeated; an intact copy (or full-size .part) is reused
# after a checksum match; low space, a failed import and a lost connection
# during the import stop with HOW TO RESOLVE and keep the copy; a replaced
# local archive stops the resume.
set -euo pipefail
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
cp -R "$(dirname "$0")"/*.sh "$(dirname "$0")"/providers "$TEST_DIR/"
printf 'package-bytes' > "$TEST_DIR/instana-airgapped.tar.gz"
LOCAL_SUM=$(sha256sum "$TEST_DIR/instana-airgapped.tar.gz" | cut -d' ' -f1)
LOCAL_SIZE=$(wc -c < "$TEST_DIR/instana-airgapped.tar.gz" | tr -d ' ')
MARKER_OK="backend=3.290.1-0 stanctl=1.11.0 size=${LOCAL_SIZE}"
CALLS="$TEST_DIR/calls"; OUT="$TEST_DIR/out"

fail() { echo "FAIL: $*" >&2; exit 1; }
must_grep() { grep -q "$@" || fail "expected match: $* (calls: $(tr '\n' ' ' < "$CALLS"))"; }
not_grep() { if grep -q "$@"; then fail "unexpected match: $* (calls: $(tr '\n' ' ' < "$CALLS"))"; fi; }
imported() { [[ "$(jq -r '.step_airgap_imported_vm0 // empty' "$TEST_DIR/.install-state.json")" == completed ]]; }

# run_case — runs phase 10 on vm0 against a VM described by the REMOTE_*
# variables; every remote action is appended to $CALLS, the output goes to
# $OUT, and the exit code is left in RC. Never call it inside if/||/&&: bash
# then ignores errexit in the whole function, also in the subshell, which
# would hide exactly the set -e aborts this test must see.
run_case() {
  : > "$CALLS"
  set +e
  (
    set -euo pipefail
    cd "$TEST_DIR"
    set --   # install.sh parses the positional arguments it is sourced with
    source ./install.sh
    DRY_RUN=false; RESUME=true; INSTALL_MODE=air-gapped
    AIRGAP_ARCHIVE="$TEST_DIR/instana-airgapped.tar.gz"
    STANCTL_CLI_VERSION=1.11.0; BACKEND_VERSION=3.290.1-0
    printf '%s\n' "${STATE:-"{}"}" > "$STATE_FILE"
    remote_exec() {
      local cmd="$4"
      [[ -z "${FAIL_PROBE:-}" || "$cmd" != *"${FAIL_PROBE}="* ]] || return 255
      case "$cmd" in
        *"air-gapped import"*)
          echo "IMPORT retry_max=${SSH_RETRY_MAX}" >> "$CALLS"
          printf '%s\n' "$cmd" > "$TEST_DIR/import_cmd"
          [[ "$cmd" == *"flock -n"* ]] && echo LOCKED >> "$CALLS"
          return "${IMPORT_RC:-0}" ;;
        *"MARKER="*) echo "MARKER=${REMOTE_MARKER:-}" ;;
        *"CLI="*)
          if grep -q '^IMPORT' "$CALLS"; then echo "CLI=stanctl version 1.11.0"
          else echo "CLI=stanctl version ${REMOTE_CLI:-}"; fi ;;
        *"SUM="*".part"*) echo SUM_PART >> "$CALLS"; echo "SUM=${REMOTE_PART_SUM:-}" ;;
        *"SUM="*)         echo SUM >> "$CALLS"; echo "SUM=${REMOTE_SUM:-}" ;;
        *"SIZE="*".part"*) echo "SIZE=${REMOTE_PART_SIZE:-}" ;;
        *"SIZE="*)         echo "SIZE=${REMOTE_SIZE:-}" ;;
        *"FREE="*) echo "FREE=${REMOTE_FREE:-999999999999}" ;;
        "rm -f /tmp/"*) echo CLEAN >> "$CALLS" ;;
        "rm -f /var/tmp/"*) echo DELETE_COPY >> "$CALLS" ;;
        "mv -f /var/tmp/instana-airgapped.tar.gz.part /var/tmp/instana-airgapped.tar.gz") echo MOVE >> "$CALLS" ;;
        *) echo "UNEXPECTED $cmd" >> "$CALLS" ;;
      esac
    }
    gcloud() { [[ "$*" != *"compute scp"* ]] || echo "SCP $*" >> "$CALLS"; }
    install_stanctl_airgapped vm0 zone-a test-project
  ) > "$OUT" 2>&1
  RC=$?
  set -e
  not_grep UNEXPECTED "$CALLS"
}

reset_vm() { unset REMOTE_MARKER REMOTE_CLI REMOTE_SIZE REMOTE_SUM REMOTE_PART_SIZE REMOTE_PART_SUM REMOTE_FREE IMPORT_RC STATE FAIL_PROBE; rm -f "$TEST_DIR/import_cmd"; }

# 1. Import finished earlier (marker + exact stanctl), nothing recorded in local state yet.
reset_vm; REMOTE_MARKER="$MARKER_OK"; REMOTE_CLI=1.11.0
run_case; [[ $RC == 0 ]] || fail "finished import must succeed: $(tail -3 "$OUT")"
not_grep SCP "$CALLS"; not_grep IMPORT "$CALLS"
must_grep DELETE_COPY "$CALLS"
imported || fail "verified import was not recorded in state"
echo 'PASS: finished import (VM marker + exact stanctl) is recognised without copy or import'

# 2. Marker matches but stanctl is a different version that contains 1.11.0 as a substring.
reset_vm; REMOTE_MARKER="$MARKER_OK"; REMOTE_CLI=11.11.0; REMOTE_SIZE=$LOCAL_SIZE; REMOTE_SUM=$LOCAL_SUM
run_case; [[ $RC == 0 ]] || fail "re-import must succeed: $(tail -3 "$OUT")"
must_grep IMPORT "$CALLS"; not_grep SCP "$CALLS"
imported || fail "re-import was not recorded"
echo 'PASS: stanctl version mismatch (exact compare, not substring) re-imports from the kept copy'

# 3. Intact copy from an earlier run.
reset_vm; REMOTE_SIZE=$LOCAL_SIZE; REMOTE_SUM=$LOCAL_SUM
run_case; [[ $RC == 0 ]] || fail "reuse must succeed: $(tail -3 "$OUT")"
must_grep '^SUM$' "$CALLS"; must_grep IMPORT "$CALLS"; not_grep SCP "$CALLS"; not_grep MOVE "$CALLS"
[[ "$(grep -n IMPORT "$CALLS" | cut -d: -f1)" -lt "$(grep -n DELETE_COPY "$CALLS" | cut -d: -f1)" ]] || fail "copy deleted before the import"
imported || fail "import was not recorded"
echo 'PASS: intact copy is reused after checksum match; deleted only after the import'

# 4. Copy of the right size but different content.
reset_vm; REMOTE_SIZE=$LOCAL_SIZE; REMOTE_SUM=deadbeef
run_case; [[ $RC == 0 ]] || fail "replace must succeed: $(tail -3 "$OUT")"
must_grep CLEAN "$CALLS"; must_grep 'SCP .*/var/tmp/instana-airgapped.tar.gz.part' "$CALLS"
must_grep MOVE "$CALLS"; must_grep IMPORT "$CALLS"
echo 'PASS: copy with a different checksum is replaced via .part and rename'

# 5. Full-size .part with matching checksum (transfer finished, rename lost).
reset_vm; REMOTE_PART_SIZE=$LOCAL_SIZE; REMOTE_PART_SUM=$LOCAL_SUM
run_case; [[ $RC == 0 ]] || fail ".part reuse must succeed: $(tail -3 "$OUT")"
must_grep SUM_PART "$CALLS"; must_grep MOVE "$CALLS"; must_grep IMPORT "$CALLS"; not_grep SCP "$CALLS"
echo 'PASS: full-size .part with matching checksum is renamed and reused'

# 6. Nothing on the VM.
reset_vm
run_case; [[ $RC == 0 ]] || fail "fresh copy must succeed: $(tail -3 "$OUT")"
must_grep CLEAN "$CALLS"; must_grep SCP "$CALLS"; must_grep IMPORT "$CALLS"; not_grep SUM "$CALLS"
must_grep 'IMPORT retry_max=1' "$CALLS"; must_grep LOCKED "$CALLS"
must_grep -F '/var/lib/instana-airgap/imported' "$TEST_DIR/import_cmd"
must_grep -F 'backend=%s stanctl=%s size=%s' "$TEST_DIR/import_cmd"
must_grep -F "3.290.1-0 1.11.0 ${LOCAL_SIZE} >" "$TEST_DIR/import_cmd"
must_grep -F 'air-gapped import --file /var/tmp/instana-airgapped.tar.gz 9>&-' "$TEST_DIR/import_cmd"
echo 'PASS: missing copy is transferred; import runs once, under a lock, without SSH retry, and writes the marker'

# 7. Not enough space for copy + import.
reset_vm; REMOTE_FREE=10
run_case; if [[ $RC == 0 ]]; then fail "low space must stop"; fi
must_grep 'HOW TO RESOLVE' "$OUT"; not_grep SCP "$CALLS"; not_grep IMPORT "$CALLS"
if imported; then fail "low space recorded an import"; fi
echo 'PASS: too little free space stops with HOW TO RESOLVE before copying'

# 7b. Enough for one package plus margin, not for copy + import (2x + 5 GiB).
reset_vm; REMOTE_FREE=$(( 5 * 1024 * 1024 * 1024 + 20 ))
run_case; if [[ $RC == 0 ]]; then fail "space for 1x package must not be enough for a new copy"; fi
must_grep 'HOW TO RESOLVE' "$OUT"; not_grep SCP "$CALLS"
echo 'PASS: a new copy needs twice the package size plus 5 GiB'

# 7c. Same space is enough when an intact copy is reused (package + 5 GiB).
reset_vm; REMOTE_FREE=$(( 5 * 1024 * 1024 * 1024 + 20 )); REMOTE_SIZE=$LOCAL_SIZE; REMOTE_SUM=$LOCAL_SUM
run_case; [[ $RC == 0 ]] || fail "reuse with package + margin free must succeed: $(tail -3 "$OUT")"
must_grep IMPORT "$CALLS"; not_grep SCP "$CALLS"
echo 'PASS: reusing a copy needs the package size plus 5 GiB'

# 7d. stanctl prints nothing although the marker matches: re-import, no generic failure box.
reset_vm; REMOTE_MARKER="$MARKER_OK"; REMOTE_CLI=""; REMOTE_SIZE=$LOCAL_SIZE; REMOTE_SUM=$LOCAL_SUM
run_case; [[ $RC == 0 ]] || fail "empty stanctl --version must re-import: $(tail -3 "$OUT")"
must_grep IMPORT "$CALLS"; not_grep 'failed unexpectedly' "$OUT"
imported || fail "re-import after empty stanctl output was not recorded"
echo 'PASS: empty stanctl --version leads to a re-import, not a generic failure'

# 7e. The VM cannot be asked about the marker (SSH failure): stop, never copy or import.
reset_vm; FAIL_PROBE=MARKER
run_case; if [[ $RC == 0 ]]; then fail "failed marker probe must stop"; fi
must_grep 'HOW TO RESOLVE' "$OUT"; must_grep 'Could not check the import marker' "$OUT"
not_grep SCP "$CALLS"; not_grep IMPORT "$CALLS"; not_grep 'failed unexpectedly' "$OUT"
echo 'PASS: a failed marker probe stops with HOW TO RESOLVE instead of copying again'

# 7f. The VM cannot be asked about the copy size: stop, never copy.
reset_vm; FAIL_PROBE=SIZE
run_case; if [[ $RC == 0 ]]; then fail "failed size probe must stop"; fi
must_grep 'Could not check the package copy' "$OUT"; not_grep SCP "$CALLS"; not_grep IMPORT "$CALLS"
echo 'PASS: a failed copy probe stops with HOW TO RESOLVE instead of copying again'

# 8. Import fails.
reset_vm; REMOTE_SIZE=$LOCAL_SIZE; REMOTE_SUM=$LOCAL_SUM; IMPORT_RC=1
run_case; if [[ $RC == 0 ]]; then fail "failed import must stop"; fi
must_grep 'HOW TO RESOLVE' "$OUT"; must_grep 'copy stays' "$OUT"; not_grep DELETE_COPY "$CALLS"
if imported; then fail "failed import was recorded"; fi
echo 'PASS: failed import stops with HOW TO RESOLVE and keeps the copy'

# 9. Connection lost during the import.
reset_vm; REMOTE_SIZE=$LOCAL_SIZE; REMOTE_SUM=$LOCAL_SUM; IMPORT_RC=255
run_case; if [[ $RC == 0 ]]; then fail "lost connection must stop"; fi
[[ "$(grep -c '^IMPORT' "$CALLS")" == 1 ]] || fail "import was retried"
must_grep 'connection to vm0 was lost during the air-gapped import' "$OUT"; not_grep DELETE_COPY "$CALLS"
echo 'PASS: lost connection during import is not retried and keeps the copy'

# 10. VM imported a different package.
reset_vm; REMOTE_MARKER="backend=3.200.0-0 stanctl=1.9.0 size=1"; REMOTE_CLI=1.9.0
run_case; if [[ $RC == 0 ]]; then fail "foreign import must stop"; fi
must_grep 'already imported a different air-gapped package' "$OUT"; not_grep IMPORT "$CALLS"; not_grep SCP "$CALLS"
echo 'PASS: a VM holding a different import stops instead of importing over it'

# 11. Local archive replaced after the recorded import (phase 10 and three-node resume validation).
reset_vm; STATE='{"backend_version":"3.200.0-0","stanctl_cli_version":"1.9.0"}'
run_case; if [[ $RC == 0 ]]; then fail "replaced archive accepted in phase 10"; fi
must_grep 'this deployment imported stanctl 1.9.0 / backend 3.200.0-0' "$OUT"; not_grep IMPORT "$CALLS"
(
  cd "$TEST_DIR"
  set --
  source ./install.sh
  DRY_RUN=false; RESUME=true; INSTALL_MODE=air-gapped
  AIRGAP_ARCHIVE="$TEST_DIR/instana-airgapped.tar.gz"
  STANCTL_CLI_VERSION=1.11.0; BACKEND_VERSION=3.290.1-0
  printf '%s\n' '{"schema_version":1,"parameters":{}}' > "$CONFIG_FILE"
  printf '%s\n' '{"deployment_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","deployment_manifest":"{}","backend_version":"3.290.1-0","stanctl_cli_version":"1.11.0"}' > "$STATE_FILE"
  validate_multinode_resume >/dev/null 2>&1 || fail "matching archive rejected by three-node resume validation"
  BACKEND_VERSION=3.300.0-0
  if (validate_multinode_resume) >/dev/null 2>&1; then fail "replaced archive accepted by three-node resume validation"; fi
)
echo 'PASS: a replaced local archive stops the resume (phase 10 and three-node validation)'
