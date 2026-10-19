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
cat > "$TEST_ROOT/bin/gcloud" <<'GCLOUD'
#!/usr/bin/env bash
case "$*" in
  *"auth list"*) echo tester@example.com ;;
  *"regions describe"*) printf '%s\n' '{"quotas":[{"metric":"CPUS","limit":999,"usage":0}]}' ;;
  *"instances describe"*) exit 1 ;;
  *) exit 0 ;;
esac
GCLOUD
printf '#!/usr/bin/env bash\necho 203.0.113.10\n' > "$TEST_ROOT/bin/curl"
chmod +x "$TEST_ROOT/bin/gcloud" "$TEST_ROOT/bin/curl"

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
  OUT="$CASE/out.txt"; RC=0
  ( cd "$CASE" && PATH="$TEST_ROOT/bin:$PATH" bash ./install.sh --dry-run "$@" <<< "$input" ) > "$OUT.raw" 2>&1 || RC=$?
  sed 's/\x1b\[[0-9;]*m//g' "$OUT.raw" > "$OUT"
}
done_ok() { [[ "$RC" == 0 ]] || fail "exit code $RC"; has "Installation Plan"; has "Dry-run complete"; }

# Answers after the menu, single-node GCP online, in question order.
LOC=$'test-project\nus-central1\nus-central1-a\ndefault\ndefault\n'
TAIL=$'instana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\ny'

# 1. "<" at the mode question: topology again with the earlier answer as default (Enter).
run back_once $'1\n1\n<\n\n1\n1\n1\n'"$LOC"$'203.0.113.10/32\ninstana-backend\n1\n'"$TAIL"
done_ok
[[ "$(count '? Select deployment topology:')" == 2 ]] || fail "topology must be asked twice"
[[ "$(count '? Select installation connectivity mode:')" == 2 ]] || fail "mode must be asked again"
has "Topology:                      single-node"
echo "PASS: < goes to the previous question; Enter keeps the earlier answer"

# 2. Back over topology and change it: the single-node answers that no longer
#    apply are dropped, three-node questions are asked (no machine size).
run change_topology $'1\n1\n1\n<\n<\n2\n\n1\n'"$LOC"$'203.0.113.10/32\ninstana-0\ninstana-1\ninstana-2\n'"$TAIL"
done_ok
has "Topology:                      three-node"
has "Installation type:             production"
hasnt "? Machine size:"
has "Node 0 (backend):              instana-0"
echo "PASS: changing an earlier answer re-asks only what depends on it"

# 3. A changed install type changes the size choices (dependent cleared).
run change_type $'1\n1\n1\n1\n<\n2\n1\n'"$LOC"$'203.0.113.10/32\ninstana-backend\n1\n'"$TAIL"
done_ok
has "Installation type:             production"
has "Machine type:                  n2-standard-32"
echo "PASS: a changed install type is used by the size question"

# 4. "<" at the first question returns to the parameter-source menu.
run first_back $'1\n<\n1\n1\n1\n1\n1\n'"$LOC"$'203.0.113.10/32\ninstana-backend\n1\n'"$TAIL"
done_ok
[[ "$(count '? How do you want to provide the deployment parameters?')" == 2 ]] || fail "menu must be shown again"
echo "PASS: < at the first question goes back to the menu"

# 5. Secrets: "<" from the agent key back to the download key; Enter keeps it.
SEC=$'instana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\n<\n\nagent-secret\nsales-secret\n1\ny'
run secret_back $'1\n1\n1\n1\n1\n'"$LOC"$'203.0.113.10/32\ninstana-backend\n1\n'"$SEC"
done_ok
hasnt "download-secret"; hasnt "agent-secret"
echo "PASS: back over a secret keeps it on Enter and never shows it"

# 6. "<" is never taken as a value; a back over a text answer re-offers it.
run text_back $'1\n1\n1\n1\n1\n'"$LOC"$'203.0.113.10/32\nmy-vm\n<\n\n\n1\n'"$TAIL"
done_ok
has "VM name:                       my-vm"
hasnt ": <"
echo "PASS: < is never stored; the earlier text answer is the default"

# 7. Plan E, then "<" at the value: nothing changes, the plan is shown again.
idx=$(printf '%s\n' TOPOLOGY INSTALL_MODE INSTALL_TYPE UBUNTU_VERSION GCP_PROJECT GCP_REGION GCP_ZONE GCP_NETWORK GCP_SUBNET SSH_SOURCE_CIDR VM_NAME SIZE BASE_DOMAIN | grep -n '^BASE_DOMAIN$' | cut -d: -f1)
run edit_back $'1\n1\n1\n1\n1\n'"$LOC"$'203.0.113.10/32\ninstana-backend\n1\ninstana.example.com\ntenant0\nunit0\nadmin-secret\ndownload-secret\nagent-secret\nsales-secret\n1\ne\n'"$idx"$'\n<\ny'
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
run import_back $'2\n<\n1\n1\n1\n1\n1\n'"$LOC"$'203.0.113.10/32\ninstana-backend\n1\n'"$TAIL"
done_ok
[[ "$(count '? How do you want to provide the deployment parameters?')" == 2 ]] || fail "menu must be shown again after < at the file path"
echo "PASS: < at the file path goes back to the menu"

echo "All back-navigation tests passed."
