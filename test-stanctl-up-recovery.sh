#!/usr/bin/env bash
# stanctl up exits non-zero after its own --timeout while Instana keeps coming
# up (real run 2026-10-29): the installer checks the cluster before deciding.
# Mocked remote_exec: no GCP, no VM. Covers the --timeout flag, recovery after a
# failed stanctl up (Instana up -> phase 12; not up -> HOW TO RESOLVE naming the
# components), single-node resume with k3s after a phase-11 stop (-> report),
# k3s without a phase-11 record (-> explained stop), secret masking and the
# three-node resume after an unrecorded stanctl up.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
cp -R "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/providers "$TEST_DIR/"
OUT="$TEST_DIR/out.txt"

fail() { echo "FAIL: $*" >&2; [[ -f "$OUT" ]] && tail -60 "$OUT" >&2; exit 1; }
has() { grep -qF -- "$1" "$OUT" || fail "expected text not found: $1"; }
hasnt() { if grep -qF -- "$1" "$OUT"; then fail "unexpected text found: $1"; fi; }

# Snapshots the status script prints on the VM.
SNAP_READY='STANCTL_RUNNING=no
K3S=yes
API=up
NODES_TOTAL=1
NODES_READY=1
CORE instana-core/instana-core Ready
UNIT instana-units/tenant0-unit0 Ready
PODS_TOTAL=59'
SNAP_PROGRESSING='STANCTL_RUNNING=no
K3S=yes
API=up
NODES_TOTAL=1
NODES_READY=1
CORE instana-core/instana-core Progressing
UNIT instana-units/tenant0-unit0
PODS_TOTAL=59
POD instana-core/appdata-writer-7d9f CrashLoopBackOff
POD instana-units/ui-backend-5c4b Running-not-ready(0/1)'
SNAP_NOK3S='STANCTL_RUNNING=no
K3S=no'
export SNAP_READY SNAP_PROGRESSING SNAP_NOK3S

# common setup inside a subshell: source the installer and mock the VM side.
setup='
  cd "$TEST_DIR"; set --
  source ./install.sh
  DRY_RUN=false; RESUME=false
  INSTANA_READY_POLL=0
  printf "{}\n" > "$STATE_FILE"
  DOWNLOAD_KEY=dl-secret-1234 SALES_KEY=sales-secret-1234 AGENT_KEY=agent-secret-1234 ADMIN_PASSWORD=Admin-Pass-1234
  BACKEND_VERSION=3.327.712-0 INSTALL_MODE=online TLS_MODE="auto-generate (self-signed)"
  VM_NAME=instana-backend GCP_ZONE=zone-a GCP_PROJECT=proj
  ACTIVE_PROVIDER=gcp
  upload_stanctl_env() { :; }
  : > "$TEST_DIR/calls"
  # SNAPS: status answers in order (the last one repeats); UP_RC: stanctl up exit code.
  remote_exec() {
    local cmd="$4" n
    case "$cmd" in
      *STANCTL_RUNNING=*)
        n=$(grep -c "^STATUS" "$TEST_DIR/calls" || true); echo STATUS >> "$TEST_DIR/calls"
        local -a s; IFS="|" read -r -a s <<< "$SNAPS"
        (( n < ${#s[@]} )) || n=$(( ${#s[@]} - 1 ))
        printf "%s\n" "${!s[n]}" ;;
      *"stanctl up --env-file"*) printf "UP %s\n" "$cmd" >> "$TEST_DIR/calls"; echo "Error: timed out waiting for the condition"; return "${UP_RC:-0}" ;;
      *"== OUT"*)
        printf "%s\n" "== OUT" "Error: timed out waiting for the condition" "== LOG" \
          "time=2026-10-29T12:00:00Z level=INFO msg=\"env\" STANCTL_DOWNLOAD_KEY=dl-secret-1234 downloadKey: abc-def" \
          "time=2026-10-29T12:00:05Z level=INFO source=healthcheck.go:162 msg=\"resource status\" kind=Core componentsStatus=Progressing" \
          "time=2026-10-29T12:00:10Z level=INFO source=healthcheck.go:162 msg=\"resource status\" kind=Core componentsStatus=Progressing" \
          "time=2026-10-29T12:00:15Z level=INFO source=healthcheck.go:162 msg=\"resource status\" kind=Core componentsStatus=Progressing" ;;
      *) return 0 ;;
    esac
  }
'
export TEST_DIR setup

run_case() {  # run_case NAME BODY — exit code in RC, output in $OUT
  RC=0
  CASE_BODY="$2"
  ( eval "$setup"; eval "$CASE_BODY" ) > "$OUT" 2>&1 || RC=$?
}

# 1. --timeout in the stanctl up command (default 90m; plan value; env override; "default").
run_case flag '
  DRY_RUN=true; run_stanctl_up_single_node instana-backend zone-a proj
  STANCTL_UP_TIMEOUT=2h; run_stanctl_up_single_node instana-backend zone-a proj
  INSTANA_STANCTL_TIMEOUT=150 run_stanctl_up_single_node instana-backend zone-a proj
  INSTANA_STANCTL_TIMEOUT=default run_stanctl_up_single_node instana-backend zone-a proj'
[[ "$RC" == 0 ]] || fail "dry-run stanctl up exit $RC"
has "stanctl up --env-file /root/.stanctl.env --instana-version '3.327.712-0' --timeout 90m --core-tls-generate-cert --quiet"
has "--timeout 120m --core-tls-generate-cert"
has "--timeout 150m --core-tls-generate-cert"
has "--instana-version '3.327.712-0'  --core-tls-generate-cert --quiet"
echo "PASS: stanctl up gets --timeout (90m default, plan value, INSTANA_STANCTL_TIMEOUT, 'default' = none)"

run_case validate '
  for v in 90 90m 2h 1h30m 30 600; do validate_stanctl_timeout "$v" || { echo "REJECTED $v"; exit 1; }; done
  for v in 10 601 abc 2d "" 11h; do if validate_stanctl_timeout "$v" 2>/dev/null; then echo "ACCEPTED $v"; exit 1; fi; done
  [[ "$(stanctl_timeout_normalize 1h30m)" == 90m ]]
  INSTANA_STANCTL_TIMEOUT=5x check_stanctl_timeout'
[[ "$RC" != 0 ]] || fail "an invalid INSTANA_STANCTL_TIMEOUT must stop"
hasnt "REJECTED"; hasnt "ACCEPTED"
has "INSTANA_STANCTL_TIMEOUT='5x' is not a valid wait time for stanctl up"
has "HOW TO RESOLVE"
has "INSTANA_STANCTL_TIMEOUT=2h ./install.sh"
echo "PASS: timeout values: 30-600 minutes as 90, 90m, 2h, 1h30m; an invalid env value stops with HOW TO RESOLVE"

# 2. stanctl up fails, cluster comes up while checking -> continues.
run_case recovered '
  UP_RC=1 SNAPS="SNAP_PROGRESSING|SNAP_READY"
  run_stanctl_up_single_node instana-backend zone-a proj
  echo "STATE=$(get_state stanctl_up_status)"
  echo "NOTE=$PHASE11_NOTE"
  grep "^UP " "$TEST_DIR/calls" | wc -l | sed "s/^ */UPCOUNT=/"'
[[ "$RC" == 0 ]] || fail "a stanctl up timeout with Instana up must continue (exit $RC)"
has "stanctl up on instana-backend ended with exit code 1"
has "Last lines from stanctl on instana-backend (secrets masked):"
has "(3x) level=INFO source=healthcheck.go:162 msg=\"resource status\" kind=Core componentsStatus=Progressing"
has "stanctl up reported a failure (exit 1; usually its own timeout), but Instana came up: nodes Ready 1/1, Core Ready, Unit Ready"
has "STATE=completed"
has "NOTE=stanctl up exited 1, but Core and Unit were verified Ready on instana-backend."
has "UPCOUNT=1"
hasnt "dl-secret-1234"; hasnt "abc-def"
has "STANCTL_DOWNLOAD_KEY=•••"
has "downloadKey: •••"
grep -q -- "--timeout 90m" "$TEST_DIR/calls" || fail "stanctl up ran without --timeout"
echo "PASS: stanctl up timeout with Instana Ready: warning, phase 11 done, no second stanctl up, secrets masked"

# 3. stanctl up fails, cluster not ready within the wait -> HOW TO RESOLVE with component names.
run_case notready '
  UP_RC=1 SNAPS="SNAP_PROGRESSING" INSTANA_READY_WAIT_MIN=0
  run_stanctl_up_single_node instana-backend zone-a proj
  echo REACHED-PHASE-12'
[[ "$RC" != 0 ]] || fail "stanctl up failure without a ready cluster must stop"
hasnt "REACHED-PHASE-12"
has "stanctl up on instana-backend failed (exit 1 after"
has "and Instana is not ready."
has "HOW TO RESOLVE"
has "Found: nodes Ready 1/1, Core Progressing, Unit Unknown, pods not Running 2/59."
has "Core instana-core/instana-core: Progressing (not Ready)"
has "Unit instana-units/tenant0-unit0: Unknown (not Ready)"
has "pod instana-core/appdata-writer-7d9f CrashLoopBackOff"
has "pod instana-units/ui-backend-5c4b Running-not-ready(0/1)"
has "console.log: (3x) level=INFO"
has "sudo kubectl get pods -A | grep -v Running"
has "sudo kubectl get core -n instana-core -o yaml | grep -A5 status"
has "sudo tail -n 100 /root/.stanctl/logs/console.log"
has "./install.sh --resume"
has "INSTANA_RERUN_STANCTL_UP=yes ./install.sh --resume"
[[ "$(jq -r .stanctl_up_status "$TEST_DIR/.install-state.json")" == failed ]] || fail "failed stanctl up not recorded"
echo "PASS: stanctl up failure with Instana not ready: HOW TO RESOLVE names Core/Unit/pods, inspect commands, resume"

# 4. stanctl up fails before Kubernetes exists -> explained; resume will run it again.
run_case nocluster '
  UP_RC=1 SNAPS="SNAP_NOK3S"
  run_stanctl_up_single_node instana-backend zone-a proj'
[[ "$RC" != 0 ]] || fail "stanctl up failure without a cluster must stop"
has "Kubernetes (k3s) is not installed on instana-backend"
has "stanctl stopped before the Kubernetes cluster existed"
has "resume runs stanctl up again"
echo "PASS: stanctl up failure before k3s: explained, resume runs it again"

# 5. Lost SSH connection (255) while stanctl still runs: no retry, no second stanctl, explained.
run_case lost '
  UP_RC=255 SNAPS="SNAP_PROGRESSING" INSTANA_READY_WAIT_MIN=0
  SNAP_PROGRESSING="${SNAP_PROGRESSING/STANCTL_RUNNING=no/STANCTL_RUNNING=yes}"
  run_stanctl_up_single_node instana-backend zone-a proj'
[[ "$RC" != 0 ]] || fail "lost connection with stanctl running must stop"
has "Exit 255 means the SSH connection to instana-backend was lost"
has "stanctl is still running on instana-backend"
has "pgrep -a stanctl"
[[ "$(grep -c '^UP ' "$TEST_DIR/calls")" == 1 ]] || fail "stanctl up was started more than once"
echo "PASS: lost connection during stanctl up: not retried, running stanctl explained"

# 6. Single-node resume: k3s exists after a phase-11 stop -> cluster checked,
#    stanctl up not repeated, phase 12 and the final report follow.
run_case resume_ready '
  RESUME=true SNAPS="SNAP_READY"
  printf "%s\n" "{\"progress_phase_10\":\"completed\",\"stanctl_up_status\":\"failed\",\"step_kernel_instana-backend\":\"completed\"}" > "$STATE_FILE"
  resume_check_existing_cluster
  echo "FLAG=$RESUME_AFTER_STANCTL_UP"
  provider_ensure_vms() { :; }; provider_ensure_disks() { :; }; provider_ensure_firewall() { :; }
  wait_for_ssh() { :; }; verify_cpu_x86_64_v3() { :; }; configure_ufw_single_node() { :; }
  format_and_mount_disk() { :; }; add_instana_repository() { :; }; install_stanctl() { :; }
  lab_kernel() { echo "FAIL-REBOOT"; }
  run_stanctl_up_single_node() { echo "FAIL-RERUN"; }
  post_install_health_check() { echo "HEALTH-CHECK"; }
  configure_kubectl_user_access() { :; }
  provider_get_ip() { echo 203.0.113.7; }
  print_final_report() { echo "FINAL-REPORT $1"; }
  print_final_summary() { echo "FINAL-SUMMARY"; }
  progress_init >/dev/null
  main_single_node'
[[ "$RC" == 0 ]] || fail "resume after a phase-11 stop with Instana up must finish (exit $RC)"
has "FLAG=true"
has "Kubernetes already exists on instana-backend (nodes Ready 1/1, Core Ready, Unit Ready, pods not Running 0/59); it comes from this deployment's stanctl up."
has "This deployment already ran stanctl up on instana-backend (recorded: failed)"
has "Instana is up on instana-backend"
has "stanctl up was not repeated: Core and Unit were verified Ready on instana-backend."
has "HEALTH-CHECK"
has "FINAL-REPORT 203.0.113.7"
has "FINAL-SUMMARY"
hasnt "FAIL-REBOOT"; hasnt "FAIL-RERUN"
[[ "$(jq -r .progress_phase_11 "$TEST_DIR/.install-state.json")" == completed ]] || fail "phase 11 not recorded as done"
echo "PASS: resume with k3s after a phase-11 stop: cluster verified, no stanctl rerun or reboot, phase 12 and report"

# 6b. Older state (no stanctl_up_status, phase 10 completed), still progressing -> waits, then explained stop.
run_case resume_notready '
  RESUME=true SNAPS="SNAP_PROGRESSING" INSTANA_READY_WAIT_MIN=0
  printf "%s\n" "{\"progress_phase_10\":\"completed\"}" > "$STATE_FILE"
  resume_check_existing_cluster
  resume_after_stanctl_up instana-backend zone-a proj 1
  echo "RETURNED-$?"'
[[ "$RC" != 0 ]] || fail "resume with Instana not ready must stop"
has "recorded: not recorded; phase 10 completed"
has "Resume found Kubernetes from this deployment's stanctl up on instana-backend, but Instana is not ready."
has "Core instana-core/instana-core: Progressing (not Ready)"
has "INSTANA_RERUN_STANCTL_UP=yes ./install.sh --resume"
hasnt "RETURNED-"
echo "PASS: resume with Instana still not ready: explained stop with components and options"

# 6c. INSTANA_RERUN_STANCTL_UP=yes: stanctl up is started again (caller runs it).
run_case resume_rerun '
  RESUME=true SNAPS="SNAP_PROGRESSING" INSTANA_READY_WAIT_MIN=0 INSTANA_RERUN_STANCTL_UP=yes
  printf "%s\n" "{\"stanctl_up_status\":\"failed\"}" > "$STATE_FILE"
  if resume_after_stanctl_up instana-backend zone-a proj 1; then echo READY; else echo RERUN; fi'
[[ "$RC" == 0 ]] || fail "rerun request exit $RC"
has "INSTANA_RERUN_STANCTL_UP=yes: running stanctl up again on instana-backend"
has "RERUN"
echo "PASS: INSTANA_RERUN_STANCTL_UP=yes runs stanctl up again on resume"

# 7. k3s on the VM, but this deployment never got to stanctl up -> explained stop.
run_case foreign '
  RESUME=true SNAPS="SNAP_READY"
  printf "%s\n" "{\"progress_phase_5\":\"completed\",\"progress_phase_6\":\"completed\"}" > "$STATE_FILE"
  resume_check_existing_cluster
  echo CONTINUED'
[[ "$RC" != 0 ]] || fail "a foreign cluster must stop the resume"
hasnt "CONTINUED"
has "Kubernetes (k3s) already exists on instana-backend (/etc/rancher/k3s/k3s.yaml), but this deployment never got to stanctl up (last completed phase in .install-state.json: 6/12)."
has "continuing could install on top of it and destroy it. Nothing was changed on instana-backend."
has "sudo /usr/local/bin/k3s-uninstall.sh"
has "HOW TO RESOLVE"
echo "PASS: k3s without a phase-11 record: explained stop, nothing changed"

# 7b. No k3s: the normal partial resume.
run_case nok3s '
  RESUME=true SNAPS="SNAP_NOK3S"
  resume_check_existing_cluster
  echo "FLAG=$RESUME_AFTER_STANCTL_UP"'
[[ "$RC" == 0 ]] || fail "resume without k3s exit $RC"
has "FLAG=false"
echo "PASS: no k3s: normal partial resume"

# 8. Three-node resume after an unrecorded stanctl up: checked, not repeated.
run_case three '
  RESUME=true SNAPS="SNAP_READY"
  SNAP_READY="${SNAP_READY/NODES_TOTAL=1/NODES_TOTAL=3}"; SNAP_READY="${SNAP_READY/NODES_READY=1/NODES_READY=3}"
  NODE0_NAME=node0
  printf "%s\n" "{\"stanctl_up_status\":\"running\"}" > "$STATE_FILE"
  run_stanctl_up_multi_node() { echo FAIL-RERUN; }
  resume_stanctl_up
  echo "STATE=$(get_state stanctl_up_status) NOTE=$PHASE11_NOTE"'
[[ "$RC" == 0 ]] || fail "three-node resume with Instana up exit $RC"
hasnt "FAIL-RERUN"
has "STATE=completed NOTE=stanctl up was not repeated: Core and Unit were verified Ready on node0."
echo "PASS: three-node resume after an unrecorded stanctl up: cluster verified, not repeated"

run_case three_partial '
  RESUME=true SNAPS="SNAP_READY" INSTANA_READY_WAIT_MIN=0
  NODE0_NAME=node0
  printf "%s\n" "{\"stanctl_up_status\":\"running\"}" > "$STATE_FILE"
  resume_stanctl_up'
[[ "$RC" != 0 ]] || fail "three-node with one Ready node must not pass"
has "nodes Ready 1/1"
has "HOW TO RESOLVE"
echo "PASS: three-node needs three Ready nodes"
