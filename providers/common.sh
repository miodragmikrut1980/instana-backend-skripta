#!/usr/bin/env bash
# Provider layer: every cloud-specific step goes through provider_<op>, which
# dispatches to prov_<PROVIDER>_<op> in providers/<PROVIDER>.sh. Everything that
# runs on the VMs themselves (kernel, UFW, mounts, stanctl) stays provider-neutral.
# Provider code calls its CLI (gcloud, ...) by bare name so the test mocks
# (shell functions or fake binaries on PATH) keep working.

PROVIDERS_SUPPORTED="gcp"

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
"

provider_name() { printf '%s\n' "${PROVIDER:-gcp}"; }

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

# resolve_provider [NAME] — first of: NAME, INSTANA_PROVIDER, PROVIDER in the
# saved parameters, provider in the state file, gcp. Sets PROVIDER and
# PROVIDER_LABEL; an unsupported name returns 1 and leaves PROVIDER unchanged.
resolve_provider() {
  local chosen="${1:-}" from_config="" from_state=""
  [[ -f "${CONFIG_FILE:-}" ]] && from_config=$(jq -r '.parameters.PROVIDER // empty' "$CONFIG_FILE" 2>/dev/null || true)
  [[ -f "${STATE_FILE:-}" ]] && from_state=$(jq -r '.provider // empty' "$STATE_FILE" 2>/dev/null || true)
  chosen="${chosen:-${INSTANA_PROVIDER:-${from_config:-${from_state:-gcp}}}}"
  validate_provider_name "$chosen" || return 1
  PROVIDER="$chosen"
  PROVIDER_LABEL=$(provider_label)
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
