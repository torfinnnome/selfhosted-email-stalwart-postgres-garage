#!/bin/bash
set -o pipefail # Ensure pipeline errors are captured
set -e # Exit on errors

# --- Configuration (SET THESE ENVIRONMENT VARIABLES or hardcode carefully) ---

# Required: Docker Container Name
CONTAINER_NAME=${CONTAINER_NAME:-"postgres"} # Name of your primary DB container

# Required: PostgreSQL Connection Details (Used INSIDE the container)
export PGUSER=${PGUSER:-"myuser"}           # The user defined in docker-compose.yml
export PGDATABASE=${PGDATABASE:-"mydb"}  # The database name defined in docker-compose.yml
# !! SECURITY !! Set PGPASSWORD securely (see notes below)
# Example: export PGPASSWORD="mysecretpassword" (NOT recommended directly in script)

# Required: Backup Directory on Host
BACKUP_DIR=${BACKUP_DIR:-"/backup/postgres"} # **SET THE CORRECT ABSOLUTE PATH**

# Optional: Retention Policy for Database Dumps
KEEP_DAYS=${KEEP_DAYS:-7}     # Days of daily backups to keep
KEEP_WEEKS=${KEEP_WEEKS:-4}    # Weeks of *end-of-week* backups to keep
KEEP_MONTHS=${KEEP_MONTHS:-12}   # Months of *end-of-month* backups to keep

# --- Script Logic ---

# Check required vars
if [ -z "$PGUSER" ] || [ -z "$PGDATABASE" ] || [ -z "$BACKUP_DIR" ] || [ -z "$CONTAINER_NAME" ]; then
  echo "Error: CONTAINER_NAME, PGUSER, PGDATABASE, and BACKUP_DIR must be set."
  exit 1
fi
# Check PGPASSWORD separately for a better warning
if [ -z "$PGPASSWORD" ]; then
    echo "Error: PGPASSWORD must be set for docker exec."
    exit 1
fi

# Create absolute path for backup dir just in case
mkdir -p "${BACKUP_DIR}"

# Derived Variables for file naming
DATE_SUFFIX=$(date +"%Y%m%d_%H%M%S")
DAY_OF_WEEK=$(date +"%u") # 1 (Mon) to 7 (Sun)
DAY_OF_MONTH=$(date +"%d") # 01 to 31
BACKUP_FILE_DAILY="${BACKUP_DIR}/${PGDATABASE}_${DATE_SUFFIX}-daily.sql.gz"
BACKUP_FILE_LATEST="${BACKUP_DIR}/${PGDATABASE}_latest.sql.gz" # Symlink
GLOBALS_FILE="${BACKUP_DIR}/globals_${DATE_SUFFIX}.sql"
GLOBALS_FILE_LATEST="${BACKUP_DIR}/globals_latest.sql"

# --- Logging ---
echo "-------------------------------------"
echo "Starting PostgreSQL docker exec backup at $(date)"
echo "Container:     ${CONTAINER_NAME}"
echo "Database:      ${PGDATABASE}"
echo "User:          ${PGUSER}"
echo "Backup Dir:    ${BACKUP_DIR}"
echo "Keep Dailies:  ${KEEP_DAYS}"
echo "Keep Weeklies: ${KEEP_WEEKS}"
echo "Keep Monthlies:${KEEP_MONTHS}"
echo "-------------------------------------"

# --- Perform the Database Backup using docker exec ---
echo "Starting pg_dump for ${PGDATABASE} via docker exec..."
# Execute pg_dump and gzip *inside* the container, pipe output to host file
docker exec \
  -e PGPASSWORD="$PGPASSWORD" \
  "$CONTAINER_NAME" \
  bash -c "pg_dump -Fc --host=localhost --username=$PGUSER --dbname=$PGDATABASE | gzip -9" > "${BACKUP_FILE_DAILY}"

if [ $? -eq 0 ]; then
  echo "Daily database backup successful: ${BACKUP_FILE_DAILY}"
else
  echo "ERROR: docker exec pg_dump failed!"
  # Optional: Capture docker exec error output?
  exit 1
fi

# --- Perform Globals Backup (Roles, Tablespaces) using docker exec ---
echo "Starting pg_dumpall --globals-only via docker exec..."
docker exec \
  -e PGPASSWORD="$PGPASSWORD" \
  "$CONTAINER_NAME" \
  pg_dumpall --globals-only --host=localhost --username=$PGUSER > "${GLOBALS_FILE}"

if [ $? -eq 0 ]; then
  echo "Globals backup successful: ${GLOBALS_FILE}"
else
  echo "ERROR: docker exec pg_dumpall failed!"
  # Don't necessarily exit, database backup might be more critical
fi

# --- Create/Update Latest Symlinks ---
ln -fs "$(basename "${BACKUP_FILE_DAILY}")" "${BACKUP_FILE_LATEST}"
echo "Updated latest DB symlink: ${BACKUP_FILE_LATEST} -> $(basename "${BACKUP_FILE_DAILY}")"
if [ -f "${GLOBALS_FILE}" ]; then
    ln -fs "$(basename "${GLOBALS_FILE}")" "${GLOBALS_FILE_LATEST}"
    echo "Updated latest Globals symlink: ${GLOBALS_FILE_LATEST} -> $(basename "${GLOBALS_FILE}")"
fi

# --- Tag Weekly DB Backup (Hard Link) ---
if [ "${DAY_OF_WEEK}" -eq 7 ]; then
  WEEKLY_LINK="${BACKUP_DIR}/$(basename "${BACKUP_FILE_DAILY}" "-daily.sql.gz")-weekly.sql.gz"
  ln "${BACKUP_FILE_DAILY}" "${WEEKLY_LINK}"
  echo "Tagged weekly DB backup: ${WEEKLY_LINK}"
fi

# --- Tag Monthly DB Backup (Hard Link) ---
if [ "${DAY_OF_MONTH}" -eq 1 ]; then
  MONTHLY_LINK="${BACKUP_DIR}/$(basename "${BACKUP_FILE_DAILY}" "-daily.sql.gz")-monthly.sql.gz"
  ln "${BACKUP_FILE_DAILY}" "${MONTHLY_LINK}"
  echo "Tagged monthly DB backup: ${MONTHLY_LINK}"
fi

# --- Pruning / Retention ---
echo "Pruning old backups..."

# Prune old daily DB dumps
echo " - Pruning daily DB backups older than ${KEEP_DAYS} days..."
find "${BACKUP_DIR}" -maxdepth 1 -name "${PGDATABASE}_*-daily.sql.gz" -type f -mtime "+${KEEP_DAYS}" -print -delete

# Prune old weekly DB dumps
KEEP_WEEKS_DAYS=$((KEEP_WEEKS * 7))
echo " - Pruning weekly DB backups older than ${KEEP_WEEKS} weeks (${KEEP_WEEKS_DAYS} days)..."
find "${BACKUP_DIR}" -maxdepth 1 -name "${PGDATABASE}_*-weekly.sql.gz" -type f -mtime "+${KEEP_WEEKS_DAYS}" -print -delete

# Prune old monthly DB dumps
KEEP_MONTHS_DAYS=$((KEEP_MONTHS * 30))
echo " - Pruning monthly DB backups older than ${KEEP_MONTHS} months (${KEEP_MONTHS_DAYS} days)..."
find "${BACKUP_DIR}" -maxdepth 1 -name "${PGDATABASE}_*-monthly.sql.gz" -type f -mtime "+${KEEP_MONTHS_DAYS}" -print -delete

# Prune old globals dumps (simpler retention, e.g., keep for 35 days)
echo " - Pruning globals backups older than 35 days..."
find "${BACKUP_DIR}" -maxdepth 1 -name "globals_*.sql" -type f -mtime "+35" -print -delete


echo "Backup and pruning complete at $(date)"
echo "-------------------------------------"

exit 0
