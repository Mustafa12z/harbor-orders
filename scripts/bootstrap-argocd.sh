#!/usr/bin/env bash
# Bootstrap Argo CD into the current kubectl context for one environment, then
# apply shared platform apps + that env's Application. Idempotent (kubectl apply).
#
# Usage:
#   scripts/bootstrap-argocd.sh <dev|staging|prod>
#
# Optional env (private repos — prefer SSH deploy key):
#   ARGOCD_REPO_SSH_KEY  OpenSSH private key for a read-only GitHub deploy key
#   ARGOCD_REPO_TOKEN    HTTPS PAT fallback (discouraged; prefer deploy key)
#   GH_TOKEN             Short-lived HTTPS fallback for the job only
set -euo pipefail

ENV="${1:-}"
case "$ENV" in
  dev|staging|prod) ;;
  *)
    echo "Usage: $0 <dev|staging|prod>" >&2
    exit 1
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SSH_URL="${ARGOCD_REPO_SSH_URL:-git@github.com:Mustafa12z/gke-microservices.git}"
REPO_HTTPS_URL="${ARGOCD_REPO_HTTPS_URL:-https://github.com/Mustafa12z/gke-microservices.git}"

echo "Creating argocd namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# v3.3.4+ required for GKE 1.35 (status.terminatingReplicas in Deployment schema).
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.3.4}"
echo "Installing Argo CD (${ARGOCD_VERSION})..."
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Autopilot scheduling can outlive the default ProgressDeadlineSeconds (600s)
# from a prior partial install, leaving rollouts already "exceeded". Restart and
# wait longer so a re-run can finish.
echo "Waiting for core Argo CD workloads (Autopilot can take several minutes)..."
for deploy in argocd-redis argocd-repo-server argocd-server \
  argocd-applicationset-controller argocd-dex-server; do
  kubectl -n argocd patch "deploy/${deploy}" \
    --type=merge -p '{"spec":{"progressDeadlineSeconds":900}}' >/dev/null 2>&1 || true
done
kubectl -n argocd rollout restart deploy/argocd-redis deploy/argocd-repo-server deploy/argocd-server \
  deploy/argocd-applicationset-controller deploy/argocd-dex-server \
  statefulset/argocd-application-controller 2>/dev/null || true

for deploy in argocd-redis argocd-repo-server argocd-server; do
  echo "Waiting for ${deploy}..."
  kubectl -n argocd rollout status "deploy/${deploy}" --timeout=900s
done
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=900s

# Private-repo credentials. Prefer durable SSH deploy key over HTTPS tokens.
if [ -n "${ARGOCD_REPO_SSH_KEY:-}" ]; then
  echo "Configuring Argo CD repository credentials (SSH deploy key) for ${REPO_SSH_URL}..."
  # shellcheck disable=SC2016
  kubectl -n argocd create secret generic repo-gke-microservices \
    --from-literal=type=git \
    --from-literal=url="${REPO_SSH_URL}" \
    --from-file=sshPrivateKey=<(printf '%s\n' "$ARGOCD_REPO_SSH_KEY") \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n argocd label secret repo-gke-microservices \
    argocd.argoproj.io/secret-type=repository --overwrite
elif TOKEN="${ARGOCD_REPO_TOKEN:-${GH_TOKEN:-}}"; [ -n "$TOKEN" ]; then
  echo "Configuring Argo CD repository credentials (HTTPS token) for ${REPO_HTTPS_URL}..."
  kubectl -n argocd create secret generic repo-gke-microservices \
    --from-literal=type=git \
    --from-literal=url="${REPO_HTTPS_URL}" \
    --from-literal=username=git \
    --from-literal=password="${TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n argocd label secret repo-gke-microservices \
    argocd.argoproj.io/secret-type=repository --overwrite
else
  echo "No ARGOCD_REPO_SSH_KEY/ARGOCD_REPO_TOKEN/GH_TOKEN set; assuming public repo access."
fi

echo "Applying AppProject + bootstrap apps + ${ENV} Application..."
kubectl apply -f "${ROOT}/gitops/appproject.yaml"
kubectl apply -f "${ROOT}/gitops/bootstrap/"
kubectl apply -f "${ROOT}/gitops/applications/${ENV}.yaml"

echo
echo "Bootstrap complete for env=${ENV}."
echo "Argo CD will reconcile bootstrap components and harbor-orders-${ENV}."
echo "Initial admin password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo
echo "Port-forward UI: kubectl -n argocd port-forward svc/argocd-server 8080:443"
