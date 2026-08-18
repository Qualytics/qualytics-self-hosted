# Exporting Control-Plane Telemetry (Logfire / OTLP)

The Qualytics control plane (the API and CMD pods) is instrumented with [OpenTelemetry](https://opentelemetry.io/) through the [Pydantic Logfire](https://pydantic.dev/logfire) SDK. Telemetry export is **off by default** and is enabled per deployment with `controlplane.observability`. Two destinations are supported, independently or together:

- **Pydantic Logfire** — set a Logfire write token.
- **Any OTLP-compatible backend** — set an OTLP endpoint (and auth headers if the backend requires them). This covers Splunk, Datadog, Grafana, Elastic, New Relic, or an in-cluster OpenTelemetry Collector.

What is exported:

- **Traces** — API request spans (route, status, duration), database statements (SQLAlchemy instrumentation), and AI-agent runs (prompt/response content is excluded).
- **Metrics** — database connection-pool usage, message-queue publisher confirms, and background-job canary latency/health from the CMD processor.

The Spark dataplane is not covered by this mechanism — it exports nothing regardless of these settings.

> Exporting to a custom OTLP backend **without** a Logfire token requires the control-plane image released with chart version `2026.8.17` or later. Sending to Logfire with a token works with any supported image.

## Sending to Pydantic Logfire

Create a write token in your Logfire project (**Settings → Write tokens**), then:

```yaml
controlplane:
  observability:
    enabled: true

secrets:
  observability:
    logfire_token: "pylf_v1_..."
```

The API and CMD pods need egress to `https://logfire-us.pydantic.dev` (or the EU endpoint, depending on your Logfire region).

## Sending to a custom OTLP backend (Splunk, collector, ...)

```yaml
controlplane:
  observability:
    enabled: true
    otlp:
      endpoint: "http://otel-collector.observability:4318"

secrets:
  observability:
    # Only needed when the backend authenticates OTLP requests.
    # Comma-separated key=value pairs, sent as HTTP headers on every export.
    otlp_headers: "Authorization=Bearer <token>"
```

Requirements and behavior:

- The endpoint must accept **OTLP over HTTP (protobuf)** — the standard collector port `4318`. gRPC-only endpoints (`4317`) are not supported.
- The control plane appends the standard signal paths itself: traces go to `<endpoint>/v1/traces` and metrics to `<endpoint>/v1/metrics`. Configure the base URL only.
- `otlp_headers` is stored in the release-managed `qualytics-creds` Secret and injected as `OTEL_EXPORTER_OTLP_HEADERS`, so backend tokens never appear in pod specs.

### Splunk

Splunk's supported pattern for both Splunk Observability Cloud and Splunk Enterprise/Cloud Platform is the [Splunk Distribution of the OpenTelemetry Collector](https://docs.splunk.com/observability/en/gdi/opentelemetry/opentelemetry.html), which receives standard OTLP on port `4318` and forwards to your Splunk backend (Observability Cloud ingest, or HEC for the platform products). Point the control plane at the collector service:

```yaml
controlplane:
  observability:
    enabled: true
    otlp:
      endpoint: "http://splunk-otel-collector.splunk-monitoring:4318"
```

Authentication against Splunk (access token, HEC token) is configured in the collector, not in Qualytics — `otlp_headers` is normally not needed in this topology.

## Sending to both

Set the Logfire token *and* the OTLP endpoint — every span and metric is delivered to both destinations.

## Environment name and sampling

```yaml
controlplane:
  observability:
    enabled: true
    # Reported as the service/environment name with all telemetry.
    # Defaults to global.dnsRecord.
    environment: "qualytics-prod"
    # Head sampling keeps every trace at level >= notice or duration >= 5s,
    # plus 10% of the remaining traffic. Set false to export every trace.
    sampling: true
```

## Values-to-environment reference

| Helm value | Environment variable | Notes |
|---|---|---|
| `controlplane.observability.environment` | `LOGFIRE_ENVIRONMENT` | Defaults to `global.dnsRecord` |
| `controlplane.observability.sampling` | `LOGFIRE_SAMPLING` | `true`/`false` |
| `secrets.observability.logfire_token` | `LOGFIRE_TOKEN` | From `qualytics-creds` |
| `controlplane.observability.otlp.endpoint` | `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP/HTTP base URL |
| `secrets.observability.otlp_headers` | `OTEL_EXPORTER_OTLP_HEADERS` | From `qualytics-creds` |

## Verifying

After `helm upgrade`, confirm the environment landed on both deployments:

```bash
kubectl -n qualytics get deployment qualytics-api qualytics-cmd \
  -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.template.spec.containers[0].env[?(@.name=="OTEL_EXPORTER_OTLP_ENDPOINT")].value}{"\n"}{end}'
```

Then generate traffic (log in, browse a datastore) and look for spans with your configured environment as the service name in the backend. If a Logfire token is invalid, the API log records a `Logfire API returned status code 401` warning at startup; OTLP delivery problems surface as export warnings in the API/CMD logs while the application continues to run normally.
