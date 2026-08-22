# Database Migration Scripts

This folder contains scripts for migrating the PostgreSQL database between servers (e.g. from Google Cloud to a new host).

## `migrate_db.sh`

Dumps the database from the **old server** and restores it on the **new server**.

### Prerequisites

* `pg_dump` and `pg_restore` / `psql` installed on the machine running the script.
* The machine must have network access to both the source and target PostgreSQL servers.
* The target database must already exist on the new server. Create it if needed:
  ```sql
  CREATE DATABASE <new_db_name>;
  ```

### Configuration

All options can be set via **environment variables** or **command-line flags** (flags take precedence).

| Environment variable | Flag | Description | Default |
|---|---|---|---|
| `OLD_DB_HOST` | `-H` | Source server hostname / IP | `localhost` |
| `OLD_DB_PORT` | `-P` | Source server port | `5432` |
| `OLD_DB_NAME` | `-d` | Source database name | *(required)* |
| `OLD_DB_USER` | `-U` | Source database user | *(required)* |
| `OLD_DB_PASSWORD` | `-p` | Source database password | *(use `.pgpass`)* |
| `NEW_DB_HOST` | `-h` | Target server hostname / IP | `localhost` |
| `NEW_DB_PORT` | `-q` | Target server port | `5432` |
| `NEW_DB_NAME` | `-D` | Target database name | same as source |
| `NEW_DB_USER` | `-u` | Target database user | *(required)* |
| `NEW_DB_PASSWORD` | `-w` | Target database password | *(use `.pgpass`)* |
| `DUMP_DIR` | `-o` | Local directory for dump files | `./dumps` |
| `DUMP_FILE` | `-f` | Explicit path to dump file | auto-generated |

### Usage examples

**Full migration (dump + restore):**
```bash
export OLD_DB_HOST=old-server.example.com
export OLD_DB_NAME=mydb
export OLD_DB_USER=myuser
export OLD_DB_PASSWORD=secret

export NEW_DB_HOST=new-server.example.com
export NEW_DB_NAME=mydb
export NEW_DB_USER=newuser
export NEW_DB_PASSWORD=newsecret

bash migration-scripts/migrate_db.sh
```

Or using flags:
```bash
bash migration-scripts/migrate_db.sh \
  -H old-server.example.com -d mydb -U myuser -p secret \
  -h new-server.example.com -D mydb -u newuser -w newsecret
```

**Dump only** (store the dump locally, do not restore yet):
```bash
bash migration-scripts/migrate_db.sh --dump-only \
  -H old-server.example.com -d mydb -U myuser -p secret \
  -o /var/backups/postgres
```

**Restore only** from an existing dump file:
```bash
bash migration-scripts/migrate_db.sh --restore-only \
  -f /var/backups/postgres/mydb_20240101_120000.dump \
  -h new-server.example.com -D mydb -u newuser -w newsecret
```

### Security notes

* Prefer using a [`~/.pgpass`](https://www.postgresql.org/docs/current/libpq-pgpass.html) file instead of passing passwords on the command line or in environment variables to avoid exposing credentials in shell history or process lists.
* Make sure the dump files are stored in a secure location with restricted permissions.
* Delete dump files after a successful migration if they are no longer needed.
