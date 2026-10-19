#!/usr/bin/env bash
# Start of a run in a real terminal: the start menu comes first; the screen
# offer only for install/resume (never for a dry-run); a re-launch inside
# screen gets the menu choice (--start=...) instead of the menu again.
# The --resume table shows the saved values readably, keys are asked with a hint.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null || { echo "SKIP: python3 not installed (needed for a real terminal)"; exit 0; }
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
printf '#!/usr/bin/env bash\ncase "$*" in *"auth list"*) echo t@example.com ;; esac\nexit 0\n' > "$TEST_ROOT/bin/gcloud"
printf '#!/usr/bin/env bash\necho 203.0.113.10\n' > "$TEST_ROOT/bin/curl"
# A fake screen records how it was started and does not start anything.
printf '#!/usr/bin/env bash\nif [[ "$1" == -ls ]]; then [[ -f "%s/sessions" ]] && printf "\\t12345.instana-101532\\t(Detached)\\n"; exit 1; fi\necho "SCREEN-ARGS: $*" >> "%s/screen.log"\nexit 0\n' "$TEST_ROOT" "$TEST_ROOT" > "$TEST_ROOT/bin/screen"
chmod +x "$TEST_ROOT/bin"/*
fail() { echo "FAIL: $*" >&2; [[ -f "${OUT:-}" ]] && tail -30 "$OUT" >&2; exit 1; }

# pty_run NAME ANSWERS... — runs ./install.sh in a pseudo terminal, sending one
# answer per prompt seen (after a short pause); transcript in $OUT.
pty_run() {
  local name="$1"; shift
  CASE="$TEST_ROOT/$name"; mkdir -p "$CASE"; cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"
  OUT="$CASE/pty.txt"
  ( cd "$CASE" && env -u STY -u TMUX PATH="$TEST_ROOT/bin:$PATH" python3 - "$@" <<'PY'
import os, pty, sys, time, select
answers = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "./install.sh"])
out = b""; end = time.time() + 40; last = time.time()
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.3)
    if r:
        try:
            b = os.read(fd, 4096)
        except OSError:
            break
        if not b:
            break
        out += b; last = time.time()
    elif answers and time.time() - last > 0.8:
        os.write(fd, (answers.pop(0) + "\n").encode()); last = time.time()
    elif not answers and time.time() - last > 3:
        break
try:
    os.kill(pid, 9)
except OSError:
    pass
open("pty.txt", "wb").write(out)
PY
  ) || true
  sed -i.bak 's/\x1b\[[0-9;]*m//g' "$OUT"
}

# 1. Dry-run from the menu: no screen offer at all.
pty_run dryrun 3 1
grep -q "What do you want to do?" "$OUT" || fail "start menu not shown"
if grep -q "You are not inside a screen/tmux session" "$OUT"; then fail "a dry-run must not offer screen"; fi
echo "PASS: a dry-run from the menu does not offer screen"

# 2. Install from the menu: the menu first, then the screen offer; the
#    re-launch inside screen carries the choice instead of showing the menu again.
rm -f "$TEST_ROOT/screen.log"
pty_run install 1 y
m=$(grep -n "What do you want to do?" "$OUT" | head -1 | cut -d: -f1)
s=$(grep -n "You are not inside a screen/tmux session" "$OUT" | head -1 | cut -d: -f1)
[[ -n "$m" && -n "$s" && "$m" -lt "$s" ]] || fail "the menu must come before the screen offer"
grep -q -- "--start=install" "$TEST_ROOT/screen.log" || { cat "$TEST_ROOT/screen.log" >&2 2>/dev/null; fail "screen must get --start=install"; }
echo "PASS: install from the menu: menu first, then screen with --start=install"

# 3. --resume shows the saved values as a table and explains the keys.
CASE="$TEST_ROOT/resume"; mkdir -p "$CASE"; cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"
jq -n '{schema_version:1, parameters:{TOPOLOGY:"single-node", INSTALL_MODE:"online", INSTALL_TYPE:"demo", GCP_PROJECT:"my-proj-123", GCP_ZONE:"europe-west6-b", BASE_DOMAIN:"lab.example.com", TENANT_NAME:"t", UNIT_NAME:"u", SSH_SOURCE_CIDR:"203.0.113.10/32", TLS_MODE:"auto-generate (self-signed)", VM_NAME:"lab", TLS_CRT_PATH:""}}' > "$CASE/.install-config.json"
chmod 600 "$CASE/.install-config.json"
( cd "$CASE"; set --; RESUME=true; source ./install.sh; RESUME=true; DRY_RUN=false
  select_versions_upfront() { :; }
  offer_saved_parameters <<< $'a\nd\nag\ns' ) > "$CASE/out.txt" 2>&1 || true
OUT="$CASE/out.txt"
grep -qE "^  GCP_PROJECT +my-proj-123$" "$OUT" || fail "saved values must be shown as a table"
if grep -q '"GCP_PROJECT":' "$OUT"; then fail "raw JSON shown"; fi
if grep -qE "^  TLS_CRT_PATH" "$OUT"; then fail "empty values must be left out"; fi
grep -q "are never saved; type them again" "$OUT" || fail "hint before the keys on resume"
echo "PASS: resume shows a readable table and explains why the keys are asked"

# 4. A still-running installer is offered BEFORE the start menu (a dropped
#    operator lands back in the live install).
touch "$TEST_ROOT/sessions"; rm -f "$TEST_ROOT/screen.log"
pty_run reattach 2 3
rm -f "$TEST_ROOT/sessions"
r=$(grep -n "An installer session is still running in screen" "$OUT" | head -1 | cut -d: -f1)
m=$(grep -n "What do you want to do?" "$OUT" | head -1 | cut -d: -f1)
[[ -n "$r" && -n "$m" && "$r" -lt "$m" ]] || fail "the running session must be offered before the menu"
[[ "$(grep -c "An installer session is still running" "$OUT")" == 1 ]] || fail "the running session must be offered once"
echo "PASS: a running installer is offered before the start menu"

# 5. destroy refuses while an installation from this folder holds the lock.
CASE="$TEST_ROOT/lock"; mkdir -p "$CASE"; cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"
( cd "$CASE"; flock .install.lock sleep 15 ) & lockpid=$!
sleep 1
( cd "$CASE"; PATH="$TEST_ROOT/bin:$PATH" bash ./install.sh --destroy < /dev/null ) > "$CASE/out.txt" 2>&1 && { kill $lockpid; fail "destroy must refuse while the lock is held"; }
kill $lockpid 2>/dev/null || true
OUT="$CASE/out.txt"
grep -q "An installation from this folder is running right now" "$OUT" || fail "destroy lock message"
grep -q "Nothing was deleted." "$OUT" || fail "destroy lock: nothing deleted"
echo "PASS: destroy refuses while an installation holds the folder lock"

# 6. A cancel or N at the plan inside screen is reported as such, not "Completed".
CASE="$TEST_ROOT/marker"; mkdir -p "$CASE"; cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"
( cd "$CASE"; set --; INSTANA_EXIT_MARKER="$CASE/m.exit" bash -c 'source ./install.sh; operator_cancel' ) > /dev/null 2>&1 || true
grep -q "cancelled by the operator — nothing was created or changed" "$CASE/m.exit.stopped" || fail "the cancel marker must be written"
( cd "$CASE"; set --; bash -c 'source ./install.sh; echo "REASON=[$(screen_stop_reason "'"$CASE"'/m.exit")]"' ) > "$CASE/r.txt" 2>&1
grep -q "REASON=\[installation cancelled by the operator" "$CASE/r.txt" || { cat "$CASE/r.txt" >&2; fail "the outer terminal must read the stop reason"; }
[[ ! -f "$CASE/m.exit.stopped" ]] || fail "the marker must be removed after reading"
echo "PASS: a cancel inside screen is reported as cancelled, not completed"

# 7. The menu names the target of each install, explains the clean-up, and
#    a dry-run asks where it would install (0 = back to the menu).
source "$SRC/test-pty-lib.inc"
CASE="$TEST_ROOT/target"; mkdir -p "$CASE"; cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"
PATH="$TEST_ROOT/bin:$PATH" pty_install "$CASE" 3 0 3 2
OUT="$CASE/pty.txt"
grep -q "2) Install on existing hosts (SSH)   any cloud or on-prem: AWS, Azure, customer DC" "$OUT" || fail "option 2 must say it covers any cloud"
grep -q "1) Install on new Google Cloud VMs   the installer creates the VMs" "$OUT" || fail "option 1 detail"
grep -q "deletes the VMs, disks and firewall rules of a lab this installer created on GCP;" "$OUT" || fail "clean-up must say what is deleted"
grep -q "Existing hosts: only forgets the local record, the machines are never touched." "$OUT" || fail "clean-up must say existing hosts are not touched"
grep -q "Select \[1-5, Enter = 1\]" "$OUT" || fail "Enter = 1 in the start menu"
[[ "$(grep -c "? Dry-run for:" "$OUT")" == 2 ]] || fail "the target question must be asked again after going back"
[[ "$(grep -c "What do you want to do?" "$OUT")" == 2 ]] || fail "0 at the target must return to the menu"
grep -q "Dry-run mode — nothing will be changed on the hosts" "$OUT" || fail "existing hosts chosen for the dry-run"
echo "PASS: the menu names each target; a dry-run asks where (0 = back to the menu)"

# 8. ./install.sh --dry-run in a terminal asks the target too, unless it is set.
CASE="$TEST_ROOT/dryarg"; mkdir -p "$CASE"; cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"
PATH="$TEST_ROOT/bin:$PATH" PTY_ARGS=--dry-run pty_install "$CASE" 2
OUT="$CASE/pty.txt"
grep -q "? Dry-run for:" "$OUT" || fail "--dry-run must ask the target in a terminal"
if grep -q "0) ← back" "$OUT"; then fail "nothing to go back to from --dry-run"; fi
grep -q "Dry-run mode — nothing will be changed on the hosts" "$OUT" || fail "--dry-run: existing hosts chosen"
CASE="$TEST_ROOT/dryset"; mkdir -p "$CASE"; cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"
PATH="$TEST_ROOT/bin:$PATH" PTY_ENV="INSTANA_PROVIDER=gcp" PTY_ARGS=--dry-run pty_install "$CASE"
if grep -q "Dry-run for:" "$CASE/pty.txt"; then fail "the target must not be asked when INSTANA_PROVIDER is set"; fi
grep -q "Dry-run mode — no GCP resources will be created" "$CASE/pty.txt" || fail "GCP dry-run banner"
# Older saved answers without PROVIDER but with GCP values mean GCP: not asked.
CASE="$TEST_ROOT/dryold"; mkdir -p "$CASE"; cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"
jq -n '{schema_version:1, parameters:{GCP_PROJECT:"my-proj-123", GCP_ZONE:"europe-west6-b", TOPOLOGY:"single-node"}}' > "$CASE/.install-config.json"
chmod 600 "$CASE/.install-config.json"
PATH="$TEST_ROOT/bin:$PATH" PTY_ARGS=--dry-run pty_install "$CASE"
if grep -q "Dry-run for:" "$CASE/pty.txt"; then fail "saved GCP answers without PROVIDER must not ask the target"; fi
grep -q "Dry-run mode — no GCP resources will be created" "$CASE/pty.txt" || fail "saved GCP answers: GCP dry-run"
echo "PASS: --dry-run asks the target in a terminal, not when it is already set"

# 9. Enter at the running-session question reattaches.
touch "$TEST_ROOT/sessions"; rm -f "$TEST_ROOT/screen.log"
pty_run reattach_enter ""
rm -f "$TEST_ROOT/sessions"
grep -q "Select \[1-2, Enter = 1\]" "$OUT" || fail "Enter = 1 at the running session"
grep -q "SCREEN-ARGS: -d -r 12345.instana-101532" "$TEST_ROOT/screen.log" || fail "Enter must reattach"
echo "PASS: Enter at the running-session question reattaches"

# 10. The final hint for existing hosts says that --destroy only forgets.
CASE="$TEST_ROOT/final"; mkdir -p "$CASE"; cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"
for p in ssh gcp; do
  ( cd "$CASE"; set --; source ./install.sh; INSTANA_PROVIDER=$p resolve_provider; DRY_RUN=false
    UNIT_NAME=u TENANT_NAME=t BASE_DOMAIN=lab.example.com FINAL_UI_IP=203.0.113.5 RUN_STARTED_AT=now
    print_final_summary < /dev/null ) > "$CASE/$p.txt" 2>&1 || true
done
grep -q "To forget this deployment (local state only; the hosts are not changed): ./install.sh --destroy" "$CASE/ssh.txt" || { cat "$CASE/ssh.txt" >&2; fail "ssh final hint"; }
if grep -q "To destroy all resources" "$CASE/ssh.txt"; then fail "ssh: no resources are destroyed"; fi
grep -q "To destroy all resources: ./install.sh --destroy" "$CASE/gcp.txt" || { cat "$CASE/gcp.txt" >&2; fail "gcp final hint"; }
echo "PASS: the final hint says what --destroy does for each target"

echo "All start-flow tests passed."
