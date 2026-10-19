#!/usr/bin/env bash
set -euo pipefail
# Host address question of the ssh provider: on a Google Cloud control machine
# the running VMs of the project are offered (this machine and hosts already
# chosen left out, its own zone first); without gcloud, or when listing fails,
# the address is typed; a saved address is the default. SSH user default: ubuntu.
SRC="$(cd "$(dirname "$0")" && pwd)"
source "$SRC/test-ssh-lib.inc"
ssh_fakes_setup
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR" "$FAKE_ROOT"' EXIT
cp -R "$SRC"/*.sh "$SRC/providers" "$TEST_DIR/"
cd "$TEST_DIR"
OUT="$FAKE_ROOT/out"

cat > "$FAKE_ROOT/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
[[ -f "$SCEN/gcloud.fail" ]] && exit 1
case "$*" in
  *"config get-value project"*) echo test-project ;;
  *"instances list"*"--project=test-project"*"status=RUNNING"*)
    printf '%s\n' "ctl europe-west6-b 10.172.0.2" "zz-a us-central1-a 10.128.0.5" \
      "ssh-test-1 europe-west6-b 10.172.0.9" "aa-b europe-west6-b 10.172.0.7" 'bad;name europe-west6-b 10.1.1.1' ;;
esac
FAKE
printf '#!/usr/bin/env bash\necho ctl\n' > "$FAKE_ROOT/bin/hostname"
printf '#!/usr/bin/env bash\necho projects/1/zones/europe-west6-b\n' > "$FAKE_ROOT/bin/curl"
chmod +x "$FAKE_ROOT/bin/gcloud" "$FAKE_ROOT/bin/hostname" "$FAKE_ROOT/bin/curl"

set --
source ./install.sh
init() { INSTANA_PROVIDER=ssh resolve_provider; DRY_RUN=false TOPOLOGY=single-node PARAMS_SOURCE=manual CONFIG_LOADED=false; }
plain() { sed 's/\x1b\[[0-9;]*m//g' "$OUT"; }

( init; prov_ssh_ask_host VM_HOST "Host address" < <(printf '2\n') > "$OUT" 2>&1; test "$VM_HOST" = 10.172.0.9 )
o=$(plain)
[[ "$o" == *"Running VMs in Google Cloud project test-project"* ]]
[[ "$o" == *"aa-b  (europe-west6-b, 10.172.0.7)"*"ssh-test-1  (europe-west6-b, 10.172.0.9)"*"zz-a  (us-central1-a, 10.128.0.5)"*"enter another address"* ]] ||
  { echo "FAIL: list order or content: $o" >&2; exit 1; }
if [[ "$o" == *"ctl  ("* || "$o" == *"bad;name"* ]]; then echo "FAIL: this machine or an unsafe name offered" >&2; exit 1; fi
echo 'PASS: running VMs are offered (own zone first, this machine left out); picking one gives its internal IP'

( init; TOPOLOGY=three-node NODE0_HOST=10.172.0.9; prov_ssh_ask_host NODE1_HOST "Node 1 host" < <(printf '1\n') > "$OUT" 2>&1; test "$NODE1_HOST" = 10.172.0.7 )
if plain | grep -q '10.172.0.9)'; then echo "FAIL: host of node 0 offered again" >&2; exit 1; fi
echo 'PASS: three-node: a host already chosen is not offered again'

( init; prov_ssh_ask_host VM_HOST "Host address" < <(printf '4\n10.0.0.5\n') > "$OUT" 2>&1; test "$VM_HOST" = 10.0.0.5 )
echo 'PASS: "enter another address" asks for the address'

touch "$SCEN/gcloud.fail"
( init; prov_ssh_ask_host VM_HOST "Host address" < <(printf '10.0.0.6\n') > "$OUT" 2>&1; test "$VM_HOST" = 10.0.0.6 )
if plain | grep -q 'Running VMs'; then echo "FAIL: list shown although gcloud failed" >&2; exit 1; fi
rm -f "$SCEN/gcloud.fail"
echo 'PASS: a failing gcloud falls back to typing the address, without a stop'

( init; command() { [[ "$*" == "-v gcloud" ]] && return 1; builtin command "$@"; }
  prov_ssh_ask_host VM_HOST "Host address" < <(printf '10.0.0.7\n') > "$OUT" 2>&1; test "$VM_HOST" = 10.0.0.7 )
if plain | grep -q 'Running VMs'; then echo "FAIL: list shown without gcloud" >&2; exit 1; fi
echo 'PASS: without gcloud the address is typed'

echo '{"schema_version":1,"parameters":{"VM_HOST":"10.9.9.9"}}' > .install-config.json
( init; CONFIG_LOADED=true; prov_ssh_ask_host VM_HOST "Host address" < <(printf '\n') > "$OUT" 2>&1; test "$VM_HOST" = 10.9.9.9 )
if plain | grep -q 'Running VMs'; then echo "FAIL: list shown although a saved address exists" >&2; exit 1; fi
rm -f .install-config.json
echo 'PASS: a saved address is the default and the list is not shown'

host_facts 10.172.0.9
( init; prov_ssh_collect_location_params < <(printf '2\n\n%s\n22\n' "$FAKE_KEY") > "$OUT" 2>&1; test "$VM_HOST" = 10.172.0.9; test "$SSH_USER" = ubuntu )
echo 'PASS: the SSH user defaults to ubuntu'

# The control machine is left out by its address too (another name, same IP).
printf '#!/usr/bin/env bash\ncase "$1" in -I) echo "10.172.0.2 172.17.0.1" ;; *) echo renamed-ctl ;; esac\n' > "$FAKE_ROOT/bin/hostname"
( init; prov_ssh_ask_host VM_HOST "Host address" < <(printf '1\n') > "$OUT" 2>&1; test "$VM_HOST" = 10.172.0.7 )
if plain | grep -q '10.172.0.2)'; then echo "FAIL: control machine offered by its IP" >&2; exit 1; fi
printf '#!/usr/bin/env bash\necho ctl\n' > "$FAKE_ROOT/bin/hostname"
echo 'PASS: the control machine is not listed, also when only its IP matches'

# gcloud without a project: no list, no guessed project.
printf '#!/usr/bin/env bash\ncase "$*" in *"get-value project"*) echo "(unset)" ;; *) echo "SHOULD-NOT-LIST" ;; esac\n' > "$FAKE_ROOT/bin/gcloud"
( init; prov_ssh_ask_host VM_HOST "Host address" < <(printf '10.0.0.8\n') > "$OUT" 2>&1; test "$VM_HOST" = 10.0.0.8 )
if plain | grep -q 'Running VMs\|instana-support-test-account'; then echo "FAIL: list without a gcloud project" >&2; exit 1; fi
echo 'PASS: gcloud without a project shows no list'

