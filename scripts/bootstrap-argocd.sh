#!/usr/bin/env bash
# Bootstrap Argo CD (Helm) + ESO-synced repo/OAuth secrets + Ingress, then apply
# AppProject and the environment Application.
#
# Usage:
#   scripts/bootstrap-argocd.sh <dev|staging|prod>
#
# Prerequisites:
#   - kubectl context for the target GKE cluster
#   - helm 3.x
#   - Terraform applied (Argo static IP/DNS, GSM secret shells, WI for argocd/secret-reader)
#   - Prefer GSM versions seeded:
#       orders[-suffix]-argocd-repo-ssh-key  (raw OpenSSH private key)
#       orders[-suffix]-argocd-google-oauth  (JSON: {"clientID":"...","clientSecret":"..."})
#   - Optional CI fallback: ARGOCD_REPO_SSH_KEY (creates the repo secret if ESO has not)
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
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-9.5.11}"
REPO_SSH_URL="${ARGOCD_REPO_SSH_URL:-git@github.com:Mustafa12z/harbor-orders.git}"
case "$ENV" in
  dev) ARGOCD_HOST="argocd.dev.order.mustafamirreh.com" ;;
  staging) ARGOCD_HOST="argocd.staging.order.mustafamirreh.com" ;;
  prod) ARGOCD_HOST="argocd.prod.order.mustafamirreh.com" ;;
esac

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required (install Helm 3 before running bootstrap)." >&2
  exit 1
fi

echo "Creating argocd namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Prior kubectl-apply installs leave last-applied-configuration annotations that
# exceed the 256KiB limit on large CRDs (applicationsets). Strip them so Helm
# can adopt/update cleanly.
echo "Clearing oversized last-applied annotations on Argo CRDs (if any)..."
for crd in applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io; do
  kubectl annotate crd "$crd" kubectl.kubernetes.io/last-applied-configuration- --overwrite >/dev/null 2>&1 || true
done

# Manifest install uses different immutable selectors than the Helm chart.
# Wipe leftovers whenever there is no healthy Helm release yet.
ARGO_STATUS="$(helm status argocd --namespace argocd -o json 2>/dev/null | jq -r '.info.status // empty' || true)"
if [ "$ARGO_STATUS" != "deployed" ]; then
  if kubectl get namespace argocd >/dev/null 2>&1 && \
     kubectl -n argocd get deploy,statefulset 2>/dev/null | grep -q argocd; then
    echo "Removing previous Argo CD install (status=${ARGO_STATUS:-none}; selectors incompatible with Helm)..."
    for kind in applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io; do
      kubectl -n argocd get "$kind" -o name 2>/dev/null | while read -r res; do
        kubectl -n argocd patch "$res" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      done
    done
    helm uninstall argocd --namespace argocd --wait --timeout 2m >/dev/null 2>&1 || true
    kubectl delete namespace argocd --wait=true --timeout=180s 2>/dev/null || true
    # If the namespace is stuck terminating, drop its finalizers.
    if kubectl get namespace argocd >/dev/null 2>&1; then
      kubectl get namespace argocd -o json \
        | jq '.spec.finalizers=[]' \
        | kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f - >/dev/null 2>&1 || true
      for _ in $(seq 1 30); do
        kubectl get namespace argocd >/dev/null 2>&1 || break
        sleep 2
      done
    fi
    for name in argocd-application-controller argocd-applicationset-controller argocd-server; do
      kubectl delete clusterrole "$name" --ignore-not-found >/dev/null 2>&1 || true
      kubectl delete clusterrolebinding "$name" --ignore-not-found >/dev/null 2>&1 || true
    done
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  fi
fi

echo "Installing Argo CD via Helm (chart ${ARGOCD_CHART_VERSION})..."
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "${ARGOCD_CHART_VERSION}" \
  --values "${ROOT}/gitops/argocd/values.yaml" \
  --values "${ROOT}/gitops/argocd/values-${ENV}.yaml" \
  --take-ownership \
  --wait \
  --timeout 15m

echo "Applying ESO + Argo Rollouts Applications..."
kubectl apply -f "${ROOT}/gitops/bootstrap/external-secrets.yaml"
kubectl apply -f "${ROOT}/gitops/bootstrap/argo-rollouts.yaml"

echo "Waiting for External Secrets Operator..."
# Namespace/CRDs appear after Argo syncs the Application (public Helm chart; no repo creds needed).
for _ in $(seq 1 60); do
  if kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
kubectl get crd externalsecrets.external-secrets.io >/dev/null
kubectl -n external-secrets wait --for=condition=available deploy --all --timeout=600s || \
  kubectl -n external-secrets rollout status deploy --timeout=600s

echo "Applying Argo CD SecretStore / ExternalSecrets for ${ENV}..."
kubectl apply -f "${ROOT}/gitops/argocd/secrets/${ENV}.yaml"

ensure_repo_secret() {
  if kubectl -n argocd get secret repo-harbor-orders >/dev/null 2>&1; then
    return 0
  fi
  if [ -z "${ARGOCD_REPO_SSH_KEY:-}" ]; then
    return 1
  fi
  echo "ESO has not synced repo-harbor-orders yet; creating from ARGOCD_REPO_SSH_KEY..."
  kubectl -n argocd create secret generic repo-harbor-orders \
    --from-literal=type=git \
    --from-literal=url="${REPO_SSH_URL}" \
    --from-file=sshPrivateKey=<(printf '%s\n' "$ARGOCD_REPO_SSH_KEY") \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n argocd label secret repo-harbor-orders \
    argocd.argoproj.io/secret-type=repository --overwrite
}

echo "Waiting for repo secret (ESO, with CI fallback)..."
REPO_OK=0
for _ in $(seq 1 36); do
  if kubectl -n argocd get secret repo-harbor-orders >/dev/null 2>&1; then
    REPO_OK=1
    break
  fi
  # After ~10s, try env fallback so bootstrap is not blocked on empty GSM shells.
  if [ "${_}" -ge 2 ]; then
    if ensure_repo_secret; then
      REPO_OK=1
      break
    fi
  fi
  sleep 5
done
if [ "$REPO_OK" -ne 1 ]; then
  ensure_repo_secret || true
fi
kubectl -n argocd get secret repo-harbor-orders >/dev/null

echo "Checking Google OAuth secret keys (optional until GSM is seeded)..."
OAUTH_OK=0
for _ in $(seq 1 12); do
  if kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.dex\.google\.clientID}' 2>/dev/null | grep -q .; then
    # Treat chart placeholders as "not ready" so we keep waiting for ESO merge.
    cid="$(kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.dex\.google\.clientID}' | base64 -d 2>/dev/null || true)"
    if [ -n "$cid" ] && [ "$cid" != "replace-me" ]; then
      OAUTH_OK=1
      break
    fi
  fi
  sleep 5
done
if [ "$OAUTH_OK" -ne 1 ]; then
  echo "WARNING: dex.google.clientID not synced from GSM yet; Google login will not work until orders-*-argocd-google-oauth is seeded." >&2
fi

echo "Applying Argo CD Ingress + ManagedCertificate..."
kubectl apply -f "${ROOT}/gitops/argocd/ingress/${ENV}.yaml"

echo "Applying AppProject + ${ENV} Application..."
kubectl apply -f "${ROOT}/gitops/appproject.yaml"
kubectl apply -f "${ROOT}/gitops/applications/${ENV}.yaml"

echo
echo "Bootstrap complete for env=${ENV}."
echo "Argo CD UI: https://${ARGOCD_HOST}"
echo "Log in with Google as mustafa.mirreh10@gmail.com (after OAuth GSM is seeded)."
echo "Break-glass admin password (if needed):"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
