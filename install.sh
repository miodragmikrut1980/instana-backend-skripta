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
#   ./install.sh [--dry-run] [--config FILE]   (see ./install.sh --help)
# =============================================================================

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_FILE="${SCRIPT_DIR}/.install-state.json"
readonly CONFIG_FILE="${SCRIPT_DIR}/.install-config.json"
readonly REPORT_FILE="${SCRIPT_DIR}/.install-report.txt"
umask 077
# The installer is split over several files; a missing one (partial copy,
# accidental delete) must produce a clear fix instead of a bash source error.
for _companion in parameters.sh input-config.sh progress.sh multinode-online.sh local-access.sh multinode-resume.sh hardware-input.sh capacity-fallback.sh providers/common.sh providers/gcp.sh providers/ssh.sh; do
  if [[ ! -f "${SCRIPT_DIR}/${_companion}" ]]; then
    echo "[ERROR] ${_companion} is missing from ${SCRIPT_DIR}; the installer needs all its files side by side." >&2
    echo "  Restore them from git in that folder:   git checkout -- . && git pull origin main" >&2
    echo "  Or clone again:  git clone https://github.com/miodragmikrut1980/instana-backend-skripta.git" >&2
    ERROR_REPORTED=true; exit 1
  fi
done
unset _companion
source "${SCRIPT_DIR}/parameters.sh"
source "${SCRIPT_DIR}/input-config.sh"
readonly LOG_FILE="${SCRIPT_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
readonly INSTANA_APT_REPO="deb [signed-by=/usr/share/keyrings/instana-archive-keyring.gpg] https://artifact-public.instana.io/artifactory/rel-debian-public-virtual generic main"
readonly INSTANA_KEYRING_URL="https://artifact-public.instana.io/artifactory/api/security/keypair/public/repositories/rel-debian-public-virtual"

# ── Colours ───────────────────────────────────────────────────────────────────
# Only on a terminal and only when NO_COLOR is not set (https://no-color.org):
# piped or redirected output, and every log file, stay plain text.
if [[ -t 1 && -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'; DIM='\033[2m'
  USE_COLOR=1
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''; DIM=''
  USE_COLOR=0
fi

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
# log_tee — like tee -a LOG_FILE, but the log file never gets colour codes.
log_tee() {
  if [[ "${USE_COLOR:-0}" != 1 ]]; then tee -a "$LOG_FILE"; return; fi
  local line plain re=$'\e''\[[0-9;]*m'
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"
    plain="$line"
    while [[ "$plain" =~ $re ]]; do plain="${plain/"${BASH_REMATCH[0]}"/}"; done
    printf '%s\n' "$plain" >> "$LOG_FILE"
  done
}
log()  { echo -e "${CYAN}[INFO]${RESET}  $*" | log_tee; }
ok()   { echo -e "${GREEN}[OK]${RESET}    $*" | log_tee; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*" | log_tee; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" | log_tee; }
ERROR_REPORTED=false
die()  { ERROR_REPORTED=true; err "$*"; declare -F progress_fail_current >/dev/null && progress_fail_current "$*"; exit 1; }

# Any exit with a non-zero status that no die/die_with_steps explained (a
# command stopped by set -e) lands here, so the user is never left with a
# bare shell prompt and no idea what to do next. Runs from the EXIT trap;
# an ERR trap would also fire inside $(...) probes that are allowed to fail.
on_exit_report() {
  local rc=$1 cmd="${2:-}"
  (( rc != 0 )) || return 0
  (( rc != 130 && rc != 143 )) || return 0        # Ctrl+C / terminated by hand
  [[ "$ERROR_REPORTED" != true ]] || return 0
  ERROR_REPORTED=true
  err "A step failed unexpectedly (exit code ${rc}) after $(declare -F run_elapsed >/dev/null && run_elapsed || echo '?') in this run:"
  if [[ -n "${LAST_FAILED_STEP:-}" ]]; then
    err "  ${LAST_FAILED_STEP}"
  elif [[ -n "$cmd" ]]; then
    err "  ${cmd}"
  fi
  {
    echo ""
    echo -e "  ${BOLD}${YELLOW}┌─ HOW TO RESOLVE ────────────────────────────────────────────${RESET}"
    echo -e "  ${YELLOW}│${RESET} Nothing already completed is lost: every finished phase is recorded in .install-state.json."
    echo -e "  ${YELLOW}│${RESET} ${BOLD}1.${RESET} Read the lines above this box for the actual cause (the last [ERROR] or ssh/gcloud message)."
    echo -e "  ${YELLOW}│${RESET} ${BOLD}2.${RESET} If it was a lost connection or a transient error, simply continue where it stopped:"
    echo -e "  ${YELLOW}│${RESET}      ${CYAN}cd ${SCRIPT_DIR} && bash install.sh --resume${RESET}"
    echo -e "  ${YELLOW}│${RESET} ${BOLD}3.${RESET} If it fails again at the same step, keep the log for troubleshooting: ${CYAN}${LOG_FILE}${RESET}"
    echo -e "  ${BOLD}${YELLOW}└─────────────────────────────────────────────────────────────${RESET}"
    echo ""
  } | log_tee >&2
  declare -F progress_fail_current >/dev/null && progress_fail_current "exit ${rc}: ${LAST_FAILED_STEP:-$cmd}"
  return 0
}
trap 'on_exit_report $? "$BASH_COMMAND"' EXIT
# Ctrl+D at a question in a terminal, confirmed with Y (ctrl_d_cancel): the
# answer is read in a subshell, so the main shell is told to cancel.
trap 'operator_cancel' USR1

# die_with_steps MESSAGE STEP... — like die, but first prints a readable
# "HOW TO RESOLVE" box. A STEP written as "text|command" shows the command
# on its own indented line; a STEP starting with "*" is printed as a note.
die_with_steps() {
  ERROR_REPORTED=true
  local msg="$1"; shift
  local n=1 step text cmd line
  err "$msg"
  {
    echo ""
    echo -e "  ${BOLD}${YELLOW}┌─ HOW TO RESOLVE ────────────────────────────────────────────${RESET}"
    for step in "$@"; do
      if [[ "$step" == \** ]]; then
        echo -e "  ${YELLOW}│${RESET} ${step#\*}"
        continue
      fi
      text="${step%%|*}"
      cmd=""; [[ "$step" == *"|"* ]] && cmd="${step#*|}"
      echo -e "  ${YELLOW}│${RESET} ${BOLD}${n}.${RESET} ${text}"
      [[ -z "$cmd" ]] || echo -e "  ${YELLOW}│${RESET}      ${CYAN}${cmd}${RESET}"
      (( n++ ))
    done
    echo -e "  ${BOLD}${YELLOW}└─────────────────────────────────────────────────────────────${RESET}"
    echo ""
  } | log_tee >&2
  declare -F progress_fail_current >/dev/null && progress_fail_current "$msg"
  exit 1
}
run()  {
  if [[ "$DRY_RUN" == true ]]; then
    { printf "${YELLOW}[DRY-RUN]${RESET} "; printf '%q ' "$@"; printf '\n'; } | log_tee
  else
    printf '>> ' >> "$LOG_FILE"
    printf '%q ' "$@" >> "$LOG_FILE"
    printf '\n' >> "$LOG_FILE"
    if declare -F spin_run >/dev/null; then
      spin_run "${1:-} ${2:-} ${3:-} ${4:-}" "$@"
    else
      "$@"
    fi
  fi
}

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
  cat <<USAGE
Usage: ./install.sh [option]

  (no option)   interactive start menu: install, dry-run, resume, destroy
  --dry-run     show the full plan and simulate every phase; creates nothing
  --config FILE take the parameters from FILE (JSON made with config-generator.html
                or --export-config); only missing or invalid values are asked.
                Combine with --dry-run to see the plan first.
  --export-config [FILE]
                write the parameters saved in this folder (.install-config.json)
                as such a file, without keys and password, and stop
  --resume      continue an interrupted deployment recorded in this folder
  --destroy     delete the GCP resources recorded in this folder (runs destroy.sh);
                combine with --dry-run to only preview what would be deleted
  --report      print the final report (UI URL, IP, hosts entries) of the last
                successful installation from this folder
  --verbose     show the full help text before every question (otherwise:
                answer ? to see it)
  --help        this text
USAGE
}

DESTROY=false
START_CHOICE=""
EXPORT_CONFIG=false
EXPORT_CONFIG_PATH=""
_args=("$@")
for (( _i = 0; _i < ${#_args[@]}; _i++ )); do
  arg="${_args[_i]}"
  case "$arg" in
    --config|--config=*)
      if [[ "$arg" == --config=* ]]; then INPUT_CONFIG="${arg#--config=}"
      elif (( _i + 1 < ${#_args[@]} )) && [[ "${_args[_i+1]}" != --* ]]; then INPUT_CONFIG="${_args[_i+1]}"; (( ++_i ))
      else INPUT_CONFIG=""; fi
      [[ -n "$INPUT_CONFIG" ]] ||
        die_with_steps "--config needs the path of the JSON input file." \
          "Give the file after --config:|./install.sh --config instana-config.json" \
          "*Create the file with config-generator.html (in this folder)."
      INPUT_CONFIG=$(input_expand_path "$INPUT_CONFIG")
      [[ "$INPUT_CONFIG" == /* ]] || INPUT_CONFIG="${PWD}/${INPUT_CONFIG}"
      INPUT_NONINTERACTIVE=1 ;;
    --export-config|--export-config=*)
      EXPORT_CONFIG=true
      if [[ "$arg" == --export-config=* ]]; then EXPORT_CONFIG_PATH="${arg#--export-config=}"
      elif (( _i + 1 < ${#_args[@]} )) && [[ "${_args[_i+1]}" != --* ]]; then EXPORT_CONFIG_PATH="${_args[_i+1]}"; (( ++_i )); fi ;;
    --resume) RESUME=true ;;
    # Internal: the start-menu choice, passed on when the installer re-launches
    # itself inside screen (so the menu is not shown twice).
    --start=install) START_CHOICE=install ;;
    --start=dry-run) START_CHOICE=dry-run; DRY_RUN=true ;;
    --start=resume) START_CHOICE=resume; RESUME=true ;;
    --dry-run) DRY_RUN=true ;;
    --verbose) export INSTANA_VERBOSE=1 ;;
    --destroy) DESTROY=true ;;
    --report)
      if [[ -f "${SCRIPT_DIR}/.install-report.txt" ]]; then cat "${SCRIPT_DIR}/.install-report.txt"; exit 0
      else echo "No report yet: no installation from this folder has completed." >&2; ERROR_REPORTED=true; exit 1; fi ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $arg"; usage; ERROR_REPORTED=true; exit 1 ;;
  esac
done
unset _args _i
if [[ -n "$INPUT_CONFIG" && "$RESUME" == true ]]; then
  die_with_steps "--config cannot be combined with --resume: a started deployment keeps the parameters it was started with." \
    "Continue the deployment recorded in this folder without --config:|./install.sh --resume" \
    "*To install something else from the file, use a new folder (each folder holds one deployment)."
fi
if [[ "$EXPORT_CONFIG" == true && ( -n "$INPUT_CONFIG" || "$RESUME" == true || "$DESTROY" == true ) ]]; then
  die_with_steps "--export-config only writes a file and stops; it cannot be combined with --config, --resume or --destroy." \
    "Export on its own:|./install.sh --export-config"
fi
# The dry-run notice is printed at the start of main, once the provider files are loaded.

# --destroy hands over to destroy.sh (same folder, same state file) so the
# operator never has to remember a second script.
run_destroy() {
  local -a args=()
  # Never while an installation from this folder is running (it holds the lock).
  exec 9>"${SCRIPT_DIR}/.install.lock"
  flock -n 9 || die_with_steps "An installation from this folder is running right now (it holds .install.lock); removing its resources now would break it. Nothing was deleted." \
    "Go to that installation (it usually runs in screen) and let it finish or stop it:|screen -ls; screen -d -r <name>" \
    "Then run the clean-up again:|./install.sh --destroy"
  [[ "$DRY_RUN" == true ]] && args+=(--dry-run)
  if [[ -f "$STATE_FILE" ]] && ! state_is_only_progress; then
    bash "${SCRIPT_DIR}/destroy.sh" "${args[@]}"
    exit $?
  fi
  if [[ -f "$STATE_FILE" ]]; then
    warn "The state file here holds only a phase-1 checkpoint, no resources; switching to clean-up by VM name."
  fi
  # No state file here (fresh clone, state already removed, or the deployment
  # was made from another folder): find the resources by VM name instead.
  resolve_provider || exit 1
  provider_destroy_by_name
}

# Interactive start menu when run without options from a terminal.
# The target (new GCP VMs or existing hosts) is part of the choice; it is
# passed on as INSTANA_PROVIDER (also into screen).
CLEANUP_DETAIL="deletes the VMs, disks and firewall rules of a lab this installer created on GCP;\nshows the list first and deletes only after you type DELETE.\nExisting hosts: only forgets the local record, the machines are never touched."
start_menu() {
  local choice recorded_provider="" note state=0
  if [[ -f "$STATE_FILE" ]] && ! state_is_only_progress; then
    state=1
    recorded_provider=$(jq -r '.provider // "gcp"' "$STATE_FILE" 2>/dev/null || echo gcp)
  fi
  local -a options=("Install on new Google Cloud VMs"$'\t'"the installer creates the VMs" \
                    "Install on existing hosts (SSH)"$'\t'"any cloud or on-prem: AWS, Azure, customer DC" \
                    "Dry-run"$'\t'"plan only, nothing is created")
  if (( state )); then
    options+=("Resume"$'\t'"continue the interrupted deployment recorded in this folder")
    if [[ "$recorded_provider" == ssh ]]; then
      options+=("Preview forgetting this deployment"$'\t'"shows what is removed here; nothing is changed" \
                "Forget this deployment"$'\t'"local record only; the hosts are never touched")
    else
      options+=("Preview deleting this deployment"$'\t'"lists its GCP resources; deletes nothing" \
                "Delete this deployment"$'\t'"its VM(s), disks and firewall rules on GCP, after you confirm")
    fi
  else
    options+=("Clean up a lab"$'\t'"$CLEANUP_DETAIL")
  fi
  [[ -f "$REPORT_FILE" ]] && options+=("Show report"$'\t'"UI URL, IP and hosts entries of the last installation here")
  options+=("Exit")
  if (( state )); then
    if [[ "$recorded_provider" == ssh ]]; then
      note="recorded here: existing hosts $(jq -r '[.ssh_target, .topology] | map(. // "?") | join(" / ")' "$STATE_FILE" 2>/dev/null)"
    else
      note="recorded here: $(jq -r '[.gcp_project, .gcp_zone, .topology] | map(. // "?") | join(" / ")' "$STATE_FILE" 2>/dev/null)"
    fi
  else
    note="no deployment in this folder"
  fi
  echo ""
  echo -e "${BOLD}Instana installer${RESET}   ${DIM}${note}${RESET}" | log_tee
  while true; do
    choice=$(PROMPT_CHOICE_DEFAULT="Install on new Google Cloud VMs" prompt_choice "What do you want to do?" "${options[@]}") || exit 0
    case "$choice" in
      "Install on new"*) START_CHOICE=install; export INSTANA_PROVIDER=gcp ;;
      "Install on existing"*) START_CHOICE=install; export INSTANA_PROVIDER=ssh ;;
      Dry-run)
        if dry_run_target_needed; then
          ask_dry_run_target 1 || continue
        fi
        START_CHOICE=dry-run; DRY_RUN=true
        provider_word_early
        warn "$(provider_text_or dry_run_banner "Dry-run mode — no GCP resources will be created.")" ;;
      Resume) START_CHOICE=resume; RESUME=true ;;
      Preview*) DRY_RUN=true; run_destroy ;;
      "Delete this"*|Forget*|"Clean up"*) run_destroy ;;
      "Show report") echo ""; cat "$REPORT_FILE"; echo ""; exit 0 ;;
      *) exit 0 ;;
    esac
    provider_word_early
    return 0
  done
}

# A dry-run in a terminal asks where it would install, unless that is
# already decided (recorded in this folder, INSTANA_PROVIDER, or --config).
dry_run_target_needed() {
  [[ -t 0 && -z "${INSTANA_PROVIDER:-}" && -z "${INPUT_CONFIG:-}" ]] || return 1
  [[ ! -f "$STATE_FILE" ]] || [[ -z "$(jq -r '.provider // (if .gcp_project then "gcp" else empty end)' "$STATE_FILE" 2>/dev/null)" ]] || return 1
  # Saved answers decide too; older ones without PROVIDER but with GCP_PROJECT are GCP.
  [[ ! -f "$CONFIG_FILE" ]] || [[ -z "$(jq -r '.parameters.PROVIDER // (if .parameters.GCP_PROJECT then "gcp" else empty end)' "$CONFIG_FILE" 2>/dev/null)" ]] || return 1
}

# ask_dry_run_target BACK — sets INSTANA_PROVIDER; returns 1 for "back"
# (BACK=1, from the start menu). Closed input: nothing to simulate, exit.
ask_dry_run_target() {
  local choice rc=0
  choice=$(PROMPT_CHOICE_DEFAULT="New Google Cloud VMs" NAV_CHOICE_BACK="$1" prompt_choice "Dry-run for:" \
    "New Google Cloud VMs"$'\t'"the installer would create the VMs" \
    "Existing hosts (SSH)"$'\t'"any cloud or on-prem: AWS, Azure, customer DC") || rc=$?
  (( rc != 3 )) || return 1
  (( rc == 0 )) || exit 0
  case "$choice" in
    "Existing hosts"*) export INSTANA_PROVIDER=ssh ;;
    *) export INSTANA_PROVIDER=gcp ;;
  esac
}

# =============================================================================
# SECTION 1 — PREREQUISITES CHECK
# =============================================================================
check_local_tools() {
  log "Checking required local tools..."
  local missing=()
  for tool in $(provider_required_tools) jq ssh-keygen curl mktemp timeout flock; do
    command -v "$tool" &>/dev/null || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}\nInstall them before running this script."
  fi
  ok "All required tools found."
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
  # In the question wizard an answer given before is the Enter default, also
  # inside blocks where "<" is not offered (WIZ_ACTIVE: the whole wizard).
  [[ "${WIZ_ACTIVE:-0}" != 1 || -z "${!var_name:-}" ]] || default="${!var_name}"
  # Changing one value from the plan: its current value is the default.
  [[ -n "${EDIT_KEY:-}" && "$var_name" == "$EDIT_KEY" && -n "${EDIT_DEFAULT:-}" ]] && default="$EDIT_DEFAULT"
  local value back="" nav="${NAV_ON:-0}" shown="$prompt_text"
  [[ "$nav" != 1 ]] || back=" $(back_label)"
  [[ -z "$default" ]] || shown+=" [${default}]"
  read_answer value "$(echo -e "${CYAN}?${RESET} ${BOLD}${shown}${RESET}${back}: ")" "$nav" || return $?
  echo "${value:-$default}"
}

# ── Reading answers ──────────────────────────────────────────────────────────
# back_label — how "back" is given at a text question: on a terminal the
# left-arrow key (or < and Enter), otherwise < and Enter.
back_label() {
  if [[ -t 0 ]]; then echo -e "${DIM}[← = back]${RESET}"; else echo "(< = back)"; fi
}

# strip_keys TEXT — TEXT without the escape sequences of arrow and other
# special keys (typed into a plain read they arrive as ^[[D and the like).
strip_keys() {
  local v="$1" re=$'\e''(\[[0-9;?]*[A-Za-z~]|O[A-Za-z])?'
  while [[ "$v" =~ $re ]]; do v="${v/"${BASH_REMATCH[0]}"/}"; done
  printf '%s' "$v"
}

# read_key_rest — after an ESC typed on a terminal: reads and prints the rest
# of that key's sequence only ([D for the left arrow, OD in application
# mode, [1;5D ...), never the characters typed after it.
read_key_rest() {
  local c seq=""
  IFS= read -rsn1 -t 0.1 c || { printf ''; return 0; }
  seq="$c"
  case "$c" in
    "[") while IFS= read -rsn1 -t 0.1 c; do seq+="$c"; [[ "$c" != [@-~] ]] || break; done ;;
    O) IFS= read -rsn1 -t 0.1 c && seq+="$c" ;;
  esac
  printf '%s' "$seq"
}

# rl_prompt TEXT — TEXT for readline's prompt: colour codes marked as
# invisible so line editing keeps the cursor in the right place.
rl_prompt() {
  local p="$1" out="" re=$'^([^\e]*)(\e\[[0-9;]*m)(.*)$'
  while [[ "$p" =~ $re ]]; do out+="${BASH_REMATCH[1]}"$'\001'"${BASH_REMATCH[2]}"$'\002'; p="${BASH_REMATCH[3]}"; done
  printf '%s' "${out}${p}"
}

# show_more_help — the longer explanation of the current question ("?").
show_more_help() {
  local line
  if (( ${#HINT_MORE[@]} == 0 )); then echo "    No more help for this question." >&2; return 0; fi
  for line in "${HINT_MORE[@]}"; do echo -e "    ${line}" >&2; done
}

# ctrl_d_cancel — Ctrl+D typed at a question in a terminal is a deliberate key,
# not a closed input: ask before cancelling. N (or Enter) asks the question
# again; Y, or Ctrl+D once more, cancels ("nothing was created"). Without a
# terminal a closed input still stops at once (read returns 1).
# Prompts must not be nested inside a $(...) that does more work after the
# prompt: after Y only the innermost subshell and the main shell stop.
ctrl_d_cancel() {
  local a="" rc=0
  echo "" >&2
  READ_ANSWER_SPACE=0 CANCEL_ASKING=1 read_answer a "$(echo -e "${YELLOW}!${RESET} Cancel the ${OPERATION_NAME:-installation}? [y/N]: ")" || rc=$?
  if (( rc != 0 )) || [[ "${a,,}" == y || "${a,,}" == yes ]]; then
    if [[ "$BASHPID" == "$$" ]]; then operator_cancel; fi
    kill -USR1 "$$"; exit 0
  fi
  echo "  Continuing; please answer the question again." >&2
}

# read_answer VAR PROMPT [BACK] — reads one typed answer into VAR.
# Returns 1 at the end of the input and, with BACK=1, 3 for "back": < and
# Enter. On a terminal the left-arrow key on an empty answer shows a <; the
# next key is read here (Enter goes back, Backspace takes it away, anything
# else continues the answer in readline), so "arrow, <, Enter" and
# "arrow, Enter" both go back exactly one question. "?" and Enter shows the
# longer help and asks again. On a terminal the answer is edited with
# readline (arrows, Backspace, Tab completes paths). Escape sequences of
# special keys never reach the answer.
# With READ_ANSWER_SPACE=1 (a long pick list with more to show) Space as the
# first key of an empty answer returns 4 at once, without Enter; an Enter typed
# right after it is swallowed. Without a terminal a line of only spaces
# returns 4.
read_answer() {
  local __var="$1" __p="$2" __back="${3:-0}" __v __first __rest __arrow __pre __k __backre='^[<]+$'
  while true; do
    __v="" __arrow=0 __pre=""
    if [[ ! -t 0 ]]; then
      if [[ "${READ_ANSWER_SPACE:-0}" == 1 ]]; then
        IFS= read -r __v || return 1
        [[ -z "$__v" || -n "${__v//[[:space:]]/}" ]] || return 4          # Space(s) + Enter: more
        __v="${__v#"${__v%%[![:space:]]*}"}"; __v="${__v%"${__v##*[![:space:]]}"}"
      else
        read -r __v || return 1
      fi
    elif [[ "$__back" == 1 || "${READ_ANSWER_SPACE:-0}" == 1 ]]; then
      printf '%s' "$__p" >&2
      if [[ -n "${READ_ANSWER_PENDING:-}" ]]; then __first="$READ_ANSWER_PENDING"; READ_ANSWER_PENDING=""
      else IFS= read -rsn1 __first || { echo "" >&2; return 1; }; fi
      if [[ "$__first" == " " && "${READ_ANSWER_SPACE:-0}" == 1 ]]; then   # Space: more, at once
        # An Enter typed right after Space belongs to it (Space + Enter);
        # any other key typed that fast starts the next answer.
        if IFS= read -rsn1 -t 0.3 __k && [[ -n "$__k" ]]; then READ_ANSWER_PENDING="$__k"; fi
        printf '\r\033[K' >&2; return 4
      fi
      if [[ "$__first" == $'\e' ]]; then
        __rest=$(read_key_rest)
        if [[ "$__back" != 1 ]] || [[ "$__rest" != "[D" && "$__rest" != "OD" ]]; then printf '\r\033[K' >&2; continue; fi   # other keys: ignored
        # Left arrow: "<" is shown; the next key decides (read here, not by
        # readline, so Backspace works the same at any typing speed).
        printf '<' >&2
        while IFS= read -rsn1 __k || { echo "" >&2; return 1; }; do
          case "$__k" in
            "") echo "" >&2; return 3 ;;                                  # Enter: back
            $'\x7f'|$'\b') break ;;                                        # Backspace: undo
            $'\e') read_key_rest >/dev/null ;;                             # another special key: ignored
            $'\x04') [[ "${CANCEL_ASKING:-0}" != 1 ]] || { echo "" >&2; return 1; }
                    ctrl_d_cancel; __pre=""; break ;;                       # Ctrl+D: cancel? (y/N)
            *) [[ "$__k" =~ ^[[:cntrl:]]$ ]] || { __pre="<${__k}"; break; } ;;  # other control keys: ignored
          esac
        done
        if [[ -z "$__pre" ]]; then printf '\r\033[K' >&2; continue; fi
      elif [[ "$__first" == $'\x04' ]]; then                          # Ctrl+D on an empty answer: cancel? (y/N)
        [[ "${CANCEL_ASKING:-0}" != 1 ]] || { echo "" >&2; return 1; }
        ctrl_d_cancel; continue
      elif [[ "$__first" =~ ^[[:cntrl:]]$ ]]; then
        printf '\r\033[K' >&2; continue                                 # Backspace or another control key: ignored
      else
        __pre="$__first"
      fi
      if [[ -z "$__first" ]]; then
        echo "" >&2
      else
        printf '\r\033[K' >&2
        read -e -r -i "$__pre" -p "$(rl_prompt "$__p")" __v || { [[ "${CANCEL_ASKING:-0}" != 1 ]] || { echo "" >&2; return 1; }; ctrl_d_cancel; continue; }
      fi
    else
      read -e -r -p "$(rl_prompt "$__p")" __v || { [[ "${CANCEL_ASKING:-0}" != 1 ]] || { echo "" >&2; return 1; }; ctrl_d_cancel; continue; }
    fi
    if [[ "$__v" == *$'\e'* ]]; then
      [[ "$__v" != *$'\e[D'* && "$__v" != *$'\eOD'* ]] || __arrow=1
      __v=$(strip_keys "$__v")
      __v="${__v#"${__v%%[![:space:]]*}"}"; __v="${__v%"${__v##*[![:space:]]}"}"
    fi
    if [[ "$__back" == 1 ]] && [[ "$__v" =~ $__backre || ( "$__arrow" == 1 && -z "$__v" ) ]]; then return 3; fi
    if [[ "$__v" == "?" ]]; then show_more_help; continue; fi
    printf -v "$__var" '%s' "$__v"
    return 0
  done
}

# Hidden input that still gives feedback: one • per typed character,
# Backspace removes the last one. Nothing typed is ever echoed or logged.
prompt_secret() {
  local var_name="$1" prompt_text="$2"
  local value="" ch extra="" keep=""
  if [[ "${NAV_ON:-0}" == 1 ]]; then
    keep="${!var_name:-}"
    if [[ -n "$keep" ]]; then extra=" ${DIM}[< Enter = back, Enter = keep the one typed before]${RESET}"; else extra=" ${DIM}[< Enter = back]${RESET}"; fi
  fi
  while true; do
    value=""
    if [[ ! -t 0 ]]; then
      read -rs value || return 1
    else
      printf '%b' "${CYAN}?${RESET} ${BOLD}${prompt_text}${RESET}${extra}: " >&2
      while IFS= read -rs -n1 ch; do
        if [[ -z "$ch" ]]; then break; fi                      # Enter
        if [[ "$ch" == $'\x04' ]]; then                          # Ctrl+D: cancel? (y/N), then ask again
          ctrl_d_cancel; value=""
          printf '%b' "${CYAN}?${RESET} ${BOLD}${prompt_text}${RESET}${extra}: " >&2
          continue
        fi
        if [[ "$ch" == $'\x7f' || "$ch" == $'\x08' ]]; then     # Backspace
          if [[ -n "$value" ]]; then value="${value%?}"; printf '\b \b' >&2; fi
          continue
        fi
        if [[ "$ch" == $'\e' ]]; then                          # arrow or other special key: ignored
          read_key_rest >/dev/null
          continue
        fi
        value+="$ch"
        printf '•' >&2
      done || { echo "" >&2; return 1; }
      echo "" >&2
    fi
    [[ "$value" != *$'\e'* ]] || value=$(strip_keys "$value")
    [[ "${NAV_ON:-0}" != 1 || "$value" != "<" ]] || return 3
    if [[ "$value" == "?" ]]; then show_more_help; continue; fi
    echo "${value:-$keep}"
    return 0
  done
}

# prompt_choice TEXT OPTION... — prints the chosen option. With
# PROMPT_CHOICE_DEFAULT set to one of the options (only for this call:
# PROMPT_CHOICE_DEFAULT=x prompt_choice ...), Enter selects it.
# An option may carry a short explanation after a TAB ("label<TAB>detail");
# it is shown dimmed (a literal \n in it starts a new line), and only the
# label is printed as the answer. With NAV_CHOICE_BACK=1 the list ends with
# "0) ← back" (0, < or the left-arrow key: return 3).
# PROMPT_CHOICE_NEWEST=1 marks a version list (newest first): without another
# default, Enter selects 1 and the prompt says so.
# A list of more than 12 options shows 10 at a time: Space (on a terminal at
# once, otherwise Space or m and Enter) shows the next 10, a and Enter all the
# rest. Numbering stays global and any number of the whole list is accepted.
PROMPT_CHOICE_PAGE=10
prompt_choice() {
  local prompt_text="$1"; shift
  local options=("$@") def="${PROMPT_CHOICE_DEFAULT:-}" def_i=0 back="${NAV_CHOICE_BACK:-0}" newest="${PROMPT_CHOICE_NEWEST:-0}"
  local opt label detail line width=0 n=$# shown=0 page=$# what="more options" i
  (( n <= 12 )) || page=$PROMPT_CHOICE_PAGE
  [[ "$newest" != 1 ]] || what="older versions"
  for opt in "${options[@]}"; do label="${opt%%$'\t'*}"; (( ${#label} <= width )) || width=${#label}; done
  for (( i = 1; i <= n; i++ )); do
    label="${options[$((i - 1))]%%$'\t'*}"
    # The default matches an option exactly or its first word ("demo" → "demo (suggested)").
    [[ -z "$def" || "$def_i" != 0 ]] || [[ "$label" != "$def" && "$label" != "$def "* ]] || def_i=$i
  done
  (( def_i != 0 || newest != 1 )) || def_i=1
  # _pc_show_upto N — prints the options after the ones already shown, up to N.
  _pc_show_upto() {
    local upto=$1
    (( upto <= n )) || upto=$n
    while (( shown < upto )); do
      opt="${options[$shown]}"; (( ++shown ))
      label="${opt%%$'\t'*}"; detail=""
      [[ "$opt" != *$'\t'* ]] || detail="${opt#*$'\t'}"
      if [[ -z "$detail" ]]; then
        echo "  $shown) $label" >&2
      elif [[ "$detail" != *'\n'* ]]; then
        printf '  %s) %-*s   %b\n' "$shown" "$width" "$label" "${DIM}${detail}${RESET}" >&2
      else
        echo "  $shown) $label" >&2
        while IFS= read -r line; do echo -e "       ${DIM}${line}${RESET}" >&2; done <<< "${detail//'\n'/$'\n'}"
      fi
    done
  }
  _pc_more_line() {
    local left=$(( n - shown )) next=$PROMPT_CHOICE_PAGE
    (( left > 0 )) || return 0
    (( next <= left )) || next=$left
    echo -e "  ${DIM}… ${left} ${what} ($(( shown + 1 ))-${n}): Space = next ${next}, a = all, or type any number${RESET}" >&2
  }
  echo -e "${CYAN}?${RESET} ${BOLD}${prompt_text}${RESET}" >&2
  _pc_show_upto "$page"
  [[ "$back" != 1 ]] || echo "  0) ← back" >&2
  _pc_more_line
  local choice range="1-${n}" rc
  if (( def_i != 0 )); then
    range+=", Enter = ${def_i}"
    [[ "$newest" != 1 || "$def_i" != 1 ]] || range+=" newest"
  fi
  while true; do
    rc=0; READ_ANSWER_SPACE=$(( shown < n ? 1 : 0 )) read_answer choice "$(echo -e "  ${BOLD}Select [${range}]:${RESET} ")" "$back" || rc=$?
    if (( shown < n )) && [[ "$rc" == 4 || ( "$rc" == 0 && "${choice,,}" =~ ^(m|more)$ ) ]]; then
      _pc_show_upto $(( shown + PROMPT_CHOICE_PAGE )); _pc_more_line; continue
    fi
    if (( shown < n )) && [[ "$rc" == 0 && "${choice,,}" =~ ^(a|all)$ ]]; then
      _pc_show_upto "$n"; continue
    fi
    (( rc == 0 )) || return "$rc"
    [[ "$back" != 1 || "$choice" != 0 ]] || return 3
    [[ -n "$choice" || "$def_i" == 0 ]] || choice=$def_i
    [[ "$choice" =~ ^[0-9]+$ ]] && (( 10#$choice >= 1 && 10#$choice <= n )) && break
    if [[ "$back" == 1 ]]; then echo "Invalid selection: type a number from 1 to ${n}, or 0 to go back." >&2
    else echo "Invalid selection: type a number from 1 to ${n}." >&2; fi
  done
  label="${options[$(( 10#$choice - 1 ))]}"
  echo "${label%%$'\t'*}"
}

# Yes/no questions always show both answers and which one Enter selects,
# e.g. "[y/N]" = type y for yes, Enter or n for no.
prompt_yes_no() {
  local prompt_text="$1" default="${2:-N}"
  local answer hint
  if [[ "${default^^}" == Y ]]; then hint="[Y/n] (Enter = yes)"; else hint="[y/N] (Enter = no)"; fi
  while true; do
    read_answer answer "$(echo -e "${CYAN}?${RESET} ${BOLD}${prompt_text}${RESET} ${hint}: ")" || return 1
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "  Please answer y (yes) or n (no)." >&2 ;;
    esac
  done
}

# The plan's question for a new deployment: prints yes, edit, save or no.
# Enter (or closed input) = no, like every other start confirmation.
prompt_plan_decision() {
  local answer
  while true; do
    read_answer answer "$(echo -e "${CYAN}?${RESET} ${BOLD}$([[ "$DRY_RUN" == true ]] && echo "Run the dry-run?" || echo "Start now?") [y/e/s/N]${RESET} ${DIM}? = more${RESET}: ")" || { echo no; return 0; }
    case "${answer,,}" in
      y|yes) echo yes; return 0 ;;
      e|edit) echo edit; return 0 ;;
      s|save) echo save; return 0 ;;
      ""|n|no) echo no; return 0 ;;
      *) echo "  Please answer y (start), e (edit a value), s (save to a file) or n (cancel)." >&2 ;;
    esac
  done
}

# hint LINE [MORE...] — the short explanation shown before a question: only
# its first line; the other lines are the longer help, shown when "?" is
# answered (or always with --verbose / INSTANA_VERBOSE=1).
HINT_MORE=()
hint() {
  local line
  HINT_MORE=("${@:2}")
  if [[ "${INSTANA_VERBOSE:-0}" == 1 ]]; then
    for line in "$@"; do echo -e "    ${DIM}${line}${RESET}" >&2; done
    return 0
  fi
  if (( $# > 1 )); then echo -e "    ${DIM}${1}  ? = more${RESET}" >&2
  else echo -e "    ${DIM}${1}${RESET}" >&2; fi
}

# opt_detail NAME LINE... — "NAME<TAB>text" from the line "NAME: text" (the
# explanation shown dimmed next to a pick-list option), or NAME alone.
opt_detail() {
  local name="$1" line; shift
  for line in "$@"; do
    [[ "$line" != "${name}: "* ]] || { printf '%s\t%s' "$name" "${line#"${name}: "}"; return 0; }
  done
  printf '%s' "$name"
}

# type_detail demo|production — the IBM minimum of a single-node type.
type_detail() {
  case "$1" in
    demo) echo "16 vCPU / 64 GB, disks 500/300/250/150 GB" ;;
    production) echo "28 vCPU / 112 GB, disks 1200/1000/1000/500 GB" ;;
  esac
}

# ── Interactive input never aborts silently ──────────────────────────────────
# An empty answer or an invalid value re-asks the question. The installer only
# stops when the operator explicitly confirms the cancellation, or when stdin
# is closed (non-interactive run with no more input).
# operator_cancel — the operator chose to cancel: not an error (exit 0, like
# answering N at the plan), and it says that nothing was created.
# Once this deployment has resources (VMs, disks, changed hosts), a cancel
# leaves an incomplete deployment: that is said plainly (they are billed or
# changed), with how to continue or remove it, and the exit code is non-zero.
operator_cancel() {
  ERROR_REPORTED=true
  local op="${OPERATION_NAME:-installation}"
  if [[ "$op" == installation && "${DRY_RUN:-false}" != true ]] && declare -F deployment_has_resources >/dev/null &&
     deployment_has_resources 2>/dev/null; then
    local undo
    if [[ "$(provider_name)" == ssh ]]; then
      undo="or forget the local record with ./install.sh --destroy (the changes on the hosts stay)"
      warn "Installation cancelled by the operator. Changes on the existing host(s) were already made; the deployment is incomplete."
    else
      undo="or remove them with ./install.sh --destroy"
      warn "Installation cancelled by the operator. Resources of this deployment exist and are billed; the deployment is incomplete."
    fi
    log "Continue where it stopped with ./install.sh --resume, ${undo}."
    mark_stopped "installation cancelled by the operator — resources of this deployment exist (./install.sh --resume or ./install.sh --destroy)"
    exit 1
  fi
  log "${op^} cancelled by the operator. Nothing was created or changed."
  mark_stopped "${op} cancelled by the operator — nothing was created or changed"
  exit 0
}

# mark_stopped TEXT — inside screen, tells the outer terminal that this run
# ended without installing (cancelled, not started, parameters saved), so it
# does not report "Completed".
mark_stopped() {
  [[ -z "${INSTANA_EXIT_MARKER:-}" ]] || printf '%s\n' "$1" > "${INSTANA_EXIT_MARKER}.stopped" 2>/dev/null || true
}

# The outer terminal's line for a finished screen session: the stop reason
# written by the inner run, or empty when it really completed.
screen_stop_reason() {
  local f="${1}.stopped" r=""
  [[ -f "$f" ]] && { r=$(head -1 "$f"); rm -f "$f"; }
  printf '%s' "$r"
}

confirm_cancel() {
  local answer
  local op="${OPERATION_NAME:-installation}"
  read_answer answer "$(echo -e "${YELLOW}!${RESET} No valid value entered. Cancel the ${op}? [y/N]: ")" ||
    die "Input ended before the answers were complete; ${op} cancelled. Nothing was changed."
  case "${answer,,}" in
    y|yes) operator_cancel ;;
  esac
  echo "  Continuing; please answer the question again." >&2
}

# prompt_required VAR TEXT DEFAULT [VALIDATOR [LABEL]]
# Sets the variable VAR directly in the calling shell (no command substitution),
# so validators may print, set globals and call die normally. VALIDATOR is called
# as: VALIDATOR VALUE LABEL and must print its own error and return non-zero.
prompt_required() {
  local var_name="$1" prompt_text="$2" default="${3:-}" validator="${4:-}" label="${5:-}"
  local value rc
  NAV_ASKED=1
  while true; do
    rc=0; value=$(prompt "$var_name" "$prompt_text" "$default") || rc=$?
    if (( rc == 3 )); then NAV_BACK=1; return 0; fi
    (( rc == 0 )) || die "Input ended before the parameters were complete; installation cancelled. Nothing was created."
    if [[ -z "$value" ]]; then
      confirm_cancel
      continue
    fi
    if [[ -n "$validator" ]] && ! "$validator" "$value" "$label"; then
      confirm_cancel
      continue
    fi
    printf -v "$var_name" '%s' "$value"
    HINT_MORE=()
    return 0
  done
}

# prompt_secret_required VAR TEXT LABEL — same contract, hidden input.
prompt_secret_required() {
  local var_name="$1" prompt_text="$2" label="$3"
  local value rc
  NAV_ASKED=1
  while true; do
    rc=0; value=$(prompt_secret "$var_name" "$prompt_text") || rc=$?
    if (( rc == 3 )); then NAV_BACK=1; return 0; fi
    (( rc == 0 )) || die "Input ended before the parameters were complete; installation cancelled. Nothing was created."
    if validate_secret "$value" "$label"; then
      printf -v "$var_name" '%s' "$value"
      HINT_MORE=()
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

validate_fqdn() {
  local fqdn="$1"
  if ! [[ "$fqdn" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    err "Invalid FQDN: ${fqdn}"; return 1
  fi
}

# =============================================================================
# SECTION 4 — COLLECT ALL PARAMETERS
# =============================================================================
# use_provider_default_name VAR TEXT_KEY — in a run from an input file, a name
# the file leaves out is taken from the provider when it offers one (existing
# hosts: the host's own name) instead of being asked. GCP offers none.
use_provider_default_name() {
  local var="$1" name
  [[ "$PARAMS_SOURCE" == import && "$var" != "$EDIT_KEY" && -z "${IMPORTED[$var]:-}" ]] || return 1
  name=$(provider_text "$2")
  [[ -n "$name" ]] && validate_vm_name "$name" "$var" >/dev/null 2>&1 || return 1
  printf -v "$var" '%s' "$name"
  log "${var} = ${name} (not in $(input_source_label); the host's own name)"
}

# ── Question wizard: one step per question, "<" goes back ────────────────────
# collect_parameters runs WIZ_STEPS in order. A step asks at most one question
# (or does one automatic job) and is skipped when a value comes from an input
# file. Answering "<" (NAV_BACK) re-runs the previous step that really asked;
# every later step then runs again with its earlier answer as the Enter
# default. When an answer CHANGES on the way back, the answers that depend on
# it are cleared (wiz_dependents) and asked again. Heavy steps (connecting to
# hosts, package, versions) are not repeated by moving forward again unless
# something they depend on changed; there is no "<" inside them.
NAV_ON=0; NAV_BACK=0; NAV_ASKED=0; WIZ_EXIT=done; WIZ_ACTIVE=0
declare -A WIZ_DONE=()
WIZ_STEPS=(wiz_ssh_hosts wiz_ssh_login wiz_topology wiz_mode wiz_type wiz_ubuntu wiz_location wiz_cidr
  wiz_vm_name wiz_node0_name wiz_node1_name wiz_node2_name wiz_size wiz_host_params
  wiz_domain wiz_tenant wiz_unit wiz_admin_password wiz_download_key wiz_agent_key
  wiz_sales_key wiz_airgap wiz_versions wiz_tls wiz_tls_crt wiz_tls_key wiz_kube wiz_stanctl_timeout)

# ask_choice VAR TEXT OPTION... — sets VAR to the chosen option; the current
# value (or the saved one when editing saved parameters) is the Enter default.
ask_choice() {
  local var="$1" text="$2" def v rc=0; shift 2
  def="${!var:-}"
  [[ -n "$def" || "$CONFIG_LOADED" != true || ! -f "${CONFIG_FILE:-}" ]] ||
    def=$(jq -r --arg k "$var" '.parameters[$k] // empty' "$CONFIG_FILE" 2>/dev/null || true)
  # The usual answer for a first-time operator (ASK_DEFAULT=... ask_choice ...).
  [[ -n "$def" ]] || def="${ASK_DEFAULT:-}"
  NAV_ASKED=1
  v=$(PROMPT_CHOICE_DEFAULT="$def" NAV_CHOICE_BACK="${NAV_ON:-0}" prompt_choice "$text" "$@") || rc=$?
  case "$rc" in
    0) printf -v "$var" '%s' "$v"; HINT_MORE=() ;;
    3) NAV_BACK=1 ;;
    *) die "Input ended before the parameters were complete; installation cancelled. Nothing was created." ;;
  esac
}

# Keys a step sets (compared before/after a revisit to find a changed answer).
wiz_keys() {
  case "$1" in
    wiz_ssh_hosts) echo TOPOLOGY VM_HOST NODE0_HOST NODE1_HOST NODE2_HOST ;;
    wiz_ssh_login) echo SSH_USER SSH_KEY_PATH SSH_PORT ;;
    wiz_topology) echo TOPOLOGY ;;
    wiz_mode) echo INSTALL_MODE ;;
    wiz_type) echo INSTALL_TYPE ;;
    wiz_location) provider_param_keys ;;
    wiz_size) echo SIZE_CHOICE ;;
    wiz_download_key) echo DOWNLOAD_KEY ;;
    wiz_tls) echo TLS_MODE ;;
  esac
}

# What a changed answer of STEP invalidates: variables to clear and heavy
# steps (WIZ_DONE) to run again.
wiz_dependents() {
  local v
  case "$1" in
    wiz_ssh_hosts) echo INSTALL_TYPE VM_NAME NODE0_NAME NODE1_NAME NODE2_NAME SSH_VIA_PRIVATE done:host_params ;;
    wiz_ssh_login) echo done:host_params ;;
    wiz_topology)
      echo INSTALL_TYPE VM_NAME NODE0_NAME NODE1_NAME NODE2_NAME SIZE SIZE_CHOICE VM_CPUS VM_RAM_GB done:host_params
      if [[ "$(provider_name)" == ssh ]]; then echo VM_HOST NODE0_HOST NODE1_HOST NODE2_HOST SSH_VIA_PRIVATE done:location; fi ;;
    wiz_type) echo SIZE SIZE_CHOICE VM_CPUS VM_RAM_GB done:host_params ;;
    wiz_mode) echo AIRGAP_ARCHIVE AIRGAP_INSPECTED BACKEND_VERSION STANCTL_CLI_VERSION STANCTL_APT_VERSION \
                   REQUESTED_BACKEND_VERSION REQUESTED_STANCTL_APT_VERSION done:airgap done:versions ;;
    wiz_location)
      echo done:host_params
      [[ "$(provider_name)" != ssh ]] || echo VM_NAME NODE0_NAME NODE1_NAME NODE2_NAME ;;
    wiz_size) echo VM_CPUS VM_RAM_GB ;;
    wiz_download_key) echo done:versions done:airgap ;;
    wiz_tls) echo TLS_CRT_PATH TLS_KEY_PATH ;;
  esac
  case "$1" in wiz_ssh_hosts|wiz_topology|wiz_type|wiz_location) for v in $(compgen -v DISK_DEV_ || true); do echo "$v"; done ;; esac
}

wiz_snapshot() {
  local k out=""
  for k in $(wiz_keys "$1"); do out+="${k}=${!k:-}|"; done
  printf '%s' "$out"
}

# Only a real change (the step had an answer before) clears its dependents;
# they are then asked again, also when they came from a file or the plan.
wiz_clear_dependents() {
  local d
  for d in $(wiz_dependents "$1"); do
    if [[ "$d" == done:* ]]; then unset "WIZ_DONE[${d#done:}]"; continue; fi
    printf -v "$d" '%s' ""
    unset "IMPORTED[$d]"
  done
}

# wiz_run STEP... — sets WIZ_EXIT=back when "<" is answered at the first
# question that was asked (the caller decides where that leads).
wiz_run() {
  local -a steps=("$@") stack=()
  local i=0 before step revisit=-1
  WIZ_EXIT=done; WIZ_ACTIVE=1
  while (( i < ${#steps[@]} )); do
    step="${steps[i]}"
    before=$(wiz_snapshot "$step")
    # A step reached with "<" runs again even when it is a heavy one.
    WIZ_REVISIT=""; (( i != revisit )) || WIZ_REVISIT="$step"
    revisit=-1
    NAV_BACK=0; NAV_ASKED=0; NAV_ON=1
    # Nothing to go back to (first question, no menu before it): no "back".
    if (( ${#stack[@]} == 0 )) && [[ "${WIZ_BACK_EXIT:-0}" != 1 && -z "${EDIT_KEY:-}" ]]; then NAV_ON=0; fi
    "$step"
    NAV_ON=0; WIZ_REVISIT=""
    if (( NAV_BACK )); then
      if (( ${#stack[@]} == 0 )); then WIZ_EXIT=back; WIZ_ACTIVE=0; NAV_ON=0; NAV_BACK=0; return 0; fi
      i="${stack[-1]}"; unset 'stack[-1]'
      revisit=$i
      continue
    fi
    if [[ -n "$before" && "$before" != *"=|"* && "$(wiz_snapshot "$step")" != "$before" ]]; then
      wiz_clear_dependents "$step"
    fi
    (( NAV_ASKED == 0 )) || stack+=("$i")
    (( ++i ))
  done
  WIZ_ACTIVE=0; NAV_ON=0; NAV_BACK=0
}

wiz_topology() {
  use_imported TOPOLOGY && return 0
  # Existing hosts, typed answers: 1 host = single-node, 3 = three-node.
  [[ "$(provider_name)" != ssh || "$PARAMS_SOURCE" == import || -z "${TOPOLOGY:-}" ]] || return 0
  local -a topo_hint
  mapfile -t topo_hint < <(provider_text_or topology_hint \
    "single-node: everything on one VM (labs, demos, small setups)." \
    "three-node: Instana spread over three VMs, IBM 'production' type, needs 3x n2-standard-16.")
  ASK_DEFAULT=single-node ask_choice TOPOLOGY "Select deployment topology:" \
    "$(opt_detail single-node "${topo_hint[@]}")" "$(opt_detail three-node "${topo_hint[@]}")"
}

wiz_mode() {
  use_imported INSTALL_MODE && return 0
  local -a mode_hint
  mapfile -t mode_hint < <(provider_text_or mode_hint \
    "online: the Instana VM downloads stanctl and images from the Instana repository itself (simplest)." \
    "air-gapped: everything comes from one instana-airgapped.tar.gz package; you will be guided to obtain or build it.")
  ASK_DEFAULT=online ask_choice INSTALL_MODE "Select installation connectivity mode:" \
    "$(opt_detail online "${mode_hint[@]}")" "$(opt_detail air-gapped "${mode_hint[@]}")"
}

wiz_type() {
  if [[ "$TOPOLOGY" != "single-node" ]]; then
    INSTALL_TYPE="production"
    log "Three-node clusters require production installation type (per documentation)."
    return 0
  fi
  use_imported INSTALL_TYPE && return 0
  local suggested=demo why=""
  if [[ "$(provider_name)" == ssh && -n "${VM_HOST:-}" ]] && declare -F ssh_type_suggestion >/dev/null; then
    read -r suggested why <<< "$(ssh_type_suggestion "$VM_HOST")"
    hint "Suggested from the checks above: ${suggested} (${why})."
    while true; do
      ASK_DEFAULT=$suggested ask_choice INSTALL_TYPE "Select installation type:" \
        "demo$([[ $suggested == demo ]] && echo ' (suggested)')"$'\t'"$(type_detail demo)" \
        "production$([[ $suggested == production ]] && echo ' (suggested)')"$'\t'"$(type_detail production)"
      INSTALL_TYPE="${INSTALL_TYPE%% *}"
      (( NAV_BACK == 0 )) || return 0
      [[ "$INSTALL_TYPE" == production && "$suggested" == demo ]] || return 0
      warn "This host is too small for production (${why}); the installation would stop at the host checks. Choose demo, or < to pick another host."
      INSTALL_TYPE=""
    done
  fi
  hint "demo = lab / evaluation, production = IBM-sized (larger, more expensive)."
  ASK_DEFAULT=demo ask_choice INSTALL_TYPE "Select installation type:" \
    "demo"$'\t'"$(type_detail demo)" "production"$'\t'"$(type_detail production)"
}

# Ubuntu version — from docs: Ubuntu 24.04 and 22.04 only
# Not asked: the IBM-supported default (or the saved value) is used and shown
# in the plan; E at the plan changes it.
wiz_ubuntu() {
  provider_uses_param UBUNTU_VERSION || return 0
  use_imported UBUNTU_VERSION && return 0
  if [[ "${EDIT_KEY:-}" == UBUNTU_VERSION ]]; then
    hint "Operating system image for the new VM(s). 24.04 is the current IBM-supported default."
    ask_choice UBUNTU_VERSION "Select Ubuntu version (supported: 24.04, 22.04):" "ubuntu-2404-lts-amd64" "ubuntu-2204-lts"
    return 0
  fi
  [[ -n "${UBUNTU_VERSION:-}" ]] || UBUNTU_VERSION=$(gcp_saved UBUNTU_VERSION 2>/dev/null || true)
  [[ -n "${UBUNTU_VERSION:-}" ]] || UBUNTU_VERSION=ubuntu-2404-lts-amd64
}

# Provider location questions (GCP project/zone/network, or the existing hosts
# and the SSH login). Asked as one block; "<" is not offered inside it yet.
wiz_location() {
  if [[ "$(provider_name)" == gcp ]]; then provider_collect_location_params; return 0; fi
  # Existing hosts, typed answers: done by wiz_ssh_hosts and wiz_ssh_login.
  [[ "$PARAMS_SOURCE" == import ]] || return 0
  [[ -z "${WIZ_DONE[location]:-}" || "${WIZ_REVISIT:-}" == wiz_location ]] || return 0
  local NAV_ON=0
  provider_collect_location_params
  WIZ_DONE[location]=1
  NAV_ASKED=0   # a block without "<": going back passes over it (E at the plan changes its values)
}

wiz_cidr() {
  provider_uses_param SSH_SOURCE_CIDR || return 0
  # Typed answers: part of the location block ("Use detected").
  [[ "$PARAMS_SOURCE" == import ]] || return 0
  use_imported SSH_SOURCE_CIDR && return 0
  hint "Public IP that may open SSH to the VM(s); default = this machine's own IP with /32." \
       "0.0.0.0/0 would allow the whole internet; avoid it."
  prompt_required "SSH_SOURCE_CIDR" "CIDR allowed to SSH to the VM(s)" "$(detect_public_cidr)" validate_cidr
}

wiz_vm_name() {
  [[ "$TOPOLOGY" == "single-node" ]] || return 0
  use_imported VM_NAME || use_provider_default_name VM_NAME default_vm_name && return 0
  wiz_host_name VM_NAME default_vm_name && return 0
  local -a name_hint
  mapfile -t name_hint < <(provider_text_or vm_name_hint \
    "Name of the new VM (its disks get the same name + -analytics, -metrics, -objects, -data)." \
    "Lowercase letters, digits and hyphens, starting with a letter, at most 63 characters." \
    "It must not exist yet in the zone (checked right after you answer).")
  hint "${name_hint[@]}"
  prompt_required "VM_NAME" "VM name" "$(provider_text_or default_vm_name instana-backend)" validate_new_vm_name VM_NAME
}

# Existing hosts, typed answers: the name is the host's own short name (made
# unique among the nodes), not asked; the plan shows it, E changes it.
wiz_host_name() {
  local var="$1" name n=2 other dup
  [[ "$(provider_name)" == ssh && "$PARAMS_SOURCE" != import && "${EDIT_KEY:-}" != "$var" ]] || return 1
  [[ -z "${!var:-}" ]] || return 0
  name=$(provider_text "$2")
  validate_vm_name "$name" "$var" >/dev/null 2>&1 || return 1
  local base="$name"
  while true; do
    dup=false
    for other in NODE0_NAME NODE1_NAME; do [[ "$other" < "$var" && "${!other:-}" == "$name" ]] && dup=true; done
    [[ "$dup" == true ]] || break
    name="${base}-${n}"; (( ++n ))
  done
  printf -v "$var" '%s' "$name"
  log "${var} = ${name} (the host's own name; E at the plan changes it)"
}

# wiz_node_name N LABEL — one of the three node names.
wiz_node_name() {
  local n="$1" label="$2" var="NODE${1}_NAME"
  [[ "$TOPOLOGY" == "three-node" ]] || return 0
  use_imported "$var" || use_provider_default_name "$var" "default_node${n}_name" && return 0
  wiz_host_name "$var" "default_node${n}_name" && return 0
  [[ "$n" != 0 ]] ||
    hint "$(provider_text_or node_names_hint "Names of the three new VMs. Node 0 runs the backend and stanctl, node 1 the data stores, node 2 the rest.")"
  prompt_required "$var" "$label" "$(provider_text_or "default_node${n}_name" "instana-${n}")" validate_node_name "$var"
}
wiz_node0_name() { wiz_node_name 0 "Node 0 name (instana-0, backend)"; }
wiz_node1_name() { wiz_node_name 1 "Node 1 name (instana-1, data store)"; }
wiz_node2_name() { wiz_node_name 2 "Node 2 name (instana-2, other)"; }

# Machine type selection
wiz_size() { show_hw_requirements_and_pick_machine_type; }

# Provider values that need the names and the size (existing hosts: data disks).
wiz_host_params() {
  # Existing hosts, typed answers: one proposed disk mapping (Enter / c / <).
  if [[ "$(provider_name)" == ssh && "$PARAMS_SOURCE" != import && "${EDIT_KEY:-}" != DISK_DEV_* ]]; then
    ssh_disk_block
    WIZ_DONE[host_params]=1
    return 0
  fi
  [[ -z "${WIZ_DONE[host_params]:-}" || "${WIZ_REVISIT:-}" == wiz_host_params ]] || return 0
  local NAV_ON=0
  provider_collect_host_params
  WIZ_DONE[host_params]=1
  NAV_ASKED=0
}

# FQDN
wiz_domain() {
  use_imported BASE_DOMAIN && return 0
  echo ""
  log "DNS entries required (all must point to the VM's external IP):"
  log "  <base_domain>"
  log "  agent-acceptor.<base_domain>"
  log "  opamp-acceptor.<base_domain>"
  log "  otlp-http.<base_domain>"
  log "  otlp-grpc.<base_domain>"
  log "  <unit>-<tenant>.<base_domain>"
  echo ""
  local suggest=""
  suggest=$(lab_domain_suggestion)
  if [[ -n "$suggest" ]]; then
    hint "Domain for the UI; suggested: ${suggest#instana.} (sslip.io, no DNS setup needed)." \
         "sslip.io resolves every sub-name to the host's public IP, so a lab needs no DNS records." \
         "Use your own domain (you must be able to add DNS records) for anything that is not a short-lived lab."
  else
    hint "Domain for the UI, e.g. instana.example.com (you add its DNS records)." \
         "You must own the domain and be able to add DNS records." \
         "For a lab you can instead put the entries printed at the end into /etc/hosts on your computer."
  fi
  prompt_required "BASE_DOMAIN" "Base domain (e.g. instana.example.com)" "$suggest" validate_fqdn
}

# lab_domain_suggestion — instana.<a-b-c-d>.sslip.io for an existing-host lab
# whose public IP is known before Start; nothing for air-gapped installations
# (or GCP, where the IP exists only after phase 3).
lab_domain_suggestion() {
  [[ "$(provider_name)" == ssh && "${INSTALL_MODE:-}" == online ]] || return 0
  local host ip
  host=$(prov_ssh_hosts 2>/dev/null | head -1)
  [[ -n "$host" ]] || return 0
  ip=$(prov_ssh_get_ip "$host" "" "" public 2>/dev/null || true)
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && ! prov_ssh_is_private "$ip" || return 0
  [[ "$ip" != 127.* && "$ip" != 169.254.* ]] || return 0
  printf 'instana.%s.sslip.io\n' "${ip//./-}"
}

# Tenant / unit names
wiz_tenant() {
  use_imported TENANT_NAME && return 0
  hint "Tenant and unit form the UI address <unit>-<tenant>.<domain>." \
       "They are Instana's two-level naming; any short lowercase names are fine (e.g. company name and 'prod' or 'lab')."
  prompt_required "TENANT_NAME" "Tenant name (max 15 chars, lowercase alphanumeric, start with letter)" "tenant0" validate_tenant_unit_name "Tenant name"
}
wiz_unit() {
  use_imported UNIT_NAME && return 0
  hint "The unit is the second part of the UI address <unit>-<tenant>.<domain>, e.g. 'prod' or 'lab'."
  prompt_required "UNIT_NAME" "Unit name (max 15 chars, lowercase alphanumeric, start with letter)" "unit0" validate_tenant_unit_name "Unit name"
}

# Admin password
wiz_admin_password() {
  use_imported_secret ADMIN_PASSWORD && return 0
  echo ""
  log "Instana admin password (will not be stored in any file or log)"
  hint "Password you choose now for the first UI user admin@instana.local (shown as •)." \
       "A password that is only '<' or '?' is not possible here ('<' alone goes back, '?' shows this help); inside a password both are fine."
  prompt_secret_required "ADMIN_PASSWORD" "Instana admin password" "Admin password"
}

# Instana keys — never logged or stored in local state/logs
wiz_download_key() {
  use_imported_secret DOWNLOAD_KEY && return 0
  echo ""
  log "Instana license keys (will not be stored in any file or log)"
  hint "Download key: access to IBM's software repository (from your Instana entitlement)." \
       "The three keys come from the Instana portal or the IBM license center:" \
       "download key = access to the software repository; agent key = lets agents connect; sales key = your license." \
       "Paste each one (typing shows • per character)." \
       "A key that is only '<' or '?' is not possible here ('<' alone goes back, '?' shows this help)."
  prompt_secret_required "DOWNLOAD_KEY" "Instana download key" "Download key"
}
wiz_agent_key() {
  use_imported_secret AGENT_KEY && return 0
  hint "Agent key: lets the Instana agents connect to this backend." \
       "A key that is only '<' or '?' is not possible here ('<' alone goes back, '?' shows this help)."
  prompt_secret_required "AGENT_KEY" "Instana agent key" "Agent key"
}
wiz_sales_key() {
  use_imported_secret SALES_KEY && return 0
  hint "Sales key: your Instana license." \
       "A key that is only '<' or '?' is not possible here ('<' alone goes back, '?' shows this help)."
  prompt_secret_required "SALES_KEY" "Instana sales key" "Sales key"
}

wiz_airgap() {
  [[ "$INSTALL_MODE" == "air-gapped" ]] || return 0
  [[ -z "${WIZ_DONE[airgap]:-}" ]] || return 0
  local NAV_ON=0
  obtain_airgapped_archive
  WIZ_DONE[airgap]=1
  NAV_ASKED=0
}

wiz_versions() {
  [[ -z "${WIZ_DONE[versions]:-}" ]] || return 0
  local NAV_ON=0
  select_versions_upfront
  WIZ_DONE[versions]=1
  NAV_ASKED=0
}

# TLS certificate
# A certificate in the installer folder or the current folder whose names
# cover the base domain, with its key next to it: "crt key", or nothing.
find_tls_cert_for_domain() {
  command -v openssl >/dev/null 2>&1 && [[ -n "${BASE_DOMAIN:-}" ]] || return 0
  # Offered only: own regular files (no links), a certificate whose names
  # cover the domain AND its sub-names (*.domain: UI, acceptors), and the key
  # that belongs to it (same public key).
  local crt key base names cpub kpub
  for crt in "$SCRIPT_DIR"/*.crt "$SCRIPT_DIR"/fullchain*.pem "$PWD"/*.crt "$PWD"/fullchain*.pem; do
    [[ -f "$crt" && ! -L "$crt" && -O "$crt" ]] || continue
    names=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed -n 's/.*DNS:\([^ ]*\).*/\1/p' || true)
    grep -qxF -- "$BASE_DOMAIN" <<< "$names" && grep -qxF -- "*.${BASE_DOMAIN}" <<< "$names" || continue
    cpub=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null || true)
    [[ -n "$cpub" ]] || continue
    base="${crt%.*}"
    for key in "${base}.key" "${crt%/*}/privkey.pem" "${base/fullchain/privkey}.pem"; do
      [[ -f "$key" && ! -L "$key" && -O "$key" ]] || continue
      kpub=$(openssl pkey -in "$key" -pubout 2>/dev/null || true)
      [[ -n "$kpub" && "$kpub" == "$cpub" ]] && { printf '%s %s\n' "$crt" "$key"; return 0; }
    done
  done
  return 0
}

wiz_tls() {
  use_imported TLS_MODE && return 0
  local found; found=$(find_tls_cert_for_domain)
  if [[ -n "$found" ]]; then
    TLS_FOUND_CRT="${found%% *}"; TLS_FOUND_KEY="${found#* }"
    hint "Found a certificate for ${BASE_DOMAIN} here: $(basename "$TLS_FOUND_CRT"); Enter uses it." \
         "Certificate ${TLS_FOUND_CRT}, key ${TLS_FOUND_KEY}." \
         "Self-signed is generated automatically instead (the browser warns; fine for a lab)."
    ASK_DEFAULT="provide custom certificate files" ask_choice TLS_MODE "TLS certificate:" "auto-generate (self-signed)" "provide custom certificate files"
    return 0
  fi
  hint "HTTPS certificate for the UI: self-signed (browser warns; fine for a lab) or your own files." \
       "Custom = you provide a certificate and key file for the domain (needed for production)."
  ASK_DEFAULT="auto-generate (self-signed)" ask_choice TLS_MODE "TLS certificate:" "auto-generate (self-signed)" "provide custom certificate files"
}
# kubectl without sudo for the login user: not asked (default no, shown in
# the plan); E at the plan changes it.
wiz_kube() {
  use_imported KUBE_USER_ACCESS && return 0
  if [[ "${EDIT_KEY:-}" == KUBE_USER_ACCESS ]]; then
    hint "yes = the SSH user gets the cluster-admin kubeconfig (kubectl without sudo)." \
         "That is full cluster administration for that user. no: use sudo kubectl."
    ASK_DEFAULT=no ask_choice KUBE_USER_ACCESS "Let the SSH user run kubectl without sudo?" "no" "yes"
    return 0
  fi
  [[ -n "${KUBE_USER_ACCESS:-}" ]] || KUBE_USER_ACCESS=$(jq -r '.parameters.KUBE_USER_ACCESS // empty' "$CONFIG_FILE" 2>/dev/null || true)
  [[ -n "${KUBE_USER_ACCESS:-}" ]] || KUBE_USER_ACCESS=no
}

# How long stanctl up waits for Instana: not asked (default 90 min, shown in
# the plan); E at the plan changes it, --config may carry it.
wiz_stanctl_timeout() {
  local from_file=""
  [[ "${PARAMS_SOURCE:-}" != import ]] || from_file="${IMPORTED[STANCTL_UP_TIMEOUT]:-}"
  use_imported STANCTL_UP_TIMEOUT && return 0
  # Asked when E picked it, or when the file's value could not be used.
  if [[ "${EDIT_KEY:-}" == STANCTL_UP_TIMEOUT || -n "$from_file" ]]; then
    hint "How long stanctl up waits for Instana to come up: whole minutes 30-600, or 90m, 2h, 1h30m." \
         "stanctl stops waiting after this time even if Instana is still starting, and then reports a failure." \
         "Larger machines, three-node clusters and newer backends may need longer (a single-node demo took ~63 min on 2026-10-29)." \
         "After a timeout the installer checks the cluster anyway (up to ${INSTANA_READY_WAIT_MIN} more minutes) and continues when Core and Unit are Ready." \
         "Saved with the parameters (also for --resume). INSTANA_STANCTL_TIMEOUT in the environment overrides it."
    prompt_required STANCTL_UP_TIMEOUT "stanctl up timeout" "${STANCTL_UP_TIMEOUT:-$STANCTL_UP_TIMEOUT_DEFAULT}" validate_stanctl_timeout "stanctl up timeout"
    ! stanctl_timeout_minutes "${STANCTL_UP_TIMEOUT:-}" >/dev/null || STANCTL_UP_TIMEOUT=$(stanctl_timeout_normalize "$STANCTL_UP_TIMEOUT")
    return 0
  fi
  [[ -n "${STANCTL_UP_TIMEOUT:-}" ]] || STANCTL_UP_TIMEOUT=$(jq -r '.parameters.STANCTL_UP_TIMEOUT // empty' "$CONFIG_FILE" 2>/dev/null || true)
  [[ -n "${STANCTL_UP_TIMEOUT:-}" ]] || STANCTL_UP_TIMEOUT=$STANCTL_UP_TIMEOUT_DEFAULT
}

wiz_tls_crt() {
  [[ "$TLS_MODE" == "provide custom certificate files" ]] || return 0
  use_imported TLS_CRT_PATH && return 0
  hint "The certificate (PEM) for the base domain, as a file on this machine."
  prompt_required "TLS_CRT_PATH" "Full path to TLS certificate file (.crt)" "${TLS_FOUND_CRT:-}" validate_file_exists "TLS certificate file"
}
wiz_tls_key() {
  [[ "$TLS_MODE" == "provide custom certificate files" ]] || return 0
  use_imported TLS_KEY_PATH && return 0
  hint "The private key (PEM) of that certificate, as a file on this machine."
  prompt_required "TLS_KEY_PATH" "Full path to TLS key file (.key)" "${TLS_FOUND_KEY:-}" validate_file_exists "TLS key file"
}

# collect_parameters — the questions. "<" at the first question asked:
# typed answers from the parameter-source menu (WIZ_BACK_EXIT=1) go back to
# the menu; values from a file or the plan cannot be gone back to, so the
# operator is told where to change them and the question is asked again.
collect_parameters() {
  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}  Instana Standard Edition — $(provider_text_or setup_title "GCP Deployment Setup")${RESET}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${RESET}"
  echo ""
  # Every question first takes a usable value from an input file (use_imported,
  # input-config.sh); without one it is asked exactly as before.
  while true; do
    wiz_run "${WIZ_STEPS[@]}"
    [[ "$WIZ_EXIT" == back ]] || return 0
    # Changing one value from the plan: back = keep it (the caller says so).
    [[ -z "${EDIT_KEY:-}" ]] || return 0
    if [[ "$PARAMS_SOURCE" == import ]]; then
      warn "This is the first question to answer; the values before it come from $(input_source_label). Change those with E at the plan."
      continue
    fi
    # From the parameter-source menu: back to the menu.
    [[ "${WIZ_BACK_EXIT:-0}" != 1 ]] || return 0
    warn "This is the first question; there is nothing before it."
  done
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
  local choice default source=""
  # From an input file: an existing package, or "build" (asks before the long download).
  if [[ "$PARAMS_SOURCE" == import ]]; then
    use_imported AIRGAP_SOURCE && source="$AIRGAP_SOURCE"
    [[ -n "$source" || -z "${IMPORTED[AIRGAP_ARCHIVE]:-}" ]] || source=existing
    if [[ "$source" == existing ]]; then
      if use_imported AIRGAP_ARCHIVE; then
        if [[ "${AIRGAP_INSPECTED:-}" == "$AIRGAP_ARCHIVE" ]] || inspect_airgapped_archive "$AIRGAP_ARCHIVE"; then
          AIRGAP_INSPECTED="$AIRGAP_ARCHIVE"
          return 0
        fi
        warn "The package ${AIRGAP_ARCHIVE} from $(input_source_label) cannot be used (reason above); choose how to provide the package below."
      fi
    elif [[ "$source" == build ]]; then
      explain_airgapped_package
      if build_airgapped_package_locally && inspect_airgapped_archive "$AIRGAP_ARCHIVE"; then
        AIRGAP_INSPECTED="$AIRGAP_ARCHIVE"
        return 0
      fi
      warn "The package was not created; choose how to provide it below."
    fi
  fi
  explain_airgapped_package
  while true; do
    default=$(default_airgapped_archive)
    [[ -z "$default" ]] || log "Found an archive: ${default} ($(( $(stat -c %s "$default" 2>/dev/null || stat -f %z "$default" 2>/dev/null || echo 0) / 1000000000 )) GB, $(date -r "$default" +%Y-%m-%d 2>/dev/null || echo "?")); Enter uses it."
    hint "Use an existing package, create one here, or switch to an online installation."
    choice=$(PROMPT_CHOICE_DEFAULT="$([[ -n "$default" ]] && echo "use an existing instana-airgapped.tar.gz on this machine")" prompt_choice "How do you want to provide the air-gapped package?" \
      "use an existing instana-airgapped.tar.gz on this machine" \
      "create the package now on this machine (needs internet, sudo and about 40 GB free)" \
      "switch to an ONLINE installation instead (the Instana VM downloads everything itself)" \
      "cancel the installation") || die "Input ended; installation cancelled. Nothing was created."
    case "$choice" in
      "use an existing"*)
        prompt_required "AIRGAP_ARCHIVE" "Local path to instana-airgapped.tar.gz" "$default" validate_file_exists "Air-gapped archive"
        # inspect_airgapped_archive sets BACKEND_VERSION / STANCTL_CLI_VERSION in this shell.
        inspect_airgapped_archive "$AIRGAP_ARCHIVE" && { AIRGAP_INSPECTED="$AIRGAP_ARCHIVE"; return 0; }
        warn "That archive cannot be used; choose again."
        ;;
      "create the package"*)
        if build_airgapped_package_locally; then
          inspect_airgapped_archive "$AIRGAP_ARCHIVE" && { AIRGAP_INSPECTED="$AIRGAP_ARCHIVE"; return 0; }
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
  local prompt="${1:-Select the exact stanctl version for the air-gapped package:}"
  local installed selected b
  local -a stanctl_versions
  mapfile -t stanctl_versions < <(apt-cache madison stanctl 2>/dev/null | awk '{print $3}' | sed '/^$/d' | sort -Vu -r | grep -E '^[0-9]+([:.+~_-]?[0-9A-Za-z]+)*$' | awk '!seen[$0]++')
  local bad v; local -a usable=()
  for v in "${stanctl_versions[@]}"; do
    bad=false; for b in "${STANCTL_KEY_IGNORED[@]}"; do [[ "$v" != "$b" ]] || bad=true; done
    [[ "$bad" == true ]] || usable+=("$v")
  done
  (( ${#STANCTL_KEY_IGNORED[@]} == 0 )) ||
    echo -e "  ${DIM}Left out (cannot read the version list with the download key it is given): ${STANCTL_KEY_IGNORED[*]}${RESET}" >&2
  stanctl_versions=("${usable[@]}")
  (( ${#stanctl_versions[@]} > 0 )) || { err "The Instana repository returned no installable stanctl versions."; return 1; }
  installed=$(dpkg-query -W -f='${Version}' stanctl 2>/dev/null || true)
  echo "" >&2
  echo -e "${BOLD}Available stanctl package versions (newest first)${RESET}${installed:+; currently installed: ${installed}}:" >&2
  selected=$(PROMPT_CHOICE_NEWEST=1 pick_from_list STANCTL_VERSION "$prompt" "${stanctl_versions[@]}") ||
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

# The list stanctl reads for "versions identify" (with the download key).
STANCTL_RELEASES_URL="https://artifact-public.instana.io/artifactory/instana-team-release-generic-virtual/versioning/standard-edition-releases.yaml"

# stanctl_error_line OUTPUT — the first error line of a stanctl call (the
# download key is masked if it ever appears), at most 300 characters.
stanctl_error_line() {
  local line
  line=$(printf '%s\n' "$1" | grep -m1 -iE 'error|status [0-9]{3}|unauthori|forbidden|denied' || true)
  [[ -n "$line" ]] || line=$(printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | tail -1)
  [[ -z "${DOWNLOAD_KEY:-}" ]] || line="${line//"$DOWNLOAD_KEY"/***}"
  printf '%s' "${line:0:300}"
}

# stanctl_identify_stop WHERE ERROR [VM] — stops with HOW TO RESOLVE when
# "stanctl versions identify" fails. WHERE is "local" (this machine, nothing
# created yet) or "vm" (phase 10; the VM and disks exist and are kept).
# Known case, verified 2026-10-29: stanctl 1.15.1 ignores the download key it
# is given (--download-key, STANCTL_DOWNLOAD_KEY, --env-file, also registry
# user/password) and gets HTTP 401 for the version list on a machine without
# earlier stanctl data in ~/.stanctl, for any user; it works only where an
# earlier stanctl run left that data (then even with a wrong key). 1.15.0
# uses the key it is given.
stanctl_identify_stop() {
  local where="$1" error="${2:-no error text}" vm="${3:-}" on
  if [[ "$where" == vm ]]; then on="on ${vm}"; else on="on this machine"; fi
  local steps=(
    "*Found: stanctl ${STANCTL_CLI_VERSION:-?} ${on} could not read the backend version list (${STANCTL_RELEASES_URL})."
    "*stanctl said: ${error}"
    "*Why it stops: without that list no compatible backend version can be chosen, so the backend is not installed."
  )
  if [[ "$error" =~ (401|403) ]]; then
    steps+=("*HTTP ${BASH_REMATCH[1]}: the request was refused. Either the download key is wrong, or this stanctl cannot read"
      "*the version list with the download key it is given. Known case: stanctl 1.15.1 gets HTTP 401 on a machine without"
      "*earlier stanctl data in ~/.stanctl (such as a new VM), for any user, even with a valid key; stanctl 1.15.0 works.")
  fi
  if [[ "$where" == vm ]]; then
    steps+=("Check the key with the APT login already on the VM (200 = the key works, 401 = refused). On ${vm}:|sudo curl -s -o /dev/null -w '%{http_code}\\\\n' --netrc-file /etc/apt/auth.conf.d/instana.conf ${STANCTL_RELEASES_URL}"
      "Try stanctl with the key in an empty HOME, as on a new VM (the key is not shown or saved); curl 200 but stanctl 401 = the stanctl problem above:|read -rsp 'Download key: ' K; echo; H=\$(mktemp -d); HOME=\"\$H\" STANCTL_DOWNLOAD_KEY=\"\$K\" stanctl versions identify; rm -rf \"\$H\"; unset K"
      "If both are refused: make sure it is the Instana DOWNLOAD key, not the agent or sales key (resume asks for the keys again)."
      "Continue with another stanctl version (e.g. 1.15.0); resume asks \"choose another stanctl version\" (Enter) or keep ${STANCTL_APT_VERSION:-it}. The VM and disks are kept (and billed meanwhile):|./install.sh --resume"
      "Or remove the lab: ./install.sh, menu \"destroy or clean up\".|./install.sh")
  else
    steps+=("Check the key with the APT login on this machine (200 = the key works, 401 = refused):|sudo curl -s -o /dev/null -w '%{http_code}\\\\n' --netrc-file /etc/apt/auth.conf.d/instana.conf ${STANCTL_RELEASES_URL}"
      "Check stanctl with the same key in an empty HOME, as on a new VM (the key is not shown or saved):|read -rsp 'Download key: ' K; echo; H=\$(mktemp -d); HOME=\"\$H\" STANCTL_DOWNLOAD_KEY=\"\$K\" stanctl versions identify; rm -rf \"\$H\"; unset K"
      "Make sure it is the Instana DOWNLOAD key, not the agent key or the sales key (order of the questions: download, agent, sales)."
      "Nothing was created yet. Run the installer again and type the download key:|./install.sh")
  fi
  die_with_steps "stanctl ${STANCTL_CLI_VERSION:-?} ${on} could not list the backend versions: ${error}" "${steps[@]}"
}

# download_key_http_code — HTTP status of the version list with the download
# key (netrc file, owner-only, removed at once; the key is never printed).
download_key_http_code() {
  local netrc code
  command -v curl >/dev/null 2>&1 || { echo none; return 0; }
  netrc=$(mktemp); chmod 600 "$netrc"
  printf 'machine artifact-public.instana.io\n  login _\n  password %s\n' "$DOWNLOAD_KEY" > "$netrc"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 --netrc-file "$netrc" "$STANCTL_RELEASES_URL" 2>/dev/null || true)
  rm -f "$netrc"
  printf '%s' "${code:-000}"
}

# The installed CLI reports the backend versions it supports; the operator
# picks one and it is pinned into the package (--instana-version).
select_local_backend_version() {
  local prompt="${1:-Select the exact Instana backend version to package:}"
  local tmp_key raw_backends selected rc=0 err_line
  local -a backend_versions
  tmp_key=$(mktemp); chmod 600 "$tmp_key"
  printf 'STANCTL_DOWNLOAD_KEY=%s\n' "$DOWNLOAD_KEY" > "$tmp_key"
  if [[ "${LOCAL_IDENTIFY_FRESH:-0}" == 1 ]]; then
    # As on a new Instana VM: no stanctl data in HOME, so a stanctl that does
    # not use the key it is given fails here, before anything is created.
    local fresh_home key_code
    fresh_home=$(mktemp -d)
    raw_backends=$(HOME="$fresh_home" stanctl versions identify --env-file "$tmp_key" --quiet 2>&1) || rc=$?
    rm -rf "$fresh_home"
    if (( rc != 0 )) && [[ "$raw_backends" =~ (401|403) ]]; then
      key_code=$(download_key_http_code)
      if [[ "$key_code" == 200 ]]; then
        rm -f "$tmp_key"
        err_line=$(stanctl_error_line "$raw_backends")
        warn "stanctl ${STANCTL_CLI_VERSION} cannot read the version list with the download key it is given (known for 1.15.1: HTTP 401 on a machine without earlier stanctl data in ~/.stanctl); choose another version."
        warn "stanctl said: ${err_line}. The key itself works (HTTP 200 for the same list); the new Instana VM has no such data either, so this version would stop in phase 10."
        return 2
      fi
    fi
  else
    raw_backends=$(stanctl versions identify --env-file "$tmp_key" --quiet 2>&1) || rc=$?
  fi
  rm -f "$tmp_key"
  (( rc == 0 )) || stanctl_identify_stop local "$(stanctl_error_line "$raw_backends")"
  mapfile -t backend_versions < <(printf '%s\n' "$raw_backends" | sed -nE 's/^[[:space:]]*-[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+[-.+~][0-9A-Za-z.-]+)[[:space:]]*$/\1/p' | sort -rV | awk '!seen[$0]++')
  (( ${#backend_versions[@]} > 0 )) ||
    { err "stanctl ${STANCTL_CLI_VERSION} returned no supported backend versions (check the download key)."; return 1; }
  echo "" >&2
  echo -e "${BOLD}Backend versions supported by stanctl ${STANCTL_CLI_VERSION}:${RESET}" >&2
  selected=$(PROMPT_CHOICE_NEWEST=1 pick_from_list BACKEND_VERSION "$prompt" "${backend_versions[@]}") ||
    { err "Backend version selection was cancelled."; return 1; }
  BACKEND_VERSION="$selected"
  ok "Selected: stanctl ${STANCTL_CLI_VERSION} → backend ${BACKEND_VERSION}"
}

# Online mode: the backend version is the first thing an urgent ticket needs
# ("reproduce the customer's problem on exactly their version"), so it is
# chosen here, before anything is created on GCP, not 20 minutes later in
# phase 10. The exact stanctl package is installed on THIS machine from the
# authenticated repository and asked which backend versions it supports; the
# pair is then pinned for the whole run (REQUESTED_* globals, honoured by
# install_stanctl on the VM). When this machine cannot do that (not
# Ubuntu/Debian, no sudo, repository unreachable) the selection falls back
# to phase 10 on the VM; a version list refused because the key is wrong
# stops with HOW TO RESOLVE before anything is created.
REQUESTED_STANCTL_APT_VERSION=""
REQUESTED_BACKEND_VERSION=""
STANCTL_KEY_IGNORED=()   # stanctl packages that cannot read the version list with the given key (this run)
# select_local_versions — exact stanctl and backend chosen on this machine.
# The backend list is read in an empty HOME, as on the new VM in phase 10; a
# stanctl that fails there while the key works is left out and the stanctl
# list is offered again.
# Returns 1 (after a warning) when the choice must move to phase 10.
select_local_versions() {
  local rc
  while true; do
    if ! select_and_install_local_stanctl "Select the exact stanctl version (newest first; the backend list depends on it):"; then
      warn "stanctl could not be installed here; the version will be chosen on the Instana VM in phase 10 instead."
      return 1
    fi
    rc=0; LOCAL_IDENTIFY_FRESH=1 select_local_backend_version "Select the exact Instana backend version to install (the customer's version):" || rc=$?
    if (( rc == 2 )); then STANCTL_KEY_IGNORED+=("$STANCTL_APT_VERSION"); continue; fi
    if (( rc != 0 )); then
      warn "Backend versions could not be listed here; the version will be chosen on the Instana VM in phase 10 instead."
      return 1
    fi
    return 0
  done
}

select_versions_upfront() {
  [[ "$INSTALL_MODE" == online ]] || return 0
  [[ "${RESUME:-false}" == true ]] && return 0
  local os_id
  echo "" >&2
  log "Backend version selection"
  imported_usable STANCTL_VERSION BACKEND_VERSION ||
  hint "Pick the exact Instana backend version, e.g. the one your customer runs." \
       "The matching stanctl is installed on this machine first (needs sudo, Ubuntu/Debian and access to" \
       "artifact-public.instana.io with your download key) so the list below is the one IBM publishes for it." \
       "The versions are pinned for this run and shown in the plan and the final report."
  if [[ "$DRY_RUN" == true ]]; then
    REQUESTED_STANCTL_APT_VERSION="DRY-RUN-SELECTION"; REQUESTED_BACKEND_VERSION="DRY-RUN-COMPATIBLE-SELECTION"
    # Dry-run cannot reach the repository: versions from an input file are only
    # format-checked here and shown in the plan.
    if use_imported STANCTL_VERSION; then REQUESTED_STANCTL_APT_VERSION="$STANCTL_VERSION"; fi
    if use_imported BACKEND_VERSION; then REQUESTED_BACKEND_VERSION="$BACKEND_VERSION"; fi
    return 0
  fi
  os_id=$(. /etc/os-release 2>/dev/null && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")
  if [[ "$os_id" != *ubuntu* && "$os_id" != *debian* ]] || ! command -v sudo >/dev/null 2>&1; then
    if use_imported STANCTL_VERSION && use_imported BACKEND_VERSION; then
      REQUESTED_STANCTL_APT_VERSION="$STANCTL_VERSION"; REQUESTED_BACKEND_VERSION="$BACKEND_VERSION"
      warn "This machine is not Ubuntu/Debian with sudo; the versions from $(input_source_label) are checked on the Instana VM in phase 10."
      return 0
    fi
    warn "This machine is not Ubuntu/Debian with sudo; the version will be chosen on the Instana VM in phase 10 instead."
    return 0
  fi
  if ! configure_local_instana_repository; then
    warn "The Instana repository could not be configured here; the version will be chosen on the Instana VM in phase 10 instead."
    return 0
  fi
  select_local_versions || return 0
  REQUESTED_STANCTL_APT_VERSION="$STANCTL_APT_VERSION"
  REQUESTED_BACKEND_VERSION="$BACKEND_VERSION"
  ok "Pinned for this run: stanctl ${STANCTL_APT_VERSION} → backend ${BACKEND_VERSION}"
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
  local from_file=true
  while true; do
    if [[ "$from_file" == true ]] && use_imported AIRGAP_OUTPUT_DIR; then :
    else prompt_required "AIRGAP_OUTPUT_DIR" "Directory for the package (will be created)" "${HOME}/instana-airgap"; fi
    from_file=false
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
  # The newest instana-airgapped*.tar.gz in the usual places (current folder,
  # installer folder, home, ~/instana-airgap, /var/tmp).
  # Only regular files owned by this user are offered: the package's stanctl
  # runs as root on the Instana VM, so a file someone else could plant (e.g.
  # in /var/tmp) or a symbolic link is never a default.
  local f
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" && ! -L "$f" && -O "$f" ]] && { printf '%s\n' "$f"; return 0; }
  done < <(ls -t "$PWD"/instana-airgapped*.tar.gz "$SCRIPT_DIR"/instana-airgapped*.tar.gz \
        "$HOME"/instana-airgapped*.tar.gz "$HOME"/instana-airgap/instana-airgapped*.tar.gz \
        /var/tmp/instana-airgapped*.tar.gz 2>/dev/null || true)
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
    local min_cpu min_ram
    case "$INSTALL_TYPE" in
      demo)       min_cpu=16;  min_ram=64 ;;
      production) min_cpu=28;  min_ram=112 ;;
    esac
    if ! provider_uses_param SIZE; then
      SIZE_CHOICE=minimum
    elif use_imported SIZE; then
      SIZE_CHOICE="$SIZE"
    elif [[ "${EDIT_KEY:-}" != SIZE && "${EDIT_KEY:-}" != VM_CPUS && "${EDIT_KEY:-}" != VM_RAM_GB ]]; then
      # Not asked: the documented minimum for the type (or the saved size);
      # shown in the plan, E at the plan changes it.
      SIZE_CHOICE="${SIZE:-minimum}"
      if [[ "${CONFIG_LOADED:-false}" == true && -z "${SIZE:-}" ]]; then
        local sc sr; sc=$(gcp_saved VM_CPUS 2>/dev/null || true); sr=$(gcp_saved VM_RAM_GB 2>/dev/null || true)
        if [[ -n "$sc" && -n "$sr" && ( "$sc" != "$min_cpu" || "$sr" != "$min_ram" ) ]]; then SIZE_CHOICE=custom; VM_CPUS="$sc"; VM_RAM_GB="$sr"; fi
      fi
      [[ "$SIZE_CHOICE" != custom || -z "${VM_CPUS:-}" ]] || { SIZE=custom; MACHINE_TYPE=$(provider_machine_type_for "$VM_CPUS" "$VM_RAM_GB"); return 0; }
    else
      show_single_node_requirements "$INSTALL_TYPE"
      echo -e "  Official minimum: ${BOLD}${min_cpu} vCPUs, ${min_ram} GB RAM${RESET}"
      echo ""
      ask_choice SIZE_CHOICE "Machine size:" \
        "minimum (${min_cpu} vCPUs / ${min_ram} GB) — from documentation" \
        "production recommended (production-small: 28 vCPUs / 112 GB)" \
        "custom — enter manually"
      (( ${NAV_BACK:-0} == 0 )) || return 0
    fi

    case "$SIZE_CHOICE" in
      "minimum"*)
        SIZE=minimum; VM_CPUS=$min_cpu; VM_RAM_GB=$min_ram ;;
      "production"*)
        SIZE=production; VM_CPUS=28; VM_RAM_GB=112 ;;
      "custom"*)
        SIZE=custom
        if ! { use_imported VM_CPUS && use_imported VM_RAM_GB; }; then
          local NAV_ON=0
          collect_cpu_ram VM_CPUS VM_RAM_GB "$min_cpu" "$min_ram" "single-node $INSTALL_TYPE"
        fi
        ;;
    esac
    # Map to the provider's machine type
    MACHINE_TYPE=$(provider_machine_type_for "$VM_CPUS" "$VM_RAM_GB")

  else
    # Three-node lab: one fixed size, nothing to choose (the lab creates
    # 3x n2-standard-16 and supports only the documented small profile).
    show_three_node_requirements
    log "$(provider_text_or three_node_size_note "Three-node lab size is fixed: small profile (12 vCPUs / 48 GB per node, documented minimum) on 3x n2-standard-16.")"
    if [[ "$PARAMS_SOURCE" == import && -n "${IMPORTED[SIZE]:-}" && "${IMPORTED[SIZE]}" != small ]]; then
      warn "SIZE '${IMPORTED[SIZE]}' from $(input_source_label) is ignored: three-node uses the fixed small size."
    fi
    SIZE=small
    NODE_CPUS=12; NODE_RAM_GB=48
    MACHINE_TYPE=$(provider_machine_type_for "$NODE_CPUS" "$NODE_RAM_GB")
  fi
}

# =============================================================================
# SECTION 5 — INSTALLATION PLAN / CONFIRMATION
# =============================================================================
# plan_fact NAME VALUE [MORE] — one key line at the top of the plan.
plan_fact() {
  printf '  %-9s %b\n' "$1" "${BOLD}${2}${RESET}${3:+  ${DIM}${3}${RESET}}"
}
# plan_warn TEXT — the key line about what is created or changed.
plan_warn() { printf '  %b\n' "${YELLOW}${1}${RESET}"; }

# The backend version as the top of the plan shows it.
plan_version_text() {
  if [[ -n "${BACKEND_VERSION:-}" ]]; then echo "backend ${BACKEND_VERSION} (stanctl ${STANCTL_APT_VERSION:-?})"
  elif [[ "$INSTALL_MODE" == online && "$DRY_RUN" == true ]]; then echo "version chosen before Start in a real run"
  elif [[ "$INSTALL_MODE" == online ]]; then echo "version chosen on the Instana host in phase 10"
  else echo "the version in the air-gapped package"; fi
}

show_plan() {
  local where_label tls_short
  where_label=$([[ "$(provider_name)" == ssh ]] && echo "existing hosts (SSH)" || echo "Google Cloud")
  tls_short=$([[ "$TLS_MODE" == "provide custom certificate files" ]] && echo "your certificate" || echo "self-signed TLS")
  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}  Installation Plan: ${TOPOLOGY} ${INSTALL_TYPE}, ${INSTALL_MODE} — ${where_label}${RESET}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${RESET}"
  # Key facts first (where, which machines, version, UI, what is created or
  # changed), the details below.
  provider_plan_key_lines head
  plan_fact "Instana" "$(plan_version_text)"
  plan_fact "UI" "https://${UNIT_NAME}-${TENANT_NAME}.${BASE_DOMAIN}" "${tls_short}, after DNS or /etc/hosts"
  provider_plan_key_lines change
  [[ "$DRY_RUN" != true ]] || echo -e "  ${YELLOW}DRY-RUN MODE: No resources will be created.${RESET}"
  echo ""
  echo -e "  ${DIM}── Details ─────────────────────────────────────────────────────${RESET}"
  # Grouped: where it goes, what is installed, how it is reached, what is
  # created or changed.
  echo -e "  ${BOLD}Where${RESET}"
  provider_plan_target_lines
  ! provider_uses_param SSH_SOURCE_CIDR || printf "  %-30s %s\n" "SSH source CIDR:"   "$SSH_SOURCE_CIDR"
  echo ""
  echo -e "  ${BOLD}What${RESET}"
  printf "  %-30s %s\n" "Topology:"         "$TOPOLOGY"
  printf "  %-30s %s\n" "Installation type:" "$INSTALL_TYPE"
  printf "  %-30s %s\n" "Connectivity mode:" "$INSTALL_MODE"
  ! provider_uses_param UBUNTU_VERSION || printf "  %-30s %s\n" "Ubuntu version:"    "$UBUNTU_VERSION"
  if [[ -n "${BACKEND_VERSION:-}" ]]; then
    printf "  %-30s %s\n" "stanctl package:"   "${STANCTL_APT_VERSION:-?}"
    printf "  %-30s %s\n" "Backend version:"   "$BACKEND_VERSION"
  elif [[ "$INSTALL_MODE" == online && "$DRY_RUN" == true ]]; then
    printf "  %-30s %s\n" "Backend version:"   "chosen before Start in a real run (a dry-run does not contact the repository)"
  elif [[ "$INSTALL_MODE" == online ]]; then
    printf "  %-30s %s\n" "Backend version:"   "chosen on the Instana host in phase 10 (this control machine could not list the versions)"
  fi
  printf "  %-30s %s\n" "kubectl without sudo:" "${KUBE_USER_ACCESS:-no} (for the SSH user on the Instana host; E changes it)"
  printf "  %-30s %s\n" "stanctl up timeout:" "$(stanctl_timeout_plan_text)"
  echo ""
  echo -e "  ${BOLD}Access${RESET}"
  printf "  %-30s %s\n" "Base domain:"       "$BASE_DOMAIN"
  printf "  %-30s %s\n" "Tenant/Unit:"       "${TENANT_NAME}/${UNIT_NAME}"
  printf "  %-30s %s\n" "UI URL (after DNS):" "https://${UNIT_NAME}-${TENANT_NAME}.${BASE_DOMAIN}"
  printf "  %-30s %s\n" "TLS:"               "$TLS_MODE"
  echo ""
  echo -e "  ${BOLD}Resources${RESET}"
  provider_plan_resource_lines

  echo ""
  local own; own=$(provider_text start_line)
  [[ "$DRY_RUN" == true || -z "$own" ]] || echo -e "  ${YELLOW}${own}${RESET}"
  if [[ "${PLAN_EDITABLE:-false}" == true ]]; then
    echo -e "  ${DIM}y = $([[ "$DRY_RUN" == true ]] && echo "run the simulation" || echo start) · e = change a value$(provider_uses_param SIZE && echo ' (also Ubuntu and machine size)' || true) · s = save to a file (no keys) · N or Enter = cancel${RESET}"
    HINT_MORE=("y: $([[ "$DRY_RUN" == true ]] && echo "run the dry-run simulation (nothing is created)" || echo "start: create the resources listed above and install Instana")." \
      "e: change one of the values above first$(provider_uses_param SIZE && echo ' (also the Ubuntu version and the machine size)' || true)." \
      "s: save these parameters to a JSON file (without keys) for a later run, and stop." \
      "N, or Enter without typing anything: cancel without starting.")
  fi
  PLAN_DECISION=start
  if [[ "${PLAN_EDITABLE:-false}" == true ]]; then
    case "$(prompt_plan_decision)" in
      yes) ;;
      edit) PLAN_DECISION=edit; return 0 ;;
      save) save_plan_to_file; log "Installation was not started; the parameters were saved for later."; mark_stopped "not started — the parameters were saved to a file"; exit 0 ;;
      *) log "Installation was not started; no action was approved from this plan."; mark_stopped "not started (N at the plan) — nothing was created"; exit 0 ;;
    esac
  else
    prompt_yes_no "Start now? Type Y to continue or N to cancel" N || { log "Installation was not started; no action was approved from this plan."; mark_stopped "not started (N at the plan) — nothing was created"; exit 0; }
  fi
  # Y typed in a terminal at this plan approves the changes it lists on
  # existing hosts and the network connections it lists (one confirmation).
  if [[ "$(provider_name)" == ssh && -t 0 ]]; then
    HOST_CHANGES_APPROVED=plan
    save_state network_rules_confirmed yes
  fi
  provider_confirm_host_changes
  save_state "provider" "$(provider_name)"
  provider_record_target
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

# =============================================================================
# SECTION 7 — REMOTE SETUP (kernel, disks, install)
# =============================================================================
SSH_RETRY_MAX="${SSH_RETRY_MAX:-3}"
SSH_RETRY_WAIT="${SSH_RETRY_WAIT:-20}"

# ssh_with_retry VM LOCATION SCOPE COMMAND — runs COMMAND on the VM through the
# provider's SSH transport and, when the connection itself fails (exit 255:
# closed, refused, timed out), waits and tries again. A non-zero exit from the
# remote command is never retried.
ssh_with_retry() {
  local attempt=1 rc=0 label="${HEARTBEAT_LABEL:-remote step on $1}"
  while :; do
    rc=0
    spin_run "$label" provider_ssh "$@" || rc=$?
    if (( rc != 255 )) || (( attempt >= SSH_RETRY_MAX )); then
      return "$rc"
    fi
    warn "SSH connection to the node was lost (attempt ${attempt}/${SSH_RETRY_MAX}). Retrying in ${SSH_RETRY_WAIT}s ..." >&2
    sleep "$SSH_RETRY_WAIT"
    (( attempt++ ))
  done
}

LAST_FAILED_STEP=""
remote_exec() {
  local vm_name="$1" zone="$2" project="$3"; shift 3
  local cmd="$*" quoted rc=0
  printf -v quoted '%q' "$cmd"
  ssh_with_retry "$vm_name" "$zone" "$project" "sudo bash -lc ${quoted}" || rc=$?
  (( rc == 0 )) || LAST_FAILED_STEP="remote command on ${vm_name} (exit ${rc}): ${cmd:0:300}"
  return "$rc"
}

remote_exec_dry() {
  local vm_name="$1" zone="$2" project="$3"; shift 3
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY-RUN]${RESET} On ${vm_name}: $*"
  else
    remote_exec "$vm_name" "$zone" "$project" "$@"
  fi
}

# spin_run LABEL COMMAND... — runs COMMAND while an animated spinner with the
# step label and the elapsed time turns on the last terminal line, updated
# every second, so any step that produces no output for a while (waiting for
# SSH, stanctl up, kubectl wait, disk creation, package copy) is visibly
# alive. The command's own output still streams through unchanged: each
# output line pushes the spinner line down. Nested calls (a spinner already
# turning for an outer step) just run the command. Every remote command
# (remote_exec / remote_user_exec), every 'run', every wait loop and every
# package copy goes through here, so no step of the installer is ever silent.
# Without a terminal (log capture, tests) the command simply runs.
HEARTBEAT_ACTIVE=false
spin_run() {
  local label="$1"; shift
  if [[ "$HEARTBEAT_ACTIVE" == true || "${DRY_RUN:-false}" == true || ! -t 2 ]]; then
    "$@"
    return
  fi
  local start=$SECONDS pid hb rc=0
  if [[ -t 1 ]]; then
    # Output is the terminal: relay it line by line so each line first wipes
    # the spinner line and the spinner then redraws below it.
    (
      HEARTBEAT_ACTIVE=true
      "$@" 2>&1 | while IFS= read -r line || [[ -n "$line" ]]; do printf '\r\033[K%s\n' "$line"; done
      exit "${PIPESTATUS[0]}"
    ) &
  else
    # Output is being captured ($(...)); leave stdout untouched.
    ( HEARTBEAT_ACTIVE=true; "$@" ) &
  fi
  pid=$!
  (
    local -a glyphs=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0 e
    while kill -0 "$pid" 2>/dev/null; do
      e=$(( SECONDS - start ))
      printf '\r\033[K  %s %s — %dm%02ds (still running; do not interrupt)' \
        "${glyphs[i % ${#glyphs[@]}]}" "$label" $((e/60)) $((e%60)) >&2
      i=$(( i + 1 ))
      sleep 1
    done
  ) >/dev/null &
  hb=$!
  trap 'kill "$pid" "$hb" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; printf "\r\033[K" >&2; exit 130' INT TERM
  wait "$pid" || rc=$?
  trap - INT TERM
  kill "$hb" 2>/dev/null || true
  wait "$hb" 2>/dev/null || true
  printf '\r\033[K' >&2
  return "$rc"
}

# with_heartbeat LABEL COMMAND... — kept for readability at the long steps;
# same as spin_run.
with_heartbeat() { spin_run "$@"; }

remote_user_exec() {
  local vm_name="$1" zone="$2" project="$3"; shift 3
  local cmd="$*" rc=0
  ssh_with_retry "$vm_name" "$zone" "$project" "$cmd" || rc=$?
  (( rc == 0 )) || LAST_FAILED_STEP="remote command on ${vm_name} (exit ${rc}): ${cmd:0:300}"
  return "$rc"
}

upload_private_file() {
  local local_file="$1" vm_name="$2" zone="$3" project="$4" remote_name="$5"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY-RUN]${RESET} Securely upload ${remote_name} to ${vm_name} (content redacted)"
    return
  fi
  spin_run "copying ${remote_name} to ${vm_name}" provider_scp "$local_file" "$vm_name" "$zone" "$project" "/tmp/${remote_name}"
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

# IBM (backend release notes): the minimum supported CPU architecture is
# x86-64-v3 (was x86-64-v2). x86-64-v3 = AVX, AVX2, BMI1, BMI2, F16C, FMA,
# LZCNT (abm), MOVBE, OSXSAVE on top of v2. n2-standard VMs (Cascade Lake or
# newer) provide it; n1 or e2 on older platforms may not. Checked on every
# node before anything is installed, so a wrong machine type fails in
# seconds with a fix instead of deep inside stanctl up.
X86_64_V3_FLAGS="avx avx2 bmi1 bmi2 f16c fma abm movbe xsave ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm"
verify_cpu_x86_64_v3() {
  local vm_name="$1" zone="$2" project="$3" out
  [[ "$DRY_RUN" != true ]] || { phase_detail active "Would verify x86-64-v3 CPU flags on ${vm_name}."; return 0; }
  out=$(remote_exec "$vm_name" "$zone" "$project" "test \"\$(uname -m)\" = x86_64 || { echo 'ARCH:'\$(uname -m); exit 0; }; missing=''; for f in ${X86_64_V3_FLAGS}; do grep -qw \"\$f\" /proc/cpuinfo || missing=\"\$missing \$f\"; done; echo \"MISSING:\$missing\"; grep -m1 'model name' /proc/cpuinfo") || die "Could not read the CPU flags on ${vm_name}."
  if [[ "$out" == ARCH:* ]]; then
    die_with_steps "${vm_name} is not x86_64 (${out#ARCH:}); Instana Standard Edition requires x86-64-v3." \
      "$(provider_hint x86_machine "$vm_name" "$zone" "$project")"
  fi
  local missing; missing=$(sed -n 's/^MISSING://p' <<< "$out" | xargs)
  if [[ -n "$missing" ]]; then
    die_with_steps "CPU of ${vm_name} lacks x86-64-v3 instructions (missing:${missing}). IBM requires x86-64-v3 for this backend version." \
      "*$(grep 'model name' <<< "$out" | sed 's/.*: //')" \
      "$(provider_hint cpu_platform "$vm_name" "$zone" "$project")" \
      "Then rerun:|./install.sh --resume"
  fi
  phase_detail done "CPU of ${vm_name} provides x86-64-v3 ($(grep 'model name' <<< "$out" | sed 's/.*: //'))."
}

wait_for_ssh() {
  local vm_name="$1" zone="$2" project="$3"
  log "Waiting for SSH on ${vm_name}..."
  if spin_run "waiting for SSH on ${vm_name}" wait_for_ssh_loop "$vm_name" "$zone" "$project"; then
    ok "SSH ready on ${vm_name}."
    return
  fi
  die "SSH did not become available on ${vm_name} after 30 bounded attempts."
}
wait_for_ssh_loop() {
  local vm_name="$1" zone="$2" project="$3"
  local attempt=0
  while (( attempt < 30 )); do
    if provider_ssh_probe "$vm_name" "$zone" "$project" 30 10 "echo ready" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 10
  done
  return 1
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
dev=$(provider_disk_device_path "$vm_name" "$device")
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
      provider_check_blank_disk "$vm_name" "$device"
      remote_exec "$vm_name" "$zone" "$project" \
        "set -euo pipefail; dev=$(provider_disk_device_path "$vm_name" "$device"); mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard \"\$dev\"; uuid=\$(blkid -s UUID -o value \"\$dev\"); grep -qF \"UUID=\$uuid  ${mount_point} \" /etc/fstab || printf 'UUID=%s  %s  ext4  discard,defaults,nofail  0 2\\n' \"\$uuid\" '${mount_point}' >> /etc/fstab; mount '${mount_point}'; findmnt -rn -M '${mount_point}'"
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

# The package is copied to /var/tmp (kept across a reboot, unlike /tmp) under a
# .part name and renamed only when the transfer finished, so the final name
# always holds a complete copy. A resumed run reuses a copy (or a full-size
# .part) after a SHA-256 comparison instead of transferring tens of GB again.
# A finished import is recorded on the VM itself (AIRGAP_IMPORT_MARKER: backend
# version, stanctl version, package size) before the copy is deleted, so a
# connection lost after the import never leaves the run without a way back.
AIRGAP_REMOTE_ARCHIVE=/var/tmp/instana-airgapped.tar.gz
AIRGAP_IMPORT_MARKER=/var/lib/instana-airgap/imported
AIRGAP_SPACE_MARGIN_BYTES=$(( 5 * 1024 * 1024 * 1024 ))

# remote_value VM ZONE PROJECT KEY COMMAND — runs COMMAND remotely (spinner
# included) and prints the value of its last "KEY=value" output line, so ssh
# banners or retry notices never end up in the value. COMMAND always prints
# the KEY= line (empty value = "not there"); a failed SSH call or a missing
# KEY= line returns 1, so "could not ask the VM" is never mistaken for "absent".
remote_value() {
  local vm_name="$1" zone="$2" project="$3" key="$4" out line; shift 4
  out=$(remote_exec "$vm_name" "$zone" "$project" "$*") || return 1
  line=$(grep "^${key}=" <<< "$out" | tail -1) || return 1
  printf '%s' "${line#"${key}="}"
}

# The VM could not be asked about the package or import: stop instead of
# guessing (a wrong guess costs a transfer of tens of GB and a re-import).
airgap_probe_failed() {
  local vm_name="$1" zone="$2" project="$3" what="$4"
  die_with_steps "Could not check ${what} on ${vm_name} (SSH or remote command failed); nothing was copied or imported." \
    "Check that the VM is running and reachable:|$(provider_hint ssh "$vm_name" "$zone" "$project" "ls -l ${AIRGAP_REMOTE_ARCHIVE}* ${AIRGAP_IMPORT_MARKER}")" \
    "Continue where it stopped:|./install.sh --resume"
}

# Exact version token from 'stanctl --version' output ("stanctl version 1.11.0");
# empty when there is none.
stanctl_version_token() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+~-]*' <<< "$1" | head -1 || true; }

# airgap_reuse_remote_copy VM ZONE PROJECT — 0 when the VM holds a complete,
# checksum-identical copy at AIRGAP_REMOTE_ARCHIVE (a full-size .part is
# verified and renamed); anything else that does not match is removed.
airgap_reuse_remote_copy() {
  local vm_name="$1" zone="$2" project="$3" local_size local_sum="" path size remote_sum
  local_size=$(wc -c < "$AIRGAP_ARCHIVE" | tr -d ' ')
  for path in "$AIRGAP_REMOTE_ARCHIVE" "${AIRGAP_REMOTE_ARCHIVE}.part"; do
    size=$(remote_value "$vm_name" "$zone" "$project" SIZE "echo SIZE=\$(test -f ${path} && wc -c < ${path})") ||
      airgap_probe_failed "$vm_name" "$zone" "$project" "the package copy ${path}"
    [[ -n "$size" ]] || continue
    if [[ "$size" != "$local_size" ]]; then
      log "${vm_name} holds an incomplete or different ${path##*/} (${size} of ${local_size} bytes); it will be replaced."
      continue
    fi
    log "${vm_name} already holds ${path##*/} with the package's exact size from an earlier run; comparing SHA-256 checksums before reusing it..."
    remote_sum=$(HEARTBEAT_LABEL="SHA-256 of ${path##*/} on ${vm_name}" remote_value "$vm_name" "$zone" "$project" SUM "echo SUM=\$(sha256sum ${path} | cut -d' ' -f1)") ||
      airgap_probe_failed "$vm_name" "$zone" "$project" "the checksum of ${path}"
    # Computed at most once per run, and only when a full-size copy exists.
    [[ -n "$local_sum" ]] || local_sum=$(spin_run "SHA-256 of the local package" sha256sum "$AIRGAP_ARCHIVE" | cut -d' ' -f1)
    if [[ -n "$remote_sum" && "$remote_sum" == "$local_sum" ]]; then
      [[ "$path" == "$AIRGAP_REMOTE_ARCHIVE" ]] || remote_exec "$vm_name" "$zone" "$project" "mv -f ${path} ${AIRGAP_REMOTE_ARCHIVE}"
      return 0
    fi
    log "${path##*/} on ${vm_name} differs from ${AIRGAP_ARCHIVE} (checksum mismatch); it will be replaced."
  done
  return 1
}

# airgap_check_space VM ZONE PROJECT NEEDED_BYTES — stops before a copy or
# import that cannot fit; an unreadable df only warns.
airgap_check_space() {
  local vm_name="$1" zone="$2" project="$3" needed="$4" free_bytes
  free_bytes=$(remote_value "$vm_name" "$zone" "$project" FREE "echo FREE=\$(df -B1 --output=avail /var/tmp 2>/dev/null | tail -1 | tr -d ' ')") || free_bytes=""
  if [[ ! "$free_bytes" =~ ^[0-9]+$ ]]; then
    warn "Free space in /var/tmp on ${vm_name} could not be read; continuing without the space check."
    return 0
  fi
  (( free_bytes >= needed )) && return 0
  die_with_steps "${vm_name} has $(( free_bytes / 1024 / 1024 / 1024 )) GB free in /var/tmp; copying and importing the package needs about $(( needed / 1024 / 1024 / 1024 )) GB." \
    "Inspect the boot disk on the VM:|$(provider_hint ssh "$vm_name" "$zone" "$project" "df -h / /var/tmp")" \
    "Free space (or grow the boot disk), then continue:|./install.sh --resume"
}

install_stanctl_airgapped() {
  local vm_name="$1" zone="$2" project="$3" marker expected cli_output installed local_size q_backend q_cli rc=0
  if [[ "$DRY_RUN" == true ]]; then
    warn "Dry-run: would copy $(basename "$AIRGAP_ARCHIVE") to ${vm_name}, extract stanctl ${STANCTL_CLI_VERSION} from it and import backend ${BACKEND_VERSION}."
    return
  fi
  verify_airgap_archive_matches_state
  local_size=$(wc -c < "$AIRGAP_ARCHIVE" | tr -d ' ')
  expected="backend=${BACKEND_VERSION} stanctl=${STANCTL_CLI_VERSION} size="

  # Import already finished (this or an earlier run): the VM marker and the
  # installed stanctl must both match the archive exactly.
  marker=$(remote_value "$vm_name" "$zone" "$project" MARKER "echo MARKER=\$(cat ${AIRGAP_IMPORT_MARKER} 2>/dev/null)") ||
    airgap_probe_failed "$vm_name" "$zone" "$project" "the import marker ${AIRGAP_IMPORT_MARKER}"
  if [[ -n "$marker" ]]; then
    cli_output=$(remote_value "$vm_name" "$zone" "$project" CLI "echo CLI=\$(stanctl --version 2>/dev/null | head -1)") ||
      airgap_probe_failed "$vm_name" "$zone" "$project" "the installed stanctl version"
    installed=$(stanctl_version_token "$cli_output")
    if [[ "$marker" == "$expected"* && "$installed" == "$STANCTL_CLI_VERSION" ]]; then
      save_state stanctl_cli_version "$STANCTL_CLI_VERSION"
      save_state backend_version "$BACKEND_VERSION"
      save_state "step_airgap_imported_${vm_name}" completed
      remote_exec "$vm_name" "$zone" "$project" "rm -f ${AIRGAP_REMOTE_ARCHIVE} ${AIRGAP_REMOTE_ARCHIVE}.part" ||
        warn "Could not remove the leftover package copy on ${vm_name}; remove ${AIRGAP_REMOTE_ARCHIVE} by hand to free space."
      phase_detail done "Air-gapped package was already imported (stanctl ${STANCTL_CLI_VERSION} → backend ${BACKEND_VERSION}); no copy or import repeated"
      ok "Air-gapped import on ${vm_name} verified (marker and stanctl ${installed}); not repeated."
      return 0
    fi
    if [[ "$marker" != "$expected"* ]]; then
      die_with_steps "${vm_name} already imported a different air-gapped package (${marker}); this run uses stanctl ${STANCTL_CLI_VERSION} / backend ${BACKEND_VERSION}." \
        "Put the original package back at ${AIRGAP_ARCHIVE}, then continue:|./install.sh --resume" \
        "*Or remove this deployment and start a new one with the new package: ./install.sh --destroy"
    fi
    warn "${vm_name} records this import, but stanctl there reports '${installed:-nothing}' instead of ${STANCTL_CLI_VERSION}; importing again."
  fi

  if airgap_reuse_remote_copy "$vm_name" "$zone" "$project"; then
    ok "Reusing the verified package copy on ${vm_name}; no new transfer."
    airgap_check_space "$vm_name" "$zone" "$project" $(( local_size + AIRGAP_SPACE_MARGIN_BYTES ))
  else
    # Old releases left the archive in /tmp after a failed import; it only takes space.
    remote_exec "$vm_name" "$zone" "$project" "rm -f /tmp/instana-airgapped.tar.gz ${AIRGAP_REMOTE_ARCHIVE} ${AIRGAP_REMOTE_ARCHIVE}.part"
    airgap_check_space "$vm_name" "$zone" "$project" $(( 2 * local_size + AIRGAP_SPACE_MARGIN_BYTES ))
    log "Copying air-gapped package to ${vm_name} ($(du -h "$AIRGAP_ARCHIVE" 2>/dev/null | cut -f1 || echo '?'))..."
    spin_run "copying the air-gapped package to ${vm_name}" provider_scp "$AIRGAP_ARCHIVE" "$vm_name" "$zone" "$project" "${AIRGAP_REMOTE_ARCHIVE}.part" bulk
    remote_exec "$vm_name" "$zone" "$project" "mv -f ${AIRGAP_REMOTE_ARCHIVE}.part ${AIRGAP_REMOTE_ARCHIVE}"
  fi

  # Documented sequence: extract the bundled stanctl binary to /usr/local/bin,
  # then import the package. The import is not idempotent, so it is never
  # retried automatically (SSH_RETRY_MAX=1) and a lock refuses a second import
  # while one is still running. The marker is written before anything is
  # deleted; the copy is removed only afterwards, as a separate step.
  # Children get 9>&- so nothing stanctl starts keeps holding the lock.
  printf -v q_backend '%q' "$BACKEND_VERSION"; printf -v q_cli '%q' "$STANCTL_CLI_VERSION"
  SSH_RETRY_MAX=1 HEARTBEAT_LABEL="air-gapped import on ${vm_name}" remote_exec "$vm_name" "$zone" "$project" \
    "set -e; exec 9>/var/lock/instana-airgap-import.lock; flock -n 9 || { echo 'STOP: another air-gapped import is still running on this VM.' >&2; exit 3; }; tar -xzf ${AIRGAP_REMOTE_ARCHIVE} -C /usr/local/bin --strip-components 1 airgapped/stanctl 9>&-; chmod 0755 /usr/local/bin/stanctl; hash -r; stanctl --version 9>&-; stanctl air-gapped import --file ${AIRGAP_REMOTE_ARCHIVE} 9>&-; install -d -m 0755 ${AIRGAP_IMPORT_MARKER%/*}; printf 'backend=%s stanctl=%s size=%s\n' ${q_backend} ${q_cli} ${local_size} > ${AIRGAP_IMPORT_MARKER}.tmp; mv -f ${AIRGAP_IMPORT_MARKER}.tmp ${AIRGAP_IMPORT_MARKER}" || rc=$?
  if (( rc == 255 )); then
    die_with_steps "The SSH connection to ${vm_name} was lost during the air-gapped import; it was not retried automatically because an import must not run twice at once." \
      "*The package copy stays in ${AIRGAP_REMOTE_ARCHIVE} on ${vm_name}. --resume checks whether the import finished (marker ${AIRGAP_IMPORT_MARKER}) and otherwise imports again from that copy, without a new transfer." \
      "Continue when the VM is reachable again:|./install.sh --resume"
  elif (( rc != 0 )); then
    die_with_steps "Air-gapped import failed on ${vm_name} (exit ${rc}); see the stanctl output above." \
      "*The package copy stays in ${AIRGAP_REMOTE_ARCHIVE} on ${vm_name}; --resume verifies it by checksum and does not copy it again." \
      "Inspect the VM if needed:|$(provider_hint ssh "$vm_name" "$zone" "$project")" \
      "Continue where it stopped:|./install.sh --resume"
  fi
  cli_output=$(remote_value "$vm_name" "$zone" "$project" CLI "echo CLI=\$(stanctl --version 2>/dev/null | head -1)") || cli_output=""
  installed=$(stanctl_version_token "$cli_output")
  [[ "$installed" == "$STANCTL_CLI_VERSION" ]] ||
    die_with_steps "Installed stanctl on ${vm_name} reports '${cli_output:-nothing}', expected ${STANCTL_CLI_VERSION} from the archive build metadata." \
      "Check which stanctl the VM runs:|$(provider_hint ssh "$vm_name" "$zone" "$project" "command -v stanctl; stanctl --version")" \
      "*Remove any other stanctl earlier in root's PATH, then continue:|./install.sh --resume"
  save_state stanctl_cli_version "$STANCTL_CLI_VERSION"
  save_state backend_version "$BACKEND_VERSION"
  save_state "step_airgap_imported_${vm_name}" completed
  remote_exec "$vm_name" "$zone" "$project" "rm -f ${AIRGAP_REMOTE_ARCHIVE} ${AIRGAP_REMOTE_ARCHIVE}.part" ||
    warn "Could not remove the package copy on ${vm_name}; remove ${AIRGAP_REMOTE_ARCHIVE} by hand to free space."
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
  [[ -n "$saved" ]] || saved="$REQUESTED_STANCTL_APT_VERSION"
  # The previous run stopped because this stanctl could not list the backend
  # versions: resume offers another version instead of repeating the stop.
  local failed change=false choice
  failed=$(get_state stanctl_identify_failed)
  if [[ -n "$failed" && "$saved" == "$failed" ]]; then
    echo "" >&2
    hint "Last time stanctl ${failed} on ${vm_name} could not list the backend versions (see the HOW TO RESOLVE box of that stop)." \
      "Known case: stanctl 1.15.1 cannot read the version list with the download key it is given (HTTP 401 on a machine" \
      "without earlier stanctl data in ~/.stanctl, such as this new VM); 1.15.0 works. Another version is installed" \
      "on the VM (downgrade allowed); the VM and disks are kept."
    choice=$(PROMPT_CHOICE_DEFAULT="choose another stanctl version" prompt_choice "stanctl ${failed} failed last time. What now?" \
      "choose another stanctl version" "keep stanctl ${failed} and try again") ||
      die "stanctl version selection was cancelled."
    if [[ "$choice" == "choose another stanctl version" ]]; then
      saved=""; change=true
      local -a others=(); local v
      for v in "${stanctl_versions[@]}"; do [[ "$v" == "$failed" ]] || others+=("$v"); done
      (( ${#others[@]} > 0 )) || die "The repository offers no stanctl version other than ${failed}."
      stanctl_versions=("${others[@]}")
    fi
  fi
  if [[ -n "$saved" ]]; then
    printf '%s\n' "${stanctl_versions[@]}" | grep -Fxq "$saved" ||
      die "Saved stanctl version ${saved} is no longer available from the configured repository."
    selected="$saved"
    phase_detail done "Using the pinned stanctl package: ${selected}"
  else
    echo ""
    echo -e "${BOLD}Available stanctl package versions (newest first):${RESET}" >&2
    selected=$(PROMPT_CHOICE_NEWEST=1 prompt_choice "Select the exact stanctl version to install:" "${stanctl_versions[@]}") ||
      die "stanctl version selection was cancelled."
  fi
  STANCTL_APT_VERSION="$selected"

  installed=$(remote_exec "$vm_name" "$zone" "$project" "dpkg-query -W -f='\${Version}' stanctl 2>/dev/null || true")
  if [[ "$installed" != "$STANCTL_APT_VERSION" ]]; then
    remote_exec "$vm_name" "$zone" "$project" \
      "apt-mark unhold stanctl >/dev/null 2>&1 || true; if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades 'stanctl=$STANCTL_APT_VERSION'; then apt-mark hold stanctl >/dev/null 2>&1 || true; exit 1; fi; apt-mark hold stanctl"
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
  # stderr is kept for the stop message (the key is never in it).
  local identify_rc=0
  raw_backends=$(remote_exec "$vm_name" "$zone" "$project" \
    "set -a; . /root/.stanctl-version.env; set +a; trap 'rm -f /root/.stanctl-version.env' EXIT; stanctl versions identify --quiet 2>&1") || identify_rc=$?
  if (( identify_rc != 0 )); then
    save_state stanctl_identify_failed "$STANCTL_APT_VERSION"
    stanctl_identify_stop vm "$(stanctl_error_line "$raw_backends")" "$vm_name"
  fi
  save_state stanctl_identify_failed ""
  mapfile -t backend_versions < <(printf '%s\n' "$raw_backends" | sed -nE 's/^[[:space:]]*-[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+[-.+~][0-9A-Za-z.-]+)[[:space:]]*$/\1/p' | sort -rV | awk '!seen[$0]++')
  (( ${#backend_versions[@]} > 0 )) ||
    die "stanctl returned no selectable compatible backend versions; no backend installation was started."

  saved=$(get_state backend_version)
  [[ -n "$saved" ]] || saved="$REQUESTED_BACKEND_VERSION"
  # A stanctl changed on resume may not offer the requested backend: ask.
  if [[ "$change" == true && -n "$saved" ]] && ! printf '%s\n' "${backend_versions[@]}" | grep -Fxq "$saved"; then
    warn "Backend ${saved} is not offered by stanctl ${STANCTL_CLI_VERSION}; choose a backend version from its list."
    saved=""
  fi
  if [[ -n "$saved" ]]; then
    printf '%s\n' "${backend_versions[@]}" | grep -Fxq "$saved" ||
      die "Saved backend ${saved} is not compatible with stanctl ${STANCTL_CLI_VERSION}."
    selected="$saved"
    save_state backend_version "$selected"
    phase_detail done "Using the pinned backend version: ${selected}"
  else
    echo ""
    echo -e "${BOLD}Backend versions compatible with stanctl ${STANCTL_CLI_VERSION}:${RESET}" >&2
    selected=$(PROMPT_CHOICE_NEWEST=1 prompt_choice "Select the exact Instana backend version to install:" "${backend_versions[@]}") ||
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

  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow $(provider_ssh_port)/tcp"
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

  remote_exec_dry "$vm_name" "$zone" "$project" "ufw allow $(provider_ssh_port)/tcp"
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
# stanctl up waits for the cluster only as long as its global --timeout
# (default 30m0s) and then exits 1, even while Kubernetes keeps bringing
# Instana up. Observed 2026-10-29 (single-node n2-standard-16, stanctl 1.15.0,
# backend 3.327.712-0): exit 1 after ~63 min with Core still "Progressing";
# minutes later all pods were Running. The installer therefore passes a longer
# timeout and, when stanctl up still fails, checks the cluster itself before
# it decides. The wait is a deployment parameter (STANCTL_UP_TIMEOUT: plan
# line, E at the plan, --config, saved for --resume; default 90m);
# INSTANA_STANCTL_TIMEOUT in the environment overrides it, and "default" there
# passes no --timeout at all (stanctl's own 30 minutes).
STANCTL_UP_TIMEOUT_DEFAULT=90m
STANCTL_UP_TIMEOUT=""
# After a failed stanctl up, and on resume, wait up to this many minutes for
# Core and Unit to report Ready (checked every INSTANA_READY_POLL seconds).
INSTANA_READY_WAIT_MIN="${INSTANA_READY_WAIT_MIN:-20}"
INSTANA_READY_POLL="${INSTANA_READY_POLL:-30}"
# stanctl up's own output on the VM (for the stop message; no secrets in it).
STANCTL_UP_OUT=/root/.stanctl-up.out
STANCTL_CONSOLE_LOG=/root/.stanctl/logs/console.log

# stanctl_timeout_minutes VALUE — minutes for 90, 90m, 2h or 1h30m; 1 otherwise.
stanctl_timeout_minutes() {
  local v="$1"
  if [[ "$v" =~ ^[0-9]{1,4}$ ]]; then echo $(( 10#$v ))
  elif [[ "$v" =~ ^([0-9]{1,4})m$ ]]; then echo $(( 10#${BASH_REMATCH[1]} ))
  elif [[ "$v" =~ ^([0-9]{1,2})h(([0-9]{1,3})m)?$ ]]; then echo $(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[3]:-0} ))
  else return 1; fi
}

# validate_stanctl_timeout VALUE [LABEL] — whole minutes 30-600 (90, 90m, 2h, 1h30m).
validate_stanctl_timeout() {
  local m
  if ! m=$(stanctl_timeout_minutes "$1"); then
    err "${2:-stanctl up timeout} '${1}' is not a wait time: use whole minutes (90) or 90m, 2h, 1h30m."
    return 1
  fi
  (( m >= 30 && m <= 600 )) ||
    { err "${2:-stanctl up timeout} '${1}' is ${m} minutes; use 30 to 600 minutes (stanctl's own default is 30)."; return 1; }
}

stanctl_timeout_normalize() { printf '%sm' "$(stanctl_timeout_minutes "$1")"; }

# The wait passed to stanctl up: "default" (no flag) or "<minutes>m".
stanctl_timeout_effective() {
  if [[ -n "${INSTANA_STANCTL_TIMEOUT:-}" ]]; then
    if [[ "$INSTANA_STANCTL_TIMEOUT" == default ]]; then echo default; else stanctl_timeout_normalize "$INSTANA_STANCTL_TIMEOUT"; fi
  elif [[ -n "${STANCTL_UP_TIMEOUT:-}" ]]; then stanctl_timeout_normalize "$STANCTL_UP_TIMEOUT"
  else echo "$STANCTL_UP_TIMEOUT_DEFAULT"; fi
}

# The plan line: "90 min (E changes it)".
stanctl_timeout_plan_text() {
  local e; e=$(stanctl_timeout_effective)
  if [[ "$e" == default ]]; then echo "30 min, stanctl's own default (INSTANA_STANCTL_TIMEOUT=default; E cannot change it while that is set)"
  elif [[ -n "${INSTANA_STANCTL_TIMEOUT:-}" ]]; then echo "${e%m} min (from INSTANA_STANCTL_TIMEOUT; E cannot change it while that is set)"
  else echo "${e%m} min (E changes it)"; fi
}

check_stanctl_timeout() {
  if [[ -n "${INSTANA_STANCTL_TIMEOUT:-}" && "$INSTANA_STANCTL_TIMEOUT" != default ]] &&
     ! validate_stanctl_timeout "$INSTANA_STANCTL_TIMEOUT" INSTANA_STANCTL_TIMEOUT 2>/dev/null; then
    die_with_steps "INSTANA_STANCTL_TIMEOUT='${INSTANA_STANCTL_TIMEOUT}' is not a valid wait time for stanctl up (whole minutes 30-600, or 90m, 2h, 1h30m)." \
      "*Why it blocks: it is passed to 'stanctl up --timeout'; a wrong value would only fail later, in phase 11." \
      "Use minutes or hours, e.g.:|INSTANA_STANCTL_TIMEOUT=2h ./install.sh" \
      "Or remove it; the plan value is used then (default 90 min, E at the plan changes it):|unset INSTANA_STANCTL_TIMEOUT; ./install.sh" \
      "*INSTANA_STANCTL_TIMEOUT=default passes no --timeout (stanctl's own 30 minutes)."
  fi
  if [[ -n "${STANCTL_UP_TIMEOUT:-}" ]] && ! validate_stanctl_timeout "$STANCTL_UP_TIMEOUT" STANCTL_UP_TIMEOUT 2>/dev/null; then
    die_with_steps "The saved STANCTL_UP_TIMEOUT='${STANCTL_UP_TIMEOUT}' in .install-config.json is not a valid wait time (whole minutes 30-600, or 90m, 2h, 1h30m)." \
      "Correct it in the file (e.g. \"STANCTL_UP_TIMEOUT\": \"90m\"), then run again:|nano ${CONFIG_FILE}" \
      "*Or override it for this run: INSTANA_STANCTL_TIMEOUT=90m ./install.sh --resume"
  fi
  if [[ ! "$INSTANA_READY_WAIT_MIN" =~ ^[0-9]+$ || ! "$INSTANA_READY_POLL" =~ ^[0-9]+$ ]]; then
    die_with_steps "INSTANA_READY_WAIT_MIN='${INSTANA_READY_WAIT_MIN}' / INSTANA_READY_POLL='${INSTANA_READY_POLL}' must be whole numbers (minutes / seconds)." \
      "Remove them for the defaults (20 minutes, a check every 30 s):|unset INSTANA_READY_WAIT_MIN INSTANA_READY_POLL; ./install.sh"
  fi
}

stanctl_timeout_flag() {
  local e; e=$(stanctl_timeout_effective)
  [[ "$e" == default ]] || printf -- '--timeout %s' "$e"
}

stanctl_timeout_text() {
  local e; e=$(stanctl_timeout_effective)
  if [[ "$e" == default ]]; then echo "30m (stanctl default)"; else echo "$e"; fi
}

# stanctl_up_remote_cmd TLS_FLAGS — the env file (keys) is removed when the
# command ends; stanctl's output still streams and is also kept on the VM.
stanctl_up_remote_cmd() {
  printf '%s' "trap 'rm -f /root/.stanctl.env' EXIT; set -o pipefail; umask 077; stanctl up --env-file /root/.stanctl.env $(stanctl_version_flag) $(stanctl_timeout_flag) ${1} --quiet 2>&1 | tee ${STANCTL_UP_OUT}"
}

# run_stanctl_up NODE ZONE PROJECT TLS_FLAGS EXPECTED_NODES — one attempt (a
# lost SSH connection is not retried: stanctl may still run on the node and a
# second one is never started blindly). A failure is followed by a check of the
# cluster: Instana that came up anyway continues; anything else stops with
# HOW TO RESOLVE.
PHASE11_NOTE=""
run_stanctl_up() {
  local node="$1" zone="$2" project="$3" tls_flags="$4" nodes="$5" rc=0 started=$SECONDS cmd
  check_stanctl_timeout
  cmd=$(stanctl_up_remote_cmd "$tls_flags")
  [[ "$DRY_RUN" == true ]] || save_state stanctl_up_status running
  phase_detail active "stanctl up waits up to $(stanctl_timeout_text) for the cluster (plan value STANCTL_UP_TIMEOUT; INSTANA_STANCTL_TIMEOUT overrides it)."
  SSH_RETRY_MAX=1 HEARTBEAT_LABEL="stanctl up on ${node}" remote_exec_dry "$node" "$zone" "$project" "$cmd" || rc=$?
  if (( rc == 0 )); then
    save_state stanctl_up_status completed
    ok "stanctl up completed on ${node}."
    return 0
  fi
  stanctl_up_recover "$node" "$zone" "$project" "$rc" "$nodes" "$(( SECONDS - started ))"
}

stanctl_up_recover() {
  local node="$1" zone="$2" project="$3" rc="$4" nodes="$5" took="$6"
  echo "" >&2
  warn "stanctl up on ${node} ended with exit code ${rc} after $(fmt_duration "$took") (its own wait limit: $(stanctl_timeout_text))."
  (( rc != 255 )) || warn "Exit 255 means the SSH connection to ${node} was lost; stanctl may still be running there. It is not started a second time."
  stanctl_failure_lines "$node" "$zone" "$project"
  log "Checking what actually runs on ${node} before deciding: nodes, Instana Core and Unit, pods (up to ${INSTANA_READY_WAIT_MIN} min more)."
  if wait_for_instana_ready "$node" "$zone" "$project" "$nodes"; then
    warn "stanctl up reported a failure (exit ${rc}; usually its own timeout), but Instana came up: ${CLUSTER_SHORT}. Continuing with phase 12."
    save_state stanctl_up_status completed
    LAST_FAILED_STEP=""
    PHASE11_NOTE="stanctl up exited ${rc}, but Core and Unit were verified Ready on ${node}."
    return 0
  fi
  save_state stanctl_up_status failed
  instana_not_ready_stop "$node" "$zone" "$project" \
    "stanctl up on ${node} failed (exit ${rc} after $(fmt_duration "$took")) and Instana is not ready." fresh
}

# mask_secrets — hides values of anything that looks like a key, password,
# token or secret, and the keys/password of this run wherever they appear.
mask_secrets() {
  local line v
  while IFS= read -r line || [[ -n "$line" ]]; do
    for v in "${DOWNLOAD_KEY:-}" "${SALES_KEY:-}" "${AGENT_KEY:-}" "${ADMIN_PASSWORD:-}"; do
      [[ ${#v} -lt 4 ]] || line="${line//"$v"/•••}"
    done
    printf '%s\n' "$line"
  done | sed -E 's/([A-Za-z_.-]*([Kk][Ee][Yy]|[Pp][Aa][Ss][Ss][Ww][Oo]?[Rr][Dd]|[Pp][Aa][Ss][Ss]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt])[A-Za-z_.-]*"?[[:space:]]*[=:][[:space:]]*)("[^"]*"|[^[:space:],}]+)/\1•••/g'
}

# stanctl_failure_lines NODE ZONE PROJECT — fills STANCTL_TAIL with the last
# lines stanctl printed and the end of its console.log (repeated health-check
# lines folded into one with a count, the time stamp removed), secrets masked.
STANCTL_TAIL=()
stanctl_failure_lines() {
  local node="$1" zone="$2" project="$3" out line
  STANCTL_TAIL=()
  [[ "$DRY_RUN" != true ]] || return 0
  out=$(HEARTBEAT_LABEL="reading stanctl's last output on ${node}" remote_exec "$node" "$zone" "$project" \
    "test -s ${STANCTL_UP_OUT} && { echo '== OUT'; tail -n 10 ${STANCTL_UP_OUT}; }; test -s ${STANCTL_CONSOLE_LOG} && { echo '== LOG'; tail -n 400 ${STANCTL_CONSOLE_LOG}; }; true" 2>/dev/null) || out=""
  local section="" ; local -a log_lines=()
  while IFS= read -r line; do
    case "$line" in
      "== OUT") section=out; continue ;;
      "== LOG") section=log; continue ;;
    esac
    [[ -n "${line//[[:space:]]/}" ]] || continue
    if [[ "$section" == out ]]; then STANCTL_TAIL+=("stanctl: ${line:0:220}")
    elif [[ "$section" == log ]]; then log_lines+=("$line"); fi
  done < <(mask_secrets <<< "$out")
  if (( ${#log_lines[@]} > 0 )); then
    while IFS= read -r line; do STANCTL_TAIL+=("console.log: ${line:0:220}"); done < <(
      printf '%s\n' "${log_lines[@]}" | sed -E 's/^time=("[^"]*"|[^[:space:]]+)[[:space:]]*//' |
        awk '{ if ($0 == prev) { n++ } else { if (NR > 1) print (n > 1 ? "(" n "x) " : "") prev; prev = $0; n = 1 } } END { if (NR) print (n > 1 ? "(" n "x) " : "") prev }' |
        tail -n 12)
  fi
  if (( ${#STANCTL_TAIL[@]} > 0 )); then
    echo -e "  ${BOLD}Last lines from stanctl on ${node} (secrets masked):${RESET}" >&2
    printf '    %s\n' "${STANCTL_TAIL[@]}" >&2
  else
    echo "  (no stanctl output found on ${node}: ${STANCTL_UP_OUT} and ${STANCTL_CONSOLE_LOG} are empty or missing)" >&2
  fi
}

# One read-only look at the cluster on a node; prints KEY=VALUE lines and
# CORE/UNIT/POD lines (see instana_cluster_check).
read -r -d '' INSTANA_STATUS_SCRIPT <<'STATUS' || true
set +e
if pgrep -x stanctl >/dev/null 2>&1; then echo "STANCTL_RUNNING=yes"; else echo "STANCTL_RUNNING=no"; fi
if ! test -e /etc/rancher/k3s/k3s.yaml; then echo "K3S=no"; exit 0; fi
echo "K3S=yes"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k=kubectl; command -v kubectl >/dev/null 2>&1 || k="k3s kubectl"
nodes=$(timeout 30 $k get nodes --no-headers 2>/dev/null) || { echo "API=down"; exit 0; }
echo "API=up"
echo "NODES_TOTAL=$(printf '%s\n' "$nodes" | grep -c .)"
echo "NODES_READY=$(printf '%s\n' "$nodes" | awk '$2 == "Ready"' | grep -c .)"
timeout 30 $k get core -A -o jsonpath='{range .items[*]}CORE {.metadata.namespace}/{.metadata.name} {.status.componentsStatus}{"\n"}{end}' 2>/dev/null
timeout 30 $k get unit -A -o jsonpath='{range .items[*]}UNIT {.metadata.namespace}/{.metadata.name} {.status.componentsStatus}{"\n"}{end}' 2>/dev/null
pods=$(timeout 30 $k get pods -A --no-headers 2>/dev/null)
echo "PODS_TOTAL=$(printf '%s\n' "$pods" | grep -c .)"
printf '%s\n' "$pods" | awk 'NF >= 4 { if ($4 == "Completed") next; split($3, r, "/"); if ($4 != "Running") print "POD " $1 "/" $2 " " $4; else if (r[1] != r[2]) print "POD " $1 "/" $2 " Running-not-ready(" $3 ")" }'
STATUS

# instana_cluster_check NODE ZONE PROJECT EXPECTED_NODES — sets CLUSTER_* and
# CLUSTER_VERDICT: ready | progressing | absent (no k3s) | api_down |
# unreachable (the check itself could not run).
CLUSTER_VERDICT="" CLUSTER_SHORT="" CLUSTER_STANCTL=no CLUSTER_NODES_READY=0 CLUSTER_NODES_TOTAL=0 CLUSTER_PODS_TOTAL=0
CLUSTER_CORE=() CLUSTER_UNIT=() CLUSTER_PODS=()
instana_cluster_check() {
  local node="$1" zone="$2" project="$3" expected="${4:-1}" out line k3s=unknown api=unknown entry ok_core=0 ok_unit=0
  CLUSTER_VERDICT=unreachable CLUSTER_STANCTL=no CLUSTER_NODES_READY=0 CLUSTER_NODES_TOTAL=0 CLUSTER_PODS_TOTAL=0
  CLUSTER_CORE=() CLUSTER_UNIT=() CLUSTER_PODS=()
  if ! out=$(HEARTBEAT_LABEL="checking Kubernetes, Instana Core and Unit on ${node}" remote_exec "$node" "$zone" "$project" "$INSTANA_STATUS_SCRIPT"); then
    CLUSTER_SHORT="the status check on ${node} could not run (SSH or sudo failed)"
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      STANCTL_RUNNING=*) CLUSTER_STANCTL="${line#*=}" ;;
      K3S=*) k3s="${line#*=}" ;;
      API=*) api="${line#*=}" ;;
      NODES_TOTAL=*) CLUSTER_NODES_TOTAL="${line#*=}" ;;
      NODES_READY=*) CLUSTER_NODES_READY="${line#*=}" ;;
      PODS_TOTAL=*) CLUSTER_PODS_TOTAL="${line#*=}" ;;
      "CORE "*) entry="${line#CORE }"; [[ "$entry" == *" "?* ]] || entry="${entry% } Unknown"; CLUSTER_CORE+=("$entry") ;;
      "UNIT "*) entry="${line#UNIT }"; [[ "$entry" == *" "?* ]] || entry="${entry% } Unknown"; CLUSTER_UNIT+=("$entry") ;;
      "POD "*) CLUSTER_PODS+=("${line#POD }") ;;
    esac
  done <<< "$out"
  [[ "$CLUSTER_NODES_TOTAL" =~ ^[0-9]+$ ]] || CLUSTER_NODES_TOTAL=0
  [[ "$CLUSTER_NODES_READY" =~ ^[0-9]+$ ]] || CLUSTER_NODES_READY=0
  for entry in "${CLUSTER_CORE[@]}"; do [[ "${entry##* }" != Ready ]] || ok_core=$((ok_core + 1)); done
  for entry in "${CLUSTER_UNIT[@]}"; do [[ "${entry##* }" != Ready ]] || ok_unit=$((ok_unit + 1)); done
  if [[ "$k3s" == no ]]; then
    CLUSTER_VERDICT=absent
    CLUSTER_SHORT="Kubernetes (k3s) is not installed on ${node}"
  elif [[ "$k3s" != yes ]]; then
    CLUSTER_SHORT="the status check on ${node} gave no usable answer"
  elif [[ "$api" != up ]]; then
    CLUSTER_VERDICT=api_down
    CLUSTER_SHORT="k3s is installed on ${node}, but the Kubernetes API does not answer"
  else
    CLUSTER_SHORT="nodes Ready ${CLUSTER_NODES_READY}/${CLUSTER_NODES_TOTAL}, Core $(cluster_states "${CLUSTER_CORE[@]}"), Unit $(cluster_states "${CLUSTER_UNIT[@]}"), pods not Running ${#CLUSTER_PODS[@]}/${CLUSTER_PODS_TOTAL}"
    if (( ${#CLUSTER_CORE[@]} > 0 && ok_core == ${#CLUSTER_CORE[@]} && ${#CLUSTER_UNIT[@]} > 0 && ok_unit == ${#CLUSTER_UNIT[@]} &&
          CLUSTER_NODES_TOTAL >= expected && CLUSTER_NODES_READY == CLUSTER_NODES_TOTAL )); then
      CLUSTER_VERDICT=ready
    else
      CLUSTER_VERDICT=progressing
    fi
  fi
  return 0
}

# cluster_states "ns/name STATUS"... → "Ready" / "Progressing, Ready" / "not created yet"
cluster_states() {
  (( $# > 0 )) || { echo "not created yet"; return; }
  local e; local -a s=()
  for e in "$@"; do s+=("${e##* }"); done
  printf '%s\n' "${s[@]}" | awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g'
}

# wait_for_instana_ready NODE ZONE PROJECT EXPECTED_NODES — 0 once Core and
# Unit are Ready and every node is Ready; 1 when that did not happen within
# INSTANA_READY_WAIT_MIN minutes, or at once when there is no cluster at all
# (or the check cannot run). Every check and every pause shows a spinner.
wait_for_instana_ready() {
  local node="$1" zone="$2" project="$3" expected="$4" start=$SECONDS limit last="" waited
  limit=$(( INSTANA_READY_WAIT_MIN * 60 ))
  while :; do
    instana_cluster_check "$node" "$zone" "$project" "$expected"
    [[ "$CLUSTER_SHORT" == "$last" ]] || phase_detail active "${node}: ${CLUSTER_SHORT}"
    last="$CLUSTER_SHORT"
    case "$CLUSTER_VERDICT" in
      ready) return 0 ;;
      absent) [[ "$CLUSTER_STANCTL" == yes ]] || return 1 ;;
      unreachable) return 1 ;;
    esac
    waited=$(( SECONDS - start ))
    (( waited < limit )) || return 1
    spin_run "waiting for Instana Core and Unit to report Ready on ${node} (waited $(fmt_duration "$waited") of ${INSTANA_READY_WAIT_MIN}m)" sleep "$INSTANA_READY_POLL"
  done
}

# instana_not_ready_stop NODE ZONE PROJECT HEADLINE fresh|resume — what was
# found (cluster state, stanctl's last lines), why it blocks, the commands to
# inspect it and how to continue.
instana_not_ready_stop() {
  local node="$1" zone="$2" project="$3" headline="$4" ctx="$5" p
  local -a steps=()
  local inspect_pods inspect_core inspect_log remove
  inspect_pods=$(provider_hint ssh "$node" "$zone" "$project" 'sudo kubectl get pods -A | grep -v Running')
  inspect_core=$(provider_hint ssh "$node" "$zone" "$project" 'sudo kubectl get core -n instana-core -o yaml | grep -A5 status; sudo kubectl get unit -A')
  inspect_log=$(provider_hint ssh "$node" "$zone" "$project" "sudo tail -n 100 ${STANCTL_CONSOLE_LOG}")
  if [[ "$(provider_name)" == ssh ]]; then
    remove="If it does not recover: forget this deployment here (./install.sh --destroy), remove k3s on the host (sudo /usr/local/bin/k3s-uninstall.sh), then install again:|./install.sh --destroy"
  else
    remove="If it does not recover: delete the lab (menu: destroy or clean up) and install again:|./install.sh --destroy"
  fi
  steps+=("*Found: ${CLUSTER_SHORT}.")
  if [[ "$CLUSTER_VERDICT" == progressing ]]; then
    for p in "${CLUSTER_CORE[@]}"; do [[ "${p##* }" == Ready ]] || steps+=("*  Core ${p% *}: ${p##* } (not Ready)"); done
    for p in "${CLUSTER_UNIT[@]}"; do [[ "${p##* }" == Ready ]] || steps+=("*  Unit ${p% *}: ${p##* } (not Ready)"); done
    (( ${#CLUSTER_CORE[@]} > 0 )) || steps+=("*  Core: not created yet")
    (( ${#CLUSTER_UNIT[@]} > 0 )) || steps+=("*  Unit: not created yet")
    (( CLUSTER_NODES_READY == CLUSTER_NODES_TOTAL )) || steps+=("*  Kubernetes nodes Ready: ${CLUSTER_NODES_READY} of ${CLUSTER_NODES_TOTAL}")
    for p in "${CLUSTER_PODS[@]:0:10}"; do steps+=("*  pod ${p}"); done
    (( ${#CLUSTER_PODS[@]} <= 10 )) || steps+=("*  ... and $(( ${#CLUSTER_PODS[@]} - 10 )) more pods not Running")
  fi
  for p in "${STANCTL_TAIL[@]}"; do steps+=("*  ${p}"); done
  if [[ "$CLUSTER_STANCTL" == yes ]]; then
    steps+=("*Why it blocks: stanctl is still running on ${node} (e.g. after a lost SSH connection); a second stanctl up is never started next to it, and the result is not known yet."
      "Watch it until it ends:|$(provider_hint ssh "$node" "$zone" "$project" "pgrep -a stanctl; sudo tail -f ${STANCTL_CONSOLE_LOG}")"
      "When stanctl has ended, continue; resume checks the cluster again and, when Core and Unit are Ready, finishes phase 12 and the report:|./install.sh --resume")
  elif [[ "$CLUSTER_VERDICT" == absent ]]; then
    steps+=("*Why it blocks: stanctl stopped before the Kubernetes cluster existed, so there is nothing to finish; its last lines above say why.")
    [[ " ${STANCTL_TAIL[*]} " != *"unknown flag: --timeout"* ]] ||
      steps+=("This stanctl does not know --timeout: continue without it (stanctl's own 30 minutes):|INSTANA_STANCTL_TIMEOUT=default ./install.sh --resume")
    steps+=("Full stanctl log on ${node}:|${inspect_log}"
      "Correct the cause, then continue; with no cluster on ${node}, resume runs stanctl up again:|./install.sh --resume" "$remove")
  elif [[ "$CLUSTER_VERDICT" == unreachable || "$CLUSTER_VERDICT" == api_down ]]; then
    steps+=("*Why it blocks: without an answer from Kubernetes the installer cannot tell whether Instana is running; it never reports success without that check."
      "Check that ${node} answers and that k3s runs:|$(provider_hint ssh "$node" "$zone" "$project" 'sudo systemctl status k3s --no-pager | head -20; sudo kubectl get nodes')"
      "Full stanctl log on ${node}:|${inspect_log}"
      "When k3s answers again, continue; resume checks the cluster again:|./install.sh --resume" "$remove")
  else
    steps+=("*Why it blocks: phase 12 (health check, hosts lines, final report) needs Instana Core and Unit Ready; the installer waited ${INSTANA_READY_WAIT_MIN} more minutes and never reports success without that."
      "See which pods are not running (Pending / ContainerCreating = still starting; CrashLoopBackOff / Error = broken):|${inspect_pods}"
      "Status of Instana Core and Unit:|${inspect_core}"
      "Full stanctl log on ${node}:|${inspect_log}"
      "If it is still starting, continue later; resume checks again (waits up to ${INSTANA_READY_WAIT_MIN} min) and, once Core and Unit are Ready, finishes phase 12 and the report without running stanctl up again:|./install.sh --resume"
      "If it is stuck, let stanctl apply the configuration to this cluster again (same pinned stanctl and backend; cluster and data disks are kept), then the same checks follow:|INSTANA_RERUN_STANCTL_UP=yes ./install.sh --resume"
      "$remove")
  fi
  [[ "$ctx" != fresh ]] || steps+=("*The VM/hosts and disks are kept (on Google Cloud they are billed meanwhile). Log: ${LOG_FILE}")
  die_with_steps "$headline" "${steps[@]}"
}

# True when this deployment ran (or started) stanctl up: recorded in the
# state, or phase 10 (install stanctl, directly followed by stanctl up) is
# recorded as completed (states written before stanctl_up_status existed).
stanctl_up_was_started() {
  [[ -n "$(get_state stanctl_up_status)" || "$(get_state progress_phase_10)" == completed || "$(get_state progress_phase_11)" == completed ]]
}

# resume_after_stanctl_up NODE ZONE PROJECT EXPECTED_NODES — resume when this
# deployment's stanctl up already ran: never repeated automatically. 0 = Instana
# is up (phase 11 done); 1 = run stanctl up now (no cluster exists and no
# stanctl runs, or INSTANA_RERUN_STANCTL_UP=yes); otherwise stops and explains.
resume_after_stanctl_up() {
  local node="$1" zone="$2" project="$3" expected="$4" status
  status=$(get_state stanctl_up_status)
  log "This deployment already ran stanctl up on ${node} (recorded: ${status:-not recorded; phase 10 completed}). It is not started again before the cluster is checked."
  STANCTL_TAIL=()
  if wait_for_instana_ready "$node" "$zone" "$project" "$expected"; then
    ok "Instana is up on ${node}: ${CLUSTER_SHORT}."
    save_state stanctl_up_status completed
    PHASE11_NOTE="stanctl up was not repeated: Core and Unit were verified Ready on ${node}."
    return 0
  fi
  if [[ "$CLUSTER_VERDICT" == absent && "$CLUSTER_STANCTL" != yes ]]; then
    warn "No Kubernetes cluster and no running stanctl on ${node}: the earlier stanctl up stopped before the cluster existed; running it again."
    return 1
  fi
  if [[ "${INSTANA_RERUN_STANCTL_UP:-}" == yes && "$CLUSTER_STANCTL" != yes && "$CLUSTER_VERDICT" != unreachable ]]; then
    warn "INSTANA_RERUN_STANCTL_UP=yes: running stanctl up again on ${node} with the pinned versions; it applies the configuration to the existing cluster."
    return 1
  fi
  stanctl_failure_lines "$node" "$zone" "$project"
  save_state stanctl_up_status failed
  instana_not_ready_stop "$node" "$zone" "$project" \
    "Resume found Kubernetes from this deployment's stanctl up on ${node}, but Instana is not ready." resume
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

  run_stanctl_up "$vm_name" "$zone" "$project" "$tls_flags" 1
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

  run_stanctl_up "$node0_name" "$zone" "$project" "$tls_flags" 3
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

  HEARTBEAT_LABEL="waiting for Kubernetes nodes to be Ready" remote_exec "$vm_name" "$zone" "$project" \
    "set -e; kubectl wait --for=condition=Ready nodes --all --timeout=300s"

  local namespace
  for namespace in instana-core instana-unit; do
    HEARTBEAT_LABEL="waiting for pods in ${namespace} to be Ready" remote_exec "$vm_name" "$zone" "$project" \
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

  # Decided before Start (plan: E → KUBE_USER_ACCESS); never asked at the end.
  if [[ "${KUBE_USER_ACCESS:-no}" != yes ]]; then
    phase_detail warn "User kubeconfig not set up (KUBE_USER_ACCESS=no; E at the plan changes it); sudo kubectl remains available."
    echo "  To allow it later on ${vm_name}: mkdir -p ~/.kube && sudo install -o \$(id -u) -g \$(id -g) -m 600 /etc/rancher/k3s/k3s.yaml ~/.kube/config"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    phase_detail active "Would copy the cluster-admin kubeconfig to the SSH user's ~/.kube/config on ${vm_name}."
    return 0
  fi

  remote_user_exec "$vm_name" "$zone" "$project" \
    'set -e; mkdir -p "$HOME/.kube"; chmod 700 "$HOME/.kube"; uid=$(id -u); gid=$(id -g); sudo install -o "$uid" -g "$gid" -m 600 /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"; KUBECONFIG="$HOME/.kube/config" kubectl config current-context >/dev/null; KUBECONFIG="$HOME/.kube/config" kubectl get nodes >/dev/null'
  phase_detail done "kubectl configured for the current SSH user on ${vm_name}."
}

# =============================================================================
# SECTION 10 — FINAL REPORT
# =============================================================================
# print_final_report IP — inside phase 12: the local access instructions and
# the saved report. The result box itself (print_final_summary) comes after
# the phase summary, so it is the last thing on the screen.
FINAL_UI_IP=""
print_final_report() {
  local external_ip="$1"
  print_local_access "$external_ip"
  [[ -n "${CONFIRMED_UI_IP:-}" ]] && external_ip="$CONFIRMED_UI_IP"
  FINAL_UI_IP="$external_ip"
  # The same report is written to REPORT_FILE so it survives the end of a
  # screen session and can be re-read later (./install.sh --report).
  {
    echo "Instana installation report — $(date '+%Y-%m-%d %H:%M')"
    echo "  Instana UI URL:  https://${UNIT_NAME}-${TENANT_NAME}.${BASE_DOMAIN}"
    echo "  Admin user:      admin@instana.local"
    echo "  External IP:     ${external_ip}"
    echo "  Backend version: ${BACKEND_VERSION:-$(get_state backend_version)}   (stanctl ${STANCTL_CLI_VERSION:-$(get_state stanctl_cli_version)})"
    echo "  Total time:      this run $(run_elapsed) (started ${RUN_STARTED_AT}); all phases together $(fmt_duration "$(phases_total_seconds)")"
    echo "  /etc/hosts entries:"
    printf '%s %s\n' "$external_ip" "$BASE_DOMAIN" \
      "$external_ip" "${UNIT_NAME}-${TENANT_NAME}.${BASE_DOMAIN}" \
      "$external_ip" "agent-acceptor.${BASE_DOMAIN}" \
      "$external_ip" "opamp-acceptor.${BASE_DOMAIN}" \
      "$external_ip" "otlp-http.${BASE_DOMAIN}" \
      "$external_ip" "otlp-grpc.${BASE_DOMAIN}"
    echo "  Kubernetes checks on the VM: sudo kubectl get nodes; sudo kubectl get pods -A"
    if [[ "$(provider_name)" == ssh ]]; then echo "  Forget this deployment (local state only; the hosts are not changed): ./install.sh --destroy"
    else echo "  Destroy: ./install.sh --destroy"; fi
  } > "$REPORT_FILE" 2>/dev/null || true
  [[ "$DRY_RUN" != true ]] || rm -f "$REPORT_FILE"
}

# print_final_summary — the result, printed once and last: after the phase
# checklist and the progress bar.
print_final_summary() {
  local external_ip="$FINAL_UI_IP"
  if [[ "$DRY_RUN" == true ]]; then
    # A simulation has no IP, no versions on a VM and no report to keep.
    echo ""
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${GREEN}  Dry-run complete — nothing was created or changed${RESET}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}Instana UI URL (after a real run):${RESET}  https://${UNIT_NAME}-${TENANT_NAME}.${BASE_DOMAIN}"
    echo -e "  ${BOLD}Total time:${RESET}      this run $(run_elapsed) (started ${RUN_STARTED_AT})"
    echo "  A real installation ends with the external IP, the /etc/hosts entries to copy and"
    echo "  the Kubernetes checks on the backend VM (sudo kubectl get nodes; sudo kubectl get pods -A)."
    echo -e "  Run it for real: ${CYAN}./install.sh${RESET}   Log of this simulation: ${LOG_FILE}"
    echo ""
    return 0
  fi
  echo ""
  echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${GREEN}  Installation Complete!${RESET}"
  echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${RESET}"
  echo ""
  echo -e "  ${BOLD}Instana UI URL:${RESET}  https://${UNIT_NAME}-${TENANT_NAME}.${BASE_DOMAIN}"
  echo -e "  ${BOLD}Admin user:${RESET}      admin@instana.local"
  echo -e "  ${BOLD}External IP:${RESET}     ${external_ip}"
  echo -e "  ${BOLD}Backend version:${RESET} ${BACKEND_VERSION:-$(get_state backend_version)}   (stanctl ${STANCTL_CLI_VERSION:-$(get_state stanctl_cli_version)})"
  echo -e "  ${BOLD}Total time:${RESET}      this run $(run_elapsed) (started ${RUN_STARTED_AT}); all phases together $(fmt_duration "$(phases_total_seconds)")"
  echo ""
  echo -e "  ${YELLOW}Ready-to-copy /etc/hosts entries:${RESET}"
  printf '%s %s\n' "$external_ip" "$BASE_DOMAIN" \
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
  if [[ "$(provider_name)" == ssh ]]; then
    echo -e "  To forget this deployment (local state only; the hosts are not changed): ${CYAN}./install.sh --destroy${RESET}"
  else
    echo -e "  To destroy all resources: ${CYAN}./install.sh --destroy${RESET}"
  fi
  echo -e "  Show this report again:   ${CYAN}./install.sh --report${RESET}   (saved in ${REPORT_FILE})"
  echo ""
  # Inside a screen session the window closes when the installer ends and the
  # report would vanish with it: hold here until the operator has read it.
  if [[ -n "${INSTANA_EXIT_MARKER:-}" && -t 0 && "$DRY_RUN" != true ]]; then
    read -rp "$(echo -e "${BOLD}Installation finished. Press Enter to close this screen session${RESET} (the report is saved and will be printed again): ")" _ || true
  fi
}

# =============================================================================
# SECTION 11 — MAIN ORCHESTRATION
# =============================================================================
main_single_node() {
  phase_start 3 "Check regional CPU quota, detect name collisions, and create the Ubuntu VM. If GCP reports a stockout, the capacity fallback may select another compatible location before any dependent resource exists."
  provider_ensure_vms
  phase_done 3 "VM is available in ${GCP_ZONE}."

  # Create and attach disks (dedicated per directory — required by documentation)
  phase_start 4 "Create separate SSD persistent disks and attach each with a stable device name. Formatting happens later, only after SSH validation."
  provider_ensure_disks
  phase_done 4 "All required data disks are attached."

  phase_start 5 "Create VPC ingress rules for SSH, public Instana endpoints, and required internal traffic. Host-level UFW is configured separately."
  provider_ensure_firewall
  phase_done 5 "GCP firewall rules are present."

  phase_start 6 "Wait until the VM accepts non-interactive SSH, verify remote administration, and verify the CPU provides x86-64-v3 (IBM minimum)."
  [[ "$DRY_RUN" != true ]] && wait_for_ssh "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  verify_cpu_x86_64_v3 "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  phase_done 6 "SSH is ready and the CPU meets the x86-64-v3 requirement."

  # Kernel parameters (verbatim from documentation)
  phase_start 7 "Apply Instana sysctl and Transparent Huge Pages settings, reboot, and verify both a new boot ID and THP=never."
  # Resume after stanctl up: the cluster is running; a recorded kernel step is
  # verified without rebooting it.
  if [[ "${RESUME_AFTER_STANCTL_UP:-false}" == true ]]; then resume_kernel "$VM_NAME"; else lab_kernel "$VM_NAME"; fi
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
  PHASE11_NOTE="Instana backend installation command completed."
  if [[ "${RESUME_AFTER_STANCTL_UP:-false}" == true ]]; then
    resume_after_stanctl_up "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" 1 ||
      run_stanctl_up_single_node "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  else
    run_stanctl_up_single_node "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  fi
  phase_done 11 "$PHASE11_NOTE"

  # Health check
  phase_start 12 "Wait for Kubernetes nodes and Instana workloads, then print exact DNS or hosts-file entries for macOS, Linux and Windows."
  post_install_health_check "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  configure_kubectl_user_access "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"

  # Get external IP
  local ext_ip=""
  if [[ "$DRY_RUN" != true ]]; then
    ext_ip=$(provider_get_ip "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" public 2>/dev/null || echo "unknown")
  fi

  print_final_report "${ext_ip:-DRY-RUN}"
  phase_done 12 "Health checks and access instructions completed."
  progress_summary
  print_final_summary
}

# =============================================================================
# ENTRY POINT
# =============================================================================
# validate_vm_name VALUE [KEY] — GCP resource name rules (also used for the disks).
validate_vm_name() {
  [[ "$1" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ ]] ||
    { err "${2:-VM name} '${1}' is invalid: use lowercase letters, digits and hyphens, start with a letter, max 63 characters, no dots."; return 1; }
}

# validate_new_vm_name VALUE [KEY] — as validate_vm_name; on Google Cloud the
# name must also be free in the chosen zone (read-only lookup; a failing
# lookup does not block, phase 3 checks again).
validate_new_vm_name() {
  validate_vm_name "$1" "${2:-VM name}" || return 1
  [[ "$(provider_name)" == gcp && -n "${GCP_ZONE:-}" && -n "${GCP_PROJECT:-}" ]] || return 0
  local errout rc=0
  errout=$(timeout 20 gcloud compute instances describe "$1" --zone="$GCP_ZONE" --project="$GCP_PROJECT" --format='value(name)' 2>&1 >/dev/null) || rc=$?
  if (( rc == 0 )); then
    err "A VM named '${1}' already exists in ${GCP_ZONE} (project ${GCP_PROJECT}); choose another name (e.g. ${1}-2), or remove the old lab first with ./install.sh → clean up."
    return 1
  fi
  # Only "not found" means free; any other answer (no permission, API off,
  # timeout) is not a verdict: say so and go on (phase 3 checks again).
  if [[ "$errout" != *"was not found"* && "$errout" != *"notFound"* ]]; then
    warn "Could not check now whether a VM named '${1}' exists in ${GCP_ZONE}: $(head -1 <<< "${errout:-no answer (exit ${rc})}" | cut -c1-160). Phase 3 checks again before anything is created."
  fi
}

# validate_node_name VALUE KEY — as validate_vm_name, and different from the
# nodes asked before it (node 1 from node 0, node 2 from nodes 0 and 1).
validate_node_name() {
  local value="$1" key="$2" other
  validate_vm_name "$value" "$key" || return 1
  for other in NODE0_NAME NODE1_NAME; do
    [[ "$other" < "$key" ]] || continue
    [[ "$(input_ctx "$other")" != "$value" ]] ||
      { err "${key} '${value}' is already used for ${other}; each node needs its own name."; return 1; }
  done
}

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
  provider_resume_state_matches ||
    die "$(provider_text_or resume_mismatch "Project, zone or VM differs from the saved state. No changes made.")"
  provider_resume_check_vm "$VM_NAME"
  wait_for_ssh "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  resume_check_existing_cluster
  warn "Partial single-node resume validated. VM and every disk will be checked individually; only missing resources will be created."
}

# Kubernetes on the VM decides how a single-node resume continues: none =
# the normal partial resume; k3s from this deployment's stanctl up = phase 11
# checks the cluster instead of running stanctl up again (RESUME_AFTER_STANCTL_UP);
# k3s although this deployment never got to stanctl up = an unknown cluster: stop.
RESUME_AFTER_STANCTL_UP=false
resume_check_existing_cluster() {
  local last=0 i
  RESUME_AFTER_STANCTL_UP=false
  instana_cluster_check "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" 1
  case "$CLUSTER_VERDICT" in
    absent) return 0 ;;
    unreachable)
      die_with_steps "Resume could not check ${VM_NAME} for an existing Kubernetes cluster: ${CLUSTER_SHORT}." \
        "*Why it blocks: whether k3s already runs there decides between installing and only checking; the installer does not guess." \
        "Check that SSH and sudo work on ${VM_NAME}:|$(provider_hint ssh "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" 'sudo -n true && echo sudo OK')" \
        "Then continue:|./install.sh --resume" ;;
  esac
  if stanctl_up_was_started; then
    RESUME_AFTER_STANCTL_UP=true
    warn "Kubernetes already exists on ${VM_NAME} (${CLUSTER_SHORT}); it comes from this deployment's stanctl up. Phase 11 checks the cluster instead of running stanctl up again."
    return 0
  fi
  for ((i=1; i<=12; i++)); do [[ "$(get_state "progress_phase_${i}")" == completed ]] && last=$i; done
  die_with_steps "Kubernetes (k3s) already exists on ${VM_NAME} (/etc/rancher/k3s/k3s.yaml), but this deployment never got to stanctl up (last completed phase in .install-state.json: ${last}/12)." \
    "*Found: ${CLUSTER_SHORT}." \
    "*Why it blocks: this cluster was not created by the installation recorded in this folder (or the state file belongs to another VM); continuing could install on top of it and destroy it. Nothing was changed on ${VM_NAME}." \
    "Look at what runs there:|$(provider_hint ssh "$VM_NAME" "$GCP_ZONE" "$GCP_PROJECT" 'sudo kubectl get nodes; sudo kubectl get pods -A | head -30')" \
    "Only if that cluster is not needed: remove it on ${VM_NAME} (deletes the cluster), then continue:|sudo /usr/local/bin/k3s-uninstall.sh" \
    "*  then: ./install.sh --resume" \
    "Otherwise install on another VM (new name or new folder):|./install.sh"
}

# True when the state file holds nothing but progress checkpoints of the
# current run (no project, topology, VMs, disks or deployment identity).
state_is_only_progress() {
  [[ -f "$STATE_FILE" ]] || return 1
  jq -e 'keys | all(startswith("progress_"))' "$STATE_FILE" >/dev/null 2>&1
}

# A new three-node deployment was requested but this folder already holds a
# state file. Only a three-node state with a deployment identity can be
# resumed; anything else (a single-node lab, an older layout, a different
# project/zone) is explained and the operator chooses what to do with it.
handle_existing_state_for_new_deployment() {
  local st_topology st_project st_zone st_vms st_id choice backup
  st_topology=$(get_state topology); st_project=$(get_state gcp_project); st_zone=$(get_state gcp_zone)
  st_id=$(get_state deployment_id)
  st_vms=$(jq -r 'to_entries[] | select(.key | startswith("vm_")) | .key | ltrimstr("vm_")' "$STATE_FILE" 2>/dev/null | paste -sd, -)
  echo "" >&2
  warn "This folder already contains .install-state.json from another deployment:"
  echo "    project/zone: ${st_project:-?}/${st_zone:-?}   topology: ${st_topology:-unknown}   VMs: ${st_vms:-none recorded}" >&2
  if [[ "$st_topology" == three-node && "$st_id" =~ ^[a-f0-9]{32}$ ]]; then
    prompt_yes_no "It is a resumable three-node deployment. Resume it with verified saved state?" Y && { RESUME=true; return 0; }
  else
    echo "    It cannot be resumed as a three-node deployment (single-node or older state without a deployment identity)." >&2
  fi
  choice=$(prompt_choice "What do you want to do with it?" \
    "delete the GCP resources of that old deployment first (VM, disks, firewall rules), then rerun" \
    "keep those resources, set the old state file aside and continue with this NEW deployment" \
    "cancel") || die "Installation cancelled by the operator. Nothing was created."
  case "$choice" in
    delete*) exec bash "${SCRIPT_DIR}/destroy.sh" ;;
    keep*)
      backup="${STATE_FILE}.$(date +%Y%m%d-%H%M%S).old"
      mv "$STATE_FILE" "$backup" || die "Could not move the old state file aside."
      ok "Old state set aside as $(basename "$backup"). Its GCP resources still exist and can be removed later with the clean-up menu option."
      ;;
    *) die "Installation cancelled by the operator. Nothing was created." ;;
  esac
}

# offer_provider_switch SAVED SAVED_SOURCE REQUESTED REQUESTED_SOURCE — a new
# deployment with another provider was requested in a folder that records one.
# Shows what the recorded deployment is, then: continue it (its own provider,
# --resume), set its files aside (renamed with a timestamp, nothing deleted)
# and start the requested one, or cancel. Sets PROVIDER_SWITCH=keep|new.
offer_provider_switch() {
  local saved="$1" saved_src="$2" requested="$3" requested_src="$4" choice ts f where vms last=0 i
  echo "" >&2
  warn "Provider '${requested}' was requested (${requested_src}), but this folder already records a deployment with provider '${saved}' (${saved_src})."
  if [[ -f "$STATE_FILE" ]]; then
    if [[ "$saved" == ssh ]]; then where="hosts $(get_state ssh_target)"; else where="project/zone $(get_state gcp_project)/$(get_state gcp_zone)"; fi
    vms=$(jq -r 'to_entries[] | select(.key|test("^(vm_|host_)")) | .key | sub("^(vm_|host_)";"")' "$STATE_FILE" 2>/dev/null | paste -sd, -)
    for ((i=1; i<=12; i++)); do [[ "$(get_state "progress_phase_${i}")" == completed ]] && last=$i; done
    echo "    recorded: ${where}   topology: $(get_state topology)   VMs/hosts: ${vms:-none recorded}   last completed phase: ${last}/12" >&2
    if [[ "$saved" == gcp && -n "$vms" ]]; then
      echo "    Its Google Cloud resources may still exist and cost money; if it is a lab you no longer need, delete them first: ./install.sh --destroy" >&2
    fi
  fi
  local -a options=()
  # Continuing means --resume, which a dry-run cannot do.
  if [[ "$DRY_RUN" == true ]]; then
    echo "    (Continuing the recorded deployment is not offered in a dry-run: it needs ./install.sh --resume.)" >&2
  else
    options+=("continue the recorded deployment with its own provider '${saved}' (resume)")
  fi
  options+=("set the recorded files aside (renamed, nothing deleted) and start a NEW '${requested}' deployment here" "cancel")
  choice=$(prompt_choice "What do you want to do?" "${options[@]}") || die "Installation cancelled; nothing was changed."
  case "$choice" in
    continue*)
      [[ -z "${INPUT_CONFIG:-}" ]] || die_with_steps "The recorded '${saved}' deployment can only be continued with the parameters it was started with; the values from ${INPUT_LABEL:-the input file} cannot change it." \
        "Continue that deployment without --config (its saved parameters are used):|unset INSTANA_PROVIDER; ./install.sh --resume" \
        "*To install the deployment from the file instead, run it again and choose 'set the recorded files aside', or use a new folder."
      [[ -f "$STATE_FILE" ]] || die_with_steps "There is no started deployment to continue in this folder (only saved parameters for provider '${saved}')." \
        "Start it with its saved parameters:|unset INSTANA_PROVIDER; ./install.sh"
      RESUME=true; PROVIDER_SWITCH=keep
      log "Continuing the recorded '${saved}' deployment (--resume)." ;;
    set*)
      local -a moved=() target n
      ts=$(date +%Y%m%d-%H%M%S)
      for f in "$STATE_FILE" "$CONFIG_FILE"; do
        [[ -f "$f" ]] || continue
        # Only the files of the recorded deployment are moved (saved parameters
        # without PROVIDER but with a GCP project are GCP parameters).
        if [[ "$f" == "$CONFIG_FILE" && "$(jq -r '.parameters.PROVIDER // (if (.parameters.GCP_PROJECT // "") != "" then "gcp" else empty end)' "$f" 2>/dev/null)" != "$saved" ]]; then continue; fi
        # Never overwrite an earlier set-aside copy (two in the same second).
        target="${f}.${ts}.old"; n=2
        while [[ -e "$target" ]]; do target="${f}.${ts}-${n}.old"; n=$((n+1)); done
        if ! mv -n "$f" "$target" || [[ -e "$f" || ! -f "$target" ]]; then
          die_with_steps "Could not set $(basename "$f") aside as $(basename "$target")." \
            "*Already moved in this step: ${moved[*]:-nothing}. $(basename "$f") is still in place; nothing was deleted." \
            "Check the folder permissions and free space:|ls -la ${SCRIPT_DIR}" \
            "*Move the remaining file by hand (any new name), then rerun:|./install.sh"
        fi
        moved+=("$(basename "$f") → $(basename "$target")")
        ok "$(basename "$f") set aside as $(basename "$target") (nothing deleted)."
      done
      [[ "$saved" != gcp ]] || warn "The Google Cloud resources of that deployment were not touched; remove them later with the clean-up menu option (by VM name) if you no longer need them."
      PROVIDER_SWITCH=new ;;
    *) log "Installation cancelled; nothing was changed."; exit 0 ;;
  esac
}

# After a dropped connection the operator simply runs ./install.sh again: if an
# installer is still running inside a screen session, offer to jump back to it.
offer_reattach_running_installer() {
  command -v screen >/dev/null 2>&1 || return 0
  local -a sessions=()
  mapfile -t sessions < <(screen -ls 2>/dev/null | sed -nE 's/^[[:space:]]+([0-9]+\.instana-[0-9]+)[[:space:]].*$/\1/p')
  (( ${#sessions[@]} > 0 )) || return 0
  echo "" >&2
  log "An installer session is still running in screen: ${sessions[*]}"
  hint "It kept running inside screen; reattaching shows its live output (nothing restarts)." \
       "Detach again at any time with Ctrl+A then D."
  local choice
  choice=$(PROMPT_CHOICE_DEFAULT="Reattach to ${sessions[0]}" prompt_choice "Reattach to it, or start something new?" \
    "Reattach to ${sessions[0]}"$'\t'"recommended after a lost connection" \
    "Start something new"$'\t'"the running one keeps working in the background") || exit 0
  case "$choice" in
    Reattach*) exec screen -d -r "${sessions[0]}" ;;
  esac
}

# A lost SSH connection kills a plain foreground installer (SIGHUP), and with
# it a running stanctl up. When started interactively outside screen/tmux the
# installer therefore offers to re-launch itself inside a screen session.
ensure_detachable_session() {
  [[ -t 0 && -t 1 ]] || return 0                  # non-interactive: nothing to protect
  [[ "$DRY_RUN" != true ]] || return 0             # a dry-run changes nothing a lost connection could break
  [[ -z "${STY:-}" && -z "${TMUX:-}" ]] || return 0   # already inside screen/tmux
  [[ "${INSTANA_NO_SCREEN:-}" != 1 ]] || return 0
  [[ "${REATTACH_OFFERED:-0}" == 1 ]] || offer_reattach_running_installer
  echo "" >&2
  warn "You are not inside a screen/tmux session."
  hint "A dropped connection would kill the installation; screen keeps it running." \
       "Why this matters: this installer runs 30-40 min for single-node online (longer for three-node and air-gapped) and drives 'stanctl up' on the Instana VM through an SSH" \
       "connection from THIS terminal. If your own connection to this machine drops (Wi-Fi, VPN, laptop sleep), Linux" \
       "closes the terminal and kills everything started from it, including stanctl up in the middle of the installation." \
       "'screen' keeps the installer running on this machine independent of your connection: you can disconnect at any" \
       "time, reconnect later, run ./install.sh again and jump straight back to the live screen where it left off."
  if ! command -v screen >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
      prompt_yes_no "Install 'screen' now (sudo apt-get install screen) so the installer can run detached?" Y &&
        sudo apt-get install -y -qq screen >/dev/null 2>&1 || true
    fi
  fi
  if command -v screen >/dev/null 2>&1; then
    local name="instana-$(date +%H%M%S)"
    if prompt_yes_no "Run the installer inside screen session '${name}' now? (reconnect later with: screen -d -r ${name})" Y; then
      log "Re-launching inside screen. Detach with Ctrl+A then D; reattach with: screen -d -r ${name}"
      # Everything shown inside screen is also logged, so if the inner installer
      # dies at once (screen then closes before anyone can read the error) the
      # last lines are printed here instead of vanishing.
      # screen flushes its log only every 10 s by default; a private screenrc
      # makes it immediate so nothing is lost when the inner script dies fast.
      local logf="${SCRIPT_DIR}/screen-${name}.log" started=$SECONDS started_epoch=$(date +%s) rc=0 rcfile
      rcfile=$(mktemp); printf 'logfile "%s"\nlogfile flush 0\ndeflog on\n' "$logf" > "$rcfile"
      # The inner installer records its own exit code in a marker file; screen
      # itself always exits 0. Diagnostics are shown only for a non-zero exit.
      local marker="${logf%.log}.exit"
      INSTANA_EXIT_MARKER="$marker" screen -c "$rcfile" -S "$name" bash -c 'exec bash "$0" "$@"' "${SCRIPT_DIR}/install.sh" "$@" || rc=$?
      rm -f "$rcfile"
      local inner_rc; inner_rc=$(cat "$marker" 2>/dev/null || echo unknown); rm -f "$marker"
      local stop_reason; stop_reason=$(screen_stop_reason "$marker")
      if [[ "$inner_rc" != 0 && -n "$stop_reason" ]]; then
        echo "" >&2
        warn "The installer inside screen session ${name} ended: ${stop_reason}. Log: ${logf}"
        ERROR_REPORTED=true
        [[ "$inner_rc" =~ ^[0-9]+$ ]] && exit "$inner_rc" || exit 1
      fi
      if [[ "$inner_rc" == 0 && -n "$stop_reason" ]]; then
        rm -f "$logf"
        echo "" >&2
        log "The installer inside screen session ${name} ended: ${stop_reason}."
        exit 0
      fi
      if [[ "$inner_rc" == 0 ]]; then
        rm -f "$logf"
        local run_log; run_log=$(ls -t "$SCRIPT_DIR"/install-*.log 2>/dev/null | head -1 || true)
        echo "" >&2
        if [[ -f "$REPORT_FILE" ]] && (( $(stat -c %Y "$REPORT_FILE" 2>/dev/null || echo 0) >= started_epoch )); then
          ok "The installer finished inside screen. Its final report (also kept in ${REPORT_FILE}):"
          sed 's/^/  /' "$REPORT_FILE" >&2
          echo "" >&2
        fi
        ok "Completed after $(fmt_duration $(( SECONDS - started ))) inside screen session ${name}."
        echo "  Report: ./install.sh --report   Log: ${run_log:-${SCRIPT_DIR}/install-*.log}" >&2
        echo "" >&2
        exit 0
      fi
      err "The installer inside screen ended after $(( SECONDS - started )) s (exit code ${inner_rc}). Its last output:"
      if [[ -s "$logf" ]]; then
        sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$logf" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -20 >&2 || true
      else
        echo "  (the screen log ${logf} is empty or missing)" >&2
      fi
      echo "  Full screen log: ${logf}" >&2
      echo "  To run without screen: INSTANA_NO_SCREEN=1 ./install.sh" >&2
      ERROR_REPORTED=true   # the inner run already printed its own error and HOW TO RESOLVE box
      [[ "$inner_rc" =~ ^[0-9]+$ ]] && exit "$inner_rc" || exit 1
    fi
  else
    warn "screen is not available; continuing in the foreground. Do not close this terminal until the installer finishes."
  fi
}

# Phase 2 checks and the plan, repeated after each "E" (change one value).
# show_plan is called as a plain command so that set -e stays active inside
# it: a failing save_state must stop the run before any resource is created
# (destroy.sh needs the recorded project, zone and provider).
PLAN_DECISION=""
run_plan_confirmation() {
  while true; do
    provider_validate_config
    if [[ "$RESUME" == true && "$TOPOLOGY" != three-node ]]; then
      validate_resume
    else
      provider_validate_image
    fi
    PLAN_DECISION=""
    show_plan
    [[ "$PLAN_DECISION" == edit ]] || return 0
    edit_parameters_before_start
    save_parameters
    validate_vm_names
    prepare_topology
  done
}

# Three-node only: an older deployment recorded in this folder is resumed or
# set aside first (an imported file can only start a NEW deployment), then the
# lab is prepared.
prepare_topology() {
  [[ "$TOPOLOGY" == three-node ]] || return 0
  # Phase 1 has just written its own progress checkpoint into the state file;
  # that is not an existing deployment. Only a state with resources/identity is.
  if [[ -f "$STATE_FILE" && "$RESUME" != true ]] && ! state_is_only_progress; then
    handle_existing_state_for_new_deployment
    if [[ "$RESUME" == true && "$PARAMS_SOURCE" == import ]]; then
      die_with_steps "The deployment recorded in this folder can only be resumed with the parameters it was started with; the values from ${INPUT_LABEL:-the input file} cannot change it." \
        "Continue that deployment without --config (its saved parameters are used):|./install.sh --resume" \
        "*To install the deployment from the file instead, run it in a new folder, or choose 'set the old state file aside' when asked."
    fi
  fi
  prepare_multinode_lab
}

main() {
  if [[ -n "${INSTANA_EXIT_MARKER:-}" ]]; then
    trap 'rc=$?; on_exit_report "$rc" "$BASH_COMMAND"; echo "$rc" > "$INSTANA_EXIT_MARKER"' EXIT
  fi
  # Wording before the provider is resolved in phase 1: the provider that was
  # requested or is recorded here (resolve_provider decides and re-applies).
  provider_word_early
  if [[ "$DESTROY" == true ]]; then
    run_destroy
  fi
  if [[ "$EXPORT_CONFIG" == true ]]; then
    # The file carries the provider recorded in this folder, never a request.
    INSTANA_PROVIDER="" resolve_provider || exit 1
    export_saved_parameters "$EXPORT_CONFIG_PATH"
    exit 0
  fi
  [[ -z "$INPUT_CONFIG" ]] || input_prepare_cli_file
  # The menu first: the screen offer only matters for a run that installs
  # (install / resume), not for a dry-run, a report or a clean-up.
  # A dropped operator lands back in the running installation first.
  if [[ -t 0 && -t 1 && -z "${STY:-}" && -z "${TMUX:-}" && "${INSTANA_NO_SCREEN:-}" != 1 ]]; then
    offer_reattach_running_installer; REATTACH_OFFERED=1
  fi
  [[ "${1:-}" != --verbose ]] || shift
  if [[ $# -eq 0 && -t 0 ]]; then
    start_menu
    case "${START_CHOICE:-}" in
      install|dry-run|resume) set -- "--start=${START_CHOICE}" ;;
    esac
  elif [[ "$DRY_RUN" == true ]]; then
    # ./install.sh --dry-run in a terminal: where would it install?
    if [[ -z "$START_CHOICE" ]] && dry_run_target_needed; then ask_dry_run_target 0; provider_word_early; fi
    warn "$(provider_text_or dry_run_banner "Dry-run mode — no GCP resources will be created.")"
  fi
  ensure_detachable_session "$@"
  echo ""
  log "Log file: ${LOG_FILE}"

  progress_init
  phase_start 1 "Verify required command-line tools, acquire the installer lock, authenticate to GCP, and collect or reuse saved non-secret parameters."
  if [[ -n "$INPUT_CONFIG" ]]; then
    input_resolve_provider
  else
    resolve_provider || exit 1
  fi
  check_local_tools
  exec 9>"${SCRIPT_DIR}/.install.lock"
  flock -n 9 || die "Another installer is running from this deployment folder."
  provider_check_auth
  choose_parameter_source
  check_stanctl_timeout
  save_parameters
  validate_vm_names
  phase_done 1 "Local prerequisites and non-secret parameters are ready."
  prepare_topology
  phase_start 2 "Validate project, region, zone, VPC, subnet and Ubuntu image, then display the complete plan before resources are changed."
  run_plan_confirmation
  offer_blank_input_secrets
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
source "${SCRIPT_DIR}/providers/common.sh"
source "${SCRIPT_DIR}/providers/gcp.sh"
source "${SCRIPT_DIR}/providers/ssh.sh"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
