#!/usr/bin/env bash
set -Eeuo pipefail

owner_password="$(< /run/secrets/db_owner_password)"
app_password="$(< /run/secrets/db_app_password)"

# The passwords go through psql variables: :'name' quotes them as SQL literals,
# so a quote in a password cannot break out of the statement.
psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc \
  --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v owner_password="$owner_password" \
  -v app_password="$app_password" <<'SQL'
CREATE ROLE cloud_owner LOGIN PASSWORD :'owner_password';
CREATE ROLE cloud_app LOGIN PASSWORD :'app_password';

CREATE SCHEMA cloud AUTHORIZATION cloud_owner;
GRANT USAGE ON SCHEMA cloud TO cloud_app;

ALTER DEFAULT PRIVILEGES FOR ROLE cloud_owner IN SCHEMA cloud
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO cloud_app;

ALTER ROLE cloud_app SET search_path = cloud;
SQL
