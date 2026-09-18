#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/install.sh"
DRY_RUN=false
TOPOLOGY=single-node
INSTALL_MODE=online
GCP_ZONE=us-central1-a
GCP_REGION=us-central1
GCP_SUBNET=default
save_state() { :; }
save_parameters() { :; }
deployment_has_resources() { return 1; }
placement_command() {
  if [[ "$3" == europe-west1-b ]]; then echo 'MOCK VM CREATED'; return 0; fi
  echo 'code: ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS'
  return 1
}
gcloud() {
  if [[ "$*" == *'zones list'* ]]; then
    echo '[{"name":"us-central1-a","region":"x/us-central1"},{"name":"us-central1-b","region":"x/us-central1"},{"name":"europe-west1-b","region":"x/europe-west1"}]'
  else
    echo '[{"name":"default","region":"x/us-central1"},{"name":"default","region":"x/europe-west1"}]'
  fi
}
create_vm test n2-standard-16 us-central1-a project default default ubuntu
test "$GCP_ZONE" = europe-west1-b
test "$GCP_REGION" = europe-west1
echo 'PASS: stockout across initial region -> successful alternative region'
if (placement_command() { echo 'PERMISSION_DENIED'; return 1; }; create_vm test n2-standard-16 us-central1-a project default default ubuntu) >/dev/null 2>&1; then exit 1; fi
echo 'PASS: permission errors do not trigger fallback'
if (deployment_has_resources() { return 0; }; create_vm test n2-standard-16 us-central1-a project default default ubuntu) >/dev/null 2>&1; then exit 1; fi
echo 'PASS: partial infrastructure prohibits relocation'
