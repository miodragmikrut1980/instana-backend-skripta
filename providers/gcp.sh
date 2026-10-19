#!/usr/bin/env bash
# GCP provider (gcloud). The GCP_* parameters are the source of truth here.

prov_gcp_label() { echo "GCP"; }
prov_gcp_required_tools() { echo "gcloud"; }
prov_gcp_check_auth() { check_gcp_login; }
prov_gcp_default_scope() { default_gcp_project; }
prov_gcp_param_keys() { echo "GCP_PROJECT GCP_REGION GCP_ZONE GCP_NETWORK GCP_SUBNET"; }
prov_gcp_validate_config() { check_gcp_configuration; }
prov_gcp_machine_type_for() { gcp_machine_type_for "$@"; }

# ── Generic hooks: GCP keeps the installer's original wording ────────────────
prov_gcp_uses_param() { return 0; }
prov_gcp_text() { :; }
prov_gcp_phase_text() { :; }
prov_gcp_ssh_port() { echo 22; }
prov_gcp_saved_param_keys() { :; }
prov_gcp_check_saved_params() { :; }
# New pd-ssd disks are zero-filled by GCP; no extra check before formatting.
prov_gcp_check_blank_disk() { :; }
prov_gcp_collect_host_params() { :; }
prov_gcp_confirm_host_changes() { :; }
prov_gcp_state_resource_pattern() { echo '^(vm_|disk_|firewall_|fw_)'; }

# Plan lines after the Ubuntu version: where the VMs are created.
prov_gcp_plan_target_lines() {
  printf "  %-30s %s\n" "GCP Project:"       "$GCP_PROJECT"
  printf "  %-30s %s\n" "Zone:"              "$GCP_ZONE"
  printf "  %-30s %s\n" "Network / subnet:"  "${GCP_NETWORK:-default} / ${GCP_SUBNET:-default}"
}

# plan_key_lines head|change — the top of the plan: where and which VM(s);
# then what is created (and that it costs money until it is removed).
prov_gcp_plan_key_lines() {
  local gb
  if [[ "$1" == head ]]; then
    plan_fact "Where" "${GCP_PROJECT} / ${GCP_ZONE}"
    if [[ "$TOPOLOGY" == three-node ]]; then
      plan_fact "VMs" "${NODE0_NAME}, ${NODE1_NAME}, ${NODE2_NAME}" "3 × n2-standard-16, ${UBUNTU_VERSION:-ubuntu}"
    else
      plan_fact "VM" "$VM_NAME" "${MACHINE_TYPE:-?}, ${UBUNTU_VERSION:-ubuntu}"
    fi
    return 0
  fi
  if [[ "$TOPOLOGY" == three-node ]]; then
    plan_warn "Creates: 3 VMs + 4 disks (3700 GB pd-ssd) + firewall rules — billed until removed (./install.sh → Clean up a lab)"
  else
    if [[ "$INSTALL_TYPE" == production ]]; then gb=3700; else gb=1200; fi
    plan_warn "Creates: 1 VM + 4 disks (${gb} GB pd-ssd), firewall rules if missing — billed until removed (./install.sh → Clean up a lab)"
  fi
}

# Plan block: the VM(s) and the data disks that will be created.
prov_gcp_plan_resource_lines() {
  if [[ "$TOPOLOGY" == three-node ]]; then
    printf "  %-30s %s\n" "Machine type:"      "n2-standard-16 on each node (three-node lab, fixed)"
  else
    printf "  %-30s %s\n" "Machine type:"      "$MACHINE_TYPE"
  fi
  if [[ "$TOPOLOGY" == "single-node" ]]; then
    printf "  %-30s %s\n" "VM name:" "$VM_NAME"
    echo ""
    echo "  Disks to create (dedicated per directory, as required by documentation):"
    case "$INSTALL_TYPE" in
      demo)
        echo "    ${VM_NAME}-analytics  : 500 GB SSD  (pd-ssd)"
        echo "    ${VM_NAME}-metrics    : 300 GB SSD  (pd-ssd)"
        echo "    ${VM_NAME}-objects    : 250 GB SSD  (pd-ssd)"
        echo "    ${VM_NAME}-data       : 150 GB SSD  (pd-ssd)"
        ;;
      production)
        echo "    ${VM_NAME}-analytics  : 1200 GB SSD (pd-ssd)"
        echo "    ${VM_NAME}-metrics    : 1000 GB SSD (pd-ssd)"
        echo "    ${VM_NAME}-objects    : 1000 GB SSD (pd-ssd)"
        echo "    ${VM_NAME}-data       :  500 GB SSD (pd-ssd)"
        ;;
    esac
    case "$INSTALL_TYPE" in
      demo) echo "  IBM minimum (demo): 16 vCPUs / 64 GB RAM, disk IOPS ≥ 1000, throughput ≥ 125 MiB/s (table: E → SIZE)." ;;
      production) echo "  IBM minimum (production): 28 vCPUs / 112 GB RAM, disk IOPS ≥ 3000, throughput ≥ 250 MiB/s (table: E → SIZE)." ;;
    esac
  else
    echo ""
    printf "  %-30s %s\n" "Node 0 (backend):"   "$NODE0_NAME"
    printf "  %-30s %s\n" "Node 1 (data store):" "$NODE1_NAME"
    printf "  %-30s %s\n" "Node 2 (other):"      "$NODE2_NAME"
    echo ""
    echo "  Disks to create:"
    echo "    ${NODE0_NAME}-objects   : 1000 GB SSD (pd-ssd)  → /mnt/instana/stanctl/objects"
    echo "    ${NODE1_NAME}-data      :  500 GB SSD (pd-ssd)  → /mnt/instana/stanctl/data"
    echo "    ${NODE1_NAME}-metrics   : 1000 GB SSD (pd-ssd)  → /mnt/instana/stanctl/metrics"
    echo "    ${NODE1_NAME}-analytics : 1200 GB SSD (pd-ssd)  → /mnt/instana/stanctl/analytics"
    if [[ "$INSTALL_MODE" == air-gapped ]]; then
      echo ""
      echo "  Note: the nodes still use the internet for Ubuntu packages (apt-get in phase 6);"
      echo "  only the Instana artifacts come from the air-gapped package."
    fi
  fi
}

# After "Start now?": where this deployment lives (destroy.sh reads it back).
prov_gcp_record_target() {
  save_state "gcp_project" "$GCP_PROJECT"
  save_state "gcp_zone" "$GCP_ZONE"
}

# Single-node --resume: same project, zone and recorded VM as the state file.
prov_gcp_resume_state_matches() {
  [[ "$(get_state gcp_project)" == "$GCP_PROJECT" && "$(get_state gcp_zone)" == "$GCP_ZONE" && "$(get_state "vm_${VM_NAME}")" == created ]]
}

# Three-node lab: firewall tag, boot size and the lab notice.
prov_gcp_prepare_multi() {
  DEPLOYMENT_TAG="lab-${NODE0_NAME:0:45}"
  BOOT_SIZE_GB=270
  warn "INTERNAL LAB: 3 x n2-standard-16 (16 CPU/64 GB), 270 GB boot per node, 4 dedicated pd-ssd data disks. Physical isolation and sustained I/O are not certified."
}

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

# prov_gcp_ssh_probe VM ZONE PROJECT TIMEOUT_S CONNECT_TIMEOUT_S COMMAND [KIND] —
# non-interactive single attempt for wait loops; never prompts, never retries.
# KIND "first" (default) waits for a new VM and accepts its host key once;
# "reboot" polls a VM whose host key is already known.
prov_gcp_ssh_probe() {
  if [[ "${7:-first}" == reboot ]]; then
    timeout "${4}s" gcloud compute ssh "$1" --quiet --project="$3" --zone="$2" \
      --command="$6" --ssh-flag='-o BatchMode=yes' --ssh-flag="-o ConnectTimeout=${5}"
    return
  fi
  timeout "${4}s" gcloud compute ssh "$1" \
    --project="$3" \
    --zone="$2" \
    --quiet --command="$6" \
    --ssh-flag="-o StrictHostKeyChecking=accept-new" \
    --ssh-flag="-o BatchMode=yes" \
    --ssh-flag="-o ConnectTimeout=${5}"
}

# prov_gcp_scp LOCAL_FILE VM ZONE PROJECT REMOTE_PATH [KIND] — KIND "file"
# (default) for small files, "bulk" for the air-gapped package.
prov_gcp_scp() {
  if [[ "${6:-file}" == bulk ]]; then
    gcloud compute scp "$1" "${2}:${5}" --project="$4" --zone="$3"
  else
    gcloud compute scp "$1" "${2}:${5}" --project="$4" --zone="$3" --quiet
  fi
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

# Project, zone (region follows), network, subnet and the SSH source CIDR.
# Typed answers: one "Use detected" block, confirmed with Enter or changed one
# by one. Values from a file (or the plan's E): only what is missing or being
# changed is asked, one question each.
prov_gcp_collect_location_params() {
  if [[ "$PARAMS_SOURCE" == import ]]; then local NAV_ON=0; gcp_location_per_key; else gcp_location_block; fi
}

# This VM's own GCP facts from the metadata server (empty outside Google Cloud).
gcp_local_meta() {
  curl -fsS --max-time 2 -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/$1" 2>/dev/null || true
}

# Network and subnet of this control machine, when the deployment goes into
# the same project and region (otherwise "default"): "network subnet".
gcp_detect_network() {
  local project="$1" region="$2" my_project my_zone net subnet
  my_project=$(gcp_local_meta project/project-id)
  my_zone=$(detect_local_gce_zone)
  [[ -n "$my_zone" && "$my_project" == "$project" && "${my_zone%-*}" == "$region" ]] || return 0
  net=$(gcp_local_meta instance/network-interfaces/0/network); net="${net##*/}"
  subnet=$(timeout 20 gcloud compute instances describe "$(hostname -s 2>/dev/null)" --zone="$my_zone" --project="$project" \
    --format='value(networkInterfaces[0].subnetwork.basename())' 2>/dev/null || true)
  [[ "$net" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ && "$subnet" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ ]] && echo "$net $subnet"
  return 0
}

# Saved value (editing saved parameters) for KEY, or empty.
gcp_saved() {
  [[ "${CONFIG_LOADED:-false}" == true && -f "${CONFIG_FILE:-}" ]] || return 0
  jq -r --arg k "$1" '.parameters[$k] // empty' "$CONFIG_FILE" 2>/dev/null || true
}

readonly GCP_CIDR_UNSAFE="detection failed — 0.0.0.0/0 allows SSH from the whole internet"
# Where each value of the block came from; kept across "<" and forward again,
# so a placeholder (GCP_CIDR_UNSAFE) is never relabelled "your answer".
GCP_SRC_PROJECT="" GCP_SRC_ZONE="" GCP_SRC_NET="" GCP_SRC_CIDR=""

# After another project or zone: a detected, default or saved network is
# worked out again (it belonged to the old project/region); a typed one is kept.
gcp_redetect_network() {
  [[ "$GCP_SRC_NET" != "your answer" ]] || return 0
  local detected
  detected=$(gcp_detect_network "$GCP_PROJECT" "$GCP_REGION")
  if [[ -n "$detected" ]]; then read -r GCP_NETWORK GCP_SUBNET <<< "$detected"; GCP_SRC_NET="this machine's network"
  else GCP_NETWORK=default; GCP_SUBNET=default; GCP_SRC_NET="every project has 'default'"; fi
}

gcp_location_block() {
  local local_zone answer which detected rc
  local_zone=$(detect_local_gce_zone)
  if [[ -z "${GCP_PROJECT:-}" ]]; then
    GCP_PROJECT=$(gcp_saved GCP_PROJECT); GCP_SRC_PROJECT="saved"
    [[ -n "$GCP_PROJECT" ]] || { GCP_PROJECT=$(default_gcp_project); GCP_SRC_PROJECT="gcloud config, else the lab default"; }
  else GCP_SRC_PROJECT="${GCP_SRC_PROJECT:-your answer}"; fi
  if [[ -z "${GCP_ZONE:-}" ]]; then
    GCP_ZONE=$(gcp_saved GCP_ZONE); GCP_SRC_ZONE="saved"
    if [[ -z "$GCP_ZONE" && -n "$local_zone" ]]; then GCP_ZONE="$local_zone"; GCP_SRC_ZONE="this machine's zone"; fi
    [[ -n "$GCP_ZONE" ]] || { GCP_ZONE=us-central1-a; GCP_SRC_ZONE="default"; }
  else GCP_SRC_ZONE="${GCP_SRC_ZONE:-your answer}"; fi
  GCP_REGION="${GCP_ZONE%-*}"
  if [[ -z "${GCP_NETWORK:-}" || -z "${GCP_SUBNET:-}" ]]; then
    GCP_NETWORK=$(gcp_saved GCP_NETWORK); GCP_SUBNET=$(gcp_saved GCP_SUBNET); GCP_SRC_NET="saved"
    if [[ -z "$GCP_NETWORK" || -z "$GCP_SUBNET" ]]; then
      detected=$(gcp_detect_network "$GCP_PROJECT" "$GCP_REGION")
      if [[ -n "$detected" ]]; then read -r GCP_NETWORK GCP_SUBNET <<< "$detected"; GCP_SRC_NET="this machine's network"
      else GCP_NETWORK=default; GCP_SUBNET=default; GCP_SRC_NET="every project has 'default'"; fi
    fi
  else GCP_SRC_NET="${GCP_SRC_NET:-your answer}"; fi
  if [[ -z "${SSH_SOURCE_CIDR:-}" ]]; then
    SSH_SOURCE_CIDR=$(gcp_saved SSH_SOURCE_CIDR); GCP_SRC_CIDR="saved"
    if [[ -z "$SSH_SOURCE_CIDR" ]]; then
      SSH_SOURCE_CIDR=$(detect_public_cidr); GCP_SRC_CIDR="this machine's public IP"
      # Detection failed: 0.0.0.0/0 is only a placeholder, never accepted with Enter.
      [[ "$SSH_SOURCE_CIDR" != 0.0.0.0/0 ]] || GCP_SRC_CIDR="$GCP_CIDR_UNSAFE"
    fi
  else GCP_SRC_CIDR="${GCP_SRC_CIDR:-your answer}"; fi
  NAV_ASKED=1
  while true; do
    echo "" >&2
    hint "Where the VM(s) are created, detected from this machine and gcloud." \
         "Enter accepts all four values, c changes one of them." \
         "SSH from = the public IP that may open SSH to the VM(s); /32 = only this one address."
    {
      gcp_detected_row "Project" "$GCP_PROJECT" "$GCP_SRC_PROJECT"
      gcp_detected_row "Zone" "$GCP_ZONE" "${GCP_SRC_ZONE}; region ${GCP_REGION}"
      gcp_detected_row "Network" "${GCP_NETWORK} / ${GCP_SUBNET}" "${GCP_SRC_NET}; network / subnet"
      if [[ "$GCP_SRC_CIDR" == "$GCP_CIDR_UNSAFE" ]]; then
        printf '    %-9s %b\n' "SSH from" "${YELLOW}${GCP_CIDR_UNSAFE}${RESET}"
        printf '    %-9s %b\n' "" "${DIM}press c to enter your IP (curl ifconfig.me shows it)${RESET}"
      else
        gcp_detected_row "SSH from" "$SSH_SOURCE_CIDR" "$GCP_SRC_CIDR"
      fi
    } >&2
    if [[ -n "$local_zone" && "${local_zone%-*}" != "$GCP_REGION" && "${INSTALL_MODE:-}" == air-gapped ]]; then
      warn "Air-gapped: the package (tens of GB) is copied from ${local_zone%-*} to ${GCP_REGION}; a cross-region copy is several times slower."
    fi
    rc=0; read_answer answer "$(echo -e "${CYAN}?${RESET} ${BOLD}Use these? [Enter = yes, c = change one]${RESET} $(back_label): ")" 1 || rc=$?
    (( rc != 1 )) || die "Input ended before the parameters were complete; installation cancelled. Nothing was created."
    (( rc != 3 )) || answer="<"
    case "$answer" in
      "<") NAV_BACK=1; return 0 ;;
      "")
        if [[ "$GCP_SRC_CIDR" == "$GCP_CIDR_UNSAFE" ]]; then
          warn "SSH from: this machine's public IP could not be detected, and 0.0.0.0/0 would open SSH to the whole internet."
          hint "Press c, choose 'SSH from (CIDR)' and type your public IP with /32 (curl ifconfig.me shows it)." \
               "Or type 0.0.0.0/0 there yourself if SSH from anywhere is really intended."
          continue
        fi
        prov_gcp_validate_param GCP_PROJECT "$GCP_PROJECT" && prov_gcp_validate_param GCP_ZONE "$GCP_ZONE" &&
          prov_gcp_validate_param GCP_NETWORK "$GCP_NETWORK" && prov_gcp_validate_param GCP_SUBNET "$GCP_SUBNET" &&
          validate_cidr "$SSH_SOURCE_CIDR" && return 0
        warn "One of the values above cannot be used (reason above); change it with c." ;;
      c|C)
        which=$(NAV_CHOICE_BACK=1 prompt_choice "Which value do you want to change?" "Project" "Zone" "Network and subnet" "SSH from (CIDR)") || which=""
        NAV_BACK=0
        case "$which" in
          Project)
            hint "Project ID (lowercase), not the display name." \
                 "'gcloud projects list' shows the projects your account can use."
            prompt_required GCP_PROJECT "GCP Project ID" "$GCP_PROJECT" validate_gcp_project_id
            (( NAV_BACK )) || { GCP_SRC_PROJECT="your answer"; gcp_redetect_network; } ;;
          Zone)
            hint "Zone = a data center, e.g. europe-west6-b (Zurich) or us-central1-a (Iowa)." "The region follows from the zone."
            prompt_required GCP_ZONE "GCP Zone" "$GCP_ZONE" validate_gcp_zone
            (( NAV_BACK )) || { GCP_SRC_ZONE="your answer"; GCP_REGION="${GCP_ZONE%-*}"; gcp_redetect_network; }
            ;;
          "Network and subnet")
            hint "VPC network and subnet the VM(s) attach to; the subnet must be in region ${GCP_REGION}."
            prompt_required GCP_NETWORK "VPC Network name" "$GCP_NETWORK" validate_gcp_network_name
            (( NAV_BACK )) || prompt_required GCP_SUBNET "Subnet name" "$GCP_SUBNET" validate_gcp_network_name
            (( NAV_BACK )) || GCP_SRC_NET="your answer" ;;
          "SSH from (CIDR)")
            hint "Public IP that may open SSH to the VM(s), e.g. 203.0.113.10/32." "0.0.0.0/0 would allow the whole internet."
            prompt_required SSH_SOURCE_CIDR "CIDR allowed to SSH to the VM(s)" "$SSH_SOURCE_CIDR" validate_cidr
            (( NAV_BACK )) || GCP_SRC_CIDR="your answer" ;;
        esac
        NAV_BACK=0 ;;
      *) echo "  Please press Enter to use these values, c to change one, or go back (left arrow, or < and Enter)." >&2 ;;
    esac
  done
}

# gcp_detected_row NAME VALUE SOURCE — one line of the "detected" block: the
# value stands out, where it came from is dimmed.
gcp_detected_row() {
  local v; printf -v v '%-32s' "$2"
  printf '    %-9s %b %b\n' "$1" "${BOLD}${v}${RESET}" "${DIM}(${3})${RESET}"
}

gcp_location_per_key() {
  use_imported GCP_PROJECT || {
    hint "The project that owns and pays for the VM(s): its ID, e.g. instana-support-test-account." \
         "Not the display name. Enter accepts the default; 'gcloud projects list' shows the projects your account can use."
    prompt_required "GCP_PROJECT" "GCP Project ID" "$(default_gcp_project)" validate_gcp_project_id
  }
  if use_imported GCP_REGION; then
    use_imported GCP_ZONE || prompt_required "GCP_ZONE" "GCP Zone" "${GCP_REGION}-a" validate_gcp_zone_in_region
  else
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
    hint "Region = area (europe-west6 = Zurich), zone = a data center in it (-a/-b/-c)." \
         "Keep the defaults unless you need another location."
    prompt_required "GCP_REGION" "GCP Region" "$local_region" validate_gcp_region
    if use_imported GCP_ZONE; then :
    elif [[ -n "$local_zone" && "$GCP_REGION" == "$local_region" ]]; then
      prompt_required "GCP_ZONE" "GCP Zone" "$local_zone" validate_gcp_zone_in_region
    else
      prompt_required "GCP_ZONE" "GCP Zone" "${GCP_REGION}-a" validate_gcp_zone_in_region
    fi
    if [[ -n "$local_zone" && "$GCP_REGION" != "$local_region" && "$INSTALL_MODE" == "air-gapped" ]]; then
      warn "Air-gapped: the package (tens of GB) will be copied from ${local_region} to ${GCP_REGION}; a cross-region copy is several times slower than staying in ${local_region}."
      prompt_yes_no "Keep region ${GCP_REGION} anyway?" N || { prompt_required "GCP_REGION" "GCP Region" "$local_region" validate_gcp_region; prompt_required "GCP_ZONE" "GCP Zone" "$([[ "$GCP_REGION" == "$local_region" ]] && echo "$local_zone" || echo "${GCP_REGION}-a")" validate_gcp_zone_in_region; }
    fi
  fi
  imported_usable GCP_NETWORK GCP_SUBNET ||
    hint "VPC network and subnet of the VM(s); keep 'default' unless your admin gave you another."
  use_imported GCP_NETWORK || prompt_required "GCP_NETWORK" "VPC Network name" "default" validate_gcp_network_name
  use_imported GCP_SUBNET || prompt_required "GCP_SUBNET" "Subnet name" "default" validate_gcp_network_name
}

# prompt_required validators (VALUE [LABEL]) for the location answers.
validate_gcp_region() { prov_gcp_validate_param GCP_REGION "$1"; }
validate_gcp_zone() { prov_gcp_validate_param GCP_ZONE "$1"; }
validate_gcp_network_name() { prov_gcp_validate_param GCP_NETWORK "$1"; }
validate_gcp_zone_in_region() {
  prov_gcp_validate_param GCP_ZONE "$1" || return 1
  [[ -z "${GCP_REGION:-}" || "$1" == "${GCP_REGION}-"? ]] ||
    { err "Zone '${1}' is not in region '${GCP_REGION}' (a zone is its region plus -a, -b or -c, e.g. ${GCP_REGION}-b)."; return 1; }
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

# ── Infrastructure: phases 3-5 ────────────────────────────────────────────────
# Single-node: shared instana-allow-* rules; three-node: per-deployment
# lab-<node0>-* rules, labels and resume verification (multinode-resume.sh).

# prov_gcp_ensure_vms — phase 3: quota, name collisions, create or verify the VM(s).
prov_gcp_ensure_vms() {
  local node
  if [[ "$TOPOLOGY" == three-node ]]; then
    check_gcp_quota "$GCP_PROJECT" "$GCP_ZONE" 48
    [[ "$RESUME" == true ]] || check_duplicate_vms "$GCP_PROJECT" "$GCP_ZONE" "$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME"
    for node in "$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME"; do
      phase_detail active "Ensuring VM ${node} exists with the expected image and machine type."
      resume_create_vm "$node" n2-standard-16 "$GCP_ZONE" "$GCP_PROJECT" "$GCP_NETWORK" "$GCP_SUBNET" "$UBUNTU_VERSION"
    done
    return
  fi
  check_gcp_quota "$GCP_PROJECT" "$GCP_ZONE" "$VM_CPUS"

  # Create a missing VM, or verify the VM recorded by this installation.
  ensure_single_vm "$VM_NAME" "$MACHINE_TYPE" "$GCP_ZONE" "$GCP_PROJECT" \
    "$GCP_NETWORK" "$GCP_SUBNET" "$UBUNTU_VERSION"
}

# prov_gcp_ensure_disks — phase 4: create or verify and attach the data disks,
# attached with the device names that prov_gcp_disk_device_path resolves.
prov_gcp_ensure_disks() {
  if [[ "$TOPOLOGY" == three-node ]]; then
    resume_disk "$NODE0_NAME" "${NODE0_NAME}-objects" 1000 disk-objects
    resume_disk "$NODE1_NAME" "${NODE1_NAME}-data" 500 disk-data
    resume_disk "$NODE1_NAME" "${NODE1_NAME}-metrics" 1000 disk-metrics
    resume_disk "$NODE1_NAME" "${NODE1_NAME}-analytics" 1200 disk-analytics
    return
  fi
  case "$INSTALL_TYPE" in
    demo)
      create_and_attach_disk "$VM_NAME" "${VM_NAME}-analytics" 500  "$GCP_ZONE" "$GCP_PROJECT" "disk-analytics"
      create_and_attach_disk "$VM_NAME" "${VM_NAME}-metrics"   300  "$GCP_ZONE" "$GCP_PROJECT" "disk-metrics"
      create_and_attach_disk "$VM_NAME" "${VM_NAME}-objects"   250  "$GCP_ZONE" "$GCP_PROJECT" "disk-objects"
      create_and_attach_disk "$VM_NAME" "${VM_NAME}-data"      150  "$GCP_ZONE" "$GCP_PROJECT" "disk-data"
      ;;
    production)
      create_and_attach_disk "$VM_NAME" "${VM_NAME}-analytics" 1200 "$GCP_ZONE" "$GCP_PROJECT" "disk-analytics"
      create_and_attach_disk "$VM_NAME" "${VM_NAME}-metrics"   1000 "$GCP_ZONE" "$GCP_PROJECT" "disk-metrics"
      create_and_attach_disk "$VM_NAME" "${VM_NAME}-objects"   1000 "$GCP_ZONE" "$GCP_PROJECT" "disk-objects"
      create_and_attach_disk "$VM_NAME" "${VM_NAME}-data"      500  "$GCP_ZONE" "$GCP_PROJECT" "disk-data"
      ;;
  esac
}

# prov_gcp_ensure_firewall — phase 5: VPC ingress rules.
prov_gcp_ensure_firewall() {
  if [[ "$TOPOLOGY" == three-node ]]; then
    resume_firewalls
  else
    create_firewall_rules "$GCP_PROJECT" "$GCP_NETWORK"
  fi
}

# prov_gcp_preflight_multi — before the plan of a new three-node lab: its
# per-deployment firewall rule names must still be free.
prov_gcp_preflight_multi() {
  local suffix
  for suffix in ssh external internal pods; do
    if gcloud compute firewall-rules describe "${DEPLOYMENT_TAG}-${suffix}" --project="$GCP_PROJECT" >/dev/null 2>&1; then
      die "Firewall name already exists: ${DEPLOYMENT_TAG}-${suffix}"
    fi
  done
}

# prov_gcp_resume_check_vm VM — single-node --resume: the recorded VM must be
# RUNNING with the selected machine type.
prov_gcp_resume_check_vm() {
  local vm
  vm=$(gcloud compute instances describe "$1" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json)
  [[ "$(jq -r .status <<< "$vm")" == RUNNING ]] || die "Existing VM must be RUNNING."
  [[ "$(jq -r '.machineType | split("/")[-1]' <<< "$vm")" == "$MACHINE_TYPE" ]] || die "Machine type differs from your selection."
}

check_gcp_quota() {
  local project="$1" zone="$2" cpus="$3" region
  region="${zone%-*}"
  log "Checking GCP CPU quota in region ${region}..."
  local quota
  quota=$(gcloud compute regions describe "$region" \
    --project="$project" \
    --format="json" 2>/dev/null \
    | jq -r '.quotas[] | select(.metric=="CPUS") | .limit' 2>/dev/null || echo "0")
  if [[ "$quota" == "0" ]]; then
    warn "Could not read CPU quota. Proceeding — check manually if creation fails."
    return
  fi
  local used
  used=$(gcloud compute regions describe "$region" \
    --project="$project" \
    --format="json" 2>/dev/null \
    | jq -r '.quotas[] | select(.metric=="CPUS") | .usage' 2>/dev/null || echo "0")
  local available
  available=$(jq -n --argjson limit "$quota" --argjson usage "$used" '$limit-$usage' 2>/dev/null || echo "unknown")
  log "CPU quota in ${region}: limit=${quota}, used=${used}, available=${available}"
  if [[ "$available" != "unknown" ]] && [[ "$(jq -n --argjson a "$available" --argjson c "$cpus" '$a<$c')" == true ]]; then
    die "Insufficient CPU quota. Need ${cpus} vCPUs, but only ${available} available in ${region}."
  fi
  ok "CPU quota sufficient."
}

check_duplicate_vms() {
  local project="$1" zone="$2"; shift 2
  local names=("$@")
  log "Checking for existing VMs..."
  for name in "${names[@]}"; do
    if gcloud compute instances describe "$name" \
      --project="$project" --zone="$zone" &>/dev/null 2>&1; then
      die "VM '${name}' already exists in zone ${zone}. Delete it first or use destroy.sh."
    fi
  done
  ok "No duplicate VMs found."
}

create_vm_once() {
  local name="$1" machine_type="$2" zone="$3" project="$4" network="$5" subnet="$6" ubuntu="$7"
  log "Creating VM: ${name} (${machine_type}, zone: ${zone})..."
  local metadata_args=()
  local label_args=()
  [[ "$TOPOLOGY" == three-node ]] && metadata_args=(--metadata=enable-oslogin=false)
  [[ -z "${DEPLOYMENT_ID:-}" ]] || label_args=("--labels=instana-lab-id=$DEPLOYMENT_ID")
  run gcloud compute instances create "$name" \
    --project="$project" \
    --zone="$zone" \
    --machine-type="$machine_type" \
    --image-family="$ubuntu" \
    --image-project="ubuntu-os-cloud" \
    --boot-disk-size="${BOOT_SIZE_GB:-100}GB" \
    --boot-disk-type="pd-ssd" \
    --network="$network" \
    --subnet="$subnet" \
    --tags="${DEPLOYMENT_TAG:-instana-backend}" "${metadata_args[@]}" "${label_args[@]}"
  save_state "vm_${name}" "created"
  ok "VM ${name} created."
}

create_and_attach_disk() {
  local vm_name="$1" disk_name="$2" size_gb="$3" zone="$4" project="$5" device_name="$6"
  local info vm attached users recorded inspect_error disk_exists=false adoption_required=false
  if [[ "$DRY_RUN" == true ]]; then
    log "Creating disk ${disk_name} (${size_gb} GB SSD; resume would verify/reuse it if present)..."
    run gcloud compute disks create "$disk_name" --project="$project" --zone="$zone" --size="${size_gb}GB" --type="pd-ssd"
    run gcloud compute instances attach-disk "$vm_name" --project="$project" --zone="$zone" --disk="$disk_name" --device-name="$device_name"
    return 0
  fi

  inspect_error=$(mktemp)
  if info=$(gcloud compute disks describe "$disk_name" --project="$project" --zone="$zone" --format=json 2>"$inspect_error"); then
    disk_exists=true
  elif grep -Eqi 'was not found|not found|could not fetch resource' "$inspect_error"; then
    disk_exists=false
  else
    rm -f "$inspect_error"
    die "Cannot inspect disk ${disk_name}; access or API failure. No resource was created or changed."
  fi
  rm -f "$inspect_error"

  if [[ "$disk_exists" != true ]]; then
    log "Creating disk ${disk_name} (${size_gb} GB SSD)..."
    run gcloud compute disks create "$disk_name" --project="$project" --zone="$zone" --size="${size_gb}GB" --type="pd-ssd"
    info=$(gcloud compute disks describe "$disk_name" --project="$project" --zone="$zone" --format=json) ||
      die "Disk ${disk_name} was created but cannot be verified; no attachment was attempted."
  else
    recorded=$(get_state "disk_${disk_name}")
    if [[ "$recorded" != created && "$recorded" != attached ]]; then
      warn "Disk '${disk_name}' exists but is not recorded in this installation state."
      adoption_required=true
    fi
    phase_detail warn "Existing disk ${disk_name} found; validating it instead of creating a duplicate."
  fi

  jq -e --argjson size "$size_gb" \
    '(.sizeGb|tonumber)==$size and (.type|endswith("/pd-ssd")) and .status=="READY"' \
    <<< "$info" >/dev/null ||
    die_with_steps "Disk ${disk_name} exists with an unexpected size, type, or state (expected ${size_gb} GB pd-ssd, READY). It was not adopted, attached, formatted, or deleted." \
      "Rerun with a DIFFERENT VM name (disk names derive from it):|./install.sh" \
      "*Or, after checking it holds nothing you need, delete the old disk and rerun:" \
      "*    gcloud compute disks delete ${disk_name} --zone=${GCP_ZONE} --project=${GCP_PROJECT}"
  users=$(jq -r '.users[]? // empty' <<< "$info")
  [[ -z "$users" || "$users" == */instances/"$vm_name" ]] || die_with_steps "Disk ${disk_name} is attached to a different VM (${users##*/}); no changes were made." \
      "Rerun with a DIFFERENT VM name so disk names do not collide:|./install.sh" \
      "*Or, if that disk belongs to an old lab, detach/delete it manually first:" \
      "*    gcloud compute disks delete ${disk_name} --zone=${GCP_ZONE} --project=${GCP_PROJECT}"

  if [[ "$adoption_required" == true ]]; then
    prompt_yes_no "Validated ${size_gb} GB READY pd-ssd disk with no foreign attachment. Adopt it only if it belongs to this interrupted deployment? It will never be automatically deleted or reformatted when non-blank." N ||
      die_with_steps "Existing disk ${disk_name} was not adopted; no changes were made." \
      "Rerun with a DIFFERENT VM name:|./install.sh" \
      "*Or delete the leftover disk if it belongs to an old lab, then rerun:" \
      "*    gcloud compute disks delete ${disk_name} --zone=${GCP_ZONE} --project=${GCP_PROJECT}"
  fi

  vm=$(gcloud compute instances describe "$vm_name" --project="$project" --zone="$zone" --format=json) || die "Cannot inspect VM ${vm_name}."
  attached=$(jq --arg disk "$disk_name" '[.disks[]|select(.source|endswith("/"+$disk))]' <<< "$vm")
  if [[ "$(jq length <<< "$attached")" == 0 ]]; then
    log "Attaching ${disk_name} to ${vm_name} as ${device_name}..."
    run gcloud compute instances attach-disk "$vm_name" --project="$project" --zone="$zone" --disk="$disk_name" --device-name="$device_name"
  fi
  vm=$(gcloud compute instances describe "$vm_name" --project="$project" --zone="$zone" --format=json) ||
    die "Cannot verify VM ${vm_name} after disk attachment attempt."
  attached=$(jq --arg disk "$disk_name" '[.disks[]|select(.source|endswith("/"+$disk))]' <<< "$vm")
  jq -e --arg device "$device_name" 'length==1 and .[0].deviceName==$device and .[0].boot==false' <<< "$attached" >/dev/null ||
    die "Disk ${disk_name} attachment is missing, duplicated, uses an unexpected device name, or is marked as a boot disk."
  phase_detail done "Attachment ${disk_name} → ${vm_name} (${device_name}) verified."
  save_state "disk_${disk_name}" "attached"
  ok "Disk ${disk_name} attached to ${vm_name}."
}

ensure_single_vm() {
  local name="$1" machine_type="$2" zone="$3" project="$4" network="$5" subnet="$6" ubuntu="$7" info recorded inspect_error vm_exists=false
  [[ "$DRY_RUN" != true ]] || { create_vm "$@"; return; }
  inspect_error=$(mktemp)
  if info=$(gcloud compute instances describe "$name" --project="$project" --zone="$zone" --format=json 2>"$inspect_error"); then
    vm_exists=true
  elif grep -Eqi 'was not found|not found|could not fetch resource' "$inspect_error"; then
    vm_exists=false
  else
    rm -f "$inspect_error"
    die "Cannot inspect VM ${name}; access or API failure. No replacement VM was created."
  fi
  rm -f "$inspect_error"
  if [[ "$vm_exists" != true ]]; then
    [[ -z "$(get_state "vm_${name}")" ]] || die_with_steps "VM ${name} is recorded in .install-state.json but no longer exists in GCP (it was deleted outside this installer). Automatic replacement is refused." \
      "See what is left of the old deployment (disks, firewall rules):|./install.sh --destroy --dry-run" \
      "Remove the leftovers and the stale state file:|./install.sh --destroy" \
      "Start a fresh deployment:|./install.sh" \
      "*Alternative, if you must keep the old disks: move the state file away and use a NEW VM name:" \
      "*    mv .install-state.json .install-state.json.old"
    create_vm "$@"
    return
  fi
  recorded=$(get_state "vm_${name}")
  [[ "$recorded" == created ]] || die_with_steps "VM '${name}' already exists in ${GCP_ZONE} but was not created by this installation (no record in .install-state.json). This installer never deletes or reuses a VM it did not create." \
      "Rerun and choose a DIFFERENT VM name for this deployment:|./install.sh" \
      "*Or, if that VM is an old lab you no longer need, delete it first and rerun:" \
      "*    gcloud compute instances delete ${name} --zone=${GCP_ZONE} --project=${GCP_PROJECT}"
  jq -e --arg machine "$machine_type" --arg network "$network" --arg subnet "$subnet" \
    '.status=="RUNNING" and (.machineType|endswith("/"+$machine)) and
     (.networkInterfaces[0].network|endswith("/"+$network)) and
     (.networkInterfaces[0].subnetwork|endswith("/"+$subnet))' <<< "$info" >/dev/null ||
    die_with_steps "Existing VM ${name} does not match the saved machine type, network, subnet, or RUNNING state." \
      "If the VM is only stopped, start it and resume:|gcloud compute instances start ${name} --zone=${GCP_ZONE} --project=${GCP_PROJECT} && ./install.sh --resume" \
      "If it was resized or moved, remove the whole deployment and start again:|./install.sh --destroy && ./install.sh"
  ok "Reuse verified VM: ${name}"
}

create_firewall_rules() {
  local project="$1" network="$2"
  log "Creating firewall rules (from documentation)..."

  # Keep SSH separate so it can be restricted to the operator's CIDR.
  if ! gcloud compute firewall-rules describe "instana-allow-ssh" \
      --project="$project" &>/dev/null 2>&1; then
    run gcloud compute firewall-rules create "instana-allow-ssh" \
      --project="$project" \
      --network="$network" \
      --allow="tcp:22" \
      --source-ranges="$SSH_SOURCE_CIDR" \
      --target-tags="instana-backend" \
      --description="Restricted SSH access for Instana administration"
    save_state "fw_ssh" "created"
  fi

  # Public Instana endpoints. Port 22 is deliberately excluded here.
  # From docs: Table 6 (single-node) / Table 10 (multi-node)
  if ! gcloud compute firewall-rules describe "instana-allow-external" \
      --project="$project" &>/dev/null 2>&1; then
    run gcloud compute firewall-rules create "instana-allow-external" \
      --project="$project" \
      --network="$network" \
      --allow="tcp:80,tcp:443,tcp:8443" \
      --target-tags="instana-backend" \
      --description="Instana external ports (doc: Table 6/10)"
    save_state "fw_external" "created"
  fi

  # K3s internal subnets — must have access to all ports (from docs)
  if ! gcloud compute firewall-rules describe "instana-allow-k3s-subnets" \
      --project="$project" &>/dev/null 2>&1; then
    run gcloud compute firewall-rules create "instana-allow-k3s-subnets" \
      --project="$project" \
      --network="$network" \
      --allow="tcp:0-65535,udp:0-65535,icmp" \
      --source-ranges="10.42.0.0/16,10.43.0.0/16" \
      --target-tags="instana-backend" \
      --description="Instana K3s pod/service subnets (doc: 10.42.0.0/16 and 10.43.0.0/16)"
    save_state "fw_k3s" "created"
  fi

  if [[ "$TOPOLOGY" == "three-node" ]]; then
    # Inter-node ports (from docs, Table 10):
    # TCP: 22,53,6443,10250,2379,2380,5001,9443
    # UDP: 53,8472
    if ! gcloud compute firewall-rules describe "instana-allow-internal" \
        --project="$project" &>/dev/null 2>&1; then
      run gcloud compute firewall-rules create "instana-allow-internal" \
        --project="$project" \
        --network="$network" \
        --allow="tcp:22,tcp:53,tcp:6443,tcp:10250,tcp:2379,tcp:2380,tcp:5001,tcp:9443,udp:53,udp:8472" \
        --target-tags="instana-backend" \
        --source-tags="instana-backend" \
        --description="Instana inter-node ports (doc: Table 10)"
      save_state "fw_internal" "created"
    fi
  fi

  ok "Firewall rules configured."
}

# ── Three-node lab resources (verified on --resume) ──────────────────────────
lab_firewalls() {
  local name rule suffix sources target
  for suffix in ssh external internal pods; do
    name="${DEPLOYMENT_TAG}-${suffix}"
    target="--target-tags=$DEPLOYMENT_TAG"
    case "$suffix" in
      ssh) rule=tcp:22; sources="--source-ranges=$SSH_SOURCE_CIDR";;
      external) rule=tcp:80,tcp:443,tcp:8443; sources=--source-ranges=0.0.0.0/0;;
      internal) rule=tcp,udp,icmp; sources="--source-tags=$DEPLOYMENT_TAG";;
      pods) rule=tcp,udp,icmp; sources=--source-ranges=10.42.0.0/16,10.43.0.0/16;;
    esac
    # The description carries the deployment identity that resume_firewalls
    # verifies; without it every later --resume would refuse these rules.
    run gcloud compute firewall-rules create "$name" --project="$GCP_PROJECT" \
      --network="$GCP_NETWORK" --allow="$rule" "$sources" "$target" --description="instana-lab-id=${DEPLOYMENT_ID:-}"
    save_state "firewall_${name}" created
  done
}

resume_create_vm() {
  local node="$1" info inspect_error vm_exists=false
  if [[ "$RESUME" != true ]]; then create_vm "$@"; return; fi
  inspect_error=$(mktemp)
  if info=$(gcloud compute instances describe "$node" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json 2>"$inspect_error"); then
    vm_exists=true
  elif grep -Eqi 'was not found|not found|could not fetch resource' "$inspect_error"; then
    vm_exists=false
  else
    rm -f "$inspect_error"
    die "Cannot inspect VM $node; access or API failure. No replacement was created."
  fi
  rm -f "$inspect_error"
  if [[ "$vm_exists" != true ]]; then
    [[ -z "$(get_state "vm_${node}")" ]] || die "Recorded VM disappeared: $node"
    create_vm "$@"; return
  fi
  jq -e --arg id "$DEPLOYMENT_ID" --arg subnet "$GCP_SUBNET" --arg network "$GCP_NETWORK" \
    '.labels["instana-lab-id"]==$id and .status=="RUNNING" and
    (.machineType|endswith("/n2-standard-16")) and
    (.networkInterfaces[0].network|endswith("/"+$network)) and
    (.networkInterfaces[0].subnetwork|endswith("/"+$subnet))' <<< "$info" >/dev/null || die "Existing VM mismatch/ownership/status: $node"
  save_state "vm_${node}" created
  ok "Reuse verified VM: $node"
}

resume_disk() {
  local node="$1" disk="$2" size="$3" device="$4" info vm attached inspect_error disk_exists=false
  if [[ "$DRY_RUN" == true ]]; then
    create_and_attach_disk "$node" "$disk" "$size" "$GCP_ZONE" "$GCP_PROJECT" "$device"; return
  fi
  inspect_error=$(mktemp)
  if info=$(gcloud compute disks describe "$disk" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json 2>"$inspect_error"); then
    disk_exists=true
  elif grep -Eqi 'was not found|not found|could not fetch resource' "$inspect_error"; then
    disk_exists=false
  else
    rm -f "$inspect_error"
    die "Cannot inspect disk $disk; access or API failure. No resource was created or changed."
  fi
  rm -f "$inspect_error"
  if [[ "$disk_exists" != true ]]; then
    [[ -z "$(get_state "disk_${disk}")" ]] || die "Recorded disk disappeared: $disk"
    run gcloud compute disks create "$disk" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --size="${size}GB" --type=pd-ssd --labels="instana-lab-id=$DEPLOYMENT_ID"
    info=$(gcloud compute disks describe "$disk" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json) || die "Created disk cannot be verified: $disk"
  fi
  jq -e --arg id "$DEPLOYMENT_ID" --argjson size "$size" --arg node "$node" \
    '.labels["instana-lab-id"]==$id and (.sizeGb|tonumber)==$size and (.type|endswith("/pd-ssd")) and .status=="READY" and
    all(.users[]?; endswith("/"+$node))' <<< "$info" >/dev/null || die "Disk ownership/size/type/attachment mismatch: $disk"
  vm=$(gcloud compute instances describe "$node" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json)
  attached=$(jq --arg disk "$disk" '[.disks[]|select(.source|endswith("/"+$disk))]' <<< "$vm")
  if [[ "$(jq length <<< "$attached")" == 0 ]]; then
    run gcloud compute instances attach-disk "$node" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --disk="$disk" --device-name="$device"
  fi
  vm=$(gcloud compute instances describe "$node" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json) || die "Cannot verify VM after disk attachment: $node"
  attached=$(jq --arg disk "$disk" '[.disks[]|select(.source|endswith("/"+$disk))]' <<< "$vm")
  jq -e --arg device "$device" 'length==1 and .[0].deviceName==$device and .[0].boot==false' <<< "$attached" >/dev/null || die "Unexpected or missing device attachment: $disk"
  save_state "disk_${disk}" attached
}

resume_firewalls() {
  [[ "$DRY_RUN" != true ]] || { lab_firewalls; return; }
  local suffix name info rule sources allowed ranges tags inspect_error firewall_exists
  for suffix in ssh external internal pods; do
    name="${DEPLOYMENT_TAG}-${suffix}"
    case "$suffix" in
      ssh) rule=tcp:22; sources="--source-ranges=$SSH_SOURCE_CIDR";;
      external) rule=tcp:80,tcp:443,tcp:8443; sources=--source-ranges=0.0.0.0/0;;
      internal) rule=tcp,udp,icmp; sources="--source-tags=$DEPLOYMENT_TAG";;
      pods) rule=tcp,udp,icmp; sources=--source-ranges=10.42.0.0/16,10.43.0.0/16;;
    esac
    tags='[]'
    case "$suffix" in
      ssh) allowed='[{"IPProtocol":"tcp","ports":["22"]}]'; ranges=$(jq -nc --arg c "$SSH_SOURCE_CIDR" '[$c]');;
      external) allowed='[{"IPProtocol":"tcp","ports":["80","443","8443"]}]'; ranges='["0.0.0.0/0"]';;
      internal) allowed='[{"IPProtocol":"tcp"},{"IPProtocol":"udp"},{"IPProtocol":"icmp"}]'; ranges='[]'; tags=$(jq -nc --arg t "$DEPLOYMENT_TAG" '[$t]');;
      pods) allowed='[{"IPProtocol":"tcp"},{"IPProtocol":"udp"},{"IPProtocol":"icmp"}]'; ranges='["10.42.0.0/16","10.43.0.0/16"]';;
    esac
    firewall_exists=false
    inspect_error=$(mktemp)
    if info=$(gcloud compute firewall-rules describe "$name" --project="$GCP_PROJECT" --format=json 2>"$inspect_error"); then
      firewall_exists=true
    elif ! grep -Eqi 'was not found|not found|could not fetch resource' "$inspect_error"; then
      rm -f "$inspect_error"
      die "Cannot inspect firewall $name; access or API failure."
    fi
    rm -f "$inspect_error"
    if [[ "$firewall_exists" != true ]]; then
      [[ -z "$(get_state "firewall_${name}")" ]] || die "Recorded firewall disappeared: $name"
      run gcloud compute firewall-rules create "$name" --project="$GCP_PROJECT" --network="$GCP_NETWORK" --allow="$rule" "$sources" --target-tags="$DEPLOYMENT_TAG" --description="instana-lab-id=$DEPLOYMENT_ID"
    else
      # Structural match (network, target tag, protocols/ports, source tags);
      # the description (identity) and the SSH source range are handled below.
      jq -e --arg tag "$DEPLOYMENT_TAG" --arg network "$GCP_NETWORK" --argjson allowed "$allowed" --argjson tags "$tags" \
        '.disabled==false and .direction=="INGRESS" and
        (.network|endswith("/"+$network)) and .targetTags==[$tag] and
        ((.sourceTags//[]|sort)==($tags|sort)) and
        (def norm: group_by(.IPProtocol) | map({IPProtocol: .[0].IPProtocol, ports: (map(.ports//[]) | add | unique)}) | sort_by(.IPProtocol);
         (.allowed|norm)==($allowed|norm))' <<< "$info" >/dev/null ||
        die_with_steps "Firewall rule ${name} exists but does not match this deployment (network, target tag, protocols or ports differ)." \
          "Inspect it:|gcloud compute firewall-rules describe ${name} --project=${GCP_PROJECT}" \
          "*If it belongs to an old lab with the same node names, delete it and rerun with --resume:" \
          "*    gcloud compute firewall-rules delete ${name} --project=${GCP_PROJECT}"
      local desc other_id
      desc=$(jq -r '.description // ""' <<< "$info")
      if [[ "$desc" == "instana-lab-id=$DEPLOYMENT_ID" ]]; then
        :
      elif [[ -z "$desc" ]]; then
        # Created by an earlier installer version without the identity tag; it
        # matches structurally, so adopt it and tag it now.
        run gcloud compute firewall-rules update "$name" --project="$GCP_PROJECT" --description="instana-lab-id=$DEPLOYMENT_ID"
        log "Adopted firewall rule ${name} (tagged with this deployment's identity)."
      else
        other_id="${desc#instana-lab-id=}"
        warn "Firewall rule ${name} carries another deployment identity (${other_id}; this run is ${DEPLOYMENT_ID}), but its content matches this deployment exactly."
        hint "It is left from an earlier attempt whose state file was lost or replaced." \
             "Adopting re-tags the rule for this deployment; nothing else changes."
        if prompt_yes_no "Adopt firewall rule ${name} for this deployment?" Y; then
          run gcloud compute firewall-rules update "$name" --project="$GCP_PROJECT" --description="instana-lab-id=$DEPLOYMENT_ID"
          ok "Adopted firewall rule ${name}."
        else
          die_with_steps "Firewall rule ${name} was not adopted." \
            "*Use different node names for this deployment, or remove the other lab first ('clean up' in ./install.sh)."
        fi
      fi
      local have_ranges
      have_ranges=$(jq -c '(.sourceRanges//[])|sort' <<< "$info")
      if [[ "$have_ranges" != "$(jq -c 'sort' <<< "$ranges")" ]]; then
        if [[ "$suffix" == ssh ]]; then
          warn "SSH firewall rule ${name} allows $(jq -r 'join(", ")' <<< "$have_ranges"), but this machine's current address is ${SSH_SOURCE_CIDR} (public IPs change between sessions)."
          if prompt_yes_no "Update the SSH rule to allow ${SSH_SOURCE_CIDR} instead?" Y; then
            run gcloud compute firewall-rules update "$name" --project="$GCP_PROJECT" --source-ranges="$SSH_SOURCE_CIDR"
            ok "SSH firewall rule ${name} now allows ${SSH_SOURCE_CIDR}."
          else
            die "SSH rule left unchanged; the installer cannot reach the nodes from ${SSH_SOURCE_CIDR}. Rerun with --resume when ready."
          fi
        else
          die_with_steps "Firewall rule ${name} has source ranges $(jq -r 'join(", ")' <<< "$have_ranges"), expected $(jq -r 'join(", ")' <<< "$ranges")." \
            "Inspect and correct it, then rerun with --resume:|gcloud compute firewall-rules describe ${name} --project=${GCP_PROJECT}"
        fi
      fi
    fi
    save_state "firewall_${name}" created
  done
}

# ── Destroy (destroy.sh and the clean-up menu) ───────────────────────────────
# prov_gcp_destroy_target — sets DESTROY_SCOPE / DESTROY_LOCATION (project and
# zone) from the state file; empty when not recorded.
prov_gcp_destroy_target() {
  DESTROY_SCOPE=$(get_state "gcp_project" 2>/dev/null || echo "")
  DESTROY_LOCATION=$(get_state "gcp_zone" 2>/dev/null || echo "")
}
prov_gcp_destroy_target_text() { echo "project: '${DESTROY_SCOPE:-?}', zone: '${DESTROY_LOCATION:-?}'"; }
prov_gcp_destroy_validate_target() {
  [[ "$DESTROY_SCOPE" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "State file holds an invalid GCP project ID '${DESTROY_SCOPE}'."
}

gcp_destroy_vm() {
  local name="$1"
  if gcloud compute instances describe "$name" \
      --project="$DESTROY_SCOPE" --zone="$DESTROY_LOCATION" &>/dev/null 2>&1; then
    log "Deleting VM: ${name}..."
    run gcloud compute instances delete "$name" \
      --project="$DESTROY_SCOPE" \
      --zone="$DESTROY_LOCATION" \
      --quiet
    ok "VM ${name} deleted."; (( DELETED++ )) || true
  else
    warn "VM ${name} not found — skipping."; (( MISSING++ )) || true
  fi
}

# Disks are deleted after the VMs, which detaches them.
gcp_destroy_disk() {
  local name="$1"
  if gcloud compute disks describe "$name" \
      --project="$DESTROY_SCOPE" --zone="$DESTROY_LOCATION" &>/dev/null 2>&1; then
    log "Deleting disk: ${name}..."
    run gcloud compute disks delete "$name" \
      --project="$DESTROY_SCOPE" \
      --zone="$DESTROY_LOCATION" \
      --quiet
    ok "Disk ${name} deleted."; (( DELETED++ )) || true
  else
    warn "Disk ${name} not found — skipping."; (( MISSING++ )) || true
  fi
}

gcp_destroy_firewall() {
  local name="$1"
  if gcloud compute firewall-rules describe "$name" \
      --project="$DESTROY_SCOPE" &>/dev/null 2>&1; then
    log "Deleting firewall rule: ${name}..."
    run gcloud compute firewall-rules delete "$name" \
      --project="$DESTROY_SCOPE" \
      --quiet
    ok "Firewall rule ${name} deleted."; (( DELETED++ )) || true
  else
    warn "Firewall rule ${name} not found — skipping."; (( MISSING++ )) || true
  fi
}

# prov_gcp_destroy_from_state — deletes the VMs, then the disks, then the
# firewall rules recorded in the state file; counts DELETED and MISSING.
prov_gcp_destroy_from_state() {
  local vm_name disk_name fw fw_key
  # VMs
  while IFS= read -r vm_name; do
    [[ -n "$vm_name" ]] && gcp_destroy_vm "$vm_name"
  done < <(jq -r 'to_entries[] | select(.key | startswith("vm_")) | .key | ltrimstr("vm_")' "$STATE_FILE" 2>/dev/null)

  # Disks
  while IFS= read -r disk_name; do
    [[ -n "$disk_name" ]] && gcp_destroy_disk "$disk_name"
  done < <(jq -r 'to_entries[] | select(.key | startswith("disk_")) | .key | ltrimstr("disk_")' "$STATE_FILE" 2>/dev/null)

  # Firewall rules
  while IFS= read -r fw; do
    [[ -n "$fw" ]] && gcp_destroy_firewall "$fw"
  done < <(jq -r 'to_entries[] | select(.key | startswith("firewall_")) | .key | ltrimstr("firewall_")' "$STATE_FILE")
  for fw in "instana-allow-ssh" "instana-allow-external" "instana-allow-k3s-subnets" "instana-allow-internal"; do
    fw_key="fw_${fw#instana-allow-}"
    if [[ "$(get_state "$fw_key")" == "created" ]]; then
      gcp_destroy_firewall "$fw"
    fi
  done
}

# Cleanup without a state file: the operator names the project, zone and VM;
# the installer lists the VM, the disks named <vm>-* and the instana-allow-*
# firewall rules, shows them, and deletes only after an explicit confirmation.
# ── Clean-up: pick a lab from a list (UX v2) ────────────────────────────────
# Labs in the project, read-only. Listed are only:
#  - label groups: VMs, disks and firewall rules carrying the same
#    instana-lab-id (three-node labs; resources left without their VMs are an
#    "orphaned" entry of their own),
#  - single-node labs: an unlabelled VM with ALL four installer disks
#    <vm>-analytics/-metrics/-objects/-data in its zone, each unattached or
#    attached only to that VM (plus its boot disk when attached only to it).
# The control machine (name or address) and the disks attached to it are
# never listed. One line per lab: "key|zones|title|vms|disks|rules" with
# vms "name@zone:status:created", disks "name@zone:sizeGB" (space-separated).
gcp_list_labs() {
  local project="$1" inst disks fws self mine
  inst=$(gcloud compute instances list --project="$project" --format=json 2>"$GCP_LIST_ERR") || return 1
  disks=$(gcloud compute disks list --project="$project" --format=json 2>>"$GCP_LIST_ERR") || return 1
  fws=$(gcloud compute firewall-rules list --project="$project" --format=json 2>>"$GCP_LIST_ERR") || return 1
  self=$(hostname -s 2>/dev/null || true)
  mine=$( { declare -F prov_ssh_local_ips >/dev/null && prov_ssh_local_ips; } | jq -R . | jq -s . 2>/dev/null || echo '[]')
  jq -r -n --argjson inst "${inst:-[]}" --argjson disks "${disks:-[]}" --argjson fws "${fws:-[]}" \
     --arg self "$self" --argjson mine "${mine:-[]}" '
    def zone: ((.zone // "") | split("/") | last);
    def users: ((.users // []) | map(split("/") | last));
    def lab: (.labels["instana-lab-id"] // "");
    def excluded: (.name == $self
      or ((.networkInterfaces[0].networkIP // "") as $i | $i != "" and ($mine | index($i)) != null)
      or ((.networkInterfaces[0].accessConfigs[0].natIP // "") as $n | $n != "" and ($mine | index($n)) != null));
    def created: ((.creationTimestamp // "") | .[0:10]);
    ($inst | map(select(excluded | not))) as $vms
    | ($inst | map(select(excluded) | .name)) as $excl
    | ($disks | map(select(users | any(. as $u | $excl | index($u) != null) | not))) as $dsk
    | ( ([$vms[], $dsk[] | lab] + [$fws[] | (.description // "") | select(startswith("instana-lab-id=")) | ltrimstr("instana-lab-id=")])
        | map(select(. != "")) | unique ) as $ids
    | ( $ids[] as $id
        | ($vms | map(select(lab == $id))) as $v
        | ($v | map(.name)) as $vn
        # a labelled disk in use by a VM outside the lab is never part of it
        | ($dsk | map(select(lab == $id and (users | all(. as $u | $vn | index($u) != null))))) as $d
        | ($fws | map(select((.description // "") == ("instana-lab-id=" + $id)))) as $f
        | select(($v | length) + ($d | length) + ($f | length) > 0)
        | [ "lab:" + $id,
            (($v + $d) | map(zone) | unique | join(",")),
            (if ($v | length) > 0 then "three-node lab " + ($v | map(.name) | join(", "))
             else "orphaned resources of lab " + $id + " (no VM left)" end),
            ($v | map(.name + "@" + zone + ":" + .status + ":" + created) | join(" ")),
            ($d | map(.name + "@" + zone + ":" + (.sizeGb // "0")) | join(" ")),
            ($f | map(.name) | join(" ")) ] | join("|") ),
      ( $vms[] | select(lab == "") | . as $v | ($v | zone) as $z
        | (["-analytics","-metrics","-objects","-data"] | map($v.name + .)) as $roles
        | ($dsk | map(select(zone == $z and lab == "" and (.name as $n | $roles | index($n)) != null))) as $rd
        | select(($rd | length) == 4 and ($rd | all(users | all(. == $v.name))))
        | ($dsk | map(select(zone == $z and .name == $v.name and (users | all(. == $v.name))))) as $boot
        | [ "vm:" + $v.name, $z, "single-node lab " + $v.name,
            ($v.name + "@" + $z + ":" + $v.status + ":" + ($v | created)),
            (($rd + $boot) | map(.name + "@" + zone + ":" + (.sizeGb // "0")) | join(" ")), "" ] | join("|") )'
}

prov_gcp_destroy_by_name() {
  echo "" >&2
  echo -e "${BOLD}Clean up a lab${RESET}" >&2
  command -v gcloud >/dev/null 2>&1 ||
    die_with_steps "gcloud is not installed on this machine, so the labs cannot be listed or removed from here." \
      "Install the Google Cloud CLI and log in, then run the clean-up again:|gcloud auth login && ./install.sh"
  check_gcp_login
  OPERATION_NAME="clean-up"
  hint "The project whose labs are listed (read-only; nothing is deleted without your typed confirmation)."
  prompt_required GCP_PROJECT "GCP Project ID" "$(default_gcp_project)" validate_gcp_project_id
  local project="$GCP_PROJECT" err_out
  GCP_LIST_ERR=$(mktemp)
  log "Listing the labs in project ${project} (read-only)..."
  local -a labs=()
  local out
  if ! out=$(gcp_list_labs "$project"); then
    err_out=$(grep -v '^\s*$' "$GCP_LIST_ERR" | head -2 | paste -sd' ' -); rm -f "$GCP_LIST_ERR"
    die_with_steps "The labs of project ${project} could not be listed: ${err_out:-gcloud failed}. Nothing was deleted." \
      "*Why it stops: without a complete list the installer cannot show exactly what would be deleted, so it deletes nothing." \
      "Check access to the project (compute.instances.list, disks.list, firewalls.list):|gcloud compute instances list --project=${project} --limit=1" \
      "Then run the clean-up again:|./install.sh"
  fi
  rm -f "$GCP_LIST_ERR"
  [[ -z "$out" ]] || mapfile -t labs <<< "$out"
  hint "Only resources created by this installer are listed (label instana-lab-id or <vm>-analytics/-metrics/-objects/-data disks)." \
       "A single-node VM is listed only when those four disks belong to it alone. Anything else: n = look a VM up by name."
  echo -e "    ${DIM}This control machine and anything else in the project are never listed or deleted.${RESET}" >&2
  if (( ${#labs[@]} == 0 )); then
    ok "No labs of this installer were found in project ${project}."
    if prompt_yes_no "Look up a VM by its name?" N; then gcp_destroy_by_vm_name "$project"; fi
    log "Nothing was deleted."
    exit 0
  fi
  local i=1 key zones title vms dsk rules v n st cr d sz total running line
  echo "" >&2
  echo -e "${CYAN}?${RESET} Labs in ${project} (this control machine is not listed):" >&2
  for line in "${labs[@]}"; do
    IFS='|' read -r key zones title vms dsk rules <<< "$line"
    total=0; running=0
    for d in $dsk; do sz="${d##*:}"; (( total += ${sz:-0} )); done
    for v in $vms; do [[ "$v" == *:RUNNING:* ]] && (( ++running )); done
    printf '  %2d) %s  (zone %s)\n' "$i" "$title" "${zones//,/, }" >&2
    for v in $vms; do IFS=: read -r n st cr <<< "$v"; printf '        VM %-24s %-10s %-16s created %s\n' "${n%@*}" "$st" "${n#*@}" "$cr" >&2; done
    printf '        disks: %s GB in %s disk(s)%s\n' "$total" "$(wc -w <<< "$dsk" | tr -d ' ')" "${rules:+; firewall rules: $(wc -w <<< "$rules" | tr -d ' ')}" >&2
    if (( running > 0 )); then echo "        cost: running VMs are billed per hour, disks while they exist" >&2
    elif [[ -n "$vms" ]]; then echo "        cost: VMs stopped, but the disks are still billed while they exist" >&2
    else echo "        cost: the disks are billed while they exist" >&2; fi
    (( ++i ))
  done
  local answer pick rc
  while true; do
    rc=0; read_answer answer "$(echo -e "  ${BOLD}Select [1-${#labs[@]}, n = look up a VM by name, 0 = back]:${RESET} ")" 1 || rc=$?
    (( rc != 1 )) || die "Input ended; clean-up cancelled. Nothing was deleted."
    [[ "$rc" != 3 && "$answer" != 0 ]] || answer="<"
    case "$answer" in
      "<") prov_gcp_destroy_by_name; return ;;
      n|N) gcp_destroy_by_vm_name "$project"; return ;;
    esac
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#labs[@]} )); then pick="${labs[$((answer-1))]}"; break; fi
    echo "  Type a number from 1 to ${#labs[@]}, n to look a VM up by name, or 0 to choose another project." >&2
  done
  IFS='|' read -r key zones title vms dsk rules <<< "$pick"
  gcp_delete_lab "$project" "$zones" "$title" "$vms" "$dsk" "$rules"
}

# gcp_gone KIND NAME ZONE PROJECT — 0 when gcloud says the resource does not
# exist; 1 when it exists or the answer is not a clear "not found".
gcp_gone() {
  local out
  if [[ "$1" == firewall-rules ]]; then out=$(gcloud compute firewall-rules describe "$2" --project="$4" --format='value(name)' 2>&1 >/dev/null) && return 1
  else out=$(gcloud compute "$1" describe "$2" --zone="$3" --project="$4" --format='value(name)' 2>&1 >/dev/null) && return 1; fi
  [[ "$out" == *"was not found"* || "$out" == *"notFound"* ]]
}

# gcp_delete_lab PROJECT ZONES TITLE "VMS" "DISKS" "RULES" — shows exactly
# what is deleted (each resource in its own zone); a preview stops there; a
# real run needs the typed DELETE phrase naming every zone, deletes the VMs,
# checks they are gone, then their disks, then the lab's rules, and ends with
# a deleted / NOT deleted table (exit 1 when something is left).
gcp_delete_lab() {
  local project="$1" zones="$2" title="$3" vms="$4" dsk="$5" rules="$6" v n z st cr d expected confirm
  echo "" >&2
  echo -e "${BOLD}This is what would be deleted (${title}, project ${project}):${RESET}" >&2
  for v in $vms; do IFS=: read -r n st cr <<< "$v"; echo "  VM    ${n%@*}  (zone ${n#*@}, ${st})" >&2; done
  for d in $dsk; do n="${d%:*}"; echo "  disk  ${n%@*}  (zone ${n#*@}, ${d##*:} GB; the data on it is lost)" >&2; done
  for d in $rules; do echo "  firewall rule  ${d}  (belongs to this lab only)" >&2; done
  if [[ "$DRY_RUN" == true ]]; then
    warn "Preview only (dry-run). Nothing was deleted."
    exit 0
  fi
  expected="DELETE ${project}/${zones}"
  echo -e "${BOLD}${RED}  This permanently deletes everything listed above (zones: ${zones//,/, }).${RESET}" >&2
  read -rp "$(echo -e "${CYAN}?${RESET} Type '${expected}' to confirm (anything else cancels): ")" confirm ||
    die "Input ended; clean-up cancelled. Nothing was deleted."
  [[ "$confirm" == "$expected" ]] || { log "Confirmation did not match; nothing was deleted."; exit 0; }
  local -a done_list=() left=()
  local -A vm_left=()
  for v in $vms; do
    n="${v%%:*}"; z="${n#*@}"; n="${n%@*}"
    log "Deleting VM ${n} (${z})..."
    gcloud compute instances delete "$n" --project="$project" --zone="$z" --quiet || true
    if gcp_gone instances "$n" "$z" "$project"; then done_list+=("VM ${n} (${z})"); ok "VM ${n} deleted."
    else left+=("VM ${n} (${z}): still exists"); vm_left[$n]=1; err "VM ${n} was NOT deleted."; fi
  done
  for d in $dsk; do
    n="${d%:*}"; z="${n#*@}"; n="${n%@*}"
    # A disk of a VM that is still there is in use: left alone.
    local owner="" k
    for k in "${!vm_left[@]}"; do [[ "$n" == "$k" || "$n" == "${k}-"* ]] && owner="$k"; done
    if [[ -n "$owner" ]]; then left+=("disk ${n} (${z}): not tried, VM ${owner} still exists"); continue; fi
    if gcp_gone disks "$n" "$z" "$project"; then done_list+=("disk ${n} (${z}, deleted with its VM)"); continue; fi
    log "Deleting disk ${n} (${z})..."
    gcloud compute disks delete "$n" --project="$project" --zone="$z" --quiet || true
    if gcp_gone disks "$n" "$z" "$project"; then done_list+=("disk ${n} (${z})"); ok "Disk ${n} deleted."
    else left+=("disk ${n} (${z}): still exists"); err "Disk ${n} was NOT deleted."; fi
  done
  for d in $rules; do
    gcloud compute firewall-rules delete "$d" --project="$project" --quiet || true
    if gcp_gone firewall-rules "$d" "" "$project"; then done_list+=("firewall rule ${d}"); ok "Firewall rule ${d} deleted."
    else left+=("firewall rule ${d}: still exists"); err "Firewall rule ${d} was NOT deleted."; fi
  done
  {
    echo ""
    echo "  Deleted:"; if (( ${#done_list[@]} )); then printf '    - %s\n' "${done_list[@]}"; else echo "    (nothing)"; fi
    echo "  NOT deleted:"; if (( ${#left[@]} )); then printf '    - %s\n' "${left[@]}"; else echo "    (nothing)"; fi
  } >&2
  if (( ${#left[@]} )); then
    local again="Fix the cause (permission, a VM still running, a disk still attached), then run the clean-up again; labelled resources that are left are listed again (orphaned ones as their own entry):|./install.sh"
    # A single-node lab is recognised by its VM: once the VM is gone, its
    # leftover disks are not listed again; they are found with n (by name).
    [[ "$title" != "single-node lab "* ]] || again="Fix the cause, then run the clean-up again and choose n (look up a VM by name) with '${title#single-node lab }': once the VM is gone, the leftover disks are not in the lab list any more:|./install.sh"
    die_with_steps "Clean-up of ${title} is incomplete: ${#left[@]} resource(s) were NOT deleted (listed above; the gcloud message is above each)." "$again"
  fi
  ok "Clean-up of ${title} in project ${project} finished; everything listed was deleted."
  exit 0
}

# Look-up by VM name (the earlier clean-up), for VMs the list does not show.
gcp_destroy_by_vm_name() {
  local project="$1" zone vm confirm vm_found disks fws expected
  echo "  Disks created by this installer are named <vm-name>-analytics/-metrics/-objects/-data." >&2
  hint "The zone is found automatically from the VM name."
  prompt_required VM_NAME "VM name to clean up (e.g. mikrut-air; for three-node the node0 name, e.g. instana-0)" ""
  vm="$VM_NAME"
  [[ "$vm" != "$(hostname -s 2>/dev/null || true)" ]] ||
    die_with_steps "'${vm}' is this control machine; the clean-up never deletes it." "*Choose the VM of the lab to remove:|./install.sh"
  local base="${vm%-0}"   # three-node: instana-0 -> also instana-1, instana-2

  log "Searching project ${project} (all zones) for resources of '${vm}'..."
  local zones
  # Regexes are quoted inside the filter expression; unquoted ( | ) confuse the gcloud filter parser.
  local vm_re="^(${vm}|${base}-[0-9])\$" disk_re="^(${vm}|${base}-[0-9])(-[a-z]+)?\$"
  zones=$( { gcloud compute instances list --project="$project" --filter="name~\"${vm_re}\"" --format="value(zone.basename())";
             gcloud compute disks list --project="$project" --filter="name~\"${disk_re}\"" --format="value(zone.basename())"; } 2>/dev/null | sed '/^$/d' | sort -u)
  if [[ -z "$zones" ]]; then
    ok "Nothing named '${vm}' (VM or disks) exists in project ${project}; nothing to delete."
    exit 0
  fi
  if (( $(wc -l <<< "$zones") > 1 )); then
    zone=$(prompt_choice "Resources named '${vm}' exist in several zones; which one?" $zones) || die "Clean-up cancelled."
  else
    zone="$zones"
  fi
  GCP_ZONE="$zone"
  log "Found them in zone ${zone}."
  vm_found=$(gcloud compute instances list --project="$project" --zones="$zone" \
    --filter="name~\"${vm_re}\"" --format="value(name,status,machineType.basename())" 2>/dev/null || true)
  disks=$(gcloud compute disks list --project="$project" --zones="$zone" \
    --filter="name~\"${disk_re}\"" --format="value(name,sizeGb,type.basename(),users.basename())" 2>/dev/null || true)
  fws=$(gcloud compute firewall-rules list --project="$project" \
    --filter="name~\"^instana-allow-\"" --format="value(name,sourceRanges.list())" 2>/dev/null || true)

  echo "" >&2
  echo -e "${BOLD}Found:${RESET}" >&2
  echo "  VMs:" >&2;    if [[ -n "$vm_found" ]]; then sed 's/^/    /' <<< "$vm_found" >&2; else echo "    (none)" >&2; fi
  echo "  Disks:" >&2;  if [[ -n "$disks" ]]; then sed 's/^/    /' <<< "$disks" >&2; else echo "    (none)" >&2; fi
  echo "  Firewall rules (shared by every Instana deployment in this project):" >&2
  if [[ -n "$fws" ]]; then sed 's/^/    /' <<< "$fws" >&2; else echo "    (none)" >&2; fi
  echo "" >&2
  if [[ -z "$vm_found" && -z "$disks" ]]; then
    ok "Nothing named '${vm}' exists in ${project}/${zone}; nothing to delete."
    exit 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    warn "Preview only (--dry-run). Nothing was deleted."
    exit 0
  fi
  prompt_yes_no "Delete the VMs and disks listed above?" N || { log "Nothing was deleted."; exit 0; }
  local delete_fw=false
  if [[ -n "$fws" ]]; then
    prompt_yes_no "Also delete the instana-allow-* firewall rules? Only say yes if no other Instana deployment in this project uses them" N && delete_fw=true
  fi
  expected="DELETE ${project}/${zone}"
  echo -e "${BOLD}${RED}  This permanently deletes the VMs and disks listed above (data on the disks is lost).${RESET}" >&2
  read -rp "$(echo -e "${CYAN}?${RESET} Type '${expected}' to confirm: ")" confirm || exit 1
  [[ "$confirm" == "$expected" ]] || die "Confirmation did not match; nothing was deleted."

  local name
  while read -r name _; do
    [[ -n "$name" ]] || continue
    log "Deleting VM ${name}..."
    gcloud compute instances delete "$name" --project="$project" --zone="$zone" --quiet && ok "VM ${name} deleted."
  done <<< "$vm_found"
  while read -r name _; do
    [[ -n "$name" ]] || continue
    # Boot disks carry the VM's name and are removed together with the VM.
    if ! gcloud compute disks describe "$name" --project="$project" --zone="$zone" >/dev/null 2>&1; then
      log "Disk ${name} is already gone (boot disk deleted with its VM)."
      continue
    fi
    log "Deleting disk ${name}..."
    gcloud compute disks delete "$name" --project="$project" --zone="$zone" --quiet && ok "Disk ${name} deleted."
  done <<< "$disks"
  if [[ "$delete_fw" == true ]]; then
    while read -r name _; do
      [[ -n "$name" ]] || continue
      gcloud compute firewall-rules delete "$name" --project="$project" --quiet && ok "Firewall rule ${name} deleted."
    done <<< "$fws"
  fi
  ok "Cleanup of '${vm}' in ${project}/${zone} finished."
  exit 0
}
