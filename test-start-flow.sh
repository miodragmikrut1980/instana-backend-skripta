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
printf '#!/usr/bin/env bash\n[[ "$1" == -ls ]] && exit 1\necho "SCREEN-ARGS: $*" >> "%s/screen.log"\nexit 0\n' "$TEST_ROOT" > "$TEST_ROOT/bin/screen"
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
pty_run dryrun 2
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

echo "All start-flow tests passed."
