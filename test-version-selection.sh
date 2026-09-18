#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$(dirname "$0")"/{install.sh,parameters.sh,multinode-online.sh,local-access.sh,multinode-resume.sh,hardware-input.sh,capacity-fallback.sh,progress.sh} "$TEST_DIR/"

(
  cd "$TEST_DIR"
  source ./install.sh
  DRY_RUN=false
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
  ! grep -q -- '--skip-version-check' calls
)

echo 'PASS: exact stanctl selection and compatible backend pinning'
