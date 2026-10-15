#!/usr/bin/env bash
set -euo pipefail
# destroy.sh against a mock gcloud: which resources are deleted, in which order,
# the confirmation phrase, dry-run, and refusal of state files without resources.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"

# Every call is logged; "describe" succeeds unless the resource name contains "gone".
cat > "$TEST_ROOT/bin/gcloud" <<'GCLOUD'
#!/usr/bin/env bash
echo "$*" >> "$GCLOUD_LOG"
case "$*" in
  *describe*gone*) exit 1 ;;
  *) exit 0 ;;
esac
GCLOUD
chmod +x "$TEST_ROOT/bin/gcloud"

FULL_STATE='{"gcp_project":"test-project","gcp_zone":"us-central1-a","topology":"three-node",
"vm_node-a":"created","vm_node-b":"created","disk_node-a-data":"attached","disk_gone-disk":"created",
"firewall_lab-node-a-ssh":"created","fw_ssh":"created","fw_internal":"created","step_vm":"completed"}'

# run_destroy NAME STATE INPUT [ARGS...] — runs destroy.sh in its own directory.
run_destroy() {
  local name="$1" state="$2" input="$3"; shift 3
  local dir="$TEST_ROOT/$name"
  mkdir -p "$dir"
  cp "$SCRIPT_DIR/destroy.sh" "$dir/destroy.sh"
  printf '%s\n' "$state" > "$dir/.install-state.json"
  : > "$dir/gcloud.log"
  (cd "$dir" && GCLOUD_LOG="$dir/gcloud.log" PATH="$TEST_ROOT/bin:$PATH" \
    bash ./destroy.sh "$@" <<< "$input" > "$dir/output.txt" 2>&1)
}

# 1. Confirmed run: VMs, then disks, then firewall rules; missing resources are skipped.
run_destroy full "$FULL_STATE" 'DELETE test-project/us-central1-a'
d="$TEST_ROOT/full"
# Full command lines: a dropped --project, --zone or --quiet (gcloud would wait
# for Y/n) must fail the test.
grep ' delete ' "$d/gcloud.log" > "$d/deletes.txt"
diff -u - "$d/deletes.txt" <<'EXPECTED'
compute instances delete node-a --project=test-project --zone=us-central1-a --quiet
compute instances delete node-b --project=test-project --zone=us-central1-a --quiet
compute disks delete node-a-data --project=test-project --zone=us-central1-a --quiet
compute firewall-rules delete lab-node-a-ssh --project=test-project --quiet
compute firewall-rules delete instana-allow-ssh --project=test-project --quiet
compute firewall-rules delete instana-allow-internal --project=test-project --quiet
EXPECTED
grep -qx 'compute disks describe gone-disk --project=test-project --zone=us-central1-a' "$d/gcloud.log"
grep -q 'Disk gone-disk not found' "$d/output.txt"
grep -q 'Deleted 6 resource(s); 1 recorded resource(s) no longer existed.' "$d/output.txt"
if [[ -e "$d/.install-state.json" ]]; then echo "FAIL: state file kept after destroy" >&2; exit 1; fi
echo 'PASS: confirmed destroy deletes recorded resources in order and removes the state file'

# 2. Wrong confirmation phrase: nothing deleted, state kept.
run_destroy wrong_phrase "$FULL_STATE" 'DELETE test-project'
d="$TEST_ROOT/wrong_phrase"
if grep -q ' delete ' "$d/gcloud.log"; then echo "FAIL: deleted without confirmation" >&2; exit 1; fi
grep -q 'Aborted.' "$d/output.txt"
test -f "$d/.install-state.json"
echo 'PASS: wrong confirmation phrase aborts without deleting'

# 3. Dry-run: only describe calls, the delete commands are printed, state kept.
run_destroy dry_run "$FULL_STATE" 'DELETE test-project/us-central1-a' --dry-run
d="$TEST_ROOT/dry_run"
if grep -q ' delete ' "$d/gcloud.log"; then echo "FAIL: dry-run deleted a resource" >&2; exit 1; fi
test "$(grep -c '\[DRY-RUN\].*delete' "$d/output.txt")" -eq 6
grep -q 'Preview finished: 6 resource(s) would be deleted, 1 recorded resource(s) no longer exist.' "$d/output.txt"
test -f "$d/.install-state.json"
echo 'PASS: dry-run previews without deleting'

# 4. State without recorded resources is refused and set aside.
if run_destroy progress_only '{"gcp_project":"test-project","gcp_zone":"us-central1-a","step_params":"completed"}' ''; then
  echo "FAIL: progress-only state accepted" >&2; exit 1
fi
d="$TEST_ROOT/progress_only"
grep -q 'records no GCP resources' "$d/output.txt"
if [[ -e "$d/.install-state.json" ]]; then echo "FAIL: unusable state file not set aside" >&2; exit 1; fi
ls "$d"/.install-state.json.*.empty >/dev/null
test ! -s "$d/gcloud.log"
echo 'PASS: state without resources is refused and set aside'

# 5. Missing zone is refused the same way.
if run_destroy no_zone '{"gcp_project":"test-project","vm_node-a":"created"}' ''; then
  echo "FAIL: state without zone accepted" >&2; exit 1
fi
grep -q 'records no GCP resources' "$TEST_ROOT/no_zone/output.txt"
echo 'PASS: state without zone is refused'

# 6. Invalid project ID is refused before any gcloud call.
if run_destroy bad_project '{"gcp_project":"Bad_Project","gcp_zone":"us-central1-a","vm_node-a":"created"}' ''; then
  echo "FAIL: invalid project accepted" >&2; exit 1
fi
grep -q "invalid GCP project ID 'Bad_Project'" "$TEST_ROOT/bad_project/output.txt"
test ! -s "$TEST_ROOT/bad_project/gcloud.log"
echo 'PASS: invalid project ID is refused'
