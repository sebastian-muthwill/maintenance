# Database Migration Scripts

This folder contains scripts for migrating the PostgreSQL database between servers (e.g. from Google Cloud to a new host).
! Only same Postgresql server versions are supported !

## `migrate_pg_db.sh`

Dumps the database from the **old server** and restores it on the **new server**.

### Prerequisites

* `pg_dump` and `pg_restore` / `psql` installed on the machine running the script. (Install with `sudo apt install -y postgresql-client`)
* The machine must have network access to both the source and target PostgreSQL servers.
* The target database must already exist on the new server. Create it if needed:
  ```sql
  CREATE DATABASE <new_db_name>;
  ```

### Configuration

All options can be set via **environment variables** or **command-line flags** (flags take precedence).

When `OLD_DB_PGPASSFILE` / `--old-pgpassfile` is set, the script can derive missing source values (`host`, `port`, `database`, `user`) from the first matching entry in that file. The same applies for target values when `NEW_DB_PGPASSFILE` / `--new-pgpassfile` is set.

| Environment variable | Flag | Description | Default |
|---|---|---|---|
| `OLD_DB_HOST` | `-H` | Source server hostname / IP | from `.pgpass` or `localhost` |
| `OLD_DB_PORT` | `-P` | Source server port | from `.pgpass` or `5432` |
| `OLD_DB_NAME` | `-d` | Source database name | from `.pgpass` or *(required)* |
| `OLD_DB_USER` | `-U` | Source database user | from `.pgpass` or *(required)* |
| `OLD_DB_PASSWORD` | `-p` | Source database password | *(use `.pgpass`)* |
| `OLD_DB_PGPASSFILE` | `--old-pgpassfile` | Path to source `.pgpass` file | *(optional)* |
| `NEW_DB_HOST` | `-h` | Target server hostname / IP | from `.pgpass` or `localhost` |
| `NEW_DB_PORT` | `-q` | Target server port | from `.pgpass` or `5432` |
| `NEW_DB_NAME` | `-D` | Target database name | from `.pgpass` or same as source |
| `NEW_DB_USER` | `-u` | Target database user | from `.pgpass` or *(required)* |
| `NEW_DB_PASSWORD` | `-w` | Target database password | *(use `.pgpass`)* |
| `NEW_DB_PGPASSFILE` | `--new-pgpassfile` | Path to target `.pgpass` file | *(optional)* |
| `DUMP_DIR` | `-o` | Local directory for dump files | `./dumps` |
| `DUMP_FILE` | `-f` | Explicit path to dump file | auto-generated |
| `DUMP_DATA_ONLY` | `--data-only` | Dump data only (no schema/constraints) | `false` |

### Usage examples

**Full migration (dump + restore):**
```bash
export OLD_DB_PGPASSFILE=/secure/old-db.pgpass

export NEW_DB_PGPASSFILE=/secure/new-db.pgpass

bash migration-scripts/postgresql-migration/migrate_pg_db.sh
```

Or using flags:
```bash
bash migration-scripts/postgresql-migration/migrate_pg_db.sh \
  --old-pgpassfile /secure/old-db.pgpass \
  --new-pgpassfile /secure/new-db.pgpass
```

**Dump only** (store the dump locally, do not restore yet):
```bash
bash migration-scripts/postgresql-migration/migrate_pg_db.sh --dump-only \
  --old-pgpassfile /secure/old-db.pgpass \
  -o /var/backups/postgres
```

**Dump only (data-only for existing target schema, e.g. Coolify UI import):**
```bash
bash migration-scripts/postgresql-migration/migrate_pg_db.sh --dump-only --data-only \
  --old-pgpassfile /secure/old-db.pgpass \
  -o /var/backups/postgres
```

**Restore only** from an existing dump file:
```bash
bash migration-scripts/postgresql-migration/migrate_pg_db.sh --restore-only \
  -f /var/backups/postgres/mydb_20240101_120000.dump \
  --new-pgpassfile /secure/new-db.pgpass
```

Example `.pgpass` files:

```text
# /secure/old-db.pgpass
old-server.example.com:5432:mydb:myuser:old_password
```

```text
# /secure/new-db.pgpass
new-server.example.com:5432:mydb:newuser:new_password
```

### Security notes

* Prefer using `.pgpass` files instead of passing passwords on the command line or in environment variables to avoid exposing credentials in shell history or process lists.
* The script supports one `.pgpass` file for the source connection (`OLD_DB_PGPASSFILE` / `--old-pgpassfile`) and one for the target connection (`NEW_DB_PGPASSFILE` / `--new-pgpassfile`).
* If connection fields are omitted, the script reads them from the first matching entry in the corresponding `.pgpass` file.
* `.pgpass` files should contain entries in the format `hostname:port:database:username:password` and must be readable by the executing user. `chmod 0600 ~/.pgpass`
* Make sure the dump files are stored in a secure location with restricted permissions.
* Delete dump files after a successful migration if they are no longer needed.

### Compatibility note (Cloud SQL -> other PostgreSQL hosts)

If your source database was created by a provider-specific admin role (for example `cloudsqlsuperuser` on Google Cloud SQL), restores can fail on other platforms with errors like:

```text
pg_restore: error: could not execute query: ERROR:  role "cloudsqlsuperuser" does not exist
Command was: ALTER SCHEMA public OWNER TO cloudsqlsuperuser;
```

This script now creates dumps with `--no-owner --no-privileges`, so ownership and ACL statements are not included in the dump output.

If you need to restore an older dump that still contains role ownership metadata, restore it with:

```bash
pg_restore --no-owner --no-privileges --dbname=<target_db> <dump_file>
```

### Compatibility note (existing schema on Coolify)

If the target database already has tables/constraints (for example after running Django migrations), importing a full schema+data dump can fail with many `constraint ... already exists` errors.

Use a **data-only** dump for this case:

```bash
bash migration-scripts/postgresql-migration/migrate_pg_db.sh --dump-only --data-only \
  --old-pgpassfile /secure/old-db.pgpass \
  -f /var/backups/postgres/app_data_only.dump
```

Then import that dump in Coolify UI. This avoids recreating schema objects (constraints, indexes, foreign keys) that already exist.
