#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Check if replication user already exists
    DO \$\$
    BEGIN
       IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${POSTGRES_REPLICATION_USER}') THEN
          CREATE USER ${POSTGRES_REPLICATION_USER} WITH REPLICATION PASSWORD '${POSTGRES_REPLICATION_PASSWORD}';
       ELSE
          ALTER USER ${POSTGRES_REPLICATION_USER} WITH REPLICATION PASSWORD '${POSTGRES_REPLICATION_PASSWORD}';
          RAISE NOTICE 'User replicator already exists, password updated.';
       END IF;
    END
    \$\$;
EOSQL

echo "Replication user check/creation complete."
