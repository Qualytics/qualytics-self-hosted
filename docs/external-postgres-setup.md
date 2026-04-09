# External PostgreSQL Setup

Qualytics supports connecting to an externally managed PostgreSQL instance instead of the bundled one. This is common in enterprise environments where customers run a shared PostgreSQL server and need to host multiple Qualytics deployments on it.

## Database-per-Deployment Model

Each Qualytics deployment (Helm release) connects to its own dedicated database on the shared server. This provides full DDL isolation, independent backups and restores, and no risk of cross-tenant interference.

```
postgres_server
  ├── qualytics_env1
  ├── qualytics_env2
  └── qualytics_...
```

## Per-Deployment Setup

Repeat the following steps for each Qualytics deployment, substituting `<tenant>` with a short identifier (e.g. `env1`, `test`) and `<strong_password>` with a secure password.

### 1. Create the service account

```sql
CREATE ROLE qualytics_<tenant> WITH LOGIN PASSWORD '<strong_password>';
```

### 2. Create the database and assign ownership

If the database does not exist yet:

```sql
CREATE DATABASE qualytics_<tenant> OWNER qualytics_<tenant>;
```

If the database already exists:

```sql
ALTER DATABASE qualytics_<tenant> OWNER TO qualytics_<tenant>;
```

Ownership grants full DDL rights within the database, which is required to run schema migrations.

### 3. Connect to the tenant database and grant schema privileges

```sql
\c qualytics_<tenant>
```

Grant explicit access on the public schema. This is required on PostgreSQL 15+, where the default `CREATE` privilege on `public` was revoked from all non-superuser roles:

```sql
GRANT ALL PRIVILEGES ON SCHEMA public TO qualytics_<tenant>;
```

### 4. Grant privileges on existing objects

If the database is being reused and already contains objects:

```sql
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO qualytics_<tenant>;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO qualytics_<tenant>;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO qualytics_<tenant>;
```

### 5. Set default privileges for future objects

Without this, tables created by migrations will not automatically inherit the correct permissions if any other role creates objects in the schema.

```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON TABLES TO qualytics_<tenant>;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON SEQUENCES TO qualytics_<tenant>;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON FUNCTIONS TO qualytics_<tenant>;
```

### 6. Optional: Enable the `pgcrypto` extension

The `pgcrypto` extension is **optional**. Qualytics performs all credential encryption at the application layer using AES-256-GCM, so `pgcrypto` is not required at runtime. The `gen_random_uuid()` function used during initial data seeding is a built-in PostgreSQL function on version 13+ and does not depend on `pgcrypto`.

If your organization permits installing extensions, you may optionally enable it as a best practice:

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;
```

If your organization's policy restricts PostgreSQL extensions, this step can be safely skipped. See the [External PostgreSQL FAQ](https://github.com/Qualytics/qualytics-self-hosted/blob/main/docs/external-postgres-faq.md) for more details on encryption and `pgcrypto`.

> **Keep the service account as the database owner.** Migrations need to create/drop tables, enums, functions, and sequences during upgrades, so they must run as a role with full DDL rights (the owner).

## PostgreSQL 15+ Note

PostgreSQL 15 revoked the default `CREATE` privilege on the `public` schema from all non-superuser roles. If you encounter the error:

```
ERROR: permission denied for schema public
```

ensure that step 3 was run after connecting to the target tenant database — not the `postgres` default database. The `\c qualytics_<tenant>` step is required before granting schema privileges.

## Full Example — Single Deployment

```sql
-- Run as superuser on the PostgreSQL server
CREATE ROLE qualytics_env1 WITH LOGIN PASSWORD 'Str0ng_P@ssword!';
CREATE DATABASE qualytics_env1 OWNER qualytics_env1;

\c qualytics_env1

GRANT ALL PRIVILEGES ON SCHEMA public TO qualytics_env1;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON TABLES TO qualytics_env1;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON SEQUENCES TO qualytics_env1;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON FUNCTIONS TO qualytics_env1;

-- Optional: enable pgcrypto (not required, see FAQ)
-- CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;
```

## Helm Chart Configuration

Once the database and service account are ready, configure each Helm release to use the external PostgreSQL instance.

**values.yaml**

```yaml
postgres:
  enabled: false   # Disable the bundled PostgreSQL StatefulSet

secrets:
  postgres:
    host: <your-postgres-host>
    port: 5432
    database: qualytics_<tenant>    # The dedicated database created above
    username: qualytics_<tenant>    # The service account created above
    password: <strong_password>
    secrets_passphrase: <passphrase>
```

**Applying the configuration**

```bash
helm upgrade --install qualytics qualytics/qualytics \
  --namespace qualytics \
  --create-namespace \
  -f values.yaml \
  --timeout=20m
```

## Validation Script (run by DBA)

Because Qualytics migrations use enums, sequences, functions, and triggers, validate the service account before handing the environment over. Run the following as the service account (or impersonating it) after completing the setup above:

```bash
export PGPASSWORD='<strong_password>'
psql "host=<your-postgres-host> port=5432 dbname=qualytics_<tenant> user=qualytics_<tenant>" -v ON_ERROR_STOP=1 <<'SQL'

\timing on
\echo 'Starting Qualytics external Postgres validation'

-- Table + index DDL (covers CREATE, ALTER, DROP on tables and indexes)
DROP TABLE IF EXISTS qualytics_permission_probe CASCADE;
CREATE TABLE qualytics_permission_probe (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    created TIMESTAMPTZ DEFAULT now()
);
INSERT INTO qualytics_permission_probe (name) VALUES ('ok');
ALTER TABLE qualytics_permission_probe ADD COLUMN note TEXT;
CREATE INDEX IF NOT EXISTS ix_qpp_created ON qualytics_permission_probe (created);
DROP INDEX IF EXISTS ix_qpp_created;
DROP TABLE IF EXISTS qualytics_permission_probe CASCADE;

-- Sequence privileges (migrations create/drop sequences)
DROP SEQUENCE IF EXISTS qualytics_permission_probe_seq;
CREATE SEQUENCE qualytics_permission_probe_seq;
SELECT nextval('qualytics_permission_probe_seq') AS seq_smoke_test;
DROP SEQUENCE IF EXISTS qualytics_permission_probe_seq;

-- Function privileges (Qualytics creates helper functions)
DROP FUNCTION IF EXISTS qualytics_permission_probe_fn() CASCADE;
CREATE FUNCTION qualytics_permission_probe_fn()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN 1;
END;
$$;
SELECT qualytics_permission_probe_fn();
DROP FUNCTION IF EXISTS qualytics_permission_probe_fn();

-- Enum privileges (migrations use CREATE TYPE + ALTER TYPE ... ADD VALUE)
DROP TYPE IF EXISTS qualytics_permission_probe_enum;
CREATE TYPE qualytics_permission_probe_enum AS ENUM ('seed');

\echo 'Committing before ALTER TYPE ... ADD VALUE (requires no active transaction)'
COMMIT;
ALTER TYPE qualytics_permission_probe_enum ADD VALUE IF NOT EXISTS 'migrated';
BEGIN;
DROP TYPE IF EXISTS qualytics_permission_probe_enum;

-- UUID generation (built-in on PostgreSQL 13+, no extension required)
SELECT gen_random_uuid() AS uuid_smoke_test;

\echo 'All Qualytics permission probes completed successfully.'
SQL
```

If every statement succeeds the DBA can be confident that:

- The service account can create/alter/drop tables, sequences, indexes, and functions.
- Enum migrations that require `ALTER TYPE ... ADD VALUE` can run (this is the most restrictive migration requirement).
- The built-in `gen_random_uuid()` function works as expected.

After validation, provide the `DATABASE_URL` (or the Helm `secrets.postgres.*` values) to the deployment team.
