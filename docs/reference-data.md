# Reference data configuration

Qualytics Reference Data installs selected datasets into a customer enrichment store.
Enable the feature with application images that support reference installation and an
MDM-enabled deployment license. The distribution service also verifies the deployment's
current central MDM grant; a local license alone cannot authorize downloads.

## Enable reference data

Add this block to your deployment values:

```yaml
controlplane:
  referenceData:
    enabled: true
    gatewayUrl: https://reference-data.qualytics.io
    timeoutSeconds: 30
```

The feature defaults to disabled. The gateway URL defaults to the public hostname above.
An override must be an HTTPS base URL, optionally including a path prefix or TCP port
from 1 through 65535, without credentials, query parameters or fragments.
`timeoutSeconds` must be a positive integer and limits each gateway request, rather
than the complete installation. Existing releases whose reused values omit
`referenceData` remain disabled. If you enable the feature while reusing older values
that omit `gatewayUrl`, the public gateway default still applies. An explicitly empty
URL is rejected.

API and CMD receive `REFERENCE_DATA_ENABLED` and, when enabled,
`REFERENCE_DATA_GATEWAY_URL` and `REFERENCE_DATA_TIMEOUT_SECONDS`. They reuse
`QUALYTICS_DEPLOYMENT_IDENTIFIER` from `qualytics-creds`, key `deployment_identifier`,
which the chart already provisions from `secrets.deployment.identifier`. Keep the
Qualytics-issued identifier in your existing protected deployment configuration; do
not put it in the URL or add AWS access keys for distribution.

Self-hosted module entitlements come from the signed deployment license. There is no
Helm module toggle to enable MDM. Contact Qualytics if the license and central grant
need to be reconciled.

## Outbound network requirements

Allow outbound HTTPS over TCP 443 to:

| Workload | Hostname | Purpose |
| --- | --- | --- |
| API and CMD | `reference-data.qualytics.io` | Authenticated discovery, plans and authorization |
| Dataplane driver and workers | `qualytics-reference-data.s3.us-east-1.amazonaws.com` | Approved release downloads during installation and refresh |

If you configure another approved gateway, allow its hostname and configured port.
S3A object reads use HTTPS on TCP 443. Gateway-only access is insufficient because
release data transfers directly from S3. Keep DNS resolution available and preserve
ordinary access to the destination enrichment store and application dependencies.
The frontend communicates through the API and requires no direct gateway or
reference-distribution credentials.

DFS destinations receive verified immutable file copies. JDBC and native destinations
use Spark reads of approved S3 objects with short-lived, scoped credentials and normal
enrichment writes. Both the driver and workers can need distribution-S3 connectivity
during installation. Subsequent profiling, scanning and checks read the installed
customer copy through ordinary datastore connections.

This chart does not create NetworkPolicies or change firewall rules. Keep TLS
certificate verification enabled through `controlplane.egress.verifyTLSCertificates`.
For an outbound proxy or TLS inspection, configure the supported application and
Spark proxy/trust settings in your environment; this feature adds no proxy or CA-volume
values. Preserve internal services in your proxy bypass configuration.

## Updates, resources and disconnected deployments

Configure manual, automatic-compatible or pinned update policy in the application.
CP owns scheduling, validation and activation; the chart adds no CronJob, reference
image, init-copy or data mount. Data refresh does not require an application rebuild
or pod restart. Failed installs leave the previous active release intact.

Use existing `controlplane.resources`, `controlplaneCmd.resources` and dataplane
resource/scratch settings. Allow capacity for transfer verification, destination
writes and retained immutable versions. Old versions can remain for running work,
pins and retries; do not delete them while referenced.

New acquisition and refresh require current central MDM authorization. Installed
copies remain usable after entitlement loss or when distribution access is blocked,
subject to dataset freshness policy and destination connectivity. Source publication
age is separate from installation age. Fully offline acquisition through signed
package import is deferred; this chart does not provide it.

## Troubleshooting

- **Feature unavailable:** check `enabled`, compatible application versions and the
  signed license's MDM entitlement.
- **Identity rejected:** verify the issued deployment identifier is configured through
  the existing secret mechanism. Inspect error codes without logging the identifier.
- **MDM denied:** ask Qualytics to verify the current central grant for this deployment.
  Reissuing a local license does not by itself change that grant.
- **Gateway timeout:** check API/CMD outbound access to the configured gateway,
  DNS, proxy and TLS trust. A larger timeout cannot fix a blocked connection.
- **S3 denied or timed out:** check driver and worker access to the distribution
  hostname separately from gateway access and destination credentials. Retry through
  the application to obtain fresh scoped authorization; do not substitute broad AWS keys.
- **Destination failure:** verify enrichment-store permissions and scratch/storage
  capacity, correct the issue and retry the saved release.
- **Stale dataset:** review source publication time and freshness policy. A successful
  refresh does not make an unchanged old upstream release newer.

Local chart tests validate configuration, rendering and credential isolation. They do
not verify a live license, central grant, Secret, network route or datastore permission.
