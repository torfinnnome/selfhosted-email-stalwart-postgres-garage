#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
FDB_SERVICE_NAME="fdb"
CLUSTER_FILE_PATH="/var/fdb/fdb.cluster"
BACKUP_TAG="default" # As per your previous log
BACKUP_DESTINATION_URL="file:///backup" # As per your previous log
BACKUP_AGENT_LOG_FILE="/var/fdb/logs/backup_agent_persistent.log"
BACKUP_AGENT_EXECUTABLE="/usr/bin/backup_agent" # Explicit path

# Polling settings
POLL_INTERVAL_SECONDS=30
MAX_POLL_ATTEMPTS=60 # 30 minutes timeout

# --- Script Logic ---

echo "------------------------------------"
echo "Starting FDB Backup Script (Persistent Agent Mode): $(date)"
echo "------------------------------------"

# Function for synchronous exec, to get output/status
fdb_exec_sync() {
    docker compose exec "${FDB_SERVICE_NAME}" "$@"
}

echo "INFO: Checking for necessary tools (backup_agent, pgrep) inside the container..."
# We still need bash inside the container for the -c "nohup ... >> log" part
fdb_exec_sync sh -c "which bash && which \"${BACKUP_AGENT_EXECUTABLE}\" && which pgrep && which nohup" || \
    { echo "ERROR: One or more necessary tools (bash, ${BACKUP_AGENT_EXECUTABLE}, pgrep, nohup) not found in container. Exiting."; exit 1; }
echo "INFO: Tools found."

echo "INFO: Checking status of backup_agent..."
PGREP_PATTERN="backup[_]agent -C ${CLUSTER_FILE_PATH}" # Avoid self-matching pgrep

if ! fdb_exec_sync sh -c "pgrep -f \"${PGREP_PATTERN}\" > /dev/null 2>&1"; then
    echo "INFO: backup_agent is not running. Attempting to start it..."
    echo "INFO: Agent logs will be at ${BACKUP_AGENT_LOG_FILE} inside the container."

    # Ensure log directory and file are accessible/creatable and then ensure log file is writable
    fdb_exec_sync sh -c "mkdir -p \"$(dirname "${BACKUP_AGENT_LOG_FILE}")\" && \
                         touch \"${BACKUP_AGENT_LOG_FILE}\" && \
                         chmod u+w \"${BACKUP_AGENT_LOG_FILE}\"" || \
        { echo "ERROR: Failed to ensure log file ${BACKUP_AGENT_LOG_FILE} is writable. Check permissions. Exiting."; exit 1; }

    # Construct the command to be run by bash -c inside the detached exec
    # We use nohup for SIGHUP immunity, and redirect stdout/stderr to the log file.
    AGENT_START_CMD_INNER="nohup ${BACKUP_AGENT_EXECUTABLE} -C \"${CLUSTER_FILE_PATH}\" >> \"${BACKUP_AGENT_LOG_FILE}\" 2>&1"

    echo "INFO: Starting agent with: docker compose exec -d ${FDB_SERVICE_NAME} bash -c '${AGENT_START_CMD_INNER}'"
    # Note the single quotes around AGENT_START_CMD_INNER for the bash -c command
    # This prevents premature expansion of >> by the script's shell if AGENT_START_CMD_INNER contained it directly.
    # Here, AGENT_START_CMD_INNER is a variable, so double quotes are fine for bash -c "..." to allow variable expansion,
    # but the internal quotes for paths need to be escaped or handled carefully.
    # Using single quotes around the whole command for bash -c is often safest if the inner command is complex.
    # Let's try with double quotes for bash -c as variables are already expanded.
    if docker compose exec -d "${FDB_SERVICE_NAME}" bash -c "${AGENT_START_CMD_INNER}"; then
        echo "INFO: backup_agent start command submitted via 'docker compose exec -d'."
    else
        # This 'else' branch is unlikely to be hit if 'docker compose exec -d' can merely launch bash.
        # The actual success of the agent is checked by pgrep later.
        echo "ERROR: 'docker compose exec -d' command itself failed to launch. This is unusual."
        exit 1
    fi

    echo "INFO: Waiting 15 seconds for backup_agent to initialize..."
    sleep 15

    if ! fdb_exec_sync sh -c "pgrep -f \"${PGREP_PATTERN}\" > /dev/null 2>&1"; then
        echo "ERROR: backup_agent FAILED to start or stay running after attempt."
        echo "ERROR: Please check the agent log file inside the container: ${FDB_SERVICE_NAME}:${BACKUP_AGENT_LOG_FILE}"
        echo "INFO: Content of agent log (${BACKUP_AGENT_LOG_FILE}):"
        fdb_exec_sync cat "${BACKUP_AGENT_LOG_FILE}" || echo " (failed to cat log or log is empty)"
        echo "SUGGESTION: Check for errors from the agent itself. Try this manually:"
        echo "          docker compose exec ${FDB_SERVICE_NAME} ${BACKUP_AGENT_EXECUTABLE} -C ${CLUSTER_FILE_PATH}"
        exit 1
    else
        echo "INFO: backup_agent appears to be running now."
    fi
else
    echo "INFO: backup_agent is already running."
fi

echo "INFO: Initiating backup request for tag '${BACKUP_TAG}' to '${BACKUP_DESTINATION_URL}'..."
start_output=$(fdb_exec_sync fdbbackup start -t "${BACKUP_TAG}" -d "${BACKUP_DESTINATION_URL}" 2>&1)
echo "INFO: fdbbackup start output: ${start_output}"

if echo "${start_output}" | grep -q "no backup agents are responding"; then
    echo "ERROR: 'fdbbackup start' reported no backup agents are responding. Agent might be stuck or unable to connect."
    echo "ERROR: Please check the agent log file inside the container: ${FDB_SERVICE_NAME}:${BACKUP_AGENT_LOG_FILE}"
    exit 1
elif ! echo "${start_output}" | grep -q -E "(successfully submitted|already exists)"; then
    echo "ERROR: Failed to initiate backup with fdbbackup start. Output was: ${start_output}"
    exit 1
fi

echo "INFO: Polling for backup completion (Tag: ${BACKUP_TAG}). Max attempts: ${MAX_POLL_ATTEMPTS}, Interval: ${POLL_INTERVAL_SECONDS}s..."
backup_completed=false
status_output=""
for ((i=1; i<=MAX_POLL_ATTEMPTS; i++)); do
    echo "INFO: Attempt ${i}/${MAX_POLL_ATTEMPTS} to check status..."
    status_output=$(fdb_exec_sync fdbbackup status -t "${BACKUP_TAG}" 2>&1)

    if echo "${status_output}" | grep -q "completed"; then
        echo "SUCCESS: Backup completed!"
        echo "${status_output}"
        backup_completed=true
        break
    elif echo "${status_output}" | grep -E -q "(in progress|running)"; then
        first_line_status=$(echo "${status_output}" | head -n1)
        echo "INFO: Backup is ongoing. Status: ${first_line_status}"
    elif echo "${status_output}" | grep -q "No previous backup"; then
        echo "WARN: Status shows 'No previous backup'. Agent might not have picked up the task yet or this is the very first backup for this tag. Waiting..."
    else
        echo "WARN: Received unexpected or potentially problematic status from 'fdbbackup status':"
        echo "${status_output}"
        echo "WARN: This might indicate an issue. Waiting..."
    fi

    if [ "${i}" -lt "${MAX_POLL_ATTEMPTS}" ]; then
        sleep "${POLL_INTERVAL_SECONDS}"
    fi
done

if [ "${backup_completed}" = true ]; then
    echo "------------------------------------"
    echo "FDB Backup Script Finished Successfully: $(date)"
    echo "Backup agent remains running."
    echo "------------------------------------"
    exit 0
else
    echo "------------------------------------"
    echo "ERROR: FDB Backup Script Failed: Backup did not complete within the timeout."
    echo "ERROR: Last status was:"
    echo "${status_output}"
    echo "ERROR: Check agent logs at ${BACKUP_AGENT_LOG_FILE} inside the container (${FDB_SERVICE_NAME}) and FDB trace logs."
    echo "Backup agent status (if started by script or previously running):"
    fdb_exec_sync sh -c "pgrep -f \"${PGREP_PATTERN}\" && echo 'Agent process found.' || echo 'Agent process NOT found.'"
    echo "------------------------------------"
    exit 1
fi
