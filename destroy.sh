#!/usr/bin/env bash
# =============================================================================
# Instana Standard Edition — GCP Teardown / Destroy Script
# =============================================================================
# Reads state from .install-state.json written by install.sh
# and removes all created GCP resources in safe reverse order.
#
# Usage:
#   ./destroy.sh [--dry-run]
# =============================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_FILE="${SCRIPT_DIR}/.install-state.json"
readonly LOG_FILE="${SCRIPT_DIR}/destroy-$(date +%Y%m%d-%H%M%S).log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

DRY_RUN=false

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

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true; warn "Dry-run mode — no resources will be deleted." ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

[[ -f "$STATE_FILE" ]] || die "State file not found: ${STATE_FILE}\nRun install.sh first."

get_state() {
  jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE"
}

# Read all state
GCP_PROJECT=$(get_state "gcp_project" 2>/dev/null || echo "")
GCP_ZONE=$(get_state "gcp_zone" 2>/dev/null || echo "")

# The state file must actually record resources. A file holding only progress
# checkpoints (an interrupted phase 1) or nothing usable is refused with a
# pointer to the name-based clean-up in install.sh, instead of pretending that
# "all resources were deleted".
recorded=$(jq -r 'to_entries[] | select(.key | test("^(vm_|disk_|firewall_|fw_)")) | .key' "$STATE_FILE" 2>/dev/null | wc -l)
if [[ -z "$GCP_PROJECT" || -z "$GCP_ZONE" || "$recorded" -eq 0 ]]; then
  err "The state file records no GCP resources (project: '${GCP_PROJECT:-?}', zone: '${GCP_ZONE:-?}', recorded resources: ${recorded})."
  echo "  Nothing can be deleted from it. If VMs or disks still exist in GCP, remove them by VM name:" >&2
  echo "      ./install.sh   ->  'clean up (preview)' / 'clean up'   (asks project, zone and VM name, e.g. instana-0)" >&2
  if [[ "$DRY_RUN" != true ]]; then
    mv -f "$STATE_FILE" "${STATE_FILE}.$(date +%Y%m%d-%H%M%S).empty" 2>/dev/null &&
      warn "The unusable state file was set aside as $(basename "${STATE_FILE}").*.empty."
  fi
  exit 1
fi
[[ "$GCP_PROJECT" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "State file holds an invalid GCP project ID '${GCP_PROJECT}'."

echo ""
echo -e "${BOLD}${RED}════════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${RED}  WARNING: This will permanently delete all Instana GCP resources${RESET}"
echo -e "${BOLD}${RED}════════════════════════════════════════════════════════════════${RESET}"
echo ""
echo "  State file: ${STATE_FILE}"
echo "  Log file:   ${LOG_FILE}"
echo ""

expected="DELETE ${GCP_PROJECT}/${GCP_ZONE}"
read -rp "$(echo -e "${RED}?${RESET} Type '${expected}' to confirm deletion: ")" confirm
[[ "$confirm" == "$expected" ]] || { log "Aborted."; exit 0; }

echo ""

DELETED=0; MISSING=0
# Delete VMs
delete_vm() {
  local name="$1"
  if gcloud compute instances describe "$name" \
      --project="$GCP_PROJECT" --zone="$GCP_ZONE" &>/dev/null 2>&1; then
    log "Deleting VM: ${name}..."
    run gcloud compute instances delete "$name" \
      --project="$GCP_PROJECT" \
      --zone="$GCP_ZONE" \
      --quiet
    ok "VM ${name} deleted."; (( DELETED++ )) || true
  else
    warn "VM ${name} not found — skipping."; (( MISSING++ )) || true
  fi
}

# Delete disks (detached after VM deletion)
delete_disk() {
  local name="$1"
  if gcloud compute disks describe "$name" \
      --project="$GCP_PROJECT" --zone="$GCP_ZONE" &>/dev/null 2>&1; then
    log "Deleting disk: ${name}..."
    run gcloud compute disks delete "$name" \
      --project="$GCP_PROJECT" \
      --zone="$GCP_ZONE" \
      --quiet
    ok "Disk ${name} deleted."; (( DELETED++ )) || true
  else
    warn "Disk ${name} not found — skipping."; (( MISSING++ )) || true
  fi
}

# Delete firewall rules
delete_firewall() {
  local name="$1"
  if gcloud compute firewall-rules describe "$name" \
      --project="$GCP_PROJECT" &>/dev/null 2>&1; then
    log "Deleting firewall rule: ${name}..."
    run gcloud compute firewall-rules delete "$name" \
      --project="$GCP_PROJECT" \
      --quiet
    ok "Firewall rule ${name} deleted."; (( DELETED++ )) || true
  else
    warn "Firewall rule ${name} not found — skipping."; (( MISSING++ )) || true
  fi
}

# Read all vm_ and disk_ keys from state file and delete
log "Reading resources from state file..."

# VMs
while IFS= read -r vm_name; do
  [[ -n "$vm_name" ]] && delete_vm "$vm_name"
done < <(jq -r 'to_entries[] | select(.key | startswith("vm_")) | .key | ltrimstr("vm_")' "$STATE_FILE" 2>/dev/null)

# Disks
while IFS= read -r disk_name; do
  [[ -n "$disk_name" ]] && delete_disk "$disk_name"
done < <(jq -r 'to_entries[] | select(.key | startswith("disk_")) | .key | ltrimstr("disk_")' "$STATE_FILE" 2>/dev/null)

# Firewall rules
while IFS= read -r fw; do
  [[ -n "$fw" ]] && delete_firewall "$fw"
done < <(jq -r 'to_entries[] | select(.key | startswith("firewall_")) | .key | ltrimstr("firewall_")' "$STATE_FILE")
for fw in "instana-allow-ssh" "instana-allow-external" "instana-allow-k3s-subnets" "instana-allow-internal"; do
  fw_key="fw_${fw#instana-allow-}"
  if [[ "$(get_state "$fw_key")" == "created" ]]; then
    delete_firewall "$fw"
  fi
done

# Remove state file
if [[ "$DRY_RUN" != true ]]; then
  rm -f "$STATE_FILE"
  ok "State file removed."
fi

echo ""
if [[ "$DRY_RUN" == true ]]; then
  ok "Preview finished: ${DELETED} resource(s) would be deleted, ${MISSING} recorded resource(s) no longer exist."
elif (( DELETED > 0 )); then
  ok "Deleted ${DELETED} resource(s); ${MISSING} recorded resource(s) no longer existed."
else
  warn "Nothing was deleted: none of the ${MISSING} recorded resource(s) exist any more."
fi
echo -e "  Log: ${LOG_FILE}"
echo ""
