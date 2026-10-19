#!/usr/bin/env bash
# Clean-up without a recorded deployment: the labs of the project are listed
# (instana-lab-id label groups, single-node VMs with the installer's disk
# names); the control machine and anything without the label or the exact
# names are never listed; a preview deletes nothing and asks no phrase; a
# real run deletes exactly the listed resources (VMs, then disks, then the
# lab's own rules) after the typed DELETE phrase. Fake gcloud with JSON.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
DEL="$TEST_ROOT/deletes.log"; export DEL
cat > "$TEST_ROOT/inst.json" <<'J'
[
 {"name":"instana-0","zone":"z/europe-west6-b","status":"RUNNING","creationTimestamp":"2026-10-18T10:00:00","labels":{"instana-lab-id":"abc"},"networkInterfaces":[{"networkIP":"10.172.0.21"}]},
 {"name":"instana-1","zone":"z/europe-west6-b","status":"RUNNING","creationTimestamp":"2026-10-18T10:01:00","labels":{"instana-lab-id":"abc"},"networkInterfaces":[{"networkIP":"10.172.0.22"}]},
 {"name":"instana-2","zone":"z/europe-west6-b","status":"RUNNING","creationTimestamp":"2026-10-18T10:02:00","labels":{"instana-lab-id":"abc"},"networkInterfaces":[{"networkIP":"10.172.0.23"}]},
 {"name":"mikrut-air","zone":"z/europe-west6-b","status":"TERMINATED","creationTimestamp":"2026-10-10T09:00:00","networkInterfaces":[{"networkIP":"10.172.0.30"}]},
 {"name":"ctl","zone":"z/europe-west6-b","status":"RUNNING","creationTimestamp":"2026-09-01T09:00:00","networkInterfaces":[{"networkIP":"10.172.0.2"}]},
 {"name":"ctl-copy","zone":"z/europe-west6-b","status":"RUNNING","creationTimestamp":"2026-09-01T09:00:00","networkInterfaces":[{"networkIP":"10.172.0.2"}]},
 {"name":"other-vm","zone":"z/europe-west6-b","status":"RUNNING","creationTimestamp":"2026-09-01T09:00:00","networkInterfaces":[{"networkIP":"10.172.0.40"}]}
]
J
cat > "$TEST_ROOT/disks.json" <<'J'
[
 {"name":"instana-0-objects","zone":"z/europe-west6-b","sizeGb":"1000","labels":{"instana-lab-id":"abc"}},
 {"name":"instana-1-data","zone":"z/europe-west6-b","sizeGb":"500","labels":{"instana-lab-id":"abc"}},
 {"name":"mikrut-air","zone":"z/europe-west6-b","sizeGb":"100"},
 {"name":"mikrut-air-analytics","zone":"z/europe-west6-b","sizeGb":"500"},
 {"name":"mikrut-air-data","zone":"z/europe-west6-b","sizeGb":"150"},
 {"name":"ctl-copy-analytics","zone":"z/europe-west6-b","sizeGb":"500"},
 {"name":"other-vm-backup","zone":"z/europe-west6-b","sizeGb":"50"}
]
J
cat > "$TEST_ROOT/fw.json" <<'J'
[ {"name":"instana-lab-abc-ui","description":"instana-lab-id=abc"}, {"name":"instana-allow-https","description":""} ]
J
cat > "$TEST_ROOT/bin/gcloud" <<FAKE
#!/usr/bin/env bash
case "\$*" in
  *"auth list"*) echo tester@example.com ;;
  *"config get-value project"*) echo test-project ;;
  *"instances list"*"--format=json"*) [[ -f "$TEST_ROOT/noaccess.flag" ]] && { echo "ERROR: (gcloud.compute.instances.list) Required 'compute.instances.list' permission for 'projects/test-project'" >&2; exit 1; }; cat "$TEST_ROOT/inst.json" ;;
  *"disks list"*"--format=json"*) cat "$TEST_ROOT/disks.json" ;;
  *"firewall-rules list"*"--format=json"*) cat "$TEST_ROOT/fw.json" ;;
  *"disks describe mikrut-air "*) exit 1 ;;
  *"disks describe"*) exit 0 ;;
  *" delete "*) echo "\$*" >> "\$DEL" ;;
esac
exit 0
FAKE
printf '#!/usr/bin/env bash\ncase "$1" in -I) echo 10.172.0.2 ;; *) echo ctl ;; esac\n' > "$TEST_ROOT/bin/hostname"
printf '#!/usr/bin/env bash\nexit 7\n' > "$TEST_ROOT/bin/curl"
chmod +x "$TEST_ROOT/bin"/*
fail() { echo "FAIL: $*" >&2; [[ -f "${OUT:-}" ]] && tail -30 "$OUT" >&2; exit 1; }
has() { grep -qF -- "$1" "$OUT" || fail "expected text not found: $1"; }
hasnt() { if grep -qF -- "$1" "$OUT"; then fail "unexpected text found: $1"; fi; }
run() {
  local name="$1" input="$2"; shift 2
  CASE="$TEST_ROOT/$name"; mkdir -p "$CASE"; cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"
  OUT="$CASE/out.txt"; RC=0; : > "$DEL"
  ( cd "$CASE" && PATH="$TEST_ROOT/bin:$PATH" bash ./install.sh --destroy "$@" <<< "$input" ) > "$OUT.raw" 2>&1 || RC=$?
  sed 's/\x1b\[[0-9;]*m//g' "$OUT.raw" > "$OUT"
}

# 1. The list: label groups and single-node labs; never the control machine
#    (by name or by IP) or a VM without the label / the exact disk names.
run preview $'\n1' --dry-run
[[ "$RC" == 0 ]] || fail "preview exit $RC"
has "1) three-node lab instana-0, instana-1, instana-2  (zone europe-west6-b)"
has "2) single-node lab mikrut-air  (zone europe-west6-b)"
has "VM mikrut-air               TERMINATED created 2026-10-10"
has "cost: VMs stopped, but the disks are still billed while they exist"
has "disks: 1500 GB in 2 disk(s); firewall rules: 1"
hasnt "lab ctl"; hasnt "ctl-copy"; hasnt "other-vm"
echo "PASS: labs are listed; the control machine and unrelated VMs are not"

# 2. Preview: exactly what would be deleted, no phrase, nothing deleted.
has "firewall rule  instana-lab-abc-ui  (belongs to this lab only)"
hasnt "instana-allow-https"
has "Preview only (dry-run). Nothing was deleted."
hasnt "This permanently deletes everything listed above."
[[ ! -s "$DEL" ]] || fail "a preview must delete nothing"
echo "PASS: the preview shows the resources, asks no phrase and deletes nothing"

# 3. Real run: the phrase, then exactly the listed resources, VMs first.
run real $'\n2\nDELETE test-project/europe-west6-b'
[[ "$RC" == 0 ]] || fail "real run exit $RC"
has "This permanently deletes everything listed above."   # (the phrase prompt itself shows only in a terminal)
head -1 "$DEL" | grep -q "instances delete mikrut-air" || fail "the VM must be deleted first: $(cat "$DEL")"
grep -q "disks delete mikrut-air-analytics" "$DEL" && grep -q "disks delete mikrut-air-data" "$DEL" || fail "the lab disks must be deleted"
[[ "$(wc -l < "$DEL" | tr -d ' ')" == 3 ]] || fail "exactly 3 deletes expected (VM, 2 disks; boot disk went with the VM): $(cat "$DEL")"
if grep -q "firewall\|instana-0\|other-vm\|ctl" "$DEL"; then fail "something outside the lab was deleted: $(cat "$DEL")"; fi
has "Disk mikrut-air is already gone (deleted with its VM)."
echo "PASS: a real run deletes exactly the listed resources, VMs first"

# 4. A three-node lab: its own firewall rule is deleted too, never the shared one.
run real_three $'\n1\nDELETE test-project/europe-west6-b'
grep -q "firewall-rules delete instana-lab-abc-ui" "$DEL" || fail "the lab's own rule must be deleted"
if grep -q "instana-allow-https" "$DEL"; then fail "a shared rule was deleted"; fi
[[ "$(grep -c "instances delete" "$DEL")" == 3 ]] || fail "three VMs expected"
echo "PASS: a three-node lab's own resources are deleted, shared rules are not"

# 5. Wrong phrase: nothing is deleted, not an error.
run wrong $'\n2\ndelete'
[[ "$RC" == 0 && ! -s "$DEL" ]] || fail "a wrong phrase must delete nothing (exit 0)"
has "Confirmation did not match; nothing was deleted."
echo "PASS: a wrong phrase deletes nothing"

# 6. No access: explained, nothing deleted.
touch "$TEST_ROOT/noaccess.flag"
run noaccess $'\n'
rm -f "$TEST_ROOT/noaccess.flag"
[[ "$RC" != 0 && ! -s "$DEL" ]] || fail "a listing error must stop without deleting"
has "The labs of project test-project could not be listed: ERROR: (gcloud.compute.instances.list) Required 'compute.instances.list' permission"
has "HOW TO RESOLVE"
echo "PASS: a listing error is explained and nothing is deleted"

# 7. "<" goes back to the project question.
run back $'\n<\n\n2' --dry-run
[[ "$(grep -c 'Labs in test-project' "$OUT")" == 2 ]] || fail "< must ask the project again and list again"
echo "PASS: < at the list goes back to the project"

echo "All clean-up list tests passed."
