#!/usr/bin/env bash
# End-to-end resume, phases 1-12, on a VM where this deployment's stanctl up
# already installed Instana (real lab 2026-10-29: phase 10 completed, k3s
# present, Core and Unit Ready, stanctl 1.15.0 pinned). The real installer
# runs (main, every phase function); only the cloud API and the SSH transport
# are mocked. On such a VM "stanctl versions identify" prints no list, only
# "No newer versions available. You are already running the latest
# supported version." The resume must verify instead of installing, never
# reboot, never re-apply UFW, never run stanctl up, and end with phase 12 and
# the final report. Also: a different installed backend or stanctl stops with
# HOW TO RESOLVE, and the same identify output on the fresh-install path is
# explained instead of a bare stop.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
printf '#!/usr/bin/env bash\ncase "$*" in *"auth list"*) echo tester@example.com ;; esac\nexit 0\n' > "$TEST_ROOT/bin/gcloud"
printf '#!/usr/bin/env bash\necho 203.0.113.10\n' > "$TEST_ROOT/bin/curl"
chmod +x "$TEST_ROOT/bin/gcloud" "$TEST_ROOT/bin/curl"

fail() { echo "FAIL: $*" >&2; [[ -f "${OUT:-}" ]] && tail -60 "$OUT" >&2; exit 1; }
has() { grep -qF -- "$1" "$OUT" || fail "expected text not found: $1"; }
hasnt() { if grep -qF -- "$1" "$OUT"; then fail "unexpected text found: $1"; fi; }
called() { grep -qF -- "$1" "$CASE/calls"; }

IDENTIFY_OUT='Identifying supported Instana versions... ✓
No newer versions available. You are already running the latest supported version.'
export IDENTIFY_OUT

# new_case NAME — folder with the saved parameters and the state of the lab.
new_case() {
  CASE="$TEST_ROOT/$1"; mkdir -p "$CASE"
  cp -R "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/providers" "$CASE/"
  OUT="$CASE/out.txt"; : > "$CASE/calls"
  jq -n '{schema_version:1, parameters:{TOPOLOGY:"single-node", INSTALL_MODE:"online", INSTALL_TYPE:"demo",
    UBUNTU_VERSION:"ubuntu-2404-lts-amd64", GCP_PROJECT:"instana-support-test-account", GCP_REGION:"europe-west6",
    GCP_ZONE:"europe-west6-b", GCP_NETWORK:"default", GCP_SUBNET:"default", SSH_SOURCE_CIDR:"203.0.113.10/32",
    VM_NAME:"mikrut-lab", VM_CPUS:"16", VM_RAM_GB:"64", MACHINE_TYPE:"n2-standard-16", BASE_DOMAIN:"lab.example.com",
    TENANT_NAME:"tenant0", UNIT_NAME:"unit0", TLS_MODE:"auto-generate (self-signed)", NODE0_NAME:"", NODE1_NAME:"",
    NODE2_NAME:"", NODE_CPUS:"", NODE_RAM_GB:"", TLS_CRT_PATH:"", TLS_KEY_PATH:"", AIRGAP_ARCHIVE:"",
    KUBE_USER_ACCESS:"no"}}' > "$CASE/.install-config.json"
  local p; local -a ph=()
  for p in 1 2 3 4 5 6 7 8 9 10; do ph+=(--arg "p$p" completed); done
  jq -n '{provider:"gcp", gcp_project:"instana-support-test-account", gcp_zone:"europe-west6-b", topology:"single-node",
    install_mode:"online", "vm_mikrut-lab":"created", "step_kernel_mikrut-lab":"completed",
    stanctl_apt_version:"1.15.0", stanctl_cli_version:"1.15.0", backend_version:"3.327.712-0",
    progress_phase_1:"completed", progress_phase_2:"completed", progress_phase_3:"completed", progress_phase_4:"completed",
    progress_phase_5:"completed", progress_phase_6:"completed", progress_phase_7:"completed", progress_phase_8:"completed",
    progress_phase_9:"completed", progress_phase_10:"completed"}' > "$CASE/.install-state.json"
  chmod 600 "$CASE/.install-config.json" "$CASE/.install-state.json"
}

# run_resume [STATE_JQ] — ./install.sh --resume (main) with the cloud API and
# SSH transport mocked; VM_* variables describe the VM.
run_resume() {
  RC=0
  [[ -z "${1:-}" ]] || { jq "$1" "$CASE/.install-state.json" > "$CASE/s.tmp" && mv "$CASE/s.tmp" "$CASE/.install-state.json"; }
  (
    cd "$CASE"; export PATH="$TEST_ROOT/bin:$PATH" INSTANA_NO_SCREEN=1 INSTANA_READY_POLL=0
    set -- --resume
    source ./install.sh
    CALLS="$CASE/calls"
    prov_gcp_check_auth() { :; }
    prov_gcp_validate_config() { :; }
    prov_gcp_validate_image() { :; }
    prov_gcp_resume_state_matches() { return 0; }
    prov_gcp_resume_check_vm() { echo "CHECK_VM $1" >> "$CALLS"; }
    prov_gcp_ensure_vms() { echo "ENSURE_VMS" >> "$CALLS"; }
    prov_gcp_ensure_disks() { echo "ENSURE_DISKS" >> "$CALLS"; }
    prov_gcp_ensure_firewall() { echo "ENSURE_FIREWALL" >> "$CALLS"; }
    prov_gcp_get_ip() { echo 203.0.113.7; }
    prov_gcp_scp() { echo "SCP $5" >> "$CALLS"; }
    prov_gcp_ssh_probe() { echo ready; }
    prov_gcp_ssh() {
      local cmd="$4" inner
      if [[ "$cmd" == "sudo bash -lc "* ]]; then eval "inner=${cmd#sudo bash -lc }"; else inner="$cmd"; fi
      case "$inner" in
        *STANCTL_RUNNING=*) echo STATUS >> "$CALLS"
          printf '%s\n' STANCTL_RUNNING=no K3S=yes API=up NODES_TOTAL=1 NODES_READY=1 \
            "CORE instana-core/instana-core Ready" "UNIT instana-units/tenant0-unit0 Ready" PODS_TOTAL=59 ;;
        *"stanctl versions identify"*) echo IDENTIFY >> "$CALLS"; printf '%s\n' "$IDENTIFY_OUT" ;;
        *"PKG="*) echo VERSIONS >> "$CALLS"
          printf '%s\n' "PKG=${VM_PKG:-1.15.0}" "CLI=stanctl version ${VM_PKG:-1.15.0}" "CORE_STATUS_VERSION=${VM_CORE_VERSION:-}" \
            CORE_SPEC_TAG= "IMAGE_TAG=${VM_IMAGE_TAG:-3.327.712-0}" ;;
        *transparent_hugepage*) echo KERNEL_CHECK >> "$CALLS" ;;
        *"ufw status"*) echo UFW_CHECK >> "$CALLS" ;;
        *ufw*) echo "UFW_CHANGE $inner" >> "$CALLS" ;;
        *"findmnt -rn -M"*) echo MOUNT_CHECK >> "$CALLS"; echo "MOUNTED:ext4:uuid-1" ;;
        *"shutdown -r"*|*reboot*) echo REBOOT >> "$CALLS" ;;
        *"stanctl up"*) echo STANCTL_UP >> "$CALLS" ;;
        *"apt-get install"*|*"apt update"*|*"sources.list.d"*) echo "APT $inner" >> "$CALLS" ;;
        *"apt-mark hold"*) echo HOLD >> "$CALLS" ;;
        *"kubectl wait"*) echo "HEALTH ${inner:0:60}" >> "$CALLS" ;;
        *) echo "OTHER ${inner:0:80}" >> "$CALLS" ;;
      esac
    }
    main
  ) < <(printf '%s\n' admin-pass-1234 download-key-1234 agent-key-1234 sales-key-1234 y y y) > "$OUT.raw" 2>&1 || RC=$?
  sed 's/\x1b\[[0-9;]*m//g' "$OUT.raw" > "$OUT"
}

# 1. The real lab: everything verified, nothing installed, report at the end.
new_case lab
run_resume
[[ "$RC" == 0 ]] || fail "resume on the installed VM must finish (exit $RC)"
has "Kubernetes already exists on mikrut-lab"
has "Kernel settings verified on mikrut-lab (THP never, swappiness 0, inotify 8192); not rebooted (Instana is installed)."
has "UFW is active on mikrut-lab; rules not re-applied on the running cluster."
has "Already installed by this deployment: stanctl 1.15.0 (held), nothing installed or changed."
has "Backend 3.327.712-0 runs in Core (instana-core pod images), as pinned."
has "stanctl up was not repeated: Core and Unit were verified Ready on mikrut-lab."
has "[PHASE 12/12]"
has "Installation Complete!"
has "Backend version: 3.327.712-0   (stanctl 1.15.0)"
has "203.0.113.7 unit0-tenant0.lab.example.com"
hasnt "no selectable"
for c in CHECK_VM ENSURE_VMS ENSURE_DISKS ENSURE_FIREWALL KERNEL_CHECK UFW_CHECK MOUNT_CHECK VERSIONS STATUS HEALTH; do
  called "$c" || fail "expected step not run: $c"
done
for c in REBOOT STANCTL_UP IDENTIFY UFW_CHANGE APT SCP; do
  if called "$c"; then fail "must not run on an installed VM: $(grep -m1 -F "$c" "$CASE/calls")"; fi
done
[[ "$(grep -c "Existing verified mount" "$OUT")" == 4 ]] || fail "all four mounts must be kept as they are"
if grep -q "mkfs" "$CASE/calls"; then fail "nothing may be formatted"; fi
[[ "$(jq -r '.progress_phase_12' "$CASE/.install-state.json")" == completed ]] || fail "phase 12 not recorded"
[[ "$(jq -r '.stanctl_up_status' "$CASE/.install-state.json")" == completed ]] || fail "stanctl up result not recorded"
[[ -s "$CASE/.install-report.txt" ]] || fail "final report not saved"
echo "PASS: resume phases 1-12 on the installed lab: verified, no reboot/UFW change/apt/stanctl up/identify, report written"

# 2. Another backend runs than the one pinned -> HOW TO RESOLVE, phase 11 not reached.
new_case otherbackend
VM_CORE_VERSION=3.329.100-0 run_resume
[[ "$RC" != 0 ]] || fail "a different running backend must stop"
has "Instana backend 3.329.100-0 runs on mikrut-lab (Core status), but this deployment pinned 3.327.712-0."
has "HOW TO RESOLVE"
has "jq '.backend_version = \"3.329.100-0\"' .install-state.json"
hasnt "[PHASE 11/12]"
echo "PASS: a different running backend stops with what was found and how to proceed"

# 3. Another stanctl package than the pinned one -> HOW TO RESOLVE, nothing installed.
new_case otherstanctl
VM_PKG=1.15.1 run_resume
[[ "$RC" != 0 ]] || fail "a different stanctl must stop"
has "stanctl on mikrut-lab is 1.15.1, but this deployment pinned 1.15.0."
has "sudo apt-get install -y --allow-downgrades stanctl=1.15.0 && sudo apt-mark hold stanctl"
if called APT; then fail "resume must not change stanctl by itself"; fi
echo "PASS: a different stanctl stops with the exact command to restore the pinned one"

# 4. The same identify output on the fresh-install path -> explained, not a bare stop.
OUT="$TEST_ROOT/fresh.txt"; RC=0
(
  cd "$TEST_ROOT/lab"; set --; source ./install.sh
  DRY_RUN=false; INSTALL_MODE=online; DOWNLOAD_KEY=download-key-1234; GCP_ZONE=z; GCP_PROJECT=p
  printf '{}\n' > "$STATE_FILE"
  prompt_choice() { printf '%s\n' 1.15.0; }
  upload_private_file() { :; }
  remote_exec() {
    case "$4" in
      *"apt-cache madison stanctl"*) printf '%s\n' 1.15.0 ;;
      *"dpkg-query -W"*) printf 1.15.0 ;;
      *"stanctl --version"*) echo "stanctl version 1.15.0" ;;
      *"stanctl versions identify"*) printf '%s\n' "$IDENTIFY_OUT" ;;
    esac
  }
  install_stanctl fresh-vm z p
  echo NOT-STOPPED
) > "$OUT" 2>&1 || RC=$?
[[ "$RC" == 1 ]] || fail "fresh install with 'No newer versions' must stop with exit 1 (got $RC)"
hasnt NOT-STOPPED
has "stanctl 1.15.0 on fresh-vm lists no backend versions: it reports that an Instana backend is already installed there."
has "stanctl said: Identifying supported Instana versions... ✓ No newer versions available."
has "HOW TO RESOLVE"
has "./install.sh --resume"
hasnt "download-key-1234"
echo "PASS: 'No newer versions available' on a fresh install is explained with HOW TO RESOLVE"
