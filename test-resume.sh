#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/install.sh"
RESUME=true
DRY_RUN=false
DEPLOYMENT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
GCP_PROJECT=test
GCP_ZONE=zone-a
GCP_NETWORK=default
GCP_SUBNET=default
NODE0_NAME=node0
get_state() { case "$1" in step_kernel_node0|stanctl_up_status) echo completed;; esac; }
save_state() { :; }
create_vm() { echo 'FAIL: unexpected resource create' >&2; exit 1; }
gcloud() {
  printf '%s\n' '{"labels":{"instana-lab-id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"status":"RUNNING","machineType":"x/n2-standard-16","networkInterfaces":[{"network":"x/default","subnetwork":"x/default"}]}'
}
resume_create_vm node0 n2-standard-16 zone-a test default default ubuntu
echo 'PASS: verified VM reused without create'
if (DEPLOYMENT_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; resume_create_vm node0 n2-standard-16 zone-a test default default ubuntu) >/dev/null 2>&1; then exit 1; fi
echo 'PASS: mismatched resource ownership rejected'
lab_kernel() { echo 'FAIL: unexpected reboot' >&2; exit 1; }
remote_exec() { [[ "$4" == *'sysctl -n vm.swappiness'* ]]; }
resume_kernel node0
echo 'PASS: completed kernel validated without reboot'
run_stanctl_up_multi_node() { echo 'FAIL: unexpected installer rerun' >&2; exit 1; }
resume_stanctl_up
echo 'PASS: completed stanctl skipped for readiness-only continuation'
if (get_state() { echo legacy; }; validate_multinode_resume) >/dev/null 2>&1; then exit 1; fi
echo 'PASS: missing/legacy state fails closed'
