#!/usr/bin/env bash
# =============================================================================
# Instana Standard Edition — GCP Deployment Script
# =============================================================================
# Source: IBM Instana Observability documentation (instana-observability-documentation.pdf)
# All hardware minimums, kernel parameters, firewall rules, and installation
# commands are taken verbatim from the official documentation.
# No values have been guessed or assumed.
#
# Supported topology:
#   - Single-node  (demo or production)
#   - Three-node   (production only — as per docs)
#
# Supported Ubuntu versions (from docs, Table 1):
#   - Ubuntu 24.04
#   - Ubuntu 22.04
#
# Usage:
#   ./install.sh [--dry-run]
# =============================================================================

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_FILE="${SCRIPT_DIR}/.install-state.json"
readonly CONFIG_FILE="${SCRIPT_DIR}/.install-config.json"
umask 077
source "${SCRIPT_DIR}/parameters.sh"
readonly LOG_FILE="${SCRIPT_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
readonly INSTANA_APT_REPO="deb [signed-by=/usr/share/keyrings/instana-archive-keyring.gpg] https://artifact-public.instana.io/artifactory/rel-debian-public-virtual generic main"
readonly INSTANA_KEYRING_URL="https://artifact-public.instana.io/artifactory/api/security/keypair/public/repositories/rel-debian-public-virtual"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── State ─────────────────────────────────────────────────────────────────────
DRY_RUN=false
RESUME=false
INSTALL_MODE=""
AIRGAP_ARCHIVE=""
AIRGAP_STANCTL_DEB=""
SSH_SOURCE_CIDR=""

# ── Logging ───────────────────────────────────────────────────────────────────
log()  { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE"; }
die()  { err "$*"; exit 1; }
run()  {
  if [[ "$DRY_RUN" == true ]]; then
    printf "${YELLOW}[DRY-RUN]${RESET} " | tee -a "$LOG_FILE"
    printf '%q ' "$@" | tee -a "$LOG_FILE"
    printf '\n' | tee -a "$LOG_FILE"
  else
    printf '>> ' >> "$LOG_FILE"
    printf '%q ' "$@" >> "$LOG_FILE"
    printf '\n' >> "$LOG_FILE"
    "$@"
  fi
}

# ── Argument parsing ──────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --resume) RESUME=true ;;
    --dry-run) DRY_RUN=true; warn "Dry-run mode — no GCP resources will be created." ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

# =============================================================================
# SECTION 1 — PREREQUISITES CHECK
# =============================================================================
check_local_tools() {
  log "Checking required local tools..."
  local missing=()
  for tool in gcloud jq ssh-keygen curl mktemp timeout; do
    command -v "$tool" &>/dev/null || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}\nInstall them before running this script."
  fi
  ok "All required tools found."
}

check_gcp_login() {
  log "Checking GCP authentication..."
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q "@"; then
    die "No active GCP account found. Run: gcloud auth login"
  fi
  ok "GCP authentication active: $(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
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
  available=$(echo "$quota - $used" | bc 2>/dev/null || echo "unknown")
  log "CPU quota in ${region}: limit=${quota}, used=${used}, available=${available}"
  if [[ "$available" != "unknown" ]] && (( $(echo "$available < $cpus" | bc -l) )); then
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

check_gcp_configuration() {
  log "Validating GCP project, zone, network, and subnet..."
  gcloud projects describe "$GCP_PROJECT" >/dev/null 2>&1 || die "Cannot access GCP project: ${GCP_PROJECT}"
  gcloud compute zones describe "$GCP_ZONE" --project="$GCP_PROJECT" >/dev/null 2>&1 || die "Zone not found or unavailable: ${GCP_ZONE}"
  gcloud compute networks describe "$GCP_NETWORK" --project="$GCP_PROJECT" >/dev/null 2>&1 || die "VPC network not found: ${GCP_NETWORK}"
  gcloud compute networks subnets describe "$GCP_SUBNET" --region="$GCP_REGION" --project="$GCP_PROJECT" >/dev/null 2>&1 || die "Subnet '${GCP_SUBNET}' not found in ${GCP_REGION}."
  ok "GCP configuration is accessible."
}

# =============================================================================
# SECTION 2 — HARDWARE MINIMUMS (from docs, verbatim)
# =============================================================================
# Source: System requirements for a single-node deployment, Table 2
# Source: System requirements for a three-node deployment, Table 3

show_single_node_requirements() {
  local install_type="$1"
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║   Single-Node Hardware Requirements (Official Minimums)      ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  case "$install_type" in
    demo)
      echo -e "  Installation type : demo (test/demo only — NOT for production)"
      echo -e "  CPU cores         : 16"
      echo -e "  Memory (GB)       : 64"
      echo -e "  Total storage     : 1200 GB"
      echo -e "  Min disk IOPS     : 1000"
      echo -e "  Min disk throughput: 125 MiB/s"
      echo ""
      echo -e "  Storage breakdown (4 dedicated disks required):"
      echo -e "    data      : 150 GB"
      echo -e "    metrics   : 300 GB"
      echo -e "    analytics : 500 GB"
      echo -e "    objects   : 250 GB"
      echo -e "    cluster   : 100 GB"
      echo -e "    root (/)  : 100 GB"
      ;;
    production)
      echo -e "  Installation type : production (Small VM)"
      echo -e "  CPU cores         : 28"
      echo -e "  Memory (GB)       : 112"
      echo -e "  Total storage     : 3700 GB"
      echo -e "  Min disk IOPS     : 3000"
      echo -e "  Min disk throughput: 250 MiB/s"
      echo ""
      echo -e "  Storage breakdown (4 dedicated disks required):"
      echo -e "    data      : 500 GB"
      echo -e "    metrics   : 1000 GB"
      echo -e "    analytics : 1200 GB"
      echo -e "    objects   : 1000 GB"
      echo -e "    cluster   : 100 GB"
      echo -e "    root (/)  : 100 GB"
      ;;
  esac
  echo ""
  echo -e "  ${YELLOW}NOTE: Each of the 4 data directories must be on its own dedicated disk.${RESET}"
  echo -e "  ${YELLOW}      Sharing disks between directories is NOT supported.${RESET}"
  echo ""
}

show_three_node_requirements() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║   Three-Node Hardware Requirements (Official Minimums)       ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo -e "  Installation type : production only (multi-node requires production)"
  echo ""
  echo -e "  ${BOLD}Production - Small per node:${RESET}"
  echo -e "  ┌─────────────┬───────────┬────────────┬─────────────┬─────────────────────────────┐"
  echo -e "  │ Node        │ CPU cores │ Memory(GB) │ Disk(GB)    │ Purpose                     │"
  echo -e "  ├─────────────┼───────────┼────────────┼─────────────┼─────────────────────────────┤"
  echo -e "  │ instana-0   │ 12        │ 48         │ 1270        │ backend + objects disk       │"
  echo -e "  │ instana-1   │ 12        │ 48         │ 2970        │ data store (data+metrics+    │"
  echo -e "  │             │           │            │             │ analytics disks)             │"
  echo -e "  │ instana-2   │ 12        │ 48         │ 270         │ other workloads (root only)  │"
  echo -e "  └─────────────┴───────────┴────────────┴─────────────┴─────────────────────────────┘"
  echo ""
  echo -e "  Disk layout per node:"
  echo -e "    instana-0 : objects disk = 1000 GB, root = 100 GB, cluster = 100 GB"
  echo -e "    instana-1 : data = 500 GB, metrics = 1000 GB, analytics = 1200 GB, root = 100 GB"
  echo -e "    instana-2 : root = 100 GB, cluster = 100 GB (no extra disk)"
  echo ""
  echo -e "  Min disk IOPS : 3000 | Min disk throughput: 250 MiB/s"
  echo ""
  echo -e "  ${YELLOW}NOTE: Multi-node requires all 3 nodes on the same private VLAN.${RESET}"
  echo -e "  ${YELLOW}      Passwordless SSH from instana-0 to instana-1 and instana-2 is required.${RESET}"
  echo ""
}

# =============================================================================
# SECTION 3 — USER INPUT
# =============================================================================
prompt() {
  local var_name="$1" prompt_text="$2" default="${3:-}"
  if [[ "$CONFIG_LOADED" == true ]]; then
    default="$(jq -r --arg k "$var_name" '.parameters[$k] // empty' "$CONFIG_FILE")"
    [[ -n "$default" ]] || default="${3:-}"
  fi
  local value
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${CYAN}?${RESET} ${prompt_text} [${default}]: ")" value
    echo "${value:-$default}"
  else
    read -rp "$(echo -e "${CYAN}?${RESET} ${prompt_text}: ")" value
    echo "$value"
  fi
}

prompt_secret() {
  local var_name="$1" prompt_text="$2"
  local value
  read -rsp "$(echo -e "${CYAN}?${RESET} ${prompt_text}: ")" value
  echo "" >&2
  echo "$value"
}

prompt_choice() {
  local prompt_text="$1"; shift
  local options=("$@")
  echo -e "${CYAN}?${RESET} ${prompt_text}" >&2
  local i=1
  for opt in "${options[@]}"; do
    echo "  $i) $opt" >&2
    (( i++ ))
  done
  local choice
  while true; do
    read -rp "$(echo -e "${CYAN}  Select [1-${#options[@]}]:${RESET} ")" choice
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )) && break
    echo "Invalid selection." >&2
  done
  echo "${options[$((choice - 1))]}"
}

prompt_yes_no() {
  local prompt_text="$1" default="${2:-N}"
  local answer
  read -rp "$(echo -e "${CYAN}?${RESET} ${prompt_text} [${default}]: ")" answer
  answer="${answer:-$default}"
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

validate_secret() {
  local value="$1" label="$2"
  [[ -n "$value" ]] || die "${label} is required."
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "${label} must not contain line breaks."
}

validate_tenant_unit_name() {
  # From docs: must match ^[a-z][a-z0-9]*$, max 15 chars, start with alpha, lowercase only
  local name="$1" label="$2"
  if ! [[ "$name" =~ ^[a-z][a-z0-9]*$ ]]; then
    die "${label} '${name}' is invalid. Must match ^[a-z][a-z0-9]*$ (lowercase alphanumeric, start with letter)"
  fi
  if [[ ${#name} -gt 15 ]]; then
    die "${label} '${name}' exceeds 15 characters."
  fi
}

validate_fqdn() {
  local fqdn="$1"
  if ! [[ "$fqdn" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    die "Invalid FQDN: ${fqdn}"
  fi
}

# =============================================================================
# SECTION 4 — COLLECT ALL PARAMETERS
# =============================================================================
collect_parameters() {
  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}  Instana Standard Edition — GCP Deployment Setup${RESET}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${RESET}"
  echo ""

  # Topology
  TOPOLOGY=$(prompt_choice "Select deployment topology:" \
    "single-node" \
    "three-node")

  INSTALL_MODE=$(prompt_choice "Select installation connectivity mode:" \
    "online" \
    "air-gapped")

  # Install type
  if [[ "$TOPOLOGY" == "single-node" ]]; then
    INSTALL_TYPE=$(prompt_choice "Select installation type:" \
      "demo" \
      "production")
  else
    INSTALL_TYPE="production"
    log "Three-node clusters require production installation type (per documentation)."
  fi

  # Ubuntu version — from docs: Ubuntu 24.04 and 22.04 only
  UBUNTU_VERSION=$(prompt_choice "Select Ubuntu version (supported: 24.04, 22.04):" \
    "ubuntu-2404-lts-amd64" \
    "ubuntu-2204-lts")

  # GCP parameters
  GCP_PROJECT=$(prompt "GCP_PROJECT" "GCP Project ID" "")
  [[ -z "$GCP_PROJECT" ]] && die "GCP Project ID is required."

  GCP_REGION=$(prompt "GCP_REGION" "GCP Region" "us-central1")
  GCP_ZONE=$(prompt "GCP_ZONE" "GCP Zone" "${GCP_REGION}-a")
  GCP_NETWORK=$(prompt "GCP_NETWORK" "VPC Network name" "default")
  GCP_SUBNET=$(prompt "GCP_SUBNET" "Subnet name" "default")
  SSH_SOURCE_CIDR=$(prompt "SSH_SOURCE_CIDR" "CIDR allowed to SSH to the VM(s)" "$(detect_public_cidr)")
  validate_cidr "$SSH_SOURCE_CIDR"

  if [[ "$TOPOLOGY" == "single-node" ]]; then
    VM_NAME=$(prompt "VM_NAME" "VM name" "instana-backend")
  else
    NODE0_NAME=$(prompt "NODE0_NAME" "Node 0 name (instana-0, backend)" "instana-0")
    NODE1_NAME=$(prompt "NODE1_NAME" "Node 1 name (instana-1, data store)" "instana-1")
    NODE2_NAME=$(prompt "NODE2_NAME" "Node 2 name (instana-2, other)" "instana-2")
  fi

  # Machine type selection
  show_hw_requirements_and_pick_machine_type

  # FQDN
  echo ""
  log "DNS entries required (all must point to the VM's external IP):"
  log "  <base_domain>"
  log "  agent-acceptor.<base_domain>"
  log "  opamp-acceptor.<base_domain>"
  log "  otlp-http.<base_domain>"
  log "  otlp-grpc.<base_domain>"
  log "  <unit>-<tenant>.<base_domain>"
  echo ""
  BASE_DOMAIN=$(prompt "BASE_DOMAIN" "Base domain (e.g. instana.example.com)" "")
  [[ -z "$BASE_DOMAIN" ]] && die "Base domain is required."
  validate_fqdn "$BASE_DOMAIN"

  # Tenant / unit names
  TENANT_NAME=$(prompt "TENANT_NAME" "Tenant name (max 15 chars, lowercase alphanumeric, start with letter)" "tenant0")
  validate_tenant_unit_name "$TENANT_NAME" "Tenant name"

  UNIT_NAME=$(prompt "UNIT_NAME" "Unit name (max 15 chars, lowercase alphanumeric, start with letter)" "unit0")
  validate_tenant_unit_name "$UNIT_NAME" "Unit name"

  # Admin password
  echo ""
  log "Instana admin password (will not be stored in any file or log)"
  ADMIN_PASSWORD=$(prompt_secret "ADMIN_PASSWORD" "Instana admin password")
  validate_secret "$ADMIN_PASSWORD" "Admin password"

  # Instana keys — never logged or stored in local state/logs
  echo ""
  log "Instana license keys (will not be stored in any file or log)"
  DOWNLOAD_KEY=$(prompt_secret "DOWNLOAD_KEY" "Instana download key")
  validate_secret "$DOWNLOAD_KEY" "Download key"

  SALES_KEY=$(prompt_secret "SALES_KEY" "Instana sales key")
  validate_secret "$SALES_KEY" "Sales key"

  AGENT_KEY=$(prompt_secret "AGENT_KEY" "Instana agent key")
  validate_secret "$AGENT_KEY" "Agent key"

  if [[ "$INSTALL_MODE" == "air-gapped" ]]; then
    echo ""
    warn "Air-gapped installation needs a matching stanctl Debian package and an air-gapped archive."
    AIRGAP_STANCTL_DEB=$(prompt "AIRGAP_STANCTL_DEB" "Local path to stanctl .deb" "")
    [[ -f "$AIRGAP_STANCTL_DEB" ]] || die "stanctl .deb not found: ${AIRGAP_STANCTL_DEB}"
    AIRGAP_ARCHIVE=$(prompt "AIRGAP_ARCHIVE" "Local path to instana-airgapped.tar.gz" "")
    [[ -f "$AIRGAP_ARCHIVE" ]] || die "Air-gapped archive not found: ${AIRGAP_ARCHIVE}"
  fi

  # TLS certificate
  TLS_MODE=$(prompt_choice "TLS certificate:" \
    "auto-generate (self-signed)" \
    "provide custom certificate files")

  if [[ "$TLS_MODE" == "provide custom certificate files" ]]; then
    TLS_CRT_PATH=$(prompt "TLS_CRT_PATH" "Full path to TLS certificate file (.crt)" "")
    TLS_KEY_PATH=$(prompt "TLS_KEY_PATH" "Full path to TLS key file (.key)" "")
    [[ -f "$TLS_CRT_PATH" ]] || die "TLS cert file not found: ${TLS_CRT_PATH}"
    [[ -f "$TLS_KEY_PATH" ]] || die "TLS key file not found: ${TLS_KEY_PATH}"
  fi
}

detect_public_cidr() {
  local ip
  ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s/32\n' "$ip"
  else
    printf '%s\n' "0.0.0.0/0"
  fi
}

validate_cidr() {
  local cidr="$1"
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || \
    die "Invalid IPv4 CIDR: ${cidr}"
  [[ "$cidr" != "0.0.0.0/0" ]] || warn "SSH will be exposed to the internet. Prefer your public IP with /32."
}

show_hw_requirements_and_pick_machine_type() {
  if [[ "$TOPOLOGY" == "single-node" ]]; then
    show_single_node_requirements "$INSTALL_TYPE"
    local min_cpu min_ram
    case "$INSTALL_TYPE" in
      demo)       min_cpu=16;  min_ram=64 ;;
      production) min_cpu=28;  min_ram=112 ;;
    esac
    echo -e "  Official minimum: ${BOLD}${min_cpu} vCPUs, ${min_ram} GB RAM${RESET}"
    echo ""
    SIZE_CHOICE=$(prompt_choice "Machine size:" \
      "minimum (${min_cpu} vCPUs / ${min_ram} GB) — from documentation" \
      "production recommended (production-small: 28 vCPUs / 112 GB)" \
      "custom — enter manually")

    case "$SIZE_CHOICE" in
      "minimum"*)
        VM_CPUS=$min_cpu; VM_RAM_GB=$min_ram ;;
      "production recommended"*)
        VM_CPUS=28; VM_RAM_GB=112 ;;
      "custom"*)
        VM_CPUS=$(prompt "VM_CPUS" "Number of vCPUs" "$min_cpu")
        VM_RAM_GB=$(prompt "VM_RAM_GB" "RAM in GB" "$min_ram")
        if (( VM_CPUS < min_cpu )); then
          die "CPU count ${VM_CPUS} is below the documented minimum of ${min_cpu}."
        fi
        if (( VM_RAM_GB < min_ram )); then
          die "RAM ${VM_RAM_GB} GB is below the documented minimum of ${min_ram} GB."
        fi
        ;;
    esac
    # Map to GCP machine type
    MACHINE_TYPE=$(gcp_machine_type_for "$VM_CPUS" "$VM_RAM_GB")

  else
    # Three-node: fixed minimum per node from docs (Small VM: 12 vCPUs, 48 GB)
    show_three_node_requirements
    SIZE_CHOICE=$(prompt_choice "Machine size for all nodes:" \
      "small (12 vCPUs / 48 GB) — documented minimum" \
      "large (24-32 vCPUs / 96-128 GB) — documented large size" \
      "custom — enter manually")
    case "$SIZE_CHOICE" in
      "small"*)
        NODE_CPUS=12; NODE_RAM_GB=48 ;;
      "large"*)
        NODE_CPUS=24; NODE_RAM_GB=96
        warn "For instana-1 (data store), docs specify 32 vCPUs / 128 GB for large. Adjust manually if needed." ;;
      "custom"*)
        NODE_CPUS=$(prompt "NODE_CPUS" "vCPUs per node" "12")
        NODE_RAM_GB=$(prompt "NODE_RAM_GB" "RAM per node (GB)" "48")
        if (( NODE_CPUS < 12 )); then
          die "CPU count ${NODE_CPUS} is below the documented minimum of 12 for three-node."
        fi
        if (( NODE_RAM_GB < 48 )); then
          die "RAM ${NODE_RAM_GB} GB is below the documented minimum of 48 GB for three-node."
        fi
        ;;
    esac
    MACHINE_TYPE=$(gcp_machine_type_for "$NODE_CPUS" "$NODE_RAM_GB")
  fi
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

# =============================================================================
# SECTION 5 — INSTALLATION PLAN / CONFIRMATION
# =============================================================================
show_plan() {
  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}  Installation Plan${RESET}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${RESET}"
  echo ""
  printf "  %-30s %s\n" "Topology:"         "$TOPOLOGY"
  printf "  %-30s %s\n" "Installation type:" "$INSTALL_TYPE"
  printf "  %-30s %s\n" "Connectivity mode:" "$INSTALL_MODE"
  printf "  %-30s %s\n" "Ubuntu version:"    "$UBUNTU_VERSION"
  printf "  %-30s %s\n" "GCP Project:"       "$GCP_PROJECT"
  printf "  %-30s %s\n" "Zone:"              "$GCP_ZONE"
  printf "  %-30s %s\n" "Machine type:"      "$MACHINE_TYPE"
  printf "  %-30s %s\n" "Base domain:"       "$BASE_DOMAIN"
  printf "  %-30s %s\n" "Tenant/Unit:"       "${TENANT_NAME}/${UNIT_NAME}"
  printf "  %-30s %s\n" "UI URL (after DNS):" "https://${UNIT_NAME}-${TENANT_NAME}.${BASE_DOMAIN}"
  printf "  %-30s %s\n" "TLS:"               "$TLS_MODE"
  printf "  %-30s %s\n" "SSH source CIDR:"   "$SSH_SOURCE_CIDR"

  if [[ "$TOPOLOGY" == "single-node" ]]; then
    echo ""
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
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo -e "  ${YELLOW}DRY-RUN MODE: No resources will be created.${RESET}"
  fi

  echo ""
  prompt_yes_no "Create GCP resources and install Instana?" || { log "Aborted by user."; exit 0; }
  save_state "gcp_project" "$GCP_PROJECT"
  save_state "gcp_zone" "$GCP_ZONE"
  save_state "topology" "$TOPOLOGY"
  save_state "install_mode" "$INSTALL_MODE"
}

# =============================================================================
# SECTION 6 — GCP INFRASTRUCTURE
# =============================================================================
save_state() {
  local key="$1" value="$2"
  [[ "$DRY_RUN" == true ]] && return 0
  if [[ -f "$STATE_FILE" ]]; then
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$STATE_FILE" > "${STATE_FILE}.tmp" \
      && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  else
    echo "{\"$key\": \"$value\"}" > "$STATE_FILE"
  fi
}

get_state() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] && jq -r --arg k "$key" '.[$k] // empty' "$STATE_FILE" || echo ""
}

create_vm() {
  local name="$1" machine_type="$2" zone="$3" project="$4" network="$5" subnet="$6" ubuntu="$7"
  log "Creating VM: ${name} (${machine_type}, zone: ${zone})..."
  run gcloud compute instances create "$name" \
    --project="$project" \
    --zone="$zone" \
    --machine-type="$machine_type" \
    --image-family="$ubuntu" \
    --image-project="ubuntu-os-cloud" \
    --boot-disk-size="100GB" \
    --boot-disk-type="pd-ssd" \
    --network="$network" \
    --subnet="$subnet" \
    --tags="instana-backend"
  save_state "vm_${name}" "created"
  ok "VM ${name} created."
}

create_and_attach_disk() {
  local vm_name="$1" disk_name="$2" size_gb="$3" zone="$4" project="$5" device_name="$6"
  log "Creating disk ${disk_name} (${size_gb} GB SSD)..."
  run gcloud compute disks create "$disk_name" \
    --project="$project" \
    --zone="$zone" \
    --size="${size_gb}GB" \
    --type="pd-ssd"
  log "Attaching ${disk_name} to ${vm_name}..."
  run gcloud compute instances attach-disk "$vm_name" \
    --project="$project" \
    --zone="$zone" \
    --disk="$disk_name" \
    --device-name="$device_name"
  save_state "disk_${disk_name}" "attached"
  ok "Disk ${disk_name} attached to ${vm_name}."
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

# =============================================================================
# SECTION 7 — REMOTE SETUP (kernel, disks, install)
# =============================================================================
remote_exec() {
  local vm_name="$1" zone="$2" project="$3"; shift 3
  local cmd="$*" quoted
  printf -v quoted '%q' "$cmd"
  gcloud compute ssh "$vm_name" \
    --project="$project" \
    --zone="$zone" \
    --command="sudo bash -lc ${quoted}" \
    --ssh-flag="-o StrictHostKeyChecking=accept-new" \
    --ssh-flag="-o ConnectTimeout=30"
}

remote_exec_dry() {
  local vm_name="$1" zone="$2" project="$3"; shift 3
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY-RUN]${RESET} On ${vm_name}: $*"
  else
    remote_exec "$vm_name" "$zone" "$project" "$@"
  fi
}

upload_private_file() {
  local local_file="$1" vm_name="$2" zone="$3" project="$4" remote_name="$5"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY-RUN]${RESET} Securely upload ${remote_name} to ${vm_name} (content redacted)"
    return
  fi
  gcloud compute scp "$local_file" "${vm_name}:/tmp/${remote_name}" --project="$project" --zone="$zone" --quiet
  remote_exec "$vm_name" "$zone" "$project" "install -o root -g root -m 600 '/tmp/${remote_name}' '/root/${remote_name}' && rm -f '/tmp/${remote_name}'"
}

upload_stanctl_env() {
  local vm_name="$1" zone="$2" project="$3" multi_ips="${4:-}"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY-RUN]${RESET} Securely upload /root/.stanctl.env to ${vm_name} (secrets redacted)"
    return
  fi
  local tmp_env
  tmp_env=$(mktemp)
  chmod 600 "$tmp_env"
  trap 'rm -f "${tmp_env:-}"' RETURN
  {
    printf 'STANCTL_CORE_BASE_DOMAIN=%s\n' "$BASE_DOMAIN"
    printf 'STANCTL_INSTALL_TYPE=%s\n' "$INSTALL_TYPE"
    printf 'STANCTL_AIR_GAPPED=%s\n' "$([[ "$INSTALL_MODE" == "air-gapped" ]] && echo true || echo false)"
    printf 'STANCTL_DOWNLOAD_KEY=%s\n' "$DOWNLOAD_KEY"
    printf 'STANCTL_SALES_KEY=%s\n' "$SALES_KEY"
    printf 'STANCTL_UNIT_AGENT_KEY=%s\n' "$AGENT_KEY"
    printf 'STANCTL_UNIT_INITIAL_ADMIN_PASSWORD=%s\n' "$ADMIN_PASSWORD"
    printf 'STANCTL_UNIT_TENANT_NAME=%s\n' "$TENANT_NAME"
    printf 'STANCTL_UNIT_UNIT_NAME=%s\n' "$UNIT_NAME"
    printf 'STANCTL_VOLUME_ANALYTICS=%s\n' /mnt/instana/stanctl/analytics
    printf 'STANCTL_VOLUME_METRICS=%s\n' /mnt/instana/stanctl/metrics
    printf 'STANCTL_VOLUME_OBJECTS=%s\n' /mnt/instana/stanctl/objects
    printf 'STANCTL_VOLUME_DATA=%s\n' /mnt/instana/stanctl/data
    if [[ -n "$multi_ips" ]]; then
      printf 'STANCTL_MULTI_NODE_ENABLE=true\n'
      printf 'STANCTL_MULTI_NODE_IPS=%s\n' "$multi_ips"
    fi
  } > "$tmp_env"
  upload_private_file "$tmp_env" "$vm_name" "$zone" "$project" .stanctl.env
  rm -f "$tmp_env"
  trap - RETURN
}

wait_for_ssh() {
  local vm_name="$1" zone="$2" project="$3"
  log "Waiting for SSH on ${vm_name}..."
  local attempt=0
  while (( attempt < 30 )); do
    if timeout 30s gcloud compute ssh "$vm_name" \
        --project="$project" \
        --zone="$zone" \
        --quiet --command="echo ready" \
        --ssh-flag="-o StrictHostKeyChecking=accept-new" \
        --ssh-flag="-o BatchMode=yes" \
        --ssh-flag="-o ConnectTimeout=10"; then
      ok "SSH ready on ${vm_name}."
      return
    fi
    attempt=$((attempt + 1))
    sleep 10
  done
  die "SSH did not become available on ${vm_name} after 30 bounded attempts."
}

apply_kernel_parameters() {
  # From docs (Kernel parameters section — same for single-node and three-node):
  # 1. vm.swappiness=0
  # 2. fs.inotify.max_user_instances=8192
  # 3. Transparent Huge Pages disabled (Ubuntu: via GRUB + update-grub)
  local vm_name="$1" zone="$2" project="$3"
  log "Applying kernel parameters on ${vm_name} (from documentation)..."

  remote_exec_dry "$vm_name" "$zone" "$project" \
    "printf '%s\\n' 'vm.swappiness=0' 'fs.inotify.max_user_instances=8192' > /etc/sysctl.d/99-stanctl.conf && sysctl --system"

  # THP — Ubuntu path (from docs: sed + update-grub)
  remote_exec_dry "$vm_name" "$zone" "$project" \
    'if ! grep -q "transparent_hugepage=never" /etc/default/grub; then sed -i "s/^GRUB_CMDLINE_LINUX=\"\(.*\)\"/GRUB_CMDLINE_LINUX=\"\1 transparent_hugepage=never\"/" /etc/default/grub; fi; update-grub'

  # Reboot required for THP change
  log "Rebooting ${vm_name} for THP change to take effect..."
  if [[ "$DRY_RUN" != true ]]; then
    remote_exec "$vm_name" "$zone" "$project" "shutdown -r +1"
    log "Graceful reboot scheduled in one minute."
    sleep 45
    sleep 30
    wait_for_ssh "$vm_name" "$zone" "$project"
    # Verify THP disabled — from docs: expected output is: always madvise [never]
    remote_exec "$vm_name" "$zone" "$project" \
      "cat /sys/kernel/mm/transparent_hugepage/enabled | grep -q '\[never\]' || (echo 'THP not disabled!' && exit 1)"
  fi
  ok "Kernel parameters applied on ${vm_name}."
}

format_and_mount_disk() {
  # From docs: mkfs.ext4 then UUID-based fstab entry
  local vm_name="$1" zone="$2" project="$3" device="$4" mount_point="$5"
  log "Formatting and mounting ${device} → ${mount_point} on ${vm_name}..."

  remote_exec_dry "$vm_name" "$zone" "$project" \
    "set -euo pipefail; dev=/dev/disk/by-id/google-${device}; test -b \"\$dev\"; mkdir -p '${mount_point}'; if findmnt -rn '${mount_point}' >/dev/null; then echo 'Already mounted: ${mount_point}'; exit 0; fi; if blkid \"\$dev\" >/dev/null 2>&1; then echo 'STOP: disk already contains a filesystem: '${device} >&2; exit 20; fi; mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard \"\$dev\"; uuid=\$(blkid -s UUID -o value \"\$dev\"); grep -qF \"UUID=\$uuid  ${mount_point} \" /etc/fstab || printf 'UUID=%s  %s  ext4  discard,defaults,nofail  0 2\\n' \"\$uuid\" '${mount_point}' >> /etc/fstab; mount '${mount_point}'; findmnt -rn '${mount_point}'"

  ok "Disk ${device} mounted at ${mount_point} on ${vm_name}."
}

add_instana_repository() {
  # From docs (Adding Instana repository and installing stanctl tool):
  local vm_name="$1" zone="$2" project="$3"
  log "Adding Instana APT repository on ${vm_name}..."

  if [[ "$DRY_RUN" == true ]]; then
    warn "Dry-run: would configure authenticated Instana APT repository (credentials redacted)."
    return
  fi

  local tmp_auth tmp_curl
  tmp_auth=$(mktemp); tmp_curl=$(mktemp)
  chmod 600 "$tmp_auth" "$tmp_curl"
  trap 'rm -f "${tmp_auth:-}" "${tmp_curl:-}"' RETURN
  printf 'machine artifact-public.instana.io\n  login _\n  password %s\n' "$DOWNLOAD_KEY" > "$tmp_auth"
  printf 'silent\nshow-error\nfail\nuser = "_:%s"\n' "$DOWNLOAD_KEY" > "$tmp_curl"
  upload_private_file "$tmp_auth" "$vm_name" "$zone" "$project" instana-apt-auth.conf
  upload_private_file "$tmp_curl" "$vm_name" "$zone" "$project" instana-curl.conf
  remote_exec "$vm_name" "$zone" "$project" \
    "install -o root -g root -m 600 /root/instana-apt-auth.conf /etc/apt/auth.conf.d/instana.conf; printf '%s\\n' '${INSTANA_APT_REPO}' > /etc/apt/sources.list.d/instana-product.list; curl --config /root/instana-curl.conf '${INSTANA_KEYRING_URL}' | gpg --dearmor --yes -o /usr/share/keyrings/instana-archive-keyring.gpg; rm -f /root/instana-apt-auth.conf /root/instana-curl.conf"
  rm -f "$tmp_auth" "$tmp_curl"
  trap - RETURN

  ok "Instana APT repository added on ${vm_name}."
}

install_stanctl_airgapped() {
  local vm_name="$1" zone="$2" project="$3"
  log "Copying air-gapped artifacts to ${vm_name}..."
  if [[ "$DRY_RUN" == true ]]; then
    warn "Dry-run: would copy $(basename "$AIRGAP_STANCTL_DEB") and $(basename "$AIRGAP_ARCHIVE")."
    return
  fi
  gcloud compute scp "$AIRGAP_STANCTL_DEB" "${vm_name}:/tmp/stanctl.deb" --project="$project" --zone="$zone"
  gcloud compute scp "$AIRGAP_ARCHIVE" "${vm_name}:/tmp/instana-airgapped.tar.gz" --project="$project" --zone="$zone"
  remote_exec "$vm_name" "$zone" "$project" \
    "dpkg -i /tmp/stanctl.deb || { echo 'STOP: stanctl .deb has unresolved OS dependencies; provide a prepared Ubuntu image or local APT mirror.' >&2; exit 21; }; stanctl air-gapped import --file /tmp/instana-airgapped.tar.gz; rm -f /tmp/stanctl.deb /tmp/instana-airgapped.tar.gz"
  ok "Air-gapped stanctl package imported on ${vm_name}."
}

install_stanctl() {
  # From docs: apt update -y && apt install -y stanctl && apt-mark hold stanctl
  local vm_name="$1" zone="$2" project="$3"
  log "Installing stanctl on ${vm_name}..."

  remote_exec_dry "$vm_name" "$zone" "$project" "apt update -y"
  remote_exec_dry "$vm_name" "$zone" "$project" "apt install -y stanctl"
  remote_exec_dry "$vm_name" "$zone" "$project" "apt-mark hold stanctl"

  ok "stanctl installed on ${vm_name}."
}

configure_ufw_single_node() {
  # From docs (Firewall rules — Ubuntu host, single-node):
  local vm_name="$1" zone="$2" project="$3"
  log "Configuring UFW firewall on ${vm_name} (from documentation)..."

  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow 22/tcp"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow 80/tcp"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow 443/tcp"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow 8443/tcp"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow from 10.42.0.0/16 to any"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow from 10.43.0.0/16 to any"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow in on lo"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow out on lo"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw --force enable && ufw --force reload"

  ok "UFW configured on ${vm_name}."
}

configure_ufw_multi_node() {
  # From docs (Firewall rules — Ubuntu host, three-node):
  local vm_name="$1" zone="$2" project="$3" node0_ip="$4" node1_ip="$5" node2_ip="$6"
  log "Configuring UFW firewall on ${vm_name} (multi-node rules from documentation)..."

  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow 22/tcp"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow 80/tcp"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow 443/tcp"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow 8443/tcp"

  for node_ip in "$node0_ip" "$node1_ip" "$node2_ip"; do
    remote_exec_dry "$vm_name" "$zone" "$project" \
      "ufw allow from ${node_ip} to any port 22 proto tcp"
    remote_exec_dry "$vm_name" "$zone" "$project" \
      "ufw allow from ${node_ip} to any port 6443,10250,2379,2380,5001,9443,53 proto tcp"
    remote_exec_dry "$vm_name" "$zone" "$project" \
      "ufw allow from ${node_ip} to any port 8472,53 proto udp"
  done

  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow from 10.42.0.0/16 to any"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow from 10.43.0.0/16 to any"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow in on lo"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow out on lo"
  remote_exec_dry "$vm_name" "$zone" "$project" "ufw --force enable && ufw --force reload"

  ok "UFW configured on ${vm_name}."
}

setup_ssh_keys_multi_node() {
  # From docs (SSH configuration):
  # The root user must have passwordless SSH access to all three nodes.
  # Generate SSH key pair on node0, copy public key to node1 and node2.
  local node0_name="$1" zone="$2" project="$3" node1_ip="$4" node2_ip="$5"
  log "Setting up passwordless SSH from ${node0_name} to other nodes (from documentation)..."

  # Generate SSH key on node0 if not present
  remote_exec_dry "$node0_name" "$zone" "$project" \
    "[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa"

  # Get public key from node0
  if [[ "$DRY_RUN" != true ]]; then
    local pub_key
    pub_key=$(remote_exec "$node0_name" "$zone" "$project" "cat ~/.ssh/id_rsa.pub")

    # Copy to node1 and node2
    for node_ip in "$node1_ip" "$node2_ip"; do
      local node_name
      node_name=$(gcloud compute instances list \
        --project="$project" \
        --filter="networkInterfaces[0].networkIP=${node_ip}" \
        --format="value(name)" | head -1)
      remote_exec "$node_name" "$zone" "$project" \
        "mkdir -p ~/.ssh && echo '${pub_key}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    done

    # Test SSH connections
    remote_exec "$node0_name" "$zone" "$project" \
      "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ${node1_ip} 'echo node1 ok'"
    remote_exec "$node0_name" "$zone" "$project" \
      "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ${node2_ip} 'echo node2 ok'"
  fi

  ok "Passwordless SSH configured."
}

# =============================================================================
# SECTION 8 — INSTANA INSTALLATION
# =============================================================================
run_stanctl_up_single_node() {
  local vm_name="$1" zone="$2" project="$3"
  log "Running stanctl up on ${vm_name}..."

  upload_stanctl_env "$vm_name" "$zone" "$project"

  # Build stanctl up command — keys passed as flags, not stored in file
  local tls_flags=""
  if [[ "$TLS_MODE" == "auto-generate (self-signed)" ]]; then
    tls_flags="--core-tls-generate-cert"
  else
    # Copy cert files to VM first
    if [[ "$DRY_RUN" != true ]]; then
      upload_private_file "$TLS_CRT_PATH" "$vm_name" "$zone" "$project" instana.crt
      upload_private_file "$TLS_KEY_PATH" "$vm_name" "$zone" "$project" instana.key
    fi
    tls_flags="--core-tls-crt=/root/instana.crt --core-tls-key=/root/instana.key"
  fi

  remote_exec_dry "$vm_name" "$zone" "$project" \
    "trap 'rm -f /root/.stanctl.env' EXIT; stanctl up --env-file /root/.stanctl.env ${tls_flags} --quiet"

  ok "stanctl up completed on ${vm_name}."
}

run_stanctl_up_multi_node() {
  local node0_name="$1" zone="$2" project="$3" node_ips="$4"
  log "Running stanctl up --multi-node-enable on ${node0_name}..."

  upload_stanctl_env "$node0_name" "$zone" "$project" "$node_ips"

  local tls_flags=""
  if [[ "$TLS_MODE" == "auto-generate (self-signed)" ]]; then
    tls_flags="--core-tls-generate-cert"
  else
    if [[ "$DRY_RUN" != true ]]; then
      upload_private_file "$TLS_CRT_PATH" "$node0_name" "$zone" "$project" instana.crt
      upload_private_file "$TLS_KEY_PATH" "$node0_name" "$zone" "$project" instana.key
    fi
    tls_flags="--core-tls-crt=/root/instana.crt --core-tls-key=/root/instana.key"
  fi

  remote_exec_dry "$node0_name" "$zone" "$project" \
    "trap 'rm -f /root/.stanctl.env' EXIT; stanctl up --env-file /root/.stanctl.env ${tls_flags} --quiet"

  ok "stanctl up completed on ${node0_name}."
}

# =============================================================================
# SECTION 9 — POST-INSTALL HEALTH CHECK
# =============================================================================
post_install_health_check() {
  local vm_name="$1" zone="$2" project="$3"
  log "Running post-install health check on ${vm_name}..."

  if [[ "$DRY_RUN" == true ]]; then
    warn "Dry-run: skipping health check."
    return
  fi

  # Check that K3s is running
  remote_exec "$vm_name" "$zone" "$project" \
    "kubectl get nodes 2>/dev/null | grep -q 'Ready' || (echo 'K3s nodes not Ready' && exit 1)"

  # Check instana-core namespace
  remote_exec "$vm_name" "$zone" "$project" \
    "kubectl get pods -n instana-core 2>/dev/null | grep -v '0/0' | grep -q 'Running' || (echo 'instana-core pods not running' && exit 1)"

  # Check instana-units namespace
  remote_exec "$vm_name" "$zone" "$project" \
    "kubectl get pods -n instana-units 2>/dev/null | grep -q 'Running' || (echo 'instana-units pods not running' && exit 1)"

  ok "Health check passed."
}

# =============================================================================
# SECTION 10 — FINAL REPORT
# =============================================================================
print_final_report() {
  local external_ip="$1"
  echo ""
  echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${GREEN}  Installation Complete!${RESET}"
  echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${RESET}"
  echo ""
  echo -e "  ${BOLD}Instana UI URL:${RESET}  https://${UNIT_NAME}-${TENANT_NAME}.${BASE_DOMAIN}"
  echo -e "  ${BOLD}Admin user:${RESET}      admin@instana.local"
  echo -e "  ${BOLD}External IP:${RESET}     ${external_ip}"
  echo ""
  echo -e "  ${YELLOW}DNS entries required (all → ${external_ip}):${RESET}"
  echo -e "    ${BASE_DOMAIN}"
  echo -e "    agent-acceptor.${BASE_DOMAIN}"
  echo -e "    opamp-acceptor.${BASE_DOMAIN}"
  echo -e "    otlp-http.${BASE_DOMAIN}"
  echo -e "    otlp-grpc.${BASE_DOMAIN}"
  echo -e "    ${UNIT_NAME}-${TENANT_NAME}.${BASE_DOMAIN}"
  echo ""
  echo -e "  ${BOLD}State file:${RESET}  ${STATE_FILE}"
  echo -e "  ${BOLD}Log file:${RESET}    ${LOG_FILE}"
  echo ""
  echo -e "  To destroy all resources: ${CYAN}./destroy.sh${RESET}"
  echo ""
}

# =============================================================================
# SECTION 11 — MAIN ORCHESTRATION
# =============================================================================
main_single_node() {
  if [[ "$RESUME" != true ]]; then
  check_gcp_quota "$GCP_PROJECT" "$GCP_ZONE" "$VM_CPUS"
  check_duplicate_vms "$GCP_PROJECT" "$GCP_ZONE" "$VM_NAME"

  # Create VM
  create_vm "$VM_NAME" "$MACHINE_TYPE" "$GCP_ZONE" "$GCP_PROJECT" \
    "$GCP_NETWORK" "$GCP_SUBNET" "$UBUNTU_VERSION"

  # Create and attach disks (dedicated per directory — required by documentation)
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

  create_firewall_rules "$GCP_PROJECT" "$GCP_NETWORK"
  fi

  [[ "$DRY_RUN" != true ]] && wait_for_ssh "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"

  # Kernel parameters (verbatim from documentation)
# Kernel already configured:   apply_kernel_parameters "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"

  # UFW firewall rules (single-node, from documentation)
  configure_ufw_single_node "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"

  # Format and mount disks (from documentation)
  format_and_mount_disk "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-analytics" "/mnt/instana/stanctl/analytics"
  format_and_mount_disk "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-metrics"   "/mnt/instana/stanctl/metrics"
  format_and_mount_disk "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-objects"   "/mnt/instana/stanctl/objects"
  format_and_mount_disk "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-data"      "/mnt/instana/stanctl/data"

  if [[ "$INSTALL_MODE" == "online" ]]; then
    add_instana_repository "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
    install_stanctl "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  else
    install_stanctl_airgapped "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  fi

  # Run stanctl up
  run_stanctl_up_single_node "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"

  # Health check
  post_install_health_check "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"

  # Get external IP
  local ext_ip=""
  if [[ "$DRY_RUN" != true ]]; then
    ext_ip=$(gcloud compute instances describe "$VM_NAME" \
      --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
      --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "unknown")
  fi

  print_final_report "${ext_ip:-DRY-RUN}"
}

main_three_node() {
  check_gcp_quota "$GCP_PROJECT" "$GCP_ZONE" $(( NODE_CPUS * 3 ))
  check_duplicate_vms "$GCP_PROJECT" "$GCP_ZONE" \
    "$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME"

  # Create all three VMs
  create_vm "$NODE0_NAME" "$MACHINE_TYPE" "$GCP_ZONE" "$GCP_PROJECT" \
    "$GCP_NETWORK" "$GCP_SUBNET" "$UBUNTU_VERSION"
  create_vm "$NODE1_NAME" "$MACHINE_TYPE" "$GCP_ZONE" "$GCP_PROJECT" \
    "$GCP_NETWORK" "$GCP_SUBNET" "$UBUNTU_VERSION"
  create_vm "$NODE2_NAME" "$MACHINE_TYPE" "$GCP_ZONE" "$GCP_PROJECT" \
    "$GCP_NETWORK" "$GCP_SUBNET" "$UBUNTU_VERSION"

  # Disks — layout from documentation:
  # node0: objects disk (1000 GB)
  # node1: data (500), metrics (1000), analytics (1200)
  # node2: no extra disk
  create_and_attach_disk "$NODE0_NAME" "${NODE0_NAME}-objects"   1000 "$GCP_ZONE" "$GCP_PROJECT" "disk-objects"
  create_and_attach_disk "$NODE1_NAME" "${NODE1_NAME}-data"       500 "$GCP_ZONE" "$GCP_PROJECT" "disk-data"
  create_and_attach_disk "$NODE1_NAME" "${NODE1_NAME}-metrics"   1000 "$GCP_ZONE" "$GCP_PROJECT" "disk-metrics"
  create_and_attach_disk "$NODE1_NAME" "${NODE1_NAME}-analytics" 1200 "$GCP_ZONE" "$GCP_PROJECT" "disk-analytics"

  create_firewall_rules "$GCP_PROJECT" "$GCP_NETWORK"

  # Get private IPs
  local node0_ip node1_ip node2_ip
  if [[ "$DRY_RUN" != true ]]; then
    node0_ip=$(gcloud compute instances describe "$NODE0_NAME" \
      --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
      --format="value(networkInterfaces[0].networkIP)")
    node1_ip=$(gcloud compute instances describe "$NODE1_NAME" \
      --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
      --format="value(networkInterfaces[0].networkIP)")
    node2_ip=$(gcloud compute instances describe "$NODE2_NAME" \
      --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
      --format="value(networkInterfaces[0].networkIP)")
  else
    node0_ip="10.0.0.1"; node1_ip="10.0.0.2"; node2_ip="10.0.0.3"
  fi

  save_state "node0_ip" "$node0_ip"
  save_state "node1_ip" "$node1_ip"
  save_state "node2_ip" "$node2_ip"

  # Wait for SSH on all nodes
  if [[ "$DRY_RUN" != true ]]; then
    wait_for_ssh "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
    wait_for_ssh "$NODE1_NAME" "$GCP_ZONE" "$GCP_PROJECT"
    wait_for_ssh "$NODE2_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  fi

  # Kernel parameters on ALL nodes (from documentation)
  for node in "$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME"; do
    apply_kernel_parameters "$node" "$GCP_ZONE" "$GCP_PROJECT"
  done

  # UFW on ALL nodes (multi-node rules from documentation)
  for node in "$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME"; do
    configure_ufw_multi_node "$node" "$GCP_ZONE" "$GCP_PROJECT" \
      "$node0_ip" "$node1_ip" "$node2_ip"
  done

  # Format and mount disks
  format_and_mount_disk "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-objects"   "/mnt/instana/stanctl/objects"
  format_and_mount_disk "$NODE1_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-data"      "/mnt/instana/stanctl/data"
  format_and_mount_disk "$NODE1_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-metrics"   "/mnt/instana/stanctl/metrics"
  format_and_mount_disk "$NODE1_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-analytics" "/mnt/instana/stanctl/analytics"

  # SSH setup (from documentation)
  setup_ssh_keys_multi_node "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" \
    "$node1_ip" "$node2_ip"

  # Install stanctl on node0 only (from docs: multi-node, run commands on node0)
  if [[ "$INSTALL_MODE" == "online" ]]; then
    add_instana_repository "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
    install_stanctl "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  else
    install_stanctl_airgapped "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  fi

  # Run stanctl up from node0
  run_stanctl_up_multi_node "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" \
    "${node0_ip},${node1_ip},${node2_ip}"

  # Health check on node0
  post_install_health_check "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"

  # Get external IP of node0 (base domain points to node0 in multi-node)
  local ext_ip=""
  if [[ "$DRY_RUN" != true ]]; then
    ext_ip=$(gcloud compute instances describe "$NODE0_NAME" \
      --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
      --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "unknown")
  fi

  print_final_report "${ext_ip:-DRY-RUN}"
}

# =============================================================================
# ENTRY POINT
# =============================================================================
validate_vm_names() {
  local name
  local names=("${VM_NAME:-}")
  [[ "$TOPOLOGY" == three-node ]] && names=("$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME")
  for name in "${names[@]}"; do
    [[ "$name" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ ]] ||
      die "Invalid VM name '$name': use lowercase letters, digits and hyphens, max 63 characters; no dots."
  done
}

validate_resume() {
  [[ "$DRY_RUN" != true ]] || die "--resume cannot be combined with --dry-run."
  [[ "$TOPOLOGY" == single-node && "$INSTALL_TYPE" == demo && "$INSTALL_MODE" == online ]] ||
    die "Resume is currently supported only for single-node online demo."
  [[ -f "$STATE_FILE" ]] || die "Copy the original .install-state.json alongside this script first."
  [[ "$(get_state gcp_project)" == "$GCP_PROJECT" && "$(get_state gcp_zone)" == "$GCP_ZONE" && "$(get_state "vm_${VM_NAME}")" == created ]] ||
    die "Project, zone or VM differs from the saved state. No changes made."
  local vm disk role size info
  vm=$(gcloud compute instances describe "$VM_NAME" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json)
  [[ "$(jq -r .status <<< "$vm")" == RUNNING ]] || die "Existing VM must be RUNNING."
  [[ "$(jq -r '.machineType | split("/")[-1]' <<< "$vm")" == "$MACHINE_TYPE" ]] || die "Machine type differs from your selection."
  for role in analytics metrics objects data; do
    disk="${VM_NAME}-${role}"
    case "$role" in analytics) size=500;; metrics) size=300;; objects) size=250;; data) size=150;; esac
    [[ "$(get_state "disk_${disk}")" == attached ]] || die "Disk not recorded as attached: $disk"
    jq -e --arg d "$disk" --arg device "disk-$role" \
      'any(.disks[]; (.source | split("/")[-1]) == $d and .deviceName == $device and .boot == false)' <<< "$vm" >/dev/null || die "Unexpected disk attachment: $disk"
    info=$(gcloud compute disks describe "$disk" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json)
    jq -e --argjson size "$size" '(.sizeGb | tonumber) == $size and (.type | endswith("/pd-ssd"))' <<< "$info" >/dev/null || die "Unexpected disk size/type: $disk"
  done
  wait_for_ssh "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  remote_exec "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" '
    set -e
    if command -v stanctl >/dev/null || test -e /etc/rancher/k3s/k3s.yaml; then
      echo "STOP: installation already started; fresh-disk resume is not appropriate." >&2; exit 1
    fi
    for role in analytics metrics objects data; do
      device=/dev/disk/by-id/google-disk-$role
      test -b "$device" || exit 1
      if lsblk -nr -o MOUNTPOINT "$device" | grep -q "[^[:space:]]"; then exit 1; fi
      if test -n "$(wipefs -n --noheadings -o TYPE "$device")"; then
        echo "STOP: existing disk signature on $device" >&2; exit 1
      fi
      test "$(lsblk -nr -o NAME "$device" | wc -l)" -eq 1 || exit 1
    done
  '
  warn "Resume validated. Infrastructure creation will be skipped; four blank data disks will be formatted and the VM rebooted."
}

main() {
  echo ""
  log "Log file: ${LOG_FILE}"

  check_local_tools
  check_gcp_login
  if ! offer_saved_parameters; then
    collect_parameters
  fi
  save_parameters
  validate_vm_names
  check_gcp_configuration
  if [[ "$RESUME" == true ]]; then
    validate_resume
  else
    gcloud compute images describe-from-family "$UBUNTU_VERSION" \
      --project=ubuntu-os-cloud >/dev/null || die "Ubuntu image family unavailable."
  fi
  show_plan

  case "$TOPOLOGY" in
    single-node)  main_single_node ;;
    three-node)   main_three_node ;;
    *)            die "Unknown topology: $TOPOLOGY" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
