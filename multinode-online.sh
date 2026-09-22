#!/usr/bin/env bash
# Three-node ONLINE lab only. Overrides the legacy online orchestration.

prepare_multinode_lab() {
  if [[ "$RESUME" == true ]]; then
    validate_multinode_resume
  fi
  [[ "$NODE_CPUS" == 12 && "$NODE_RAM_GB" == 48 ]] || die "First lab release supports the small profile only (12 CPU/48 GB minimum per node)."
  [[ "$NODE0_NAME" != "$NODE1_NAME" && "$NODE0_NAME" != "$NODE2_NAME" && "$NODE1_NAME" != "$NODE2_NAME" ]] || die "Node names must be distinct."
  [[ "$RESUME" == true || ! -f "$STATE_FILE" ]] || state_is_only_progress || die "Existing state: use --resume or a NEW deployment folder."
  DEPLOYMENT_TAG="lab-${NODE0_NAME:0:45}"
  BOOT_SIZE_GB=270
  warn "INTERNAL LAB: 3 x n2-standard-16 (16 CPU/64 GB), 270 GB boot per node, 4 dedicated pd-ssd data disks. Physical isolation and sustained I/O are not certified."
  warn "Use a NEW base domain; existing single-node DNS must not be redirected. Public HTTP/TLS endpoints will be reachable."
  local suffix
  [[ "$DRY_RUN" == true ]] && return 0
  [[ "$RESUME" == true ]] && return 0
  for suffix in ssh external internal pods; do
    if gcloud compute firewall-rules describe "${DEPLOYMENT_TAG}-${suffix}" --project="$GCP_PROJECT" >/dev/null 2>&1; then
      die "Firewall name already exists: ${DEPLOYMENT_TAG}-${suffix}"
    fi
  done
}

lab_checkpoint() { save_state "step_$1" completed; }

lab_firewalls() {
  local name rule suffix sources target
  for suffix in ssh external internal pods; do
    name="${DEPLOYMENT_TAG}-${suffix}"
    target="--target-tags=$DEPLOYMENT_TAG"
    case "$suffix" in
      ssh) rule=tcp:22; sources="--source-ranges=$SSH_SOURCE_CIDR";;
      external) rule=tcp:80,tcp:443,tcp:8443; sources=--source-ranges=0.0.0.0/0;;
      internal) rule=tcp,udp,icmp; sources="--source-tags=$DEPLOYMENT_TAG";;
      pods) rule=tcp,udp,icmp; sources=--source-ranges=10.42.0.0/16,10.43.0.0/16;;
    esac
    run gcloud compute firewall-rules create "$name" --project="$GCP_PROJECT" \
      --network="$GCP_NETWORK" --allow="$rule" "$sources" "$target"
    save_state "firewall_${name}" created
  done
}

lab_kernel() {
  local node="$1" before after i
  remote_exec_dry "$node" "$GCP_ZONE" "$GCP_PROJECT" 'set -e; printf "vm.swappiness=0\nfs.inotify.max_user_instances=8192\n" > /etc/sysctl.d/99-stanctl.conf; sysctl --system; if ! grep -q transparent_hugepage=never /etc/default/grub; then sed -i '\''s/^GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="transparent_hugepage=never /'\'' /etc/default/grub; fi; update-grub'
  [[ "$DRY_RUN" == true ]] && return 0
  before=$(remote_exec "$node" "$GCP_ZONE" "$GCP_PROJECT" 'cat /proc/sys/kernel/random/boot_id')
  remote_exec "$node" "$GCP_ZONE" "$GCP_PROJECT" 'shutdown -r +1'
  for ((i=0; i<40; i++)); do
    sleep 10
    after=$(timeout 20s gcloud compute ssh "$node" --quiet --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
      --command='cat /proc/sys/kernel/random/boot_id' --ssh-flag='-o BatchMode=yes' --ssh-flag='-o ConnectTimeout=5' 2>/dev/null || true)
    if [[ -n "$after" && "$after" != "$before" ]]; then
      remote_exec "$node" "$GCP_ZONE" "$GCP_PROJECT" 'grep -q "\[never\]" /sys/kernel/mm/transparent_hugepage/enabled'
      lab_checkpoint "kernel_${node}"
      return 0
    fi
  done
  die "Reboot was not verified on $node; stop and inspect."
}

lab_root_ssh() {
  local node ip pub known line
  remote_exec_dry "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" 'set -e; install -d -m 700 /root/.ssh; test -f /root/.ssh/id_rsa || ssh-keygen -t rsa -b 3072 -N "" -f /root/.ssh/id_rsa'
  [[ "$DRY_RUN" == true ]] && return 0
  pub=$(remote_exec "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" 'cat /root/.ssh/id_rsa.pub')
  [[ "$pub" =~ ^ssh-rsa\ [A-Za-z0-9+/=]+\  ]] || die "Unexpected SSH public key."
  for node in "$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME"; do
    remote_exec "$node" "$GCP_ZONE" "$GCP_PROJECT" "set -e; install -d -m 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; grep -qxF '$pub' /root/.ssh/authorized_keys || printf '%s\\n' '$pub' >> /root/.ssh/authorized_keys; printf 'PermitRootLogin prohibit-password\\n' > /etc/ssh/sshd_config.d/00-instana-lab.conf; sshd -t; systemctl reload ssh"
    ip=$(get_state "${node}_private_ip")
    known=$(remote_exec "$node" "$GCP_ZONE" "$GCP_PROJECT" 'cat /etc/ssh/ssh_host_ed25519_key.pub')
    line="$ip $known"
    remote_exec "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" "touch /root/.ssh/known_hosts; chmod 600 /root/.ssh/known_hosts; grep -qxF '$line' /root/.ssh/known_hosts || printf '%s\\n' '$line' >> /root/.ssh/known_hosts"
    remote_exec "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 root@$ip 'id -u' | grep -qx 0"
  done
  lab_checkpoint root_ssh
}

main_three_node() {
  [[ "$INSTALL_MODE" == online ]] || { legacy_main_three_node; return; }
  initialize_multinode_state
  local node ip
  phase_start 3 "Check quota for three nodes and create or verify all VMs. Resume mode validates existing resources instead of recreating them."
  check_gcp_quota "$GCP_PROJECT" "$GCP_ZONE" 48
  [[ "$RESUME" == true ]] || check_duplicate_vms "$GCP_PROJECT" "$GCP_ZONE" "$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME"
  for node in "$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME"; do
    phase_detail active "Ensuring VM ${node} exists with the expected image and machine type."
    resume_create_vm "$node" n2-standard-16 "$GCP_ZONE" "$GCP_PROJECT" "$GCP_NETWORK" "$GCP_SUBNET" "$UBUNTU_VERSION"
  done
  phase_done 3 "All three VMs are present and verified."

  phase_start 4 "Create and attach four dedicated SSD data disks using stable device names; existing attachments are verified during resume."
  resume_disk "$NODE0_NAME" "${NODE0_NAME}-objects" 1000 disk-objects
  resume_disk "$NODE1_NAME" "${NODE1_NAME}-data" 500 disk-data
  resume_disk "$NODE1_NAME" "${NODE1_NAME}-metrics" 1000 disk-metrics
  resume_disk "$NODE1_NAME" "${NODE1_NAME}-analytics" 1200 disk-analytics
  phase_done 4 "All multi-node data disks are attached."

  phase_start 5 "Create deployment-scoped GCP rules: restricted SSH, public 80/443/8443, node-to-node traffic, and pod/service CIDRs."
  resume_firewalls
  phase_done 5 "GCP firewall rules are present and recorded."

  phase_start 6 "Wait for SSH, install required Ubuntu packages, verify CPU instruction flags, record private IPs, and establish verified root SSH between nodes."
  for node in "$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME"; do
    if [[ "$DRY_RUN" == true ]]; then ip=10.128.0.10; else
      ip=$(gcloud compute instances describe "$node" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format='value(networkInterfaces[0].networkIP)')
      wait_for_ssh "$node" "$GCP_ZONE" "$GCP_PROJECT"
    fi
    save_state "${node}_private_ip" "$ip"
    phase_detail active "Preparing OS prerequisites and CPU checks on ${node}."
    remote_exec_dry "$node" "$GCP_ZONE" "$GCP_PROJECT" 'set -e; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y curl gnupg ca-certificates ufw; test "$(uname -m)" = x86_64; for flag in avx avx2 bmi1 bmi2 fma f16c ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm; do grep -qw "$flag" /proc/cpuinfo || { echo "Missing CPU flag $flag"; exit 1; }; done'
  done
  lab_root_ssh
  phase_done 6 "All nodes accept SSH, pass prerequisite checks, and node0 can securely reach every node."

  phase_start 7 "Apply Instana kernel settings on every node, reboot one node at a time, and verify boot ID and THP=never before continuing."
  for node in "$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME"; do
    phase_detail active "Applying and verifying kernel settings on ${node}."
    resume_kernel "$node"
  done
  phase_done 7 "Kernel settings and reboots were verified on all nodes."

  phase_start 8 "Configure UFW on every node: retain SSH, permit documented public endpoints, and restrict cluster traffic to the three private node IPs."
  for node in "$NODE0_NAME" "$NODE1_NAME" "$NODE2_NAME"; do
    configure_ufw_multi_node "$node" "$GCP_ZONE" "$GCP_PROJECT" "$(get_state "${NODE0_NAME}_private_ip")" "$(get_state "${NODE1_NAME}_private_ip")" "$(get_state "${NODE2_NAME}_private_ip")"
  done
  phase_done 8 "Host firewall rules were applied on all nodes."

  phase_start 9 "Format only blank data disks, create documented mount paths, persist /etc/fstab entries, and verify mounts."
  resume_mount "$NODE0_NAME" disk-objects /mnt/instana/stanctl/objects
  resume_mount "$NODE1_NAME" disk-data /mnt/instana/stanctl/data
  resume_mount "$NODE1_NAME" disk-metrics /mnt/instana/stanctl/metrics
  resume_mount "$NODE1_NAME" disk-analytics /mnt/instana/stanctl/analytics
  lab_checkpoint disks_mounted
  phase_done 9 "All multi-node storage paths are mounted."

  phase_start 10 "Authenticate to the Instana APT repository, import its signing key, and install stanctl on node0. Secrets are not stored in state or logs."
  resume_install_stanctl
  lab_checkpoint stanctl_installed
  phase_done 10 "stanctl is installed on node0."

  phase_start 11 "Run stanctl up --multi-node-enable from node0 and let it build the Kubernetes cluster, data stores and backend applications."
  resume_stanctl_up
  phase_done 11 "Multi-node Instana installation completed."

  phase_start 12 "Verify three Ready Kubernetes nodes and Instana workloads, then print local hosts-file instructions for macOS, Linux and Windows."
  if [[ "$DRY_RUN" != true ]]; then
    remote_exec "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" 'set -e; kubectl wait --for=condition=Ready nodes --all --timeout=600s; test "$(kubectl get nodes -o name | wc -l)" -eq 3'
    post_install_health_check "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
    configure_kubectl_user_access "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  fi
  lab_checkpoint completed
  ip=DRY-RUN
  [[ "$DRY_RUN" == true ]] || ip=$(gcloud compute instances describe "$NODE0_NAME" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
  print_final_report "$ip"
  phase_done 12 "Cluster health and local access instructions completed."
  progress_summary
}
