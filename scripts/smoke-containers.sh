#!/usr/bin/env bash
# Smoke-test container images for GKE Autopilot (linux/amd64).
# Builds each service, asserts platform, runs /healthz in a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PLATFORM="${PLATFORM:-linux/amd64}"
TAG_PREFIX="${TAG_PREFIX:-gke-smoke}"
NETWORK="${NETWORK:-gke-smoke-net}"
PG_NAME="${PG_NAME:-gke-smoke-postgres}"
TIMEOUT_SECS="${TIMEOUT_SECS:-90}"

SERVICES="api-gateway order-service inventory-service payment-service notification-service shipping-service worker scheduler dashboard-api"

PASS=0
FAIL=0
CLEANUP_CONTAINERS=""

log()  { printf '==> %s\n' "$*"; }
ok()   { printf '  OK  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

cleanup() {
  for c in $CLEANUP_CONTAINERS; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

track() {
  CLEANUP_CONTAINERS="$CLEANUP_CONTAINERS $1"
}

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

needs_db() {
  case "$1" in
    order-service|inventory-service|payment-service|notification-service|shipping-service|scheduler|dashboard-api) return 0 ;;
    *) return 1 ;;
  esac
}

wait_http() {
  url="$1"
  secs="${2:-$TIMEOUT_SECS}"
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

assert_platform() {
  image="$1"
  arch="$(docker image inspect "$image" --format '{{.Architecture}}')"
  if [ "$arch" != "amd64" ]; then
    fail "$image architecture is '$arch' (want amd64 for GKE)"
    return 1
  fi
  ok "$image is linux/amd64"
}

build_all() {
  log "Building images for $PLATFORM"
  for svc in $SERVICES; do
    log "docker build $svc"
    docker build --platform="$PLATFORM" \
      -t "${TAG_PREFIX}/${svc}:latest" \
      "./services/${svc}"
    assert_platform "${TAG_PREFIX}/${svc}:latest" || true
  done
}

start_postgres() {
  log "Starting Postgres on network $NETWORK"
  docker network create "$NETWORK" >/dev/null 2>&1 || true
  docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$PG_NAME" --network "$NETWORK" \
    -e POSTGRES_DB=orders \
    -e POSTGRES_USER=app \
    -e POSTGRES_PASSWORD=localdev \
    postgres:16 >/dev/null
  track "$PG_NAME"

  i=1
  while [ "$i" -le "$TIMEOUT_SECS" ]; do
    if docker exec "$PG_NAME" pg_isready -U app -d orders >/dev/null 2>&1; then
      ok "Postgres ready"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  fail "Postgres did not become ready"
  return 1
}

run_service() {
  svc="$1"
  image="${TAG_PREFIX}/${svc}:latest"
  port="$(service_port "$svc")"
  name="gke-smoke-${svc}"

  docker rm -f "$name" >/dev/null 2>&1 || true

  log "Running $svc on :$port"
  case "$svc" in
    api-gateway)
      docker run -d --name "$name" --network "$NETWORK" \
        -p "127.0.0.1:${port}:${port}" \
        -e JWT_SECRET=smoke-test-secret \
        "$image" >/dev/null
      ;;
    worker)
      docker run -d --name "$name" --network "$NETWORK" \
        -p "127.0.0.1:${port}:${port}" \
        -e SQS_QUEUE_URL=http://127.0.0.1:9/smoke \
        -e HEALTH_PORT=8090 \
        "$image" >/dev/null
      ;;
    scheduler)
      docker run -d --name "$name" --network "$NETWORK" \
        -p "127.0.0.1:${port}:${port}" \
        -e "DATABASE_URL=postgres://app:localdev@${PG_NAME}:5432/orders?sslmode=disable" \
        -e HEALTH_PORT=8091 \
        "$image" >/dev/null
      ;;
    *)
      if needs_db "$svc"; then
        docker run -d --name "$name" --network "$NETWORK" \
          -p "127.0.0.1:${port}:${port}" \
          -e "DATABASE_URL=postgres://app:localdev@${PG_NAME}:5432/orders?sslmode=disable" \
          "$image" >/dev/null
      else
        docker run -d --name "$name" --network "$NETWORK" \
          -p "127.0.0.1:${port}:${port}" \
          "$image" >/dev/null
      fi
      ;;
  esac
  track "$name"

  url="http://127.0.0.1:${port}/healthz"
  if wait_http "$url"; then
    body="$(curl -sf "$url")"
    ok "$svc /healthz → $body"
  else
    fail "$svc did not answer $url within ${TIMEOUT_SECS}s"
    docker logs "$name" 2>&1 | tail -30 || true
  fi
}

log "GKE container smoke (platform=$PLATFORM)"
build_all
start_postgres

for svc in $SERVICES; do
  run_service "$svc"
done

echo
log "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
