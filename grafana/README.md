# Grafana dashboards (SRE handbook)

Importable Grafana dashboards aligned with the [Google SRE Book](https://sre.google/sre-book/table-of-contents/) monitoring model.

| File | Theme | Source |
|------|--------|--------|
| `dashboards/sre-golden-signals.json` | **Four golden signals** — latency, traffic, errors, saturation | SRE Book Ch. 6 |
| `dashboards/sre-service-red.json` | **RED** — rate, errors, duration by operation | SRE workbook / RED method |
| `dashboards/sre-slo-error-budget.json` | **SLIs / SLOs / error budget** + burn rates | SRE Book Ch. 4 + Workbook |

## Prerequisites

1. Traces flowing Alloy → Grafana Cloud (already configured).
2. Alloy **spanmetrics** enabled (see `k8s/base/observability/alloy.yaml`) so Prometheus receives:
   - `traces_span_metrics_calls_total`
   - `traces_span_metrics_duration_seconds_*`
3. Redeploy Alloy after config changes:

```bash
make deploy ENV=dev
# or
kubectl -n orders apply -f k8s/base/observability/alloy.yaml
kubectl -n orders rollout restart deploy/grafana-alloy
```

4. Generate traffic, then in Grafana **Explore → Metrics** confirm those metric names exist (wait ~1–2 minutes after first spans).

## Import

In Grafana Cloud:

1. **Dashboards → New → Import**
2. Upload one of the JSON files (or paste contents)
3. When prompted, pick your **Prometheus** / Mimir datasource (`grafanacloud-*-prom`)
4. Repeat for the other two dashboards

Variables after import:

- **Environment** — `deployment.environment` (e.g. `dev`)
- **Service** — `api-gateway`, `order-service`, `payment-service`, `worker`, …
- SLO dashboard also has availability %, latency threshold, and percentile knobs

## How metrics are produced

```text
apps (otelhttp spans)
  → Alloy OTLP :4318
  → otelcol.connector.spanmetrics  → RED Prom metrics
  → otelcol.connector.servicegraph → edge metrics (Explore → Service graph)
  → Grafana Cloud OTLP (metrics + traces)
```

Saturation on the golden-signals board is **estimated in-flight requests** (Little’s Law). Autopilot CPU/memory stay in **Cloud Monitoring** on purpose (see `docs/observability.md`).

## Tempo (optional)

Raw traces: **Explore → Tempo**, filter `resource.service.name` / `deployment.environment`.  
Service graph view needs the servicegraph metrics Alloy now emits.
