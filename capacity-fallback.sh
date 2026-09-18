#!/usr/bin/env bash
# Automatic placement fallback only for a fresh first-VM stockout.
deployment_has_resources() {
  [[ -f "$STATE_FILE" ]] || return 1
  jq -e 'to_entries|any(.[]; (.key|startswith("vm_")) or (.key|startswith("disk_")) or (.key|startswith("firewall_")) or (.key|startswith("fw_")))' "$STATE_FILE" >/dev/null
}

placement_command() {
  # Do not call a set -e function in a conditional: run the raw API command.
  local name="$1" machine="$2" zone="$3" project="$4" network="$5" subnet="$6" image="$7"
  local metadata=() labels=()
  [[ "$TOPOLOGY" != three-node || "$INSTALL_MODE" != online ]] || metadata=(--metadata=enable-oslogin=false)
  [[ -z "${DEPLOYMENT_ID:-}" ]] || labels=("--labels=instana-lab-id=$DEPLOYMENT_ID")
  gcloud compute instances create "$name" --project="$project" --zone="$zone" \
    --machine-type="$machine" --image-family="$image" --image-project=ubuntu-os-cloud \
    --boot-disk-size="${BOOT_SIZE_GB:-100}GB" --boot-disk-type=pd-ssd \
    --network="$network" --subnet="$subnet" --tags="${DEPLOYMENT_TAG:-instana-backend}" \
    "${metadata[@]}" "${labels[@]}"
}

create_vm() {
  [[ "$DRY_RUN" != true ]] || { create_vm_once "$@"; return; }
  local name="$1" machine="$2" zone="$3" project="$4" network="$5" subnet="$6" image="$7"
  local output code zones subnets candidate region next_subnet count=0 manifest
  output=$(mktemp)
  log "Creating VM: $name ($machine, zone: $zone)..."
  while true; do
    if placement_command "$name" "$machine" "$zone" "$project" "$network" "$subnet" "$image" >"$output" 2>&1; then
      cat "$output"; rm -f "$output"
      GCP_ZONE="$zone"; GCP_REGION="${zone%-*}"; GCP_SUBNET="$subnet"
      save_state gcp_zone "$GCP_ZONE"
      # Placement is now authoritative; update saved parameters before resuming.
      if [[ -n "${DEPLOYMENT_ID:-}" ]]; then save_state deployment_manifest ''; fi
      save_parameters
      if [[ -n "${DEPLOYMENT_ID:-}" ]]; then save_state deployment_manifest "$(jq -cS .parameters "$CONFIG_FILE")"; fi
      save_state "vm_${name}" created
      ok "VM $name created in $zone (region $GCP_REGION, subnet $subnet)."
      return 0
    else code=$?; fi
    cat "$output"
    if ! grep -qE 'ZONE_RESOURCE_POOL_EXHAUSTED|reason: stockout' "$output"; then
      rm -f "$output"; die "VM creation failed (exit $code); not a stockout. No automatic relocation."
    fi
    deployment_has_resources && { rm -f "$output"; die "Stockout after partial infrastructure creation. Keep the deployment in its zone; no automatic relocation."; }
    if [[ "$count" == 0 ]]; then
      warn "Stockout: searching other zones/regions. This can change latency and regional pricing; CPU/RAM and network remain unchanged."
      # Read APIs must succeed. Do not treat auth errors as missing capacity.
      zones=$(gcloud compute zones list --project="$project" --filter=status=UP --format=json) || { rm -f "$output"; die 'Cannot list zones.'; }
      subnets=$(gcloud compute networks subnets list --project="$project" --network="$network" --format=json) || { rm -f "$output"; die 'Cannot list subnets.'; }
      zones=$(jq -r --arg initial "$zone" --arg current "${zone%-*}" \
        'sort_by([if (.region|endswith("/"+$current)) then 0 else 1 end,.name])|.[]|select(.name!=$initial)|.name' <<< "$zones")
    fi
    next_subnet=''
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      region="${candidate%-*}"
      # Prefer the original subnet name, otherwise accept exactly one subnet
      # in the SAME network and region. Never create/change a VPC network.
      next_subnet=$(jq -r --arg region "$region" --arg old "$6" \
        '[.[]|select(.region|endswith("/"+$region))] as $s |
        if any($s[]; .name==$old) then $old elif ($s|length)==1 then $s[0].name else empty end' <<< "$subnets")
      [[ -n "$next_subnet" ]] || continue
      break
    done <<< "$zones"
    if [[ -z "$next_subnet" || "$count" -ge 12 ]]; then
      rm -f "$output"; die 'No placement succeeded within 13 attempts; no suitable unambiguous subnet or capacity. Retry later.'
    fi
    # Remove the chosen zone and earlier skipped entries to bound the search.
    zones=$(printf '%s\n' "$zones" | awk -v chosen="$candidate" 'seen {print} $0==chosen {seen=1}')
    zone="$candidate"; subnet="$next_subnet"; count=$((count+1))
    log "Automatic capacity retry $count/12: zone=$zone, region=${zone%-*}, subnet=$subnet"
  done
}
