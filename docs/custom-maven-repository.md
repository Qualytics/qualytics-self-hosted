# Resolving JDBC Drivers from an Internal Maven Repository

Some JDBC drivers cannot be bundled into the Qualytics dataplane due to vendor licensing, so the Spark driver resolves them at startup instead: the chart passes `dataplane.extraPackages` to `spark-submit --packages`, and Apache Ivy downloads the artifacts from Maven Central every time the driver starts.

```yaml
dataplane:
  extraPackages:
    - "com.teradata.jdbc:terajdbc:20.00.00.56"
    - "com.ibm.db2:jcc:12.1.4.0"
```

If your cluster has no route to Maven Central — air-gapped networks, egress-restricted VPCs, or environments where all artifacts must flow through an approved registry — point this resolution at an internal Maven repository (JFrog Artifactory, Sonatype Nexus, or any Maven-layout registry) with `dataplane.ivy`. The chart generates the required [Ivy settings file](https://ant.apache.org/ivy/history/latest-milestone/settings.html) for you, renders it into a release-managed Secret, mounts it into the Spark driver, and passes it to `spark-submit` via `spark.jars.ivySettings`.

Key properties of this mechanism:

- The generated settings file **fully replaces** Spark's built-in resolvers — Maven Central is never contacted. The repository you configure must therefore serve *every* coordinate listed in `dataplane.extraPackages`.
- Only the **driver pod** needs network access to the repository. Executors receive the resolved jars from the driver.
- Resolution happens on **every driver start** (the Ivy cache does not survive pod restarts), so treat the repository as an ongoing runtime dependency — like your datastores — not a one-time install dependency.
- The Secret is created and owned by the Helm release — there is nothing to create by hand, and changing any `dataplane.ivy` value automatically restarts the driver so the new configuration takes effect.

> Deployments that simply don't use Teradata or DB2 don't need any of this — remove the coordinates you don't need from `dataplane.extraPackages` instead.

## 1. Prepare the repository

Either option works:

- **Proxy Maven Central** — a remote/proxy repository (or a virtual repository that includes one), e.g. Artifactory's `maven-remote`. The artifacts are cached in your registry on first resolution.
- **Host the artifacts directly** — if the registry cannot reach Maven Central either, deploy the files into a local Maven-layout repository. Neither driver has transitive dependencies, so for the coordinates above it is exactly four files:

  ```text
  com/teradata/jdbc/terajdbc/20.00.00.56/terajdbc-20.00.00.56.pom
  com/teradata/jdbc/terajdbc/20.00.00.56/terajdbc-20.00.00.56.jar
  com/ibm/db2/jcc/12.1.4.0/jcc-12.1.4.0.pom
  com/ibm/db2/jcc/12.1.4.0/jcc-12.1.4.0.jar
  ```

  The versions track chart releases — always match the coordinates pinned in `dataplane.extraPackages` for your chart version.

Verify the repository serves the artifacts before touching the cluster:

```bash
curl -u 'svc-user:<token>' -fsIL \
  https://repo.example.com/artifactory/maven-remote/com/teradata/jdbc/terajdbc/20.00.00.56/terajdbc-20.00.00.56.jar
```

## 2. Configure `values.yaml`

```yaml
dataplane:
  extraPackages:
    - "com.teradata.jdbc:terajdbc:20.00.00.56"
    - "com.ibm.db2:jcc:12.1.4.0"
  ivy:
    enabled: true
    repositoryUrl: "https://repo.example.com/artifactory/maven-remote/"
    realm: "Artifactory Realm"
    username: "svc-user"
    password: "<token-or-password>"
```

Details that matter:

- **`repositoryUrl`** is the base URL of a Maven-layout repository. The chart derives the credentials hostname from it automatically.
- **`realm`** must match the realm string your registry sends in its HTTP `WWW-Authenticate` challenge. Defaults: `Artifactory Realm` for JFrog Artifactory, `Sonatype Nexus Repository Manager` for Nexus. Confirm yours with:

  ```bash
  curl -sI https://repo.example.com/artifactory/maven-remote/ | grep -i www-authenticate
  ```

- **`username` / `password`** — set both for an authenticated repository, or leave both empty for anonymous read access (the chart rejects setting only one). Prefer a registry identity token or API key over a real password; both are accepted as basic-auth passwords by Artifactory and Nexus. Handle `values.yaml` like the other credentials it already contains (`chmod 600`). Arbitrary characters are safe — the chart XML-escapes all values.

Then upgrade as usual:

```bash
helm upgrade qualytics qualytics/qualytics \
  --namespace qualytics \
  --version "$CHART_VERSION" \
  -f values.yaml \
  --wait \
  --timeout=5m
```

## Verify

Ivy logs its resolution at driver startup. Confirm the settings file was loaded and each artifact was found in the `internal` resolver (not `central`):

```bash
kubectl -n qualytics logs deployment/qualytics-spark | grep -E "loading settings|found com\."
```

Expected output:

```text
:: loading settings :: url = file:/opt/spark/conf/ivysettings.xml
found com.teradata.jdbc#terajdbc;20.00.00.56 in internal
found com.ibm.db2#jcc;12.1.4.0 in internal
```

The rendered file itself can be inspected at any time:

```bash
kubectl -n qualytics get secret qualytics-spark-ivy-settings \
  -o jsonpath='{.data.ivysettings\.xml}' | base64 -d
```

## Rotating credentials

Update `dataplane.ivy.username` / `password` in `values.yaml` and run `helm upgrade`. The driver pod carries a checksum of the rendered settings file, so the upgrade automatically restarts the driver with the new credentials — no manual `kubectl rollout restart` needed.

## Requirements and limitations

- The driver pod must reach the repository host on 443 (adjust NetworkPolicies / egress allowlists accordingly). Executors don't need access.
- The repository's TLS certificate must chain to a CA present in standard JVM truststores (i.e. a publicly trusted CA). Certificates issued by a private/internal CA are not currently supported for this path — contact Qualytics support if that is a blocker.
- The generated settings define a single repository. If you need multiple internal repositories, put a virtual repository (Artifactory) or repository group (Nexus) in front of them and point `repositoryUrl` at that.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `helm upgrade` fails with `dataplane.ivy.repositoryUrl is required` or `must both be set` | The values block is incomplete — set `repositoryUrl`, and either both or neither of `username`/`password`. |
| Driver in `CrashLoopBackOff`, logs show `unresolved dependency: com.teradata.jdbc#terajdbc;…: not found` | The repository doesn't serve the coordinate, or `repositoryUrl` is wrong. Re-run the `curl` pre-flight from step 1. |
| Resolution log shows `HTTP response code: 401` | Wrong credentials, or `realm` doesn't match the registry's `WWW-Authenticate` realm. |
| `PKIX path building failed` during resolution | The repository presents a certificate the JVM doesn't trust (typically an internal CA — see limitations above). |
| Connection test fails with `Failed to get driver instance for jdbcUrl=jdbc:teradata://…` | The JDBC driver never made it onto the dataplane classpath. Check the resolution log above, and confirm the coordinate is still present in `dataplane.extraPackages`. |
