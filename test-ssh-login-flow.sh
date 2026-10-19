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
run probe_key $'10.0.0.5\n\n1\n1\n\n'"$TAIL"
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
run probe_user $'10.0.0.5\n\n1\n1\n\n'"$TAIL"
done_ok
has "${me} @ $KEYS/google_compute_engine   OK (port 22)"
has "SSH login:                     ${me} on port 22"
rm -f "$SCEN/10.0.0.5.deny-user-ubuntu"
echo "PASS: when ubuntu is refused, the local login name is tried"

# 3. Unreachable host: retry menu, re-enter the address, continue.
echo 255 > "$SCEN/10.0.0.9.rc"; echo "ssh: connect to host 10.0.0.9 port 22: Connection timed out" > "$SCEN/10.0.0.9.err"
run unreachable $'10.0.0.9\n1\n10.0.0.5\n\n1\n1\n\n'"$TAIL"
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
run bad_check $'10.0.0.6\n\n2\n10.0.0.5\n\n1\n1\n\n'"$TAIL"
done_ok
has "│ sudo        asks for a password"
has "cannot run sudo without a password on 10.0.0.6"
has "sudo tee /etc/sudoers.d/90-instana-installer"
host_facts 10.0.0.6
echo "PASS: a failed host check is explained at the question, with the fix"

# 5. Cancel from the retry menu stops with a plain message, nothing changed.
echo 255 > "$SCEN/10.0.0.8.rc"; echo "ssh: connect to host 10.0.0.8 port 22: Connection refused" > "$SCEN/10.0.0.8.err"
run cancel $'10.0.0.8\n5\n'
[[ "$RC" == 0 ]] || fail "an operator cancel must exit 0 (like N at the plan), got $RC"
has "nothing listens on port 22 of 10.0.0.8 (Connection refused)"
has "Installation cancelled by the operator. Nothing was created or changed."
hasnt "Installation Plan"
echo "PASS: cancel from the retry menu stops cleanly"

# 6. Install type: suggested from CPU/RAM/disks with the reason; production
#    on a host that is too small is explained and asked again.
host_facts 10.0.0.6 CPUS=16 MEM_KB=65000000
run type_small $'10.0.0.6\n\n1\n2\n1\n\n'"$TAIL"
done_ok
has "Suggested from the checks above: demo ("
has "production needs 28 vCPU / 112 GB"
has "This host is too small for production"
has "Installation type:             demo"
host_facts 10.0.0.6
run type_big $'10.0.0.5\n\n1\n\n\n'"$TAIL"
done_ok
has "Suggested from the checks above: production ("
has "Installation type:             production"
echo "PASS: the install type is suggested from the host, with the reason"

# 7. Three hosts = three-node; names are the hosts' own names (not asked).
run three $'inst-a.lab inst-b.lab inst-c.lab\n\n1\n\n'"$TAIL"
done_ok
has "Topology:                      three-node"
has "NODE0_NAME = inst-a (the host's own name; E at the plan changes it)"
has "Host inst-b:"
hasnt "? Node 0 name"
echo "PASS: three addresses give a three-node deployment named after the hosts"

# 8. Back across the hosts (domain → disks → type → mode → login → hosts):
#    single → three re-asks what depends on the hosts
#    (names, disks, login check) instead of keeping stale single-node values.
run hosts_change $'10.0.0.5\n\n1\n1\n\n<\n<\n<\n<\n<\ninst-a.lab inst-b.lab inst-c.lab\n\n\n\n'"$TAIL"
done_ok
has "Topology:                      three-node"
has "Host inst-a:"
hasnt "Host instana-backend:"
hasnt "VM name:"
[[ "$(count 'Use detected login:')" -ge 2 ]] || fail "the login must be checked again for the new hosts"
echo "PASS: changing the hosts re-asks names, disks and the login"

# 9. A wrong count of addresses is explained and asked again.
run count_bad $'10.0.0.5 10.0.0.6\nn\n10.0.0.5\n\n1\n1\n\n'"$TAIL"
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
run gcloud_list $'2\n\n1\n1\n\n'"$TAIL"
done_ok
has "ssh-test-1             10.0.0.5        34.65.106.11    europe-west6-b  n2-standard-16"
has "a)  enter another address"
hasnt "34.65.11.204"
grep -q " 1)  lab-db " "$OUT" && grep -q " 2)  ssh-test-1 " "$OUT" || fail "list order (own zone, by name)"
grep -q "Host instana-backend: *10.0.0.5 " "$OUT" || fail "the picked VM (2 = ssh-test-1, internal IP 10.0.0.5) must be used"
echo "PASS: the gcloud list shows name, addresses, zone and machine type; the control machine is not listed"

# 11. Disks: one proposed mapping, smallest disk that fits, largest role first.
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/bin/gcloud"; printf '#!/usr/bin/env bash\necho ctl\n' > "$FAKE_ROOT/bin/hostname"
run disk_map $'10.0.0.5\n\n1\n1\n\n'"$TAIL"
done_ok
grep -qE "analytics +≥  500 GB  →  sdb +600 GB" "$OUT" || fail "analytics → sdb"
grep -qE "metrics +≥  300 GB  →  sdc +1100 GB" "$OUT" || fail "metrics → sdc"
grep -qE "data +≥  150 GB  →  sdd +1300 GB" "$OUT" || fail "data → the remaining disk"

echo "PASS: the disk mapping is proposed (smallest fitting disk, largest role first)"

# 12. Three-node node 1 (the review case): data must not take the 1300 GB disk
#     that analytics needs.
run disk_three $'inst-a.lab inst-b.lab inst-c.lab\n\n1\n\n'"$TAIL"
done_ok
grep -qE "analytics +≥ 1200 GB  →  sdd +1300 GB" "$OUT" || fail "node 1 analytics → sdd"
grep -qE "data +≥  500 GB  →  sdb +600 GB" "$OUT" || fail "node 1 data → sdb"
has "inst-c (inst-c.lab): no data disk needed"
echo "PASS: three-node mapping keeps the big disk for analytics"

# 13. c = choose each disk yourself, then the mapping is shown again.
run disk_choose $'10.0.0.5\n\n1\n1\nc\n2\n1\n1\n1\n\n'"$TAIL"
done_ok
has "? Disk for analytics on instana-backend:"
grep -qE "analytics +≥  500 GB  →  sdc +1100 GB" "$OUT" || fail "chosen disk not used"
echo "PASS: c lets the operator choose each disk, then confirm the mapping"

# 14. "<" at the mapping goes back to the install type.
run disk_back $'10.0.0.5\n\n1\n1\n<\n\n\n'"$TAIL"
done_ok
[[ "$(count '? Select installation type:')" == 2 ]] || fail "< at the mapping must go back to the type"
echo "PASS: < at the disk mapping goes back"

# 15. No complete mapping possible: explained with the fix, no stop until cancel.
NO_DATA_DISKS=1 host_facts 10.0.0.7
run disk_none $'10.0.0.7\n\n1\n1\n3\n'
[[ "$RC" == 0 ]] || fail "an operator cancel must exit 0, got $RC"
has "no unused disk of at least 500 GB is left for the Instana analytics directory"
has "Attach an empty disk of that size"
has "? What now?"
has "check again (after attaching or freeing a disk)"
hasnt "Installation Plan"
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
run plan_network $'1\n\n1\n1\n\n'"$TAIL"
done_ok
has "Changes the installer will make on the host(s) (Y below approves them):"
has "Network (outside the host(s); the installer does not change it):"
has "gcloud firewall rules for ssh-test-1 (network default, read-only check):"
has "✓ allowed from anywhere: TCP 443"
has "✗ missing: TCP 8443, 80"
has "--allow=tcp:8443,tcp:80"
# (a real run's start line; a dry-run shows its own)
( cd "$CASE"; set --; source ./install.sh; INSTANA_PROVIDER=ssh resolve_provider; provider_text start_line ) |
  grep -q "Y approves the changes on the host(s) listed above and confirms the network connections listed" || fail "start line"
has "Changes on the host(s): formats 4 blank data disk(s), kernel settings + a REBOOT of each host, UFW firewall on — Y approves (list below)"
has "Hosts     10.0.0.5 ("
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

# 18. At most 4 login tries (fail2ban: 5 failures in 10 min), each with
#     BatchMode, IdentitiesOnly and exactly one key.
MANY="$FAKE_ROOT/many"; mkdir -p "$MANY"
for k in k1 k2 k3 k4 k5 k6; do cp "$FAKE_KEY" "$MANY/$k"; touch "$SCEN/deny-key-$k"; done
: > "$SSH_LOG"
INSTANA_SSH_DIR="$MANY" run tries $'10.0.0.5\n5\n'
tries=$(grep -c -- "-- 10.0.0.5 true" "$SSH_LOG" || true)
[[ "$tries" == 4 ]] || fail "expected 4 login tries, got $tries"
while IFS= read -r line; do
  [[ "$line" == *"-o IdentitiesOnly=yes -o BatchMode=yes"* ]] || fail "probe without BatchMode/IdentitiesOnly: $line"
  [[ "$(grep -o -- ' -i ' <<< "$line" | wc -l | tr -d ' ')" == 1 ]] || fail "probe must pass exactly one key: $line"
done < <(grep -- "-- 10.0.0.5 true" "$SSH_LOG")
for k in k1 k2 k3 k4 k5 k6; do rm -f "$SCEN/deny-key-$k"; done
echo "PASS: at most 4 tries, each non-interactive with exactly one key"

# 19. A host that does not answer is tried once, not with every key.
: > "$SSH_LOG"
run timeout_once $'10.0.0.9\n5\n'
[[ "$(grep -c -- "-- 10.0.0.9 true" "$SSH_LOG" || true)" == 1 ]] || fail "an unreachable host must be tried once"
echo "PASS: no further tries when the host itself does not answer"

# 20. A passphrase key that is not in ssh-agent is never passed to ssh.
LOCK="$FAKE_ROOT/lock"; mkdir -p "$LOCK"; cp "$FAKE_KEY" "$LOCK/google_compute_engine"; cp "$FAKE_KEY" "$LOCK/id_ed25519"
touch "$SCEN/locked-google_compute_engine"
: > "$SSH_LOG"
INSTANA_SSH_DIR="$LOCK" run locked $'10.0.0.5\n\n1\n1\n\n'"$TAIL"
done_ok
if grep -q -- "-i $LOCK/google_compute_engine" "$SSH_LOG"; then fail "a locked key without ssh-agent was passed to ssh"; fi
has "google_compute_engine: passphrase-protected and not loaded in ssh-agent — skipped"
rm -f "$SCEN/locked-google_compute_engine"
echo "PASS: a passphrase key without ssh-agent is skipped, never tried"

# 21. A changed login reads the host facts again (no reuse of facts read with
#     the earlier login).
: > "$SSH_LOG"
run login_same $'10.0.0.5\n\n<\n\n1\n1\n\n'"$TAIL"
done_ok
base=$(grep -o FACTS_END=1 "$SSH_LOG" | wc -l | tr -d ' ')
: > "$SSH_LOG"
run login_change $'10.0.0.5\n\n<\nc\nadmin\n\n\n\n1\n1\n\n'"$TAIL"
done_ok
[[ "$(grep -o FACTS_END=1 "$SSH_LOG" | wc -l | tr -d ' ')" == $(( base + 1 )) ]] || fail "facts must be read again after the login changed (and only then)"
# ... already in the questions (the checks shown are those of the new login).
[[ "$(count 'Checking 10.0.0.5 (read-only)...')" == 2 ]] || fail "the host checks must run again for the changed login"
has "SSH login:                     admin on port 22"
echo "PASS: a changed login reads the host facts again"

# 22. Back to the install type after the disks were mapped: the suggestion
#     still sees all unused disks (production stays possible).
run type_after_map $'10.0.0.5\n\n1\n1\n\n<\n<\n2\n\n'"$TAIL"
done_ok
[[ "$(count 'Suggested from the checks above: production (')" == 2 ]] || fail "the suggestion must not change after the disk mapping"
hasnt "This host is too small for production"
has "Installation type:             production"
echo "PASS: going back to the type after the disk mapping keeps the suggestion"

# 23. A port given with an earlier address does not stick to new hosts.
run port_reset $'10.0.0.5:2222\n<\n10.0.0.5\n\n1\n1\n\n'"$TAIL"
done_ok
has "SSH login:                     ubuntu on port 22,"
echo "PASS: host:port does not stick after the hosts are picked again"

# 24. Lab domain: for an online existing-host lab whose public IP is known
#     before Start, instana.<ip>.sslip.io is suggested (Enter takes it); never
#     for air-gapped.
cat > "$FAKE_ROOT/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"config get-value project"*) echo test-project ;;
  *"instances list"*"networkIP=10.0.0.5"*"natIP"*) echo 34.65.106.11 ;;
  *"instances list"*"status=RUNNING"*) echo "ssh-test-1 europe-west6-b 10.0.0.5 34.65.106.11 n2-standard-16" ;;
esac
exit 0
FAKE
chmod +x "$FAKE_ROOT/bin/gcloud"
run sslip $'1\n\n1\n1\n\n\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\ny'
done_ok
has "Domain for the UI; suggested: 34-65-106-11.sslip.io (sslip.io, no DNS setup needed)."
has "Base domain:                   instana.34-65-106-11.sslip.io"
run sslip_air $'1\n\n2\n1\n\ninstana.example.com\n'
hasnt "sslip.io"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/bin/gcloud"
echo "PASS: sslip.io is suggested only for an online existing-host lab with a known public IP"

# 25. Firewall check makes no wrong claims: a matching deny rule is reported
#     as blocked, and rules that cannot be read are "not verifiable" (never
#     "missing" with a create command).
cat > "$FAKE_ROOT/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"config get-value project"*) echo test-project ;;
  *"instances list"*"networkIP=10.0.0.5"*"natIP"*) echo 34.65.106.11 ;;
  *"instances list"*"networkIP=10.0.0.5"*) echo "ssh-test-1 europe-west6-b default" ;;
  *"instances list"*"status=RUNNING"*) echo "ssh-test-1 europe-west6-b 10.0.0.5 34.65.106.11 n2-standard-16" ;;
  *"firewall-rules list"*)
    [[ "${FWCASE:-}" == noaccess ]] && { echo "ERROR: (gcloud.compute.firewall-rules.list) Required 'compute.firewalls.list' permission" >&2; exit 1; }
    echo '[{"name":"allow-all-web","priority":1000,"allowed":[{"IPProtocol":"tcp","ports":["443","8443","80"]}],"sourceRanges":["0.0.0.0/0"]},
           {"name":"deny-https","priority":100,"denied":[{"IPProtocol":"tcp","ports":["443"]}],"sourceRanges":["0.0.0.0/0"]}]' ;;
esac
exit 0
FAKE
chmod +x "$FAKE_ROOT/bin/gcloud"
run fw_deny $'1\n\n1\n1\n\n'"$TAIL"
done_ok
has "✗ blocked or not verifiable: TCP 443 (deny rule deny-https)"
has "✓ allowed from anywhere: TCP 8443, 80"
has "organization or network firewall policies are not"
export FWCASE=noaccess
run fw_noaccess $'1\n\n1\n1\n\n'"$TAIL"
unset FWCASE
done_ok
has "not verifiable (could not read them: ERROR: (gcloud.compute.firewall-rules.list) Required 'compute.firewalls.list' permission)"
hasnt "✗ missing"; hasnt "firewall-rules create"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/bin/gcloud"
echo "PASS: the firewall check reports deny rules and unreadable rules honestly"

# 26. The network rules are never confirmed by a file or the environment: the
#     key is ignored with a reason, the variable starts empty, and without a
#     terminal phase 5 stops with the terminal-only fix.
( cd "$CASE"; set --; source ./install.sh; INSTANA_PROVIDER=ssh resolve_provider; PARAMS_SOURCE=import; INPUT_LABEL=f.json
  IMPORTED=([NETWORK_RULES_CONFIRMED]=true [VM_HOST]=10.0.0.5); input_drop_unknown_keys
  echo "LEFT=${IMPORTED[NETWORK_RULES_CONFIRMED]:-none}" ) > "$TEST_ROOT/nrc.txt" 2>&1
grep -q "NETWORK_RULES_CONFIRMED in f.json is ignored: the network connections are confirmed with Y at the plan" "$TEST_ROOT/nrc.txt" || { cat "$TEST_ROOT/nrc.txt" >&2; fail "the file key must be ignored with a reason"; }
grep -q "LEFT=none" "$TEST_ROOT/nrc.txt" || fail "the key must be dropped"
NETWORK_RULES_CONFIRMED=true bash -c "cd '$CASE'; set --; source ./install.sh; echo \"ENV=[\$NETWORK_RULES_CONFIRMED]\"" > "$TEST_ROOT/nrc2.txt" 2>&1
grep -q "ENV=\[\]" "$TEST_ROOT/nrc2.txt" || fail "the environment must not pre-confirm the network rules"
port_file="$TEST_ROOT/port"; rm -f "$port_file"
python3 -c "import socket,time,sys;s=socket.socket();s.bind(('127.0.0.1',0));s.listen(5);open(sys.argv[1],'w').write(str(s.getsockname()[1]));time.sleep(40)" "$port_file" &
lp=$!; for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$port_file" ]] && break; sleep 0.3; done
if ( cd "$CASE"; set --; source ./install.sh; INSTANA_PROVIDER=ssh resolve_provider; DRY_RUN=false TOPOLOGY=single-node VM_HOST=127.0.0.1 SSH_USER=ubuntu SSH_PORT="$(cat "$port_file")"
     prov_ssh_ensure_firewall < /dev/null ) > "$TEST_ROOT/nrc3.txt" 2>&1; then kill $lp 2>/dev/null; fail "without a terminal the network rules must not be confirmed"; fi
kill $lp 2>/dev/null || true
grep -q "a file cannot" "$TEST_ROOT/nrc3.txt" || { cat "$TEST_ROOT/nrc3.txt" >&2; fail "the stop must name the terminal-only fix"; }
if grep -q '"NETWORK_RULES_CONFIRMED": "true"' "$TEST_ROOT/nrc3.txt"; then fail "the stop must not suggest the file key"; fi
echo "PASS: the network rules are confirmed only by Y at the plan in a terminal"

echo "All existing-host login flow tests passed."
