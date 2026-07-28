#!/usr/bin/env bash
# Tear down in-cluster workloads (especially GCE Ingress / NEGs) before terraform destroy.
# Safe to run when the cluster is already gone — still sweeps orphan GCE LB objects
# (backend services, health checks, NEGs) and k8s-* firewalls that pin the VPC.
#
# Env:
#   ENV, TF_DIR, NAMESPACE, PROJECT, NETWORK, NEG_WAIT_SECS
#   FIREWALL_ONLY=1  — skip kubectl; sweep orphan GCE LB + firewalls on NETWORK
set -euo pipefail

ENV="${ENV:-dev}"
TF_DIR="${TF_DIR:-terraform/environments/${ENV}}"
NAMESPACE="${NAMESPACE:-orders}"
NEG_WAIT_SECS="${NEG_WAIT_SECS:-180}"
FIREWALL_ONLY="${FIREWALL_ONLY:-0}"

log() { printf '%s\n' "$*"; }

tf_out() {
  terraform -chdir="${TF_DIR}" output -raw "$1" 2>/dev/null || true
}

# GKE's ingress/service controllers create k8s-* health check and node port rules
# outside Terraform. Cluster delete does not always remove them, and GLBC can
# recreate L7 rules while the cluster is tearing down — so callers should sweep
# again after a failed VPC delete.
sweep_firewall_rules() {
  local project="$1"
  local network="$2"
  if [ -z "${project}" ] || [ -z "${network}" ]; then
    log "Cannot sweep firewalls (project='${project}' network='${network}')."
    return 0
  fi

  log "Sweeping GKE-managed firewall rules on ${network}..."
  local rules
  rules="$(gcloud compute firewall-rules list \
    --project="${project}" \
    --filter="network~/${network}$ AND name~^k8s-" \
    --format="value(name)" 2>/dev/null || true)"

  if [ -z "${rules}" ]; then
    log "No GKE-managed firewall rules left on ${network}."
    return 0
  fi

  while read -r rule; do
    [ -z "${rule}" ] && continue
    log "Deleting firewall rule ${rule}..."
    gcloud compute firewall-rules delete "${rule}" \
      --project="${project}" \
      --quiet || true
  done <<<"${rules}"
}

# NEGs cannot be deleted while referenced by backend services. After Ingress /
# cluster teardown, orphan k8s1-* backends + health checks often remain and pin
# the VPC via zonal NEGs.
sweep_gce_lb_orphans() {
  local project="$1"
  local network="$2"
  if [ -z "${project}" ] || [ -z "${network}" ]; then
    log "Cannot sweep GCE LB orphans (project='${project}' network='${network}')."
    return 0
  fi

  log "Sweeping orphan GCE backend services tied to NEGs on ${network}..."
  local backends
  backends="$(gcloud compute backend-services list \
    --project="${project}" \
    --format="value(name)" 2>/dev/null || true)"

  while read -r bs; do
    [ -z "${bs}" ] && continue
    # Backend group URLs omit the VPC; resolve each NEG's network.
    local groups match=0 neg_ref neg_name neg_zone neg_net
    groups="$(gcloud compute backend-services describe "${bs}" \
      --project="${project}" \
      --global \
      --format="value(backends[].group)" 2>/dev/null || true)"
    [ -z "${groups}" ] && continue
    printf '%s' "${groups}" | grep -q "networkEndpointGroups/" || continue

    for neg_ref in ${groups}; do
      neg_name="${neg_ref##*/}"
      neg_zone="$(printf '%s' "${neg_ref}" | sed -n 's|.*/zones/\([^/]*\)/networkEndpointGroups/.*|\1|p')"
      [ -z "${neg_zone}" ] && continue
      neg_net="$(gcloud compute network-endpoint-groups describe "${neg_name}" \
        --project="${project}" \
        --zone="${neg_zone}" \
        --format="value(network)" 2>/dev/null || true)"
      if printf '%s' "${neg_net}" | grep -q "/${network}$"; then
        match=1
        break
      fi
    done
    [ "${match}" -eq 1 ] || continue

    log "Deleting backend service ${bs}..."
    gcloud compute backend-services delete "${bs}" \
      --project="${project}" \
      --global \
      --quiet || true
  done <<<"${backends}"

  log "Sweeping orphan GKE health checks (k8s1-*)..."
  local hcs
  hcs="$(gcloud compute health-checks list \
    --project="${project}" \
    --filter="name~^k8s1-" \
    --format="value(name)" 2>/dev/null || true)"
  while read -r hc; do
    [ -z "${hc}" ] && continue
    log "Deleting health check ${hc}..."
    gcloud compute health-checks delete "${hc}" \
      --project="${project}" \
      --quiet || true
  done <<<"${hcs}"

  log "Sweeping Network Endpoint Groups on ${network}..."
  local neg_list
  neg_list="$(gcloud compute network-endpoint-groups list \
    --project="${project}" \
    --filter="network~/${network}$" \
    --format="csv[no-heading](name,zone.basename())" 2>/dev/null || true)"

  if [ -z "${neg_list}" ]; then
    log "No NEGs left on ${network}."
  else
    while IFS=, read -r name zone; do
      [ -z "${name}" ] && continue
      zone="${zone##*/}"
      log "Deleting NEG ${name} (${zone})..."
      gcloud compute network-endpoint-groups delete "${name}" \
        --project="${project}" \
        --zone="${zone}" \
        --quiet || true
    done <<<"${neg_list}"

    local elapsed=0
    while [ "${elapsed}" -lt "${NEG_WAIT_SECS}" ]; do
      local left
      left="$(gcloud compute network-endpoint-groups list \
        --project="${project}" \
        --filter="network~/${network}$" \
        --format="value(name)" 2>/dev/null | wc -l | tr -d '[:space:]')"
      if [ "${left}" -eq 0 ]; then
        log "All NEGs cleared."
        break
      fi
      log "Waiting for ${left} NEG(s) to finish deleting..."
      sleep 5
      elapsed=$((elapsed + 5))
    done

    if [ "${elapsed}" -ge "${NEG_WAIT_SECS}" ]; then
      log "Warning: some NEGs may still exist; terraform destroy might fail on the VPC."
    fi
  fi
}

sweep_vpc_orphans() {
  local project="$1"
  local network="$2"
  sweep_gce_lb_orphans "${project}" "${network}"
  sweep_firewall_rules "${project}" "${network}"
}

# Prefer live Terraform outputs; fall back so a partial destroy can still sweep.
PROJECT="${PROJECT:-$(tf_out project_id)}"
PROJECT="${PROJECT:-${GOOGLE_CLOUD_PROJECT:-${CLOUDSDK_CORE_PROJECT:-}}}"
NETWORK="${NETWORK:-$(tf_out network_name)}"
case "${ENV}" in
  staging) NETWORK="${NETWORK:-gke-orders-staging-vpc}" ;;
  prod) NETWORK="${NETWORK:-gke-orders-prod-vpc}" ;;
  *) NETWORK="${NETWORK:-gke-orders-vpc}" ;;
esac

if [ "${FIREWALL_ONLY}" = "1" ]; then
  sweep_vpc_orphans "${PROJECT}" "${NETWORK}"
  exit 0
fi

CLUSTER="$(tf_out cluster_name)"
LOCATION="$(tf_out cluster_location)"

if [ -z "${CLUSTER}" ] || [ -z "${LOCATION}" ]; then
  log "No cluster in Terraform state; sweeping orphan GCE LB / firewalls only."
  sweep_vpc_orphans "${PROJECT}" "${NETWORK}"
  exit 0
fi

# Reached on a retry after a partially failed destroy: the cluster is gone but
# its NEGs / firewalls can still be pinning the VPC.
if ! gcloud container clusters describe "${CLUSTER}" \
  --region="${LOCATION}" \
  --project="${PROJECT}" >/dev/null 2>&1; then
  log "Cluster ${CLUSTER} not found in GCP; sweeping orphan GCE LB / firewalls."
  sweep_vpc_orphans "${PROJECT}" "${NETWORK}"
  exit 0
fi

log "Fetching credentials for ${CLUSTER} (${LOCATION})..."
gcloud container clusters get-credentials "${CLUSTER}" \
  --region="${LOCATION}" \
  --project="${PROJECT}" \
  --quiet

if ! kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
  log "Namespace ${NAMESPACE} not present; nothing to delete."
else
  # Ingress owns the HTTP(S) LB and zonal NEGs that block VPC delete.
  log "Deleting Ingress in ${NAMESPACE} (releases GCE load balancer / NEGs)..."
  kubectl -n "${NAMESPACE}" delete ingress --all --wait=true --timeout=5m || true

  log "Deleting namespace ${NAMESPACE}..."
  kubectl delete namespace "${NAMESPACE}" --wait=true --timeout=10m || true

  if kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
    log "Namespace still terminating; waiting up to 90s..."
    i=0
    while [ "$i" -lt 18 ]; do
      kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || break
      sleep 5
      i=$((i + 1))
    done
  fi
fi

# Always sweep after in-cluster cleanup — backends/NEGs/HC rules often outlive
# the cluster delete and pin the VPC on terraform destroy.
sweep_vpc_orphans "${PROJECT}" "${NETWORK}"
exit 0
