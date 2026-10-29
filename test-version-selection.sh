#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
cp -R "$(dirname "$0")"/*.sh "$(dirname "$0")"/providers "$TEST_DIR/"

(
  cd "$TEST_DIR"
  source ./install.sh
  DRY_RUN=false
  INSTALL_MODE=online
  DOWNLOAD_KEY='test-secret-not-for-log'
  TLS_MODE='auto-generate (self-signed)'
  : > calls
  prompt_choice() {
    case "$1" in
      *stanctl*) printf '%s\n' '1.15.2' ;;
      *backend*) printf '%s\n' '3.321.456-0' ;;
      *) return 1 ;;
    esac
  }
  upload_private_file() { :; }
  remote_exec_dry() { remote_exec "$@"; }
  remote_exec() {
    local command="$4"
    printf '%s\n' "$command" >> calls
    case "$command" in
      *"apt-cache madison stanctl"*) printf '%s\n' '1.15.2' '1.14.4' ;;
      *"dpkg-query -W"*) printf '%s' '1.15.2' ;;
      *"stanctl --version"*) printf '%s\n' 'stanctl version 1.15.2' ;;
      *"stanctl versions identify"*) printf '%s\n' 'Identified the following Instana versions:' '- 3.321.456-0' '- 3.319.465-0' ;;
      *) : ;;
    esac
  }

  install_stanctl node0 zone-a project-a
  [[ "$STANCTL_APT_VERSION" == 1.15.2 ]]
  [[ "$STANCTL_CLI_VERSION" == 1.15.2 ]]
  [[ "$BACKEND_VERSION" == 3.321.456-0 ]]
  [[ "$(get_state stanctl_apt_version)" == 1.15.2 ]]
  [[ "$(get_state stanctl_cli_version)" == 1.15.2 ]]
  [[ "$(get_state backend_version)" == 3.321.456-0 ]]
  grep -q 'stanctl versions identify --quiet' calls

  upload_stanctl_env() { :; }
  run_stanctl_up_single_node node0 zone-a project-a
  grep -q -- "--instana-version '3.321.456-0'" calls
  if grep -q -- '--skip-version-check' calls; then echo "FAIL: test-version-selection.sh:49: unexpected match" >&2; exit 1; fi
)

echo 'PASS: exact stanctl selection and compatible backend pinning'

# stanctl 1.15.1 ignores the download key it is given: HTTP 401 for the
# version list on a machine without earlier stanctl data in ~/.stanctl, for any
# user (verified 2026-10-29). Mock: 1.15.1 fails whenever $HOME has no
# .stanctl/instana.yaml, whoever runs it.
KEY='key-not-for-output-123'
fail() { echo "FAIL: $*" >&2; tail -40 "$OUT" >&2; exit 1; }

# 1. Phase 10 on the VM: the stop shows stanctl's error and HOW TO RESOLVE,
#    and records which stanctl failed.
P10="$TEST_DIR/p10"; mkdir -p "$P10"; cp -R "$TEST_DIR"/*.sh "$TEST_DIR/providers" "$P10/"
OUT="$P10/stop.txt"; rc=0
(
  cd "$P10"; source ./install.sh
  DRY_RUN=false; INSTALL_MODE=online; DOWNLOAD_KEY="$KEY"
  prompt_choice() { printf '%s\n' '1.15.1'; }
  upload_private_file() { :; }
  remote_exec() {
    case "$4" in
      *"apt-cache madison stanctl"*) printf '%s\n' '1.15.1' '1.15.0' ;;
      *"dpkg-query -W"*) printf '%s' '1.15.1' ;;
      *"stanctl --version"*) printf '%s\n' 'stanctl version 1.15.1' ;;
      *"stanctl versions identify"*) echo "Error: status 401 for GET ${STANCTL_RELEASES_URL}"; return 1 ;;
      *) : ;;
    esac
  }
  install_stanctl node0 zone-a project-a
  echo "NOT-STOPPED"
) > "$OUT" 2>&1 || rc=$?
(( rc == 1 )) || fail "phase 10: the 401 must stop with exit 1 (got $rc)"
if grep -q "NOT-STOPPED" "$OUT"; then fail "phase 10 must stop"; fi
grep -q "HOW TO RESOLVE" "$OUT" || fail "phase 10: HOW TO RESOLVE expected"
grep -q "stanctl said: Error: status 401" "$OUT" || fail "phase 10: stanctl's error line expected"
grep -q "Known case: stanctl 1.15.1 gets HTTP 401 on a machine without" "$OUT" || fail "phase 10: the stanctl problem must be explained"
if grep -qi "as root" "$OUT"; then fail "phase 10: the old 'as root' diagnosis must be gone"; fi
grep -qF -- "-w '%{http_code}\n' --netrc-file /etc/apt/auth.conf.d/instana.conf" "$OUT" || fail "phase 10: curl check expected"
grep -qF 'H=$(mktemp -d); HOME="$H" STANCTL_DOWNLOAD_KEY="$K" stanctl versions identify' "$OUT" || fail "phase 10: empty-HOME check expected"
grep -q "./install.sh --resume" "$OUT" || fail "phase 10: how to continue expected"
if grep -qF "$KEY" "$OUT"; then fail "phase 10: the key must never be shown"; fi
[[ "$(cd "$P10" && jq -r .stanctl_identify_failed .install-state.json)" == 1.15.1 ]] || fail "phase 10: the failed stanctl must be recorded"

# 2. Resume after that stop: "choose another stanctl version" (Enter), the
#    failed one is not offered, the other is installed (downgrade allowed)
#    and the run goes on.
OUT="$P10/resume.txt"; rc=0
(
  cd "$P10"; source ./install.sh
  DRY_RUN=false; INSTALL_MODE=online; DOWNLOAD_KEY="$KEY"; RESUME=true
  echo 1.15.1 > installed; : > calls
  prompt_choice() {
    case "$1" in
      *"failed last time"*) printf '%s\n' "${PROMPT_CHOICE_DEFAULT}" ;;
      *stanctl*) [[ " ${*:2} " != *" 1.15.1 "* ]] || { echo "FAILED-OFFERED" >&2; return 1; }; printf '%s\n' '1.15.0' ;;
      *backend*) printf '%s\n' '3.321.456-0' ;;
      *) return 1 ;;
    esac
  }
  upload_private_file() { :; }
  remote_exec() {
    printf '%s\n' "$4" >> calls
    case "$4" in
      *"apt-cache madison stanctl"*) printf '%s\n' '1.15.1' '1.15.0' ;;
      *"apt-get install"*) echo 1.15.0 > installed ;;
      *"dpkg-query -W"*) cat installed ;;
      *"stanctl --version"*) printf 'stanctl version %s\n' "$(cat installed)" ;;
      *"stanctl versions identify"*)
        [[ "$(cat installed)" != 1.15.1 ]] || { echo "Error: status 401"; return 1; }
        printf '%s\n' '- 3.321.456-0' ;;
      *) : ;;
    esac
  }
  install_stanctl node0 zone-a project-a
  [[ "$STANCTL_APT_VERSION" == 1.15.0 && "$BACKEND_VERSION" == 3.321.456-0 ]] || { echo "WRONG-VERSIONS $STANCTL_APT_VERSION $BACKEND_VERSION"; exit 1; }
  [[ -z "$(get_state stanctl_identify_failed)" ]] || { echo "MARK-NOT-CLEARED"; exit 1; }
  grep -q -- "--allow-downgrades 'stanctl=1.15.0'" calls || { echo "NO-DOWNGRADE"; exit 1; }
  echo "RESUMED-OK"
) > "$OUT" 2>&1 || rc=$?
grep -q "RESUMED-OK" "$OUT" || fail "resume must offer another stanctl version and proceed"
grep -q "Last time stanctl 1.15.1 on node0 could not list the backend versions" "$OUT" || fail "resume must say why it asks"

# 3. Before Start, on this machine: the list is read in a fresh empty HOME,
#    as on a new VM. The caller's HOME holds earlier stanctl data, where
#    1.15.1 would work; in the empty HOME it fails while the key works (curl
#    200), so it is left out and the stanctl list is offered again; 1.15.0 is
#    then used. Nothing stops, and sudo is not used for the check.
upfront() {  # upfront NAME CURL_CODE — runs select_local_versions, output in $OUT
  local code="$2"; OUT="$TEST_DIR/$1.txt"; rc=0
  mkdir -p "$TEST_DIR/userhome/.stanctl"; : > "$TEST_DIR/userhome/.stanctl/instana.yaml"
  (
    cd "$TEST_DIR"; set --; source ./install.sh
    DOWNLOAD_KEY="$KEY"; PARAMS_SOURCE=manual; HOME="$TEST_DIR/userhome"
    echo 1.15.1 > installed; : > picks; : > homes
    apt-cache() { printf '%s\n' 'stanctl | 1.15.1 | repo' 'stanctl | 1.15.0 | repo'; }
    dpkg-query() { cat installed; }
    sudo() {
      case "$1" in
        stanctl) echo "SUDO-STANCTL" >> homes; stanctl "${@:2}" ;;
        DEBIAN_FRONTEND=*) [[ "$*" =~ stanctl=([0-9.]+) ]] && echo "${BASH_REMATCH[1]}" > installed ;;
        *) : ;;
      esac
    }
    curl() {
      local a nf="" prev=""; for a in "$@"; do [[ "$prev" != --netrc-file ]] || nf="$a"; prev="$a"; done
      grep -q "password ${KEY}" "$nf" && [[ "$(stat -c %a "$nf" 2>/dev/null || stat -f %Lp "$nf")" == 600 ]] || { printf 000; return 0; }
      printf '%s' "$CURL_CODE"
    }
    stanctl() {
      case "$1" in
        --version) echo "stanctl version $(cat installed)" ;;
        versions)
          printf 'HOME=%s files=%s\n' "$HOME" "$(ls -A "$HOME" | wc -l | tr -d ' ')" >> homes
          if [[ "$(cat installed)" == 1.15.1 && ! -f "$HOME/.stanctl/instana.yaml" ]]; then echo "Error: status 401 for GET x" >&2; return 1; fi
          if [[ "$CURL_CODE" != 200 ]]; then echo "Error: status 401 for GET x" >&2; return 1; fi
          printf '%s\n' '- 3.321.456-0' ;;
      esac
    }
    prompt_choice() {
      case "$1" in
        *stanctl*) echo "${*:2}" >> picks; if [[ " ${*:2} " == *" 1.15.1 "* ]]; then echo 1.15.1; else echo 1.15.0; fi ;;
        *backend*) echo 3.321.456-0 ;;
      esac
    }
    CURL_CODE="$code"
    select_local_versions
    [[ "$STANCTL_APT_VERSION" == 1.15.0 && "$BACKEND_VERSION" == 3.321.456-0 ]] || { echo "WRONG-VERSIONS $STANCTL_APT_VERSION"; exit 1; }
    [[ "$(wc -l < picks | tr -d ' ')" == 2 && "$(tail -1 picks)" == 1.15.0 ]] || { echo "LIST-NOT-REOFFERED"; cat picks; exit 1; }
    echo "UPFRONT-OK"
  ) > "$OUT" 2>&1 || rc=$?
}
upfront upfront 200
grep -q "UPFRONT-OK" "$OUT" || fail "upfront: a stanctl that ignores the given key must be left out and the list offered again"
grep -qF "stanctl 1.15.1 cannot read the version list with the download key it is given (known for 1.15.1: HTTP 401 on a machine without earlier stanctl data in ~/.stanctl); choose another version." "$OUT" || fail "upfront: the stanctl problem must be explained"
grep -q "stanctl said: Error: status 401 for GET x. The key itself works (HTTP 200" "$OUT" || fail "upfront: stanctl's error and the key check must be shown"
grep -q "Left out (cannot read the version list with the download key it is given): 1.15.1" "$OUT" || fail "upfront: the left-out version must be named"
if grep -qi "as root" "$OUT"; then fail "upfront: the old 'as root' diagnosis must be gone"; fi
if grep -q "SUDO-STANCTL" "$TEST_DIR/homes"; then fail "upfront: the check must not use sudo"; fi
if grep -q "HOME=$TEST_DIR/userhome " "$TEST_DIR/homes"; then fail "upfront: the check must not use the caller's HOME"; fi
grep -q "files=0" "$TEST_DIR/homes" || fail "upfront: the check must run in an empty HOME"
for h in $(sed -nE 's/^HOME=([^ ]+) .*/\1/p' "$TEST_DIR/homes"); do [[ ! -e "$h" ]] || fail "upfront: the temporary HOME $h was not removed"; done
if grep -qF "$KEY" "$OUT"; then fail "upfront: the key must never be shown"; fi

# 4. Wrong key: curl is refused too -> explained stop before anything is created.
upfront wrongkey 401
(( rc == 1 )) || fail "wrong key: must stop with exit 1 (got $rc)"
if grep -q "UPFRONT-OK" "$OUT"; then fail "wrong key: must not continue"; fi
grep -q "HOW TO RESOLVE" "$OUT" || fail "wrong key: HOW TO RESOLVE expected"
grep -q "Make sure it is the Instana DOWNLOAD key" "$OUT" || fail "wrong key: the key hint expected"
grep -q "Nothing was created yet" "$OUT" || fail "wrong key: how to continue expected"
if grep -qF "$KEY" "$OUT"; then fail "wrong key: the key must never be shown"; fi
echo 'PASS: stanctl that ignores the given download key: found in an empty HOME before Start and re-offered, wrong key stops, phase-10 stop explains, resume switches the version'
