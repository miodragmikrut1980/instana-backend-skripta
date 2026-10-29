#!/usr/bin/env bash
# How answers are read: the left-arrow key on an empty answer writes "<" and
# Enter goes back (arrow + Enter, arrow + < + Enter and ESC O D all go back
# exactly once); "?" shows the longer help; pick lists end with "0) ← back";
# escape sequences of special keys never reach a value; long lists show 10 at
# a time (Space = next 10, a = all), version lists: Enter = 1 newest.
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

# 6. Ctrl+D in a terminal is a deliberate key: it asks "Cancel ...? [y/N]".
#    N asks the same question again; Y, or Ctrl+D twice, cancels (exit 0,
#    nothing created). Other control keys are ignored. Keys 0.4 s apart.
newcase ctrld
cat > "$CASE/drv.sh" <<'EOF'
set --; source ./install.sh
NAV_ON=1
for i in 1 2 3; do rc=0; v=$(prompt X "Name" "def") || rc=$?; echo "RESULT[$v] rc=$rc"; done
echo "AFTER-LOOP"
EOF
PTY_GAP=0.4 PTY_SCRIPT=./drv.sh pty_install "$CASE" 'RAW:\x1b[D' 'RAW:\x04' 'n' 'abc' 'RAW:\x01' 'RAW:\x04' 'n' 'RAW:\x1b[D' 'RAW:\x01' 'RAW:\x7f' 'z' 'RAW:\x04' 'y'
OUT="$CASE/pty.txt"
mapfile -t res < <(grep -o 'RESULT\[[^]]*\] rc=[0-9]' "$OUT")
expected=("RESULT[abc] rc=0" "RESULT[z] rc=0")
[[ "${res[*]}" == "${expected[*]}" ]] || fail "Ctrl+D, got: ${res[*]}"
[[ "$(grep -c "Cancel the installation? \[y/N\]" "$OUT")" == 3 ]] || fail "each Ctrl+D must ask before cancelling"
[[ "$(grep -c "Continuing; please answer the question again." "$OUT")" == 2 ]] || fail "N must ask the question again"
grep -q "Installation cancelled by the operator. Nothing was created or changed." "$OUT" || fail "Y must cancel"
if grep -q "AFTER-LOOP" "$OUT"; then fail "the run must end after Y"; fi
newcase ctrld2
cat > "$CASE/drv.sh" <<'EOF'
set --; source ./install.sh
NAV_ON=1
rc=0; v=$(prompt X "Name" "def") || rc=$?; echo "RESULT[$v] rc=$rc"
EOF
PTY_GAP=0.4 PTY_SCRIPT=./drv.sh pty_install "$CASE" 'RAW:\x04' 'RAW:\x04'
OUT="$CASE/pty.txt"
grep -q "Installation cancelled by the operator. Nothing was created or changed." "$OUT" || fail "Ctrl+D twice must cancel"
if grep -q "RESULT" "$OUT"; then fail "Ctrl+D twice: nothing may continue"; fi
echo "PASS: Ctrl+D asks before cancelling (N = same question, Y or Ctrl+D again = cancel); control keys ignored"

# 7. A long pick list (55 versions) shows 10 at a time. In a terminal Space
#    shows the next 10 at once (no Enter; Space + Enter typed fast counts as
#    one), "a" + Enter all the rest; any number of the whole list is accepted,
#    Enter = 1 (newest). A short list is shown whole, as before.
newcase longlist
cat > "$CASE/drv.sh" <<'EOF'
set --; source ./install.sh
mapfile -t V < <(for i in $(seq 55 -1 1); do echo "1.$i.0-1"; done)
for i in 1 2 3 4 5; do rc=0; v=$(PROMPT_CHOICE_NEWEST=1 prompt_choice "Version" "${V[@]}") || rc=$?; echo "RESULT[$v] rc=$rc"; done
rc=0; v=$(prompt_choice "Short" a b c d e) || rc=$?; echo "RESULT[$v] rc=$rc"
EOF
PTY_SCRIPT=./drv.sh pty_install "$CASE" 'RAW: ' '25' '' '40' 'a' '55' 'RAW: \n' '2' '3'
OUT="$CASE/pty.txt"
mapfile -t res < <(grep -o 'RESULT\[[^]]*\] rc=[0-9]' "$OUT")
expected=("RESULT[1.31.0-1] rc=0" "RESULT[1.55.0-1] rc=0" "RESULT[1.16.0-1] rc=0" "RESULT[1.1.0-1] rc=0" "RESULT[1.54.0-1] rc=0" "RESULT[c] rc=0")
[[ "${res[*]}" == "${expected[*]}" ]] || fail "long list, got: ${res[*]}"
grep -q "Select \[1-55, Enter = 1 newest\]" "$OUT" || fail "a version list must say Enter = 1 newest"
grep -q "… 45 older versions (11-55): Space = next 10, a = all, or type any number" "$OUT" || fail "the long list must say how to see more"
grep -q "… 35 older versions (21-55)" "$OUT" || fail "Space must show the next 10"
[[ "$(grep -c '^  10) 1.46.0-1$' "$OUT")" == 5 ]] || fail "each long list must show the first 10"
[[ "$(grep -c '  11) 1.45.0-1$' "$OUT")" == 3 ]] || fail "11 only after Space or a"
[[ "$(grep -c '^  21) 1.35.0-1$' "$OUT")" == 1 ]] || fail "21 only after a (all)"
grep -q "^  55) 1.1.0-1$" "$OUT" || fail "a must show all the rest"
grep -q "Select \[1-5\]:" "$OUT" || fail "a short list keeps its prompt"
grep -q "^  5) e$" "$OUT" || fail "a short list is shown whole"
[[ "$(grep -c "older versions\|more options" "$OUT")" == 7 ]] || fail "a short list has no more-line"
# Without a terminal: Space + Enter or m + Enter show the next 10, a + Enter all.
OUT="$CASE/piped.txt"
( cd "$CASE"; set --; source ./install.sh
  mapfile -t V < <(for i in $(seq 55 -1 1); do echo "1.$i.0-1"; done)
  for i in 1 2 3 4; do rc=0; v=$(PROMPT_CHOICE_NEWEST=1 prompt_choice "Version" "${V[@]}") || rc=$?; echo "RESULT[$v] rc=$rc"; done
  rc=0; v=$(NAV_CHOICE_BACK=1 prompt_choice "Pick" $(seq 1 20)) || rc=$?; echo "RESULT[$v] rc=$rc"
) <<< $' \n12\nm\nm\n\n55\na\n08\n0\n' > "$OUT" 2>&1
mapfile -t res < <(grep -o 'RESULT\[[^]]*\] rc=[0-9]' "$OUT")
expected=("RESULT[1.44.0-1] rc=0" "RESULT[1.55.0-1] rc=0" "RESULT[1.1.0-1] rc=0" "RESULT[1.48.0-1] rc=0" "RESULT[] rc=3")
[[ "${res[*]}" == "${expected[*]}" ]] || fail "long list without a terminal, got: ${res[*]}"
grep -q "… 10 more options (11-20): Space = next 10" "$OUT" || fail "a long non-version list says more options"
echo "PASS: long lists show 10 at a time (Space at once, m/Space + Enter, a = all), any number is accepted, Enter = 1 newest; short lists unchanged"

echo "All answer-key tests passed."
