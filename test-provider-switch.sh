#!/usr/bin/env bash
set -euo pipefail
# A folder that records a deployment with one provider, and a NEW deployment
# with another provider is requested: in a terminal the operator may continue
# the recorded one or set its files aside (renamed, nothing deleted); --resume
# and runs without a terminal keep the hard stop.
SRC="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
GCP_STATE='{"provider":"gcp","gcp_project":"test-project","gcp_zone":"us-central1-a","topology":"single-node","vm_old-lab":"created","progress_phase_1":"completed","progress_phase_3":"completed"}'
GCP_CONFIG='{"schema_version":1,"parameters":{"TOPOLOGY":"single-node","GCP_PROJECT":"test-project","VM_NAME":"old-lab"}}'

# in_terminal DIR INPUT [RESUME] — resolve_provider for INSTANA_PROVIDER=ssh with
# a real terminal (python pty); prints the transcript, then ACTIVE=/RESUME=.
in_terminal() {
  local dir="$1" input="$2" resume="${3:-false}"
  python3 - "$dir" "$input" "$resume" <<'PY'
import os, pty, sys, time
d, data, resume = sys.argv[1], sys.argv[2], sys.argv[3]
script = ('cd "%s"; set --; source ./install.sh; RESUME=%s; INSTANA_PROVIDER=ssh; '
          'if resolve_provider; then echo "ACTIVE=$ACTIVE_PROVIDER RESUME=$RESUME"; else echo REFUSED; fi') % (d, resume)
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
