#!/bin/bash

# === Configuration ===
MINIO_ALIAS="source"       # The 'mc' alias for your MinIO server (e.g., 'source', 'myminio')
BUCKET_NAME="stalwart"     # The name of the bucket you want to back up
LOCAL_BACKUP_DIR="/storage/docker/backup/minio" # IMPORTANT: Set the *absolute path* to your local backup destination folder
LOG_FILE="/storage/docker/backup/minio_backup_stalwart.log" # Optional: Path to the log file. Leave empty "" to disable file logging.
LOCK_FILE="/tmp/minio_backup_stalwart.lock"   # Optional: Lock file to prevent concurrent runs. Leave empty "" to disable locking.
MC_BIN="/storage/docker/mc"

# === Options for mc mirror ===
# --overwrite: Overwrite files in destination if source is newer (usually desired for mirror)
# --remove:    Delete files from destination if they were removed from source.
#              Use with caution! If you want the backup to be an archive
#              that *never* deletes files, OMIT the --remove flag.
MC_MIRROR_OPTIONS="--overwrite"
# MC_MIRROR_OPTIONS="--overwrite --remove" # Uncomment this line if you want deleted source files removed from backup

# === Script Logic ===

# --- Logging Function ---
log_message() {
    local message="$1"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local log_line="$timestamp - $message"

    echo "$log_line" # Always print to stdout
    if [[ -n "$LOG_FILE" ]]; then
        echo "$log_line" >> "$LOG_FILE" # Append to log file if configured
    fi
}

# --- Lock Function Wrapper ---
# Uses flock to ensure only one instance runs at a time.
# If LOCK_FILE is empty, just runs the command directly.
run_with_lock() {
    local command_to_run=("$@") # Capture the command and its arguments

    if [[ -z "$LOCK_FILE" ]]; then
        # No lock file configured, run directly
        log_message "INFO: Lock file not configured. Running backup directly."
        "${command_to_run[@]}"
        return $?
    fi

    # Lock file is configured, use flock
    (
        flock -n 9 || { log_message "ERROR: Backup script is already running (lock file '$LOCK_FILE' held). Exiting."; exit 1; }
        log_message "INFO: Acquired lock ($LOCK_FILE). Proceeding with backup."
        # Execute the actual command passed to this function
        "${command_to_run[@]}"
        exit_code=$?
        log_message "INFO: Releasing lock ($LOCK_FILE)."
        exit $exit_code # Exit the subshell with the command's exit code
    ) 9>"$LOCK_FILE" # Redirect FD 9 to the lock file for flock

    # Return the exit code captured from the subshell
    return $?
}


# --- Main Backup Function ---
do_backup() {
    log_message "INFO: Starting backup for bucket '$BUCKET_NAME' on alias '$MINIO_ALIAS' to '$LOCAL_BACKUP_DIR'."

    # 1. Check if mc command exists
    if ! command -v ${MC_BIN} &> /dev/null; then
        log_message "ERROR: 'mc' command not found. Please install MinIO Client (mc) and ensure it's in the PATH."
        return 1
    fi

    # 2. Check if MinIO alias exists
     if ! ${MC_BIN} alias list "$MINIO_ALIAS" &> /dev/null; then
         log_message "ERROR: MinIO alias '$MINIO_ALIAS' not found or configured incorrectly. Use 'mc alias set ...' first."
         return 1
     fi

    # 3. Ensure backup directory exists
    if [ ! -d "$LOCAL_BACKUP_DIR" ]; then
        log_message "INFO: Backup directory '$LOCAL_BACKUP_DIR' does not exist. Attempting to create..."
        # Use mkdir -p to create parent directories as needed
        if ! mkdir -p "$LOCAL_BACKUP_DIR"; then
            log_message "ERROR: Failed to create backup directory '$LOCAL_BACKUP_DIR'. Check permissions."
            return 1
        else
            log_message "INFO: Successfully created backup directory '$LOCAL_BACKUP_DIR'."
        fi
    elif [ ! -w "$LOCAL_BACKUP_DIR" ]; then
         log_message "ERROR: Backup directory '$LOCAL_BACKUP_DIR' exists but is not writable. Check permissions."
         return 1
    fi

    # 4. Construct the source path for mc
    local mc_source_path="$MINIO_ALIAS/$BUCKET_NAME"

    # 5. Run mc mirror
    log_message "INFO: Running: mc mirror $MC_MIRROR_OPTIONS $mc_source_path $LOCAL_BACKUP_DIR"
    # Execute mc mirror command
    ${MC_BIN} mirror $MC_MIRROR_OPTIONS "$mc_source_path" "$LOCAL_BACKUP_DIR"
    local mc_exit_code=$?

    # 6. Check mc mirror result
    if [ $mc_exit_code -eq 0 ]; then
        log_message "SUCCESS: Backup completed successfully for '$mc_source_path'."
        return 0
    else
        log_message "ERROR: mc mirror command failed with exit code $mc_exit_code for '$mc_source_path'."
        return $mc_exit_code
    fi
}

# --- Execute Backup with Locking ---
# Pass the 'do_backup' function name and its arguments to 'run_with_lock'
run_with_lock do_backup
backup_exit_code=$?

log_message "INFO: Backup script finished with exit code $backup_exit_code."
exit $backup_exit_code
