#!/usr/bin/env bash
# Existing hosts, typed answers (UX v2): hosts first (1 = single-node,
# 3 = three-node), the login is found by trying the local keys and users,
# the read-only host checks run right away, and every failure offers a retry
# menu instead of a stop. Fake ssh from test-ssh-lib.inc, dry-run.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
source "$SRC/test-ssh-lib.inc"
ssh_fakes_setup
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT" "$FAKE_ROOT"' EXIT
# No gcloud project here: the host addresses are typed.
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/bin/gcloud"
printf '#!/usr/bin/env bash\necho 203.0.113.10\n' > "$FAKE_ROOT/bin/curl"
chmod +x "$FAKE_ROOT/bin/gcloud" "$FAKE_ROOT/bin/curl"
KEYS="$FAKE_ROOT/sshdir"; mkdir -p "$KEYS"
cp "$FAKE_KEY" "$KEYS/google_compute_engine"; cp "$FAKE_KEY" "$KEYS/id_ed25519"
export INSTANA_SSH_DIR="$KEYS"
for h in 10.0.0.5 10.0.0.6 inst-a.lab inst-b.lab inst-c.lab; do host_facts "$h"; done

fail() { echo "FAIL: $*" >&2; [[ -f "${OUT:-}" ]] && tail -40 "$OUT" >&2; exit 1; }
has() { grep -qF -- "$1" "$OUT" || fail "expected text not found: $1"; }
hasnt() { if grep -qF -- "$1" "$OUT"; then fail "unexpected text found: $1"; fi; }
count() { grep -cF -- "$1" "$OUT" || true; }
run() {
  local name="$1" input="$2"
  CASE="$TEST_ROOT/$name"; mkdir -p "$CASE"
  cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"
  OUT="$CASE/out.txt"; RC=0
  ( cd "$CASE" && INSTANA_PROVIDER=ssh bash ./install.sh --dry-run <<< "$input" ) > "$OUT.raw" 2>&1 || RC=$?
  sed 's/\x1b\[[0-9;]*m//g' "$OUT.raw" > "$OUT"
}
done_ok() { [[ "$RC" == 0 ]] || fail "exit code $RC"; has "Installation Plan"; has "Dry-run complete"; }
TAIL=$'instana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\ny'

# 1. The first key that the host accepts is found and offered with one Enter.
touch "$SCEN/deny-key-google_compute_engine"
run probe_key $'1\n10.0.0.5\n\n1\n1\n\n'"$TAIL"
done_ok
has "ubuntu @ $KEYS/google_compute_engine   refused"
has "ubuntu @ $KEYS/id_ed25519   OK (port 22)"
has "Use detected login:"
has "SSH login:                     ubuntu on port 22, key $KEYS/id_ed25519"
rm -f "$SCEN/deny-key-google_compute_engine"
echo "PASS: the login is found by trying the keys; the working one is offered"

# 2. ubuntu refused: the local login name is tried next.
me=$(id -un)
touch "$SCEN/10.0.0.5.deny-user-ubuntu"
run probe_user $'1\n10.0.0.5\n\n1\n1\n\n'"$TAIL"
done_ok
has "${me} @ $KEYS/google_compute_engine   OK (port 22)"
has "SSH login:                     ${me} on port 22"
rm -f "$SCEN/10.0.0.5.deny-user-ubuntu"
echo "PASS: when ubuntu is refused, the local login name is tried"

# 3. Unreachable host: retry menu, re-enter the address, continue.
echo 255 > "$SCEN/10.0.0.9.rc"; echo "ssh: connect to host 10.0.0.9 port 22: Connection timed out" > "$SCEN/10.0.0.9.err"
run unreachable $'1\n10.0.0.9\n1\n10.0.0.5\n\n1\n1\n\n'"$TAIL"
done_ok
has "Cannot log in to 10.0.0.9: no answer from 10.0.0.9 on port 22 within 5 s"
has "Check from here: ssh -v -p 22"
has "? What now?"
has "re-enter the address"
has "Host instana-backend:"
grep -qF "Host instana-backend:                 10.0.0.5" "$OUT" || grep -q "Host instana-backend: *10.0.0.5" "$OUT" || fail "plan must use the re-entered host"
echo "PASS: an unreachable host gives the retry menu, not a stop"

# 4. A failed host check (sudo) is shown in the table; choose another host.
host_facts 10.0.0.6 SUDO=no
run bad_check $'1\n10.0.0.6\n\n2\n10.0.0.5\n\n1\n1\n\n'"$TAIL"
done_ok
has "│ sudo        asks for a password"
has "cannot run sudo without a password on 10.0.0.6"
has "sudo tee /etc/sudoers.d/90-instana-installer"
host_facts 10.0.0.6
echo "PASS: a failed host check is explained at the question, with the fix"

# 5. Cancel from the retry menu stops with a plain message, nothing changed.
echo 255 > "$SCEN/10.0.0.8.rc"; echo "ssh: connect to host 10.0.0.8 port 22: Connection refused" > "$SCEN/10.0.0.8.err"
run cancel $'1\n10.0.0.8\n5\n'
[[ "$RC" != 0 ]] || fail "cancel must stop"
has "nothing listens on port 22 of 10.0.0.8 (Connection refused)"
has "Installation cancelled by the operator. Nothing was changed."
echo "PASS: cancel from the retry menu stops cleanly"

# 6. Install type: suggested from CPU/RAM/disks with the reason; production
#    on a host that is too small is explained and asked again.
host_facts 10.0.0.6 CPUS=16 MEM_KB=65000000
run type_small $'1\n10.0.0.6\n\n1\n2\n1\n\n'"$TAIL"
done_ok
has "Suggested from the checks above: demo."
has "production needs 28 vCPU / 112 GB"
has "This host is too small for production"
has "Installation type:             demo"
host_facts 10.0.0.6
run type_big $'1\n10.0.0.5\n\n1\n\n\n'"$TAIL"
done_ok
has "Suggested from the checks above: production."
has "Installation type:             production"
echo "PASS: the install type is suggested from the host, with the reason"

# 7. Three hosts = three-node; names are the hosts' own names (not asked).
run three $'1\ninst-a.lab inst-b.lab inst-c.lab\n\n1\n\n'"$TAIL"
done_ok
has "Topology:                      three-node"
has "NODE0_NAME = inst-a (the host's own name; E at the plan changes it)"
has "Host inst-b:"
hasnt "? Node 0 name"
echo "PASS: three addresses give a three-node deployment named after the hosts"

# 8. Back across the hosts (domain → disks → type → mode → login → hosts):
#    single → three re-asks what depends on the hosts
#    (names, disks, login check) instead of keeping stale single-node values.
run hosts_change $'1\n10.0.0.5\n\n1\n1\n\n<\n<\n<\n<\n<\ninst-a.lab inst-b.lab inst-c.lab\n\n\n\n'"$TAIL"
done_ok
has "Topology:                      three-node"
has "Host inst-a:"
hasnt "Host instana-backend:"
hasnt "VM name:"
[[ "$(count 'Use detected login:')" -ge 2 ]] || fail "the login must be checked again for the new hosts"
echo "PASS: changing the hosts re-asks names, disks and the login"

# 9. A wrong count of addresses is explained and asked again.
run count_bad $'1\n10.0.0.5 10.0.0.6\nn\n10.0.0.5\n\n1\n1\n\n'"$TAIL"
done_ok
has "2 addresses given; give 1 (single-node) or 3 (three-node), separated by spaces."
echo "PASS: 2 addresses are refused with the reason"

# 10. On a Google Cloud control machine the running VMs are listed (internal
#     and external IP, zone, machine type); the control machine is not.
cat > "$FAKE_ROOT/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"config get-value project"*) echo test-project ;;
  *"instances list"*"status=RUNNING"*)
    printf '%s\n' "ctl europe-west6-b 10.172.0.2 34.65.11.204 e2-medium" \
      "ssh-test-1 europe-west6-b 10.0.0.5 34.65.106.11 n2-standard-16" "lab-db europe-west6-b 10.0.0.6 '' n2-standard-8" ;;
esac
exit 0
FAKE
printf '#!/usr/bin/env bash\ncase "$1" in -I) echo 10.172.0.2 ;; *) echo ctl ;; esac\n' > "$FAKE_ROOT/bin/hostname"
chmod +x "$FAKE_ROOT/bin/gcloud" "$FAKE_ROOT/bin/hostname"
run gcloud_list $'1\n2\n\n1\n1\n\n'"$TAIL"
done_ok
has "ssh-test-1             10.0.0.5        34.65.106.11    europe-west6-b  n2-standard-16"
has "a)  enter another address"
hasnt "34.65.11.204"
grep -q " 1)  lab-db " "$OUT" && grep -q " 2)  ssh-test-1 " "$OUT" || fail "list order (own zone, by name)"
grep -q "Host instana-backend: *10.0.0.5 " "$OUT" || fail "the picked VM (2 = ssh-test-1, internal IP 10.0.0.5) must be used"
echo "PASS: the gcloud list shows name, addresses, zone and machine type; the control machine is not listed"

# 11. Disks: one proposed mapping, smallest disk that fits, largest role first.
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/bin/gcloud"; printf '#!/usr/bin/env bash\necho ctl\n' > "$FAKE_ROOT/bin/hostname"
run disk_map $'1\n10.0.0.5\n\n1\n1\n\n'"$TAIL"
done_ok
grep -qE "analytics +≥  500 GB  →  sdb +600 GB" "$OUT" || fail "analytics → sdb"
grep -qE "metrics +≥  300 GB  →  sdc +1100 GB" "$OUT" || fail "metrics → sdc"
grep -qE "data +≥  150 GB  →  sdd +1300 GB" "$OUT" || fail "data → the remaining disk"

echo "PASS: the disk mapping is proposed (smallest fitting disk, largest role first)"

# 12. Three-node node 1 (the review case): data must not take the 1300 GB disk
#     that analytics needs.
run disk_three $'1\ninst-a.lab inst-b.lab inst-c.lab\n\n1\n\n'"$TAIL"
done_ok
grep -qE "analytics +≥ 1200 GB  →  sdd +1300 GB" "$OUT" || fail "node 1 analytics → sdd"
grep -qE "data +≥  500 GB  →  sdb +600 GB" "$OUT" || fail "node 1 data → sdb"
has "inst-c (inst-c.lab): no data disk needed"
echo "PASS: three-node mapping keeps the big disk for analytics"

# 13. c = choose each disk yourself, then the mapping is shown again.
run disk_choose $'1\n10.0.0.5\n\n1\n1\nc\n2\n1\n1\n1\n\n'"$TAIL"
done_ok
has "? Disk for analytics on instana-backend:"
grep -qE "analytics +≥  500 GB  →  sdc +1100 GB" "$OUT" || fail "chosen disk not used"
echo "PASS: c lets the operator choose each disk, then confirm the mapping"

# 14. "<" at the mapping goes back to the install type.
run disk_back $'1\n10.0.0.5\n\n1\n1\n<\n\n\n'"$TAIL"
done_ok
[[ "$(count '? Select installation type:')" == 2 ]] || fail "< at the mapping must go back to the type"
echo "PASS: < at the disk mapping goes back"

# 15. No complete mapping possible: explained with the fix, no stop until cancel.
NO_DATA_DISKS=1 host_facts 10.0.0.7
run disk_none $'1\n10.0.0.7\n\n1\n1\n5\n'
[[ "$RC" != 0 ]] || fail "cancel must stop"
has "no unused disk of at least 500 GB is left for the Instana analytics directory"
has "Attach an empty disk of that size"
has "? What now?"
echo "PASS: a host without suitable disks is explained, with retry options"

# 16. The plan lists the host changes and the network connections; for a
#     host that is a VM of the gcloud project the firewall rules are looked up
#     (read-only): allowed / missing, with the command to add the missing ones.
cat > "$FAKE_ROOT/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"config get-value project"*) echo test-project ;;
  *"instances list"*"networkIP=10.0.0.5"*) echo "ssh-test-1 europe-west6-b default" ;;
  *"instances list"*"status=RUNNING"*) echo "ssh-test-1 europe-west6-b 10.0.0.5 34.65.106.11 n2-standard-16" ;;
  *"firewall-rules list"*) echo '[{"name":"allow-https","allowed":[{"IPProtocol":"tcp","ports":["443"]}],"sourceRanges":["0.0.0.0/0"]},
                                  {"name":"tagged","allowed":[{"IPProtocol":"tcp","ports":["8443"]}],"sourceRanges":["0.0.0.0/0"],"targetTags":["other"]}]' ;;
esac
exit 0
FAKE
chmod +x "$FAKE_ROOT/bin/gcloud"
run plan_network $'1\n1\n\n1\n1\n\n'"$TAIL"
done_ok
has "Changes the installer will make on the host(s) (Y below approves them):"
has "Network (outside the host(s); the installer does not change it):"
has "gcloud firewall rules for ssh-test-1 (network default, read-only check):"
has "✓ allowed from anywhere: TCP 443"
has "✗ missing: TCP 8443, 80"
has "--allow=tcp:8443,tcp:80"
# (a real run's start line; a dry-run shows its own)
( cd "$CASE"; set --; source ./install.sh; INSTANA_PROVIDER=ssh resolve_provider; provider_text start_line ) |
  grep -q "Y also approves the changes on the hosts and confirms the network connections listed" || fail "start line"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/bin/gcloud"
echo "PASS: the plan lists host changes and checks the firewall rules read-only"

# 17. One confirmation: Y at the plan in a terminal is the approval of the host
#     changes (recorded; --resume does not ask again). Without a terminal the
#     changes are never approved.
CASE="$TEST_ROOT/approve"; mkdir -p "$CASE"; cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"
python3 - "$CASE" <<'PY'
import os, pty, sys, time
d = sys.argv[1]
script = ('cd "%s"; set --; source ./install.sh; INSTANA_PROVIDER=ssh resolve_provider; DRY_RUN=false; '
          'TOPOLOGY=single-node VM_HOST=10.0.0.5 SSH_USER=ubuntu SSH_PORT=22; HOST_CHANGES_APPROVED=plan; '
          'prov_ssh_confirm_host_changes; echo APPROVED=$(get_state host_changes_approved)') % d
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", script])
out = b""; end = time.time() + 30
while time.time() < end:
    try:
        b = os.read(fd, 4096)
    except OSError:
        break
    if not b: break
    out += b
os.waitpid(pid, 0)
open(d + "/pty.txt", "wb").write(out)
PY
grep -q "APPROVED=yes" "$CASE/pty.txt" || { cat "$CASE/pty.txt" >&2; fail "plan Y in a terminal must record the approval"; }
if grep -q "Make these changes on the host" "$CASE/pty.txt"; then fail "a second confirmation was asked"; fi
( cd "$CASE"; set --; source ./install.sh; INSTANA_PROVIDER=ssh resolve_provider; DRY_RUN=false RESUME=true
  TOPOLOGY=single-node VM_HOST=10.0.0.5 SSH_USER=ubuntu SSH_PORT=22
  prov_ssh_confirm_host_changes < /dev/null ) > "$CASE/resume.txt" 2>&1 || { cat "$CASE/resume.txt" >&2; fail "resume must not ask again"; }
grep -q "were approved when this deployment was started" "$CASE/resume.txt" || fail "resume message"
rm -f "$CASE/.install-state.json"
if ( cd "$CASE"; set --; source ./install.sh; INSTANA_PROVIDER=ssh resolve_provider; DRY_RUN=false
  TOPOLOGY=single-node VM_HOST=10.0.0.5 SSH_USER=ubuntu SSH_PORT=22; HOST_CHANGES_APPROVED=plan
  prov_ssh_confirm_host_changes < /dev/null ) > "$CASE/notty.txt" 2>&1; then fail "without a terminal the changes must not be approved"; fi
grep -q "must be confirmed in a terminal" "$CASE/notty.txt" || fail "no-terminal message"
echo "PASS: one Y at the plan approves the host changes (terminal only), recorded for --resume"

echo "All existing-host login flow tests passed."
