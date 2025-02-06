#!/bin/bash

# Configurable variables
CONFIG_DIR="$1"  # Directory containing backup configurations
BACKUP_DIR="$2"  # Directory where backups will be stored
MAX_PARALLEL=4   # Maximum parallel backups
SSH_USER="back"  # Default SSH user
SSH_KEY="$HOME/.ssh/process_rsa"  # Default SSH private key
SSH_PASS=""  # Optional fallback password
LOG_DIR="/var/log/cron/backup"  # Default log directory
NOTIF_EMAIL=""  # Email for failure notifications (leave blank to disable)
WALL_NOTIF="true"  # Set to "true" to enable wall notifications, "false" to disable

# Ensure required directories are provided
if [[ -z "$CONFIG_DIR" || -z "$BACKUP_DIR" ]]; then
    echo "Usage: $0 <config_directory> <backup_directory>"
    exit 1
fi

# Create backup directory and log directory if they don't exist
mkdir -p "$BACKUP_DIR"
mkdir -p "$LOG_DIR"

# Function to check for config changes and notify users
detect_config_change() {
    local host_file="$1"
    local ssh_auth_method="$2"
    local host_ip
    local config_backup_dir

    host_ip=$(basename "$host_file")
    config_backup_dir="$BACKUP_DIR/$host_ip/.last_config"

    # If there’s a previous config, compare it with the current one
    if [[ -f "$config_backup_dir" ]]; then
        diff_output=$(diff -u "$config_backup_dir" "$host_file")
        if [[ -n "$diff_output" ]]; then
            echo "WARNING: Backup configuration changed for $host_ip!"
            echo "$diff_output"

            # Log the detected changes
            echo "WARNING: Backup configuration changed for $host_ip!" | tee -a "$LOG_DIR/${host_ip}-config_change.log"
            echo "$diff_output" | tee -a "$LOG_DIR/${host_ip}-config_change.log"

            # Notify remote host if key-based authentication is available
            if [[ "$WALL_NOTIF" == "true" ]]; then
                if [[ "$ssh_auth_method" == "key" ]]; then
                    ssh -i "$SSH_KEY" "${SSH_USER}@${host_ip}" "wall -n 'Backup configuration change detected on this system.'" 2>/dev/null
                else
                    echo "WARNING: Skipping remote wall notification for $host_ip (Key-based authentication unavailable)." | tee -a "$LOG_DIR/${host_ip}-config_change.log"
                fi
                wall -n "Backup configuration change detected for host $host_ip."
            fi
        fi
    fi

    # Save the current config as the new "last known" version
    cp "$host_file" "$config_backup_dir"
}


# Function to perform the backup
backup_host() {
    local host_file="$1"
    local host_ip
    local backup_time
    local host_backup_dir
    local log_file
    local backup_failed=false
    local ssh_auth_method=""

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
        ssh_auth_method="key"
    elif [[ -n "$SSH_PASS" ]]; then
        echo "Authentication: Password-based login" | tee -a "$log_file"
        ssh_auth_method="password"
    else
        echo "ERROR: Cannot connect to $host_ip via SSH. Skipping backup." | tee -a "$log_file"
        backup_failed=true
    fi

    # Detect config changes (after verifying SSH access)
    detect_config_change "$host_file" "$ssh_auth_method"

    echo "Directories to backup:" | tee -a "$log_file"

    # Read directories to back up from the config file
    while IFS= read -r remote_path; do
        [[ -z "$remote_path" ]] && continue  # Skip empty lines
        echo "$remote_path" | tee -a "$log_file"  # Log the directory

        # Ensure absolute path structure
        local target_path="$host_backup_dir$remote_path"
        mkdir -p "$(dirname "$target_path")"

        # Perform rsync backup with verbose logging
        #This is the old rsync command that cannot do root access for files
        #rsync -avz --stats --delete -e "ssh -i $SSH_KEY" "${SSH_USER}@${host_ip}:$remote_path" "$target_path" 2>&1 | tee -a "$log_file"
        rsync -avz --stats --delete -e "ssh -i $SSH_KEY ${SSH_USER}@${host_ip} sudo rsync --server --sender -logDtpre.iLsfx --numeric-ids ${remote_path}" "${SSH_USER}@${host_ip}:$remote_path" "$target_path" 2>&1 | tee -a "$log_file"
        if [[ $? -ne 0 ]]; then
            echo "ERROR: rsync failed for $remote_path on $host_ip. Retrying..." | tee -a "$log_file"
            sleep 5  # Short delay before retry
            #rsync -avz --progress --delete -e "ssh -i $SSH_KEY" "${SSH_USER}@${host_ip}:$remote_path" "$target_path" 2>&1 | tee -a "$log_file"
            rsync -avz --stats --delete -e "ssh -i $SSH_KEY ${SSH_USER}@${host_ip} sudo rsync --server --sender -logDtpre.iLsfx --numeric-ids ${remote_path}" "${SSH_USER}@${host_ip}:$remote_path" "$target_path" 2>&1 | tee -a "$log_file"
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
export BACKUP_DIR SSH_USER SSH_KEY SSH_PASS LOG_DIR NOTIF_EMAIL WALL_NOTIF

# Run backups in parallel
find "$CONFIG_DIR" -type f | xargs -I {} -P "$MAX_PARALLEL" bash -c 'backup_host "$@"' _ {}

echo "All backups initiated."
