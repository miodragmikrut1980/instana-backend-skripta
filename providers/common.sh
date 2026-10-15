#!/usr/bin/env bash
# Provider layer: every cloud-specific step goes through provider_<op>, which
# dispatches to prov_<PROVIDER>_<op> in providers/<PROVIDER>.sh. Everything that
# runs on the VMs themselves (kernel, UFW, mounts, stanctl) stays provider-neutral.
# Provider code calls its CLI (gcloud, ...) by bare name so the test mocks
# (shell functions or fake binaries on PATH) keep working.

PROVIDERS_SUPPORTED="gcp ssh"

# The contract: every provider defines prov_<name>_<op> for each op below
# (checked by test-provider-contract.sh).
PROVIDER_CONTRACT_OPS="
label
required_tools
check_auth
default_scope
param_keys
validate_param
collect_location_params
validate_config
validate_image
machine_type_for
disk_device_path
ssh
ssh_probe
scp
get_ip
hint
ensure_vms
ensure_disks
ensure_firewall
preflight_multi
resume_check_vm
destroy_target
destroy_target_text
destroy_validate_target
destroy_from_state
destroy_by_name
uses_param
text
phase_text
ssh_port
plan_target_lines
plan_resource_lines
record_target
confirm_host_changes
resume_state_matches
prepare_multi
collect_host_params
state_resource_pattern
saved_param_keys
check_saved_params
"

# The active provider lives in ACTIVE_PROVIDER, set only by resolve_provider;
# PROVIDER is the saved parameter, so a PROVIDER variable that happens to be in
# the environment never changes the dispatch.
ACTIVE_PROVIDER=""
provider_name() { printf '%s\n' "${ACTIVE_PROVIDER:-gcp}"; }

for _op in $PROVIDER_CONTRACT_OPS; do
  eval "provider_${_op}() { \"prov_\$(provider_name)_${_op}\" \"\$@\"; }"
done
unset _op

# Neutral parameter names accepted for every provider. For GCP they are aliases
# of the GCP_* parameters (see provider_normalize_params).
PROVIDER_COMMON_KEYS="PROVIDER PROVIDER_SCOPE PROVIDER_REGION PROVIDER_LOCATION PROVIDER_NETWORK PROVIDER_SUBNET"

validate_provider_name() {
  case " $PROVIDERS_SUPPORTED " in
    *" ${1:-} "*) ;;
    *) err "Unsupported provider '${1:-}' (supported: ${PROVIDERS_SUPPORTED})."; return 1 ;;
  esac
}

# resolve_provider [NAME [SOURCE]] — picks the provider and sets ACTIVE_PROVIDER,
# PROVIDER and PROVIDER_LABEL. A deployment recorded in this folder wins: the
# state file (an older state without a provider key is a GCP deployment) and an
# explicit PROVIDER in the saved parameters. A requested provider (NAME, which
# SOURCE describes, default "--provider"; otherwise INSTANA_PROVIDER) that
# differs from the recorded one stops with HOW TO RESOLVE instead of switching.
# Without a recorded provider: NAME, then INSTANA_PROVIDER, then gcp.
resolve_provider() {
  local requested="${1:-}" requested_src="${2:---provider}" from_config="" from_state="" saved="" saved_src="" chosen chosen_src
  if [[ -z "$requested" && -n "${INSTANA_PROVIDER:-}" ]]; then
    requested="$INSTANA_PROVIDER" requested_src="INSTANA_PROVIDER"
  fi
  [[ -f "${CONFIG_FILE:-}" ]] && from_config=$(jq -r '.parameters.PROVIDER // empty' "$CONFIG_FILE" 2>/dev/null || true)
  [[ -f "${STATE_FILE:-}" ]] && from_state=$(jq -r '.provider // (if .gcp_project then "gcp" else empty end)' "$STATE_FILE" 2>/dev/null || true)
  if [[ -n "$from_config" && -n "$from_state" && "$from_config" != "$from_state" ]]; then
    provider_resolve_failed "The saved parameters name provider '${from_config}' (.install-config.json) but the deployment in this folder uses '${from_state}' (.install-state.json)." \
      "*Each folder holds one deployment. Restore the .install-config.json that belongs to this deployment, or start the other deployment in a new folder."
    return 1
  fi
  if [[ -n "$from_state" ]]; then saved="$from_state" saved_src=".install-state.json"
  elif [[ -n "$from_config" ]]; then saved="$from_config" saved_src=".install-config.json"; fi
  if [[ -n "$saved" && -n "$requested" && "$requested" != "$saved" ]]; then
    provider_resolve_failed "Provider '${requested}' was requested (${requested_src}) but this folder records provider '${saved}' (${saved_src}); the provider of a recorded deployment never changes." \
      "Continue with the recorded provider: drop the request and rerun:|unset INSTANA_PROVIDER; ./install.sh" \
      "*For a deployment with provider '${requested}', use a new folder (each folder holds one deployment)."
    return 1
  fi
  chosen="${saved:-${requested:-gcp}}"
  chosen_src="${saved_src:-${requested_src}}"
  [[ -n "$saved$requested" ]] || chosen_src="default"
  if [[ " $PROVIDERS_SUPPORTED " != *" $chosen "* ]]; then
    provider_resolve_failed "Unsupported provider '${chosen}' (from ${chosen_src}); supported: ${PROVIDERS_SUPPORTED}." \
      "Use a supported provider, or leave it unset for gcp:|unset INSTANA_PROVIDER; ./install.sh"
    return 1
  fi
  ACTIVE_PROVIDER="$chosen"
  PROVIDER="$chosen"
  PROVIDER_LABEL=$(provider_label)
  ! declare -F progress_apply_provider_titles >/dev/null || progress_apply_provider_titles
}

# provider_text_or KEY DEFAULT_LINE... — the provider's own wording for KEY
# (one line per output line), or the default lines.
provider_text_or() {
  local key="$1" own; shift
  own=$(provider_text "$key")
  if [[ -n "$own" ]]; then printf '%s\n' "$own"; else printf '%s\n' "$@"; fi
}

# Inside the installer a failed resolution stops with HOW TO RESOLVE; sourced
# on its own (tests, --config tooling) it prints the reason and returns 1.
provider_resolve_failed() {
  if declare -F die_with_steps >/dev/null; then die_with_steps "$@"; fi
  err "$1"
}

# provider_normalize_params — GCP keeps GCP_* as the source of truth and the
# PROVIDER_* names as aliases: fills whichever side is empty; both set to
# different values is an error.
provider_normalize_params() {
  [[ "$(provider_name)" == gcp ]] || return 0
  local pair neutral gcp
  for pair in SCOPE:PROJECT REGION:REGION LOCATION:ZONE NETWORK:NETWORK SUBNET:SUBNET; do
    neutral="PROVIDER_${pair%%:*}" gcp="GCP_${pair##*:}"
    if [[ -n "${!neutral:-}" && -n "${!gcp:-}" && "${!neutral}" != "${!gcp}" ]]; then
      err "${neutral}=${!neutral} conflicts with ${gcp}=${!gcp}."; return 1
    fi
    [[ -n "${!gcp:-}" ]] || printf -v "$gcp" '%s' "${!neutral:-}"
    printf -v "$neutral" '%s' "${!gcp:-}"
  done
}
