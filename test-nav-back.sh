#!/usr/bin/env bash
# "<" goes back to the previous question: earlier answers become Enter
# defaults, a changed answer clears the answers that depend on it, "<" at the
# first question returns to the parameter-source menu, secrets keep their
# value on Enter, "<" is never stored. Mock gcloud/curl as in test-dry-run.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
# META=1: this control machine is a GCE VM (project ctl-project, zone
# europe-west6-b, network mynet/mysub); IPIFY_FAIL=1: no public IP detected.
cat > "$TEST_ROOT/bin/gcloud" <<'GCLOUD'
#!/usr/bin/env bash
case "$*" in
  *"config get-value project"*) [[ "${META:-}" == 1 ]] && echo ctl-project ;;
  *"instances describe ctl "*) echo mysub ;;
  *"instances describe noperm"*) echo "ERROR: (gcloud.compute.instances.describe) Required 'compute.instances.get' permission" >&2; exit 1 ;;
  *"auth list"*) echo tester@example.com ;;
  *"regions describe"*) printf '%s\n' '{"quotas":[{"metric":"CPUS","limit":999,"usage":0}]}' ;;
  *"instances describe taken-vm"*) echo taken-vm ;;
  *"instances describe"*) echo "ERROR: (gcloud.compute.instances.describe) The resource 'projects/p/zones/z/instances/x' was not found" >&2; exit 1 ;;
  *) exit 0 ;;
esac
GCLOUD
cat > "$TEST_ROOT/bin/curl" <<'CURL'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *metadata.google.internal*)
    [[ "${META:-}" == 1 ]] || exit 7
    case "$url" in
      */instance/zone) echo projects/1/zones/europe-west6-b ;;
      */project/project-id) echo ctl-project ;;
      */network-interfaces/0/network) echo projects/1/networks/mynet ;;
      */network-interfaces/0/ip) echo 10.172.0.2 ;;
      *) exit 22 ;;
    esac ;;
  *ipify*) [[ "${IPIFY_FAIL:-}" == 1 ]] && exit 6; echo 203.0.113.10 ;;
  *) echo 203.0.113.10 ;;
esac
CURL
printf '#!/usr/bin/env bash\necho ctl\n' > "$TEST_ROOT/bin/hostname"
chmod +x "$TEST_ROOT/bin/gcloud" "$TEST_ROOT/bin/curl" "$TEST_ROOT/bin/hostname"
mkdir -p "$TEST_ROOT/pkg/airgapped/config" "$TEST_ROOT/pkg/airgapped/buildmeta"
printf '#!/bin/sh\necho stanctl version 1.10.9\n' > "$TEST_ROOT/pkg/airgapped/stanctl"
printf 'instana-version: 3.285.123-0\n' > "$TEST_ROOT/pkg/airgapped/config/instana.yaml"
printf 'version: 1.10.9\n' > "$TEST_ROOT/pkg/airgapped/buildmeta/buildmeta.yaml"
tar -czf "$TEST_ROOT/instana-airgapped.tar.gz" -C "$TEST_ROOT/pkg" airgapped

fail() { echo "FAIL: $*" >&2; [[ -f "${OUT:-}" ]] && tail -40 "$OUT" >&2; exit 1; }
has() { grep -qF -- "$1" "$OUT" || fail "expected text not found: $1"; }
hasnt() { if grep -qF -- "$1" "$OUT"; then fail "unexpected text found: $1"; fi; }
count() { grep -cF -- "$1" "$OUT" || true; }

# run NAME INPUT [ARGS...] — dry-run in a fresh folder; colour-free output in $OUT.
run() {
  local name="$1" input="$2"; shift 2
  CASE="$TEST_ROOT/$name"; mkdir -p "$CASE"
  cp -R "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/providers" "$SCRIPT_DIR/examples" "$CASE/"
  chmod 600 "$CASE"/examples/*.json
  # An input file in the folder: the parameter-source menu is shown, so "<"
  # at the first question has somewhere to go (without one the questions
  # start at once; test-start-flow.sh / test-config-file.sh cover that).
  [[ -n "${NOFILE:-}" ]] || cp "$CASE/examples/single-gcp-online-full.json" "$CASE/instana-config-found.json"
  [[ -z "${CERTDIR:-}" ]] || cp "$TEST_ROOT/lab.crt" "$TEST_ROOT/lab.key" "$CASE/"
  jq 'del(.parameters.GCP_ZONE, .parameters.BASE_DOMAIN)' "$CASE/examples/single-gcp-online-full.json" > "$CASE/nozone.json"
  chmod 600 "$CASE/nozone.json"
  OUT="$CASE/out.txt"; RC=0
  ( cd "$CASE" && PATH="$TEST_ROOT/bin:$PATH" bash ./install.sh --dry-run "$@" <<< "$input" ) > "$OUT.raw" 2>&1 || RC=$?
  sed 's/\x1b\[[0-9;]*m//g' "$OUT.raw" > "$OUT"
}
done_ok() { [[ "$RC" == 0 ]] || fail "exit code $RC"; has "Installation Plan"; has "Dry-run complete"; }

# Answers after the menu, single-node GCP online, in question order:
# topology, mode, type, the location block (Enter = use detected), VM name, then TAIL.
TAIL=$'instana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\ny'

# 1. "<" at the mode question: topology again with the earlier answer as default (Enter).
run back_once $'1\n1\n<\n\n1\n1\n\ninstana-backend\n'"$TAIL"
done_ok
[[ "$(count '? Select deployment topology:')" == 2 ]] || fail "topology must be asked twice"
[[ "$(count '? Select installation connectivity mode:')" == 2 ]] || fail "mode must be asked again"
has "Topology:                      single-node"
echo "PASS: < goes to the previous question; Enter keeps the earlier answer"

# 2. Back over topology and change it: the single-node answers that no longer
#    apply are dropped, three-node questions are asked (no machine size).
run change_topology $'1\n1\n1\n<\n<\n2\n\n\ninstana-0\ninstana-1\ninstana-2\n'"$TAIL"
done_ok
has "Topology:                      three-node"
has "Installation type:             production"
hasnt "? Machine size:"
has "Node 0 (backend):              instana-0"
echo "PASS: changing an earlier answer re-asks only what depends on it"

# 3. "<" at the location block goes back to the install type; a changed type
#    changes the machine size (dependent cleared, default minimum for the type).
run change_type $'1\n1\n1\n1\n<\n2\n\ninstana-backend\n'"$TAIL"
done_ok
has "Installation type:             production"
has "Machine type:                  n2-standard-32"
echo "PASS: a changed install type is used by the size question"

# 4. "<" at the first question returns to the parameter-source menu.
run first_back $'1\n<\n1\n1\n1\n1\n\ninstana-backend\n'"$TAIL"
done_ok
[[ "$(count '? Where do the answers come from?')" == 2 ]] || fail "menu must be shown again"
echo "PASS: < at the first question goes back to the menu"

# 5. Secrets: "<" from the agent key back to the download key; Enter keeps it.
SEC=$'instana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\n<\n\nagent-secret\nsales-secret\n1\ny'
run secret_back $'1\n1\n1\n1\n\ninstana-backend\n'"$SEC"
done_ok
hasnt "download-secret"; hasnt "agent-secret"
echo "PASS: back over a secret keeps it on Enter and never shows it"

# 6. "<" is never taken as a value; a back over a text answer re-offers it.
run text_back $'1\n1\n1\n1\n\nmy-vm\n<\n\n'"$TAIL"
done_ok
has "VM name:                       my-vm"
hasnt ": <"
echo "PASS: < is never stored; the earlier text answer is the default"

# 7. Plan E, then "<" at the value: nothing changes, the plan is shown again.
idx=$(printf '%s\n' TOPOLOGY INSTALL_MODE INSTALL_TYPE UBUNTU_VERSION GCP_PROJECT GCP_REGION GCP_ZONE GCP_NETWORK GCP_SUBNET SSH_SOURCE_CIDR VM_NAME SIZE BASE_DOMAIN | grep -n '^BASE_DOMAIN$' | cut -d: -f1)
run edit_back $'1\n1\n1\n1\n\ninstana-backend\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\ne\n'"$idx"$'\n<\ny'
done_ok
has "BASE_DOMAIN was not changed; back to the plan."
[[ "$(count 'Installation Plan')" == 2 ]] || fail "plan must be shown again"
has "Base domain:                   instana.example.com"
echo "PASS: < while changing a value at the plan keeps it"

# 8. Import with values missing: "<" at the first question that is asked
#    cannot go to values from the file; the operator is told where to change them.
run cfg_back $'2\nexamples/single-gcp-online-partial.json\n<\n\ninstana.example.com\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\ny'
done_ok
has "This is the first question to answer; the values before it come from single-gcp-online-partial.json. Change those with E at the plan."
echo "PASS: in a run from a file, < at the first asked question explains where earlier values come from"

# 9. Import from the menu: "<" at the file path returns to the menu.
run import_back $'2\n<\n1\n1\n1\n1\n\ninstana-backend\n'"$TAIL"
done_ok
[[ "$(count '? Where do the answers come from?')" == 2 ]] || fail "menu must be shown again after < at the file path"
echo "PASS: < at the file path goes back to the menu"

# 10. Location block: c changes one value; "<" inside the change menu returns
#     to the block; "<" at the block goes back to the previous question.
run block_change $'1\n1\n1\n1\nc\n2\neurope-west6-b\n\ninstana-backend\n'"$TAIL"
done_ok
has "Where the VM(s) are created, detected from this machine and gcloud."
has "Zone:                          europe-west6-b"
has "(your answer; region europe-west6)"
run block_back $'1\n1\n1\n1\nc\n<\n<\n\n\ninstana-backend\n'"$TAIL"
done_ok
[[ "$(count 'Where the VM(s) are created, detected from this machine')" == 3 ]] || fail "block must be shown 3 times (start, after < in the change menu, after going back)"
[[ "$(count '? Select installation type:')" == 2 ]] || fail "< at the block must go back to the install type"
has "Zone:                          us-central1-a"
hasnt "? Select Ubuntu version"
hasnt "? Machine size:"
echo "PASS: location block: Enter uses the detected values, c changes one, < goes back"

# 11. A VM name that already exists in the zone is explained and asked again.
run vm_taken $'1\n1\n1\n1\n\ntaken-vm\nn\nfresh-vm\n'"$TAIL"
done_ok
has "A VM named 'taken-vm' already exists in us-central1-a"
has "VM name:                       fresh-vm"
echo "PASS: an existing VM name is refused at the question"

# 12. Ubuntu version and machine size are not asked; E at the plan changes them.
keys=$(printf '%s\n' TOPOLOGY INSTALL_MODE INSTALL_TYPE UBUNTU_VERSION GCP_PROJECT GCP_REGION GCP_ZONE GCP_NETWORK GCP_SUBNET SSH_SOURCE_CIDR VM_NAME SIZE BASE_DOMAIN)
u=$(grep -n '^UBUNTU_VERSION$' <<< "$keys" | cut -d: -f1); z=$(grep -n '^SIZE$' <<< "$keys" | cut -d: -f1)
run plan_edit $'1\n1\n1\n1\n\ninstana-backend\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\ne\n'"$u"$'\n2\ne\n'"$z"$'\n3\n32\n128\ny'
done_ok
has "Ubuntu version:                ubuntu-2204-lts"
has "Machine type:                  n2-standard-32"
has "e = change a value (also Ubuntu and machine size)"
echo "PASS: Ubuntu version and machine size are changed with E at the plan"

# 13. Going back into the location block keeps the earlier answers (no
#     fallback to detected defaults): Enter everywhere, plan unchanged.
run block_keep $'1\n1\n1\n1\nc\n1\nmy-proj-123\nc\n2\neurope-west6-b\nc\n3\nnet1\nsub1\n\nmy-vm\n<\n<\n\n\n'"$TAIL"
done_ok
has "GCP Project:                   my-proj-123"
has "Zone:                          europe-west6-b"
has "VM name:                       my-vm"
echo "PASS: back into the location block keeps project, zone and network"

# 14. Custom machine size: changing it again from the plan offers the earlier
#     custom CPU/RAM as Enter defaults (a block without "<").
z=$(printf '%s\n' TOPOLOGY INSTALL_MODE INSTALL_TYPE UBUNTU_VERSION GCP_PROJECT GCP_REGION GCP_ZONE GCP_NETWORK GCP_SUBNET SSH_SOURCE_CIDR VM_NAME SIZE | grep -n '^SIZE$' | cut -d: -f1)
run size_keep $'1\n1\n1\n1\n\ninstana-backend\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\ne\n'"$z"$'\n3\n32\n128\ne\n'"$z"$'\n3\n\n\ny'
done_ok
has "Machine type:                  n2-standard-32"
echo "PASS: the earlier custom CPU/RAM are the defaults when the size is changed again"

# 15. "<" passes over a block without "<" (air-gapped package) to the previous
#     question; the block is not run again.
AIR=$'1\n1\n2\n1\n\ninstana-backend\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\n'"$TEST_ROOT/instana-airgapped.tar.gz"$'\n<\n\n1\ny'
run air_pass "$AIR"
done_ok
[[ "$(count '? How do you want to provide the air-gapped package?')" == 1 ]] || fail "the package block must not run again"
has "import backend 3.285.123-0"
echo "PASS: < passes over a block without <, which is not repeated"

# 16. A changed answer clears what depends on it: air-gapped → back to the
#     connectivity question → online drops the package and its versions (no
#     stale backend version from the package), the version step runs again.
BK=$'<\n<\n<\n<\n<\n<\n<\n<\n<\n<\n<\n'   # TLS → sales → agent → download → admin → unit → tenant → domain → VM name → location → type → mode
run mode_change $'1\n1\n2\n1\n\ninstana-backend\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\n'"$TEST_ROOT/instana-airgapped.tar.gz"$'\n'"$BK"$'1\n\n\n\n\n\n\n\n\n\n\n1\ny'
done_ok
has "Connectivity mode:             online"
hasnt "import backend 3.285.123-0"
hasnt "Backend version:               3.285.123-0"
grep -q -- "--instana-version 'DRY-RUN-COMPATIBLE-SELECTION'" "$OUT" || fail "versions must be chosen again for online"
echo "PASS: a changed answer clears its dependents (package, versions) and they run again"

# 17. Inside a block without "<" (a run from a file: single location questions)
#     the earlier answer is still the Enter default after going back to it.
run file_keep $'2\nnozone.json\neurope-west6-c\n<\n\ninstana.example.com\ny'
done_ok
has "Zone:                          europe-west6-c"
echo "PASS: going back into a block keeps the answer typed there"

# 18. This machine's network is offered only for its own project and region;
#     another project or zone in the block re-derives it (default/default).
export META=1
run net_detect $'1\n1\n1\n1\nc\n1\nother-proj\nc\n2\nus-central1-a\n\ninstana-backend\n'"$TAIL"
unset META
done_ok
grep -qE "Network +mynet / mysub +\(this machine's network; network / subnet\)" "$OUT" || fail "this machine's network must be offered first"
grep -q "Network   default / default .*(every project has 'default'; network / subnet)" "$OUT" || fail "network must be re-derived after another project"
[[ "$(grep -c "mynet / mysub" "$OUT")" == 1 ]] || fail "this machine's network shown for another project"
echo "PASS: this machine's network is offered only in its own project and region"

# 19. Public IP not detected: 0.0.0.0/0 is labelled and not accepted with Enter.
export IPIFY_FAIL=1
run cidr_fail $'1\n1\n1\n1\n\nc\n4\n198.51.100.7/32\n\ninstana-backend\n'"$TAIL"
unset IPIFY_FAIL
done_ok
has "detection failed — 0.0.0.0/0 allows SSH from the whole internet"
has "this machine's public IP could not be detected, and 0.0.0.0/0 would open SSH to the whole internet"
has "SSH from  detection failed — 0.0.0.0/0 allows SSH from the whole internet"
has "press c to enter your IP (curl ifconfig.me shows it)"
has "curl ifconfig.me"
has "SSH source CIDR:               198.51.100.7/32"
echo "PASS: a failed IP detection never opens SSH to the internet with one Enter"

# 20. The VM-name lookup failing for another reason is said, not taken as "free".
run vm_noperm $'1\n1\n1\n1\n\nnoperm\n'"$TAIL"
done_ok
has "Could not check now whether a VM named 'noperm' exists in us-central1-a: ERROR: (gcloud.compute.instances.describe) Required 'compute.instances.get' permission. Phase 3 checks again"
hasnt "Could not check now whether a VM named 'instana-backend'"
echo "PASS: a failing name lookup is reported, not treated as a free name"

# 21. The 0.0.0.0/0 placeholder stays refused after "<" and forward again.
export IPIFY_FAIL=1
run cidr_back $'1\n1\n1\n1\n\n<\n\n\nc\n4\n198.51.100.7/32\n\ninstana-backend\n'"$TAIL"
unset IPIFY_FAIL
done_ok
[[ "$(count "this machine's public IP could not be detected")" == 2 ]] || fail "Enter must be refused again after going back"
has "SSH source CIDR:               198.51.100.7/32"
echo "PASS: the unsafe placeholder is never relabelled or accepted after going back"

# 22. A certificate in the installer folder that covers the domain is
#     offered (Enter uses it, its paths are the defaults).
if command -v openssl >/dev/null && openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=instana.example.com \
     -addext "subjectAltName=DNS:instana.example.com,DNS:*.instana.example.com" \
     -keyout "$TEST_ROOT/lab.key" -out "$TEST_ROOT/lab.crt" >/dev/null 2>&1; then
  CERTDIR=1 run tls_found $'1\n1\n1\n1\n\ninstana-backend\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n\n\n\ny'
  done_ok
  has "Found a certificate for instana.example.com here: lab.crt; Enter uses it."
  has "TLS:                           provide custom certificate files"
  echo "PASS: a certificate for the domain in the folder is offered"
else
  echo "SKIP: openssl cannot create a test certificate here"
fi

# 23. The newest instana-airgapped*.tar.gz is the default package.
( cd "$TEST_ROOT"; mkdir -p newest/home newest/run; cp instana-airgapped.tar.gz newest/home/instana-airgapped-old.tar.gz
  touch -t 202601010000 newest/home/instana-airgapped-old.tar.gz
  cp instana-airgapped.tar.gz newest/home/instana-airgapped-new.tar.gz
  cp -R "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/providers" newest/run/
  cd newest/run; set --; HOME="$TEST_ROOT/newest/home" bash -c 'source ./install.sh; default_airgapped_archive' ) > "$TEST_ROOT/newest.txt" 2>&1
grep -q "instana-airgapped-new.tar.gz" "$TEST_ROOT/newest.txt" || { cat "$TEST_ROOT/newest.txt" >&2; fail "the newest package must be the default"; }
echo "PASS: the newest air-gapped package is the default"

# 24. kubectl without sudo is decided at the plan (default no), never asked
#     at the end of the run.
k=$(printf '%s\n' TOPOLOGY INSTALL_MODE INSTALL_TYPE UBUNTU_VERSION GCP_PROJECT GCP_REGION GCP_ZONE GCP_NETWORK GCP_SUBNET SSH_SOURCE_CIDR VM_NAME SIZE BASE_DOMAIN TENANT_NAME UNIT_NAME STANCTL_VERSION BACKEND_VERSION TLS_MODE KUBE_USER_ACCESS | grep -n '^KUBE_USER_ACCESS$' | cut -d: -f1)
run kube $'1\n1\n1\n1\n\ninstana-backend\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\ne\n'"$k"$'\n2\ny'
done_ok
has "kubectl without sudo:          no (for the SSH user on the Instana host; E changes it)"
has "kubectl without sudo:          yes (for the SSH user on the Instana host; E changes it)"
has "Would copy the cluster-admin kubeconfig to the SSH user's ~/.kube/config"
hasnt "Allow the current SSH user"
echo "PASS: kubectl without sudo is chosen at the plan, not asked at the end"

# 24b. stanctl up timeout: one plan line (default 90 min), changed with E;
#      "?" shows the longer help, an invalid value is asked again, 2h = 120 min.
run sttimeout $'1\n1\n1\n1\n\ninstana-backend\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\ne\n'"$((k + 1))"$'\n?\n10\nn\n2h\ny'
done_ok
has "stanctl up timeout:            90 min (E changes it)"
has "Changing STANCTL_UP_TIMEOUT"
has "stanctl stops waiting after this time even if Instana is still starting"
has "stanctl up timeout '10' is 10 minutes; use 30 to 600 minutes"
has "stanctl up timeout:            120 min (E changes it)"
has "stanctl up --env-file /root/.stanctl.env"
has "--timeout 120m"
echo "PASS: stanctl up timeout is shown in the plan and changed with E (invalid value asked again)"

# 25. /etc/hosts lines: only node 0's IP; taken as detected, asked only when unknown.
( cd "$TEST_ROOT"; mkdir -p ip; cp -R "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/providers" ip/; cd ip; set --
  PATH="$TEST_ROOT/bin:$PATH" bash -c 'source ./install.sh; DRY_RUN=false TOPOLOGY=three-node NODE0_NAME=n0 NODE1_NAME=n1 NODE2_NAME=n2
    BASE_DOMAIN=lab.example.com TENANT_NAME=t UNIT_NAME=u
    print_local_access 34.65.1.2 < /dev/null; echo "UI=$CONFIRMED_UI_IP"
    print_local_access unknown <<< "35.1.2.3"; echo "UI=$CONFIRMED_UI_IP"' ) > "$TEST_ROOT/ip.txt" 2>&1
grep -q "Public IPv4 of n0: 34.65.1.2 (detected; used for the /etc/hosts lines below)." "$TEST_ROOT/ip.txt" || { cat "$TEST_ROOT/ip.txt" >&2; fail "detected IP must be used without a question"; }
grep -q "UI=34.65.1.2" "$TEST_ROOT/ip.txt" && grep -q "UI=35.1.2.3" "$TEST_ROOT/ip.txt" || fail "UI IP"
grep -q "could not be detected; type it" "$TEST_ROOT/ip.txt" || fail "unknown IP must be asked"
if grep -q "n1\|n2" <(grep "Public IPv4 of" "$TEST_ROOT/ip.txt"); then fail "only node 0 is asked"; fi
echo "PASS: only node 0's public IP is used; a detected one is not asked"

# 26. Offered files are only own regular files: a symbolic link to a package is
#     never the default; a certificate needs the domain and *.domain, and the
#     key must belong to it.
( cd "$TEST_ROOT"; rm -rf link && mkdir -p link/home link/run && ln -s "$TEST_ROOT/instana-airgapped.tar.gz" link/home/instana-airgapped.tar.gz
  cp -R "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/providers" link/run/; cd link/run; set --
  HOME="$TEST_ROOT/link/home" bash -c 'source ./install.sh; echo "DEFAULT=[$(default_airgapped_archive)]"' ) > "$TEST_ROOT/link.txt" 2>&1
grep -q "DEFAULT=\[\]" "$TEST_ROOT/link.txt" || { cat "$TEST_ROOT/link.txt" >&2; fail "a symbolic link must not be offered as the package"; }
if command -v openssl >/dev/null; then
  CD="$TEST_ROOT/certs"; mkdir -p "$CD"; cp -R "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/providers" "$CD/"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=a -addext "subjectAltName=DNS:instana.example.com" -keyout "$CD/only.key" -out "$CD/only.crt" >/dev/null 2>&1
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=b -addext "subjectAltName=DNS:instana.example.com,DNS:*.instana.example.com" -keyout "$CD/other.key" -out "$CD/wrongkey.crt" >/dev/null 2>&1
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=c -addext "subjectAltName=DNS:instana.example.com,DNS:*.instana.example.com" -keyout "$CD/wrongkey.key" -out "$CD/unused.crt" >/dev/null 2>&1
  rm -f "$CD/unused.crt"
  ( cd "$CD"; set --; bash -c 'source ./install.sh; BASE_DOMAIN=instana.example.com; echo "FOUND=[$(find_tls_cert_for_domain)]"' ) > "$TEST_ROOT/cert.txt" 2>&1
  grep -q "FOUND=\[\]" "$TEST_ROOT/cert.txt" || { cat "$TEST_ROOT/cert.txt" >&2; fail "a cert without *.domain, or with a key of another cert, must not be offered"; }
fi
echo "PASS: only own regular files are offered; a certificate needs domain and *.domain and its own key"

echo "All back-navigation tests passed."
