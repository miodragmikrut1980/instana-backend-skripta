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
  [[ "$(get_state deployment_manifest)" == "$manifest" ]] ||
    die_with_steps "The saved parameters in .install-config.json differ from the ones this deployment was started with; no resources were changed." \
      "Compare the recorded and the current parameters:|jq -r .deployment_manifest .install-state.json; jq -cS .parameters .install-config.json" \
      "Restore the original .install-config.json (from a copy of this folder), then continue:|./install.sh --resume" \
      "*Or remove that deployment first: ./install.sh --destroy"
  # A stanctl up that was running or failed is not repeated blindly:
  # resume_stanctl_up checks node0 first (running stanctl, cluster, Core/Unit).
  case "$(get_state stanctl_up_status)" in
    running|failed) warn "The last stanctl up on ${NODE0_NAME} did not record success; phase 11 checks the cluster on ${NODE0_NAME} before anything is started again." ;;
  esac
  # RESUME may have been switched on only now (answer "resume" to the existing
  # state prompt), after the parameters were loaded: check the package here too.
  [[ "$INSTALL_MODE" != air-gapped ]] || verify_airgap_archive_matches_state
}

initialize_multinode_state() {
  [[ "$DRY_RUN" == true ]] && return 0
  if [[ "$RESUME" != true ]]; then
    DEPLOYMENT_ID=$(tr -d - </proc/sys/kernel/random/uuid)
    save_state deployment_id "$DEPLOYMENT_ID"
    save_state deployment_manifest "$(jq -cS .parameters "$CONFIG_FILE")"
  fi
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
  provider_check_blank_disk "$node" "$device"
  remote_exec "$node" "$GCP_ZONE" "$GCP_PROJECT" "set -euo pipefail
    dev=$(provider_disk_device_path "$node" "$device")
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
  if [[ "$INSTALL_MODE" == air-gapped ]]; then
    # Resume-aware on its own: verifies a recorded import, reuses a matching copy.
    install_stanctl_airgapped "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  elif [[ "$RESUME" == true && "$(get_state step_stanctl_installed)" == completed ]]; then
    remote_exec "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" 'set -e; command -v stanctl >/dev/null; st=$(dpkg-query -W -f="\${Status}" stanctl); echo "stanctl $(stanctl --version 2>/dev/null | head -1): package status \"$st\""; echo "$st" | grep -q "ok installed"'
  else
    add_instana_repository "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
    install_stanctl "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT"
  fi
}

resume_stanctl_up() {
  local status
  status=$(get_state stanctl_up_status)
  if [[ "$RESUME" == true && "$status" == completed ]]; then
    ok 'stanctl up previously succeeded; rechecking readiness without reinstalling.'
    return 0
  fi
  PHASE11_NOTE="Multi-node Instana installation completed."
  # Started before but no recorded success: check node0 first; 0 = Instana is
  # up, 1 = run stanctl up (no cluster and no stanctl there, or
  # INSTANA_RERUN_STANCTL_UP=yes); anything else stops with HOW TO RESOLVE.
  if [[ "$RESUME" == true && ( "$status" == running || "$status" == failed ) ]]; then
    resume_after_stanctl_up "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" 3 && return 0
  fi
  [[ "$DRY_RUN" == true ]] || save_state stanctl_up_status running
  run_stanctl_up_multi_node "$NODE0_NAME" "$GCP_ZONE" "$GCP_PROJECT" "$(get_state "${NODE0_NAME}_private_ip"),$(get_state "${NODE1_NAME}_private_ip"),$(get_state "${NODE2_NAME}_private_ip")"
  save_state stanctl_up_status completed
}
