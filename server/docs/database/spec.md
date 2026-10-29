# Database — V1 specification

## Migrations

- Flyway runs the migrations **at Spring Boot startup** (Spring Boot's default behaviour with `spring-boot-starter-flyway`).
- Why: a single instance, deployed by tag (see [deployment](../deployment/spec.md#updates)). No separate migration step to forget, and no two servers racing to migrate.
- Migrations are **hand-written SQL** (`V<n>__<description>.sql`), the source of truth for the schema. Hibernate runs with `spring.jpa.hibernate.ddl-auto=validate`: at startup it checks that the entities match the schema and refuses to start otherwise. Rejected: letting Hibernate create or update the schema (`ddl-auto=update`): no history, nothing to review, and it never drops or renames cleanly.
- PostgreSQL supports DDL inside a transaction, and Flyway wraps each migration in one: a failed migration usually leaves the schema as it was. Spring Boot then fails to start.

## Roles

| Role | Used by | Rights |
|---|---|---|
| Superuser (`POSTGRES_USER`) | PostgreSQL container only (initialisation) | Everything, including running commands in the container (`COPY … FROM PROGRAM`) |
| Schema owner | Flyway (`spring.flyway.user`) | DDL: `CREATE`, `ALTER`, `DROP` on the application schema |
| Application role | Spring Boot (`spring.datasource.username`) | DML only: `SELECT`, `INSERT`, `UPDATE`, `DELETE` |

- Why: least privilege. Under an SQL injection through an endpoint, the damage depends on the role behind the query:
  - superuser: commands run inside the container;
  - schema owner: tables dropped or altered;
  - application role: rows read, rewritten or deleted. Rewriting a row with false data is as bad as deleting it: least privilege **reduces** the damage, it does not remove it.
- Spring Boot uses two connections: Flyway's, as the owner, and the application's, with DML only. The superuser password no longer goes into the Spring Boot container.
- PostgreSQL roles are not Linux users. UID 999 is the Linux user running the PostgreSQL process and owning its data files; Spring Boot never acts as it. Spring Boot authenticates over TCP with a role name and password, and PostgreSQL checks that role's rights.
- Rejected:
  - one role for both migrations and queries: an injection could drop tables;
  - the superuser for Flyway: its password would sit in the Spring Boot container, and it can run commands.

## Role creation

- The schema owner and the application role are created by a script in `/docker-entrypoint-initdb.d/`, run by the PostgreSQL image as the superuser.
- The script is a **shell script** (`.sh`), not a `.sql` file: SQL cannot read the passwords from the secret files in `/run/secrets/`. The script reads them and passes them to `psql`; no password is written in the repository.
  - The passwords go through `psql -v` variables, used as `:'name'`: `psql` quotes them as SQL literals. Pasting them into the SQL from the shell would be an SQL injection in the init script itself, as soon as a password holds a quote.
- Script: [`postgres/init/create-roles.sh`](../../../postgres/init/create-roles.sh), mounted read-only on `/docker-entrypoint-initdb.d/`. Names: schema `cloud`, owner `cloud_owner`, application role `cloud_app`. Secrets: `db_owner_password`, `db_app_password`.
- The image runs these scripts **only when the data directory is empty**, i.e. when the volume is created, never on later starts. On the Pi, this is the expected behaviour: the roles are created once.
- Why not a Flyway migration:
  - Flyway needs the owner role to connect **before** running the first migration: a migration cannot create it;
  - a migration creating the application role would hold its password in a file committed to a public repository.
- Development: the dev volume already exists, so the script does not run on it. Recreate the volume:

  ```bash
  docker compose -f compose.yaml -f compose.dev.yaml down -v
  docker compose -f compose.yaml -f compose.dev.yaml up -d
  ```

  **Development only.** On the Pi, `down -v` deletes every file's metadata.

## Schema

- The application's tables live in a **dedicated schema**, created by the init script and owned by the schema owner (`CREATE SCHEMA … AUTHORIZATION <owner>`).
- Why: since PostgreSQL 15, `PUBLIC` no longer has `CREATE` on the `public` schema, so the owner could not create its tables there. A dedicated schema matches the "schema owner" role, instead of granting rights on a schema shared with every role.
- The application role gets `USAGE` on the schema. PostgreSQL checks rights at two levels: without `USAGE` on the schema, a `SELECT` granted on a table inside it still fails with `permission denied for schema`.
- `spring.flyway.schemas` names the schema Flyway manages; its history table (`flyway_schema_history`) is created there.
- The application role's `search_path` is set in the database by the init script (`ALTER ROLE <application role> SET search_path = <schema>`).
  - Why it is needed: the default `search_path` is `"$user", public`, where `$user` is the schema **named** like the connected role, not the schemas it owns. An unqualified `SELECT … FROM files` from the application role looks in a schema named after the role, then in `public`, and fails with `relation "files" does not exist`. Flyway does not hit this: it sets the `search_path` of its own connection to its schema while migrating.
  - Why in the database rather than in Spring Boot (`currentSchema=` in the JDBC URL, or Hibernate's `default_schema`): it also applies to a `psql` session opened with the application role to debug.

## Tables

Every table of the schema, in one place. The specs linked in each section give the reasons behind the columns. Naming: `snake_case`, unquoted (PostgreSQL folds unquoted names to lowercase, and Spring Boot maps a Java field `createdAt` to a column `created_at`).

### `users`

See [auth](../auth/spec.md#accounts).

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `uuid` | primary key, `DEFAULT uuidv7()` | see [Ids](#ids) |
| `email` | `text` | `NOT NULL`, unique, must equal `lower(trim(email))` | login identifier, not the primary key |
| `password_hash` | `text` | `NOT NULL` | Argon2id encoded string, salt and parameters included (see [auth](../auth/spec.md#passwords)) |
| `created_at` | `timestamptz` | `NOT NULL`, `DEFAULT now()` | |
| `updated_at` | `timestamptz` | `NOT NULL`, `DEFAULT now()`, set by a trigger on `UPDATE` | when the email or the password last changed |

- The `updated_at` trigger lives in the database, not in Hibernate (`@UpdateTimestamp`) or the service: the `DEFAULT` only applies on `INSERT`, and a trigger also covers an `UPDATE` run by hand in `psql`.
- The trigger has no `WHEN (OLD.* IS DISTINCT FROM NEW.*)` clause: an `UPDATE` that changes nothing still moves `updated_at`. Accepted because Hibernate's dirty checking only sends an `UPDATE` for an entity whose fields actually changed. Exceptions to keep in mind: bulk JPQL/HQL updates (`UPDATE User u SET …`) and native queries bypass dirty checking, as do `UPDATE`s run by hand in `psql`.

## Rights on future tables

- A `GRANT … ON ALL TABLES` only covers the tables that exist when it runs. When the init script runs, Flyway has created nothing yet.
- The init script, as the superuser, sets **default privileges**: every table the owner creates later is readable and writable by the application role.

  ```sql
  ALTER DEFAULT PRIVILEGES FOR ROLE <owner>
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO <application role>;
  ```

  - `FOR ROLE` names the role whose **future objects** are concerned (the owner, since Flyway creates the tables); `TO` names the role receiving the rights.
  - A superuser may set default privileges for any role.
- Exception: `flyway_schema_history`. Flyway creates it as the owner, so the default privileges give the application role write access to it. The first migration revokes them (`REVOKE ALL ON flyway_schema_history FROM cloud_app`); Flyway creates the table before running that migration, so it already exists. Why: this table is Flyway's only memory. Rows deleted through an SQL injection would make Flyway replay old migrations and the server fail to start; a changed checksum fails validation; a fake row would skip a real migration.

## Ids

- Primary keys are **UUIDs**, not `GENERATED … AS IDENTITY`.
- Why: an identity id can be guessed (`/users/42` means `/users/43` likely exists); a UUID v4 holds 122 random bits. No sequence either, so no extra rights to grant on one.
- **UUID v7**, generated by PostgreSQL 18's `uuidv7()` as the column's `DEFAULT`.
  - It starts with a timestamp: ids are ordered by creation, which keeps the primary key's B-tree inserts at its end (faster, less page splitting than random v4).
  - The cost, accepted: anyone holding an id knows when the row was created. For a family cloud, a creation date reveals nothing worth hiding. The rest of the id stays random, so ids still cannot be guessed.

## Dates

- Dates are `timestamptz`, never `timestamp`. A `timestamptz` is an instant: PostgreSQL stores it in UTC and converts it on the way in and out, so the server's time zone cannot shift it. A `timestamp` is a wall-clock time with no zone: the same value means a different instant depending on where it was written. Clients display it in the user's time zone.
- Creation dates are recorded from the start: a column added later stays empty for every existing row.

## Secrets

Three passwords, one file each in `secrets/`:

| Secret | Read by |
|---|---|
| Superuser | PostgreSQL |
| Schema owner | PostgreSQL (init script), Spring Boot (Flyway) |
| Application role | PostgreSQL (init script), Spring Boot (datasource) |

- Without Swarm, a Compose `file:` secret is a bind mount: inside the container, the file keeps its owner and mode from the host (`uid`, `gid` and `mode` are ignored). The superuser's file can stay `400` owned by UID 999. The two others must be readable by both containers: shared group and `440`, see [deployment](../deployment/spec.md#open).

## Open
