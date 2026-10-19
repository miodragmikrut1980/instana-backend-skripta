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
declare -a PHASE_STARTED      # SECONDS when the phase started (this run)
declare -a PHASE_SECONDS      # duration of the phase, this run or a previous one
PROGRESS_CURRENT=0
RUN_STARTED_SECONDS=$SECONDS
RUN_STARTED_AT=$(date '+%Y-%m-%d %H:%M:%S')

# fmt_duration SECONDS → "1h 02m 03s" / "4m 12s" / "37s"
fmt_duration() {
  local t=${1:-0}
  if (( t >= 3600 )); then printf '%dh %02dm %02ds' $((t/3600)) $((t%3600/60)) $((t%60))
  elif (( t >= 60 )); then printf '%dm %02ds' $((t/60)) $((t%60))
  else printf '%ds' "$t"; fi
}
run_elapsed() { fmt_duration $(( SECONDS - RUN_STARTED_SECONDS )); }
# Sum of every phase's recorded duration (this run plus earlier runs taken
# from the state file) = the real installation work time across resumes.
phases_total_seconds() {
  local i t=0
  for ((i=1; i<=PROGRESS_TOTAL; i++)); do t=$(( t + ${PHASE_SECONDS[$i]:-0} )); done
  echo "$t"
}

progress_emit() { echo -e "$*" | log_tee; }

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
    if [[ -n "${PHASE_SECONDS[$i]:-}" ]]; then
      progress_emit "  [${mark}] ${i}/${PROGRESS_TOTAL} ${PROGRESS_TITLES[$i]}  ($(fmt_duration "${PHASE_SECONDS[$i]}"))"
    else
      progress_emit "  [${mark}] ${i}/${PROGRESS_TOTAL} ${PROGRESS_TITLES[$i]}"
    fi
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
      saved=$(get_state "progress_phase_${i}_seconds" 2>/dev/null || true)
      [[ "$saved" =~ ^[0-9]+$ ]] && PHASE_SECONDS[$i]="$saved"
    fi
  done
  progress_checklist
  if (( $(progress_percent) > 0 )); then
    progress_bar resumed
  else
    progress_bar running
  fi
}

# A provider may word a phase its own way (provider_phase_text N title|start|done);
# without its own text the wording below and at the call site is used.
provider_phase_word() {
  declare -F provider_phase_text >/dev/null || return 0
  provider_phase_text "$@"
}
declare -a PROGRESS_DEFAULT_TITLES=("${PROGRESS_TITLES[@]}")
progress_apply_provider_titles() {
  local i t
  for ((i=1; i<=PROGRESS_TOTAL; i++)); do
    t=$(provider_phase_word "$i" title)
    PROGRESS_TITLES[$i]="${t:-${PROGRESS_DEFAULT_TITLES[$i]}}"
  done
}

phase_start() {
  local number="$1" explanation="$2" own
  own=$(provider_phase_word "$number" start)
  [[ -z "$own" ]] || explanation="$own"
  PROGRESS_CURRENT="$number"
  PROGRESS_STATUS[$number]=active
  PHASE_STARTED[$number]=$SECONDS
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
  local number="${1:-$PROGRESS_CURRENT}" message="${2:-Phase completed.}" own
  own=$(provider_phase_word "$number" done)
  [[ -z "$own" ]] || message="$own"
  PROGRESS_STATUS[$number]=done
  local took=$(( SECONDS - ${PHASE_STARTED[$number]:-$SECONDS} ))
  PHASE_SECONDS[$number]=$took
  if [[ "$DRY_RUN" != true ]]; then
    save_state "progress_phase_${number}" completed
    save_state "progress_phase_${number}_seconds" "$took"
  fi
  phase_detail done "$message"
  progress_emit "  Phase ${number} took $(fmt_duration "$took"); running for $(run_elapsed) since start ($RUN_STARTED_AT)."
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
    progress_emit "  Stopped after $(run_elapsed) in this run (started $RUN_STARTED_AT)."
    progress_bar stopped
    if [[ "${DRY_RUN:-false}" == true ]] || ! declare -F deployment_has_resources >/dev/null || ! deployment_has_resources 2>/dev/null; then
      progress_emit "  Nothing was created yet. Correct the reported problem and run ./install.sh again."
    else
      progress_emit "  Correct the reported problem and continue where it stopped: ./install.sh --resume"
    fi
  fi
}

progress_summary() {
  progress_checklist
  progress_bar complete
  # The total time is part of the result that follows (print_final_summary).
  progress_emit "${GREEN}${BOLD}All required phases completed.${RESET}"
}
