#!/usr/bin/env bash
collect_cpu_ram() {
  local cpu_var="$1" ram_var="$2" min_cpu="$3" min_ram="$4" label="$5"
  local cpu ram selection
  while true; do
    cpu=$(prompt "$cpu_var" "Number of vCPUs ($label)" "$min_cpu") || die "CPU input closed; cancelled."
    ram=$(prompt "$ram_var" "RAM in GB ($label)" "$min_ram") || die "RAM input closed; cancelled."
    if [[ "$cpu" =~ ^[0-9]{1,9}$ && "$ram" =~ ^[0-9]{1,9}$ ]]; then
      cpu=$((10#$cpu)); ram=$((10#$ram))
      if (( cpu >= min_cpu && ram >= min_ram )); then
        printf -v "$cpu_var" '%s' "$cpu"
        printf -v "$ram_var" '%s' "$ram"
        return 0
      fi
    fi
    warn "Invalid hardware for $label: CPU=$cpu, RAM=$ram GB. Minimum: $min_cpu vCPU / $min_ram GB. Use positive whole numbers."
    selection=$(prompt_choice "Hardware input is invalid. Choose:" "re-enter CPU and RAM" "cancel installation") || die "Selection closed; cancelled."
    [[ "$selection" == "re-enter CPU and RAM" ]] || die "Installation cancelled by user."
  done
}
