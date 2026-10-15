#!/usr/bin/env bash
set -euo pipefail
# The GCP provider passes exactly the gcloud arguments the installer used before
# the provider layer existed (SSH transport, probe, copy, IP lookup, hints).
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/gcloud" <<'GCLOUD'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GCLOUD_ARGS"
case "$*" in
  *networkIP*) echo 10.0.0.5 ;;
  *natIP*) echo 203.0.113.7 ;;
esac
GCLOUD
chmod +x "$TEST_ROOT/bin/gcloud"

bash -s "$(cd "$(dirname "$0")" && pwd)" "$TEST_ROOT" <<'TEST'
set -euo pipefail
err() { echo "$*" >&2; }
source "$1/providers/common.sh"
source "$1/providers/gcp.sh"
export PATH="$2/bin:$PATH" GCLOUD_ARGS="$2/args"
expect() { diff -u - "$GCLOUD_ARGS" || { echo "FAIL: unexpected gcloud arguments for $1" >&2; exit 1; }; }

provider_ssh vm0 zone-a proj-a 'sudo bash -lc echo\ hi'
expect ssh <<'EOF'
compute
ssh
vm0
--project=proj-a
--zone=zone-a
--command=sudo bash -lc echo\ hi
--ssh-flag=-o StrictHostKeyChecking=accept-new
--ssh-flag=-o ConnectTimeout=30
--ssh-flag=-o ServerAliveInterval=15
--ssh-flag=-o ServerAliveCountMax=8
--ssh-flag=-o TCPKeepAlive=yes
EOF

provider_ssh_probe vm0 zone-a proj-a 30 10 'echo ready'
expect ssh_probe <<'EOF'
compute
ssh
vm0
--project=proj-a
--zone=zone-a
--quiet
--command=echo ready
--ssh-flag=-o StrictHostKeyChecking=accept-new
--ssh-flag=-o BatchMode=yes
--ssh-flag=-o ConnectTimeout=10
EOF

provider_scp /tmp/local.env vm0 zone-a proj-a /tmp/.stanctl.env
expect scp <<'EOF'
compute
scp
/tmp/local.env
vm0:/tmp/.stanctl.env
--project=proj-a
--zone=zone-a
--quiet
EOF

test "$(provider_get_ip vm0 zone-a proj-a private)" = 10.0.0.5
expect get_ip <<'EOF'
compute
instances
describe
vm0
--project=proj-a
--zone=zone-a
--format=value(networkInterfaces[0].networkIP)
EOF
test "$(provider_get_ip vm0 zone-a proj-a public)" = 203.0.113.7
echo 'PASS: SSH, probe, copy and IP lookup use the same gcloud arguments as before'

test "$(provider_hint ssh vm0 zone-a proj-a 'df -h /')" = "gcloud compute ssh vm0 --zone=zone-a --project=proj-a --command='df -h /'"
test "$(provider_hint ssh vm0 zone-a proj-a)" = "gcloud compute ssh vm0 --zone=zone-a --project=proj-a"
[[ "$(provider_hint cpu_platform vm0 zone-a proj-a)" == *"set-min-cpu-platform vm0 --min-cpu-platform='Intel Cascade Lake' --zone=zone-a --project=proj-a"* ]]
echo 'PASS: HOW TO RESOLVE hints name the gcloud commands'
TEST
