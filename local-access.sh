#!/usr/bin/env bash
valid_public_ipv4() {
  local ip="$1" octet
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local parts
  IFS=. read -r -a parts <<< "$ip"
  for octet in "${parts[@]}"; do (( 10#$octet <= 255 )) || return 1; done
  [[ "$ip" != 0.0.0.0 ]] || return 1
}

print_local_access() {
  local detected="$1" node ip ui_ip='' default answer
  [[ "$DRY_RUN" != true ]] || { echo 'Local hosts instructions will use confirmed public IPv4 at the end of a real installation.'; return 0; }
  # Only node 0 is used (UI, gateway, acceptors). Its public IP is taken as
  # detected (GCP external IP, or the existing host's public / external IP);
  # it is asked only when it is not known.
  local nodes=("${VM_NAME:-}")
  [[ "$TOPOLOGY" != three-node ]] || nodes=("$NODE0_NAME")
  echo
  for node in "${nodes[@]}"; do
    default="$detected"
    [[ "$default" != unknown ]] || default=''
    if valid_public_ipv4 "$default"; then
      ip="$default"
      echo "Public IPv4 of ${node}: ${ip} (detected; used for the /etc/hosts lines below)."
      ui_ip="$ip"
      save_state "public_ip_${node}" "$ip"
      continue
    fi
    echo "$(provider_text_or ip_confirm_line 'Confirm public IPv4 addresses. Enter accepts the GCP value.')"
    echo "The public IPv4 of ${node} could not be detected; type it (or skip)."
    while true; do
      if ! read -rp "Public IPv4 of $node [$default] (or skip): " answer; then
        answer="$default"
        if ! valid_public_ipv4 "$answer"; then echo 'No confirmed public IP; local access instructions skipped.'; return 0; fi
      fi
      [[ "$answer" != skip ]] || { echo 'Local access instructions skipped; installation remains unchanged.'; return 0; }
      ip="${answer:-$default}"
      valid_public_ipv4 "$ip" && break
      echo 'Invalid IPv4 address. Example: 34.66.50.241'
    done
    [[ -n "$ui_ip" ]] || ui_ip="$ip"
    save_state "public_ip_${node}" "$ip"
  done
  CONFIRMED_UI_IP="$ui_ip"
  echo
  echo 'LOCAL ACCESS — edit hosts on YOUR workstation, not on the installer VM.'
  echo 'For multinode all entries use NODE0 (UI/gateway/acceptors), not node1/node2.'
  echo 'Replace existing entries for these exact names; do not leave conflicting duplicates.'
  printf '\nPaste these entries:\n'
  printf '%s %s\n' "$ui_ip" "$BASE_DOMAIN" \
    "$ui_ip" "${UNIT_NAME}-${TENANT_NAME}.${BASE_DOMAIN}" \
    "$ui_ip" "agent-acceptor.${BASE_DOMAIN}" \
    "$ui_ip" "opamp-acceptor.${BASE_DOMAIN}" \
    "$ui_ip" "otlp-http.${BASE_DOMAIN}" \
    "$ui_ip" "otlp-grpc.${BASE_DOMAIN}"
  printf '\nmacOS — Terminal:\nsudo nano /etc/hosts\nSave: Ctrl+O, Enter; exit: Ctrl+X. Then:\nsudo dscacheutil -flushcache\nsudo killall -HUP mDNSResponder\n'
  printf '\nWindows — open Notepad as Administrator, File > Open:\nC:\\Windows\\System32\\drivers\\etc\\hosts\nSelect All files; save as hosts, NOT hosts.txt. Administrator terminal:\nipconfig /flushdns\n'
  printf '\nLinux — terminal:\nsudo nano /etc/hosts\nSave: Ctrl+O, Enter; exit: Ctrl+X. If systemd-resolved is active:\nsudo resolvectl flush-caches\nOtherwise use your resolver cache service or reopen the browser.\n'
  printf '\nOpen: https://%s-%s.%s\n' "$UNIT_NAME" "$TENANT_NAME" "$BASE_DOMAIN"
  echo 'Self-signed TLS may show a certificate warning. Hosts changes affect only this workstation; they do not configure DNS for the backend or other agents.'
  echo 'Check public IP after VM stop/start; an ephemeral IP may change. Browser Secure DNS/proxy settings may require separate checking if resolution differs.'
}
