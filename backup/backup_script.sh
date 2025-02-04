#!/bin/bash

# Configurable variables
CONFIG_DIR="$1"  # Directory containing backup configurations
BACKUP_DIR="$2"  # Directory where backups will be stored
MAX_PARALLEL=4   # Maximum parallel backups
SSH_USER="back"  # Default SSH user
SSH_KEY="$HOME/.ssh/id_rsa"  # Default SSH private key
SSH_PASS=""  # Optionally specify a fallback password

# Ensure required directories are provided
if [[ -z "$CONFIG_DIR" || -z "$BACKUP_DIR" ]]; then
    echo "Usage: $0 <config_directory> <backup_directory>"
    exit 1
fi

# Create backup directory if it does not exist
mkdir -p "$BACKUP_DIR"

# Function to perform the backup
backup_host() {
    local host_file="$1"
    local host_ip
    local backup_time
    local host_backup_dir

    host_ip=$(basename "$host_file")  # Extract host IP from filename
    backup_time=$(TZ="America/New_York" date +"%Y-%m-%d %H:%M:%SZ")
    host_backup_dir="$BACKUP_DIR/$host_ip/$backup_time"

    echo "Starting backup for $host_ip at $backup_time"

    # Read directories to back up from the config file
    while IFS= read -r remote_path; do
        [[ -z "$remote_path" ]] && continue  # Skip empty lines

        # Ensure absolute path structure
        local target_path="$host_backup_dir$remote_path"
        mkdir -p "$(dirname "$target_path")"

        # Perform rsync backup
        rsync -az -e "ssh -i $SSH_KEY" --progress --delete "${SSH_USER}@${host_ip}:$remote_path" "$target_path" ||
        ( [[ -n "$SSH_PASS" ]] && sshpass -p "$SSH_PASS" rsync -az -e "ssh" --progress --delete "${SSH_USER}@${host_ip}:$remote_path" "$target_path" )
    done < "$host_file"

    echo "Backup for $host_ip completed."
}

export -f backup_host
export BACKUP_DIR SSH_USER SSH_KEY SSH_PASS

# Run backups in parallel
find "$CONFIG_DIR" -type f | xargs -I {} -P "$MAX_PARALLEL" bash -c 'backup_host "$@"' _ {}

echo "All backups initiated."