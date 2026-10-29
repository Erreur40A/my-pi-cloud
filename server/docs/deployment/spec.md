# Deployment — V1 specification

## Stack

- Everything runs in **Docker**, described by a Compose file in the repo: Nginx (reverse proxy + web app), Spring Boot, PostgreSQL.
- Goal: anyone can clone the repo, fill in `.env` from `.env.exemple`, and start the stack. A hand-installed service on the host would break that.
- Only Nginx publishes ports (80, 443). Spring Boot and PostgreSQL talk on an internal Docker network and publish none.

### Security checklist

Docker hides several traps: everything works while being exposed.

- **Published ports bypass ufw.** Docker inserts its own iptables rules before ufw. Publish on the Pi's LAN IP only, or filter in the `DOCKER-USER` chain; check from another machine, not from the Pi.
- **Non-root user** in every image.
- **The `docker` group is root-equivalent** on the host: add no one to it lightly.
- **Never mount `/var/run/docker.sock`** into a container.
- Hardening in Compose: `read_only`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, memory limits.
- **Pinned image versions**, updated by hand: unlike `apt`, nothing updates them automatically.
- **No secret in an image or in the repo**: `.env` is not versioned, only `.env.exemple` is.
- Volumes (files, PostgreSQL data) owned by the containers' non-root UID.

## Compose files

| File | Loaded | Content |
|---|---|---|
| `compose.yaml` | Always | Production. Safe on its own: PostgreSQL publishes no port. |
| `compose.dev.yaml` | Only with `-f` | Development additions, e.g. PostgreSQL published on `127.0.0.1:5432` for `bootRun`. |

- Production: `docker compose up -d`. Development: `docker compose -f compose.yaml -f compose.dev.yaml up -d`.
- Why production is the base: someone who forgets `-f` on the Pi gets the safe setup. With development as the base, production would have to remove the port with `!reset` (merging adds list entries, it never removes them), and forgetting the production file would publish it.
- Why not `compose.override.yaml`: Compose loads it automatically whenever it exists. The Pi has a full clone of the repo, so the development file would be loaded in production.
- Versioning the production file is safe: it holds no secret value. Values come from `.env` (not versioned) and the JWT key from `secrets/` (git-ignored).

### Configuration reaching Spring Boot

- Production: Compose reads `.env` and passes values to the container as **environment variables**, which Spring Boot reads before `application.properties`. The `.env` file itself is never copied into the container.
- Not as command-line arguments: any user of the Pi sees them with `ps aux`, while `/proc/<pid>/environ` is readable only by the process owner.
- Database URL: `application.properties` holds the development URL (`localhost`); production overrides it whole with `SPRING_DATASOURCE_URL`, which Spring Boot maps to `spring.datasource.url` (relaxed binding).
  - Why: it is Spring Boot's standard variable, so no custom placeholder to maintain.
  - The database name stays in `.env` only: `compose.yaml` builds the URL with `${POSTGRES_DB}`, as it already does for the PostgreSQL service.
  - Rejected: a `${DB_HOST:localhost}` placeholder. It works too, but adds a project-specific variable for no gain.
- Development: `bootRun` runs on the host, outside Docker. Spring Boot imports the root `.env` itself with `spring.config.import=optional:file:../.env[.properties]`.
  - `optional:` because the file does not exist inside the production container. Trap: a wrong path is skipped silently too; remove `optional:` once to check the file is found.
  - `[.properties]` because Spring Boot picks a loader from the file extension, and `.env` has none. Without it, startup fails.
  - Not `env:`: it reads properties stored *inside* an environment variable, not a `.env` file.

## Images

- Images are **built on the Pi**. The dev machine is x86, the Pi is ARM: an image built on the PC would not run there.
- Official base images (`eclipse-temurin`, `postgres`, `nginx`) are published for both architectures under the same tag: Docker picks the right one, nothing to write for it.
- The Spring Boot `Dockerfile` is **multi-stage**:
  1. a build stage with the JDK and Gradle compiles the `.jar`;
  2. the final stage holds **only a JRE** and the `.jar`.

  Why: a smaller image, and a smaller attack surface (a compiler in production is a tool handed to an attacker). Nothing but Docker is installed on the Pi.
- Spring Boot images are **tagged with the git tag** (`v1.2.0`), and the Pi keeps the **last three**; the deploy script deletes older ones. Why: with a single name, each build replaced the previous image, and a rollback had to rebuild it (minutes of downtime, and a build that can fail too).
- The Spring Boot container has a Compose `healthcheck` calling `/actuator/health`. The final image has no `curl` (checked: the `eclipse-temurin` JRE image has neither `curl` nor `wget`), and adding one would bring back a tool for an attacker. The call is made by a small Java class using the JDK's HTTP client, compiled in the build stage and copied into the final image (a JRE cannot run a `.java` source file: that needs the `jdk.compiler` module).

## Startup

- systemd starts the Docker daemon at boot; Docker restarts the containers through their restart policy (`restart: unless-stopped`).
- Order: PostgreSQL, then Spring Boot, then Nginx.
- A started PostgreSQL container is not a **ready** PostgreSQL. Its Compose `healthcheck` runs `pg_isready`, and Spring Boot waits with `depends_on: { postgres: { condition: service_healthy } }`. Without it, Spring Boot crashes and restarts in a loop until the database answers.
- Spring Boot's own health is exposed by Actuator (`/actuator/health`), which also checks the database connection.

## Updates

### Trigger

- The Pi **pulls**: a cron job runs `git fetch --tags` in its clone of the repo. The connection goes out from the Pi, so nothing is exposed. GitHub cannot reach the Pi anyway (LAN only).
- **Only a new tag is deployed** (`v1.2.0`), never a plain push to `main`
- Tags are **signed** (`git tag -s`). Before deploying, the Pi runs `git verify-tag` and trusts **only my public key**. The private key never goes to GitHub: a stolen GitHub account cannot get code to run on the Pi.
- The deployed version is the checked-out tag itself: no separate version file to drift out of sync.

### Steps

1. Verify the tag's signature; stop if it fails.
2. `pg_dump` the database.
3. Build the new image **while the old version keeps running**. If the build fails, the old version stays up.
4. Switch (`docker compose up -d --wait`): a few seconds of downtime, accepted. Uploads interrupted by the switch resume on their own (chunks received are stored in the database, see [file-storage](../file-storage/spec.md#2-chunks)).
5. `--wait` returns once every service is healthy, or with an error code if one is not. On error, roll back. Why: without this check, `up -d` returns at once and a version failing at startup (a broken migration, for instance) restarts in a loop with nobody noticing.

### Rollback

Check out the previous tag, start its image (still on the Pi), and restore the dump taken at step 2 (a Flyway migration may have changed the schema).

### Rejected

- **GitHub Actions deploying to the Pi**: it would need a self-hosted runner on the Pi, which GitHub strongly advises against for a public repo (a pull request from anyone could run code on it). GitHub Actions is still used to build and run the tests on GitHub's machines.
- **Canary (50/50) or blue/green**: both versions would share one database. A migration renaming a column breaks the old version's queries (there is no fallback: they fail). Running two versions safely needs *expand and contract* migrations, too heavy for a handful of users.
- **Restoring from PostgreSQL's old row versions**: MVCC keeps them only for running transactions, and `VACUUM` removes them. It is not a history.

## Backups

- The rule of three copies is out of budget (no NAS); only USB keys are available.
- The **database is small** (metadata only) but is the **most valuable part**: without it, files are a pile of UUIDs with no name or folder. It is the cheapest and most important thing to back up.
- **Order: database first, then files.**
  - Files first: a file uploaded between the two copies is in the database backup but not in the file backup. After a restore, the app shows a file that does not exist.
  - Database first: the same file is on disk but unknown to the database. After a restore, it is an invisible orphan: wasted space, nothing broken.
  - Renames and moves do not matter here: they only touch the database, the physical file never changes.
- Do not run a backup at the same time as the trash purge: a file deleted during the copy is the one case "database first" does not cover.
- **Accepted limitation:** files have no second copy in V1. If the SSD dies, they are lost. Users must know the cloud is not a backup of their phone.

## Open

- Backup schedule and destination (USB key for the database dumps).
- Cron frequency for the update check.
- Where `acme.sh` runs and how Nginx reloads a renewed certificate (see [network](../network/spec.md#open)).
- Rollback steps in detail, once the deploy script exists.
- Database passwords for the Spring Boot container (`db_owner_password`, `db_app_password`, see [database](../database/spec.md#secrets)): read with `configtree:` on `/run/secrets/`. The secret files are `400` owned by PostgreSQL's UID 999, unreadable by Spring Boot's non-root user. Direction chosen: a dedicated non-root user for Spring Boot, sharing a group with PostgreSQL, and these two files in `440` (the superuser's stays `400`). Rejected: running Spring Boot as UID 999 (after a container escape, the attacker would be the owner of the database files on the host), and two copies of each secret (they drift apart). Still to decide: which GID, and checking it is not used by a group on the Pi's host.
