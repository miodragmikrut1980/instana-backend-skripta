#!/usr/bin/env bash
# Only explicitly allowlisted non-secret values are serialized. Never source JSON.
CONFIG_LOADED=false
PARAMETER_KEYS=(TOPOLOGY INSTALL_MODE INSTALL_TYPE UBUNTU_VERSION GCP_PROJECT
  GCP_REGION GCP_ZONE GCP_NETWORK GCP_SUBNET SSH_SOURCE_CIDR VM_NAME
  NODE0_NAME NODE1_NAME NODE2_NAME VM_CPUS VM_RAM_GB NODE_CPUS NODE_RAM_GB
  MACHINE_TYPE BASE_DOMAIN TENANT_NAME UNIT_NAME TLS_MODE TLS_CRT_PATH
  TLS_KEY_PATH AIRGAP_STANCTL_DEB AIRGAP_ARCHIVE)

save_parameters() {
  [[ "$DRY_RUN" == true ]] && return 0
  if [[ "${RESUME:-false}" == true ]]; then
    [[ -f "$CONFIG_FILE" ]] || die "Resume requires the original .install-config.json; no parameters were changed."
    log "Resume mode: saved non-secret parameters are locked and were not rewritten."
    return 0
  fi
  [[ ! -L "$CONFIG_FILE" ]] || die "Refusing symlink configuration."
  local key temp json='{}'
  for key in "${PARAMETER_KEYS[@]}"; do
    json=$(jq --arg k "$key" --arg v "${!key:-}" '.[$k]=$v' <<< "$json")
  done
  if [[ "${TOPOLOGY:-}" == three-node && "${INSTALL_MODE:-}" == online && -f "$STATE_FILE" ]]; then
    local original
    original=$(get_state deployment_manifest)
    if [[ -n "$original" && "$original" != "$(jq -cS . <<< "$json")" ]]; then
      die "Saved deployment parameters are immutable during resume; original configuration preserved."
    fi
  fi
  temp=$(mktemp "${CONFIG_FILE}.XXXXXX")
  chmod 600 "$temp"
  jq -n --argjson parameters "$json" \
    '{schema_version:1,parameters:$parameters}' > "$temp"
  mv -f "$temp" "$CONFIG_FILE"
  log "Non-secret parameters saved (permissions 600)."
}

offer_saved_parameters() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    [[ "${RESUME:-false}" != true ]] || die "Resume requires the original .install-config.json alongside install.sh."
    return 1
  fi
  [[ ! -L "$CONFIG_FILE" && -O "$CONFIG_FILE" ]] || die "Unsafe config ownership or symlink."
  jq -e 'type=="object" and .schema_version==1 and
    (.parameters|type)=="object" and
    (.parameters|all(.[]; type=="string"))' "$CONFIG_FILE" >/dev/null || die "Invalid saved configuration."
  chmod 600 "$CONFIG_FILE"
  local key choice
  echo "Saved non-secret parameters:" >&2
  jq '.parameters' "$CONFIG_FILE" >&2
  if [[ "${RESUME:-false}" == true ]]; then
    echo "Resume mode: automatically reusing locked saved parameters; editing is disabled." >&2
    choice="reuse saved parameters"
  else
    choice=$(prompt_choice "Previous configuration found:" \
      "reuse saved parameters" "edit parameters (saved text values as defaults)")
  fi
  CONFIG_LOADED=true
  [[ "$choice" == "reuse saved parameters" ]] || return 1
  for key in "${PARAMETER_KEYS[@]}"; do
    printf -v "$key" '%s' "$(jq -r --arg k "$key" '.parameters[$k] // empty' "$CONFIG_FILE")"
  done
  [[ "$TOPOLOGY" == single-node || "$TOPOLOGY" == three-node ]] || die "Invalid saved topology."
  [[ "$INSTALL_MODE" == online || "$INSTALL_MODE" == air-gapped ]] || die "Invalid saved connectivity."
  [[ "$INSTALL_TYPE" == demo || "$INSTALL_TYPE" == production ]] || die "Invalid saved installation type."
  validate_fqdn "$BASE_DOMAIN"
  validate_tenant_unit_name "$TENANT_NAME" Tenant
  validate_tenant_unit_name "$UNIT_NAME" Unit
  validate_cidr "$SSH_SOURCE_CIDR"
  ADMIN_PASSWORD=$(prompt_secret ADMIN_PASSWORD "Instana admin password")
  DOWNLOAD_KEY=$(prompt_secret DOWNLOAD_KEY "Instana download key")
  SALES_KEY=$(prompt_secret SALES_KEY "Instana sales key")
  AGENT_KEY=$(prompt_secret AGENT_KEY "Instana agent key")
  validate_secret "$ADMIN_PASSWORD" "Admin password"
  validate_secret "$DOWNLOAD_KEY" "Download key"
  validate_secret "$SALES_KEY" "Sales key"
  validate_secret "$AGENT_KEY" "Agent key"
  if [[ "$TLS_MODE" == "provide custom certificate files" ]]; then
    [[ -f "$TLS_CRT_PATH" && -f "$TLS_KEY_PATH" ]] || die "Custom TLS files missing."
  else
    [[ "$TLS_MODE" == "auto-generate (self-signed)" ]] || die "Invalid TLS mode."
  fi
  if [[ "$INSTALL_MODE" == air-gapped ]]; then
    [[ -f "$AIRGAP_STANCTL_DEB" && -f "$AIRGAP_ARCHIVE" ]] || die "Air-gap files missing."
  fi
  return 0
}
