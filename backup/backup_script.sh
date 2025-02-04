#!/bin/bash

# Configurable variables
CONFIG_DIR="$1"  # Directory containing backup configurations
BACKUP_DIR="$2"  # Directory where backups will be stored
MAX_PARALLEL=4   # Maximum parallel backups
SSH_USER="back"  # Default SSH user
SSH_KEY="$HOME/.ssh/id_rsa"  # Default SSH private key
SSH_PASS=""  # Optional fallback password
LOG_DIR="/var/log/cron/backup"  # Default log directory
NOTIF_EMAIL=""  # Email for failure notifications (leave blank to disable)

# Ensure required directories are provided
if [[ -z "$CONFIG_DIR" || -z "$BACKUP_DIR" ]]; then
    echo "Usage: $0 <config_directory> <backup_directory>"
    exit 1
fi

# Create backup directory and log directory if they don't exist
mkdir -p "$BACKUP_DIR"
mkdir -p "$LOG_DIR"

# Function to perform the backup
backup_host() {
    local host_file="$1"
    local host_ip
    local backup_time
    local host_backup_dir
    local log_file
    local backup_failed=false

    host_ip=$(basename "$host_file")  # Extract host IP from filename
    backup_time=$(TZ="America/New_York" date +"%Y-%m-%d_%H:%M:%SZ")
    host_backup_dir="$BACKUP_DIR/$host_ip/$backup_time"
    log_file="$LOG_DIR/${host_ip}---${backup_time}.log"

    echo "Starting backup for $host_ip at $backup_time" | tee -a "$log_file"

    # Check available disk space
    AVAILABLE_SPACE=$(df --output=avail "$BACKUP_DIR" | tail -1)
    if (( AVAILABLE_SPACE < 1000000 )); then
        echo "WARNING: Low disk space on backup destination ($AVAILABLE_SPACE KB remaining)!" | tee -a "$log_file"
    fi

    # Test SSH connection
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${host_ip}" "exit" 2>/dev/null; then
        echo "Authentication: SSH Key (${SSH_KEY##*/})" | tee -a "$log_file"
        auth_method="-e \"ssh -i $SSH_KEY\""
    elif [[ -n "$SSH_PASS" ]]; then
        echo "Authentication: Password-based login" | tee -a "$log_file"
        auth_method="sshpass -p \"$SSH_PASS\" rsync -e ssh"
    else
        echo "ERROR: Cannot connect to $host_ip via SSH. Skipping backup." | tee -a "$log_file"
        backup_failed=true
    fi

    echo "Directories to backup:" | tee -a "$log_file"

    # Read directories to back up from the config file
    while IFS= read -r remote_path; do
        [[ -z "$remote_path" ]] && continue  # Skip empty lines
        echo "$remote_path" | tee -a "$log_file"  # Log the directory

        # Ensure absolute path structure
        local target_path="$host_backup_dir$remote_path"
        mkdir -p "$(dirname "$target_path")"

        # Perform rsync backup with verbose logging
        rsync -avz --progress --delete ${auth_method} "${SSH_USER}@${host_ip}:$remote_path" "$target_path" 2>&1 | tee -a "$log_file"
        if [[ $? -ne 0 ]]; then
            echo "ERROR: rsync failed for $remote_path on $host_ip. Retrying..." | tee -a "$log_file"
            sleep 5  # Short delay before retry
            rsync -avz --progress --delete ${auth_method} "${SSH_USER}@${host_ip}:$remote_path" "$target_path" 2>&1 | tee -a "$log_file"
            if [[ $? -ne 0 ]]; then
                echo "ERROR: Second rsync attempt failed for $remote_path on $host_ip. Skipping." | tee -a "$log_file"
                backup_failed=true
            fi
        fi
    done < "$host_file"

    echo "Backup for $host_ip completed." | tee -a "$log_file"

    # Send failure notification if enabled
    if [[ "$backup_failed" == "true" && -n "$NOTIF_EMAIL" ]]; then
        mail -s "Backup Failure for $host_ip" "$NOTIF_EMAIL" < "$log_file"
    fi
}

export -f backup_host
export BACKUP_DIR SSH_USER SSH_KEY SSH_PASS LOG_DIR NOTIF_EMAIL

# Run backups in parallel
find "$CONFIG_DIR" -type f | xargs -I {} -P "$MAX_PARALLEL" bash -c 'backup_host "$@"' _ {}

echo "All backups initiated."
