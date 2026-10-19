#!/usr/bin/env bash
# Existing-hosts provider (ssh): installs on 1 or 3 Ubuntu hosts the operator
# already has, over plain OpenSSH. It never creates, resizes, reboots without
# confirmation, or deletes a host. Phases 6-12 run unchanged on top of
# prov_ssh_ssh / prov_ssh_scp. Every stop explains itself (host_stop): what
# was found, why it blocks the installation, how to fix it, how to continue.

SSH_KNOWN_HOSTS_FILE="${SCRIPT_DIR:-.}/.ssh-known-hosts"
SSH_DISK_ROLES="ANALYTICS METRICS OBJECTS DATA"
declare -A SSH_FACT=()        # "<host>|KEY" -> value from prov_ssh_gather_facts
declare -a SSH_FACT_DISKS=()  # "<host>|<dev>|<bytes>|<parts>|<mounts>|<fstype>|<model>|<stable path>"
declare -a SSH_FACT_LINKS=()  # "<host>|<by-id or by-path link>|<device>"
SSH_AGENT_CHECKED=""          # key path that passed the ssh-agent preflight

prov_ssh_label() { echo "existing hosts"; }
prov_ssh_required_tools() { echo "ssh scp ssh-add"; }
prov_ssh_default_scope() { :; }
prov_ssh_machine_type_for() { echo "existing host"; }
prov_ssh_validate_image() { :; }
prov_ssh_preflight_multi() { :; }
prov_ssh_ssh_port() { echo "${SSH_PORT:-22}"; }
prov_ssh_state_resource_pattern() { echo '^(host_|hostdisk_)'; }

# ── Parameters ───────────────────────────────────────────────────────────────
prov_ssh_disk_keys() {
  local role n
  if [[ "${TOPOLOGY:-}" == three-node ]]; then
    echo DISK_DEV_NODE0_OBJECTS
    for role in DATA METRICS ANALYTICS; do echo "DISK_DEV_NODE1_${role}"; done
  elif [[ "${TOPOLOGY:-}" == single-node ]]; then
    for role in $SSH_DISK_ROLES; do echo "DISK_DEV_${role}"; done
  else
    for role in $SSH_DISK_ROLES; do echo "DISK_DEV_${role}"; done
    for n in 0 1 2; do for role in $SSH_DISK_ROLES; do echo "DISK_DEV_NODE${n}_${role}"; done; done
  fi
}

prov_ssh_param_keys() {
  echo "SSH_USER SSH_KEY_PATH SSH_PORT SSH_VIA_PRIVATE VM_HOST NODE0_HOST NODE1_HOST NODE2_HOST NETWORK_RULES_CONFIRMED" $(prov_ssh_disk_keys)
}

# Saved in .install-config.json next to the common parameters.
prov_ssh_check_saved_params() { prov_ssh_check_params; }

prov_ssh_saved_param_keys() {
  local hosts="VM_HOST"
  [[ "${TOPOLOGY:-}" == three-node ]] && hosts="NODE0_HOST NODE1_HOST NODE2_HOST"
  echo "PROVIDER SSH_USER SSH_KEY_PATH SSH_PORT SSH_VIA_PRIVATE ${hosts}" $(prov_ssh_disk_keys)
}

# Generic questions that do not apply to existing hosts: the OS is detected,
# SSH is already open, the hardware is what it is.
prov_ssh_uses_param() {
  case "$1" in
    UBUNTU_VERSION|SSH_SOURCE_CIDR|SIZE|VM_CPUS|VM_RAM_GB) return 1 ;;
  esac
  return 0
}

prov_ssh_host_valid() {
  local v="$1" ip='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$' o
  if [[ "$v" =~ $ip ]]; then
    for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
    return 0
  fi
  [[ "$v" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

# prov_ssh_validate_param KEY VALUE — format only; the host itself is checked
# after connecting. Same contract as the prompt_required validators.
prov_ssh_validate_param() {
  local key="$1" v="$2" other
  case "$key" in
    VM_HOST|NODE0_HOST|NODE1_HOST|NODE2_HOST)
      prov_ssh_host_valid "$v" || { err "${key} '${v}' is not an IPv4 address or host name (e.g. 10.0.0.5 or instana-0.example.com)."; return 1; }
      for other in NODE0_HOST NODE1_HOST NODE2_HOST; do
        [[ "$other" == "$key" || "$key" == VM_HOST ]] && continue
        [[ "$v" != "$(input_ctx_or_var "$other")" ]] || { err "${key} '${v}' is already used for ${other}; each node needs its own host."; return 1; }
      done ;;
    SSH_USER)
      [[ "$v" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] || { err "SSH_USER '${v}' is not a valid Linux user name (lowercase letters, digits, _ . -; e.g. ubuntu)."; return 1; } ;;
    SSH_KEY_PATH)
      local p; p=$(prov_ssh_expand_path "$v")
      [[ -e "$p" ]] || { err "SSH key ${p} does not exist on this machine. Give the path of the private key that may log in to the hosts (e.g. ~/.ssh/id_ed25519)."; return 1; }
      [[ -f "$p" && -r "$p" ]] || { err "SSH key ${p} is not a readable file."; return 1; }
      [[ "$(head -c 40 "$p" 2>/dev/null)" == *"PRIVATE KEY"* ]] || { err "${p} is not a private SSH key (the file does not start with a PRIVATE KEY header; a .pub file is the public half)."; return 1; } ;;
    SSH_PORT)
      [[ "$v" =~ ^[0-9]{1,5}$ ]] && (( 10#$v >= 1 && 10#$v <= 65535 )) || { err "SSH_PORT '${v}' must be a number from 1 to 65535 (usually 22)."; return 1; } ;;
    SSH_VIA_PRIVATE|NETWORK_RULES_CONFIRMED)
      [[ "$v" == true || "$v" == false ]] || { err "${key} '${v}' must be true or false."; return 1; } ;;
    DISK_DEV_*)
      [[ "$v" =~ ^/dev/disk/by-(id|path)/[A-Za-z0-9._:+@-]+$ ]] ||
        { err "${key} '${v}' must be a stable disk path under /dev/disk/by-id/ or /dev/disk/by-path/ (not /dev/sdX, which can change after a reboot)."; return 1; } ;;
    *) err "Unknown parameter '${key}' for provider ssh (existing hosts)."; return 1 ;;
  esac
}

input_ctx_or_var() {
  if declare -F input_ctx >/dev/null; then input_ctx "$1"; else printf '%s' "${!1:-}"; fi
}

prov_ssh_expand_path() {
  local p="$1"
  [[ "$p" == "~" ]] && p="$HOME"
  [[ "$p" == "~/"* ]] && p="${HOME}/${p#\~/}"
  printf '%s' "$p"
}

# Keys this deployment needs, in the order they are asked.
prov_ssh_required_keys() {
  if [[ "${TOPOLOGY:-}" == three-node ]]; then echo NODE0_HOST NODE1_HOST NODE2_HOST; else echo VM_HOST; fi
  echo SSH_USER SSH_KEY_PATH SSH_PORT
  prov_ssh_disk_keys
}

# prov_ssh_check_params — every SSH value (typed, from a file, or loaded from
# .install-config.json on reuse/--resume) passes the same check before any of
# it is used in an ssh call, a local command or a remote root command.
prov_ssh_check_params() {
  local key reason
  for key in $(prov_ssh_required_keys) SSH_VIA_PRIVATE; do
    [[ "$key" == SSH_VIA_PRIVATE && -z "${SSH_VIA_PRIVATE:-}" ]] && continue
    if [[ -z "${!key:-}" ]]; then
      reason="${key} is empty."
    elif reason=$(prov_ssh_validate_param "$key" "${!key}" 2>&1); then
      continue
    fi
    reason=$(sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^\[ERROR\] *//' <<< "$reason" | paste -sd' ' -)
    die_with_steps "The saved parameter ${key} cannot be used: ${reason}" \
      "*Why the installation stops: SSH values go into ssh commands and into commands run as root on the hosts; a value that fails the check is never used." \
      "Look at the saved value:|jq -r '.parameters.${key}' $(prov_ssh_q "${CONFIG_FILE:-.install-config.json}")" \
      "Start a new deployment and enter the value again (or fix it in the input file):|./install.sh" \
      "*A deployment that was already started keeps its saved parameters; restore the original .install-config.json, then continue with ./install.sh --resume."
  done
}

# prompt_required validators.
validate_ssh_host() { prov_ssh_validate_param "${2:-VM_HOST}" "$1"; }
validate_ssh_user() { prov_ssh_validate_param SSH_USER "$1"; }
validate_ssh_key() { prov_ssh_validate_param SSH_KEY_PATH "$1"; }
validate_ssh_port() { prov_ssh_validate_param SSH_PORT "$1"; }

# Hosts of this deployment, in node order.
prov_ssh_hosts() {
  if [[ "${TOPOLOGY:-}" == three-node ]]; then printf '%s\n' "$NODE0_HOST" "$NODE1_HOST" "$NODE2_HOST"
  else printf '%s\n' "$VM_HOST"; fi
}

# Node name or host -> host to connect to.
prov_ssh_host_for() {
  local node="$1"
  if [[ "${TOPOLOGY:-}" == three-node ]]; then
    [[ "$node" == "${NODE0_NAME:-}" ]] && { echo "$NODE0_HOST"; return; }
    [[ "$node" == "${NODE1_NAME:-}" ]] && { echo "$NODE1_HOST"; return; }
    [[ "$node" == "${NODE2_NAME:-}" ]] && { echo "$NODE2_HOST"; return; }
  else
    [[ "$node" == "${VM_NAME:-}" ]] && { echo "$VM_HOST"; return; }
  fi
  local h
  while IFS= read -r h; do [[ -n "$h" && "$node" == "$h" ]] && { echo "$h"; return; }; done < <(prov_ssh_hosts 2>/dev/null)
  echo "$node"
}

# Node name -> index (three-node) for DISK_DEV_NODE<n>_*.
prov_ssh_node_index() {
  [[ "$1" == "${NODE0_NAME:-}" ]] && { echo 0; return; }
  [[ "$1" == "${NODE1_NAME:-}" ]] && { echo 1; return; }
  [[ "$1" == "${NODE2_NAME:-}" ]] && { echo 2; return; }
  echo ""
}

prov_ssh_disk_key_for() {
  local node="$1" role="$2"
  if [[ "${TOPOLOGY:-}" == three-node ]]; then echo "DISK_DEV_NODE$(prov_ssh_node_index "$node")_${role}"
  else echo "DISK_DEV_${role}"; fi
}

# prov_ssh_disk_device_path NODE DEVICE — DEVICE is the installer's role name
# (disk-analytics, ...); the path is the stable link chosen for that role.
prov_ssh_disk_device_path() {
  local role key
  role=$(tr '[:lower:]' '[:upper:]' <<< "${2#disk-}")
  key=$(prov_ssh_disk_key_for "$1" "$role")
  printf '%s\n' "${!key:-}"
}

# ── Explained stops ──────────────────────────────────────────────────────────
# host_stop HOST FOUND WHY CONTINUE FIX... — every stop names what was found on
# which host, why that blocks the installation, how to fix it, how to continue.
host_stop() {
  local host="$1" found="$2" why="$3" cont="$4"; shift 4
  die_with_steps "Host ${host}: ${found}" \
    "*Why the installation stops: ${why}" \
    "$@" \
    "How to continue afterwards:|${cont}"
}

prov_ssh_continue_cmd() {
  if [[ "${RESUME:-false}" == true ]]; then echo "./install.sh --resume"; else echo "./install.sh${INPUT_CONFIG:+ --config ${INPUT_CONFIG}}"; fi
}

# ── Transport ────────────────────────────────────────────────────────────────
# Same keep-alive values as the GCP transport; a known_hosts file of its own in
# this folder, so a host key that changes later is a hard stop, never accepted.
prov_ssh_opts() {
  SSH_OPTS=(-i "$(prov_ssh_expand_path "$SSH_KEY_PATH")" -o IdentitiesOnly=yes -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS_FILE}"
    -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o TCPKeepAlive=yes)
}

# prov_ssh_ssh NODE LOCATION SCOPE COMMAND — LOCATION and SCOPE (GCP zone and
# project) are not used; exit 255 means the connection failed.
prov_ssh_ssh() {
  local -a SSH_OPTS; prov_ssh_opts
  ssh "${SSH_OPTS[@]}" -p "${SSH_PORT:-22}" -l "$SSH_USER" -- "$(prov_ssh_host_for "$1")" "$4"
}

# prov_ssh_ssh_probe NODE LOCATION SCOPE TIMEOUT_S CONNECT_TIMEOUT_S COMMAND [KIND]
prov_ssh_ssh_probe() {
  local -a SSH_OPTS; prov_ssh_opts
  timeout "${4}s" ssh "${SSH_OPTS[@]}" -o "ConnectTimeout=${5}" -p "${SSH_PORT:-22}" -l "$SSH_USER" -- "$(prov_ssh_host_for "$1")" "$6"
}

# prov_ssh_scp LOCAL_FILE NODE LOCATION SCOPE REMOTE_PATH [KIND]
prov_ssh_scp() {
  local -a SSH_OPTS; prov_ssh_opts
  scp "${SSH_OPTS[@]}" -P "${SSH_PORT:-22}" -o "User=${SSH_USER}" -- "$1" "$(prov_ssh_host_for "$2"):${5}"
}

# prov_ssh_get_ip NODE LOCATION SCOPE public|private
prov_ssh_get_ip() {
  local host; host=$(prov_ssh_host_for "$1")
  if [[ "$4" == private ]]; then
    prov_ssh_ssh "$1" "" "" "ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if(\$i==\"src\"){print \$(i+1); exit}}' | grep . || hostname -I | awk '{print \$1}'"
    return
  fi
  # Hosts reached over a private network: the public address is confirmed by hand at the end.
  [[ "${SSH_VIA_PRIVATE:-false}" != true ]] || { echo unknown; return 0; }
  if [[ "$host" =~ ^[0-9.]+$ ]]; then echo "$host"; else getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}'; fi
}

# Shell-quoted value for commands printed to be copied (paths may hold spaces).
prov_ssh_q() { printf '%q' "$1"; }
# The ssh command line an operator can paste to reach HOST.
prov_ssh_cmd_line() { printf 'ssh -i %s -p %s %s@%s' "$(prov_ssh_q "$SSH_KEY_PATH")" "${SSH_PORT:-22}" "$SSH_USER" "$1"; }

prov_ssh_hint() {
  local kind="$1" node="$2" cmd="${5:-}" host
  host=$(prov_ssh_host_for "$node")
  case "$kind" in
    ssh)
      local base; base=$(prov_ssh_cmd_line "$host")
      if [[ -n "$cmd" ]]; then printf '%s\n' "${base} '${cmd}'"; else printf '%s\n' "$base"; fi ;;
    cpu_platform)
      printf '%s\n' "The CPU of ${host} lacks x86-64-v3 instructions; this cannot be fixed on the host. Use a machine with a newer CPU (Intel Haswell / AMD Excavator or newer; on a VM: a machine type that exposes AVX2), then start again:|./install.sh" ;;
    x86_machine)
      printf '%s\n' "${host} is not an x86_64 machine; Instana needs x86_64 (x86-64-v3). Use another host, then start again:|./install.sh" ;;
  esac
}

# ── ssh-agent preflight ──────────────────────────────────────────────────────
# A key without a passphrase is used directly. A passphrase-protected key must
# be loaded in ssh-agent: ssh-add is run once interactively (it asks for the
# passphrase itself); the installer never reads, stores or logs a passphrase.
prov_ssh_agent_preflight() {
  local key fp rc=0
  key=$(prov_ssh_expand_path "$SSH_KEY_PATH")
  [[ "$SSH_AGENT_CHECKED" != "$key" ]] || return 0
  if ssh-keygen -y -P '' -f "$key" >/dev/null 2>&1; then
    SSH_AGENT_CHECKED="$key"; return 0
  fi
  if [[ -f "${key}.pub" ]]; then fp=$(ssh-keygen -lf "${key}.pub" 2>/dev/null | awk '{print $2}')
  else fp=$(ssh-keygen -lf "$key" 2>/dev/null | awk '{print $2}'); fi
  ssh-add -l >/dev/null 2>&1 || rc=$?
  if [[ -z "${SSH_AUTH_SOCK:-}" || "$rc" == 2 ]]; then
    die_with_steps "SSH key ${key} is protected by a passphrase, and no ssh-agent is running in this shell to hold it." \
      "*Why the installation stops: every step runs over SSH without prompts (BatchMode); a passphrase cannot be typed for each of the hundreds of SSH calls." \
      "Start an agent in this shell and load the key once (ssh-add asks for the passphrase):|eval \"\$(ssh-agent -s)\" && ssh-add $(prov_ssh_q "$key")" \
      "How to continue afterwards (in the same shell):|$(prov_ssh_continue_cmd)"
  fi
  if [[ -n "$fp" ]] && ssh-add -l 2>/dev/null | grep -qF "$fp"; then
    SSH_AGENT_CHECKED="$key"; ok "SSH key ${key} is loaded in ssh-agent."; return 0
  fi
  if [[ -t 0 ]]; then
    hint "SSH key ${key} is protected by a passphrase and not loaded in ssh-agent yet." \
         "ssh-add will now ask for the passphrase once (typed into ssh-add, not into this installer)."
    if ssh-add "$key"; then
      SSH_AGENT_CHECKED="$key"; ok "SSH key ${key} loaded in ssh-agent."; return 0
    fi
  fi
  die_with_steps "SSH key ${key} is protected by a passphrase and could not be loaded into ssh-agent." \
    "*Why the installation stops: every step runs over SSH without prompts (BatchMode), so the key must be available in ssh-agent." \
    "Load the key once in this shell (ssh-add asks for the passphrase):|ssh-add $(prov_ssh_q "$key")" \
    "*If no agent is running, start one first: eval \"\$(ssh-agent -s)\"" \
    "How to continue afterwards (in the same shell):|$(prov_ssh_continue_cmd)"
}

prov_ssh_check_auth() {
  [[ -n "${SSH_KEY_PATH:-}" ]] || return 0
  prov_ssh_agent_preflight
}

# ── Facts about a host (read-only) ───────────────────────────────────────────
# One SSH call per host; output KEY=VALUE lines.
SSH_FACTS_SCRIPT='hostname -s | sed "s/^/HOSTNAME=/"
. /etc/os-release 2>/dev/null; echo "OS_ID=${ID:-}"; echo "OS_VERSION=${VERSION_ID:-}"; echo "OS_NAME=${PRETTY_NAME:-}"
echo "ARCH=$(uname -m)"; echo "CPUS=$(nproc)"; echo "MEM_KB=$(awk "/^MemTotal:/{print \$2}" /proc/meminfo)"
df -B1 --output=size,avail / | awk "NR==2{print \"ROOT_SIZE=\"\$1; print \"ROOT_FREE=\"\$2}"
if sudo -n true 2>/dev/null; then echo SUDO=ok; else echo SUDO=no; fi
if test -e /etc/rancher/k3s/k3s.yaml; then echo K3S=yes; else echo K3S=no; fi
if command -v stanctl >/dev/null 2>&1; then echo STANCTL=yes; else echo STANCTL=no; fi
echo "FIREWALLD=$(systemctl is-active firewalld 2>/dev/null || true)"
echo "MACHINE_ID=$(cat /etc/machine-id 2>/dev/null)"
echo "PRODUCT_UUID=$(sudo -n cat /sys/class/dmi/id/product_uuid 2>/dev/null)"
if ss -ltnH 2>/dev/null | awk "{print \$4}" | grep -Eq "(^|:)22\$"; then echo SSHD22=yes; else echo SSHD22=no; fi
echo "NTP=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
lsblk -bdpn -o NAME,SIZE,TYPE 2>/dev/null | while read -r n s t; do
  [ "$t" = disk ] || continue
  echo "DISK=$n|$s|$(lsblk -npo NAME "$n" | wc -l)|$(lsblk -npo MOUNTPOINT "$n" | tr -d " \n")|$(lsblk -dno FSTYPE "$n")|$(lsblk -dno MODEL "$n" | tr -s " " | tr " " _)"
done
for l in /dev/disk/by-id/* /dev/disk/by-path/*; do [ -e "$l" ] && echo "LINK=$l|$(readlink -f "$l")"; done
echo FACTS_END=1'

# prov_ssh_gather_facts HOST — fills SSH_FACT / SSH_FACT_DISKS; connection
# problems stop with an explanation.
prov_ssh_gather_facts() {
  local host="$1" out errf rc=0 line key value
  errf=$(mktemp)
  out=$(prov_ssh_ssh_probe "$host" "" "" 60 15 "$SSH_FACTS_SCRIPT" 2>"$errf") || rc=$?
  if (( rc != 0 )) || [[ "$out" != *"FACTS_END=1"* ]]; then
    local msg; msg=$(grep -v '^\s*$' "$errf" | head -3 | paste -sd' ' -); rm -f "$errf"
    if [[ "$msg" == *"IDENTIFICATION HAS CHANGED"* || "$msg" == *"Host key verification failed"* ]]; then
      host_stop "$host" "its SSH host key differs from the key recorded when the installer first connected (${SSH_KNOWN_HOSTS_FILE})." \
        "a changed host key means the address now leads to another machine, or the host was reinstalled; continuing could install on the wrong machine." \
        "$(prov_ssh_continue_cmd)" \
        "Check that ${host} is still the intended machine (console, hostname, IP)." \
        "If the host was deliberately reinstalled, forget its old key:|ssh-keygen -R ${host} -f $(prov_ssh_q "$SSH_KNOWN_HOSTS_FILE")"
    fi
    if (( rc == 124 )); then msg="no answer within 60 seconds${msg:+ (${msg})}"; fi
    host_stop "$host" "SSH login as ${SSH_USER} on port ${SSH_PORT:-22} with key ${SSH_KEY_PATH} failed: ${msg:-exit code ${rc}}." \
      "the installer runs every step on the host over SSH; without a working login nothing can be checked or installed." \
      "$(prov_ssh_continue_cmd)" \
      "Try the same login by hand; it must work without a password prompt:|$(prov_ssh_cmd_line "$host") true" \
      "*If it asks for a password or is refused: authorize the key on the host ($(printf 'ssh-copy-id -i %s -p %s %s@%s' "$(prov_ssh_q "${SSH_KEY_PATH}.pub")" "${SSH_PORT:-22}" "$SSH_USER" "$host"))." \
      "*If it times out: check that the host is running and that port ${SSH_PORT:-22} is open from this machine." \
      "*Run the installer as the same Linux user ($(id -un 2>/dev/null || echo "\$USER")) who owns the key ${SSH_KEY_PATH}; a key authorized for another user on this machine does not help." \
      "*Google Cloud hosts with OS Login enforced (metadata enable-oslogin=TRUE on the project) ignore keys in the instance or project metadata: set enable-oslogin=false on that instance, or grant the user OS Login access."
  fi
  rm -f "$errf"
  local -a links=() kept=() kept_links=()
  for line in "${SSH_FACT_DISKS[@]}"; do [[ "$line" == "${host}|"* ]] || kept+=("$line"); done
  for line in "${SSH_FACT_LINKS[@]}"; do [[ "$line" == "${host}|"* ]] || kept_links+=("$line"); done
  SSH_FACT_DISKS=("${kept[@]}"); SSH_FACT_LINKS=("${kept_links[@]}")
  while IFS= read -r line; do
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in
      DISK) SSH_FACT["${host}|DISKS"]+="${value}"$'\n' ;;
      LINK)
        # Paths come from the host's udev; only plain stable names are used.
        [[ "${value%%|*}" =~ ^/dev/disk/by-(id|path)/[A-Za-z0-9._:+@-]+$ && "${value#*|}" =~ ^/dev/[A-Za-z0-9/_-]+$ ]] || continue
        links+=("$value"); SSH_FACT_LINKS+=("${host}|${value}") ;;
      HOSTNAME|OS_ID|OS_VERSION|OS_NAME|ARCH|CPUS|MEM_KB|ROOT_SIZE|ROOT_FREE|SUDO|K3S|STANCTL|FIREWALLD|MACHINE_ID|PRODUCT_UUID|SSHD22|NTP)
        SSH_FACT["${host}|${key}"]="$value" ;;
    esac
  done <<< "$out"
  SSH_FACT["${host}|GATHERED"]=1
  local dev bytes parts mounts fstype model stable l target best
  while IFS='|' read -r dev bytes parts mounts fstype model; do
    [[ "$dev" =~ ^/dev/[A-Za-z0-9/_-]+$ && "$bytes" =~ ^[0-9]+$ && "$parts" =~ ^[0-9]+$ ]] || continue
    best=""
    for l in "${links[@]}"; do
      target="${l#*|}"; [[ "$target" == "$dev" ]] || continue
      l="${l%%|*}"
      case "$l" in
        /dev/disk/by-id/wwn-*|/dev/disk/by-id/nvme-eui.*) [[ -n "$best" ]] || best="$l" ;;
        /dev/disk/by-id/*) [[ "$best" == /dev/disk/by-id/* && "$best" != */wwn-* && "$best" != */nvme-eui.* ]] || best="$l" ;;
        /dev/disk/by-path/*) [[ -n "$best" ]] || best="$l" ;;
      esac
    done
    SSH_FACT_DISKS+=("${host}|${dev}|${bytes}|${parts}|${mounts}|${fstype}|${model}|${best}")
  done <<< "${SSH_FACT["${host}|DISKS"]:-}"
  SSH_FACT["${host}|DISKS"]=""
}

prov_ssh_fact() { printf '%s' "${SSH_FACT["$1|$2"]:-}"; }

# Identity of the machine behind an address: /etc/machine-id, otherwise the
# DMI product UUID (read with sudo -n); empty when neither is available.
prov_ssh_host_id() {
  local id
  id=$(prov_ssh_fact "$1" MACHINE_ID)
  [[ -n "$id" ]] || { id=$(prov_ssh_fact "$1" PRODUCT_UUID); [[ -z "$id" ]] || id="dmi:${id}"; }
  printf '%s' "$id"
}

# The host key ssh accepted for HOST on first contact (known_hosts of this folder).
prov_ssh_known_key() {
  local name="$1"
  [[ "${SSH_PORT:-22}" == 22 ]] || name="[$1]:${SSH_PORT}"
  # Nothing recorded yet is a normal answer (first contact), not an error.
  { ssh-keygen -l -F "$name" -f "$SSH_KNOWN_HOSTS_FILE" 2>/dev/null | grep -v '^#' | head -1; } || true
}
prov_ssh_ensure_facts() { [[ -n "${SSH_FACT["$1|GATHERED"]:-}" ]] || prov_ssh_gather_facts "$1"; }

# Ubuntu image name the rest of the installer and the plan use.
prov_ssh_ubuntu_version() {
  case "$(prov_ssh_fact "$1" OS_VERSION)" in
    24.04) echo ubuntu-2404-lts-amd64 ;;
    22.04) echo ubuntu-2204-lts ;;
    *) echo "ubuntu-$(prov_ssh_fact "$1" OS_VERSION)" ;;
  esac
}

# ── Sizes (IBM documentation) ────────────────────────────────────────────────
prov_ssh_min_cpu_ram() {
  if [[ "${TOPOLOGY:-}" == three-node ]]; then echo "12 48"
  elif [[ "${INSTALL_TYPE:-}" == production ]]; then echo "28 112"
  else echo "16 64"; fi
}

prov_ssh_role_min_gb() {
  local role="$1"
  if [[ "${TOPOLOGY:-}" == three-node || "${INSTALL_TYPE:-}" == production ]]; then
    case "$role" in ANALYTICS) echo 1200 ;; METRICS) echo 1000 ;; OBJECTS) echo 1000 ;; DATA) echo 500 ;; esac
  else
    case "$role" in ANALYTICS) echo 500 ;; METRICS) echo 300 ;; OBJECTS) echo 250 ;; DATA) echo 150 ;; esac
  fi
}

# Root filesystem: IBM documents 100 GB for /; the GCP labs use 100 GB
# (single-node) and 270 GB (three-node, / also holds the cluster data).
readonly SSH_ROOT_IBM_MIN_GB=100
prov_ssh_root_lab_gb() { [[ "${TOPOLOGY:-}" == three-node ]] && echo 270 || echo 100; }

gb_of_bytes() { echo $(( ${1:-0} / 1000000000 )); }
# Sizes are compared in decimal GB with 3% tolerance (a "500 GB" disk has
# slightly less than 500*10^9 usable bytes on some platforms).
size_at_least_gb() { (( ${1:-0} * 100 >= ${2} * 1000000000 * 97 )); }

# ── Phase 1: questions ───────────────────────────────────────────────────────
prov_ssh_collect_location_params() {
  if [[ "$TOPOLOGY" == three-node ]]; then
    imported_usable NODE0_HOST NODE1_HOST NODE2_HOST ||
      hint "Addresses of the three existing hosts (IPv4 or DNS name reachable from this machine)." \
           "Node 0 runs the backend and stanctl, node 1 the data stores (three big disks), node 2 the rest."
    prov_ssh_ask_host NODE0_HOST "Node 0 host (backend)"
    prov_ssh_ask_host NODE1_HOST "Node 1 host (data store)"
    prov_ssh_ask_host NODE2_HOST "Node 2 host (other)"
  else
    imported_usable VM_HOST ||
      hint "Address of the existing Ubuntu host (IPv4 or DNS name reachable from this machine)." \
           "The installer checks it before anything is changed; it never deletes or recreates the host."
    prov_ssh_ask_host VM_HOST "Host address"
  fi
  imported_usable SSH_USER SSH_KEY_PATH SSH_PORT ||
    hint "How this machine logs in: a user with passwordless sudo on the host(s), the private key file and the SSH port." \
         "The key never leaves this machine; only its path is saved."
  # Ubuntu cloud images (GCP, AWS, ...) log in as "ubuntu"; a saved value comes first.
  use_imported SSH_USER || prompt_required SSH_USER "SSH user" "ubuntu" validate_ssh_user
  use_imported SSH_KEY_PATH || prompt_required SSH_KEY_PATH "SSH private key path" "$(prov_ssh_default_key)" validate_ssh_key
  SSH_KEY_PATH=$(prov_ssh_expand_path "$SSH_KEY_PATH")
  use_imported SSH_PORT || prompt_required SSH_PORT "SSH port" "22" validate_ssh_port
  if [[ "$TOPOLOGY" == three-node ]]; then
    use_imported SSH_VIA_PRIVATE || {
      hint "Are the node addresses above private (this machine is in the same network)? Then the public address" \
           "for the browser is asked at the end instead of being taken from them."
      SSH_VIA_PRIVATE=$(prompt_choice "Node addresses are:" "false" "true")
    }
  else
    SSH_VIA_PRIVATE="${SSH_VIA_PRIVATE:-false}"
  fi
  prov_ssh_agent_preflight
  local host known
  while IFS= read -r host; do
    log "Connecting to ${SSH_USER}@${host}:${SSH_PORT} (read-only checks)..."
    known=$(prov_ssh_known_key "$host")
    prov_ssh_gather_facts "$host"
    if [[ -z "$known" ]]; then
      known=$(prov_ssh_known_key "$host")
      warn "First connection to ${host}: its SSH host key is now trusted for this deployment: ${known:-not recorded}."
      hint "Compare it with the key on the host's console if you can (sudo ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub)." \
           "From now on a different key on this address stops the installer."
    fi
    ok "${host}: $(prov_ssh_fact "$host" OS_NAME), $(prov_ssh_fact "$host" CPUS) vCPUs, $(( $(prov_ssh_fact "$host" MEM_KB) / 1000000 )) GB RAM, hostname $(prov_ssh_fact "$host" HOSTNAME)."
  done < <(prov_ssh_hosts)
  UBUNTU_VERSION=$(prov_ssh_ubuntu_version "$(prov_ssh_hosts | head -1)")
}

# The host's short name as an installer name (lowercase, letters/digits/-).
prov_ssh_name_from_host() {
  local n
  n=$(prov_ssh_fact "$1" HOSTNAME | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n-' '-' | sed -e 's/^[^a-z]*//' -e 's/-*$//' | cut -c1-63)
  printf '%s\n' "${n:-$2}"
}

# prov_ssh_ask_host KEY LABEL — from the input file, else a saved value as the
# default, else (on a Google Cloud control machine with gcloud) a numbered list
# of the running VMs of the project, else a free answer.
prov_ssh_ask_host() {
  local key="$1" label="$2" saved="" choice c ip name zone project
  use_imported "$key" && return 0
  [[ "$CONFIG_LOADED" == true && -f "${CONFIG_FILE:-}" ]] && saved=$(jq -r --arg k "$key" '.parameters[$k] // empty' "$CONFIG_FILE" 2>/dev/null || true)
  [[ "$key" == "${EDIT_KEY:-}" && -n "${EDIT_DEFAULT:-}" ]] && saved="$EDIT_DEFAULT"
  if [[ -z "$saved" ]]; then
    local -a found=() options=()
    project=$(prov_ssh_gce_project)
    [[ -z "$project" ]] || mapfile -t found < <(prov_ssh_gce_instances "$project")
    if (( ${#found[@]} > 0 )); then
      for c in "${found[@]}"; do IFS='|' read -r name zone ip <<< "$c"; options+=("${name}  (${zone}, ${ip})"); done
      hint "Running VMs in Google Cloud project ${project} (listed with gcloud from this machine; this machine and hosts already chosen are left out)." \
           "Pick one to use its internal IP, or choose 'enter another address' for any other host."
      choice=$(prompt_choice "${label}:" "${options[@]}" "enter another address") || choice=""
      if [[ -n "$choice" && "$choice" != "enter another address" ]]; then
        ip="${choice##*, }"; ip="${ip%)}"
        if prov_ssh_validate_param "$key" "$ip" >/dev/null 2>&1; then
          printf -v "$key" '%s' "$ip"
          ok "${key} = ${ip} (${choice%%  (*})"
          return 0
        fi
      fi
    fi
  fi
  prompt_required "$key" "$label" "" validate_ssh_host "$key"
}

# Running VMs of the current gcloud project, as "name|zone|internal IP", the
# zone of this machine first. A convenience only: no gcloud, no login, an
# error or a timeout simply gives an empty list (the address is typed).
prov_ssh_gce_project() {
  command -v gcloud >/dev/null 2>&1 || return 0
  local project
  project=$(timeout 10 gcloud config get-value project 2>/dev/null || true)
  [[ -n "$project" && "$project" != "(unset)" ]] || project="instana-support-test-account"
  [[ ! "$project" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || printf '%s\n' "$project"
}
prov_ssh_gce_instances() {
  local project="$1" here self out name zone ip used k
  here=$(! declare -F detect_local_gce_zone >/dev/null || detect_local_gce_zone)
  self=$(hostname -s 2>/dev/null || true)
  out=$(timeout 20 gcloud compute instances list --project="$project" --filter=status=RUNNING \
    --format='value(name,zone.basename(),networkInterfaces[0].networkIP)' 2>/dev/null) || return 0
  used=" "
  for k in VM_HOST NODE0_HOST NODE1_HOST NODE2_HOST; do used+="${!k:-} "; done
  while read -r name zone ip _; do
    [[ "$name" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ && "$zone" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]] || continue
    prov_ssh_host_valid "$ip" && [[ "$ip" =~ ^[0-9.]+$ ]] || continue
    [[ "$name" != "$self" && "$used" != *" $ip "* ]] || continue
    printf '%s|%s|%s|%s\n' "$([[ "$zone" == "$here" ]] && echo 0 || echo 1)" "$name" "$zone" "$ip"
  done <<< "$out" | sort -t'|' -k1,1 -k2,2 | cut -d'|' -f2-
}

prov_ssh_default_key() {
  local k
  for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do [[ -f "$k" ]] && { echo "$k"; return; }; done
  echo "$HOME/.ssh/id_ed25519"
}

prov_ssh_text() {
  case "$1" in
    setup_title) echo "Existing-host Deployment Setup" ;;
    topology_hint)
      echo "single-node: everything on one existing host (labs, demos, small setups)."
      echo "three-node: Instana spread over three existing hosts, IBM 'production' type, at least 12 vCPUs / 48 GB each." ;;
    vm_name_hint)
      echo "Name for this host inside the installer (state file, messages); the host itself is not renamed."
      echo "Lowercase letters, digits and hyphens; the host's own name is offered." ;;
    node_names_hint) echo "Names for the three hosts inside the installer (state file, messages); the hosts are not renamed." ;;
    three_node_size_note) echo "Three-node: each host needs at least the small profile (12 vCPUs / 48 GB, documented minimum); checked on the hosts." ;;
    start_line) echo "Enter Y and press Enter to START installing Instana on the host(s) listed above." ;;
    resume_mismatch) echo "Host, user or port differs from the saved state of this deployment. No changes made." ;;
    ip_confirm_line) echo "Confirm public IPv4 addresses. Enter accepts the address used for SSH." ;;
    default_vm_name) prov_ssh_name_from_host "${VM_HOST:-}" instana-backend ;;
    dry_run_banner) echo "Dry-run mode — nothing will be changed on the hosts (they are only read over SSH)." ;;
    destroy_banner) echo "This forgets the deployment recorded in this folder; nothing on the hosts is deleted or changed" ;;
    destroy_nothing_hint)
      echo "  The installer has not checked or changed any host for this deployment yet; there is nothing to forget."
      echo "  The hosts are never deleted by the installer." ;;
    default_node0_name) prov_ssh_name_from_host "${NODE0_HOST:-}" instana-0 ;;
    default_node1_name) prov_ssh_name_from_host "${NODE1_HOST:-}" instana-1 ;;
    default_node2_name) prov_ssh_name_from_host "${NODE2_HOST:-}" instana-2 ;;
  esac
}

prov_ssh_phase_text() {
  case "$1:$2" in
    1:start) echo "Verify required command-line tools, acquire the installer lock, check the SSH key, and collect or reuse saved non-secret parameters." ;;
    2:title) echo "Host access and installation plan" ;;
    2:start) echo "Check SSH access, the ssh-agent key and the chosen data disks on every host, then display the complete plan before anything is changed." ;;
    2:done) echo "Host access and installation plan were validated." ;;
    3:title) echo "Host checks (OS, CPU, RAM, sudo)" ;;
    3:start) echo "Read-only checks on every host: Ubuntu version, x86_64, CPU and RAM, root filesystem, passwordless sudo, no existing Kubernetes, firewalld, host identity." ;;
    3:done) echo "All hosts passed the checks." ;;
    4:title) echo "Data disk mapping" ;;
    4:start) echo "Verify that every chosen data disk still exists, is large enough, unmounted and unpartitioned; record the mapping." ;;
    4:done) echo "Data disks are mapped and recorded." ;;
    5:title) echo "Network port checklist" ;;
    5:start) echo "List the ports that must be open between this machine, the users and the hosts; verify SSH reachability; confirm the rules." ;;
    5:done) echo "Network rules confirmed." ;;
  esac
}

# Names default to the hosts' own short names; then each role gets a disk.
prov_ssh_collect_host_params() {
  local node role key
  for node in $(prov_ssh_nodes); do
    for role in $(prov_ssh_roles_for "$node"); do
      key=$(prov_ssh_disk_key_for "$node" "$role")
      prov_ssh_choose_disk "$node" "$role" "$key"
    done
  done
}

prov_ssh_nodes() {
  if [[ "${TOPOLOGY:-}" == three-node ]]; then echo "$NODE0_NAME $NODE1_NAME $NODE2_NAME"; else echo "$VM_NAME"; fi
}

prov_ssh_roles_for() {
  if [[ "${TOPOLOGY:-}" != three-node ]]; then echo "$SSH_DISK_ROLES"; return; fi
  case "$(prov_ssh_node_index "$1")" in
    0) echo OBJECTS ;;
    1) echo "DATA METRICS ANALYTICS" ;;
    *) echo "" ;;
  esac
}

# Disks of HOST usable for ROLE: whole disk, no partitions/holders, nothing
# mounted, not an LVM/RAID/crypt member, a stable path, large enough, and not
# already chosen for another role. Prints "path|GB|model|dev".
prov_ssh_disk_candidates() {
  local host="$1" role="$2" self_key="$3" line h dev bytes parts mounts fstype model stable min k taken
  min=$(prov_ssh_role_min_gb "$role")
  for line in "${SSH_FACT_DISKS[@]}"; do
    IFS='|' read -r h dev bytes parts mounts fstype model stable <<< "$line"
    [[ "$h" == "$host" && -n "$stable" && "$parts" == 1 && -z "$mounts" ]] || continue
    case "$fstype" in LVM2_member|linux_raid_member|crypto_LUKS|zfs_member) continue ;; esac
    size_at_least_gb "$bytes" "$min" || continue
    taken=false
    for k in $(prov_ssh_disk_keys); do
      [[ "$k" != "$self_key" && -n "${!k:-}" ]] || continue
      [[ "$(prov_ssh_disk_dev "$host" "${!k}")" == "$dev" ]] && taken=true
    done
    [[ "$taken" == false ]] || continue
    printf '%s|%s|%s|%s\n' "$stable" "$(gb_of_bytes "$bytes")" "${model:-?}" "$dev"
  done
}

# Kernel device behind a /dev/disk/by-* path on HOST (any link to the disk).
prov_ssh_disk_dev() {
  local host="$1" path="$2" line h link target
  for line in "${SSH_FACT_LINKS[@]}"; do
    IFS='|' read -r h link target <<< "$line"
    [[ "$h" == "$host" && "$link" == "$path" ]] && { echo "$target"; return; }
  done
}

prov_ssh_choose_disk() {
  local node="$1" role="$2" key="$3" host min c chosen
  host=$(prov_ssh_host_for "$node")
  min=$(prov_ssh_role_min_gb "$role")
  local -a cands options
  mapfile -t cands < <(prov_ssh_disk_candidates "$host" "$role" "$key")
  if use_imported "$key"; then
    for c in "${cands[@]}"; do [[ "${c##*|}" == "$(prov_ssh_disk_dev "$host" "${!key}")" ]] && return 0; done
    warn "${key} ${!key} from $(input_source_label) is not usable on ${host} for ${role,,} (missing, smaller than ${min} GB, mounted, partitioned or already used for another role); choose a disk below."
    printf -v "$key" '%s' ""
  fi
  if (( ${#cands[@]} == 0 )); then
    host_stop "$host" "no unused disk of at least ${min} GB is available for the ${role,,} data ($(prov_ssh_disk_summary "$host"))." \
      "IBM requires a dedicated disk per Instana data directory; the installer never uses the system disk, a mounted or partitioned disk, or one disk for two roles." \
      "$(prov_ssh_continue_cmd)" \
      "Attach an empty disk of at least ${min} GB to ${host} (no partitions, not mounted), then check it is visible:|$(prov_ssh_cmd_line "$host") lsblk -dp -o NAME,SIZE,TYPE,MOUNTPOINT"
  fi
  if [[ ! -t 0 && -n "${INPUT_NONINTERACTIVE:-}" ]]; then
    host_stop "$host" "no disk is chosen for the ${role,,} data (${key} is missing or not usable) and there is no terminal to ask." \
      "each Instana data directory needs its own disk, and the installer never picks one silently." \
      "$(prov_ssh_continue_cmd)" \
      "Put one of these paths into the input file as \"${key}\": $(printf '%s ' "${cands[@]%%|*}")"
  fi
  for c in "${cands[@]}"; do
    local p gb model dev
    IFS='|' read -r p gb model dev <<< "$c"
    options+=("${p}  (${gb} GB, ${model}, now ${dev})")
  done
  hint "Disk on ${host} for the ${role,,} data (at least ${min} GB). Only unused whole disks are offered;" \
       "it is formatted ext4 in phase 9 only if it is blank. Stable /dev/disk/by-id names survive reboots."
  chosen=$(prompt_choice "Disk for ${role,,} on ${node}:" "${options[@]}") ||
    host_stop "$host" "input ended while choosing the disk for ${role,,}." \
      "each Instana data directory needs its own disk, and the installer never picks one silently." \
      "$(prov_ssh_continue_cmd)" "Run the installer in a terminal and choose the disk, or set \"${key}\" in the input file."
  printf -v "$key" '%s' "${chosen%%  (*}"
}

prov_ssh_disk_summary() {
  local host="$1" line h dev bytes parts mounts fstype model stable out=""
  for line in "${SSH_FACT_DISKS[@]}"; do
    IFS='|' read -r h dev bytes parts mounts fstype model stable <<< "$line"
    [[ "$h" == "$host" ]] || continue
    out+="${out:+; }${dev} $(gb_of_bytes "$bytes") GB"
    [[ -z "$mounts" ]] || out+=", mounted at ${mounts}"
    (( parts <= 1 )) || out+=", partitioned"
  done
  printf '%s' "${out:-no disks found}"
}

# ── Phase 2: access check for runs that skipped the questions (saved/--resume) ─
prov_ssh_validate_config() {
  # The shared phase code passes zone and project to every remote call; for
  # existing hosts they are empty (prov_ssh_ssh ignores them).
  GCP_ZONE="${GCP_ZONE:-}" GCP_PROJECT="${GCP_PROJECT:-}"
  prov_ssh_check_params
  prov_ssh_agent_preflight
  local host
  while IFS= read -r host; do prov_ssh_ensure_facts "$host"; done < <(prov_ssh_hosts)
  [[ -n "${UBUNTU_VERSION:-}" ]] || UBUNTU_VERSION=$(prov_ssh_ubuntu_version "$(prov_ssh_hosts | head -1)")
  ok "SSH access to $(prov_ssh_hosts | paste -sd' ' -) works as ${SSH_USER} on port ${SSH_PORT}."
}

# ── Plan ─────────────────────────────────────────────────────────────────────
prov_ssh_plan_target_lines() {
  printf "  %-30s %s\n" "Install on:"        "existing host(s), nothing is created or deleted"
  printf "  %-30s %s\n" "SSH login:"         "${SSH_USER} on port ${SSH_PORT}, key ${SSH_KEY_PATH}"
}

prov_ssh_plan_resource_lines() {
  local node host role key
  echo ""
  for node in $(prov_ssh_nodes); do
    host=$(prov_ssh_host_for "$node")
    printf "  %-30s %s\n" "Host ${node}:" "${host} ($(prov_ssh_fact "$host" OS_NAME), $(prov_ssh_fact "$host" CPUS) vCPUs, $(( ${SSH_FACT["${host}|MEM_KB"]:-0} / 1000000 )) GB RAM)"
    for role in $(prov_ssh_roles_for "$node"); do
      key=$(prov_ssh_disk_key_for "$node" "$role")
      printf "    %-28s %s\n" "${role,,} disk:" "${!key} → /mnt/instana/stanctl/${role,,}"
    done
  done
  echo ""
  echo "  Changes the installer will make on the host(s) (confirmed separately after Start):"
  prov_ssh_host_changes | sed 's/^/    - /'
}

prov_ssh_host_changes() {
  echo "kernel settings (sysctl, Transparent Huge Pages off via GRUB) and a REBOOT of each host, one at a time"
  echo "Ubuntu firewall (UFW) enabled: SSH port ${SSH_PORT}, 80, 443, 8443 and the cluster networks open"
  echo "the chosen blank data disks formatted ext4 and mounted under /mnt/instana/stanctl (non-blank disks stop the run)"
  [[ "${TOPOLOGY:-}" != three-node ]] || echo "root SSH key from node 0 to all nodes and 'PermitRootLogin prohibit-password' (sshd drop-in)"
  echo "Instana package repository, stanctl and Kubernetes (k3s) installed"
}

# Always asked in a terminal, also for runs from an input file: these are
# changes on machines the installer does not own.
prov_ssh_confirm_host_changes() {
  [[ "$DRY_RUN" != true ]] || return 0
  echo "" >&2
  echo -e "${BOLD}These changes will be made on $(prov_ssh_hosts | paste -sd' ' -):${RESET}" >&2
  prov_ssh_host_changes | sed 's/^/  - /' >&2
  if [[ ! -t 0 ]]; then
    die_with_steps "The changes on the existing host(s) must be confirmed in a terminal, and this run has none." \
      "*Why the installation stops: the installer reboots the hosts and changes their firewall and disks; that is never approved by a file or a script." \
      "Run the installer in a terminal and answer the confirmation:|./install.sh${INPUT_CONFIG:+ --config ${INPUT_CONFIG}}"
  fi
  prompt_yes_no "Make these changes on the host(s)? (the hosts will be rebooted)" N ||
    { log "Installation was not started; the changes on the hosts were not approved."; exit 0; }
}

prov_ssh_record_target() {
  save_state "ssh_target" "$(prov_ssh_target_text)"
}
prov_ssh_target_text() { echo "${SSH_USER}@$(prov_ssh_hosts | paste -sd, -):${SSH_PORT}"; }

prov_ssh_resume_state_matches() {
  [[ "$(get_state ssh_target)" == "$(prov_ssh_target_text)" && "$(get_state "host_${VM_NAME}")" == checked ]]
}

prov_ssh_prepare_multi() {
  BOOT_SIZE_GB=$(prov_ssh_root_lab_gb)
  warn "THREE EXISTING HOSTS: node 0 needs a disk for objects, node 1 three disks (data, metrics, analytics); every host at least 12 vCPUs / 48 GB."
}

# ── Phase 3: host checks ─────────────────────────────────────────────────────
prov_ssh_check_host() {
  local node="$1" host min_cpu min_ram cpus ram_gb root_gb rid cont
  host=$(prov_ssh_host_for "$node")
  cont=$(prov_ssh_continue_cmd)
  read -r min_cpu min_ram <<< "$(prov_ssh_min_cpu_ram)"
  if [[ "$(prov_ssh_fact "$host" SUDO)" != ok ]]; then
    host_stop "$host" "user ${SSH_USER} cannot run sudo without a password." \
      "every installation step runs as root through 'sudo' in a non-interactive SSH session, where a password prompt would hang." \
      "$cont" \
      "On ${host}, allow ${SSH_USER} passwordless sudo (as an administrator):|echo '${SSH_USER} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-instana-installer && sudo chmod 440 /etc/sudoers.d/90-instana-installer"
  fi
  if [[ "$(prov_ssh_fact "$host" OS_ID)" != ubuntu || ! "$(prov_ssh_fact "$host" OS_VERSION)" =~ ^(22\.04|24\.04)$ ]]; then
    host_stop "$host" "it runs $(prov_ssh_fact "$host" OS_NAME) (${SSH_USER}@${host}, /etc/os-release)." \
      "Instana Standard Edition supports only Ubuntu 22.04 and 24.04 (IBM documentation, Table 1)." \
      "./install.sh" \
      "Use a host with Ubuntu 24.04 (recommended) or 22.04, or reinstall this one, then start again."
  fi
  if [[ "$(prov_ssh_fact "$host" ARCH)" != x86_64 ]]; then
    host_stop "$host" "its CPU architecture is $(prov_ssh_fact "$host" ARCH)." \
      "Instana Standard Edition runs only on x86_64 CPUs with the x86-64-v3 instruction set." \
      "./install.sh" "Use an x86_64 host, then start again."
  fi
  cpus=$(prov_ssh_fact "$host" CPUS); ram_gb=$(( $(prov_ssh_fact "$host" MEM_KB) * 1024 / 1000000000 ))
  if (( cpus < min_cpu || ram_gb * 100 < min_ram * 95 )); then
    host_stop "$host" "it has ${cpus} vCPUs and ${ram_gb} GB RAM." \
      "this $( [[ "${TOPOLOGY:-}" == three-node ]] && echo "three-node node" || echo "${INSTALL_TYPE} single-node" ) installation needs at least ${min_cpu} vCPUs and ${min_ram} GB RAM (IBM documentation)." \
      "./install.sh" \
      "Give the host more CPU/RAM (resize the VM or use bigger hardware), or choose a smaller installation type, then start again."
  fi
  root_gb=$(gb_of_bytes "$(prov_ssh_fact "$host" ROOT_SIZE)")
  if ! size_at_least_gb "$(prov_ssh_fact "$host" ROOT_SIZE)" "$SSH_ROOT_IBM_MIN_GB"; then
    host_stop "$host" "its root filesystem (/) is ${root_gb} GB." \
      "IBM requires at least ${SSH_ROOT_IBM_MIN_GB} GB for / (operating system, container images, logs)." \
      "$cont" \
      "Grow the root disk and filesystem to at least ${SSH_ROOT_IBM_MIN_GB} GB (e.g. on a VM: resize the disk, then):|sudo growpart <disk> <partition> && sudo resize2fs <root device>"
  fi
  if ! size_at_least_gb "$(prov_ssh_fact "$host" ROOT_SIZE)" "$(prov_ssh_root_lab_gb)"; then
    warn "${host}: root filesystem (/) is ${root_gb} GB; the GCP labs of this installer use $(prov_ssh_root_lab_gb) GB. Continuing, but watch the free space during the installation."
  fi
  if [[ "$(prov_ssh_fact "$host" FIREWALLD)" == active ]]; then
    host_stop "$host" "firewalld is active." \
      "the installer configures the Ubuntu firewall (UFW); firewalld and UFW together give unpredictable rules and can block the cluster traffic. The installer never disables a firewall by itself." \
      "$cont" \
      "If firewalld is not needed on this host, stop and disable it (as an administrator):|sudo systemctl disable --now firewalld"
  fi
  if [[ "${RESUME:-false}" != true && "$(prov_ssh_fact "$host" K3S)" == yes ]]; then
    host_stop "$host" "Kubernetes (k3s) is already installed (/etc/rancher/k3s/k3s.yaml exists)." \
      "a new installation needs a host without an existing cluster; installing on top of it could destroy that cluster or mix two installations." \
      "./install.sh --resume (only if this folder started that installation), otherwise ./install.sh" \
      "If this host's old installation is no longer needed, remove it first (deletes that cluster):|sudo /usr/local/bin/k3s-uninstall.sh" \
      "*If this folder's own installation was interrupted, continue it with --resume instead."
  fi
  if [[ "${TOPOLOGY:-}" == three-node && "$(prov_ssh_fact "$host" SSHD22)" != yes ]]; then
    host_stop "$host" "sshd does not listen on port 22." \
      "in a three-node cluster node 0 reaches the other nodes as root over SSH on port 22 (stanctl multi-node)." \
      "$cont" \
      "Let sshd also listen on port 22 (add 'Port 22' next to the existing Port line), then:|sudo systemctl restart ssh"
  fi
  if [[ -z "$(prov_ssh_host_id "$host")" ]]; then
    host_stop "$host" "it has no machine identity: /etc/machine-id is missing or empty and /sys/class/dmi/id/product_uuid cannot be read." \
      "the installer records the identity of every host and compares it on --resume, so that an address that now leads to another machine is never continued; without an identity that check is impossible." \
      "$cont" \
      "Create a machine ID on the host (systemd does this on a normal boot):|sudo systemd-machine-id-setup && cat /etc/machine-id"
  fi
  rid=$(get_state "hostid_${node}")
  if [[ -n "$rid" && "$rid" != "$(prov_ssh_host_id "$host")" ]]; then
    host_stop "$host" "its machine ID ($(prov_ssh_host_id "$host")) differs from the one recorded when this deployment started (${rid})." \
      "the address now leads to another machine (or the host was reinstalled); continuing would install half a deployment on the wrong machine." \
      "./install.sh --resume" \
      "Point ${node} back at the original machine (DNS / IP), or remove this deployment's local state and start a new one:|./install.sh --destroy"
  fi
  [[ "$(prov_ssh_fact "$host" STANCTL)" != yes || "${RESUME:-false}" == true ]] ||
    warn "${host}: stanctl is already installed; the version chosen for this deployment will be installed over it."
  [[ "$(prov_ssh_fact "$host" NTP)" != no ]] ||
    warn "${host}: the clock is not NTP-synchronized; clusters need synchronized clocks (sudo timedatectl set-ntp true)."
  phase_detail done "${node} (${host}): $(prov_ssh_fact "$host" OS_NAME), ${cpus} vCPUs, ${ram_gb} GB RAM, / ${root_gb} GB, sudo ok."
}

prov_ssh_ensure_vms() {
  local node host
  for node in $(prov_ssh_nodes); do
    host=$(prov_ssh_host_for "$node")
    prov_ssh_gather_facts "$host"
    prov_ssh_check_host "$node"
    if [[ "$DRY_RUN" != true ]]; then
      save_state "host_${node}" checked
      [[ -n "$(get_state "hostid_${node}")" ]] || save_state "hostid_${node}" "$(prov_ssh_host_id "$host")"
    fi
  done
}

prov_ssh_resume_check_vm() {
  prov_ssh_gather_facts "$(prov_ssh_host_for "$1")"
  prov_ssh_check_host "$1"
}

# ── Phase 4: data disks ──────────────────────────────────────────────────────
prov_ssh_ensure_disks() {
  local node host role key path line h dev bytes parts mounts fstype model stable found min target
  for node in $(prov_ssh_nodes); do
    host=$(prov_ssh_host_for "$node")
    prov_ssh_ensure_facts "$host"
    for role in $(prov_ssh_roles_for "$node"); do
      key=$(prov_ssh_disk_key_for "$node" "$role"); path="${!key:-}"; min=$(prov_ssh_role_min_gb "$role")
      target="/mnt/instana/stanctl/${role,,}"
      found=""
      local want; want=$(prov_ssh_disk_dev "$host" "$path")
      for line in "${SSH_FACT_DISKS[@]}"; do
        IFS='|' read -r h dev bytes parts mounts fstype model stable <<< "$line"
        [[ "$h" == "$host" && -n "$want" && "$dev" == "$want" ]] && { found="$line"; break; }
      done
      if [[ -z "$found" ]]; then
        host_stop "$host" "the disk chosen for ${role,,} (${key}=${path:-empty}) is not present (disks now: $(prov_ssh_disk_summary "$host"))." \
          "the installer only uses the exact disk that was chosen and shown in the plan; it never substitutes another disk." \
          "$(prov_ssh_continue_cmd)" \
          "Reattach that disk to ${host}, or start a new deployment and choose another disk:|./install.sh"
      fi
      IFS='|' read -r h dev bytes parts mounts fstype model stable <<< "$found"
      size_at_least_gb "$bytes" "$min" ||
        host_stop "$host" "the disk for ${role,,} (${path}) has $(gb_of_bytes "$bytes") GB." \
          "IBM requires at least ${min} GB for the ${role,,} data of this installation type." \
          "./install.sh" "Use a disk of at least ${min} GB (resize it or choose another one in a new run)."
      if [[ "$parts" != 1 || ( -n "$mounts" && "$mounts" != "$target" ) ]]; then
        host_stop "$host" "the disk for ${role,,} (${path}, now ${dev}) is $( [[ "$parts" != 1 ]] && echo partitioned || echo "mounted at ${mounts}" )." \
          "a data disk must be a whole, unused disk; the installer never repartitions or unmounts a disk that may hold data." \
          "$(prov_ssh_continue_cmd)" \
          "Check what is on it:|$(prov_ssh_cmd_line "$host") lsblk -p ${dev}" \
          "*If it holds nothing you need: unmount it and remove its partitions (wipefs -a ${dev} deletes the signatures), or choose another disk in a new run."
      fi
      [[ "$DRY_RUN" == true ]] || save_state "hostdisk_${node}-${role,,}" "$path"
      phase_detail done "${node}: ${role,,} → ${path} ($(gb_of_bytes "$bytes") GB, now ${dev})."
    done
  done
}

# ── Phase 9: before a disk without a filesystem signature is formatted ──────
# "Blank" for the installer means: no signature blkid knows. Disks on hosts the
# installer does not own may hold data without one (raw database files, an
# encrypted volume, another OS); such a disk is formatted only when its first
# and last MiB (by byte offset, so a size that is not a multiple of 1 MiB
# still has its very end checked, where a GPT backup header sits) are zeros. Read-only; a disk with a signature is left
# to the existing checks (empty ext4 adoption, refusal of anything else).
prov_ssh_check_blank_disk() {
  local node="$1" device="$2" path host out
  path=$(prov_ssh_disk_device_path "$node" "$device"); host=$(prov_ssh_host_for "$node")
  out=$(remote_exec "$node" "" "" "set -euo pipefail
dev='${path}'
test -b \"\$dev\"
if blkid \"\$dev\" >/dev/null 2>&1; then echo SIGNED; exit 0; fi
size=\$(blockdev --getsize64 \"\$dev\")
start=\$(( size > 1048576 ? size - 1048576 : 0 ))
first=\$(head -c 1048576 \"\$dev\" | tr -d '\\000' | wc -c)
last=\$(dd if=\"\$dev\" bs=1M iflag=skip_bytes,count_bytes skip=\$start count=1048576 2>/dev/null | tr -d '\\000' | wc -c)
echo \"ZEROCHECK:\$first:\$last\"") ||
    host_stop "$host" "the data disk ${path} could not be read before formatting." \
      "the installer formats a disk without a filesystem only after checking that it holds no data." \
      "./install.sh --resume" \
      "Check that the disk is attached and readable:|$(prov_ssh_hint ssh "$node" "" "" "sudo blockdev --getsize64 ${path}")"
  out=$(tail -n 1 <<< "$out")
  case "$out" in
    SIGNED|ZEROCHECK:0:0) return 0 ;;
  esac
  host_stop "$host" "the disk ${path} has no filesystem signature, but its first or last MiB is not empty (${out#ZEROCHECK:} non-zero bytes)." \
    "it may hold data without a filesystem signature (raw database files, an encrypted volume, another operating system); formatting would destroy it, so the installer never formats it on its own." \
    "./install.sh --resume" \
    "Look at the start of the disk to see what it holds:|$(prov_ssh_hint ssh "$node" "" "" "sudo hexdump -C -n 512 ${path}")" \
    "Only if it holds nothing you need, wipe it yourself (start and end of the disk):|sudo wipefs -a ${path} && sudo dd if=/dev/zero of=${path} bs=1M count=10 && sudo dd if=/dev/zero of=${path} bs=1M count=1 oflag=seek_bytes seek=\$(( \$(sudo blockdev --getsize64 ${path}) - 1048576 ))"
}

# ── Phase 5: network ports ───────────────────────────────────────────────────
prov_ssh_ensure_firewall() {
  local host
  echo "  These connections must be allowed by the network around the host(s) (cloud security groups," >&2
  echo "  data-center firewalls); the installer cannot open them:" >&2
  echo "    - from this machine to every host: TCP ${SSH_PORT} (SSH)" >&2
  echo "    - from users and Instana agents to $( [[ "${TOPOLOGY:-}" == three-node ]] && echo "node 0" || echo "the host" ): TCP 80, 443, 8443" >&2
  if [[ "${TOPOLOGY:-}" == three-node ]]; then
    echo "    - between the three nodes: TCP 22, 53, 6443, 10250, 2379, 2380, 5001, 9443; UDP 53, 8472" >&2
    echo "    - between the nodes, the pod and service networks 10.42.0.0/16 and 10.43.0.0/16 (all protocols)" >&2
  fi
  while IFS= read -r host; do
    if [[ "$DRY_RUN" == true ]]; then
      phase_detail active "Would check that TCP ${SSH_PORT} on ${host} is reachable from this machine."
    elif timeout 6 bash -c "exec 3<>/dev/tcp/${host}/${SSH_PORT}" 2>/dev/null; then
      phase_detail done "${host}: TCP ${SSH_PORT} reachable from this machine."
    else
      host_stop "$host" "TCP port ${SSH_PORT} (SSH) cannot be reached from this machine any more." \
        "every remaining step runs over SSH." \
        "$(prov_ssh_continue_cmd)" \
        "Check that the host is running and the network allows TCP ${SSH_PORT} from this machine:|$(prov_ssh_cmd_line "$host") true"
    fi
  done < <(prov_ssh_hosts)
  warn "Ports 80, 443 and 8443$( [[ "${TOPOLOGY:-}" == three-node ]] && echo " and the node-to-node ports" ) can only be tested after Instana is running."
  [[ "$DRY_RUN" != true ]] || return 0
  [[ "${NETWORK_RULES_CONFIRMED:-}" == true ]] || use_imported NETWORK_RULES_CONFIRMED || true
  if [[ "${NETWORK_RULES_CONFIRMED:-}" == true ]]; then
    ok "Network rules confirmed (NETWORK_RULES_CONFIRMED=true)."
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die_with_steps "The network rules listed above are not confirmed, and there is no terminal to ask." \
      "*Why the installation stops: without them the cluster or the UI cannot work, and the installer cannot check them before Instana runs." \
      "Make sure the rules exist, then confirm them in the input file (\"NETWORK_RULES_CONFIRMED\": \"true\") or run in a terminal:|$(prov_ssh_continue_cmd)"
  fi
  prompt_yes_no "Are these network rules in place?" N ||
    die_with_steps "The network rules listed above are not confirmed." \
      "*Why the installation stops: without them the cluster or the UI cannot work after a long installation." \
      "Ask the network/cloud administrator to allow the listed connections." \
      "How to continue afterwards:|./install.sh --resume"
  NETWORK_RULES_CONFIRMED=true
}

# ── Destroy: local state only, hosts are never touched ──────────────────────
prov_ssh_destroy_target() {
  DESTROY_SCOPE=state
  DESTROY_LOCATION=$(get_state ssh_target 2>/dev/null || echo "")
}
prov_ssh_destroy_target_text() { echo "hosts: '${DESTROY_LOCATION:-?}'"; }
prov_ssh_destroy_validate_target() { :; }
prov_ssh_destroy_from_state() {
  warn "Provider ssh (existing hosts): nothing is deleted on the hosts. Only this folder's state is removed."
  echo "  What stays on the host(s) ${DESTROY_LOCATION}: the Instana installation (k3s, stanctl), the" >&2
  echo "  formatted data disks mounted under /mnt/instana/stanctl, UFW rules and kernel settings." >&2
  echo "  To clean a host completely, uninstall k3s there (sudo /usr/local/bin/k3s-uninstall.sh) and" >&2
  echo "  remove the /mnt/instana/stanctl entries from /etc/fstab." >&2
  if [[ "$DRY_RUN" == true ]]; then
    DESTROY_SUMMARY="Preview finished: only the local state of this folder would be removed; nothing on the hosts."
  else
    DESTROY_SUMMARY="This folder's record of the deployment was removed; nothing on the hosts was deleted or changed."
  fi
}
prov_ssh_destroy_by_name() {
  ok "Provider ssh (existing hosts) creates nothing, so there is nothing to clean up by name. The hosts are never deleted."
  exit 0
}
