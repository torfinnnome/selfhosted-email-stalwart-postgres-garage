#!/bin/bash

# Exit on any error
set -e
# Exit on undeclared variable
set -u
# Exit on pipefail
set -o pipefail

# --- Configuration ---
# MinIO Client (mc) alias for your source MinIO server
# Ensure this alias is configured with admin credentials:
# mc alias set myminio http://your-minio-server:9000 YOUR_ROOT_USER YOUR_ROOT_PASSWORD
MINIO_ALIAS="source"

# Base directory where backups will be stored
BACKUP_BASE_DIR="/storage/docker/backup/minio-system" # IMPORTANT: Ensure this directory exists and is writable

# Timestamp for the backup
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Directory for the current backup's contents
CURRENT_BACKUP_DIR="${BACKUP_BASE_DIR}/${TIMESTAMP}_minio_settings"

# Optional: Compress the backup directory
COMPRESS_BACKUP=true
COMPRESSED_BACKUP_FILE="${BACKUP_BASE_DIR}/minio_settings_export_${TIMESTAMP}.tar.gz"

# Retention: Number of days to keep backups
RETENTION_DAYS=7
# --- End Configuration ---

# --- Pre-flight Checks ---
if ! command -v mc &> /dev/null; then
    echo "ERROR: MinIO Client (mc) is not installed or not in PATH."
    exit 1
fi
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is not installed or not in PATH. (sudo apt install jq / sudo yum install jq)"
    exit 1
fi

if ! mc alias ls "${MINIO_ALIAS}" &> /dev/null; then
    echo "ERROR: MinIO alias '${MINIO_ALIAS}' not found. Please configure it first using 'mc alias set ...'"
    exit 1
fi

# Check if the alias has admin privileges (basic check, might not be foolproof)
if ! mc admin info "${MINIO_ALIAS}" &> /dev/null; then
    echo "ERROR: Alias '${MINIO_ALIAS}' does not appear to have admin privileges or server is unreachable."
    echo "Please ensure the alias uses root credentials or an access key with admin policies."
    exit 1
fi

if [ ! -d "${BACKUP_BASE_DIR}" ]; then
    echo "INFO: Backup base directory '${BACKUP_BASE_DIR}' does not exist. Creating it..."
    mkdir -p "${BACKUP_BASE_DIR}"
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to create backup base directory '${BACKUP_BASE_DIR}'."
        exit 1
    fi
elif [ ! -w "${BACKUP_BASE_DIR}" ]; then
    echo "ERROR: Backup base directory '${BACKUP_BASE_DIR}' is not writable."
    exit 1
fi

# --- Main Backup Logic ---
echo "----------------------------------------------------"
echo "Starting MinIO Settings Export: $(date)"
echo "Target Alias: ${MINIO_ALIAS}"
echo "Backup Content Directory: ${CURRENT_BACKUP_DIR}"
echo "----------------------------------------------------"

mkdir -p "${CURRENT_BACKUP_DIR}/bucket_policies"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create backup content directory '${CURRENT_BACKUP_DIR}'."
    exit 1
fi

# 1. Export IAM configuration (users, groups, policies, service accounts)
IAM_EXPORT_FILE="${CURRENT_BACKUP_DIR}/iam_configuration_${MINIO_ALIAS}.zip"
echo "INFO: Exporting IAM configuration to ${IAM_EXPORT_FILE}..."
if mc admin cluster iam export "${MINIO_ALIAS}" -o "${IAM_EXPORT_FILE}"; then
    # Verify the zip file is not empty and seems valid
    if [ -s "${IAM_EXPORT_FILE}" ] && unzip -t "${IAM_EXPORT_FILE}" > /dev/null 2>&1; then
        echo "SUCCESS: IAM configuration exported."
    else
        echo "WARNING: IAM export file '${IAM_EXPORT_FILE}' appears empty or invalid."
        # Optionally treat as an error
        # rm -f "${IAM_EXPORT_FILE}"
        # rm -rf "${CURRENT_BACKUP_DIR}" # Clean up partial backup
        # exit 1
    fi
else
    echo "ERROR: Failed to export IAM configuration."
    rm -rf "${CURRENT_BACKUP_DIR}" # Clean up partial backup
    exit 1
fi

# 2. Export Bucket Policies
echo "INFO: Exporting bucket policies..."
# Get bucket names, excluding the ".minio.sys" internal bucket if it ever shows up (it shouldn't via `mc ls`)
BUCKETS=$(mc ls "${MINIO_ALIAS}" --json | jq -r 'select(.type=="bucket" and .key != ".minio.sys/") | .key' | sed 's/\///g')

if [ -z "$BUCKETS" ]; then
    echo "INFO: No user buckets found to export policies from."
else
    for BUCKET_NAME in $BUCKETS; do
        BUCKET_POLICY_FILE="${CURRENT_BACKUP_DIR}/bucket_policies/${BUCKET_NAME}_policy.json"
        echo "  - Exporting policy for bucket '${BUCKET_NAME}'..."
        POLICY_CONTENT=$(mc policy get "${MINIO_ALIAS}/${BUCKET_NAME}" 2>/dev/null || echo "NO_POLICY_OR_ERROR")

        if [[ "$POLICY_CONTENT" == "NO_POLICY_OR_ERROR" ]] || [[ "$POLICY_CONTENT" == *"specified bucket has no policy"* ]]; then
            echo "    INFO: Bucket '${BUCKET_NAME}' has no policy set or an error occurred fetching it."
            # Create a file indicating no policy for clarity during restore
            echo "{ \"Info\": \"No policy was set on bucket ${BUCKET_NAME} at time of backup, or error fetching.\" }" > "${BUCKET_POLICY_FILE}"
        elif [[ -z "$POLICY_CONTENT" ]]; then
            echo "    INFO: Bucket '${BUCKET_NAME}' has an empty policy (effectively no access)."
            echo "{ \"Info\": \"Policy for bucket ${BUCKET_NAME} was empty at time of backup.\" }" > "${BUCKET_POLICY_FILE}"
        else
            echo "${POLICY_CONTENT}" > "${BUCKET_POLICY_FILE}"
            echo "    SUCCESS: Policy for bucket '${BUCKET_NAME}' exported."
        fi
    done
fi

# Note about other configurations
echo "INFO: Other bucket-specific configurations (versioning, object locking, ILM, quotas, tags, replication)"
echo "      are NOT exported by this script. Consider scripting their export/import if needed."
echo "      Example: 'mc version info ALIAS/BUCKET', 'mc ilm rule export ALIAS/BUCKET'"
echo "      Example: 'mc replicate export ALIAS/BUCKET > bucket_replication.json'"

# --- Compression (Optional) ---
if [ "${COMPRESS_BACKUP}" = true ]; then
    echo "INFO: Compressing backup content to ${COMPRESSED_BACKUP_FILE}"
    if tar -czf "${COMPRESSED_BACKUP_FILE}" -C "$(dirname "${CURRENT_BACKUP_DIR}")" "$(basename "${CURRENT_BACKUP_DIR}")"; then
        echo "SUCCESS: Backup compressed."
        echo "INFO: Removing temporary uncompressed backup directory: ${CURRENT_BACKUP_DIR}"
        rm -rf "${CURRENT_BACKUP_DIR}"
    else
        echo "ERROR: Failed to compress backup. The uncompressed backup is still available at ${CURRENT_BACKUP_DIR}"
        # Decide if you want to exit or continue if compression fails
        # exit 1
    fi
fi

# --- Cleanup Old Backups ---
echo "INFO: Cleaning up old backups older than ${RETENTION_DAYS} days..."
if [ "${COMPRESS_BACKUP}" = true ]; then
    find "${BACKUP_BASE_DIR}" -name "minio_settings_export_*.tar.gz" -type f -mtime +"${RETENTION_DAYS}" -print -delete
else
    # If not compressing, CURRENT_BACKUP_DIR is the final backup dir for that run
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "*_minio_settings" -mtime +"${RETENTION_DAYS}" -print -exec rm -rf {} \;
fi
echo "INFO: Cleanup complete."

echo "----------------------------------------------------"
echo "MinIO Settings Export Finished: $(date)"
if [ "${COMPRESS_BACKUP}" = true ] && [ -f "${COMPRESSED_BACKUP_FILE}" ]; then
    echo "Backup archive: ${COMPRESSED_BACKUP_FILE}"
elif [ ! "${COMPRESS_BACKUP}" = true ] && [ -d "${CURRENT_BACKUP_DIR}" ]; then
     echo "Backup directory: ${CURRENT_BACKUP_DIR}"
elif [ "${COMPRESS_BACKUP}" = true ] && [ ! -f "${COMPRESSED_BACKUP_FILE}" ] && [ -d "${CURRENT_BACKUP_DIR}" ]; then
    echo "Backup directory (compression failed): ${CURRENT_BACKUP_DIR}"
fi
echo "----------------------------------------------------"
echo ""
echo "CRITICAL REMINDERS:"
echo "1. This script exports IAM configuration and bucket policies using 'mc admin' and 'mc policy'."
echo "2. You MUST ALSO SEPARATELY backup your MinIO server's STARTUP configuration:"
echo "   - MINIO_ROOT_USER and MINIO_ROOT_PASSWORD (or ACCESS_KEY/SECRET_KEY)"
echo "   - MINIO_VOLUMES or disk paths for data storage"
echo "   - Docker-compose files, Kubernetes manifests, or systemd service files"
echo "   - Any TLS certificates and keys if used directly by MinIO"
echo "   - Other environment variables or command-line flags used for starting MinIO."
echo "3. Other bucket configurations (versioning, locking, ILM, quotas, tags, replication)"
echo "   may require separate export/import scripts or manual re-application."
echo "----------------------------------------------------"

exit 0
