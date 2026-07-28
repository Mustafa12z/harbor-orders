#!/usr/bin/env bash
# Smoke-test the orders stack already deployed on GKE.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NAMESPACE="${NAMESPACE:-orders}"
TIMEOUT_SECS="${TIMEOUT_SECS:-180}"
ENV="${ENV:-dev}"
TF_DIR="terraform/environments/${ENV}"

DEPLOYMENTS="api-gateway order-service inventory-service payment-service notification-service shipping-service worker scheduler dashboard-api"

PASS=0
FAIL=0
PF_PIDS=""

log()  { printf '==> %s\n' "$*"; }
ok()   { printf '  OK  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

cleanup() {
  for p in $PF_PIDS; do
    kill "$p" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

service_port() {
  case "$1" in
    api-gateway) echo 8080 ;;
    order-service) echo 8081 ;;
    inventory-service) echo 8082 ;;
    payment-service) echo 8083 ;;
    notification-service) echo 8084 ;;
    shipping-service) echo 8085 ;;
    dashboard-api) echo 8086 ;;
    worker) echo 8090 ;;
    scheduler) echo 8091 ;;
    *) return 1 ;;
  esac
}

wait_http() {
  url="$1"
  secs="${2:-60}"
  i=1
  while [ "$i" -le "$secs" ]; do
    if curl -sf --max-time 2 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

log "GKE cluster smoke (namespace=$NAMESPACE)"

if ! kubectl -n "$NAMESPACE" get ns >/dev/null 2>&1; then
  fail "namespace $NAMESPACE not reachable — run: make kubeconfig ENV=$ENV"
  exit 1
fi

for d in $DEPLOYMENTS; do
  log "Waiting for deploy/$d"
  if kubectl -n "$NAMESPACE" rollout status "deploy/$d" --timeout="${TIMEOUT_SECS}s"; then
    ok "deploy/$d Ready"
  else
    fail "deploy/$d not Ready"
    kubectl -n "$NAMESPACE" describe "deploy/$d" | tail -40 || true
    continue
  fi

  image="$(kubectl -n "$NAMESPACE" get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [ -n "$image" ] && docker image inspect "$image" >/dev/null 2>&1; then
    arch="$(docker image inspect "$image" --format '{{.Architecture}}')"
    if [ "$arch" = "amd64" ]; then
      ok "$d image arch amd64"
    else
      fail "$d image arch is $arch (want amd64)"
    fi
  elif [ -n "$image" ]; then
    ok "$d image ref: $image"
  fi

  port="$(service_port "$d")"
  local_port=$((18000 + port))
  kubectl -n "$NAMESPACE" port-forward "deploy/$d" "${local_port}:${port}" >/dev/null 2>&1 &
  pf_pid=$!
  PF_PIDS="$PF_PIDS $pf_pid"
  sleep 2

  url="http://127.0.0.1:${local_port}/healthz"
  if wait_http "$url" 45; then
    ok "$d /healthz → $(curl -sf "$url")"
  else
    fail "$d /healthz via port-forward failed"
    kubectl -n "$NAMESPACE" logs "deploy/$d" --tail=30 || true
  fi
  kill "$pf_pid" >/dev/null 2>&1 || true
done

for ss in postgres redis; do
  if kubectl -n "$NAMESPACE" get "statefulset/$ss" >/dev/null 2>&1; then
    if kubectl -n "$NAMESPACE" rollout status "statefulset/$ss" --timeout="${TIMEOUT_SECS}s"; then
      ok "statefulset/$ss Ready"
    else
      fail "statefulset/$ss not Ready"
    fi
  fi
done

ip="$(kubectl -n "$NAMESPACE" get ingress orders -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [ -n "$ip" ]; then
  if wait_http "http://${ip}/healthz" 60; then
    ok "Ingress http://${ip}/healthz → $(curl -sf "http://${ip}/healthz")"
  else
    fail "Ingress http://${ip}/healthz failed"
  fi
else
  log "Ingress ADDRESS not ready yet — skip external /healthz"
fi

if [ -d "$TF_DIR" ] && terraform -chdir="$TF_DIR" output -raw artifact_registry_url >/dev/null 2>&1; then
  ok "Artifact Registry: $(terraform -chdir="$TF_DIR" output -raw artifact_registry_url)"
fi

echo
log "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
