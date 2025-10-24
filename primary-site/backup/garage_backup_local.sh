#!/bin/bash

# === Configuration ===
RCLONE_REMOTE_NAME="garage"       # The 'rclone' remote name for your Garage server
BUCKET_NAME="stalwart"     # The name of the bucket you want to back up
LOCAL_BACKUP_DIR="/storage/docker/backup/garage" # IMPORTANT: Set the *absolute path* to your local backup destination folder
LOG_FILE="/storage/docker/backup/garage_backup_stalwart.log" # Optional: Path to the log file. Leave empty "" to disable file logging.
LOCK_FILE="/tmp/garage_backup_stalwart.lock"   # Optional: Lock file to prevent concurrent runs. Leave empty "" to disable locking.
RCLONE_BIN="/usr/bin/rclone"

# === Options for rclone sync ===
# --update: Skip files that are newer on the destination.
# --transfers=N: Number of file transfers to run in parallel.
# --checkers=N: Number of checkers to run in parallel.
# --s3-env-auth: Get S3 credentials from environment variables.
RCLONE_SYNC_OPTIONS="--update --transfers=4 --checkers=8 --s3-env-auth"

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
    log_message "INFO: Starting backup for bucket '$BUCKET_NAME' on remote '$RCLONE_REMOTE_NAME' to '$LOCAL_BACKUP_DIR'."

    # 1. Check if rclone command exists
    if ! command -v ${RCLONE_BIN} &> /dev/null; then
        log_message "ERROR: 'rclone' command not found. Please install rclone and ensure it's in the PATH."
        return 1
    fi

    # 2. Check if rclone remote exists
     if ! ${RCLONE_BIN} config show "$RCLONE_REMOTE_NAME" &> /dev/null; then
         log_message "ERROR: rclone remote '$RCLONE_REMOTE_NAME' not found or configured incorrectly. Use 'rclone config' first."
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

    # 4. Construct the source path for rclone
    local rclone_source_path="$RCLONE_REMOTE_NAME:$BUCKET_NAME"

    # 5. Run rclone sync
    log_message "INFO: Running: rclone sync $RCLONE_SYNC_OPTIONS $rclone_source_path $LOCAL_BACKUP_DIR"
    # Execute rclone sync command
    ${RCLONE_BIN} sync $RCLONE_SYNC_OPTIONS "$rclone_source_path" "$LOCAL_BACKUP_DIR"
    local rclone_exit_code=$?

    # 6. Check rclone sync result
    if [ $rclone_exit_code -eq 0 ]; then
        log_message "SUCCESS: Backup completed successfully for '$rclone_source_path'."
        return 0
    else
        log_message "ERROR: rclone sync command failed with exit code $rclone_exit_code for '$rclone_source_path'."
        return $rclone_exit_code
    fi
}

# --- Execute Backup with Locking ---
# Pass the 'do_backup' function name and its arguments to 'run_with_lock'
run_with_lock do_backup
backup_exit_code=$?

log_message "INFO: Backup script finished with exit code $backup_exit_code."
exit $backup_exit_code
