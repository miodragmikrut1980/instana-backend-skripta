#!/usr/bin/env bash
# =============================================================================
# Instana Standard Edition — Teardown / Destroy Script
# =============================================================================
# Reads state from .install-state.json written by install.sh and removes the
# cloud resources it records in safe reverse order, through the provider that
# created them (providers/<provider>.sh; a state without one is GCP).
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

for _provider_file in common.sh gcp.sh ssh.sh; do
  [[ -f "${SCRIPT_DIR}/providers/${_provider_file}" ]] ||
    die "providers/${_provider_file} is missing from ${SCRIPT_DIR}; restore it from git (git checkout -- . && git pull origin main)."
  source "${SCRIPT_DIR}/providers/${_provider_file}"
done
unset _provider_file
resolve_provider || exit 1

# Where the recorded resources live (GCP: project and zone).
DESTROY_SCOPE="" DESTROY_LOCATION=""
provider_destroy_target

# The state file must actually record resources. A file holding only progress
# checkpoints (an interrupted phase 1) or nothing usable is refused with a
# pointer to the name-based clean-up in install.sh, instead of pretending that
# "all resources were deleted".
recorded=$(jq -r --arg re "$(provider_state_resource_pattern)" 'to_entries[] | select(.key | test($re)) | .key' "$STATE_FILE" 2>/dev/null | wc -l)
if [[ -z "$DESTROY_SCOPE" || -z "$DESTROY_LOCATION" || "$recorded" -eq 0 ]]; then
  err "The state file records no ${PROVIDER_LABEL} resources ($(provider_destroy_target_text), recorded resources: ${recorded})."
  echo "  Nothing can be deleted from it. If VMs or disks still exist in ${PROVIDER_LABEL}, remove them by VM name:" >&2
  echo "      ./install.sh   ->  'clean up (preview)' / 'clean up'   (asks project, zone and VM name, e.g. instana-0)" >&2
  if [[ "$DRY_RUN" != true ]]; then
    mv -f "$STATE_FILE" "${STATE_FILE}.$(date +%Y%m%d-%H%M%S).empty" 2>/dev/null &&
      warn "The unusable state file was set aside as $(basename "${STATE_FILE}").*.empty."
  fi
  exit 1
fi
provider_destroy_validate_target || exit 1

echo ""
echo -e "${BOLD}${RED}════════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${RED}  WARNING: This will permanently delete all Instana ${PROVIDER_LABEL} resources${RESET}"
echo -e "${BOLD}${RED}════════════════════════════════════════════════════════════════${RESET}"
echo ""
echo "  State file: ${STATE_FILE}"
echo "  Log file:   ${LOG_FILE}"
echo ""

expected="DELETE ${DESTROY_SCOPE}/${DESTROY_LOCATION}"
read -rp "$(echo -e "${RED}?${RESET} Type '${expected}' to confirm deletion: ")" confirm
[[ "$confirm" == "$expected" ]] || { log "Aborted."; exit 0; }

echo ""

DELETED=0; MISSING=0
log "Reading resources from state file..."
provider_destroy_from_state

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
