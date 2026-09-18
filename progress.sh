#!/usr/bin/env bash
# Human-readable progress and resumable phase checkpoints.

readonly PROGRESS_TOTAL=12
declare -a PROGRESS_TITLES=(
  ""
  "Local prerequisites and installation parameters"
  "GCP validation and installation plan"
  "Capacity check and virtual machines"
  "Dedicated data disks"
  "GCP VPC firewall rules"
  "SSH readiness and operating-system prerequisites"
  "Kernel parameters and verified reboot"
  "Host firewall (UFW)"
  "Filesystems, mounts and inter-node access"
  "Instana repository/package and stanctl"
  "Instana backend installation"
  "Health checks and local access instructions"
)
declare -a PROGRESS_STATUS
PROGRESS_CURRENT=0

progress_emit() { echo -e "$*" | tee -a "$LOG_FILE"; }

progress_bar() {
  local state="${1:-running}" percent width=30 filled empty
  local filled_text empty_text label colour
  percent=$(progress_percent)
  filled=$((percent * width / 100))
  empty=$((width - filled))
  printf -v filled_text '%*s' "$filled" ''
  printf -v empty_text '%*s' "$empty" ''
  filled_text=${filled_text// /#}
  empty_text=${empty_text// /-}
  case "$state" in
    complete) label="COMPLETE"; colour="$GREEN" ;;
    stopped) label="STOPPED"; colour="$RED" ;;
    resumed) label="RESUME"; colour="$CYAN" ;;
    *) label="IN PROGRESS"; colour="$GREEN" ;;
  esac

  # Keep logs and redirected output free from terminal control sequences.
  printf '[%s%s] %3d%%  %s\n' "$filled_text" "$empty_text" "$percent" "$label" >> "$LOG_FILE"
  if [[ -t 1 ]]; then
    printf '%b[%s%b%s%b] %3d%%  %s%b\n' "$colour" "$filled_text" "$RESET" "$empty_text" "$BOLD" "$percent" "$label" "$RESET"
  else
    printf '[%s%s] %3d%%  %s\n' "$filled_text" "$empty_text" "$percent" "$label"
  fi
}

progress_percent() {
  local completed=0 i
  for ((i=1; i<=PROGRESS_TOTAL; i++)); do
    [[ "${PROGRESS_STATUS[$i]:-}" == done || "${PROGRESS_STATUS[$i]:-}" == skipped ]] && ((completed+=1))
  done
  printf '%d' $((completed * 100 / PROGRESS_TOTAL))
}

progress_checklist() {
  local i mark
  progress_emit ""
  progress_emit "${BOLD}Installation checklist — $(progress_percent)% complete${RESET}"
  for ((i=1; i<=PROGRESS_TOTAL; i++)); do
    case "${PROGRESS_STATUS[$i]:-pending}" in
      done) mark="${GREEN}✓${RESET}";;
      active) mark="${CYAN}→${RESET}";;
      skipped) mark="${YELLOW}–${RESET}";;
      failed) mark="${RED}✗${RESET}";;
      *) mark=" ";;
    esac
    progress_emit "  [${mark}] ${i}/${PROGRESS_TOTAL} ${PROGRESS_TITLES[$i]}"
  done
  progress_emit ""
}

progress_init() {
  local i saved
  for ((i=1; i<=PROGRESS_TOTAL; i++)); do
    PROGRESS_STATUS[$i]=pending
    if [[ "$DRY_RUN" != true && -f "$STATE_FILE" ]]; then
      saved=$(get_state "progress_phase_${i}" 2>/dev/null || true)
      [[ "$saved" == completed ]] && PROGRESS_STATUS[$i]=done
    fi
  done
  progress_checklist
  if (( $(progress_percent) > 0 )); then
    progress_bar resumed
  else
    progress_bar running
  fi
}

phase_start() {
  local number="$1" explanation="$2"
  PROGRESS_CURRENT="$number"
  PROGRESS_STATUS[$number]=active
  progress_emit "${BOLD}${CYAN}[PHASE ${number}/${PROGRESS_TOTAL}] ${PROGRESS_TITLES[$number]}${RESET}"
  progress_emit "  ${explanation}"
  progress_emit "  Overall progress before this phase: $(progress_percent)%"
  progress_bar running
}

phase_detail() {
  local state="$1"; shift
  local mark
  case "$state" in
    done) mark="${GREEN}✓${RESET}";;
    warn) mark="${YELLOW}!${RESET}";;
    fail) mark="${RED}✗${RESET}";;
    *) mark="${CYAN}→${RESET}";;
  esac
  progress_emit "    [${mark}] $*"
}

phase_done() {
  local number="${1:-$PROGRESS_CURRENT}" message="${2:-Phase completed.}"
  PROGRESS_STATUS[$number]=done
  [[ "$DRY_RUN" == true ]] || save_state "progress_phase_${number}" completed
  phase_detail done "$message"
  progress_emit "  Overall progress: $(progress_percent)%"
  if (( $(progress_percent) == 100 )); then
    progress_bar complete
  else
    progress_bar running
  fi
}

phase_skip() {
  local number="$1" reason="$2"
  PROGRESS_STATUS[$number]=skipped
  [[ "$DRY_RUN" == true ]] || save_state "progress_phase_${number}" completed
  phase_detail warn "Skipped: ${reason}"
  progress_emit "  Overall progress: $(progress_percent)%"
  if (( $(progress_percent) == 100 )); then
    progress_bar complete
  else
    progress_bar running
  fi
}

progress_fail_current() {
  local message="$1"
  if (( PROGRESS_CURRENT > 0 )); then
    PROGRESS_STATUS[$PROGRESS_CURRENT]=failed
    phase_detail fail "Phase ${PROGRESS_CURRENT} stopped: ${message}"
    progress_bar stopped
    progress_emit "  Correct the reported problem and rerun with --resume when supported."
  fi
}

progress_summary() {
  progress_checklist
  progress_bar complete
  progress_emit "${GREEN}${BOLD}All required phases completed.${RESET}"
}
