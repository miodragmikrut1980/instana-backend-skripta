#!/usr/bin/env bash
set -euo pipefail
# SSH provider host checks (phase 3). Every STOP must say, in plain words,
# (a) what was found on which host, (b) why it blocks the installation,
# (c) how to fix it, (d) how to continue — asserted for each case below.
SRC="$(cd "$(dirname "$0")" && pwd)"
source "$SRC/test-ssh-lib.inc"
ssh_fakes_setup
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR" "$FAKE_ROOT"' EXIT
cp -R "$SRC"/*.sh "$SRC/providers" "$TEST_DIR/"
cd "$TEST_DIR"

# run_checks TOPOLOGY — phase 3 against the scenario files; output in $OUT.
OUT="$FAKE_ROOT/out"
run_checks() {
  local topo="$1"
  (
    set --
    source ./install.sh
    INSTANA_PROVIDER=ssh resolve_provider
    DRY_RUN=false RESUME="${RESUME:-false}" TOPOLOGY="$topo" INSTALL_TYPE=demo
    SSH_USER=ubuntu SSH_KEY_PATH="$FAKE_KEY" SSH_PORT=22
    VM_NAME=lab VM_HOST=h1
    NODE0_NAME=n0 NODE1_NAME=n1 NODE2_NAME=n2 NODE0_HOST=h1 NODE1_HOST=h2 NODE2_HOST=h3
    [[ "$topo" == three-node ]] && INSTALL_TYPE=production
    provider_ensure_vms
  ) > "$OUT" 2>&1
}

# expect_stop NAME FOUND WHY FIX — the run failed and its text carries all four parts.
expect_stop() {
  local name="$1" found="$2" why="$3" fix="$4" o
  o=$(sed 's/\x1b\[[0-9;]*m//g' "$OUT")
  local why_line; why_line=$(grep -m1 'Why the installation stops:' <<< "$o" || true)
  [[ "$why_line" == *"$why"* ]] || { echo "FAIL: ${name}: the 'Why the installation stops:' line does not say '${why}'" >&2; echo "$o" | tail -20 >&2; exit 1; }
  for part in "$found" "$fix" "How to continue afterwards:"; do
    [[ "$o" == *"$part"* ]] || { echo "FAIL: ${name}: missing '${part}' in:"; echo "$o" | tail -20; exit 1; } >&2
  done
  echo "PASS: ${name} stops with an explanation"
}

stop_case() {
  local name="$1" topo="$2"; shift 2
  if run_checks "$topo"; then echo "FAIL: ${name} was accepted" >&2; tail -5 "$OUT" >&2; exit 1; fi
  expect_stop "$name" "$@"
}

for h in h1 h2 h3; do host_facts "$h"; done
run_checks single-node
grep -q 'lab (h1): Ubuntu 24.04.1 LTS, 32 vCPUs' "$OUT"
echo 'PASS: a healthy host passes'

host_facts h1 SUDO=no
stop_case "no passwordless sudo" single-node "Host h1: user ubuntu cannot run sudo without a password." \
  "every installation step runs as root" "NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-instana-installer"

host_facts h1 OS_VERSION=20.04 "OS_NAME=Ubuntu 20.04.6 LTS"
stop_case "Ubuntu 20.04" single-node "Host h1: it runs Ubuntu 20.04.6 LTS" \
  "supports only Ubuntu 22.04 and 24.04" "Use a host with Ubuntu 24.04"

host_facts h1 ARCH=aarch64
stop_case "ARM host" single-node "Host h1: its CPU architecture is aarch64." \
  "runs only on x86_64" "Use an x86_64 host"

host_facts h1 CPUS=8 MEM_KB=32000000
stop_case "too small" single-node "Host h1: it has 8 vCPUs and 32 GB RAM." \
  "needs at least 16 vCPUs and 64 GB RAM" "Give the host more CPU/RAM"

host_facts h1 ROOT_SIZE=60000000000
stop_case "root below IBM minimum" single-node "Host h1: its root filesystem (/) is 60 GB." \
  "IBM requires at least 100 GB for /" "Grow the root disk"

host_facts h1 FIREWALLD=active
stop_case "firewalld active" single-node "Host h1: firewalld is active." \
  "The installer never disables a firewall by itself." "sudo systemctl disable --now firewalld"

host_facts h1 K3S=yes
stop_case "existing k3s" single-node "Host h1: Kubernetes (k3s) is already installed" \
  "a new installation needs a host without an existing cluster" "sudo /usr/local/bin/k3s-uninstall.sh"

host_facts h1; host_facts h2 SSHD22=no
stop_case "three-node sshd not on 22" three-node "Host h2: sshd does not listen on port 22." \
  "node 0 reaches the other nodes as root over SSH on port 22" "sudo systemctl restart ssh"

host_facts h2
echo 1 > "$SCEN/h1.rc"; echo 255 > "$SCEN/h1.rc"; echo "ssh: connect to host h1 port 22: Connection refused" > "$SCEN/h1.err"
stop_case "SSH login fails" single-node "Host h1: SSH login as ubuntu on port 22 with key ${FAKE_KEY} failed: ssh: connect to host h1 port 22: Connection refused." \
  "the installer runs every step on the host over SSH" "ssh -i ${FAKE_KEY} -p 22 ubuntu@h1 true"

echo "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!" > "$SCEN/h1.err"
stop_case "changed host key" single-node "Host h1: its SSH host key differs from the key recorded" \
  "the address now leads to another machine" "ssh-keygen -R h1 -f"
rm -f "$SCEN/h1.rc" "$SCEN/h1.err"

# Resume: the machine behind the address must be the one recorded at the start.
echo '{"provider":"ssh","hostid_lab":"mid-original"}' > .install-state.json
RESUME=true stop_case "different machine on resume" single-node "Host h1: its machine ID (mid-h1) differs from the one recorded when this deployment started (mid-original)." \
  "the address now leads to another machine" "./install.sh --destroy"
rm -f .install-state.json

host_facts h1 ROOT_SIZE=150000000000; host_facts h2; host_facts h3
run_checks three-node
grep -q 'h1: root filesystem (/) is 150 GB; the GCP labs of this installer use 270 GB' "$OUT"
echo 'PASS: three-node root between the IBM minimum and the lab size only warns'
