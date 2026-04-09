# Qualytics External PostgreSQL: Common Questions

This document addresses common questions from customers deploying Qualytics against an externally managed PostgreSQL instance.

For initial setup instructions, see the [External PostgreSQL Setup Guide](https://github.com/Qualytics/qualytics-self-hosted/blob/main/docs/external-postgres-setup.md).

---

## 1. The `pgcrypto` Extension

### Is `pgcrypto` required?

**The `pgcrypto` extension is optional — it is not a hard requirement for Qualytics.**

The `CREATE EXTENSION IF NOT EXISTS pgcrypto` statement included in the setup script is a recommended best practice, but Qualytics will function correctly without it. Qualytics performs all credential encryption at the application layer using industry-standard AES-256-GCM, so `pgcrypto` is not invoked at runtime.

We include it in the setup script because `pgcrypto` is an [official PostgreSQL extension](https://www.postgresql.org/docs/current/pgcrypto.html) bundled with every standard PostgreSQL distribution. It is widely trusted, used in production by thousands of organizations, and provides useful cryptographic functions at the database level should they ever be needed. Having it available is a defensive measure — a nice-to-have, not a dependency.

**If your organization's policy restricts installing PostgreSQL extensions, you can safely omit the `CREATE EXTENSION IF NOT EXISTS pgcrypto` line from the setup script.** Qualytics will operate normally without it.

### What is `pgcrypto`?

`pgcrypto` is a standard extension that ships with PostgreSQL itself — it is not third-party software. It provides cryptographic functions (hashing, encryption, random generation) directly within the database.

- **Official and trusted** — Maintained by the PostgreSQL Global Development Group as part of the [contrib modules](https://www.postgresql.org/docs/current/contrib.html)
- **Shipped with PostgreSQL** — Included in every standard PostgreSQL installation; no external downloads required
- **Widely adopted** — Used in production by organizations worldwide; major cloud providers (AWS RDS, Google Cloud SQL, Azure Database for PostgreSQL) all support it natively
- **Non-invasive** — Installing the extension does not modify existing tables or data; it simply makes cryptographic functions available for use
- **No performance impact** — The extension only consumes resources when its functions are explicitly called

### How does Qualytics encrypt sensitive data?

Qualytics encrypts all sensitive credentials **at the application layer** before they ever reach the database. This means encryption happens entirely within the Qualytics application — not inside PostgreSQL.

- **Algorithm:** AES-256-GCM — authenticated encryption providing both confidentiality and tamper detection
- **Padding:** PKCS5 — standard block cipher padding
- **Key management:** Application-managed passphrase set at deploy time; never stored in the database

When Qualytics stores a credential (e.g., a database password or API token), it encrypts the value *before* sending it to the database. The database only ever stores the encrypted ciphertext. When Qualytics needs the credential, it reads the ciphertext and decrypts it in application memory. **The database server never sees or processes plaintext secrets.**

### What data is encrypted?

All authentication credentials are encrypted at rest. This includes:

- **Database connections** — usernames and passwords
- **Object storage connections** — access keys and secret keys
- **Vault / secrets manager credentials** — login payloads
- **Third-party integrations** — API tokens for services like Slack, Atlan, LLMs, etc.
- **Notifications** — webhook and notification authentication secrets

Qualytics also maintains audit-history versions of these records, which carry the same encryption.

### Why application-layer encryption?

Application-layer encryption is an industry best practice for credential storage, followed by most modern SaaS platforms:

1. **The database never sees plaintext.** Even a full database dump, a stolen backup, or a compromised database account cannot reveal secrets — only the Qualytics application holding the encryption key can decrypt them.

2. **Works everywhere.** No dependency on specific PostgreSQL extensions or features. Works identically across all managed PostgreSQL services (RDS, Cloud SQL, Azure Database for PostgreSQL).

3. **Separation of concerns.** The encryption key is managed entirely within the application tier (environment variables or a secrets manager), fully separate from database access controls.

4. **Key rotation support.** Qualytics supports encryption key rotation, allowing zero-downtime re-encryption of all credentials without any database-side changes.

5. **Tamper detection.** AES-GCM is an authenticated encryption mode — any modification to the encrypted data in the database will be detected and rejected.

---

## 2. Using a Non-Public Schema

### Can Qualytics use a custom schema instead of `public`?

While technically possible with engineering changes, **we do not currently recommend or support it.** This is not a blocker — it is an explanation of why the current default is the right choice given the setup.

### Your database is already isolated

The standard Qualytics setup creates a **dedicated database** (e.g., `qualytics`) and a **dedicated service account** (e.g., `qualytics_user`). No other application shares this database.

Given this isolation model, the `public` schema within the dedicated database is effectively private to Qualytics. There is no material security or organizational benefit to adding a second layer of namespace isolation via a custom schema — the dedicated database already provides full separation from all other workloads.

### Why the `public` schema is the right default

Using a dedicated database with the `public` schema gives you full isolation from other applications, works out of the box with default PostgreSQL behavior, and is the standard, fully tested configuration for Qualytics. Adding a custom schema on top of an already-dedicated database does not improve isolation — it only adds unused complexity and additional configuration to manage.

### What would a custom schema require?

Switching to a non-public schema would require Qualytics engineering changes across multiple layers of the application, including the data model definitions, database migration system, and connection configuration. This is significant effort with no security benefit given that Qualytics already operates in a dedicated database.

### Recommendation

Use the `public` schema within the dedicated Qualytics database. The database-level isolation already provides the separation that a custom schema would aim to achieve. If your organization has a policy requiring non-public schemas regardless of database isolation, please contact Qualytics support so we can evaluate the specific requirements.

---

## Summary

- **Is `pgcrypto` required?** — Optional. Recommended best practice included in the setup script, but not a hard requirement. Qualytics works without it.
- **What is `pgcrypto`?** — An official PostgreSQL extension bundled with every standard distribution — trusted, widely used, and non-invasive.
- **Are credentials encrypted?** — Yes. AES-256-GCM at the application layer — the database never sees plaintext.
- **Can we use a non-public schema?** — Not recommended. The dedicated database already provides full isolation. Using `public` within it is standard and supported.
