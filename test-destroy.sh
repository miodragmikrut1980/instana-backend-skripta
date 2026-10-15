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
"firewall_lab-node-a-ssh":"created","fw_ssh":"created","fw_internal":"created","step_vm":"completed",
"hostdisk_lab-data":"/dev/disk/by-id/x"}'

# run_destroy NAME STATE INPUT [ARGS...] — runs destroy.sh in its own directory.
run_destroy() {
  local name="$1" state="$2" input="$3"; shift 3
  local dir="$TEST_ROOT/$name"
  mkdir -p "$dir"
  cp -R "$SCRIPT_DIR/destroy.sh" "$SCRIPT_DIR/providers" "$dir/"
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

# 4b. Keys of another provider (hostdisk_*) are not GCP resources: the pattern is anchored.
if run_destroy foreign_keys '{"provider":"gcp","gcp_project":"test-project","gcp_zone":"us-central1-a","hostdisk_lab-data":"/dev/disk/by-id/x","myvm_x":"created"}' ''; then
  echo "FAIL: state with only foreign keys accepted" >&2; exit 1
fi
grep -q 'records no GCP resources (project: .test-project., zone: .us-central1-a., recorded resources: 0)' "$TEST_ROOT/foreign_keys/output.txt"
echo 'PASS: only keys that start with vm_/disk_/firewall_/fw_ count as GCP resources'

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

# 7. A copy without the providers folder stops with a restore hint, deleting nothing.
mkdir -p "$TEST_ROOT/no_providers"
cp "$SCRIPT_DIR/destroy.sh" "$TEST_ROOT/no_providers/"
printf '%s\n' "$FULL_STATE" > "$TEST_ROOT/no_providers/.install-state.json"
if (cd "$TEST_ROOT/no_providers" && GCLOUD_LOG=/dev/null PATH="$TEST_ROOT/bin:$PATH" bash ./destroy.sh <<< 'DELETE test-project/us-central1-a' > out.txt 2>&1); then
  echo "FAIL: destroy ran without providers/" >&2; exit 1
fi
grep -q 'providers/common.sh is missing' "$TEST_ROOT/no_providers/out.txt"
test -f "$TEST_ROOT/no_providers/.install-state.json"
echo 'PASS: missing providers/ folder is reported, nothing deleted'

# 8. Existing hosts (provider ssh): only the local state is removed; no remote call at all.
for tool in ssh scp; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$GCLOUD_LOG"\n' "$tool" > "$TEST_ROOT/bin/$tool"; chmod +x "$TEST_ROOT/bin/$tool"; done
SSH_STATE='{"provider":"ssh","ssh_target":"ubuntu@10.0.0.5:22","topology":"single-node","host_lab":"checked","hostid_lab":"mid","hostdisk_lab-data":"/dev/disk/by-id/scsi-0d"}'
run_destroy ssh_preview "$SSH_STATE" 'DELETE state/ubuntu@10.0.0.5:22' --dry-run
d="$TEST_ROOT/ssh_preview"
grep -q 'nothing on the hosts is deleted or changed' "$d/output.txt"
grep -q 'Preview finished: only the local state of this folder would be removed; nothing on the hosts.' "$d/output.txt"
test -f "$d/.install-state.json"
run_destroy ssh "$SSH_STATE" 'DELETE state/ubuntu@10.0.0.5:22'
d="$TEST_ROOT/ssh"
test ! -s "$d/gcloud.log"
grep -q "This folder's record of the deployment was removed; nothing on the hosts was deleted or changed." "$d/output.txt"
grep -q 'sudo /usr/local/bin/k3s-uninstall.sh' "$d/output.txt"
if [[ -e "$d/.install-state.json" ]]; then echo "FAIL: ssh state kept" >&2; exit 1; fi
echo 'PASS: provider ssh: destroy forgets the local state only, no ssh or gcloud call'

