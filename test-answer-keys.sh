#!/usr/bin/env bash
# How answers are read: the left-arrow key on an empty answer writes "<" and
# Enter goes back (arrow + Enter, arrow + < + Enter and ESC O D all go back
# exactly once); "?" shows the longer help; pick lists end with "0) ← back";
# escape sequences of special keys never reach a value.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null || { echo "SKIP: python3 not installed (needed for a real terminal)"; exit 0; }
source "$SRC/test-pty-lib.inc"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; [[ -f "${OUT:-}" ]] && tail -30 "$OUT" >&2; exit 1; }
newcase() { CASE="$TEST_ROOT/$1"; mkdir -p "$CASE"; cp -R "$SRC"/*.sh "$SRC/providers" "$CASE/"; }

# 1. Text question in a terminal.
newcase text
cat > "$CASE/drv.sh" <<'EOF'
set --; source ./install.sh
NAV_ON=1
hint "Short help line." "Longer help line one."
for i in 1 2 3 4 5 6 7 8; do rc=0; v=$(prompt X "Name" "def") || rc=$?; echo "RESULT[$v] rc=$rc"; done
EOF
PTY_SCRIPT=./drv.sh pty_install "$CASE" 'RAW:\x1b[D' '' 'RAW:\x1b[D' '<' 'RAW:\x1bOD' '' '?' 'abc' '' 'RAW:\x1b[D' 'RAW:\x7f' 'xyz' \
  'RAW:\x1b[D\x7fq\n' 'RAW:\x1b[D' 'RAW:\x08' 'w'
OUT="$CASE/pty.txt"
mapfile -t res < <(grep -o 'RESULT\[[^]]*\] rc=[0-9]' "$OUT")
expected=("RESULT[] rc=3" "RESULT[] rc=3" "RESULT[] rc=3" "RESULT[abc] rc=0" "RESULT[def] rc=0" "RESULT[xyz] rc=0"
          "RESULT[q] rc=0" "RESULT[w] rc=0")
[[ "${res[*]}" == "${expected[*]}" ]] || fail "got: ${res[*]}"
grep -q "Short help line.  ? = more" "$OUT" || fail "the hint must offer ? = more"
grep -q "Longer help line one." "$OUT" || fail "? must show the longer help"
grep -q "\[← = back\]" "$OUT" || fail "a text question must name the arrow key for back"
echo "PASS: arrow+Enter, arrow+<+Enter and ESC O D each go back once; ? shows help; Backspace (^? or ^H, also typed at once) undoes the arrow"

# 2. Pick list in a terminal: 0) ← back, the arrow, and Enter = default.
newcase pick
cat > "$CASE/drv.sh" <<'EOF'
set --; source ./install.sh
for i in 1 2 3 4; do rc=0; v=$(PROMPT_CHOICE_DEFAULT=b NAV_CHOICE_BACK=1 prompt_choice "Pick" "a"$'\t'"first one" "b") || rc=$?; echo "RESULT[$v] rc=$rc"; done
EOF
PTY_SCRIPT=./drv.sh pty_install "$CASE" '0' 'RAW:\x1b[D' '' '' '1'
OUT="$CASE/pty.txt"
mapfile -t res < <(grep -o 'RESULT\[[^]]*\] rc=[0-9]' "$OUT")
expected=("RESULT[] rc=3" "RESULT[] rc=3" "RESULT[b] rc=0" "RESULT[a] rc=0")
[[ "${res[*]}" == "${expected[*]}" ]] || fail "got: ${res[*]}"
grep -q "0) ← back" "$OUT" || fail "the list must offer 0) ← back"
grep -q "1) a   first one" "$OUT" || fail "the option detail must follow the option"
grep -q "Select \[1-2, Enter = 2\]" "$OUT" || fail "the default must be shown"
echo "PASS: pick list: 0 and the arrow go back, Enter takes the default, details are shown"

# 3. Without a terminal: escape sequences are removed before the answer is used.
newcase piped
OUT="$CASE/out.txt"
( cd "$CASE"; set --; source ./install.sh
  NAV_ON=1
  for i in 1 2 3; do rc=0; v=$(prompt X "Name" "def") || rc=$?; echo "RESULT[$v] rc=$rc"; done
  rc=0; v=$(NAV_CHOICE_BACK=1 prompt_choice "Pick" a b) || rc=$?; echo "RESULT[$v] rc=$rc"
  NAV_ON=0; rc=0; v=$(prompt X "Name" "def") || rc=$?; echo "RESULT[$v] rc=$rc"
) <<< $'\e[D<\n\eOD\n\e[Aabc\e[C\n0\n\e[D<\n' > "$OUT" 2>&1
mapfile -t res < <(grep -o 'RESULT\[[^]]*\] rc=[0-9]' "$OUT")
expected=("RESULT[] rc=3" "RESULT[] rc=3" "RESULT[abc] rc=0" "RESULT[] rc=3" "RESULT[<] rc=0")
[[ "${res[*]}" == "${expected[*]}" ]] || fail "got: ${res[*]}"
if grep -q $'\e' "$OUT"; then fail "an escape sequence reached a value or the output"; fi
echo "PASS: ^[[D< and ^[OD mean back, other key sequences are dropped from the answer"

# 4. A secret in a terminal: arrow keys are ignored, never part of the value.
newcase secret
cat > "$CASE/drv.sh" <<'EOF'
set --; source ./install.sh
NAV_ON=1
v=$(prompt_secret S "Key") ; echo "RESULT[$v]"
EOF
PTY_SCRIPT=./drv.sh pty_install "$CASE" 'RAW:a\x1b[Db\x1bODc\n'
OUT="$CASE/pty.txt"
grep -q 'RESULT\[abc\]' "$OUT" || fail "secret value: $(grep RESULT "$OUT" | cat -v)"
grep -q "\[< Enter = back\]" "$OUT" || fail "a secret must say how to go back"
echo "PASS: arrow keys inside a secret are ignored"

# 5. Keys typed at human speed (one key every 0.4 s): Backspace after the
#    arrow removes the "<"; arrow + Enter, arrow + < + Enter and a second
#    arrow + Enter go back.
newcase paced
cat > "$CASE/drv.sh" <<'EOF'
set --; source ./install.sh
NAV_ON=1
for i in 1 2 3 4 5; do rc=0; v=$(prompt X "Name" "def") || rc=$?; echo "RESULT[$v] rc=$rc"; done
EOF
PTY_GAP=0.4 PTY_SCRIPT=./drv.sh pty_install "$CASE" 'RAW:\x1b[D' 'RAW:\x7f' 'RAW:x' 'RAW:\n' \
  'RAW:\x1b[D' 'RAW:\n' 'RAW:\x1b[D' 'RAW:<' 'RAW:\n' 'RAW:\x1b[D' 'RAW:\x1b[D' 'RAW:\n' \
  'RAW:\x1b[D' 'RAW:\x08' 'RAW:y' 'RAW:\n'
OUT="$CASE/pty.txt"
mapfile -t res < <(grep -o 'RESULT\[[^]]*\] rc=[0-9]' "$OUT")
expected=("RESULT[x] rc=0" "RESULT[] rc=3" "RESULT[] rc=3" "RESULT[] rc=3" "RESULT[y] rc=0")
[[ "${res[*]}" == "${expected[*]}" ]] || fail "paced keys, got: ${res[*]}"
echo "PASS: at human typing speed Backspace undoes the arrow and Enter after it goes back"

echo "All answer-key tests passed."
