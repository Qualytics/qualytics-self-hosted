# Resolving JDBC Drivers from an Internal Maven Repository

Some JDBC drivers cannot be bundled into the Qualytics dataplane due to vendor licensing, so the Spark driver resolves them at startup instead: the chart passes `dataplane.extraPackages` to `spark-submit --packages`, and Apache Ivy downloads the artifacts from Maven Central every time the driver starts.

```yaml
dataplane:
  extraPackages:
    - "com.teradata.jdbc:terajdbc:20.00.00.56"
    - "com.ibm.db2:jcc:12.1.4.0"
```

If your cluster has no route to Maven Central — air-gapped networks, egress-restricted VPCs, or environments where all artifacts must flow through an approved registry — you can point this resolution at an internal Maven repository (JFrog Artifactory, Sonatype Nexus, or any Maven-layout registry) with `dataplane.ivySettingsSecret`. You provide an [Ivy settings file](https://ant.apache.org/ivy/history/latest-milestone/settings.html) in a Kubernetes Secret; the chart mounts it into the Spark driver and passes it to `spark-submit` via `spark.jars.ivySettings`.

Key properties of this mechanism:

- The settings file **fully replaces** Spark's built-in resolvers — Maven Central is never contacted. The repository you configure must therefore serve *every* coordinate listed in `dataplane.extraPackages`.
- Only the **driver pod** needs network access to the repository. Executors receive the resolved jars from the driver directly.
- Resolution happens on **every driver start** (the Ivy cache does not survive pod restarts), so treat the repository as an ongoing runtime dependency — like your datastores — not a one-time install dependency.
- Credentials live only inside the Secret. They never appear in Helm values, pod specs, or `spark-submit` logs.

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

## 2. Write `ivysettings.xml`

For a repository that allows anonymous reads:

```xml
<ivysettings>
  <settings defaultResolver="internal"/>
  <resolvers>
    <ibiblio name="internal" m2compatible="true"
             root="https://repo.example.com/artifactory/maven-remote/"/>
  </resolvers>
</ivysettings>
```

For an authenticated repository, add a `<credentials>` element:

```xml
<ivysettings>
  <settings defaultResolver="internal"/>
  <credentials host="repo.example.com"
               realm="Artifactory Realm"
               username="svc-user"
               passwd="<token-or-password>"/>
  <resolvers>
    <ibiblio name="internal" m2compatible="true"
             root="https://repo.example.com/artifactory/maven-remote/"/>
  </resolvers>
</ivysettings>
```

Details that matter:

- **`host`** is the bare hostname — no scheme, no path.
- **`realm`** must match the realm string your registry sends in its HTTP `WWW-Authenticate` challenge. Defaults: `Artifactory Realm` for JFrog Artifactory, `Sonatype Nexus Repository Manager` for Nexus. Confirm yours with:

  ```bash
  curl -sI https://repo.example.com/artifactory/maven-remote/ | grep -i www-authenticate
  ```

- **`passwd`** — prefer a registry identity token or API key over a real password; both are accepted as basic-auth passwords by Artifactory and Nexus.
- **`root`** is the repository base URL. Multiple repositories can be combined with an Ivy `<chain>` resolver if needed.

## 3. Create the Secret

The Secret must live in the release namespace and the key must be named `ivysettings.xml`:

```bash
kubectl -n qualytics create secret generic qualytics-ivy-settings \
  --from-file=ivysettings.xml
```

## 4. Reference it in `values.yaml` and upgrade

```yaml
dataplane:
  ivySettingsSecret: "qualytics-ivy-settings"
```

```bash
helm upgrade qualytics qualytics/qualytics \
  --namespace qualytics \
  --version "$CHART_VERSION" \
  -f values.yaml \
  --wait \
  --timeout=5m
```

## Verify

Ivy logs its resolution at driver startup. Confirm the settings file was loaded and each artifact was found in *your* resolver (not `central`):

```bash
kubectl -n qualytics logs deployment/qualytics-spark | grep -E "loading settings|found com\."
```

Expected output:

```text
:: loading settings :: url = file:/opt/spark/conf/ivysettings.xml
found com.teradata.jdbc#terajdbc;20.00.00.56 in internal
found com.ibm.db2#jcc;12.1.4.0 in internal
```

## Rotating credentials

Update the Secret, then restart the driver (the file is read once, at startup):

```bash
kubectl -n qualytics create secret generic qualytics-ivy-settings \
  --from-file=ivysettings.xml --dry-run=client -o yaml | kubectl apply -f -
kubectl -n qualytics rollout restart deployment/qualytics-spark
```

## Requirements and limitations

- The driver pod must reach the repository host on 443 (adjust NetworkPolicies / egress allowlists accordingly). Executors don't need access.
- The repository's TLS certificate must chain to a CA present in standard JVM truststores (i.e. a publicly trusted CA). Certificates issued by a private/internal CA are not currently supported for this path — contact Qualytics support if that is a blocker.
- `spark.jars.ivySettings` accepts only local `file://` paths, which is why the chart mounts the Secret rather than accepting a URL.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| Driver in `CrashLoopBackOff`, logs show `unresolved dependency: com.teradata.jdbc#terajdbc;…: not found` | The repository doesn't serve the coordinate, or `root` is wrong. Re-run the `curl` pre-flight from step 1. |
| Resolution log shows `HTTP response code: 401` | Wrong credentials, or the `realm` in `ivysettings.xml` doesn't match the registry's `WWW-Authenticate` realm. |
| `PKIX path building failed` during resolution | The repository presents a certificate the JVM doesn't trust (typically an internal CA — see limitations above). |
| Driver pod stuck in `ContainerCreating`, events show `FailedMount … secret "…" not found` | The Secret doesn't exist in the release namespace, the name in `dataplane.ivySettingsSecret` is wrong, or the key isn't `ivysettings.xml`. |
| Connection test fails with `Failed to get driver instance for jdbcUrl=jdbc:teradata://…` | The JDBC driver never made it onto the dataplane classpath. Check the resolution log above, and confirm the coordinate is still present in `dataplane.extraPackages`. |
