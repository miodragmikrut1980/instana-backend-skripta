#!/usr/bin/env bash
set -euo pipefail
# A folder that records a deployment with one provider, and a NEW deployment
# with another provider is requested: in a terminal the operator may continue
# the recorded one or set its files aside (renamed, nothing deleted); --resume
# and runs without a terminal keep the hard stop.
command -v python3 >/dev/null || { echo "SKIP: python3 not installed (needed for a real terminal)"; exit 0; }
SRC="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
GCP_STATE='{"provider":"gcp","gcp_project":"test-project","gcp_zone":"us-central1-a","topology":"single-node","vm_old-lab":"created","progress_phase_1":"completed","progress_phase_3":"completed"}'
GCP_CONFIG='{"schema_version":1,"parameters":{"TOPOLOGY":"single-node","GCP_PROJECT":"test-project","VM_NAME":"old-lab"}}'

# in_terminal DIR INPUT [RESUME] — resolve_provider for INSTANA_PROVIDER=ssh with
# a real terminal (python pty); prints the transcript, then ACTIVE=/RESUME=.
in_terminal() {
  local dir="$1" input="$2" resume="${3:-false}" pre="${4:-:}"
  python3 - "$dir" "$input" "$resume" "$pre" <<'PY'
import os, pty, signal, sys, time
d, data, resume, pre = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
script = ('cd "%s"; set --; source ./install.sh; %s; RESUME=%s; INSTANA_PROVIDER=ssh; '
          'if resolve_provider; then echo "ACTIVE=$ACTIVE_PROVIDER RESUME=$RESUME"; else echo REFUSED; fi') % (d, pre, resume)
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", script])
out = b""; sent = False; deadline = time.time() + 30
while time.time() < deadline:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
    if not sent and b"What do you want to do?" in out:
        time.sleep(0.2); os.write(fd, data.encode()); sent = True
else:
    # Never hang the suite: a run still waiting for input after the deadline is a failure.
    os.kill(pid, signal.SIGKILL); out += b"\nTIMEOUT\n"
os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
PY
}

case_dir() {
  local d="$TEST_ROOT/$1"; mkdir -p "$d"; cp -R "$SRC"/*.sh "$SRC/providers" "$d/"
  printf '%s\n' "$GCP_STATE" > "$d/.install-state.json"; printf '%s\n' "$GCP_CONFIG" > "$d/.install-config.json"
  chmod 600 "$d"/.install-*.json; echo "$d"
}
plain() { sed 's/\x1b\[[0-9;]*m//g; s/\r//g'; }

d=$(case_dir new)
out=$(in_terminal "$d" $'2\n' | plain)
[[ "$out" == *"recorded: project/zone test-project/us-central1-a   topology: single-node   VMs/hosts: old-lab   last completed phase: 3/12"* ]] || { echo "FAIL: summary of the recorded deployment: $out" >&2; exit 1; }
[[ "$out" == *"delete them first: ./install.sh --destroy"* ]] || { echo "FAIL: no cost reminder" >&2; exit 1; }
[[ "$out" == *"ACTIVE=ssh RESUME=false"* ]] || { echo "FAIL: new provider not chosen: $out" >&2; exit 1; }
ls "$d"/.install-state.json.*.old "$d"/.install-config.json.*.old >/dev/null
[[ ! -e "$d/.install-state.json" && ! -e "$d/.install-config.json" ]] || { echo "FAIL: recorded files still in place" >&2; exit 1; }
cmp <(printf '%s\n' "$GCP_STATE") "$d"/.install-state.json.*.old
echo 'PASS: set aside: both files renamed unchanged (nothing deleted), the new provider is used'

d=$(case_dir keep)
out=$(in_terminal "$d" $'1\n' | plain)
[[ "$out" == *"ACTIVE=gcp RESUME=true"* ]] || { echo "FAIL: continue: $out" >&2; exit 1; }
test -f "$d/.install-state.json"
echo 'PASS: continue: the recorded provider and --resume are used, nothing moved'

d=$(case_dir cancel)
in_terminal "$d" $'3\n' > /dev/null || true
test -f "$d/.install-state.json"; test -f "$d/.install-config.json"
if ls "$d"/*.old >/dev/null 2>&1; then echo "FAIL: cancel moved a file" >&2; exit 1; fi
echo 'PASS: cancel changes nothing'

d=$(case_dir resume)
out=$(in_terminal "$d" $'2\n' true | plain)
[[ "$out" == *"the provider of a recorded deployment never changes"* && "$out" != *"What do you want to do?"* && "$out" != *ACTIVE=* ]] || { echo "FAIL: --resume must keep the hard stop: $out" >&2; exit 1; }
[[ "$out" == *"./install.sh --destroy"* ]]
test -f "$d/.install-state.json"
echo 'PASS: --resume keeps the hard stop (with the --destroy hint)'

d=$(case_dir notty)
out=$(cd "$d" && bash -c 'set --; source ./install.sh; INSTANA_PROVIDER=ssh resolve_provider && echo ACCEPTED || echo REFUSED' < /dev/null 2>&1 | plain || true)
[[ "$out" == *"the provider of a recorded deployment never changes"* && "$out" == *"offers to set the recorded files aside"* && "$out" != *ACCEPTED* ]] || { echo "FAIL: no terminal: $out" >&2; exit 1; }
test -f "$d/.install-state.json"
echo 'PASS: without a terminal: hard stop, explanation names the way out, nothing moved'

# Two set-asides in the same second never overwrite an earlier copy.
d=$(case_dir same_second)
echo old-state > "$d/.install-state.json.20260101-000000.old"; echo old-config > "$d/.install-config.json.20260101-000000.old"
out=$(in_terminal "$d" $'2\n' false 'date() { echo 20260101-000000; }' | plain)
[[ "$out" == *"ACTIVE=ssh"* ]] || { echo "FAIL: same-second set-aside: $out" >&2; exit 1; }
test "$(cat "$d/.install-state.json.20260101-000000.old")" = old-state
test "$(cat "$d/.install-config.json.20260101-000000.old")" = old-config
cmp <(printf '%s\n' "$GCP_STATE") "$d/.install-state.json.20260101-000000-2.old"
test -f "$d/.install-config.json.20260101-000000-2.old"
echo 'PASS: a set-aside copy from the same second is never overwritten'

# A failing second move reports exactly what was already moved.
d=$(case_dir half_moved)
out=$(in_terminal "$d" $'2\n' false 'mv() { [[ "$*" == *install-config* ]] && return 1; command mv "$@"; }' | plain)
[[ "$out" == *"Could not set .install-config.json aside"* && "$out" == *"Already moved in this step: .install-state.json → .install-state.json."* && "$out" == *".install-config.json is still in place; nothing was deleted."* ]] ||
  { echo "FAIL: partial set-aside report: $out" >&2; exit 1; }
[[ "$out" != *ACTIVE=* ]]
test -f "$d/.install-config.json"
echo 'PASS: a failed set-aside says exactly what was moved and what is still in place'

# Dry-run: "continue" (needs --resume) is not offered, and the reason is shown.
d=$(case_dir dry)
out=$(in_terminal "$d" $'2\n' false 'DRY_RUN=true' | plain)
[[ "$out" == *"not offered in a dry-run"* && "$out" != *"continue the recorded deployment"* ]] || { echo "FAIL: dry-run offer: $out" >&2; exit 1; }
echo 'PASS: dry-run does not offer to continue the recorded deployment'

# --config FILE + "continue": refused (the file cannot change a recorded deployment).
d=$(case_dir config_continue)
out=$(in_terminal "$d" $'1\n' false 'INPUT_CONFIG=/tmp/x.json INPUT_LABEL=x.json' | plain)
[[ "$out" == *"can only be continued with the parameters it was started with; the values from x.json cannot change it"* && "$out" != *ACTIVE=* ]] ||
  { echo "FAIL: --config + continue: $out" >&2; exit 1; }
test -f "$d/.install-state.json"
echo 'PASS: --config together with "continue" is refused with an explanation'

# --export-config writes the recorded provider, never INSTANA_PROVIDER.
d=$(case_dir export)
(cd "$d" && INSTANA_PROVIDER=ssh bash ./install.sh --export-config "$d/out.json" < /dev/null > "$d/export.log" 2>&1) || { cat "$d/export.log" >&2; exit 1; }
test "$(jq -r .parameters.PROVIDER "$d/out.json")" = gcp
echo 'PASS: --export-config keeps the recorded provider (gcp) despite INSTANA_PROVIDER=ssh'

