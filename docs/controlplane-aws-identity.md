# Giving the Controlplane an AWS Identity

By default the Qualytics hub pods (`api` and `cmd`) run under the namespace's `default` ServiceAccount with no cloud identity of their own. Anything that needs AWS credentials therefore falls back to whatever identity the *node* carries — the EKS node instance role, shared with every other pod scheduled there.

That is coarse, and for one feature it is the difference between a one-line setup and a two-role one: **AgentQ's Amazon Bedrock integration with IAM Role authentication**. This guide covers giving the controlplane its own identity and pointing Bedrock at it.

None of this applies if you authenticate Bedrock with an API key or with AWS access keys, or if you use a non-AWS LLM provider.

## 1. Create the ServiceAccount

```yaml
controlplane:
  serviceAccount:
    create: true
```

This creates a ServiceAccount named `<release>-controlplane` and binds it to both hub deployments. Both need it: `api` and `cmd` each resolve LLM providers independently.

Setting `name` adopts an existing ServiceAccount instead of creating one; with `create: false` the chart binds it without managing it.

## 2. Attach an AWS role to it

Pick one. **EKS Pod Identity is the simplest** and needs nothing in your values file.

### EKS Pod Identity (recommended)

Install the `eks-pod-identity-agent` add-on on the cluster, then associate the role with the ServiceAccount:

```bash
aws eks create-pod-identity-association \
  --cluster-name <cluster> \
  --namespace <namespace> \
  --service-account <release>-controlplane \
  --role-arn arn:aws:iam::<account>:role/<role>
```

The role's trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "pods.eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
```

Restart the hub deployments so the credentials are injected.

### IRSA

Needs the cluster's OIDC provider registered as an IAM identity provider — the `terraform/aws/cluster` module outputs `cluster_oidc_provider_arn` for exactly this. Trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "<cluster_oidc_provider_arn>" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "<oidc-issuer>:sub": "system:serviceaccount:<namespace>:<release>-controlplane",
        "<oidc-issuer>:aud": "sts.amazonaws.com"
      }
    }
  }]
}
```

Then annotate the ServiceAccount:

```yaml
controlplane:
  serviceAccount:
    create: true
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::<account>:role/<role>"
```

### Node instance role

Nothing to configure in the chart — this is what happens already. Grant the permissions below directly to the node group's instance role. Simplest to set up, and the widest blast radius: every pod on those nodes gets the same access. Use it to get going, not to stay.

## 3. Configure Bedrock

In **Settings → Integrations → AgentQ**, choose Amazon Bedrock and set **Authentication Method** to *IAM Role*. What goes in **Role ARN** depends on where Bedrock lives.

### Bedrock in the same AWS account — leave Role ARN blank

Qualytics calls Bedrock as the identity from step 2. Grant it:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
    "Resource": "*"
  }]
}
```

Scope `Resource` to the model or inference-profile ARNs you intend to use if you prefer.

That is the whole setup. No second role, no trust policy.

### Bedrock in a different AWS account — set Role ARN

There is no cross-account invoke for Bedrock; you have to hold credentials in the account with model access. Create a role **in that account** carrying the policy above, and trust the identity from step 2:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::<account>:role/<role from step 2>" },
    "Action": "sts:AssumeRole",
    "Condition": { "StringEquals": { "sts:ExternalId": "<your external id>" } }
  }]
}
```

Enter that role's ARN, and the same External ID if you used one. Two things trip people up here:

- **Name the role ARN, not the session ARN.** `arn:aws:iam::…:role/name`, never `arn:aws:sts::…:assumed-role/name/session`.
- **Assumed sessions are capped at one hour.** The controlplane's own identity is already a role, so this is role chaining. Qualytics mints fresh credentials as needed; just don't set `MaxSessionDuration` above 3600 and expect it to apply.

## Troubleshooting

Qualytics tests the provider before saving the configuration, and a failure names the AWS identity resolved by the pod:

```
Failed to validate API key for bedrock:… : AccessDeniedException …
  — AWS caller identity: arn:aws:sts::123456789012:assumed-role/prod-nodes/i-0abc.
    Grant bedrock:InvokeModel to that identity.
```

Read that ARN first — it tells you which of the three mechanisms above actually took effect. `assumed-role/<node group>/i-…` means the pod is still on the node instance role, so the ServiceAccount is not wired up: check that `controlplane.serviceAccount.create` is set, that the association or annotation names the same ServiceAccount the chart created, and that the pods have been restarted since. With a Role ARN configured, the error names this ambient identity as the principal the target role must trust.

To ask the same question directly:

```bash
kubectl exec deploy/<release>-api -- python3 -c "import boto3;print(boto3.client('sts').get_caller_identity())"
```

If the message says the controlplane could not resolve any AWS credentials at all, no identity reached the pod — step 2 has not taken effect.
