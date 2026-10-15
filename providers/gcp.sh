#!/usr/bin/env bash
# GCP provider (gcloud). The GCP_* parameters are the source of truth here.

prov_gcp_label() { echo "GCP"; }
prov_gcp_required_tools() { echo "gcloud"; }
prov_gcp_check_auth() { check_gcp_login; }
prov_gcp_default_scope() { default_gcp_project; }
prov_gcp_param_keys() { echo "GCP_PROJECT GCP_REGION GCP_ZONE GCP_NETWORK GCP_SUBNET"; }
prov_gcp_validate_config() { check_gcp_configuration; }
prov_gcp_machine_type_for() { gcp_machine_type_for "$@"; }

# prov_gcp_validate_param KEY VALUE — format only, never calls gcloud (whether
# the project, zone, network and subnet exist is checked by validate_config).
# Same contract as the prompt_required validators: 0, or 1 with the reason.
prov_gcp_validate_param() {
  local key="$1" value="$2"
  case "$key" in
    GCP_PROJECT|PROVIDER_SCOPE) validate_gcp_project_id "$value" ;;
    GCP_REGION|PROVIDER_REGION)
      [[ "$value" =~ ^[a-z]+-[a-z]+[0-9]+$ ]] || { err "Invalid GCP region '${value}' (e.g. europe-west6)."; return 1; } ;;
    GCP_ZONE|PROVIDER_LOCATION)
      [[ "$value" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]] || { err "Invalid GCP zone '${value}' (e.g. europe-west6-b)."; return 1; } ;;
    GCP_NETWORK|GCP_SUBNET|PROVIDER_NETWORK|PROVIDER_SUBNET)
      [[ "$value" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || { err "Invalid GCP network or subnet name '${value}'."; return 1; } ;;
    *) err "Unknown GCP parameter '${key}'."; return 1 ;;
  esac
}

# SSH keep-alive: a probe every 15 s, give up after 8 missed replies (2 min).
# Long remote steps (stanctl up, kubectl wait) produce no traffic for minutes
# and an idle connection is otherwise dropped by NAT or the node's sshd.
GCP_SSH_KEEPALIVE_FLAGS=(
  --ssh-flag="-o StrictHostKeyChecking=accept-new"
  --ssh-flag="-o ConnectTimeout=30"
  --ssh-flag="-o ServerAliveInterval=15"
  --ssh-flag="-o ServerAliveCountMax=8"
  --ssh-flag="-o TCPKeepAlive=yes"
)
# prov_gcp_ssh VM ZONE PROJECT COMMAND — one SSH session; exit 255 means the
# connection failed (ssh_with_retry retries only that).
prov_gcp_ssh() {
  gcloud compute ssh "$1" \
    --project="$3" \
    --zone="$2" \
    --command="$4" \
    "${GCP_SSH_KEEPALIVE_FLAGS[@]}"
}

# prov_gcp_ssh_probe VM ZONE PROJECT TIMEOUT_S CONNECT_TIMEOUT_S COMMAND —
# non-interactive single attempt for wait loops; never prompts, never retries.
prov_gcp_ssh_probe() {
  timeout "${4}s" gcloud compute ssh "$1" \
    --project="$3" \
    --zone="$2" \
    --quiet --command="$6" \
    --ssh-flag="-o StrictHostKeyChecking=accept-new" \
    --ssh-flag="-o BatchMode=yes" \
    --ssh-flag="-o ConnectTimeout=${5}"
}

# prov_gcp_scp LOCAL_FILE VM ZONE PROJECT REMOTE_PATH
prov_gcp_scp() {
  gcloud compute scp "$1" "${2}:${5}" --project="$4" --zone="$3" --quiet
}

# prov_gcp_get_ip VM ZONE PROJECT public|private
prov_gcp_get_ip() {
  local field='networkInterfaces[0].networkIP'
  [[ "$4" == private ]] || field='networkInterfaces[0].accessConfigs[0].natIP'
  gcloud compute instances describe "$1" --project="$3" --zone="$2" --format="value(${field})"
}

# prov_gcp_hint KIND VM ZONE PROJECT [COMMAND] — text for HOW TO RESOLVE boxes.
#   ssh           command line to open a shell (or run COMMAND) on the VM
#   cpu_platform  step that moves the VM to a CPU with x86-64-v3
#   x86_machine   step for a VM that is not x86_64 at all
prov_gcp_hint() {
  local kind="$1" vm="$2" zone="$3" project="$4" cmd="${5:-}"
  case "$kind" in
    ssh)
      if [[ -n "$cmd" ]]; then
        printf '%s\n' "gcloud compute ssh ${vm} --zone=${zone} --project=${project} --command='${cmd}'"
      else
        printf '%s\n' "gcloud compute ssh ${vm} --zone=${zone} --project=${project}"
      fi ;;
    cpu_platform)
      printf '%s\n' "Use an n2-standard machine type (Cascade Lake or newer), or stop the VM and set a minimum CPU platform:|gcloud compute instances stop ${vm} --zone=${zone} --project=${project} && gcloud compute instances set-min-cpu-platform ${vm} --min-cpu-platform='Intel Cascade Lake' --zone=${zone} --project=${project} && gcloud compute instances start ${vm} --zone=${zone} --project=${project}" ;;
    x86_machine)
      printf '%s\n' "Recreate the VM with an x86_64 machine type (n2-standard family is verified).|./install.sh" ;;
  esac
}

# prov_gcp_disk_device_path NODE DEVICE — where an attached data disk appears on
# the VM: GCP exposes the --device-name given at attach time under by-id.
prov_gcp_disk_device_path() { printf '%s\n' "/dev/disk/by-id/google-$2"; }

prov_gcp_validate_image() {
  gcloud compute images describe-from-family "$UBUNTU_VERSION" \
    --project=ubuntu-os-cloud >/dev/null || die "Ubuntu image family unavailable."
}

# Project, region, zone, VPC network and subnet questions of collect_parameters.
prov_gcp_collect_location_params() {
  hint "The Google Cloud project that will own and pay for the VM(s). It is the project ID (lowercase, e.g. instana-support-test-account)," \
       "not the display name. Enter accepts the default; 'gcloud projects list' shows the projects your account can use."
  prompt_required "GCP_PROJECT" "GCP Project ID" "$(default_gcp_project)" validate_gcp_project_id
  # Default region/zone: where this machine runs when it is itself a GCE VM
  # (metadata server), so the deployment lands close to it. That matters most
  # for air-gapped installs, where the ~30 GB package is copied to the VM.
  local local_zone local_region
  local_zone=$(detect_local_gce_zone)
  if [[ -n "$local_zone" ]]; then
    local_region="${local_zone%-*}"
    log "This machine is a GCE VM in zone ${local_zone}; offering region ${local_region} as the default (fastest transfer to the Instana VM)."
  else
    local_region="us-central1"
  fi
  hint "Region = geographic area (e.g. europe-west6 = Zurich, us-central1 = Iowa); zone = a data center inside it (suffix -a/-b/-c)." \
       "Keep the defaults unless you need another location."
  prompt_required "GCP_REGION" "GCP Region" "$local_region"
  if [[ -n "$local_zone" && "$GCP_REGION" == "$local_region" ]]; then
    prompt_required "GCP_ZONE" "GCP Zone" "$local_zone"
  else
    prompt_required "GCP_ZONE" "GCP Zone" "${GCP_REGION}-a"
  fi
  if [[ -n "$local_zone" && "$GCP_REGION" != "$local_region" && "$INSTALL_MODE" == "air-gapped" ]]; then
    warn "Air-gapped: the package (tens of GB) will be copied from ${local_region} to ${GCP_REGION}; a cross-region copy is several times slower than staying in ${local_region}."
    prompt_yes_no "Keep region ${GCP_REGION} anyway?" N || { prompt_required "GCP_REGION" "GCP Region" "$local_region"; prompt_required "GCP_ZONE" "GCP Zone" "$([[ "$GCP_REGION" == "$local_region" ]] && echo "$local_zone" || echo "${GCP_REGION}-a")"; }
  fi
  hint "VPC network and subnet the VM(s) attach to. Every project has one called 'default'; keep it unless your admin gave you another."
  prompt_required "GCP_NETWORK" "VPC Network name" "default"
  prompt_required "GCP_SUBNET" "Subnet name" "default"
}

check_gcp_login() {
  log "Checking GCP authentication..."
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q "@"; then
    die "No active GCP account found. Run: gcloud auth login"
  fi
  ok "GCP authentication active: $(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
}

check_gcp_configuration() {
  log "Validating GCP project, zone, network, and subnet..."
  gcloud projects describe "$GCP_PROJECT" >/dev/null 2>&1 || die "Cannot access GCP project: ${GCP_PROJECT}"
  gcloud compute zones describe "$GCP_ZONE" --project="$GCP_PROJECT" >/dev/null 2>&1 || die "Zone not found or unavailable: ${GCP_ZONE}"
  gcloud compute networks describe "$GCP_NETWORK" --project="$GCP_PROJECT" >/dev/null 2>&1 || die "VPC network not found: ${GCP_NETWORK}"
  gcloud compute networks subnets describe "$GCP_SUBNET" --region="$GCP_REGION" --project="$GCP_PROJECT" >/dev/null 2>&1 || die "Subnet '${GCP_SUBNET}' not found in ${GCP_REGION}."
  ok "GCP configuration is accessible."
}

validate_gcp_project_id() {
  # https://cloud.google.com/resource-manager/docs/creating-managing-projects: 6-30 chars,
  # lowercase letters, digits, hyphens; starts with a letter; no trailing hyphen.
  local id="$1"
  [[ "$id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    { err "Invalid GCP Project ID '${id}': 6-30 lowercase letters, digits or hyphens, starting with a letter."; return 1; }
}

# Default project: the active gcloud project; otherwise the lab project this
# installer is normally used with (adjust here if you use another one).
readonly FALLBACK_GCP_PROJECT="instana-support-test-account"
default_gcp_project() {
  local p
  p=$(gcloud config get-value project 2>/dev/null || true)
  [[ -n "$p" && "$p" != "(unset)" ]] && printf '%s\n' "$p" || printf '%s\n' "$FALLBACK_GCP_PROJECT"
}

# Zone of this machine when it runs on Google Compute Engine, e.g. europe-west6-b;
# empty elsewhere. The metadata server answers only from inside GCE.
detect_local_gce_zone() {
  local raw
  raw=$(curl -fsS --max-time 2 -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/zone 2>/dev/null) || return 0
  raw="${raw##*/}"
  [[ "$raw" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]] && printf '%s\n' "$raw"
  return 0
}

gcp_machine_type_for() {
  local cpus="$1" ram_gb="$2"
  # Use n2-standard series as it provides guaranteed performance (IOPS requirement from docs: 3000)
  # n2-standard machines come in specific sizes; pick the smallest that fits
  if   (( cpus <= 2  && ram_gb <= 8   )); then echo "n2-standard-2"
  elif (( cpus <= 4  && ram_gb <= 16  )); then echo "n2-standard-4"
  elif (( cpus <= 8  && ram_gb <= 32  )); then echo "n2-standard-8"
  elif (( cpus <= 16 && ram_gb <= 64  )); then echo "n2-standard-16"
  elif (( cpus <= 32 && ram_gb <= 128 )); then echo "n2-standard-32"
  elif (( cpus <= 48 && ram_gb <= 192 )); then echo "n2-standard-48"
  elif (( cpus <= 64 && ram_gb <= 256 )); then echo "n2-standard-64"
  else echo "n2-standard-96"
  fi
}
