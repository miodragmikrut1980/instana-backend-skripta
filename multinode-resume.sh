#!/usr/bin/env bash
# Fail closed on uncertain ownership or installer execution. No recovery deletes.
validate_multinode_resume() {
  [[ "$DRY_RUN" != true ]] || die "Resume requires actual state validation, not --dry-run."
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" && -O "$STATE_FILE" ]] || die "Missing or unsafe state file."
  DEPLOYMENT_ID=$(get_state deployment_id)
  [[ "$DEPLOYMENT_ID" =~ ^[a-f0-9]{32}$ ]] || die_with_steps "The state file in this folder is not a resumable three-node deployment (no deployment identity; probably a single-node or older state)." \
    "Run the installer without --resume and choose what to do with the old state when asked:|./install.sh" \
    "*Or remove that old deployment first: ./install.sh --destroy"
  local manifest
  manifest=$(jq -cS .parameters "$CONFIG_FILE")
  [[ "$(get_state deployment_manifest)" == "$manifest" ]] || die "Parameters differ from original deployment. Restore its saved config; no resources changed."
  if [[ "$(get_state stanctl_up_status)" == running ]]; then
    die "Previous stanctl up outcome is uncertain. Inspect node0; do not launch a second installer automatically."
  fi
}

initialize_multinode_state() {
  [[ "$DRY_RUN" == true ]] && return 0
  if [[ "$RESUME" != true ]]; then
    DEPLOYMENT_ID=$(tr -d - </proc/sys/kernel/random/uuid)
    save_state deployment_id "$DEPLOYMENT_ID"
    save_state deployment_manifest "$(jq -cS .parameters "$CONFIG_FILE")"
  fi
}

resume_create_vm() {
  local node="$1" info inspect_error vm_exists=false
  if [[ "$RESUME" != true ]]; then create_vm "$@"; return; fi
  inspect_error=$(mktemp)
  if info=$(gcloud compute instances describe "$node" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json 2>"$inspect_error"); then
    vm_exists=true
  elif grep -Eqi 'was not found|not found|could not fetch resource' "$inspect_error"; then
    vm_exists=false
  else
    rm -f "$inspect_error"
    die "Cannot inspect VM $node; access or API failure. No replacement was created."
  fi
  rm -f "$inspect_error"
  if [[ "$vm_exists" != true ]]; then
    [[ -z "$(get_state "vm_${node}")" ]] || die "Recorded VM disappeared: $node"
    create_vm "$@"; return
  fi
  jq -e --arg id "$DEPLOYMENT_ID" --arg subnet "$GCP_SUBNET" --arg network "$GCP_NETWORK" \
    '.labels["instana-lab-id"]==$id and .status=="RUNNING" and
    (.machineType|endswith("/n2-standard-16")) and
    (.networkInterfaces[0].network|endswith("/"+$network)) and
    (.networkInterfaces[0].subnetwork|endswith("/"+$subnet))' <<< "$info" >/dev/null || die "Existing VM mismatch/ownership/status: $node"
  save_state "vm_${node}" created
  ok "Reuse verified VM: $node"
}

resume_disk() {
  local node="$1" disk="$2" size="$3" device="$4" info vm attached inspect_error disk_exists=false
  if [[ "$DRY_RUN" == true ]]; then
    create_and_attach_disk "$node" "$disk" "$size" "$GCP_ZONE" "$GCP_PROJECT" "$device"; return
  fi
  inspect_error=$(mktemp)
  if info=$(gcloud compute disks describe "$disk" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json 2>"$inspect_error"); then
    disk_exists=true
  elif grep -Eqi 'was not found|not found|could not fetch resource' "$inspect_error"; then
    disk_exists=false
  else
    rm -f "$inspect_error"
    die "Cannot inspect disk $disk; access or API failure. No resource was created or changed."
  fi
  rm -f "$inspect_error"
  if [[ "$disk_exists" != true ]]; then
    [[ -z "$(get_state "disk_${disk}")" ]] || die "Recorded disk disappeared: $disk"
    run gcloud compute disks create "$disk" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --size="${size}GB" --type=pd-ssd --labels="instana-lab-id=$DEPLOYMENT_ID"
    info=$(gcloud compute disks describe "$disk" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json) || die "Created disk cannot be verified: $disk"
  fi
  jq -e --arg id "$DEPLOYMENT_ID" --argjson size "$size" --arg node "$node" \
    '.labels["instana-lab-id"]==$id and (.sizeGb|tonumber)==$size and (.type|endswith("/pd-ssd")) and .status=="READY" and
    all(.users[]?; endswith("/"+$node))' <<< "$info" >/dev/null || die "Disk ownership/size/type/attachment mismatch: $disk"
  vm=$(gcloud compute instances describe "$node" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json)
  attached=$(jq --arg disk "$disk" '[.disks[]|select(.source|endswith("/"+$disk))]' <<< "$vm")
  if [[ "$(jq length <<< "$attached")" == 0 ]]; then
    run gcloud compute instances attach-disk "$node" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --disk="$disk" --device-name="$device"
  fi
  vm=$(gcloud compute instances describe "$node" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format=json) || die "Cannot verify VM after disk attachment: $node"
  attached=$(jq --arg disk "$disk" '[.disks[]|select(.source|endswith("/"+$disk))]' <<< "$vm")
  jq -e --arg device "$device" 'length==1 and .[0].deviceName==$device and .[0].boot==false' <<< "$attached" >/dev/null || die "Unexpected or missing device attachment: $disk"
  save_state "disk_${disk}" attached
}

resume_firewalls() {
  [[ "$DRY_RUN" != true ]] || { lab_firewalls; return; }
  local suffix name info rule sources allowed ranges tags inspect_error firewall_exists
  for suffix in ssh external internal pods; do
    name="${DEPLOYMENT_TAG}-${suffix}"
    case "$suffix" in
      ssh) rule=tcp:22; sources="--source-ranges=$SSH_SOURCE_CIDR";;
      external) rule=tcp:80,tcp:443,tcp:8443; sources=--source-ranges=0.0.0.0/0;;
      internal) rule=tcp,udp,icmp; sources="--source-tags=$DEPLOYMENT_TAG";;
      pods) rule=tcp,udp,icmp; sources=--source-ranges=10.42.0.0/16,10.43.0.0/16;;
    esac
    tags='[]'
    case "$suffix" in
      ssh) allowed='[{"IPProtocol":"tcp","ports":["22"]}]'; ranges=$(jq -nc --arg c "$SSH_SOURCE_CIDR" '[$c]');;
      external) allowed='[{"IPProtocol":"tcp","ports":["80","443","8443"]}]'; ranges='["0.0.0.0/0"]';;
      internal) allowed='[{"IPProtocol":"tcp"},{"IPProtocol":"udp"},{"IPProtocol":"icmp"}]'; ranges='[]'; tags=$(jq -nc --arg t "$DEPLOYMENT_TAG" '[$t]');;
      pods) allowed='[{"IPProtocol":"tcp"},{"IPProtocol":"udp"},{"IPProtocol":"icmp"}]'; ranges='["10.42.0.0/16","10.43.0.0/16"]';;
    esac
    firewall_exists=false
    inspect_error=$(mktemp)
    if info=$(gcloud compute firewall-rules describe "$name" --project="$GCP_PROJECT" --format=json 2>"$inspect_error"); then
      firewall_exists=true
    elif ! grep -Eqi 'was not found|not found|could not fetch resource' "$inspect_error"; then
      rm -f "$inspect_error"
      die "Cannot inspect firewall $name; access or API failure."
    fi
    rm -f "$inspect_error"
    if [[ "$firewall_exists" != true ]]; then
      [[ -z "$(get_state "firewall_${name}")" ]] || die "Recorded firewall disappeared: $name"
      run gcloud compute firewall-rules create "$name" --project="$GCP_PROJECT" --network="$GCP_NETWORK" --allow="$rule" "$sources" --target-tags="$DEPLOYMENT_TAG" --description="instana-lab-id=$DEPLOYMENT_ID"
    else
      jq -e --arg id "$DEPLOYMENT_ID" --arg tag "$DEPLOYMENT_TAG" --arg network "$GCP_NETWORK" --argjson allowed "$allowed" --argjson ranges "$ranges" --argjson tags "$tags" \
        '.description==("instana-lab-id="+$id) and .disabled==false and .direction=="INGRESS" and
        (.network|endswith("/"+$network)) and .targetTags==[$tag] and
        ((.sourceRanges//[]|sort)==($ranges|sort)) and ((.sourceTags//[]|sort)==($tags|sort)) and
        ((.allowed|map(.ports=((.ports//[])|sort))|sort_by(.IPProtocol))==($allowed|map(.ports=((.ports//[])|sort))|sort_by(.IPProtocol)))' <<< "$info" >/dev/null || die "Firewall ownership or rule mismatch: $name"
    fi
    save_state "firewall_${name}" created
  done
}

resume_kernel() {
  local node="$1"
  if [[ "$RESUME" == true && "$(get_state "step_kernel_${node}")" == completed ]]; then
    remote_exec "$node" "$GCP_ZONE" "$GCP_PROJECT" 'set -e; grep -q "\[never\]" /sys/kernel/mm/transparent_hugepage/enabled; test "$(sysctl -n vm.swappiness)" = 0; test "$(sysctl -n fs.inotify.max_user_instances)" = 8192'
    ok "Kernel verified; reboot skipped on $node"
  else lab_kernel "$node"; fi
}

resume_mount() {
  local node="$1" device="$2" mountpoint="$3"
  if [[ "$DRY_RUN" == true ]]; then format_and_mount_disk "$node" "$GCP_ZONE" "$GCP_PROJECT" "$device" "$mountpoint"; return; fi
  remote_exec "$node" "$GCP_ZONE" "$GCP_PROJECT" "set -euo pipefail
    dev=/dev/disk/by-id/google-$device
    target='$mountpoint'
    test -b \"\$dev\"
    test \"\$(lsblk -nr -o NAME \"\$dev\" | wc -l)\" -eq 1 || { echo 'STOP: partitioned disk'; exit 1; }
    uuid=\$(blkid -s UUID -o value \"\$dev\" || true)
    if findmnt -rn -M \"\$target\" >/dev/null; then
      test -n \"\$uuid\"; test \"\$(findmnt -rn -M \"\$target\" -o UUID)\" = \"\$uuid\" || { echo 'STOP: wrong mounted device'; exit 1; }
      exit 0
    fi
    test -z \"\$(lsblk -nr -o MOUNTPOINT \"\$dev\" | tr -d '[:space:]')\" || { echo 'STOP: disk mounted elsewhere'; exit 1; }
    if test -n \"\$uuid\"; then
      test \"\$(blkid -s TYPE -o value \"\$dev\")\" = ext4 || { echo 'STOP: unexpected filesystem'; exit 1; }
    else
      test -z \"\$(wipefs -n --noheadings -o TYPE \"\$dev\")\" || { echo 'STOP: unknown disk signatures'; exit 1; }
      mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard \"\$dev\"
      uuid=\$(blkid -s UUID -o value \"\$dev\")
    fi
    mkdir -p \"\$target\"
    if awk -v path=\"\$target\" '\$2==path {found=1} END {exit !found}' /etc/fstab; then
      awk -v path=\"\$target\" -v src=\"UUID=\$uuid\" '\$2==path && \$1!=src {bad=1} END {exit bad}' /etc/fstab || { echo 'STOP: conflicting fstab'; exit 1; }
    else printf 'UUID=%s %s ext4 discard,defaults,nofail 0 2\\n' \"\$uuid\" \"\$target\" >> /etc/fstab; fi
    mount \"\$target\"
    test \"\$(findmnt -rn -M \"\$target\" -o UUID)\" = \"\$uuid\"
  "
  lab_checkpoint "mount_${node}_${device}"
}

resume_install_stanctl() {
  if [[ "$RESUME" == true && "$(get_state step_stanctl_installed)" == completed ]]; then
    remote_exec "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" 'set -e; command -v stanctl; dpkg-query -W -f="${Status}" stanctl | grep -q "install ok installed"'
  else
    add_instana_repository "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
    install_stanctl "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  fi
}

resume_stanctl_up() {
  if [[ "$RESUME" == true && "$(get_state stanctl_up_status)" == completed ]]; then
    ok 'stanctl up previously succeeded; rechecking readiness without reinstalling.'
    return 0
  fi
  [[ "$DRY_RUN" == true ]] || save_state stanctl_up_status running
  run_stanctl_up_multi_node "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" "$(get_state "${NODE0_NAME}_private_ip"),$(get_state "${NODE1_NAME}_private_ip"),$(get_state "${NODE2_NAME}_private_ip")"
  save_state stanctl_up_status completed
}
