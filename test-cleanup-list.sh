#!/usr/bin/env bash
# Clean-up without a recorded deployment: the labs of the project are listed
# (instana-lab-id label groups; single-node VMs whose four installer disks
# belong only to them); the control machine, its disks and anything without
# the label or the exact names are never listed; a preview deletes nothing
# and asks no phrase; a real run deletes exactly the listed resources, each
# in its own zone (VMs first, checked gone, then disks, then the lab's rules)
# after the typed DELETE phrase naming every zone, and ends with a
# deleted / NOT deleted table. Fake gcloud with JSON and a state of deletes.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
DEL="$TEST_ROOT/deletes.log"; export DEL TEST_ROOT
U="https://x/zones/europe-west6-b/instances"
cat > "$TEST_ROOT/inst.json" <<J
[
 {"name":"instana-0","zone":"z/europe-west6-b","status":"RUNNING","creationTimestamp":"2026-10-18T10:00:00","labels":{"instana-lab-id":"abc"},"networkInterfaces":[{"networkIP":"10.172.0.21"}]},
 {"name":"instana-1","zone":"z/europe-west6-c","status":"RUNNING","creationTimestamp":"2026-10-18T10:01:00","labels":{"instana-lab-id":"abc"},"networkInterfaces":[{"networkIP":"10.172.0.22"}]},
 {"name":"mikrut-air","zone":"z/europe-west6-b","status":"TERMINATED","creationTimestamp":"2026-10-10T09:00:00","networkInterfaces":[{"networkIP":"10.172.0.30"}]},
 {"name":"web","zone":"z/europe-west6-b","status":"RUNNING","creationTimestamp":"2026-09-01T09:00:00","networkInterfaces":[{"networkIP":"10.172.0.41"}]},
 {"name":"db","zone":"z/europe-west6-b","status":"RUNNING","creationTimestamp":"2026-09-01T09:00:00","networkInterfaces":[{"networkIP":"10.172.0.42"}]},
 {"name":"ctl","zone":"z/europe-west6-b","status":"RUNNING","creationTimestamp":"2026-09-01T09:00:00","networkInterfaces":[{"networkIP":"10.172.0.2"}]},
 {"name":"ctl-copy","zone":"z/europe-west6-b","status":"RUNNING","creationTimestamp":"2026-09-01T09:00:00","networkInterfaces":[{"networkIP":"10.172.0.2"}]}
]
J
cat > "$TEST_ROOT/disks.json" <<J
[
 {"name":"instana-0-objects","zone":"z/europe-west6-b","sizeGb":"1000","labels":{"instana-lab-id":"abc"},"users":["$U/instana-0"]},
 {"name":"instana-1-data","zone":"z/europe-west6-c","sizeGb":"500","labels":{"instana-lab-id":"abc"},"users":["https://x/zones/europe-west6-c/instances/instana-1"]},
 {"name":"old-objects","zone":"z/europe-west6-a","sizeGb":"1000","labels":{"instana-lab-id":"gone1"}},
 {"name":"mikrut-air","zone":"z/europe-west6-b","sizeGb":"100","users":["$U/mikrut-air"]},
 {"name":"mikrut-air-analytics","zone":"z/europe-west6-b","sizeGb":"500","users":["$U/mikrut-air"]},
 {"name":"mikrut-air-metrics","zone":"z/europe-west6-b","sizeGb":"300","users":["$U/mikrut-air"]},
 {"name":"mikrut-air-objects","zone":"z/europe-west6-b","sizeGb":"250"},
 {"name":"mikrut-air-data","zone":"z/europe-west6-b","sizeGb":"150","users":["$U/mikrut-air"]},
 {"name":"web","zone":"z/europe-west6-b","sizeGb":"10","users":["$U/web"]},
 {"name":"web-analytics","zone":"z/europe-west6-b","sizeGb":"500"},
 {"name":"web-metrics","zone":"z/europe-west6-b","sizeGb":"300"},
 {"name":"web-objects","zone":"z/europe-west6-b","sizeGb":"250"},
 {"name":"web-data","zone":"z/europe-west6-b","sizeGb":"150","users":["$U/db"]},
 {"name":"ctl-copy-scratch","zone":"z/europe-west6-b","sizeGb":"50","labels":{"instana-lab-id":"abc"},"users":["$U/ctl-copy"]}
]
J
cat > "$TEST_ROOT/fw.json" <<'J'
[ {"name":"instana-lab-abc-ui","description":"instana-lab-id=abc"}, {"name":"instana-allow-https","description":""} ]
J
cat > "$TEST_ROOT/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
arg() { local k="$1"; shift; for a in "$@"; do [[ "$a" == "--$k="* ]] && { echo "${a#--$k=}"; return; }; done; }
zone=$(arg zone "$@")
case "$*" in
  *"auth list"*) echo tester@example.com ;;
  *"config get-value project"*) echo test-project ;;
  *"instances list"*"--format=json"*) [[ -f "$TEST_ROOT/noaccess.flag" ]] && { echo "ERROR: (gcloud.compute.instances.list) Required 'compute.instances.list' permission for 'projects/test-project'" >&2; exit 1; }; cat "$TEST_ROOT/inst.json" ;;
  *"disks list"*"--format=json"*) cat "$TEST_ROOT/disks.json" ;;
  *"firewall-rules list"*"--format=json"*) cat "$TEST_ROOT/fw.json" ;;
  *"instances describe"*|*"disks describe"*)
    kind=instances; [[ "$*" == *"disks describe"* ]] && kind=disks; name="$4"
    file="$TEST_ROOT/inst.json"; [[ $kind == disks ]] && file="$TEST_ROOT/disks.json"
    gone=no; grep -qx "$kind $name@$zone" "$DEL" 2>/dev/null && gone=yes
    # a boot disk goes with its VM
    [[ $kind == disks ]] && grep -qx "instances $name@$zone" "$DEL" 2>/dev/null && gone=yes
    if [[ $gone == no ]] && jq -e --arg n "$name" --arg z "$zone" 'any(.[]; .name == $n and (.zone | endswith("/" + $z)))' "$file" >/dev/null; then echo "$name"; exit 0; fi
    echo "ERROR: (gcloud.compute.$kind.describe) The resource 'projects/test-project/zones/$zone/$kind/$name' was not found" >&2; exit 1 ;;
  *"firewall-rules describe"*) grep -qx "firewall-rules $4@" "$DEL" 2>/dev/null && { echo "ERROR: was not found" >&2; exit 1; }; echo "$4" ;;
  *" delete "*)
    kind="$2"; name="$4"
    [[ -f "$TEST_ROOT/fail-$name" ]] && { echo "ERROR: (gcloud.compute.$kind.delete) Could not delete $name: resourceInUseByAnotherResource" >&2; exit 1; }
    if [[ $kind != firewall-rules ]]; then
      file="$TEST_ROOT/inst.json"; [[ $kind == disks ]] && file="$TEST_ROOT/disks.json"
      jq -e --arg n "$name" --arg z "$zone" 'any(.[]; .name == $n and (.zone | endswith("/" + $z)))' "$file" >/dev/null ||
        { echo "ERROR: (gcloud.compute.$kind.delete) The resource '$name' was not found in $zone" >&2; exit 1; }
    fi
    echo "$kind $name@$zone" >> "$DEL" ;;
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

# 1. The list: label groups (multi-zone), orphaned labelled resources, and
#    single-node labs whose four disks belong only to them. Never the control
#    machine, its disks, or a VM whose installer-like disk belongs to another VM.
run preview $'\n1' --dry-run
[[ "$RC" == 0 ]] || fail "preview exit $RC"
has "1) three-node lab instana-0, instana-1  (zone europe-west6-b, europe-west6-c)"
has "2) orphaned resources of lab gone1 (no VM left)  (zone europe-west6-a)"
has "3) single-node lab mikrut-air  (zone europe-west6-b)"
hasnt "single-node lab web"; hasnt "lab ctl"
has "disks: 1500 GB in 2 disk(s); firewall rules: 1"
echo "PASS: labs are listed; the control machine, its disks and a VM with a borrowed disk are not"

# 2. Preview: every resource with its own zone, no phrase, nothing deleted.
has "VM    instana-1  (zone europe-west6-c, RUNNING)"
has "disk  instana-1-data  (zone europe-west6-c, 500 GB; the data on it is lost)"
has "firewall rule  instana-lab-abc-ui  (belongs to this lab only)"
hasnt "instana-allow-https"; hasnt "ctl-copy-scratch"
has "Preview only (dry-run). Nothing was deleted."
hasnt "This permanently deletes everything listed above"
[[ ! -s "$DEL" ]] || fail "a preview must delete nothing"
echo "PASS: the preview shows each resource in its zone, asks no phrase and deletes nothing"

# 3. Single-node lab: the phrase, then exactly the lab's VM and disks, VM first.
run real_single $'\n3\nDELETE test-project/europe-west6-b'
[[ "$RC" == 0 ]] || fail "real run exit $RC"
head -1 "$DEL" | grep -qx "instances mikrut-air@europe-west6-b" || fail "the VM must be deleted first: $(cat "$DEL")"
for d in analytics metrics objects data; do grep -qx "disks mikrut-air-$d@europe-west6-b" "$DEL" || fail "disk mikrut-air-$d"; done
[[ "$(wc -l < "$DEL" | tr -d ' ')" == 5 ]] || fail "exactly 5 deletes expected (VM + 4 disks; boot disk went with the VM): $(cat "$DEL")"
has "disk mikrut-air (europe-west6-b, deleted with its VM)"
echo "PASS: a single-node lab: exactly its VM and disks, VM first"

# 4. Multi-zone three-node lab: every delete in the resource's own zone; the
#    phrase names both zones; the lab's own rule, never the shared one.
run real_three $'\n1\nDELETE test-project/europe-west6-b,europe-west6-c'
[[ "$RC" == 0 ]] || fail "multi-zone exit $RC"
grep -qx "instances instana-1@europe-west6-c" "$DEL" || fail "instana-1 must be deleted in its own zone"
grep -qx "disks instana-1-data@europe-west6-c" "$DEL" || fail "instana-1-data must be deleted in its own zone"
grep -qx "firewall-rules instana-lab-abc-ui@" "$DEL" || fail "the lab's own rule"
if grep -q "instana-allow-https\|ctl-copy" "$DEL"; then fail "a shared rule or the control machine's disk was deleted"; fi
echo "PASS: a multi-zone lab is deleted zone by zone, with a phrase naming all zones"

# 5. A failure is not hidden: NOT deleted table, non-zero exit, and the disks
#    of a VM that is still there are not tried.
touch "$TEST_ROOT/fail-instana-1"
run partial $'\n1\nDELETE test-project/europe-west6-b,europe-west6-c'
rm -f "$TEST_ROOT/fail-instana-1"
[[ "$RC" != 0 ]] || fail "an incomplete clean-up must exit non-zero"
has "VM instana-1 was NOT deleted."
has "disk instana-1-data (europe-west6-c): not tried, VM instana-1 still exists"
has "Clean-up of three-node lab instana-0, instana-1 is incomplete: 2 resource(s) were NOT deleted"
if grep -q "disks instana-1-data" "$DEL"; then fail "the disk of a VM that still exists was deleted"; fi
grep -qx "instances instana-0@europe-west6-b" "$DEL" || fail "the other VM is still deleted"
echo "PASS: a partial failure ends with a NOT deleted table and a non-zero exit"

# 6. Wrong phrase (also a single-zone phrase for a multi-zone lab): nothing deleted.
run wrong $'\n1\nDELETE test-project/europe-west6-b'
[[ "$RC" == 0 && ! -s "$DEL" ]] || fail "a wrong phrase must delete nothing (exit 0)"
has "Confirmation did not match; nothing was deleted."
echo "PASS: a wrong phrase deletes nothing"

# 7. No access: explained, nothing deleted.
touch "$TEST_ROOT/noaccess.flag"
run noaccess $'\n'
rm -f "$TEST_ROOT/noaccess.flag"
[[ "$RC" != 0 && ! -s "$DEL" ]] || fail "a listing error must stop without deleting"
has "The labs of project test-project could not be listed: ERROR: (gcloud.compute.instances.list) Required 'compute.instances.list' permission"
has "HOW TO RESOLVE"
echo "PASS: a listing error is explained and nothing is deleted"

# 8. "<" goes back to the project question.
run back $'\n<\n\n1' --dry-run
[[ "$(grep -c 'Labs in test-project' "$OUT")" == 2 ]] || fail "< must ask the project again and list again"
echo "PASS: < at the list goes back to the project"

echo "All clean-up list tests passed."
