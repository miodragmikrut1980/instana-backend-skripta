#!/usr/bin/env bash
# Colours only on a terminal without NO_COLOR; piped output and every log
# file are plain text (no escape codes).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null || { echo "SKIP: python3 not installed (needed for a real terminal)"; exit 0; }
source "$SRC/test-pty-lib.inc"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
printf '#!/usr/bin/env bash\ncase "$*" in *"auth list"*) echo t@example.com ;; esac\nexit 0\n' > "$TEST_ROOT/bin/gcloud"
printf '#!/usr/bin/env bash\necho 203.0.113.10\n' > "$TEST_ROOT/bin/curl"
chmod +x "$TEST_ROOT/bin"/*
export PATH="$TEST_ROOT/bin:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }
ESC=$'\e'
newcase() { CASE="$TEST_ROOT/$1"; mkdir -p "$CASE"; cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"; }

# 1. Output into a pipe/file: no escape codes on screen or in the log.
newcase piped
( cd "$CASE" && bash ./install.sh --destroy --dry-run < /dev/null ) > "$CASE/out.txt" 2>&1 || true
[[ -s "$CASE/out.txt" ]] || fail "no output"
if grep -q "$ESC" "$CASE/out.txt"; then fail "escape codes in piped output: $(grep -m1 "$ESC" "$CASE/out.txt" | cat -v)"; fi
ls "$CASE"/install-*.log >/dev/null 2>&1 || fail "no log file written"
if grep -q "$ESC" "$CASE"/install-*.log; then fail "escape codes in the log"; fi
echo "PASS: piped output and its log are plain text"

# 2. A terminal: colours on screen, the log file stays plain.
newcase tty
pty_install "$CASE" 'RAW:\x04'
grep -q "$ESC\[1m" "$CASE/pty.raw" || fail "no bold text on a terminal"
grep -q "What do you want to do?" "$CASE/pty.txt" || fail "start menu not shown"
ls "$CASE"/install-*.log >/dev/null 2>&1 || fail "no log file written"
if grep -q "$ESC" "$CASE"/install-*.log; then fail "escape codes in the log of a terminal run: $(grep -m1 "$ESC" "$CASE"/install-*.log | cat -v)"; fi
grep -q "Instana installer" "$CASE"/install-*.log || fail "log lines missing"
echo "PASS: a terminal gets colours, its log stays plain"

# 3. NO_COLOR on a terminal: no colour codes at all.
newcase nocolor
PTY_ENV="NO_COLOR=1" pty_install "$CASE" 'RAW:\x04'
grep -q "What do you want to do?" "$CASE/pty.txt" || fail "start menu not shown with NO_COLOR"
if grep -q "$ESC\[[0-9;]*m" "$CASE/pty.raw"; then fail "colour codes despite NO_COLOR: $(grep -m1 "$ESC\[[0-9;]*m" "$CASE/pty.raw" | cat -v)"; fi
echo "PASS: NO_COLOR turns colours off"

echo "All plain-output tests passed."
