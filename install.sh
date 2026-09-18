#!/usr/bin/env bash
# =============================================================================
# Instana Standard Edition — GCP Deployment Script
# =============================================================================
# Source: IBM Instana Observability documentation (instana-observability-documentation.pdf)
# Internal lab installer. IBM requirements are mapped to GCP resources.
# Separate cloud disks do not prove physical storage isolation or performance.
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
AIRGAP_OUTPUT_DIR=""
SSH_SOURCE_CIDR=""
CONFIRMED_UI_IP=""
STANCTL_APT_VERSION=""
STANCTL_CLI_VERSION=""
BACKEND_VERSION=""

# ── Logging ───────────────────────────────────────────────────────────────────
log()  { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE"; }
die()  { err "$*"; declare -F progress_fail_current >/dev/null && progress_fail_current "$*"; exit 1; }
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
  for tool in gcloud jq ssh-keygen curl mktemp timeout flock; do
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
    read -rp "$(echo -e "${CYAN}?${RESET} ${prompt_text} [${default}]: ")" value || return 1
    echo "${value:-$default}"
  else
    read -rp "$(echo -e "${CYAN}?${RESET} ${prompt_text}: ")" value || return 1
    echo "$value"
  fi
}

prompt_secret() {
  local var_name="$1" prompt_text="$2"
  local value
  read -rsp "$(echo -e "${CYAN}?${RESET} ${prompt_text}: ")" value || { echo "" >&2; return 1; }
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
    read -rp "$(echo -e "${CYAN}  Select [1-${#options[@]}]:${RESET} ")" choice || return 1
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )) && break
    echo "Invalid selection." >&2
  done
  echo "${options[$((choice - 1))]}"
}

# Yes/no questions always show both answers and which one Enter selects,
# e.g. "[y/N]" = type y for yes, Enter or n for no.
prompt_yes_no() {
  local prompt_text="$1" default="${2:-N}"
  local answer hint
  if [[ "${default^^}" == Y ]]; then hint="[Y/n] (Enter = yes)"; else hint="[y/N] (Enter = no)"; fi
  while true; do
    read -rp "$(echo -e "${CYAN}?${RESET} ${prompt_text} ${hint}: ")" answer || return 1
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "  Please answer y (yes) or n (no)." >&2 ;;
    esac
  done
}

# ── Interactive input never aborts silently ──────────────────────────────────
# An empty answer or an invalid value re-asks the question. The installer only
# stops when the operator explicitly confirms the cancellation, or when stdin
# is closed (non-interactive run with no more input).
confirm_cancel() {
  local answer
  read -rp "$(echo -e "${YELLOW}!${RESET} No valid value entered. Cancel the installation? [y/N]: ")" answer ||
    die "Input ended before the parameters were complete; installation cancelled. Nothing was created."
  case "${answer,,}" in
    y|yes) die "Installation cancelled by the operator. Nothing was created." ;;
  esac
  echo "  Continuing; please answer the question again." >&2
}

# prompt_required VAR TEXT DEFAULT [VALIDATOR [LABEL]]
# Sets the variable VAR directly in the calling shell (no command substitution),
# so validators may print, set globals and call die normally. VALIDATOR is called
# as: VALIDATOR VALUE LABEL and must print its own error and return non-zero.
prompt_required() {
  local var_name="$1" prompt_text="$2" default="${3:-}" validator="${4:-}" label="${5:-}"
  local value
  while true; do
    value=$(prompt "$var_name" "$prompt_text" "$default") ||
      die "Input ended before the parameters were complete; installation cancelled. Nothing was created."
    if [[ -z "$value" ]]; then
      confirm_cancel
      continue
    fi
    if [[ -n "$validator" ]] && ! "$validator" "$value" "$label"; then
      confirm_cancel
      continue
    fi
    printf -v "$var_name" '%s' "$value"
    return 0
  done
}

# prompt_secret_required VAR TEXT LABEL — same contract, hidden input.
prompt_secret_required() {
  local var_name="$1" prompt_text="$2" label="$3"
  local value
  while true; do
    value=$(prompt_secret "$var_name" "$prompt_text") ||
      die "Input ended before the parameters were complete; installation cancelled. Nothing was created."
    if validate_secret "$value" "$label"; then
      printf -v "$var_name" '%s' "$value"
      return 0
    fi
    confirm_cancel
  done
}

validate_secret() {
  local value="$1" label="$2"
  [[ -n "$value" ]] || { err "${label} is required."; return 1; }
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || { err "${label} must not contain line breaks."; return 1; }
}

validate_tenant_unit_name() {
  # From docs: must match ^[a-z][a-z0-9]*$, max 15 chars, start with alpha, lowercase only
  local name="$1" label="$2"
  if ! [[ "$name" =~ ^[a-z][a-z0-9]*$ ]]; then
    err "${label} '${name}' is invalid. Must match ^[a-z][a-z0-9]*$ (lowercase alphanumeric, start with letter)"
    return 1
  fi
  if [[ ${#name} -gt 15 ]]; then
    err "${label} '${name}' exceeds 15 characters."
    return 1
  fi
}

validate_file_exists() {
  local path="$1" label="$2"
  [[ -f "$path" && ! -L "$path" ]] || { err "${label} not found or is a symlink: ${path}"; return 1; }
}

validate_gcp_project_id() {
  # https://cloud.google.com/resource-manager/docs/creating-managing-projects: 6-30 chars,
  # lowercase letters, digits, hyphens; starts with a letter; no trailing hyphen.
  local id="$1"
  [[ "$id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    { err "Invalid GCP Project ID '${id}': 6-30 lowercase letters, digits or hyphens, starting with a letter."; return 1; }
}

validate_fqdn() {
  local fqdn="$1"
  if ! [[ "$fqdn" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    err "Invalid FQDN: ${fqdn}"; return 1
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
  prompt_required "GCP_PROJECT" "GCP Project ID (from 'gcloud projects list')" "$(gcloud config get-value project 2>/dev/null || true)" validate_gcp_project_id
  prompt_required "GCP_REGION" "GCP Region" "us-central1"
  prompt_required "GCP_ZONE" "GCP Zone" "${GCP_REGION}-a"
  prompt_required "GCP_NETWORK" "VPC Network name" "default"
  prompt_required "GCP_SUBNET" "Subnet name" "default"
  prompt_required "SSH_SOURCE_CIDR" "CIDR allowed to SSH to the VM(s)" "$(detect_public_cidr)" validate_cidr
  if [[ "$TOPOLOGY" == "single-node" ]]; then
    prompt_required "VM_NAME" "VM name" "instana-backend"
  else
    prompt_required "NODE0_NAME" "Node 0 name (instana-0, backend)" "instana-0"
    prompt_required "NODE1_NAME" "Node 1 name (instana-1, data store)" "instana-1"
    prompt_required "NODE2_NAME" "Node 2 name (instana-2, other)" "instana-2"
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
  prompt_required "BASE_DOMAIN" "Base domain (e.g. instana.example.com)" "" validate_fqdn
  # Tenant / unit names
  prompt_required "TENANT_NAME" "Tenant name (max 15 chars, lowercase alphanumeric, start with letter)" "tenant0" validate_tenant_unit_name "Tenant name"
  prompt_required "UNIT_NAME" "Unit name (max 15 chars, lowercase alphanumeric, start with letter)" "unit0" validate_tenant_unit_name "Unit name"
  # Admin password
  echo ""
  log "Instana admin password (will not be stored in any file or log)"
  prompt_secret_required "ADMIN_PASSWORD" "Instana admin password" "Admin password"
  # Instana keys — never logged or stored in local state/logs
  echo ""
  log "Instana license keys (will not be stored in any file or log)"
  prompt_secret_required "DOWNLOAD_KEY" "Instana download key" "Download key"
  prompt_secret_required "SALES_KEY" "Instana sales key" "Sales key"
  prompt_secret_required "AGENT_KEY" "Instana agent key" "Agent key"
  if [[ "$INSTALL_MODE" == "air-gapped" ]]; then
    obtain_airgapped_archive
  fi

  # TLS certificate
  TLS_MODE=$(prompt_choice "TLS certificate:" \
    "auto-generate (self-signed)" \
    "provide custom certificate files")

  if [[ "$TLS_MODE" == "provide custom certificate files" ]]; then
    prompt_required "TLS_CRT_PATH" "Full path to TLS certificate file (.crt)" "" validate_file_exists "TLS certificate file"
    prompt_required "TLS_KEY_PATH" "Full path to TLS key file (.key)" "" validate_file_exists "TLS key file"
  fi
}

# run_with_read_progress FILE COMMAND... — runs COMMAND and, while it reads FILE,
# prints "NN% · elapsed" on one line so long single-pass reads of a multi-GB
# archive do not look hung. The position comes from /proc/<pid>/fdinfo of the
# process that has FILE open (tar's gzip child); without /proc only elapsed
# time is shown. Returns COMMAND's exit status.
run_with_read_progress() {
  local file="$1"; shift
  local total pid start pos pct elapsed fd link d
  total=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo 0)
  file=$(readlink -f "$file" 2>/dev/null || printf '%s' "$file")
  "$@" &
  pid=$!
  start=$SECONDS
  [[ -t 2 ]] || { wait "$pid"; return $?; }
  while kill -0 "$pid" 2>/dev/null; do
    pos=""
    if [[ -d /proc ]]; then
      for d in "$pid" $(pgrep -P "$pid" 2>/dev/null) $(pgrep -P "$pid" 2>/dev/null | xargs -r -n1 pgrep -P 2>/dev/null); do
        for fd in /proc/"$d"/fd/*; do
          link=$(readlink "$fd" 2>/dev/null) || continue
          if [[ "$link" == "$file" ]]; then
            pos=$(awk '/^pos:/{print $2}' "/proc/$d/fdinfo/${fd##*/}" 2>/dev/null)
            break 2
          fi
        done
      done
    fi
    elapsed=$(( SECONDS - start ))
    if [[ -n "$pos" && "$total" -gt 0 ]]; then
      pct=$(( pos * 100 / total ))
      printf '\r  reading archive: %3d%%  ·  %dm%02ds ' "$pct" $((elapsed/60)) $((elapsed%60)) >&2
    else
      printf '\r  reading archive ...  %dm%02ds ' $((elapsed/60)) $((elapsed%60)) >&2
    fi
    sleep 2
  done
  wait "$pid"; local rc=$?
  elapsed=$(( SECONDS - start ))
  printf '\r  reading archive: done in %dm%02ds          \n' $((elapsed/60)) $((elapsed%60)) >&2
  return $rc
}

# ── Air-gapped package: explain, locate, build or fall back ──────────────────
# IBM docs: the package is created on a bastion host with internet access by
# 'stanctl air-gapped package', then transferred to the Instana host. This
# machine can act as the bastion when it has internet, sudo and an APT-based OS.
explain_airgapped_package() {
  echo "" >&2
  echo -e "${BOLD}Air-gapped installation package${RESET}" >&2
  echo "  An air-gapped Instana host installs everything from one archive, instana-airgapped.tar.gz." >&2
  echo "  The archive is produced on a machine WITH internet access (the bastion host) by:" >&2
  echo "      stanctl air-gapped package --output-dir <directory>" >&2
  echo "  It contains the stanctl binary, the Instana container images, Helm charts, k3s and the" >&2
  echo "  license, pinned to one backend version. No separate stanctl .deb package is needed." >&2
  echo "  Size: several tens of GB; IBM requires at least 20-30 GB free in the output directory," >&2
  echo "  and creating it takes from several minutes to over an hour depending on bandwidth." >&2
  echo "  This installer can create the package here (this machine becomes the bastion) using the" >&2
  echo "  download and sales keys you entered, copy it to the Instana VM and import it there." >&2
  echo "" >&2
}

obtain_airgapped_archive() {
  local choice default
  explain_airgapped_package
  while true; do
    default=$(default_airgapped_archive)
    [[ -z "$default" ]] || log "Found an archive: ${default}"
    choice=$(prompt_choice "How do you want to provide the air-gapped package?" \
      "use an existing instana-airgapped.tar.gz on this machine" \
      "create the package now on this machine (needs internet, sudo and about 40 GB free)" \
      "switch to an ONLINE installation instead (the Instana VM downloads everything itself)" \
      "cancel the installation") || die "Input ended; installation cancelled. Nothing was created."
    case "$choice" in
      "use an existing"*)
        prompt_required "AIRGAP_ARCHIVE" "Local path to instana-airgapped.tar.gz" "$default" validate_file_exists "Air-gapped archive"
        # inspect_airgapped_archive sets BACKEND_VERSION / STANCTL_CLI_VERSION in this shell.
        inspect_airgapped_archive "$AIRGAP_ARCHIVE" && return 0
        warn "That archive cannot be used; choose again."
        ;;
      "create the package"*)
        if build_airgapped_package_locally; then
          inspect_airgapped_archive "$AIRGAP_ARCHIVE" && return 0
          warn "The created archive failed inspection; choose again."
        else
          warn "The package was not created; choose again."
        fi
        ;;
      "switch to an ONLINE"*)
        INSTALL_MODE="online"
        AIRGAP_ARCHIVE=""
        ok "Switched to an online installation. The Instana VM will use the Instana repository directly."
        return 0
        ;;
      *)
        die "Installation cancelled by the operator. Nothing was created."
        ;;
    esac
  done
}

# Installs stanctl on this machine from the authenticated Instana APT repository
# (IBM docs: "Adding Instana repository and installing stanctl tool") if it is
# missing, then runs 'stanctl air-gapped package'. Keys are passed through a
# root-only temporary env file, never on the command line.
# The management machine gets the same authenticated APT source as the Instana
# VM (IBM docs: "Adding Instana repository and installing stanctl tool").
configure_local_instana_repository() {
  local tmp_auth
  # gpg (gnupg) is needed for the repository keyring and is not on minimal images.
  if ! command -v gpg >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    log "Installing gnupg, curl and ca-certificates first..."
    sudo rm -f /etc/apt/sources.list.d/instana-product.list
    sudo apt-get update -qq && sudo apt-get install -y -qq gnupg curl ca-certificates ||
      { err "Could not install gnupg/curl on this machine."; return 1; }
  fi
  tmp_auth=$(mktemp); chmod 600 "$tmp_auth"
  printf 'machine artifact-public.instana.io\n  login _\n  password %s\n' "$DOWNLOAD_KEY" > "$tmp_auth"
  sudo install -o root -g root -m 600 "$tmp_auth" /etc/apt/auth.conf.d/instana.conf
  rm -f "$tmp_auth"
  # Keyring first, sources list only after it succeeds: a list without a key
  # breaks every later 'apt-get update' on this machine.
  # chmod 644: gpg may create the keyring as 0600 and APT verifies signatures as
  # the unprivileged _apt user, which then fails with "Permission denied".
  if ! curl -fsS -u "_:${DOWNLOAD_KEY}" "$INSTANA_KEYRING_URL" | sudo gpg --dearmor --yes -o /usr/share/keyrings/instana-archive-keyring.gpg ||
     ! sudo chmod 644 /usr/share/keyrings/instana-archive-keyring.gpg; then
    sudo rm -f /usr/share/keyrings/instana-archive-keyring.gpg /etc/apt/sources.list.d/instana-product.list
    err "Could not download the Instana repository key; check the download key."
    return 1
  fi
  printf '%s\n' "$INSTANA_APT_REPO" | sudo tee /etc/apt/sources.list.d/instana-product.list >/dev/null
  if ! sudo apt-get update -qq; then
    sudo rm -f /etc/apt/sources.list.d/instana-product.list
    err "apt-get update failed with the Instana repository; the repository entry was removed again."
    return 1
  fi
  ok "Instana APT repository configured on this machine."
}

# Same rule as on the Instana VM: an exact stanctl package version is chosen,
# installed and held. The archive is later packaged by exactly this CLI.
select_and_install_local_stanctl() {
  local installed selected
  local -a stanctl_versions
  mapfile -t stanctl_versions < <(apt-cache madison stanctl 2>/dev/null | awk '{print $3}' | sed '/^$/d' | sort -Vu -r | grep -E '^[0-9]+([:.+~_-]?[0-9A-Za-z]+)*$' | awk '!seen[$0]++')
  (( ${#stanctl_versions[@]} > 0 )) || { err "The Instana repository returned no installable stanctl versions."; return 1; }
  installed=$(dpkg-query -W -f='${Version}' stanctl 2>/dev/null || true)
  echo "" >&2
  echo -e "${BOLD}Available stanctl package versions (newest first)${RESET}${installed:+; currently installed: ${installed}}:" >&2
  selected=$(prompt_choice "Select the exact stanctl version for the air-gapped package:" "${stanctl_versions[@]}") ||
    { err "stanctl version selection was cancelled."; return 1; }
  if [[ "$installed" != "$selected" ]]; then
    log "Installing stanctl ${selected} on this machine..."
    sudo apt-mark unhold stanctl >/dev/null 2>&1 || true
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "stanctl=${selected}"; then
      err "stanctl ${selected} could not be installed on this machine."
      return 1
    fi
  fi
  sudo apt-mark hold stanctl >/dev/null 2>&1 || true
  installed=$(dpkg-query -W -f='${Version}' stanctl 2>/dev/null || true)
  [[ "$installed" == "$selected" ]] || { err "Installed stanctl ${installed} does not match selected ${selected}."; return 1; }
  STANCTL_APT_VERSION="$selected"
  STANCTL_CLI_VERSION=$(stanctl --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([.+~-][0-9A-Za-z.-]+)?' | head -1 || true)
  [[ -n "$STANCTL_CLI_VERSION" ]] || { err "Could not parse 'stanctl --version' output."; return 1; }
  ok "stanctl on this machine: package ${STANCTL_APT_VERSION} (CLI ${STANCTL_CLI_VERSION}), held."
}

# The installed CLI reports the backend versions it supports; the operator
# picks one and it is pinned into the package (--instana-version).
select_local_backend_version() {
  local tmp_key raw_backends selected
  local -a backend_versions
  tmp_key=$(mktemp); chmod 600 "$tmp_key"
  printf 'STANCTL_DOWNLOAD_KEY=%s\n' "$DOWNLOAD_KEY" > "$tmp_key"
  raw_backends=$(stanctl versions identify --env-file "$tmp_key" --quiet 2>/dev/null)
  rm -f "$tmp_key"
  mapfile -t backend_versions < <(printf '%s\n' "$raw_backends" | sed -nE 's/^[[:space:]]*-[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+[-.+~][0-9A-Za-z.-]+)[[:space:]]*$/\1/p' | awk '!seen[$0]++')
  (( ${#backend_versions[@]} > 0 )) ||
    { err "stanctl ${STANCTL_CLI_VERSION} returned no supported backend versions (check the download key)."; return 1; }
  echo "" >&2
  echo -e "${BOLD}Backend versions supported by stanctl ${STANCTL_CLI_VERSION}:${RESET}" >&2
  selected=$(prompt_choice "Select the exact Instana backend version to package:" "${backend_versions[@]}") ||
    { err "Backend version selection was cancelled."; return 1; }
  BACKEND_VERSION="$selected"
  ok "Package will pin: stanctl ${STANCTL_CLI_VERSION} → backend ${BACKEND_VERSION}"
}

build_airgapped_package_locally() {
  local out_dir free_gb tmp_env tmp_auth os_id
  os_id=$(. /etc/os-release 2>/dev/null && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")
  [[ "$os_id" == *ubuntu* || "$os_id" == *debian* ]] ||
    { err "This machine is not Ubuntu/Debian; stanctl is installed from an APT repository. Create the package on an Ubuntu bastion host."; return 1; }
  command -v sudo >/dev/null 2>&1 || { err "sudo is required to install stanctl on this machine."; return 1; }
  # Reachability only: any HTTP status counts (the root URL answers 4xx/3xx
  # without credentials); 000 means no connection at all.
  local http_code
  http_code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' https://artifact-public.instana.io/ 2>/dev/null || true)
  if [[ -z "$http_code" || "$http_code" == 000 ]]; then
    err "artifact-public.instana.io is not reachable from this machine (no HTTP response); the package cannot be created here."
    return 1
  fi
  log "artifact-public.instana.io reachable (HTTP ${http_code})."
  # Output directory: IBM requires 20-30 GB free where the package is created.
  # Below 20 GB the download would fail part-way, so the directory is re-asked.
  while true; do
    prompt_required "AIRGAP_OUTPUT_DIR" "Directory for the package (will be created)" "${HOME}/instana-airgap"
    out_dir="$AIRGAP_OUTPUT_DIR"
    mkdir -p "$out_dir" || { err "Cannot create ${out_dir}."; confirm_cancel; continue; }
    free_gb=$(df -Pk "$out_dir" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')
    log "Free space in ${out_dir}: ${free_gb:-?} GB (IBM: at least 20-30 GB for the package)."
    if [[ -n "$free_gb" ]] && (( free_gb < 20 )); then
      err "Not enough space in ${out_dir}: ${free_gb} GB free, the package needs 20-30 GB."
      echo "  Options: choose a directory on a larger disk, free space, or enlarge this VM's disk, e.g." >&2
      echo "    gcloud compute disks resize <boot-disk> --size=100GB --zone=<zone>   (then: sudo growpart /dev/sda 1 && sudo resize2fs /dev/sda1)" >&2
      prompt_yes_no "Choose another directory?" Y || return 1
      continue
    fi
    if [[ -n "$free_gb" ]] && (( free_gb < 40 )); then
      prompt_yes_no "Between 20 and 40 GB free; the package may still not fit. Continue anyway?" N || { prompt_yes_no "Choose another directory?" Y || return 1; continue; }
    fi
    break
  done
  echo "" >&2
  echo "  Next steps on THIS machine: add the Instana APT repository, let you pick the exact stanctl and" >&2
  echo "  backend versions, then run 'stanctl air-gapped package' into ${out_dir} (long download)." >&2
  prompt_yes_no "Type y to start creating the package now, or n to go back to the menu" N ||
    { warn "Package creation skipped."; return 1; }

  configure_local_instana_repository || return 1
  select_and_install_local_stanctl || return 1
  select_local_backend_version || return 1

  tmp_env=$(mktemp); chmod 600 "$tmp_env"
  printf 'STANCTL_DOWNLOAD_KEY=%s\nSTANCTL_SALES_KEY=%s\nSTANCTL_INSTANA_VERSION=%s\n' "$DOWNLOAD_KEY" "$SALES_KEY" "$BACKEND_VERSION" > "$tmp_env"
  log "Creating the air-gapped package in ${out_dir}: stanctl ${STANCTL_CLI_VERSION} → backend ${BACKEND_VERSION}."
  log "This downloads several tens of GB; do not interrupt it."
  # Long downloads can drop ("unexpected EOF"). stanctl keeps already exported
  # images in <out_dir>/airgapped/docker and skips them on the next run, so a
  # retry only fetches what is missing.
  local attempt=1 max_attempts=3 packaged=false
  while (( attempt <= max_attempts )); do
    if stanctl air-gapped package --env-file "$tmp_env" --output-dir "$out_dir"; then
      packaged=true
      break
    fi
    if (( attempt < max_attempts )); then
      warn "'stanctl air-gapped package' failed (attempt ${attempt}/${max_attempts}). Retrying in 30 s; already downloaded images are reused."
      sleep 30
    fi
    (( attempt++ ))
  done
  rm -f "$tmp_env"
  if [[ "$packaged" != true ]]; then
    err "'stanctl air-gapped package' failed ${max_attempts} times; see its output above. Choosing option 2 again resumes from the images already downloaded."
    return 1
  fi
  AIRGAP_ARCHIVE="${out_dir}/instana-airgapped.tar.gz"
  [[ -f "$AIRGAP_ARCHIVE" ]] || { err "Expected ${AIRGAP_ARCHIVE} was not produced."; return 1; }
  ok "Package created: ${AIRGAP_ARCHIVE}"
}

# Default for the air-gapped archive prompt: the only instana-airgapped.tar.gz
# found in the current directory, the script folder or the home directory.
default_airgapped_archive() {
  local candidate
  for candidate in "$PWD/instana-airgapped.tar.gz" "$SCRIPT_DIR/instana-airgapped.tar.gz" \
                   "$HOME/instana-airgapped.tar.gz" "$HOME/instana-airgap/instana-airgapped.tar.gz"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 0
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
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] ||
    { err "Invalid IPv4 CIDR: ${cidr}"; return 1; }
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
        collect_cpu_ram VM_CPUS VM_RAM_GB "$min_cpu" "$min_ram" "single-node $INSTALL_TYPE"
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
        collect_cpu_ram NODE_CPUS NODE_RAM_GB 12 48 "three-node (per node)"
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
  echo -e "  ${BOLD}${YELLOW}CONFIRMATION REQUIRED${RESET}"
  if [[ "$DRY_RUN" == true ]]; then
    echo "  Enter Y and press Enter to run the dry-run simulation."
  else
    echo "  Enter Y and press Enter to START creating GCP resources and installing Instana."
  fi
  echo "  Enter N, or press Enter without typing anything, to cancel without starting."
  echo ""
  prompt_yes_no "Start now? Type Y to continue or N to cancel" N || { log "Installation was not started; no action was approved from this plan."; exit 0; }
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
  [[ ! -L "$STATE_FILE" ]] || die "Unsafe state symlink."
  [[ ! -f "$STATE_FILE" || -O "$STATE_FILE" ]] || die "Unexpected state ownership."
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

create_vm_once() {
  local name="$1" machine_type="$2" zone="$3" project="$4" network="$5" subnet="$6" ubuntu="$7"
  log "Creating VM: ${name} (${machine_type}, zone: ${zone})..."
  local metadata_args=()
  local label_args=()
  [[ "$TOPOLOGY" == three-node && "$INSTALL_MODE" == online ]] && metadata_args=(--metadata=enable-oslogin=false)
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
    die "Disk ${disk_name} has an unexpected size, type, or state; expected ${size_gb} GB pd-ssd in READY state. It was not adopted, attached, formatted, or deleted."
  users=$(jq -r '.users[]? // empty' <<< "$info")
  [[ -z "$users" || "$users" == */instances/"$vm_name" ]] || die "Disk ${disk_name} is attached to a different VM; no changes made."

  if [[ "$adoption_required" == true ]]; then
    prompt_yes_no "Validated ${size_gb} GB READY pd-ssd disk with no foreign attachment. Adopt it only if it belongs to this interrupted deployment? It will never be automatically deleted or reformatted when non-blank." N ||
      die "Existing disk was not adopted. Use another deployment name or inspect it manually; no changes were made."
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
    [[ -z "$(get_state "vm_${name}")" ]] || die "VM ${name} is recorded in state but no longer exists. Automatic replacement is refused."
    create_vm "$@"
    return
  fi
  recorded=$(get_state "vm_${name}")
  [[ "$recorded" == created ]] || die "VM '${name}' already exists but is not owned by this saved installation."
  jq -e --arg machine "$machine_type" --arg network "$network" --arg subnet "$subnet" \
    '.status=="RUNNING" and (.machineType|endswith("/"+$machine)) and
     (.networkInterfaces[0].network|endswith("/"+$network)) and
     (.networkInterfaces[0].subnetwork|endswith("/"+$subnet))' <<< "$info" >/dev/null ||
    die "Existing VM ${name} does not match the saved machine type, network, subnet, or RUNNING state."
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

remote_user_exec() {
  local vm_name="$1" zone="$2" project="$3"; shift 3
  local cmd="$*"
  gcloud compute ssh "$vm_name" \
    --project="$project" \
    --zone="$zone" \
    --command="$cmd" \
    --ssh-flag="-o StrictHostKeyChecking=accept-new" \
    --ssh-flag="-o ConnectTimeout=30"
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
  local inspection status fstype uuid
  log "Formatting and mounting ${device} → ${mount_point} on ${vm_name}..."

  if [[ "$DRY_RUN" == true ]]; then
    remote_exec_dry "$vm_name" "$zone" "$project" \
      "Inspect ${device}; format only if blank; otherwise require verified empty ext4 and explicit adoption; mount at ${mount_point} by UUID"
    ok "Disk ${device} mount workflow simulated for ${mount_point} on ${vm_name}."
    return 0
  fi

  inspection=$(remote_exec "$vm_name" "$zone" "$project" \
    "set -euo pipefail
dev=/dev/disk/by-id/google-${device}
target='${mount_point}'
test -b \"\$dev\"
mkdir -p \"\$target\"
if findmnt -rn -M \"\$target\" >/dev/null; then
  source=\$(findmnt -rn -M \"\$target\" -o SOURCE)
  fstype=\$(findmnt -rn -M \"\$target\" -o FSTYPE)
  test \"\$(readlink -f \"\$source\")\" = \"\$(readlink -f \"\$dev\")\"
  test \"\$fstype\" = ext4
  uuid=\$(blkid -s UUID -o value \"\$dev\")
  printf 'MOUNTED:ext4:%s\\n' \"\$uuid\"
  exit 0
fi
if ! blkid \"\$dev\" >/dev/null 2>&1; then
  echo BLANK
  exit 0
fi
fstype=\$(blkid -s TYPE -o value \"\$dev\")
uuid=\$(blkid -s UUID -o value \"\$dev\")
test \"\$fstype\" = ext4 || { printf 'UNSUPPORTED:%s:%s\\n' \"\$fstype\" \"\$uuid\"; exit 0; }
probe=\$(mktemp -d)
cleanup() { mountpoint -q \"\$probe\" && umount \"\$probe\"; rmdir \"\$probe\"; }
trap cleanup EXIT
mount -o ro,noload \"\$dev\" \"\$probe\"
if find \"\$probe\" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit | grep -q .; then
  printf 'EXISTING_NONEMPTY:ext4:%s\\n' \"\$uuid\"
else
  printf 'EXISTING_EMPTY:ext4:%s\\n' \"\$uuid\"
fi") || die "Could not safely inspect ${device}; it was not formatted or mounted."

  status=$(tail -n 1 <<< "$inspection")
  case "$status" in
    MOUNTED:ext4:*)
      uuid=${status##*:}
      remote_exec "$vm_name" "$zone" "$project" \
        "grep -qF 'UUID=$uuid  ${mount_point} ' /etc/fstab || printf 'UUID=%s  %s  ext4  discard,defaults,nofail  0 2\\n' '$uuid' '${mount_point}' >> /etc/fstab; findmnt -rn -M '${mount_point}'"
      phase_detail done "Existing verified mount ${device} → ${mount_point} retained."
      ;;
    BLANK)
      remote_exec "$vm_name" "$zone" "$project" \
        "set -euo pipefail; dev=/dev/disk/by-id/google-${device}; mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard \"\$dev\"; uuid=\$(blkid -s UUID -o value \"\$dev\"); grep -qF \"UUID=\$uuid  ${mount_point} \" /etc/fstab || printf 'UUID=%s  %s  ext4  discard,defaults,nofail  0 2\\n' \"\$uuid\" '${mount_point}' >> /etc/fstab; mount '${mount_point}'; findmnt -rn -M '${mount_point}'"
      ;;
    EXISTING_EMPTY:ext4:*)
      uuid=${status##*:}
      warn "${device} already contains an empty ext4 filesystem (UUID ${uuid}); it was inspected read-only."
      prompt_yes_no "Reuse this empty filesystem only if it was created by this interrupted deployment? No formatting will occur." N ||
        die "Existing filesystem was not adopted; ${device} remains unchanged."
      remote_exec "$vm_name" "$zone" "$project" \
        "set -euo pipefail; grep -qF 'UUID=$uuid  ${mount_point} ' /etc/fstab || printf 'UUID=%s  %s  ext4  discard,defaults,nofail  0 2\\n' '$uuid' '${mount_point}' >> /etc/fstab; mount '${mount_point}'; findmnt -rn -M '${mount_point}'"
      phase_detail done "Adopted empty ext4 filesystem without formatting: ${device} → ${mount_point}."
      ;;
    EXISTING_NONEMPTY:ext4:*)
      die "${device} contains files from an existing filesystem. It was inspected read-only and will not be adopted, formatted, or changed."
      ;;
    UNSUPPORTED:*)
      fstype=$(cut -d: -f2 <<< "$status")
      die "${device} contains unsupported filesystem '${fstype}'. It will not be adopted, formatted, or changed."
      ;;
    *)
      die "Unexpected filesystem inspection result for ${device}; no change was made."
      ;;
  esac

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
    "install -o root -g root -m 600 /root/instana-apt-auth.conf /etc/apt/auth.conf.d/instana.conf; printf '%s\\n' '${INSTANA_APT_REPO}' > /etc/apt/sources.list.d/instana-product.list; curl --config /root/instana-curl.conf '${INSTANA_KEYRING_URL}' | gpg --dearmor --yes -o /usr/share/keyrings/instana-archive-keyring.gpg; chmod 644 /usr/share/keyrings/instana-archive-keyring.gpg; rm -f /root/instana-apt-auth.conf /root/instana-curl.conf"
  rm -f "$tmp_auth" "$tmp_curl"
  trap - RETURN

  ok "Instana APT repository added on ${vm_name}."
}

# IBM docs (Installing Standard Edition in an air-gapped environment): the
# package produced by 'stanctl air-gapped package' on the bastion host carries
# the stanctl binary (airgapped/stanctl), the pinned Instana backend version
# (airgapped/config/instana.yaml) and the stanctl build metadata
# (airgapped/buildmeta/buildmeta.yaml). The archive is inspected locally so the
# operator sees the exact versions in the plan before anything is copied.
inspect_airgapped_archive() {
  # Returns 1 (after printing the reason) so the operator can correct the path.
  local archive="$1" instana_yaml buildmeta_yaml
  [[ -n "$archive" ]] || { err "Air-gapped archive path is required."; return 1; }
  [[ -f "$archive" && ! -L "$archive" ]] || { err "Air-gapped archive not found or is a symlink: ${archive}"; return 1; }
  command -v tar >/dev/null 2>&1 || { err "tar is required to inspect the air-gapped archive."; return 1; }
  log "Inspecting air-gapped archive $(basename "$archive") ($(du -h "$archive" 2>/dev/null | cut -f1 || echo '?'), one pass through the archive, a few minutes)..."
  # One pass: extract only the three small members. gzip cannot be seeked, so the
  # whole archive is read once; listing and extracting separately would triple that.
  local tmp_dir
  tmp_dir=$(mktemp -d) || { err "Cannot create a temporary directory."; return 1; }
  if ! run_with_read_progress "$archive" tar -xzf "$archive" -C "$tmp_dir" airgapped/stanctl airgapped/config/instana.yaml airgapped/buildmeta/buildmeta.yaml 2>"$tmp_dir/tar.err"; then
    if grep -q "Not found in archive" "$tmp_dir/tar.err"; then
      err "Archive is missing $(grep -o 'airgapped/[^:]*' "$tmp_dir/tar.err" | sort -u | tr '\n' ' '); it was not created by 'stanctl air-gapped package' or is incomplete."
    else
      err "Cannot read ${archive}; expected a gzip tar created by 'stanctl air-gapped package'. $(head -1 "$tmp_dir/tar.err")"
    fi
    rm -rf "$tmp_dir"; return 1
  fi
  [[ -s "$tmp_dir/airgapped/stanctl" ]] || { err "airgapped/stanctl in the archive is empty."; rm -rf "$tmp_dir"; return 1; }
  instana_yaml=$(cat "$tmp_dir/airgapped/config/instana.yaml")
  buildmeta_yaml=$(cat "$tmp_dir/airgapped/buildmeta/buildmeta.yaml")
  rm -rf "$tmp_dir"
  BACKEND_VERSION=$(sed -nE 's/^instana-version:[[:space:]]*"?([^"[:space:]]+)"?.*$/\1/p' <<< "$instana_yaml" | head -1)
  STANCTL_CLI_VERSION=$(sed -nE 's/^version:[[:space:]]*"?v?([^"[:space:]]+)"?.*$/\1/p' <<< "$buildmeta_yaml" | head -1)
  [[ -n "$BACKEND_VERSION" ]] || { err "airgapped/config/instana.yaml does not declare instana-version."; return 1; }
  [[ -n "$STANCTL_CLI_VERSION" ]] || { err "airgapped/buildmeta/buildmeta.yaml does not declare the stanctl version."; return 1; }
  ok "Air-gapped package: stanctl ${STANCTL_CLI_VERSION} → Instana backend ${BACKEND_VERSION}"
}

install_stanctl_airgapped() {
  local vm_name="$1" zone="$2" project="$3"
  log "Copying air-gapped package to ${vm_name}..."
  if [[ "$DRY_RUN" == true ]]; then
    warn "Dry-run: would copy $(basename "$AIRGAP_ARCHIVE"), extract stanctl ${STANCTL_CLI_VERSION} from it and import backend ${BACKEND_VERSION}."
    return
  fi
  gcloud compute scp "$AIRGAP_ARCHIVE" "${vm_name}:/tmp/instana-airgapped.tar.gz" --project="$project" --zone="$zone"
  # Documented sequence: extract the bundled stanctl binary to /usr/local/bin,
  # then import the package. The archive stays until import succeeds so a
  # failed import can be retried without another transfer.
  remote_exec "$vm_name" "$zone" "$project" \
    "set -e; tar -xzf /tmp/instana-airgapped.tar.gz -C /usr/local/bin --strip-components 1 airgapped/stanctl; chmod 0755 /usr/local/bin/stanctl; hash -r; stanctl --version; stanctl air-gapped import --file /tmp/instana-airgapped.tar.gz; rm -f /tmp/instana-airgapped.tar.gz" ||
    die "Air-gapped import failed on ${vm_name}; the archive remains in /tmp on the VM for inspection."
  local cli_output
  cli_output=$(remote_exec "$vm_name" "$zone" "$project" "stanctl --version" 2>/dev/null || true)
  grep -Fq "$STANCTL_CLI_VERSION" <<< "$cli_output" ||
    die "Installed stanctl reports '${cli_output}', expected ${STANCTL_CLI_VERSION} from the archive build metadata."
  save_state stanctl_cli_version "$STANCTL_CLI_VERSION"
  save_state backend_version "$BACKEND_VERSION"
  phase_detail done "Imported air-gapped package: stanctl ${STANCTL_CLI_VERSION} → backend ${BACKEND_VERSION}"
  ok "Air-gapped stanctl package imported on ${vm_name}."
}

install_stanctl() {
  # IBM docs: install an exact stanctl package and hold it. The installed CLI
  # then queries IBM release metadata for backend versions compatible with it.
  local vm_name="$1" zone="$2" project="$3"
  local raw_versions raw_backends selected saved installed cli_output tmp_key
  local -a stanctl_versions backend_versions
  log "Selecting and installing an exact stanctl version on ${vm_name}..."

  remote_exec_dry "$vm_name" "$zone" "$project" "apt update -y"

  if [[ "$DRY_RUN" == true ]]; then
    phase_detail active "Would list authenticated APT versions, install one exact stanctl version, and hold it."
    phase_detail active "Would run 'stanctl versions identify' and require selection of a compatible full backend version."
    STANCTL_APT_VERSION="DRY-RUN-SELECTION"
    BACKEND_VERSION="DRY-RUN-COMPATIBLE-SELECTION"
    return 0
  fi

  raw_versions=$(remote_exec "$vm_name" "$zone" "$project" \
    "apt-cache madison stanctl | awk '{print \$3}' | sed '/^$/d' | sort -Vu -r") ||
    die "Cannot retrieve stanctl package versions from the authenticated Instana repository."
  mapfile -t stanctl_versions < <(printf '%s\n' "$raw_versions" | grep -E '^[0-9]+([:.+~_-]?[0-9A-Za-z]+)*$' | awk '!seen[$0]++')
  (( ${#stanctl_versions[@]} > 0 )) || die "The Instana repository returned no installable stanctl versions."

  saved=$(get_state stanctl_apt_version)
  if [[ -n "$saved" ]]; then
    printf '%s\n' "${stanctl_versions[@]}" | grep -Fxq "$saved" ||
      die "Saved stanctl version ${saved} is no longer available from the configured repository."
    selected="$saved"
    phase_detail done "Reusing saved stanctl package selection: ${selected}"
  else
    echo ""
    echo -e "${BOLD}Available stanctl package versions (newest first):${RESET}" >&2
    selected=$(prompt_choice "Select the exact stanctl version to install:" "${stanctl_versions[@]}") ||
      die "stanctl version selection was cancelled."
  fi
  STANCTL_APT_VERSION="$selected"

  installed=$(remote_exec "$vm_name" "$zone" "$project" "dpkg-query -W -f='\${Version}' stanctl 2>/dev/null || true")
  if [[ "$installed" != "$STANCTL_APT_VERSION" ]]; then
    remote_exec "$vm_name" "$zone" "$project" \
      "apt-mark unhold stanctl >/dev/null 2>&1 || true; if ! DEBIAN_FRONTEND=noninteractive apt-get install -y 'stanctl=$STANCTL_APT_VERSION'; then apt-mark hold stanctl >/dev/null 2>&1 || true; exit 1; fi; apt-mark hold stanctl"
  else
    remote_exec "$vm_name" "$zone" "$project" "apt-mark hold stanctl"
  fi
  installed=$(remote_exec "$vm_name" "$zone" "$project" "dpkg-query -W -f='\${Version}' stanctl")
  [[ "$installed" == "$STANCTL_APT_VERSION" ]] ||
    die "Installed stanctl package ${installed} does not match selected ${STANCTL_APT_VERSION}."
  cli_output=$(remote_exec "$vm_name" "$zone" "$project" "stanctl --version") || die "Installed stanctl cannot report its version."
  STANCTL_CLI_VERSION=$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([.+~-][0-9A-Za-z.-]+)?' <<< "$cli_output" | head -1 || true)
  [[ -n "$STANCTL_CLI_VERSION" ]] || die "Could not parse 'stanctl --version' output; no backend selection attempted."
  remote_exec "$vm_name" "$zone" "$project" \
    "dpkg --compare-versions '$STANCTL_CLI_VERSION' ge '1.10.4' || { echo 'Online lifecycle operations require stanctl 1.10.4 or later.' >&2; exit 24; }" ||
    die "Installed stanctl CLI ${STANCTL_CLI_VERSION} is unsafe for online lifecycle operations; rerun and choose 1.10.4 or later."
  save_state stanctl_apt_version "$STANCTL_APT_VERSION"
  save_state stanctl_cli_version "$STANCTL_CLI_VERSION"
  phase_detail done "Verified stanctl package ${STANCTL_APT_VERSION} (CLI ${STANCTL_CLI_VERSION}); package is held."

  tmp_key=$(mktemp)
  chmod 600 "$tmp_key"
  trap 'rm -f "${tmp_key:-}"' RETURN
  printf 'STANCTL_DOWNLOAD_KEY=%s\n' "$DOWNLOAD_KEY" > "$tmp_key"
  upload_private_file "$tmp_key" "$vm_name" "$zone" "$project" .stanctl-version.env
  rm -f "$tmp_key"
  trap - RETURN
  raw_backends=$(remote_exec "$vm_name" "$zone" "$project" \
    "set -a; . /root/.stanctl-version.env; set +a; trap 'rm -f /root/.stanctl-version.env' EXIT; stanctl versions identify --quiet") ||
    die "stanctl ${STANCTL_CLI_VERSION} could not retrieve its compatible backend versions."
  mapfile -t backend_versions < <(printf '%s\n' "$raw_backends" | sed -nE 's/^[[:space:]]*-[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+[-.+~][0-9A-Za-z.-]+)[[:space:]]*$/\1/p' | awk '!seen[$0]++')
  (( ${#backend_versions[@]} > 0 )) ||
    die "stanctl returned no selectable compatible backend versions; no backend installation was started."

  saved=$(get_state backend_version)
  if [[ -n "$saved" ]]; then
    printf '%s\n' "${backend_versions[@]}" | grep -Fxq "$saved" ||
      die "Saved backend ${saved} is not compatible with stanctl ${STANCTL_CLI_VERSION}."
    selected="$saved"
    phase_detail done "Reusing saved compatible backend selection: ${selected}"
  else
    echo ""
    echo -e "${BOLD}Backend versions compatible with stanctl ${STANCTL_CLI_VERSION}:${RESET}" >&2
    selected=$(prompt_choice "Select the exact Instana backend version to install:" "${backend_versions[@]}") ||
      die "Backend version selection was cancelled."
    save_state backend_version "$selected"
  fi
  BACKEND_VERSION="$selected"
  phase_detail done "Selected verified compatible pair: stanctl ${STANCTL_CLI_VERSION} → backend ${BACKEND_VERSION}"

  ok "Exact stanctl and compatible backend versions selected on ${vm_name}."
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
# Online: the operator-selected backend version is passed explicitly. Air-gapped:
# 'stanctl air-gapped import' already wrote the packaged instana-version into the
# stanctl configuration and STANCTL_AIR_GAPPED=true is set in the env file, so no
# version flag is passed (a mismatching value would only make stanctl up fail).
stanctl_version_flag() {
  if [[ "$INSTALL_MODE" != "air-gapped" ]]; then
    [[ -n "$BACKEND_VERSION" ]] || die "No backend version selected for the online installation."
    printf -- "--instana-version '%s'" "$BACKEND_VERSION"
  fi
}
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
    "trap 'rm -f /root/.stanctl.env' EXIT; stanctl up --env-file /root/.stanctl.env $(stanctl_version_flag) ${tls_flags} --quiet"

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
    "trap 'rm -f /root/.stanctl.env' EXIT; stanctl up --env-file /root/.stanctl.env $(stanctl_version_flag) ${tls_flags} --quiet"

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

  remote_exec "$vm_name" "$zone" "$project" \
    "set -e; kubectl wait --for=condition=Ready nodes --all --timeout=300s"

  local namespace
  for namespace in instana-core instana-unit; do
    remote_exec "$vm_name" "$zone" "$project" \
      "set -e; kubectl get namespace '$namespace' >/dev/null; pods=\$(kubectl get pods -n '$namespace' --field-selector=status.phase!=Succeeded -o name); test -n \"\$pods\" || { echo 'No active pods in $namespace' >&2; exit 1; }; kubectl wait --for=condition=Ready pod --all --field-selector=status.phase!=Succeeded -n '$namespace' --timeout=300s"
  done

  ok "Node/core/unit readiness check passed (UI and ingestion still require testing)."
}

configure_kubectl_user_access() {
  local vm_name="$1" zone="$2" project="$3"
  echo ""
  echo -e "  ${BOLD}Kubernetes administration${RESET}"
  echo "  Kubernetes is ready. Commands always available on ${vm_name}:"
  echo "    sudo kubectl get nodes"
  echo "    sudo kubectl get pods -A"
  echo ""
  echo -e "  ${YELLOW}Optional:${RESET} copy the cluster-admin kubeconfig to the current SSH user's home directory."
  echo "  This lets that user run kubectl without sudo and grants that user full cluster administration."

  if [[ "$DRY_RUN" == true || ! -t 0 ]]; then
    phase_detail warn "Skipped optional user kubeconfig setup; sudo kubectl remains available."
    return 0
  fi
  if ! prompt_yes_no "Allow the current SSH user on ${vm_name} to run kubectl without sudo?" N; then
    phase_detail warn "User kubeconfig setup skipped; use sudo kubectl."
    return 0
  fi

  remote_user_exec "$vm_name" "$zone" "$project" \
    'set -e; mkdir -p "$HOME/.kube"; chmod 700 "$HOME/.kube"; uid=$(id -u); gid=$(id -g); sudo install -o "$uid" -g "$gid" -m 600 /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"; KUBECONFIG="$HOME/.kube/config" kubectl config current-context >/dev/null; KUBECONFIG="$HOME/.kube/config" kubectl get nodes >/dev/null'
  phase_detail done "kubectl configured for the current SSH user on ${vm_name}."
}

# =============================================================================
# SECTION 10 — FINAL REPORT
# =============================================================================
print_final_report() {
  local external_ip="$1"
  print_local_access "$external_ip"
  [[ -n "${CONFIRMED_UI_IP:-}" ]] && external_ip="$CONFIRMED_UI_IP"
  echo ""
  echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${GREEN}  Installation Complete!${RESET}"
  echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${RESET}"
  echo ""
  echo -e "  ${BOLD}Instana UI URL:${RESET}  https://${UNIT_NAME}-${TENANT_NAME}.${BASE_DOMAIN}"
  echo -e "  ${BOLD}Admin user:${RESET}      admin@instana.local"
  echo -e "  ${BOLD}External IP:${RESET}     ${external_ip}"
  echo ""
  echo -e "  ${YELLOW}Ready-to-copy /etc/hosts entries:${RESET}"
  printf '    %s %s\n' "$external_ip" "$BASE_DOMAIN" \
    "$external_ip" "${UNIT_NAME}-${TENANT_NAME}.${BASE_DOMAIN}" \
    "$external_ip" "agent-acceptor.${BASE_DOMAIN}" \
    "$external_ip" "opamp-acceptor.${BASE_DOMAIN}" \
    "$external_ip" "otlp-http.${BASE_DOMAIN}" \
    "$external_ip" "otlp-grpc.${BASE_DOMAIN}"
  echo ""
  echo -e "  ${BOLD}State file:${RESET}  ${STATE_FILE}"
  echo -e "  ${BOLD}Log file:${RESET}    ${LOG_FILE}"
  echo ""
  echo -e "  ${BOLD}Kubernetes checks on the backend VM:${RESET}"
  echo "    sudo kubectl get nodes"
  echo "    sudo kubectl get pods -A"
  echo ""
  echo -e "  To destroy all resources: ${CYAN}./destroy.sh${RESET}"
  echo ""
}

# =============================================================================
# SECTION 11 — MAIN ORCHESTRATION
# =============================================================================
main_single_node() {
  phase_start 3 "Check regional CPU quota, detect name collisions, and create the Ubuntu VM. If GCP reports a stockout, the capacity fallback may select another compatible location before any dependent resource exists."
  check_gcp_quota "$GCP_PROJECT" "$GCP_ZONE" "$VM_CPUS"

  # Create a missing VM, or verify the VM recorded by this installation.
  ensure_single_vm "$VM_NAME" "$MACHINE_TYPE" "$GCP_ZONE" "$GCP_PROJECT" \
    "$GCP_NETWORK" "$GCP_SUBNET" "$UBUNTU_VERSION"
  phase_done 3 "VM is available in ${GCP_ZONE}."

  # Create and attach disks (dedicated per directory — required by documentation)
  phase_start 4 "Create separate SSD persistent disks and attach each with a stable device name. Formatting happens later, only after SSH validation."
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
  phase_done 4 "All required data disks are attached."

  phase_start 5 "Create VPC ingress rules for SSH, public Instana endpoints, and required internal traffic. Host-level UFW is configured separately."
  create_firewall_rules "$GCP_PROJECT" "$GCP_NETWORK"
  phase_done 5 "GCP firewall rules are present."

  phase_start 6 "Wait until the VM accepts non-interactive SSH and verify that remote administration is possible."
  [[ "$DRY_RUN" != true ]] && wait_for_ssh "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  phase_done 6 "SSH is ready."

  # Kernel parameters (verbatim from documentation)
  phase_start 7 "Apply Instana sysctl and Transparent Huge Pages settings, reboot, and verify both a new boot ID and THP=never."
  lab_kernel "$VM_NAME"
  phase_done 7 "Kernel settings and reboot were verified."

  # UFW firewall rules (single-node, from documentation)
  phase_start 8 "Enable the Ubuntu firewall while preserving SSH and allowing documented Instana service ports."
  configure_ufw_single_node "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  phase_done 8 "UFW rules were applied."

  # Format and mount disks (from documentation)
  phase_start 9 "Format only blank attached disks, mount them at the documented Instana paths, and persist mounts in /etc/fstab."
  format_and_mount_disk "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-analytics" "/mnt/instana/stanctl/analytics"
  format_and_mount_disk "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-metrics"   "/mnt/instana/stanctl/metrics"
  format_and_mount_disk "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-objects"   "/mnt/instana/stanctl/objects"
  format_and_mount_disk "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-data"      "/mnt/instana/stanctl/data"
  phase_done 9 "Instana storage paths are mounted."

  phase_start 10 "Configure the authenticated Instana package source and install stanctl, or import the selected air-gapped artifacts. Credentials are used in memory and are not written to state or log files."
  if [[ "$INSTALL_MODE" == "online" ]]; then
    add_instana_repository "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
    install_stanctl "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  else
    install_stanctl_airgapped "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  fi
  phase_done 10 "stanctl is installed and ready."

  # Run stanctl up
  phase_start 11 "Run stanctl up with the selected topology, tenant, unit, domain and TLS settings. This is normally the longest phase."
  run_stanctl_up_single_node "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  phase_done 11 "Instana backend installation command completed."

  # Health check
  phase_start 12 "Wait for Kubernetes nodes and Instana workloads, then print exact DNS or hosts-file entries for macOS, Linux and Windows."
  post_install_health_check "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  configure_kubectl_user_access "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"

  # Get external IP
  local ext_ip=""
  if [[ "$DRY_RUN" != true ]]; then
    ext_ip=$(gcloud compute instances describe "$VM_NAME" \
      --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
      --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "unknown")
  fi

  print_final_report "${ext_ip:-DRY-RUN}"
  phase_done 12 "Health checks and access instructions completed."
  progress_summary
}

legacy_main_three_node() {
  phase_start 3 "Check quota and create the three VMs required by the selected multi-node profile."
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
  phase_done 3 "All three VMs were created."

  # Disks — layout from documentation:
  # node0: objects disk (1000 GB)
  # node1: data (500), metrics (1000), analytics (1200)
  # node2: no extra disk
  phase_start 4 "Create and attach the documented dedicated SSD data disks using stable device names."
  create_and_attach_disk "$NODE0_NAME" "${NODE0_NAME}-objects"   1000 "$GCP_ZONE" "$GCP_PROJECT" "disk-objects"
  create_and_attach_disk "$NODE1_NAME" "${NODE1_NAME}-data"       500 "$GCP_ZONE" "$GCP_PROJECT" "disk-data"
  create_and_attach_disk "$NODE1_NAME" "${NODE1_NAME}-metrics"   1000 "$GCP_ZONE" "$GCP_PROJECT" "disk-metrics"
  create_and_attach_disk "$NODE1_NAME" "${NODE1_NAME}-analytics" 1200 "$GCP_ZONE" "$GCP_PROJECT" "disk-analytics"
  phase_done 4 "All multi-node data disks are attached."

  phase_start 5 "Create GCP VPC rules for SSH, public Instana endpoints, and node-to-node cluster communication."
  create_firewall_rules "$GCP_PROJECT" "$GCP_NETWORK"
  phase_done 5 "GCP firewall rules are present."

  # Get private IPs
  phase_start 6 "Record private IP addresses and wait until every node accepts non-interactive SSH."
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
  phase_done 6 "All nodes are reachable over SSH."

  # Kernel parameters on ALL nodes (from documentation)
  phase_start 7 "Apply documented sysctl and THP settings on every node, reboot, and verify the settings."
  for node in "$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME"; do
    apply_kernel_parameters "$node" "$GCP_ZONE" "$GCP_PROJECT"
  done
  phase_done 7 "Kernel configuration completed on all nodes."

  # UFW on ALL nodes (multi-node rules from documentation)
  phase_start 8 "Configure Ubuntu UFW on every node while retaining SSH and required Instana cluster ports."
  for node in "$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME"; do
    configure_ufw_multi_node "$node" "$GCP_ZONE" "$GCP_PROJECT" \
      "$node0_ip" "$node1_ip" "$node2_ip"
  done
  phase_done 8 "UFW configuration completed on all nodes."

  # Format and mount disks
  phase_start 9 "Format blank disks, persist their mounts, and configure the documented node0-to-node SSH relationship."
  format_and_mount_disk "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-objects"   "/mnt/instana/stanctl/objects"
  format_and_mount_disk "$NODE1_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-data"      "/mnt/instana/stanctl/data"
  format_and_mount_disk "$NODE1_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-metrics"   "/mnt/instana/stanctl/metrics"
  format_and_mount_disk "$NODE1_NAME" "$GCP_ZONE" "$GCP_PROJECT" "disk-analytics" "/mnt/instana/stanctl/analytics"

  # SSH setup (from documentation)
  setup_ssh_keys_multi_node "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" \
    "$node1_ip" "$node2_ip"
  phase_done 9 "Storage mounts and inter-node SSH are ready."

  # Install stanctl on node0 only (from docs: multi-node, run commands on node0)
  phase_start 10 "Install stanctl on node0 from the authenticated online repository or selected air-gapped package."
  if [[ "$INSTALL_MODE" == "online" ]]; then
    add_instana_repository "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
    install_stanctl "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  else
    install_stanctl_airgapped "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  fi
  phase_done 10 "stanctl is available on node0."

  # Run stanctl up from node0
  phase_start 11 "Run the multi-node stanctl installation from node0 and wait for backend deployment."
  run_stanctl_up_multi_node "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" \
    "${node0_ip},${node1_ip},${node2_ip}"
  phase_done 11 "Instana multi-node installation command completed."

  # Health check on node0
  phase_start 12 "Check Kubernetes and Instana workload readiness, then print local access instructions for each operating system."
  post_install_health_check "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  configure_kubectl_user_access "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"

  # Get external IP of node0 (base domain points to node0 in multi-node)
  local ext_ip=""
  if [[ "$DRY_RUN" != true ]]; then
    ext_ip=$(gcloud compute instances describe "$NODE0_NAME" \
      --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
      --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "unknown")
  fi

  print_final_report "${ext_ip:-DRY-RUN}"
  phase_done 12 "Health checks and local access instructions completed."
  progress_summary
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
  [[ "$TOPOLOGY" == single-node ]] || die "This resume validator is for single-node deployments."
  [[ -f "$STATE_FILE" ]] || die "Copy the original .install-state.json alongside this script first."
  [[ "$(get_state gcp_project)" == "$GCP_PROJECT" && "$(get_state gcp_zone)" == "$GCP_ZONE" && "$(get_state "vm_${VM_NAME}")" == created ]] ||
    die "Project, zone or VM differs from the saved state. No changes made."
  local vm
  vm=$(gcloud compute instances describe "$VM_NAME" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json)
  [[ "$(jq -r .status <<< "$vm")" == RUNNING ]] || die "Existing VM must be RUNNING."
  [[ "$(jq -r '.machineType | split("/")[-1]' <<< "$vm")" == "$MACHINE_TYPE" ]] || die "Machine type differs from your selection."
  wait_for_ssh "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  remote_exec "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" '
    set -e
    if test -e /etc/rancher/k3s/k3s.yaml; then
      echo "STOP: Kubernetes installation already started; automatic single-node continuation is refused." >&2; exit 1
    fi
  '
  warn "Partial single-node resume validated. VM and every disk will be checked individually; only missing resources will be created."
}

main() {
  echo ""
  log "Log file: ${LOG_FILE}"

  progress_init
  phase_start 1 "Verify required command-line tools, acquire the installer lock, authenticate to GCP, and collect or reuse saved non-secret parameters."
  check_local_tools
  exec 9>"${SCRIPT_DIR}/.install.lock"
  flock -n 9 || die "Another installer is running from this deployment folder."
  check_gcp_login
  if ! offer_saved_parameters; then
    collect_parameters
  fi
  save_parameters
  validate_vm_names
  phase_done 1 "Local prerequisites and non-secret parameters are ready."
  if [[ "$TOPOLOGY" == three-node && "$INSTALL_MODE" == online ]]; then
    if [[ -f "$STATE_FILE" && "$RESUME" != true ]]; then
      prompt_yes_no "Existing deployment found. Resume with verified saved state?" Y || die "Resume declined."
      RESUME=true
    fi
    prepare_multinode_lab
  fi
  phase_start 2 "Validate project, region, zone, VPC, subnet and Ubuntu image, then display the complete plan before resources are changed."
  check_gcp_configuration
  if [[ "$RESUME" == true && "$TOPOLOGY" != three-node ]]; then
    validate_resume
  else
    gcloud compute images describe-from-family "$UBUNTU_VERSION" \
      --project=ubuntu-os-cloud >/dev/null || die "Ubuntu image family unavailable."
  fi
  show_plan
  phase_done 2 "GCP configuration and installation plan were validated."

  case "$TOPOLOGY" in
    single-node)  main_single_node ;;
    three-node)   main_three_node ;;
    *)            die "Unknown topology: $TOPOLOGY" ;;
  esac
}

source "${SCRIPT_DIR}/multinode-online.sh"
source "${SCRIPT_DIR}/local-access.sh"
source "${SCRIPT_DIR}/multinode-resume.sh"
source "${SCRIPT_DIR}/hardware-input.sh"
source "${SCRIPT_DIR}/capacity-fallback.sh"
source "${SCRIPT_DIR}/progress.sh"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
