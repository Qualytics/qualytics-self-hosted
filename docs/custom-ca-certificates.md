# Trusting an Internal Certificate Authority

The Qualytics dataplane runs on Java, which verifies every TLS connection against the certificate authorities in its **truststore**. Out of the box that is the JDK's standard set of public CAs. A datastore endpoint whose certificate is signed by your organization's **internal CA** is therefore rejected during the TLS handshake:

```
javax.net.ssl.SSLHandshakeException: PKIX path building failed:
sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target
```

Typical cases:

- a **Hadoop KMS** protecting an HDFS encryption zone (native Hive datastores read these files through the KMS);
- **HiveServer2**, a Hive metastore, or another JDBC endpoint with TLS enabled;
- any internal HTTPS service a datastore connection reaches.

The fix is to give the dataplane a truststore that contains the standard public CAs **plus** your internal root CA, mount it into the driver and executor pods, and point the JVM at it.

Key properties of this mechanism:

- What you add is your CA's **public certificate**, the same kind of file every browser and operating system trust store ships with. It contains no private key and grants no access; it only lets the dataplane verify that it is talking to your servers.
- The truststore must **start from the image's own `cacerts`**, so public endpoints (cloud object stores, SaaS datastores) keep working.
- The truststore lives in a Kubernetes Secret that **you** create and own (by hand, or synced from Vault or another secrets manager). The chart only mounts it.
- The truststore password (`changeit`, the JDK default) is not a secret. A truststore holds only public certificates, and the password exists only because the PKCS12 file format requires one.

## 1. Build the truststore

Start from the `cacerts` of the dataplane image your release runs, then import your CA (and any intermediate CA your servers don't send in their chain):

```bash
kubectl -n <namespace> exec deploy/<release>-spark -- sh -c 'cat "$JAVA_HOME/lib/security/cacerts"' > truststore.p12

keytool -importcert -noprompt -alias corp-root-ca -file corp-root-ca.pem \
  -keystore truststore.p12 -storepass changeit
```

To see which certificates a server presents, and confirm which one is the root:

```bash
openssl s_client -connect kms.example.com:9494 -showcerts </dev/null
```

Check the result:

```bash
keytool -list -keystore truststore.p12 -storepass changeit | grep -i corp-root-ca
```

## 2. Create the Secret

The Secret must be in the release namespace, with the truststore under the key `truststore.p12`.

**Directly:**

```bash
kubectl -n <namespace> create secret generic qualytics-ca-truststore --from-file=truststore.p12
```

**From Vault.** Store the file base64-encoded (KV holds strings), then let your operator decode it on sync:

```bash
vault kv put secret/qualytics/ca-truststore truststore_p12="$(base64 -i truststore.p12)"
```

External Secrets Operator:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: qualytics-ca-truststore
  namespace: <namespace>
spec:
  secretStoreRef: { kind: ClusterSecretStore, name: <vault-store> }
  target: { name: qualytics-ca-truststore }
  data:
    - secretKey: truststore.p12
      remoteRef:
        key: qualytics/ca-truststore
        property: truststore_p12
        decodingStrategy: Base64
```

Vault Secrets Operator:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: qualytics-ca-truststore
  namespace: <namespace>
spec:
  type: kv-v2
  mount: secret
  path: qualytics/ca-truststore
  destination:
    name: qualytics-ca-truststore
    create: true
    transformation:
      excludeRaw: true
      templates:
        truststore.p12:
          text: '{{ get .Secrets "truststore_p12" | b64dec }}'
```

## 3. Configure `values.yaml`

```yaml
dataplane:
  driver:
    extraVolumes:
      - name: ca-truststore
        secret:
          secretName: qualytics-ca-truststore
    extraVolumeMounts:
      - name: ca-truststore
        mountPath: /opt/qualytics/ca
        readOnly: true
  extraSparkConf:
    # Driver JVM. defaultJavaOptions is separate from the chart's own extraJavaOptions, so both apply.
    spark.driver.defaultJavaOptions: "-Djavax.net.ssl.trustStore=/opt/qualytics/ca/truststore.p12 -Djavax.net.ssl.trustStorePassword=changeit"
    # Executors: Spark mounts the Secret into every executor pod it creates.
    spark.kubernetes.executor.secrets.qualytics-ca-truststore: "/opt/qualytics/ca"
    spark.executor.defaultJavaOptions: "-Djavax.net.ssl.trustStore=/opt/qualytics/ca/truststore.p12 -Djavax.net.ssl.trustStorePassword=changeit"
```

Both the driver and the executors need the truststore. For example, reading an HDFS encryption zone requires the driver to obtain a KMS delegation token and every executor to call the KMS for each file it opens.

Apply with `helm upgrade`. Changing `extraSparkConf` restarts the driver automatically.

## 4. Verify

The truststore is mounted and the JVM is using it:

```bash
kubectl -n <namespace> exec deploy/<release>-spark -- ls -l /opt/qualytics/ca/truststore.p12
kubectl -n <namespace> exec deploy/<release>-spark -- sh -c 'ps -o args= -C java | grep -o "javax.net.ssl.trustStore=[^ ]*"'
```

Then run an operation against the datastore that was failing, e.g. a profile. The `PKIX path building failed` error should be gone. If the endpoint now answers with an authorization error instead (for a Hadoop KMS, `403` / `not allowed to do 'DECRYPT_EEK'`), TLS is working, and what remains is a permission on the server side.

## Rotating the CA

Rebuild `truststore.p12` with the new certificate (step 1) and update the Secret or its Vault source. Pods read the file only when they start, so restart the driver:

```bash
kubectl -n <namespace> rollout restart deploy/<release>-spark
```

Executors started after the restart pick up the new file automatically. Rebuilding from a current image's `cacerts` also refreshes the public CAs, so it is worth doing after major Qualytics upgrades as well.
