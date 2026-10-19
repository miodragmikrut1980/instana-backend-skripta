#!/usr/bin/env bash
# Deployment input file: ./install.sh --config FILE, or "import them from a JSON
# file" in the parameter-source menu. Format: schema instana-installer-input,
# schema_version 1, written by config-generator.html or --export-config.
# A value from the file is used only after the same check as a typed answer.
# A missing or invalid value is asked in the terminal (with the reason shown
# first), never accepted silently. Without a terminal the run stops up front
# and lists every value that is missing or invalid. Never source JSON.

readonly INPUT_SCHEMA="instana-installer-input"
INPUT_CONFIG=""          # absolute path of the input file (--config or import screen)
INPUT_LABEL=""           # how messages name the source: file name, or "the current plan"
PARAMS_SOURCE=manual     # manual | import (an input file or an edit of the plan) | saved
QUIET_OK=false           # true while re-collecting for "edit a value": no ok line per kept value
EDIT_KEY=""              # key being changed from the plan; its old value is the prompt default
EDIT_DEFAULT=""
PLAN_EDITABLE=false      # the plan offers E (edit) and S (save to a file) only for new deployments
INPUT_HAD_SECRETS=false  # the input file itself (not the environment) carried a secret
declare -A IMPORTED=()        # KEY -> value from the input file
declare -A IMPORTED_SECRET=() # DOWNLOAD_KEY/AGENT_KEY/SALES_KEY/ADMIN_PASSWORD -> value
declare -A IMPORTED_SECRET_SRC=()
INPUT_CONFLICTS=()       # "GCP_ZONE|PROVIDER_LOCATION" pairs with different values

readonly INPUT_SECRET_KEYS="DOWNLOAD_KEY AGENT_KEY SALES_KEY ADMIN_PASSWORD"
# Keys an input file may carry besides PARAMETER_KEYS (parameters.sh).
readonly INPUT_EXTRA_KEYS="PROVIDER SIZE AIRGAP_SOURCE AIRGAP_OUTPUT_DIR STANCTL_VERSION BACKEND_VERSION"
# Derived by the installer; accepted in a file but never taken from it.
readonly INPUT_DERIVED_KEYS="MACHINE_TYPE NODE_CPUS NODE_RAM_GB"
# Keys of the existing-hosts provider (ssh), besides DISK_DEV_*.
readonly INPUT_SSH_KEYS="SSH_USER SSH_KEY_PATH SSH_PORT SSH_VIA_PRIVATE VM_HOST NODE0_HOST NODE1_HOST NODE2_HOST NETWORK_RULES_CONFIRMED"
# Keys only the gcp provider uses (ignored, with the reason, for ssh).
readonly INPUT_GCP_ONLY_KEYS="UBUNTU_VERSION GCP_PROJECT GCP_REGION GCP_ZONE GCP_NETWORK GCP_SUBNET SSH_SOURCE_CIDR SIZE VM_CPUS VM_RAM_GB"

# ── small helpers ────────────────────────────────────────────────────────────
input_expand_path() {
  local p="$1"
  [[ "$p" == "~" ]] && p="$HOME"
  [[ "$p" == "~/"* ]] && p="${HOME}/${p#\~/}"
  printf '%s' "$p"
}

# Removes colours and the [ERROR]/[WARN] prefix from captured validator output.
input_reason() {
  local r
  r=$(sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^\[ERROR\] *//' -e 's/^\[WARN\] *//' -e 's/^\[OK\] *//' | paste -sd' ' -)
  r="${r%% }"
  [[ "$r" == *. ]] || r="${r}."
  printf '%s' "$r"
}

# Value of KEY for cross-checks: the shell variable once it is set in this
# run, otherwise the value from the input file.
input_ctx() {
  local v="${!1:-}"
  [[ -n "$v" ]] || v="${IMPORTED[$1]:-}"
  printf '%s' "$v"
}

input_one_of() {
  local key="$1" value="$2" opt; shift 2
  for opt in "$@"; do [[ "$value" == "$opt" ]] && return 0; done
  local list; list=$(printf "'%s', " "$@"); list="${list%, }"
  err "${key} '${value}' is not one of: ${list}."
  return 1
}

input_example() {
  case "$1" in
    TOPOLOGY) echo '"single-node" or "three-node"' ;;
    INSTALL_MODE) echo '"online" or "air-gapped"' ;;
    INSTALL_TYPE) echo '"demo" or "production"' ;;
    UBUNTU_VERSION) echo '"ubuntu-2404-lts-amd64" or "ubuntu-2204-lts"' ;;
    GCP_PROJECT|PROVIDER_SCOPE) echo '"instana-support-test-account"' ;;
    GCP_REGION|PROVIDER_REGION) echo '"europe-west6"' ;;
    GCP_ZONE|PROVIDER_LOCATION) echo '"europe-west6-b"' ;;
    GCP_NETWORK|GCP_SUBNET|PROVIDER_NETWORK|PROVIDER_SUBNET) echo '"default"' ;;
    SSH_SOURCE_CIDR) echo '"auto" (this machine'"'"'s public IP) or "203.0.113.10/32"' ;;
    VM_NAME) echo '"mikrut-lab"' ;;
    NODE0_NAME|NODE1_NAME|NODE2_NAME) echo "\"mikrut-node-${1:4:1}\"" ;;
    SIZE) echo '"minimum", "production" or "custom"' ;;
    VM_CPUS) echo '"32"' ;;
    VM_RAM_GB) echo '"128"' ;;
    BASE_DOMAIN) echo '"instana.lab.example.com"' ;;
    TENANT_NAME) echo '"tenant0"' ;;
    UNIT_NAME) echo '"unit0"' ;;
    TLS_MODE) echo '"auto-generate (self-signed)" or "provide custom certificate files"' ;;
    TLS_CRT_PATH) echo '"/home/<user>/certs/instana.crt"' ;;
    TLS_KEY_PATH) echo '"/home/<user>/certs/instana.key"' ;;
    VM_HOST|NODE0_HOST|NODE1_HOST|NODE2_HOST) echo '"10.0.0.5" or "instana-0.example.com"' ;;
    SSH_USER) echo '"ubuntu"' ;;
    SSH_KEY_PATH) echo '"~/.ssh/id_ed25519"' ;;
    SSH_PORT) echo '"22"' ;;
    SSH_VIA_PRIVATE|NETWORK_RULES_CONFIRMED) echo '"true" or "false"' ;;
    DISK_DEV_*) echo '"/dev/disk/by-id/scsi-0Google_PersistentDisk_data" (see: ls -l /dev/disk/by-id on the host)' ;;
    AIRGAP_SOURCE) echo '"existing" or "build"' ;;
    AIRGAP_ARCHIVE) echo '"/home/<user>/instana-airgap/instana-airgapped.tar.gz"' ;;
    AIRGAP_OUTPUT_DIR) echo '"/home/<user>/instana-airgap"' ;;
    STANCTL_VERSION) echo 'a stanctl package version from "apt-cache madison stanctl", or leave it empty to choose from the list' ;;
    BACKEND_VERSION) echo '"3.323.470-0", or leave it empty to choose from the list' ;;
    DOWNLOAD_KEY|AGENT_KEY|SALES_KEY) echo "the key from your IBM/Instana entitlement" ;;
    ADMIN_PASSWORD) echo "any password without line breaks" ;;
    *) echo "see config-generator.html" ;;
  esac
}

# What a value is needed for, in plain words (fail-fast list and summary).
input_purpose() {
  case "$1" in
    TOPOLOGY) echo "how many VMs are created" ;;
    INSTALL_MODE) echo "where Instana is downloaded from" ;;
    INSTALL_TYPE) echo "disk sizes and minimum machine size" ;;
    UBUNTU_VERSION) echo "the operating system image of the VMs" ;;
    GCP_PROJECT) echo "the project that owns and pays for the VMs" ;;
    GCP_REGION|GCP_ZONE) echo "where the VMs are created" ;;
    GCP_NETWORK|GCP_SUBNET) echo "the network the VMs attach to" ;;
    SSH_SOURCE_CIDR) echo "who may open SSH to the VMs (firewall rule)" ;;
    VM_NAME|NODE0_NAME|NODE1_NAME|NODE2_NAME) [[ "$(provider_name)" == ssh ]] && echo "the host's name inside the installer" || echo "the VM name in Google Cloud" ;;
    VM_HOST|NODE0_HOST|NODE1_HOST|NODE2_HOST) echo "the existing host to install on" ;;
    SSH_USER|SSH_KEY_PATH|SSH_PORT) echo "logging in to the host(s) over SSH" ;;
    SSH_VIA_PRIVATE) echo "whether the host addresses are private" ;;
    NETWORK_RULES_CONFIRMED) echo "confirming the network rules around the hosts" ;;
    DISK_DEV_*) echo "the dedicated data disk for one Instana data directory" ;;
    SIZE|VM_CPUS|VM_RAM_GB) echo "the machine size" ;;
    BASE_DOMAIN) echo "the address Instana is reached at" ;;
    TENANT_NAME|UNIT_NAME) echo "the UI address <unit>-<tenant>.<domain>" ;;
    TLS_MODE|TLS_CRT_PATH|TLS_KEY_PATH) echo "the HTTPS certificate" ;;
    AIRGAP_SOURCE|AIRGAP_ARCHIVE|AIRGAP_OUTPUT_DIR) echo "the air-gapped package" ;;
    STANCTL_VERSION|BACKEND_VERSION) echo "the exact Instana version to install" ;;
    DOWNLOAD_KEY) echo "access to the Instana software repository" ;;
    AGENT_KEY) echo "letting agents connect" ;;
    SALES_KEY) echo "the Instana license" ;;
    ADMIN_PASSWORD) echo "the first UI login (admin@instana.local)" ;;
    *) echo "the installation" ;;
  esac
}

# Closest known key to a misspelled one (edit distance up to 3), or nothing.
input_suggest_key() {
  local unknown="$1"; shift
  printf '%s\n' "$@" | awk -v u="$unknown" '
    function lev(a, b,   i, j, la, lb, d, c) {
      la = length(a); lb = length(b)
      for (i = 0; i <= la; i++) d[i, 0] = i
      for (j = 0; j <= lb; j++) d[0, j] = j
      for (i = 1; i <= la; i++) for (j = 1; j <= lb; j++) {
        c = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
        d[i, j] = d[i-1, j] + 1
        if (d[i, j-1] + 1 < d[i, j]) d[i, j] = d[i, j-1] + 1
        if (d[i-1, j-1] + c < d[i, j]) d[i, j] = d[i-1, j-1] + c
      }
      return d[la, lb]
    }
    { x = lev(u, $0); if (best == "" || x < bd) { bd = x; best = $0 } }
    END { if (best != "" && bd <= 3) print best }'
}

# ── checking one value ───────────────────────────────────────────────────────
# input_check KEY VALUE — the check a typed answer gets; prints the reason via
# err and returns 1 when the value cannot be used.
input_check() {
  local key="$1" v="$2" min_cpu=16 min_ram=64 region
  case "$key" in
    TOPOLOGY) input_one_of "$key" "$v" single-node three-node ;;
    INSTALL_MODE) input_one_of "$key" "$v" online air-gapped ;;
    INSTALL_TYPE) input_one_of "$key" "$v" demo production ;;
    UBUNTU_VERSION) input_one_of "$key" "$v" ubuntu-2404-lts-amd64 ubuntu-2204-lts ;;
    SIZE) input_one_of "$key" "$v" minimum production custom ;;
    AIRGAP_SOURCE) input_one_of "$key" "$v" existing build ;;
    TLS_MODE) input_one_of "$key" "$v" "auto-generate (self-signed)" "provide custom certificate files" auto custom ;;
    GCP_PROJECT|GCP_REGION|GCP_NETWORK|GCP_SUBNET) provider_validate_param "$key" "$v" ;;
    GCP_ZONE)
      provider_validate_param "$key" "$v" || return 1
      region=$(input_ctx GCP_REGION)
      [[ -z "$region" || "$v" == "${region}-"? ]] ||
        { err "GCP_ZONE '${v}' is not in GCP_REGION '${region}' (a zone is its region plus -a, -b or -c, e.g. ${region}-b)."; return 1; } ;;
    SSH_SOURCE_CIDR) [[ "$v" == auto ]] || validate_cidr "$v" ;;
    VM_NAME) validate_vm_name "$v" "$key" ;;
    NODE0_NAME|NODE1_NAME|NODE2_NAME) validate_node_name "$v" "$key" ;;
    VM_CPUS|VM_RAM_GB)
      [[ "$(input_ctx INSTALL_TYPE)" == production ]] && { min_cpu=28; min_ram=112; }
      [[ "$v" =~ ^[0-9]{1,9}$ ]] || { err "${key} '${v}' must be a whole number, e.g. $(input_example "$key")."; return 1; }
      if [[ "$key" == VM_CPUS ]] && (( 10#$v < min_cpu )); then
        err "VM_CPUS ${v} is below the minimum of ${min_cpu} vCPUs for a $(input_ctx INSTALL_TYPE) single-node installation."; return 1
      fi
      if [[ "$key" == VM_RAM_GB ]] && (( 10#$v < min_ram )); then
        err "VM_RAM_GB ${v} is below the minimum of ${min_ram} GB for a $(input_ctx INSTALL_TYPE) single-node installation."; return 1
      fi ;;
    BASE_DOMAIN) validate_fqdn "$v" ;;
    TENANT_NAME) validate_tenant_unit_name "$v" "Tenant name" ;;
    UNIT_NAME) validate_tenant_unit_name "$v" "Unit name" ;;
    TLS_CRT_PATH) validate_file_exists "$(input_expand_path "$v")" "TLS certificate file (TLS_CRT_PATH)" ;;
    TLS_KEY_PATH) validate_file_exists "$(input_expand_path "$v")" "TLS key file (TLS_KEY_PATH)" ;;
    AIRGAP_ARCHIVE) validate_file_exists "$(input_expand_path "$v")" "Air-gapped package (AIRGAP_ARCHIVE)" ;;
    AIRGAP_OUTPUT_DIR)
      [[ "$v" == /* || "$v" == "~"* ]] ||
        { err "AIRGAP_OUTPUT_DIR '${v}' must be an absolute path (starting with / or ~/)."; return 1; } ;;
    STANCTL_VERSION|BACKEND_VERSION)
      [[ "$v" =~ ^[0-9][0-9A-Za-z.+~:_-]*$ ]] ||
        { err "${key} '${v}' does not look like a version number, e.g. 3.323.470-0."; return 1; } ;;
    VM_HOST|NODE0_HOST|NODE1_HOST|NODE2_HOST|SSH_USER|SSH_KEY_PATH|SSH_PORT|SSH_VIA_PRIVATE|NETWORK_RULES_CONFIRMED|DISK_DEV_*)
      provider_validate_param "$key" "$v" ;;
    DOWNLOAD_KEY) validate_secret "$v" "Download key" ;;
    AGENT_KEY) validate_secret "$v" "Agent key" ;;
    SALES_KEY) validate_secret "$v" "Sales key" ;;
    ADMIN_PASSWORD) validate_secret "$v" "Admin password" ;;
    *) err "Unknown key ${key}."; return 1 ;;
  esac
}

# The form a valid value is stored in (paths expanded, short TLS names, auto CIDR).
input_normalize() {
  local key="$1" v="$2"
  case "$key" in
    TLS_MODE)
      case "$v" in
        auto) v="auto-generate (self-signed)" ;;
        custom) v="provide custom certificate files" ;;
      esac ;;
    TLS_CRT_PATH|TLS_KEY_PATH|AIRGAP_ARCHIVE|AIRGAP_OUTPUT_DIR|SSH_KEY_PATH) v=$(input_expand_path "$v") ;;
    SSH_SOURCE_CIDR) [[ "$v" == auto ]] && v=$(detect_public_cidr) ;;
  esac
  printf '%s' "$v"
}

input_source_label() { printf '%s' "${INPUT_LABEL:-the input file}"; }

# use_imported KEY — when this run takes values from an input file (or from
# the plan being edited) and KEY has a usable value there, sets the variable
# and returns 0: the question is skipped. Otherwise returns 1 and the caller
# asks as usual; an unusable value is explained first (the check's own
# [ERROR] line, then what to do).
use_imported() {
  local key="$1" value
  [[ "$PARAMS_SOURCE" == import && "$key" != "$EDIT_KEY" ]] || return 1
  value="${IMPORTED[$key]:-}"
  [[ -n "$value" ]] || return 1
  if input_check "$key" "$value"; then
    printf -v "$key" '%s' "$(input_normalize "$key" "$value")"
    [[ "$QUIET_OK" == true ]] || ok "${key} = ${!key} (from $(input_source_label))"
    return 0
  fi
  warn "${key} from $(input_source_label) cannot be used (reason above); please enter it now. Valid example: $(input_example "$key")."
  IMPORTED[$key]=""
  return 1
}

# imported_usable KEY... — true when every KEY will be taken from the input
# file without a question (decides whether the explanation before a group of
# questions is needed). Prints nothing.
imported_usable() {
  local key
  [[ "$PARAMS_SOURCE" == import ]] || return 1
  for key in "$@"; do
    [[ "$key" != "$EDIT_KEY" && -n "${IMPORTED[$key]:-}" ]] || return 1
    input_check "$key" "${IMPORTED[$key]}" >/dev/null 2>&1 || return 1
  done
}

imported_usable_secret() {
  local key
  [[ "$PARAMS_SOURCE" == import ]] || return 1
  for key in "$@"; do
    [[ "$key" != "$EDIT_KEY" && -n "${IMPORTED_SECRET[$key]:-}" ]] || return 1
    input_check "$key" "${IMPORTED_SECRET[$key]}" >/dev/null 2>&1 || return 1
  done
}

# use_imported_secret KEY — like use_imported for the keys and the admin
# password (environment INSTANA_<KEY> first, then the file). Never prints a value.
use_imported_secret() {
  local key="$1" value src
  [[ "$PARAMS_SOURCE" == import && "$key" != "$EDIT_KEY" ]] || return 1
  value="${IMPORTED_SECRET[$key]:-}"
  [[ -n "$value" ]] || return 1
  src="${IMPORTED_SECRET_SRC[$key]:-$(input_source_label)}"
  if input_check "$key" "$value"; then
    printf -v "$key" '%s' "$value"
    [[ "$QUIET_OK" == true ]] || ok "${key} taken from ${src} (hidden)"
    return 0
  fi
  warn "${key} from ${src} cannot be used (reason above); please type it now (hidden input)."
  IMPORTED_SECRET[$key]=""
  return 1
}

# pick_from_list KEY PROMPT OPTION... — prints the chosen option. A value for
# KEY from the input file is taken when the list offers it; otherwise the
# operator chooses. Messages go to stderr (the result is captured).
pick_from_list() {
  local key="$1" prompt_text="$2" want opt; shift 2
  if [[ "$PARAMS_SOURCE" == import && "$key" != "$EDIT_KEY" ]]; then
    want="${IMPORTED[$key]:-}"
    if [[ -n "$want" ]]; then
      for opt in "$@"; do
        if [[ "$opt" == "$want" ]]; then
          [[ "$QUIET_OK" == true ]] || ok "${key} = ${want} (from $(input_source_label))" >&2
          printf '%s\n' "$want"; return 0
        fi
      done
      warn "${key} ${want} from $(input_source_label) is not offered by the Instana repository (newest offered: $1). Choose one of the offered versions below." >&2
      IMPORTED[$key]=""
    fi
  fi
  prompt_choice "$prompt_text" "$@"
}

# ── reading the file ─────────────────────────────────────────────────────────
# validate_input_file PATH [LABEL] — same contract as the prompt_required
# validators: 0, or 1 with the reason (and the way to fix it) printed.
validate_input_file() {
  local f; f=$(input_expand_path "$1")
  local made_by="Create it with config-generator.html (in the installer folder) or with ./install.sh --export-config."
  if [[ ! -e "$f" ]]; then err "Input file not found: ${f}. Check the path (absolute, or relative to $(pwd)). ${made_by}"; return 1; fi
  if [[ -L "$f" ]]; then err "Input file ${f} is a symbolic link; refused for safety. Use the real file path."; return 1; fi
  if [[ ! -f "$f" ]]; then err "Input file ${f} is not a regular file."; return 1; fi
  if [[ ! -O "$f" ]]; then err "Input file ${f} belongs to another user; refused because it may contain keys. Copy it and take ownership: cp ${f} ~/instana-config.json"; return 1; fi
  if [[ ! -r "$f" ]]; then err "Input file ${f} is not readable."; return 1; fi
  local jq_msg
  if ! jq_msg=$(jq -e . "$f" 2>&1 >/dev/null); then
    err "Input file ${f} is not valid JSON (${jq_msg:-empty file}). Open it in config-generator.html ('Open a file…') or create it again there."
    return 1
  fi
  local schema version
  schema=$(jq -r 'if type=="object" then (.schema // "") else "" end' "$f")
  version=$(jq -r 'if type=="object" then (.schema_version // "" | tostring) else "" end' "$f")
  if [[ "$schema" != "$INPUT_SCHEMA" ]]; then
    err "Input file ${f} is not an installer input file: \"schema\" is '${schema:-missing}', expected '${INPUT_SCHEMA}'. ${made_by}"
    return 1
  fi
  if [[ "$version" != 1 ]]; then
    err "Input file ${f} has schema_version '${version:-missing}'; this installer reads schema_version 1. Create the file again with the config-generator.html from this installer folder."
    return 1
  fi
  if ! jq -e '(.parameters|type)=="object"' "$f" >/dev/null; then
    err "Input file ${f} has no \"parameters\" object. ${made_by}"; return 1
  fi
  local bad
  bad=$(jq -r '[.parameters, (.secrets // {})] | map(to_entries[] | select(.value|type != "string") | .key) | join(", ")' "$f" 2>/dev/null || echo "?")
  if [[ -n "$bad" ]]; then
    err "Input file ${f}: every value must be text in quotes, e.g. \"VM_CPUS\": \"32\". Not text: ${bad}."
    return 1
  fi
  if ! jq -e '(.secrets // {}) | type=="object"' "$f" >/dev/null; then
    err "Input file ${f}: \"secrets\" must be an object like {\"DOWNLOAD_KEY\": \"\", ...}."; return 1
  fi
}

# load_input_file PATH — fills IMPORTED / IMPORTED_SECRET (file must be valid).
load_input_file() {
  local f="$1" key value mode
  IMPORTED=(); IMPORTED_SECRET=(); IMPORTED_SECRET_SRC=(); INPUT_HAD_SECRETS=false
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    IMPORTED[$key]="$value"
  done < <(jq -j '.parameters | to_entries[] | .key, "\u0000", .value, "\u0000"' "$f")
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    case " $INPUT_SECRET_KEYS " in
      *" $key "*) ;;
      *) warn "Unknown key \"secrets\".\"${key}\" in $(input_source_label) is ignored (secrets are: ${INPUT_SECRET_KEYS// /, })."; continue ;;
    esac
    [[ -n "$value" ]] || continue
    IMPORTED_SECRET[$key]="$value"; IMPORTED_SECRET_SRC[$key]="$(input_source_label)"; INPUT_HAD_SECRETS=true
  done < <(jq -j '(.secrets // {}) | to_entries[] | .key, "\u0000", .value, "\u0000"' "$f")
  for key in $INPUT_SECRET_KEYS; do
    local env_name="INSTANA_${key}"
    if [[ -n "${!env_name:-}" ]]; then
      IMPORTED_SECRET[$key]="${!env_name}"; IMPORTED_SECRET_SRC[$key]="the environment variable ${env_name}"
    fi
  done
  if [[ "$INPUT_HAD_SECRETS" == true ]]; then
    mode=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null || echo "")
    if [[ -n "$mode" && "$mode" != 600 && "$mode" != 400 ]]; then
      warn "$(input_source_label) contains keys but other users could read it (permissions ${mode}); setting it to 600 (owner only)."
      chmod 600 "$f"
    fi
  fi
}

# The provider named in the file must be the provider of this run.
input_check_provider() {
  local fp="${IMPORTED[PROVIDER]:-}"
  [[ -n "$fp" ]] || return 0
  input_refuse_unsupported_provider "$fp" "$(input_source_label)"
  if [[ "$fp" != "$(provider_name)" ]]; then
    die_with_steps "PROVIDER '${fp}' in $(input_source_label) differs from the provider of this run ('$(provider_name)'); the installer does not switch providers." \
      "Set \"PROVIDER\": \"$(provider_name)\" in the file, or remove the PROVIDER line, then import it again." \
      "*A deployment with another provider belongs in its own folder."
  fi
}

# Every provider named in a file is supported now; an unknown name is refused
# by resolve_provider with its source.
input_refuse_unsupported_provider() { :; }

# GCP_* are the names the installer uses; PROVIDER_* in a file are aliases.
# Same value or one side empty: merged. Different values: the operator picks
# (in a terminal) or the run stops listing the conflict (no terminal).
input_resolve_aliases() {
  local pair neutral gcp nv gv choice
  INPUT_CONFLICTS=()
  if [[ "$(provider_name)" != gcp ]]; then
    for pair in SCOPE REGION LOCATION NETWORK SUBNET; do
      [[ -z "${IMPORTED[PROVIDER_$pair]:-}" ]] || log "PROVIDER_${pair} ignored: it names a cloud location, which PROVIDER '$(provider_name)' does not use."
      unset "IMPORTED[PROVIDER_$pair]"
    done
    return 0
  fi
  for pair in SCOPE:PROJECT REGION:REGION LOCATION:ZONE NETWORK:NETWORK SUBNET:SUBNET; do
    neutral="PROVIDER_${pair%%:*}" gcp="GCP_${pair##*:}"
    nv="${IMPORTED[$neutral]:-}" gv="${IMPORTED[$gcp]:-}"
    unset 'IMPORTED[$neutral]'
    [[ -n "$nv" ]] || continue
    if [[ -z "$gv" || "$gv" == "$nv" ]]; then
      IMPORTED[$gcp]="$nv"
      continue
    fi
    if [[ ! -t 0 && -n "${INPUT_NONINTERACTIVE:-}" ]]; then
      INPUT_CONFLICTS+=("${gcp}|${neutral}|${gv}|${nv}")
      continue
    fi
    warn "$(input_source_label) gives two different values for the same setting: ${gcp}='${gv}' and ${neutral}='${nv}' (${neutral} is another name for ${gcp})."
    choice=$(prompt_choice "Which value should be used for ${gcp}?" \
      "${gv} (from ${gcp})" "${nv} (from ${neutral})" "neither: let me type the value") ||
      die_with_steps "Input ended while choosing between ${gcp}='${gv}' and ${neutral}='${nv}' from $(input_source_label); the installation was not started and nothing was created." \
        "Keep only one of the two names in the file (they are the same setting): delete the ${neutral} line or the ${gcp} line." \
        "Then run again; without the conflict nothing is asked for it:|./install.sh --config ${INPUT_CONFIG:-<file>}"
    case "$choice" in
      "neither"*) IMPORTED[$gcp]="" ;;
      *) IMPORTED[$gcp]="${choice% (from *}" ;;
    esac
  done
  # Only a zone given: its region follows from it.
  if [[ -z "${IMPORTED[GCP_REGION]:-}" && "${IMPORTED[GCP_ZONE]:-}" =~ ^([a-z]+-[a-z]+[0-9]+)-[a-z]$ ]]; then
    IMPORTED[GCP_REGION]="${BASH_REMATCH[1]}"
    log "GCP_REGION = ${IMPORTED[GCP_REGION]} (derived from GCP_ZONE ${IMPORTED[GCP_ZONE]})"
  fi
}

# Unknown keys are ignored with a hint (typo → closest known key); keys of
# another provider or derived values are ignored with the reason.
input_drop_unknown_keys() {
  local key suggestion
  local -a known=("${PARAMETER_KEYS[@]}")
  read -r -a _extra <<< "$INPUT_EXTRA_KEYS $PROVIDER_COMMON_KEYS $(provider_param_keys)"
  known+=("${_extra[@]}")
  for key in "${!IMPORTED[@]}"; do
    if [[ "$(provider_name)" == ssh && " $INPUT_GCP_ONLY_KEYS " == *" $key "* ]]; then
      [[ -z "${IMPORTED[$key]}" ]] || log "${key} ignored: used only with PROVIDER 'gcp' (new VMs in Google Cloud), not with existing hosts."
      unset 'IMPORTED[$key]'; continue
    fi
    case " ${known[*]} " in *" $key "*) continue ;; esac
    if [[ " $INPUT_SSH_KEYS " == *" $key "* || "$key" == DISK_DEV_* ]]; then
      [[ -z "${IMPORTED[$key]}" ]] || log "${key} ignored: used only with PROVIDER 'ssh' (existing hosts), not with '$(provider_name)'."
      unset 'IMPORTED[$key]'; continue
    fi
    suggestion=$(input_suggest_key "$key" "${known[@]}")
    if [[ -n "$suggestion" ]]; then
      warn "Unknown key ${key} in $(input_source_label) is ignored. Did you mean ${suggestion}? Correct the name in the file so it is used next time."
    else
      warn "Unknown key ${key} in $(input_source_label) is ignored (not an installer setting; see config-generator.html for the valid names)."
    fi
    unset 'IMPORTED[$key]'
  done
  for key in $INPUT_DERIVED_KEYS; do
    if [[ -n "${IMPORTED[$key]:-}" ]]; then
      log "${key} in $(input_source_label) is ignored: the installer derives it from the topology and machine size."
    fi
    unset 'IMPORTED[$key]'
  done
}

# Keys this deployment needs, in question order, decided from the file's own
# (valid) answers. Where a deciding value is missing or invalid, the keys that
# depend on it are listed only when the file has them.
input_applicable_keys() {
  local topo mode tls size src
  topo=$(input_valid_or_empty TOPOLOGY); mode=$(input_valid_or_empty INSTALL_MODE)
  tls=$(input_normalize TLS_MODE "$(input_valid_or_empty TLS_MODE)"); size=$(input_valid_or_empty SIZE)
  src=$(input_valid_or_empty AIRGAP_SOURCE)
  [[ -z "$src" && -n "${IMPORTED[AIRGAP_ARCHIVE]:-}" ]] && src=existing
  local -a keys=(TOPOLOGY INSTALL_MODE)
  if [[ "$topo" == single-node ]] || [[ -z "$topo" && -n "${IMPORTED[INSTALL_TYPE]:-}" ]]; then keys+=(INSTALL_TYPE); fi
  if [[ "$(provider_name)" == ssh ]]; then
    local -a ssh_keys; mapfile -t ssh_keys < <(input_ssh_applicable_keys "$topo")
    keys+=("${ssh_keys[@]}")
  else
    keys+=(UBUNTU_VERSION GCP_PROJECT GCP_REGION GCP_ZONE GCP_NETWORK GCP_SUBNET SSH_SOURCE_CIDR)
    if [[ "$topo" == single-node ]]; then keys+=(VM_NAME SIZE)
    elif [[ "$topo" == three-node ]]; then keys+=(NODE0_NAME NODE1_NAME NODE2_NAME)
    else
      local k; for k in VM_NAME NODE0_NAME NODE1_NAME NODE2_NAME SIZE; do [[ -z "${IMPORTED[$k]:-}" ]] || keys+=("$k"); done
    fi
    if [[ "$topo" != three-node && "$size" == custom ]]; then keys+=(VM_CPUS VM_RAM_GB); fi
  fi
  keys+=(BASE_DOMAIN TENANT_NAME UNIT_NAME ADMIN_PASSWORD DOWNLOAD_KEY AGENT_KEY SALES_KEY)
  if [[ "$mode" == air-gapped ]]; then
    keys+=(AIRGAP_SOURCE)
    if [[ "$src" == build ]]; then keys+=(AIRGAP_OUTPUT_DIR STANCTL_VERSION BACKEND_VERSION)
    else keys+=(AIRGAP_ARCHIVE); fi
  elif [[ "$mode" == online ]]; then keys+=(STANCTL_VERSION BACKEND_VERSION)
  else
    local k; for k in AIRGAP_SOURCE AIRGAP_ARCHIVE AIRGAP_OUTPUT_DIR STANCTL_VERSION BACKEND_VERSION; do [[ -z "${IMPORTED[$k]:-}" ]] || keys+=("$k"); done
  fi
  keys+=(TLS_MODE)
  if [[ "$tls" == "provide custom certificate files" ]]; then keys+=(TLS_CRT_PATH TLS_KEY_PATH)
  elif [[ -z "$tls" ]]; then
    local k; for k in TLS_CRT_PATH TLS_KEY_PATH; do [[ -z "${IMPORTED[$k]:-}" ]] || keys+=("$k"); done
  fi
  printf '%s\n' "${keys[@]}"
}

# Existing hosts (ssh): hosts, login, names and one disk per data directory.
input_ssh_applicable_keys() {
  local topo="$1" k
  if [[ "$topo" == three-node ]]; then
    printf '%s\n' NODE0_HOST NODE1_HOST NODE2_HOST SSH_USER SSH_KEY_PATH SSH_PORT SSH_VIA_PRIVATE NODE0_NAME NODE1_NAME NODE2_NAME \
      DISK_DEV_NODE0_OBJECTS DISK_DEV_NODE1_DATA DISK_DEV_NODE1_METRICS DISK_DEV_NODE1_ANALYTICS
  elif [[ "$topo" == single-node ]]; then
    printf '%s\n' VM_HOST SSH_USER SSH_KEY_PATH SSH_PORT VM_NAME DISK_DEV_ANALYTICS DISK_DEV_METRICS DISK_DEV_OBJECTS DISK_DEV_DATA
  else
    for k in VM_HOST NODE0_HOST NODE1_HOST NODE2_HOST SSH_USER SSH_KEY_PATH SSH_PORT SSH_VIA_PRIVATE VM_NAME NODE0_NAME NODE1_NAME NODE2_NAME; do
      [[ -z "${IMPORTED[$k]:-}" ]] || echo "$k"
    done
  fi
  [[ -z "${IMPORTED[NETWORK_RULES_CONFIRMED]:-}" ]] || echo NETWORK_RULES_CONFIRMED
}

input_valid_or_empty() {
  local v="${IMPORTED[$1]:-}"
  [[ -n "$v" ]] && input_check "$1" "$v" >/dev/null 2>&1 && printf '%s' "$v"
  return 0
}

# Evaluates every key once before any question: fills INPUT_ROWS with
# "status|key|text" (status ok, ask or skip) and INPUT_PROBLEMS with the
# lines a run without a terminal must stop on.
INPUT_ROWS=(); INPUT_PROBLEMS=()
input_evaluate() {
  local key value reason status text interactive=true
  [[ -t 0 ]] || interactive=false
  INPUT_ROWS=(); INPUT_PROBLEMS=()
  local -a applicable; mapfile -t applicable < <(input_applicable_keys)
  for key in "${applicable[@]}"; do
    if [[ " $INPUT_SECRET_KEYS " == *" $key "* ]]; then
      value="${IMPORTED_SECRET[$key]:-}"
      if [[ -z "$value" ]]; then
        status=ask; text="not in the file; asked in the terminal (hidden input)"
        INPUT_PROBLEMS+=("${key}: missing (\"secrets\".\"${key}\" is empty and INSTANA_${key} is not set). Needed for: $(input_purpose "$key"). Put $(input_example "$key") there, or export INSTANA_${key}=... before running.")
      elif reason=$(input_check "$key" "$value" 2>&1); then
        status=ok; text="•••• (hidden, from ${IMPORTED_SECRET_SRC[$key]})"
      else
        reason=$(input_reason <<< "$reason")
        status=ask; text="cannot be used: ${reason}"
        INPUT_PROBLEMS+=("${key}: ${reason} Needed for: $(input_purpose "$key"). Use $(input_example "$key").")
      fi
      INPUT_ROWS+=("${status}|${key}|${text}")
      continue
    fi
    value="${IMPORTED[$key]:-}"
    if [[ -z "$value" && "$(provider_name)" == ssh && "$key" =~ ^(VM_NAME|NODE[012]_NAME)$ ]]; then
      INPUT_ROWS+=("ok|${key}|not in the file; the host's own name is used")
      continue
    fi
    if [[ -z "$value" && ( "$key" == UBUNTU_VERSION || "$key" == SIZE ) ]]; then
      INPUT_ROWS+=("ok|${key}|not in the file; default $([[ "$key" == SIZE ]] && echo minimum || echo ubuntu-2404-lts-amd64) (E at the plan changes it)")
      continue
    fi
    if [[ -z "$value" ]]; then
      if [[ "$key" == STANCTL_VERSION || "$key" == BACKEND_VERSION ]]; then
        text="not in the file; chosen from the live list"
        [[ "$DRY_RUN" == true ]] && text="not in the file (dry-run uses a placeholder)"
      else
        text="not in the file; asked below"
      fi
      INPUT_ROWS+=("ask|${key}|${text}")
      if [[ "$DRY_RUN" != true || ( "$key" != STANCTL_VERSION && "$key" != BACKEND_VERSION ) ]]; then
        INPUT_PROBLEMS+=("${key}: missing. Needed for: $(input_purpose "$key"). Example: \"${key}\": $(input_example "$key").")
      fi
    elif reason=$(input_check "$key" "$value" 2>&1); then
      INPUT_ROWS+=("ok|${key}|${value}")
    else
      reason=$(input_reason <<< "$reason")
      INPUT_ROWS+=("ask|${key}|'${value}' cannot be used: ${reason}")
      INPUT_PROBLEMS+=("${key}: '${value}' cannot be used: ${reason} Needed for: $(input_purpose "$key"). Example: \"${key}\": $(input_example "$key").")
    fi
  done
  # Present but not needed for this deployment.
  local topo; topo=$(input_valid_or_empty TOPOLOGY)
  for key in "${!IMPORTED[@]}"; do
    [[ -n "${IMPORTED[$key]}" && "$key" != PROVIDER ]] || continue
    [[ " ${applicable[*]} " == *" $key "* ]] && continue
    if [[ "$topo" == three-node && "$key" == INSTALL_TYPE ]]; then
      [[ "${IMPORTED[$key]}" == production ]] || INPUT_ROWS+=("skip|${key}|'${IMPORTED[$key]}' ignored: three-node always uses production")
      continue
    fi
    if [[ "$topo" == three-node && "$key" == SIZE ]]; then
      [[ "${IMPORTED[$key]}" == small ]] || INPUT_ROWS+=("skip|${key}|'${IMPORTED[$key]}' ignored: three-node uses a fixed size (3 x n2-standard-16)")
      continue
    fi
    INPUT_ROWS+=("skip|${key}|ignored for this deployment ($(input_valid_or_empty TOPOLOGY) $(input_valid_or_empty INSTALL_MODE))")
  done
  local c
  for c in "${INPUT_CONFLICTS[@]}"; do
    IFS='|' read -r key neutral gv nv <<< "$c"
    INPUT_PROBLEMS+=("${key}: the file gives two different values, ${key}='${gv}' and ${neutral}='${nv}' (the same setting under two names). Keep only one of them.")
  done
}

input_show_summary() {
  local row status key text n_ok=0 n_ask=0
  {
    echo ""
    echo -e "${BOLD}Values from ${INPUT_CONFIG}${RESET}"
    for row in "${INPUT_ROWS[@]}"; do
      IFS='|' read -r status key text <<< "$row"
      case "$status" in
        ok) (( ++n_ok )); printf "  ${GREEN}%-5s${RESET} %-18s %s\n" ok "$key" "$text" ;;
        ask) (( ++n_ask )); printf "  ${YELLOW}%-5s${RESET} %-18s %s\n" ask "$key" "$text" ;;
        skip) printf "  ${DIM}%-5s${RESET} %-18s %s\n" skip "$key" "$text" ;;
      esac
    done
    echo "  ${n_ok} values taken from the file; ${n_ask} will be asked below."
    echo ""
  } | tee -a "$LOG_FILE" >&2
}

# Without a terminal nothing can be asked: stop before the first question and
# list every value that is missing or invalid, with the fix for each.
input_fail_fast_if_incomplete() {
  (( ${#INPUT_PROBLEMS[@]} > 0 )) || return 0
  local -a steps=() p
  for p in "${INPUT_PROBLEMS[@]}"; do steps+=("*  - ${p}"); done
  die_with_steps "${INPUT_CONFIG} cannot be used without a terminal: ${#INPUT_PROBLEMS[@]} value(s) are missing or invalid, and there is no terminal to ask for them:" \
    "${steps[@]}" \
    "Fill in these values in the file (or open it in config-generator.html with 'Open a file…', fix the marked fields and download it again)." \
    "Keys and the admin password can also come from the environment:|export INSTANA_DOWNLOAD_KEY=... INSTANA_AGENT_KEY=... INSTANA_SALES_KEY=... INSTANA_ADMIN_PASSWORD=..." \
    "Or run it in a terminal; the installer then asks for exactly these values:|./install.sh --config ${INPUT_CONFIG}"
}

# ── the two ways in: --config FILE and the import screen ─────────────────────
# --config FILE: checked before anything else; problems stop with HOW TO RESOLVE.
input_prepare_cli_file() {
  local reason
  if ! reason=$(validate_input_file "$INPUT_CONFIG" 2>&1); then
    die_with_steps "--config ${INPUT_CONFIG}: $(input_reason <<< "$reason")" \
      "Fix the file, or create it again with config-generator.html (in this folder), then rerun:|./install.sh --config <file>" \
      "*Or start without --config and answer the questions, or import a file from the menu:|./install.sh"
  fi
  INPUT_LABEL=$(basename "$INPUT_CONFIG")
}

# Provider for a --config run: INSTANA_PROVIDER, otherwise PROVIDER from the file.
input_resolve_provider() {
  local fp
  fp=$(jq -r '.parameters.PROVIDER // empty' "$INPUT_CONFIG")
  if [[ -n "${INSTANA_PROVIDER:-}" ]]; then
    [[ -z "$fp" || "$fp" == "$INSTANA_PROVIDER" ]] ||
      warn "PROVIDER '${fp}' in ${INPUT_LABEL} is overridden by INSTANA_PROVIDER=${INSTANA_PROVIDER}."
    input_refuse_unsupported_provider "$INSTANA_PROVIDER" "INSTANA_PROVIDER"
    resolve_provider || exit 1
  else
    [[ -z "$fp" ]] || input_refuse_unsupported_provider "$fp" "$INPUT_LABEL"
    resolve_provider "$fp" "$INPUT_CONFIG" || exit 1
  fi
}

default_input_file() {
  local f
  f=$(ls -t "$PWD"/instana-config*.json "$SCRIPT_DIR"/instana-config*.json "$HOME"/instana-config*.json 2>/dev/null | head -1 || true)
  printf '%s' "$f"
}

ask_input_file() {
  echo "" >&2
  hint "Path of the JSON file on THIS machine, e.g. ${SCRIPT_DIR}/instana-config.json." \
       "To make one: open config-generator.html (in this folder) in a browser, fill it in, press 'Copy as paste-in command'" \
       "and paste that into a terminal here; or copy the downloaded file over with gcloud compute scp." \
       "Values missing or invalid in the file are asked here afterwards, one by one."
  prompt_required INPUT_CONFIG "JSON file path" "$(default_input_file)" validate_input_file "Input file"
  (( ${NAV_BACK:-0} == 0 )) || return 0
  INPUT_CONFIG=$(input_expand_path "$INPUT_CONFIG")
  [[ "$INPUT_CONFIG" == /* ]] || INPUT_CONFIG="${PWD}/${INPUT_CONFIG}"
  INPUT_LABEL=$(basename "$INPUT_CONFIG")
}

# import_parameters — the mixed flow: values from the file, questions for the rest.
import_parameters() {
  PARAMS_SOURCE=import
  load_input_file "$INPUT_CONFIG"
  input_check_provider
  input_resolve_aliases
  input_drop_unknown_keys
  input_evaluate
  input_show_summary
  [[ -t 0 || -z "${INPUT_NONINTERACTIVE:-}" ]] || input_fail_fast_if_incomplete
  # The summary above already lists every value taken from the file; below
  # only questions and problems are printed.
  QUIET_OK=true
  collect_parameters
  QUIET_OK=false
  provider_normalize_params || true
}

# ── parameter-source menu ────────────────────────────────────────────────────
choose_parameter_source() {
  if [[ "$RESUME" == true ]]; then
    offer_saved_parameters || collect_parameters
    return 0
  fi
  PLAN_EDITABLE=true
  if [[ -n "$INPUT_CONFIG" ]]; then
    import_parameters
    return 0
  fi
  local choice
  local -a options=("enter the parameters now (questions one by one)" \
                    "import them from a JSON file (made with config-generator.html or --export-config)")
  if [[ -f "$CONFIG_FILE" ]]; then
    options+=("reuse the parameters saved in this folder (.install-config.json; keys are asked again)" \
              "edit the parameters saved in this folder (saved values offered as defaults)")
  fi
  # "<" at the first question (or at the file path) comes back to this menu.
  local WIZ_BACK_EXIT=1
  while true; do
    echo "" >&2
    hint "Type the answers now, or import a file prepared with config-generator.html: values from the file are" \
         "checked like typed answers, and only the missing or invalid ones are asked." \
         "In every question, < goes back to the previous one."
    choice=$(prompt_choice "How do you want to provide the deployment parameters?" "${options[@]}") ||
      die_with_steps "Input ended before the way to provide the parameters was chosen; the installation was not started and nothing was created." \
        "Run the installer in a terminal and answer the menu (1 = type the answers, 2 = import a file):|./install.sh" \
        "Or, without a terminal, give a complete input file:|./install.sh --config instana-config.json"
    WIZ_EXIT=done
    case "$choice" in
      "enter"*) PARAMS_SOURCE=manual; collect_parameters ;;
      "import"*)
        NAV_BACK=0; NAV_ON=1; INPUT_CONFIG=""; ask_input_file; NAV_ON=0
        if (( NAV_BACK )); then INPUT_CONFIG=""; continue; fi
        import_parameters ;;
      "reuse"*) PARAMS_SOURCE=saved; offer_saved_parameters "reuse saved parameters" || collect_parameters ;;
      *) PARAMS_SOURCE=saved; offer_saved_parameters "edit parameters (saved text values as defaults)" || collect_parameters ;;
    esac
    [[ "$WIZ_EXIT" == back ]] || return 0
    # Back to the menu: a later import or manual entry starts clean.
    PARAMS_SOURCE=manual; CONFIG_LOADED=false; IMPORTED=(); IMPORTED_SECRET=(); IMPORTED_SECRET_SRC=()
  done
}

# ── after the plan: edit one value, write the input file, blank secrets ──────
# Current value of every key that applies to this deployment, as an input file
# would carry it (used for "edit a value", "save to a file" and --export-config).
input_current_value() {
  local key="$1"
  case "$key" in
    PROVIDER) provider_name ;;
    SIZE) printf '%s' "${SIZE:-}" ;;
    AIRGAP_SOURCE) [[ -n "${AIRGAP_ARCHIVE:-}" ]] && printf existing ;;
    STANCTL_VERSION) [[ "${REQUESTED_STANCTL_APT_VERSION:-}" == DRY-RUN* ]] || printf '%s' "${REQUESTED_STANCTL_APT_VERSION:-}" ;;
    BACKEND_VERSION) [[ "${REQUESTED_BACKEND_VERSION:-}" == DRY-RUN* ]] || printf '%s' "${REQUESTED_BACKEND_VERSION:-}" ;;
    *) printf '%s' "${!key:-}" ;;
  esac
}

input_current_keys() {
  local -a keys=(PROVIDER TOPOLOGY INSTALL_MODE)
  [[ "$TOPOLOGY" == single-node ]] && keys+=(INSTALL_TYPE)
  if [[ "$(provider_name)" == ssh ]]; then
    mapfile -t -O "${#keys[@]}" keys < <(input_ssh_applicable_keys "$TOPOLOGY")
  elif [[ "$TOPOLOGY" == single-node ]]; then
    keys+=(UBUNTU_VERSION GCP_PROJECT GCP_REGION GCP_ZONE GCP_NETWORK GCP_SUBNET SSH_SOURCE_CIDR)
    keys+=(VM_NAME SIZE)
    [[ "${SIZE:-}" == custom ]] && keys+=(VM_CPUS VM_RAM_GB)
  else
    keys+=(UBUNTU_VERSION GCP_PROJECT GCP_REGION GCP_ZONE GCP_NETWORK GCP_SUBNET SSH_SOURCE_CIDR)
    keys+=(NODE0_NAME NODE1_NAME NODE2_NAME)
  fi
  keys+=(BASE_DOMAIN TENANT_NAME UNIT_NAME)
  if [[ "$INSTALL_MODE" == air-gapped ]]; then keys+=(AIRGAP_SOURCE AIRGAP_ARCHIVE)
  else keys+=(STANCTL_VERSION BACKEND_VERSION); fi
  keys+=(TLS_MODE)
  [[ "$TLS_MODE" == "provide custom certificate files" ]] && keys+=(TLS_CRT_PATH TLS_KEY_PATH)
  printf '%s\n' "${keys[@]}"
}

# write_input_file PATH — the current parameters as an input file, without keys.
write_input_file() {
  local path="$1" key json='{}' tmp
  local -a keys; mapfile -t keys < <(input_current_keys)
  for key in "${keys[@]}"; do
    json=$(jq --arg k "$key" --arg v "$(input_current_value "$key")" '.[$k]=$v' <<< "$json")
  done
  tmp=$(mktemp "${path}.XXXXXX") || return 1
  chmod 600 "$tmp"
  jq -n --arg schema "$INPUT_SCHEMA" --argjson p "$json" \
    '{schema:$schema, schema_version:1, parameters:$p,
      secrets:{DOWNLOAD_KEY:"", AGENT_KEY:"", SALES_KEY:"", ADMIN_PASSWORD:""}}' > "$tmp" &&
    mv -f "$tmp" "$path"
}

input_export_default_path() {
  local name="${VM_NAME:-}"
  [[ "${TOPOLOGY:-}" == three-node ]] && name="${NODE0_NAME:-}"
  printf '%s/instana-config-%s-%s.json' "$SCRIPT_DIR" "${name:-lab}" "$(date +%Y%m%d-%H%M%S)"
}

# save_plan_to_file [PATH] — writes the input file; an existing file is replaced
# only after confirmation.
save_plan_to_file() {
  local path="${1:-$(input_export_default_path)}"
  path=$(input_expand_path "$path"); [[ "$path" == /* ]] || path="${PWD}/${path}"
  if [[ -e "$path" ]]; then
    [[ ! -L "$path" ]] || die_with_steps "${path} is a symbolic link; refused." "Choose another file name:|./install.sh --export-config ~/instana-config.json"
    prompt_yes_no "${path} already exists. Replace it?" N ||
      die_with_steps "${path} already exists and was not replaced." \
        "Choose another file name:|./install.sh --export-config ~/instana-config-new.json"
  fi
  write_input_file "$path" || die_with_steps "Could not write ${path}." "Check that the folder exists and is writable:|ls -ld $(dirname "$path")"
  ok "Parameters saved to ${path} (permissions 600, keys and admin password NOT included)."
  echo "  Use it later with:   ./install.sh --config ${path}" >&2
  echo "  Or open it in config-generator.html ('Open a file…') to change values." >&2
}

# --export-config [FILE]: the parameters saved in this folder as an input file.
export_saved_parameters() {
  [[ -f "$CONFIG_FILE" ]] ||
    die_with_steps "Nothing to export: this folder has no .install-config.json (it is written after the parameters of a run are confirmed)." \
      "Run the installer once (a dry-run is enough), then export:|./install.sh --dry-run" \
      "*Or create a file from scratch with config-generator.html."
  [[ ! -L "$CONFIG_FILE" && -O "$CONFIG_FILE" ]] ||
    die_with_steps "${CONFIG_FILE} is a symbolic link or belongs to another user; it is not read, because whoever controls it could change what gets exported." \
      "Look at the file and its owner:|ls -l ${CONFIG_FILE}" \
      "Run the export as the user who owns this installer folder, or replace the link by the real file of this deployment." \
      "Then export again:|./install.sh --export-config"
  jq -e 'type=="object" and .schema_version==1 and (.parameters|type)=="object" and (.parameters|all(.[]; type=="string"))' "$CONFIG_FILE" >/dev/null ||
    die_with_steps "${CONFIG_FILE} is not a valid saved configuration." "*Create a new input file with config-generator.html instead."
  local key
  for key in "${PARAMETER_KEYS[@]}"; do
    printf -v "$key" '%s' "$(jq -r --arg k "$key" '.parameters[$k] // empty' "$CONFIG_FILE")"
  done
  local min_cpu=16 min_ram=64
  [[ "$INSTALL_TYPE" == production ]] && { min_cpu=28; min_ram=112; }
  if [[ "$TOPOLOGY" == three-node ]]; then SIZE=small
  elif [[ "$VM_CPUS" == "$min_cpu" && "$VM_RAM_GB" == "$min_ram" ]]; then SIZE=minimum
  elif [[ "$VM_CPUS" == 28 && "$VM_RAM_GB" == 112 ]]; then SIZE=production
  else SIZE=custom; fi
  save_plan_to_file "${1:-}"
}

# The plan's "E": pick one value, then re-collect with every other current
# value kept (dependent values are re-checked; a value that no longer fits is asked).
edit_parameters_before_start() {
  local -a keys items; local key value choice
  mapfile -t keys < <(input_current_keys)
  keys=("${keys[@]/PROVIDER}")
  for key in ${keys[@]}; do
    items+=("${key} = $(input_current_value "$key")")
  done
  for key in $INPUT_SECRET_KEYS; do items+=("${key} = ••••"); done
  choice=$(prompt_choice "Which value do you want to change?" "${items[@]}" "nothing, show the plan again") ||
    die_with_steps "Input ended while choosing the value to change; the installation was not started and nothing was created." \
      "Run the installer again in a terminal; at the plan answer E and pick the value by its number:|./install.sh${INPUT_CONFIG:+ --config ${INPUT_CONFIG}}" \
      "*Or change the value in the input file (config-generator.html: 'Open a file…') and run again."
  [[ "$choice" != "nothing"* ]] || return 0
  EDIT_KEY="${choice%% = *}"
  EDIT_DEFAULT=$(input_current_value "$EDIT_KEY")
  [[ " $INPUT_SECRET_KEYS " == *" $EDIT_KEY "* ]] && EDIT_DEFAULT=""
  IMPORTED=(); IMPORTED_SECRET=(); IMPORTED_SECRET_SRC=()
  for key in ${keys[@]}; do IMPORTED[$key]=$(input_current_value "$key"); done
  for key in $INPUT_SECRET_KEYS; do IMPORTED_SECRET[$key]="${!key:-}"; IMPORTED_SECRET_SRC[$key]="the current plan"; done
  local saved_label="$INPUT_LABEL"
  WIZ_DONE=()
  PARAMS_SOURCE=import; INPUT_LABEL="the current plan"; QUIET_OK=true
  log "Changing ${EDIT_KEY}; every other value is kept (values that depend on it are checked again)."
  collect_parameters
  [[ "$WIZ_EXIT" != back ]] || log "${EDIT_KEY} was not changed; back to the plan."
  QUIET_OK=false; EDIT_KEY=""; EDIT_DEFAULT=""; INPUT_LABEL="$saved_label"
  provider_normalize_params || true
}

# After "Start": the keys in the input file are no longer needed there.
offer_blank_input_secrets() {
  [[ "$DRY_RUN" != true && "$INPUT_HAD_SECRETS" == true && -n "$INPUT_CONFIG" && -f "$INPUT_CONFIG" ]] || return 0
  echo "" >&2
  hint "${INPUT_CONFIG} still contains the keys and/or the admin password in plain text." \
       "They are not needed in it any more; removing them keeps the file safe to keep and to reuse (they are asked next time)."
  if prompt_yes_no "Remove the keys and the admin password from ${INPUT_LABEL} now?" Y; then
    local tmp; tmp=$(mktemp "${INPUT_CONFIG}.XXXXXX"); chmod 600 "$tmp"
    if jq '.secrets = {DOWNLOAD_KEY:"", AGENT_KEY:"", SALES_KEY:"", ADMIN_PASSWORD:""}' "$INPUT_CONFIG" > "$tmp" && mv -f "$tmp" "$INPUT_CONFIG"; then
      ok "Keys and admin password removed from ${INPUT_CONFIG}; the other values are unchanged."
    else
      rm -f "$tmp"; warn "Could not rewrite ${INPUT_CONFIG}; remove the values under \"secrets\" by hand."
    fi
  else
    warn "${INPUT_CONFIG} keeps the keys in plain text (permissions 600). Do not share or commit it."
  fi
}
