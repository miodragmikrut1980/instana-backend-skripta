# Shared fakes for the test-ssh-*.sh tests (sourced, not a test itself).
# Fake ssh/scp/ssh-add/ssh-keygen on PATH. Per host, files in $SCEN:
#   <host>.facts  answer to the read-only facts script (FACTS_END=1 is appended)
#   <host>.rc     exit code of every ssh call to that host (default 0)
#   <host>.err    stderr of a failing call
#   <host>.zero   answer to the pre-format zero check (default ZEROCHECK:0:0)
#   <host>.zerorc exit code of the pre-format zero check (the read fails)
#   <host>.deny-user-<user>, deny-key-<key file name>  login refused (exit 255)
#   locked-<key file name>  that key has a passphrase (ssh-keygen -y fails)
# Every call is appended to $SSH_LOG (one line, arguments joined by spaces).
ssh_fakes_setup() {
  FAKE_ROOT="$(mktemp -d)"
  SCEN="$FAKE_ROOT/scen"; SSH_LOG="$FAKE_ROOT/ssh.log"
  mkdir -p "$FAKE_ROOT/bin" "$SCEN"; : > "$SSH_LOG"
  export SCEN SSH_LOG
  cat > "$FAKE_ROOT/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
echo "ssh $*" >> "$SSH_LOG"
host=""; prev=""; user=""; key=""
for a in "$@"; do
  [[ "$prev" == "--" && -z "$host" ]] && host="$a"
  [[ "$prev" == "-l" ]] && user="$a"
  [[ "$prev" == "-i" ]] && key="${a##*/}"
  prev="$a"
done
# Login refused for one user or one key: <host>.deny-user-<user>, deny-key-<key file name>.
if [[ -f "$SCEN/$host.deny-user-$user" || -f "$SCEN/deny-key-$key" ]]; then
  echo "${user}@${host}: Permission denied (publickey)." >&2; exit 255
fi
echo "$host" >> "$SCEN/known"   # accept-new: the host key is now known
cmd="${!#}"
rc=0; [[ -f "$SCEN/$host.rc" ]] && rc=$(cat "$SCEN/$host.rc")
if (( rc != 0 )); then cat "$SCEN/$host.err" >&2 2>/dev/null; exit "$rc"; fi
case "$cmd" in
  *FACTS_END*) cat "$SCEN/$host.facts"; echo FACTS_END=1 ;;
  *"route get"*) echo 10.0.0.$(( ${#host} % 200 + 10 )) ;;
  *ZEROCHECK*) if [[ -f "$SCEN/$host.zerorc" ]]; then echo "blockdev: cannot read" >&2; exit "$(cat "$SCEN/$host.zerorc")"
               elif [[ -f "$SCEN/$host.zero" ]]; then cat "$SCEN/$host.zero"; else echo ZEROCHECK:0:0; fi ;;
esac
exit 0
FAKE
  cat > "$FAKE_ROOT/bin/scp" <<'FAKE'
#!/usr/bin/env bash
echo "scp $*" >> "$SSH_LOG"
FAKE
  cat > "$FAKE_ROOT/bin/ssh-keygen" <<'FAKE'
#!/usr/bin/env bash
echo "ssh-keygen $*" >> "$SSH_LOG"
case "$*" in
  *"-y -P"*)
    kf=""; prev=""; for a in "$@"; do [[ "$prev" == "-f" ]] && kf="${a##*/}"; prev="$a"; done
    [[ "${FAKE_KEY_LOCKED:-no}" == yes || -f "$SCEN/locked-$kf" ]] && exit 1; exit 0 ;;
  *-lf*) echo "256 SHA256:fakefingerprint comment (ED25519)" ;;
  *"-l -F"*)
    name="${3#[}"; name="${name%%]*}"
    grep -qx "$name" "$SCEN/known" 2>/dev/null && echo "$3 ED25519 SHA256:hostkey-of-${name}" ;;
esac
FAKE
  cat > "$FAKE_ROOT/bin/ssh-add" <<'FAKE'
#!/usr/bin/env bash
echo "ssh-add $*" >> "$SSH_LOG"
if [[ "$*" == "-l" ]]; then
  case "${FAKE_AGENT:-none}" in
    none) exit 2 ;;
    empty) echo "The agent has no identities."; exit 1 ;;
    loaded) echo "256 SHA256:fakefingerprint comment (ED25519)"; exit 0 ;;
  esac
fi
exit "${FAKE_ADD_RC:-0}"
FAKE
  chmod +x "$FAKE_ROOT/bin"/*
  export PATH="$FAKE_ROOT/bin:$PATH"
  FAKE_KEY="$FAKE_ROOT/id_test"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----\n' > "$FAKE_KEY"
  chmod 600 "$FAKE_KEY"
}

# host_facts HOST [KEY=VALUE overrides...] — a healthy Ubuntu 24.04 host with
# 32 vCPUs, 128 GB RAM, a 300 GB root disk and four blank data disks
# (sdb 600 GB, sdc 1100 GB, sdd 1300 GB, sde 1100 GB).
host_facts() {
  local host="$1"; shift
  local -A f=([HOSTNAME]="${host%%.*}" [OS_ID]=ubuntu [OS_VERSION]=24.04 [OS_NAME]="Ubuntu 24.04.1 LTS"
    [ARCH]=x86_64 [CPUS]=32 [MEM_KB]=131900000 [ROOT_SIZE]=300000000000 [ROOT_FREE]=250000000000
    [SUDO]=ok [K3S]=no [STANCTL]=no [FIREWALLD]=inactive [MACHINE_ID]="mid-${host}" [PRODUCT_UUID]="uuid-${host}" [SSHD22]=yes [NTP]=yes)
  local kv
  for kv in "$@"; do f[${kv%%=*}]="${kv#*=}"; done
  {
    for kv in "${!f[@]}"; do echo "${kv}=${f[$kv]}"; done
    if [[ -z "${NO_DATA_DISKS:-}" ]]; then
      echo "DISK=/dev/sda|300000000000|3|/boot/efi/|vfat|Root"
      echo "DISK=/dev/sdb|600000000000|1|||PersistentDisk"
      echo "DISK=/dev/sdc|1100000000000|1|||PersistentDisk"
      echo "DISK=/dev/sdd|1300000000000|1|||PersistentDisk"
      echo "DISK=/dev/sde|1100000000000|1|||PersistentDisk"
      local d
      for d in a b c d e; do
        echo "LINK=/dev/disk/by-id/scsi-0Disk_${host}_sd${d}|/dev/sd${d}"
        echo "LINK=/dev/disk/by-id/wwn-0x5000_sd${d}|/dev/sd${d}"
      done
    else
      echo "DISK=/dev/sda|300000000000|3|/boot/efi/|vfat|Root"
    fi
    printf '%s\n' "${EXTRA_FACT_LINES[@]}"
  } > "$SCEN/${host}.facts"
}
