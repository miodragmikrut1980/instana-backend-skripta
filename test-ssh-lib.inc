# Shared fakes for the test-ssh-*.sh tests (sourced, not a test itself).
# Fake ssh/scp/ssh-add/ssh-keygen on PATH. Per host, files in $SCEN:
#   <host>.facts  answer to the read-only facts script (FACTS_END=1 is appended)
#   <host>.rc     exit code of every ssh call to that host (default 0)
#   <host>.err    stderr of a failing call
# Every call is appended to $SSH_LOG (one line, arguments joined by spaces).
ssh_fakes_setup() {
  FAKE_ROOT="$(mktemp -d)"
  SCEN="$FAKE_ROOT/scen"; SSH_LOG="$FAKE_ROOT/ssh.log"
  mkdir -p "$FAKE_ROOT/bin" "$SCEN"; : > "$SSH_LOG"
  export SCEN SSH_LOG
  cat > "$FAKE_ROOT/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
echo "ssh $*" >> "$SSH_LOG"
host=""; for a in "$@"; do [[ "$a" == *@* && -z "$host" ]] && host="${a#*@}"; done
cmd="${!#}"
rc=0; [[ -f "$SCEN/$host.rc" ]] && rc=$(cat "$SCEN/$host.rc")
if (( rc != 0 )); then cat "$SCEN/$host.err" >&2 2>/dev/null; exit "$rc"; fi
case "$cmd" in
  *FACTS_END*) cat "$SCEN/$host.facts"; echo FACTS_END=1 ;;
  *"route get"*) echo 10.0.0.$(( ${#host} % 200 + 10 )) ;;
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
  *"-y -P"*) [[ "${FAKE_KEY_LOCKED:-no}" == yes ]] && exit 1; exit 0 ;;
  *-lf*) echo "256 SHA256:fakefingerprint comment (ED25519)" ;;
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
    [SUDO]=ok [K3S]=no [STANCTL]=no [FIREWALLD]=inactive [MACHINE_ID]="mid-${host}" [SSHD22]=yes [NTP]=yes)
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
