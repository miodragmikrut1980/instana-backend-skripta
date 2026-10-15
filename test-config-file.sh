#!/usr/bin/env bash
# Input file (--config FILE, or "import them from a JSON file" in the menu):
# values from the file are checked like typed answers, only missing or invalid
# ones are asked, and every stop explains what is wrong and how to fix it.
# Uses the files in examples/ and mocks gcloud/curl like test-dry-run.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/gcloud" <<'GCLOUD'
#!/usr/bin/env bash
case "$*" in
  *"auth list"*) echo tester@example.com ;;
  *"regions describe"*) printf '%s\n' '{"quotas":[{"metric":"CPUS","limit":999,"usage":0}]}' ;;
  *"instances describe"*) exit 1 ;;
  *) exit 0 ;;
esac
GCLOUD
chmod +x "$TEST_ROOT/bin/gcloud"
printf '#!/usr/bin/env bash\necho 203.0.113.10\n' > "$TEST_ROOT/bin/curl"
chmod +x "$TEST_ROOT/bin/curl"

mkdir -p "$TEST_ROOT/pkg/airgapped/config" "$TEST_ROOT/pkg/airgapped/buildmeta"
printf '#!/bin/sh\necho stanctl version 1.10.9\n' > "$TEST_ROOT/pkg/airgapped/stanctl"
printf 'instana-version: 3.285.123-0\nregistry:\n  url: artifact-public.instana.io\n' > "$TEST_ROOT/pkg/airgapped/config/instana.yaml"
printf 'version: 1.10.9\ncommitDate: 2026-01-01\ncommitHash: abc\n' > "$TEST_ROOT/pkg/airgapped/buildmeta/buildmeta.yaml"
tar -czf "$TEST_ROOT/instana-airgapped.tar.gz" -C "$TEST_ROOT/pkg" airgapped

fail() { echo "FAIL: $*" >&2; [[ -f "${OUT:-}" ]] && tail -40 "$OUT" >&2; exit 1; }
has() { grep -qF -- "$1" "$OUT" || fail "expected text not found: $1"; }
hasnt() { if grep -qF -- "$1" "$OUT"; then fail "unexpected text found: $1"; fi; }

# new_case NAME — fresh installer folder (no state, no saved parameters).
new_case() {
  CASE="$TEST_ROOT/$1"
  mkdir -p "$CASE"
  cp -R "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/providers" "$SCRIPT_DIR/examples" "$CASE/"
  chmod 600 "$CASE"/examples/*.json
  OUT="$CASE/out.txt"
}

# run_installer STDIN ARGS... — exit code in RC, colour-free output in $OUT.
run_installer() {
  local input="$1"; shift
  RC=0
  ( cd "$CASE" && PATH="$TEST_ROOT/bin:$PATH" bash ./install.sh "$@" <<< "$input" ) > "$OUT.raw" 2>&1 || RC=$?
  sed 's/\x1b\[[0-9;]*m//g' "$OUT.raw" > "$OUT"
}

no_questions() {  # prompt_choice prints "? <question>" even without a terminal
  if grep -q '^? ' "$OUT"; then fail "a question was asked: $(grep -m1 '^? ' "$OUT")"; fi
}

completed() {
  [[ "$RC" == 0 ]] || fail "exit code $RC"
  has "Installation Plan"
  has "100% complete"
}

# 1. Complete file: no question at all, plan and full dry-run; secrets never shown.
new_case full
run_installer "y" --config examples/single-gcp-online-full.json --dry-run
completed; no_questions
has "22 values taken from the file; 0 will be asked below."
has "Base domain:                   instana.lab.example.com"
has "Backend version:               3.323.470-0"
for s in test-download-key-0000 test-agent-key-0000 test-sales-key-0000 Test-Admin-Pass-0000; do
  hasnt "$s"
  if grep -rqF "$s" "$CASE"/install-*.log; then fail "secret in the log"; fi
done
echo "PASS: complete file runs without a single question"

# 2. No terminal and values missing: one stop listing every missing value with the fix.
new_case partial_notty
run_installer "" --config examples/single-gcp-online-partial.json --dry-run
[[ "$RC" != 0 ]] || fail "incomplete file without a terminal must stop"
has "cannot be used without a terminal: 6 value(s) are missing or invalid"
has "HOW TO RESOLVE"
has '- SSH_SOURCE_CIDR: missing. Needed for: who may open SSH to the VMs (firewall rule). Example: "SSH_SOURCE_CIDR": "auto"'
has '- BASE_DOMAIN: missing. Needed for: the address Instana is reached at. Example: "BASE_DOMAIN": "instana.lab.example.com".'
for k in ADMIN_PASSWORD DOWNLOAD_KEY AGENT_KEY SALES_KEY; do
  has "- ${k}: missing (\"secrets\".\"${k}\" is empty and INSTANA_${k} is not set)"
done
has "export INSTANA_DOWNLOAD_KEY=... INSTANA_AGENT_KEY=... INSTANA_SALES_KEY=... INSTANA_ADMIN_PASSWORD=..."
has "Fill in these values in the file (or open it in config-generator.html"
hasnt "Installation Plan"
no_questions
echo "PASS: no terminal: every missing value is listed with what it is for and an example"

# 3. No terminal and invalid values: each listed with the reason and a valid example.
new_case invalid_notty
run_installer "" --config examples/single-gcp-invalid-values.json --dry-run
[[ "$RC" != 0 ]] || fail "invalid file without a terminal must stop"
has "5 value(s) are missing or invalid"
has "- GCP_PROJECT: 'X' cannot be used: Invalid GCP Project ID 'X'"
has "- SSH_SOURCE_CIDR: '10.0.0.0/33' cannot be used: Invalid IPv4 CIDR: 10.0.0.0/33."
has "- VM_NAME: 'Test_Lab' cannot be used: VM_NAME 'Test_Lab' is invalid"
has "- BASE_DOMAIN: 'bad_domain!' cannot be used: Invalid FQDN: bad_domain!."
has "- TENANT_NAME: 'Tenant-0' cannot be used: Tenant name 'Tenant-0' is invalid"
has 'Example: "TENANT_NAME": "tenant0".'
echo "PASS: no terminal: every invalid value is listed with the reason and a valid example"

# 4. Import from the menu: invalid values are explained, then asked; typed answers win.
new_case invalid_menu
run_installer $'2\n'"$CASE/examples/single-gcp-invalid-values.json"$'\nmy-project-1\n\nmikrut-lab\ninstana.lab.example.com\ntenant0\ny' --dry-run
completed
for k in GCP_PROJECT SSH_SOURCE_CIDR VM_NAME BASE_DOMAIN TENANT_NAME; do
  has "${k} from single-gcp-invalid-values.json cannot be used (reason above); please enter it now. Valid example:"
done
has "GCP Project:                   my-project-1"
has "VM name:                       mikrut-lab"
has "Tenant/Unit:                   tenant0/unit0"
has "SSH source CIDR:               203.0.113.10/32"
echo "PASS: menu import: invalid values are explained and asked, the rest comes from the file"

# 5. Keys from the environment, file without keys.
new_case env_secrets
jq '.secrets |= map_values("")' "$CASE/examples/single-gcp-online-full.json" > "$CASE/nokeys.json"; chmod 600 "$CASE/nokeys.json"
INSTANA_DOWNLOAD_KEY=env-download INSTANA_AGENT_KEY=env-agent INSTANA_SALES_KEY=env-sales INSTANA_ADMIN_PASSWORD=env-admin \
  run_installer "y" --config nokeys.json --dry-run
completed; no_questions
grep -qE "^  ok +DOWNLOAD_KEY +•••• \(hidden, from the environment variable INSTANA_DOWNLOAD_KEY\)" "$OUT" || fail "DOWNLOAD_KEY env row"
hasnt "env-download"
echo "PASS: keys can come from INSTANA_* environment variables"

# 6. PROVIDER_* names are accepted as aliases; a file without PROVIDER means gcp.
for f in single-gcp-provider-aliases single-gcp-legacy-no-provider; do
  new_case "$f"
  run_installer "y" --config "examples/$f.json" --dry-run
  completed; no_questions
  has "Zone:                          europe-west6-b"
done
echo "PASS: PROVIDER_* aliases and files without PROVIDER"

# 7. Two names for one setting with different values.
new_case conflict_notty
run_installer "" --config examples/single-gcp-alias-conflict.json --dry-run
[[ "$RC" != 0 ]] || fail "conflict without a terminal must stop"
has "- GCP_ZONE: the file gives two different values, GCP_ZONE='europe-west6-b' and PROVIDER_LOCATION='europe-west6-a' (the same setting under two names). Keep only one of them."
new_case conflict_menu
run_installer $'2\n'"$CASE/examples/single-gcp-alias-conflict.json"$'\n2\ny' --dry-run
completed
has "gives two different values for the same setting: GCP_ZONE='europe-west6-b' and PROVIDER_LOCATION='europe-west6-a'"
has "? Which value should be used for GCP_ZONE?"
has "Zone:                          europe-west6-a"
echo "PASS: alias conflict: listed without a terminal, chosen with one"

# 8. Unknown key: ignored with a suggestion; the real key is then asked.
new_case unknown_key
run_installer $'2\n'"$CASE/examples/single-gcp-unknown-key.json"$'\nmytenant\ny' --dry-run
completed
has "Unknown key TENNANT_NAME in single-gcp-unknown-key.json is ignored. Did you mean TENANT_NAME? Correct the name in the file so it is used next time."
has "Tenant/Unit:                   mytenant/unit0"
echo "PASS: unknown key is ignored with a 'did you mean' hint"

# 9. Machine size: custom above the minimum is used; below it is explained.
new_case custom_size
run_installer "y" --config examples/single-gcp-custom-size.json --dry-run
completed; no_questions
has "Machine type:                  n2-standard-32"
new_case custom_small
run_installer "" --config examples/single-gcp-custom-size-too-small.json --dry-run
[[ "$RC" != 0 ]] || fail "too small custom size must stop without a terminal"
has "- VM_CPUS: '16' cannot be used: VM_CPUS 16 is below the minimum of 28 vCPUs for a production single-node installation."
has "- VM_RAM_GB: '64' cannot be used: VM_RAM_GB 64 is below the minimum of 112 GB for a production single-node installation."
echo "PASS: custom machine size is checked against the documented minimum"

# 10. Three-node: the size is fixed; another size in the file is ignored with a warning.
new_case three_large
run_installer "y" --config examples/three-gcp-size-large.json --dry-run
completed; no_questions
grep -qE "^  skip +SIZE +'large' ignored: three-node uses a fixed size \(3 x n2-standard-16\)" "$OUT" || fail "SIZE skip row"
has "SIZE 'large' from three-gcp-size-large.json is ignored: three-node uses the fixed small size."
test "$(grep -c '\[INFO\].*Creating VM:' "$OUT")" -eq 3 || fail "three VMs expected"
hasnt "Machine size for all nodes"
new_case three_dup
run_installer "" --config examples/three-gcp-duplicate-names.json --dry-run
[[ "$RC" != 0 ]] || fail "duplicate node names must stop without a terminal"
has "- NODE2_NAME: 'test-node-1' cannot be used: NODE2_NAME 'test-node-1' is already used for NODE1_NAME; each node needs its own name."
echo "PASS: three-node size is fixed and node names must differ"

# 11. Existing hosts (ssh) are not available yet: clear stop with the alternative.
new_case ssh
run_installer "" --config examples/three-ssh-full.json --dry-run
[[ "$RC" != 0 ]] || fail "PROVIDER ssh must stop"
has "PROVIDER 'ssh' (install on existing hosts over SSH) in three-ssh-full.json is not available in this version yet"
has 'set "PROVIDER": "gcp" in the file'
echo "PASS: PROVIDER ssh stops with an explanation"

# 12. Air-gapped: the package from the file is used, versions come from it.
new_case air
sed "s#__ARCHIVE__#$TEST_ROOT/instana-airgapped.tar.gz#" "$CASE/examples/single-gcp-airgapped-existing.json" > "$CASE/air.json"; chmod 600 "$CASE/air.json"
run_installer "y" --config air.json --dry-run
completed; no_questions
grep -qE "^  skip +BACKEND_VERSION +ignored for this deployment" "$OUT" || fail "BACKEND_VERSION skip row"
has "import backend 3.285.123-0"
new_case air_missing
run_installer "" --config examples/single-gcp-airgapped-missing-archive.json --dry-run
[[ "$RC" != 0 ]] || fail "missing package must stop without a terminal"
has "- AIRGAP_ARCHIVE: '/nonexistent/instana-airgapped.tar.gz' cannot be used: Air-gapped package (AIRGAP_ARCHIVE) not found or is a symlink"
echo "PASS: air-gapped package from the file"

# 13. Keys in a file readable by others: tightened to 600, the missing keys listed.
new_case perms
chmod 644 "$CASE/examples/single-gcp-secrets-only-download.json"
run_installer "" --config examples/single-gcp-secrets-only-download.json --dry-run
has "contains keys but other users could read it (permissions 644); setting it to 600 (owner only)."
test "$(stat -c %a "$CASE/examples/single-gcp-secrets-only-download.json")" = 600 || fail "file mode not 600"
has "- AGENT_KEY: missing"
hasnt "- DOWNLOAD_KEY: missing"
hasnt "test-download-key-0000"
echo "PASS: a file with keys is made owner-only"

# 14. Unusable files stop at once with the reason and the fix.
for f in bad-schema-version:"has schema_version '2'; this installer reads schema_version 1" \
         bad-schema-name:"is not an installer input file: \"schema\" is 'something-else', expected 'instana-installer-input'" \
         bad-non-string-values:"every value must be text in quotes, e.g. \"VM_CPUS\": \"32\". Not text: VM_CPUS, SSH_PORT." \
         invalid-json:"is not valid JSON"; do
  new_case "${f%%:*}"
  run_installer "" --config "examples/${f%%:*}.json" --dry-run
  [[ "$RC" != 0 ]] || fail "${f%%:*} must stop"
  has "${f#*:}"
  has "HOW TO RESOLVE"
done
new_case missing_file
run_installer "" --config nothere.json --dry-run
[[ "$RC" != 0 ]] || fail "missing file must stop"
has "Input file not found: $CASE/nothere.json"
new_case no_path
run_installer "" --config
has "--config needs the path of the JSON input file."
has "./install.sh --config instana-config.json"
new_case with_resume
run_installer "" --config examples/single-gcp-online-full.json --resume
[[ "$RC" != 0 ]] || fail "--config with --resume must stop"
has "--config cannot be combined with --resume"
has "./install.sh --resume"
new_case symlink
ln -s "$CASE/examples/single-gcp-online-full.json" "$CASE/link.json"
run_installer "" --config link.json --dry-run
[[ "$RC" != 0 ]] || fail "a symbolic link must be refused"
has "is a symbolic link; refused for safety. Use the real file path."
has "HOW TO RESOLVE"
echo "PASS: unusable files and option combinations stop with HOW TO RESOLVE"

# 15. Menu import: a wrong path is explained and asked again.
new_case menu_path
run_installer $'2\n/nope.json\nn\n'"$CASE/examples/single-gcp-online-full.json"$'\ny' --dry-run
completed
has "Input file not found: /nope.json"
has "Continuing; please answer the question again."
echo "PASS: import screen re-asks a wrong path"

# 16. Plan: E changes one value and shows the plan again; S saves a file to reuse.
new_case edit
idx=$(printf '%s\n' TOPOLOGY INSTALL_MODE INSTALL_TYPE UBUNTU_VERSION GCP_PROJECT GCP_REGION GCP_ZONE GCP_NETWORK GCP_SUBNET SSH_SOURCE_CIDR VM_NAME SIZE BASE_DOMAIN | grep -n '^BASE_DOMAIN$' | cut -d: -f1)
run_installer $'e\n'"$idx"$'\nedited.example.com\ny' --config examples/single-gcp-online-full.json --dry-run
completed
has "? Which value do you want to change?"
has "Changing BASE_DOMAIN; every other value is kept"
test "$(grep -c 'Installation Plan' "$OUT")" -eq 2 || fail "plan must be shown again after an edit"
has "Base domain:                   edited.example.com"
echo "PASS: plan E changes one value and shows the plan again"

new_case save
run_installer "s" --config examples/single-gcp-online-full.json --dry-run
[[ "$RC" == 0 ]] || fail "save must exit 0"
saved=$(ls "$CASE"/instana-config-test-lab-*.json)
test "$(stat -c %a "$saved")" = 600 || fail "saved file not 600"
jq -e '.schema=="instana-installer-input" and .schema_version==1 and (.secrets|all(.[]; .=="")) and .parameters.PROVIDER=="gcp"' "$saved" >/dev/null || fail "saved file content"
for k in TOPOLOGY INSTALL_MODE INSTALL_TYPE GCP_PROJECT GCP_ZONE VM_NAME SIZE BASE_DOMAIN TENANT_NAME STANCTL_VERSION BACKEND_VERSION TLS_MODE; do
  [[ "$(jq -r --arg k "$k" '.parameters[$k]' "$saved")" == "$(jq -r --arg k "$k" '.parameters[$k]' "$CASE/examples/single-gcp-online-full.json")" ]] || fail "saved $k differs"
done
has "Parameters saved to $saved (permissions 600, keys and admin password NOT included)."
hasnt "100% complete"
test -f "$saved" || fail "saved file missing"
for v in test-download-key-0000 test-agent-key-0000 test-sales-key-0000 Test-Admin-Pass-0000; do
  if grep -qF "$v" "$saved"; then fail "secret $v written into the saved file"; fi
done
cp "$saved" "$CASE/again.json"
INSTANA_DOWNLOAD_KEY=d INSTANA_AGENT_KEY=a INSTANA_SALES_KEY=s INSTANA_ADMIN_PASSWORD=p run_installer "y" --config again.json --dry-run
completed; no_questions
echo "PASS: plan S saves a reusable file without keys (round trip)"

# 17. --export-config writes the parameters saved in this folder as an input file.
new_case export
jq -n '{schema_version:1, parameters:{TOPOLOGY:"single-node", INSTALL_MODE:"online", INSTALL_TYPE:"production",
  UBUNTU_VERSION:"ubuntu-2204-lts", GCP_PROJECT:"my-project-1", GCP_REGION:"europe-west6", GCP_ZONE:"europe-west6-b",
  GCP_NETWORK:"default", GCP_SUBNET:"default", SSH_SOURCE_CIDR:"203.0.113.10/32", VM_NAME:"saved-lab", VM_CPUS:"32",
  VM_RAM_GB:"128", MACHINE_TYPE:"n2-standard-32", BASE_DOMAIN:"saved.example.com", TENANT_NAME:"t1", UNIT_NAME:"u1",
  TLS_MODE:"auto-generate (self-signed)", NODE0_NAME:"", NODE1_NAME:"", NODE2_NAME:"", NODE_CPUS:"", NODE_RAM_GB:"",
  TLS_CRT_PATH:"", TLS_KEY_PATH:"", AIRGAP_ARCHIVE:""}}' > "$CASE/.install-config.json"
chmod 600 "$CASE/.install-config.json"
run_installer "" --export-config exported.json
[[ "$RC" == 0 ]] || fail "--export-config exit code $RC"
jq -e '.parameters.SIZE=="custom" and .parameters.VM_CPUS=="32" and .parameters.VM_NAME=="saved-lab" and (has("secrets")) and (.parameters|has("MACHINE_TYPE")|not)' "$CASE/exported.json" >/dev/null || fail "exported content"
test -f "$CASE/exported.json" || fail "exported file missing"
for v in test-download-key-0000 test-agent-key-0000 test-sales-key-0000 Test-Admin-Pass-0000; do
  if grep -qF "$v" "$CASE/exported.json"; then fail "secret $v written into the exported file"; fi
done
run_installer "" --export-config exported.json
[[ "$RC" != 0 ]] || fail "existing export file must not be replaced without confirmation"
has "exported.json already exists and was not replaced."
new_case export_none
run_installer "" --export-config
[[ "$RC" != 0 ]] || fail "export without saved parameters must stop"
has "Nothing to export: this folder has no .install-config.json"
new_case export_unsafe
printf '{"schema_version":1,"parameters":{}}\n' > "$CASE/real.json"
ln -s "$CASE/real.json" "$CASE/.install-config.json"
run_installer "" --export-config
[[ "$RC" != 0 ]] || fail "export from a symbolic link must stop"
has "is a symbolic link or belongs to another user; it is not read"
has "Run the export as the user who owns this installer folder"
has "./install.sh --export-config"
echo "PASS: --export-config"

# 18. After Start: offer to blank the keys in the file (only on yes).
new_case blank
cp "$CASE/examples/single-gcp-online-full.json" "$CASE/k.json"; chmod 600 "$CASE/k.json"
( cd "$CASE"; set --; source ./install.sh
  DRY_RUN=false INPUT_CONFIG="$CASE/k.json" INPUT_LABEL=k.json INPUT_HAD_SECRETS=true
  offer_blank_input_secrets <<< "n" >/dev/null 2>&1
  jq -e '.secrets.DOWNLOAD_KEY=="test-download-key-0000"' k.json >/dev/null
  offer_blank_input_secrets <<< "y" >/dev/null 2>&1
  jq -e '(.secrets|all(.[]; .=="")) and .parameters.VM_NAME=="test-lab"' k.json >/dev/null
) || fail "blanking the keys in the file"
echo "PASS: keys are removed from the file only after yes"

# 19. Existing three-node deployment in the folder: resume is refused for an
#     imported file (with the command to use); setting it aside continues.
new_case state
( cd "$CASE"; set --; source ./install.sh
  printf '{"topology":"three-node","gcp_project":"p","gcp_zone":"europe-west6-b","deployment_id":"%s","vm_a":"created"}\n' "$(printf 'a%.0s' {1..32})" > .install-state.json
  TOPOLOGY=three-node PARAMS_SOURCE=import INPUT_LABEL=f.json RESUME=false DRY_RUN=true
  NODE_CPUS=12 NODE_RAM_GB=48 NODE0_NAME=n0 NODE1_NAME=n1 NODE2_NAME=n2
  prepare_topology <<< "y"
) > "$CASE/out.raw" 2>&1 && fail "resume of a recorded deployment from a file must stop"
sed 's/\x1b\[[0-9;]*m//g' "$CASE/out.raw" > "$OUT"
has "The deployment recorded in this folder can only be resumed with the parameters it was started with; the values from f.json cannot change it."
has "./install.sh --resume"
( cd "$CASE"; set --; source ./install.sh
  TOPOLOGY=three-node PARAMS_SOURCE=import INPUT_LABEL=f.json RESUME=false DRY_RUN=true
  NODE_CPUS=12 NODE_RAM_GB=48 NODE0_NAME=n0 NODE1_NAME=n1 NODE2_NAME=n2
  prepare_topology <<< $'n\n2'
  ls .install-state.json.*.old >/dev/null
) > "$CASE/out.raw" 2>&1 || { cat "$CASE/out.raw" >&2; fail "setting the old state aside must continue"; }
echo "PASS: existing deployment: resume refused for a file, set-aside continues"

# 20. Closed input in the new questions stops with what happened and how to go on.
new_case conflict_eof
run_installer $'2\n'"$CASE/examples/single-gcp-alias-conflict.json" --dry-run
[[ "$RC" != 0 ]] || fail "closed input at the conflict question must stop"
has "Input ended while choosing between GCP_ZONE='europe-west6-b' and PROVIDER_LOCATION='europe-west6-a'"
has "Keep only one of the two names in the file"
new_case edit_eof
run_installer "e" --config examples/single-gcp-online-full.json --dry-run
[[ "$RC" != 0 ]] || fail "closed input at the edit question must stop"
has "Input ended while choosing the value to change; the installation was not started and nothing was created."
has "at the plan answer E and pick the value by its number"
new_case menu_eof
run_installer "" --dry-run
[[ "$RC" != 0 ]] || fail "closed input at the source menu must stop"
has "Input ended before the way to provide the parameters was chosen"
has "./install.sh --config instana-config.json"
echo "PASS: closed input in the new questions is explained"

# 21. A failing state write while the plan is confirmed stops the run (set -e
#     must stay active inside show_plan), so nothing is created unrecorded.
new_case plan_state
# A separate bash process: inside "( ... ) && x" a subshell would run with set -e off.
cat > "$CASE/plan.sh" <<'PLAN'
set --; source ./install.sh
DRY_RUN=false PLAN_EDITABLE=true RESUME=false
TOPOLOGY=single-node INSTALL_TYPE=demo INSTALL_MODE=online UBUNTU_VERSION=ubuntu-2404-lts-amd64
GCP_PROJECT=test-project GCP_ZONE=europe-west6-b MACHINE_TYPE=n2-standard-16 VM_NAME=instana-backend
BASE_DOMAIN=instana.example.com TENANT_NAME=tenant0 UNIT_NAME=unit0 TLS_MODE=auto SSH_SOURCE_CIDR=203.0.113.10/32
provider_validate_config() { :; }; provider_validate_image() { :; }
prompt_plan_decision() { echo yes; }
save_state() { return 1; }
run_plan_confirmation
echo "AFTER-PLAN"
PLAN
RC=0; ( cd "$CASE" && bash plan.sh ) > "$CASE/out.raw" 2>&1 || RC=$?
[[ "$RC" != 0 ]] || fail "a failing save_state in the plan must stop the run"
if grep -q "AFTER-PLAN" "$CASE/out.raw"; then fail "the run continued after save_state failed"; fi
echo "PASS: a failing state write at the plan stops the run"

echo "All input-file tests passed."
