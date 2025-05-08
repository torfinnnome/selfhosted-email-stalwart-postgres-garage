#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# Environment variables expected:
# PRIMARY_HOST
# REPLICATION_USER
# REPLICATION_PASSWORD
# PGDATA=/var/lib/postgresql/data/pgdata (Set in compose env)

echo "Standby setup script started."
echo "PGDATA is set to: $PGDATA"
echo "Parent directory is: $(dirname "$PGDATA")"

# Check if the data directory is already initialized *and contains PG_VERSION*
if [ -s "$PGDATA/PG_VERSION" ]; then
  echo "Data directory $PGDATA already contains a PostgreSQL cluster (PG_VERSION found)."

  # Ensure standby.signal exists if we are restarting an existing standby
  # Needed because postgresql.auto.conf might get overwritten on startup if not careful
  touch "$PGDATA/standby.signal"
  echo "Ensured standby.signal exists."

  # Ensure correct ownership before starting postgres
  echo "Ensuring correct ownership of $PGDATA..."
  chown -R postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"
  echo "Ownership and permissions set for $PGDATA."

else
  echo "Data directory $PGDATA is empty or does not contain a valid cluster."

  # Wait for the primary server to be available
  echo "Waiting for primary server ($PRIMARY_HOST:5432) to become available..."
  # Use pg_isready with connection string for password security
  export PGPASSWORD="$REPLICATION_PASSWORD"
  until pg_isready -h "$PRIMARY_HOST" -p 5432 -U "$REPLICATION_USER" -d "dbname=postgres" -q; do
    echo "Primary is not ready yet - sleeping"
    sleep 5
  done
  unset PGPASSWORD
  echo "Primary server is ready."

  # *** REMOVED the problematic 'find ... -delete' line ***
  # pg_basebackup will fail if the directory exists and is not empty.
  # It will create the directory if it doesn't exist.
  # Ensure parent directory exists and is writable (Docker volume mount should handle this)
  PARENT_DIR=$(dirname "$PGDATA")
  if [ ! -d "$PARENT_DIR" ]; then
    echo "Error: Parent directory $PARENT_DIR does not exist."
    exit 1
  fi
  echo "Parent directory $PARENT_DIR exists."

  # Run pg_basebackup
  echo "Running pg_basebackup..."
  # Use PGPASSWORD environment variable for pg_basebackup
  export PGPASSWORD="$REPLICATION_PASSWORD"
  pg_basebackup \
    --host=$PRIMARY_HOST \
    --port=5432 \
    --username=$REPLICATION_USER \
    --pgdata="$PGDATA" \
    --wal-method=stream \
    --checkpoint=fast \
    --progress \
    --verbose \
    --write-recovery-conf # Creates standby.signal/postgresql.auto.conf entries

  # Check if pg_basebackup was successful
  if [ $? -ne 0 ]; then
    echo "pg_basebackup failed!"
    unset PGPASSWORD # Unset password even on failure
    exit 1
  fi
  unset PGPASSWORD # Unset password after successful use
  echo "pg_basebackup completed successfully."

  # Recommended: Explicitly ensure primary_slot_name is in postgresql.auto.conf
  # The -R flag should add primary_conninfo, this makes sure slot name is there too.
  # Use 'grep -q || echo' to add only if not present
  if ! grep -q "primary_slot_name" "$PGDATA/postgresql.auto.conf"; then
    echo "primary_slot_name = 'standby1_slot'" >>"$PGDATA/postgresql.auto.conf"
    echo "Added primary_slot_name to postgresql.auto.conf"
  else
    echo "primary_slot_name already exists in postgresql.auto.conf"
  fi

  # Ensure standby.signal exists (pg_basebackup --write-recovery-conf should create it)
  # Use touch just in case, doesn't hurt.
  touch "$PGDATA/standby.signal"
  echo "Ensured standby.signal exists."

  # Set correct permissions/ownership *after* pg_basebackup creates the directory
  echo "Setting ownership and permissions for newly created $PGDATA..."
  chown -R postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"
  echo "Ownership and permissions set for $PGDATA."

fi

echo "Starting PostgreSQL in standby mode as user 'postgres'..."
exec gosu postgres postgres
