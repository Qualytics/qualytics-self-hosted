# License Management

Self-hosted Qualytics deployments require a valid license. A **31-day grace period** starts when the first datastore connection is created — during this time the platform is fully functional without a license.

Licenses are binary (active or expired) — there are no tiers or feature gates.

> **What happens if you don't activate a license?** After the grace period expires (or after a license expires), **dataplane operations stop** — scanning, profiling, and all Spark-based jobs are blocked. The platform UI remains accessible so admins can apply a license.

---

## Grace Period

- Starts automatically when the **first datastore** is created
- Lasts **31 days** — the platform is fully operational during this window
- A warning banner in **Settings > Status** shows remaining days
- No license is needed during this period, but we recommend activating early

---

## License Request & Activation

Only users with **Admin** or **Manager** roles can manage licenses.

### Step 1: Generate a License Request

1. Navigate to **Settings > Status**
2. Click **"Generate License Request"**
3. This creates an encoded fingerprint of your deployment (datastore count, user count, etc.)
4. Copy the request string

### Step 2: Send the Request to Qualytics

Send the license request to your Qualytics account manager via a **secure channel**:
- [BitWarden Send](https://bitwarden.com/products/send/) (recommended)
- Encrypted email
- Other secure file transfer

> **Do not** send license requests over plain email or unencrypted channels — the request contains deployment metadata.

### Step 3: Apply the Signed License

1. Qualytics signs your request and returns a **license key**
2. Back in **Settings > Status**, click **"Update License"**
3. Paste the signed license key and submit
4. The license is now active — the expiration date displays on the Status page

---

## License Renewal

- The license expiration date is visible on **Settings > Status**
- A **warning appears 30 days before expiration** (date turns red with a warning icon)
- **Renew before expiration** to avoid service interruption
- The renewal process is the same as initial activation:
  1. Generate License Request
  2. Send to Qualytics
  3. Apply the signed license

If a license expires, dataplane operations stop immediately until a new license is applied.

---

## No Helm Configuration Needed

Licensing is handled entirely through the UI. No environment variables, Helm values, or `values.yaml` changes are required.

---

## Additional Resources

- [Self-Hosted Deployment Guide](https://userguide.qualytics.io/deployments/self-hosted-deployment/) — End-to-end deployment walkthrough
- [Authentication Configuration](./authentication.md) — OIDC and Auth0 setup
