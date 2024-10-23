#!/bin/bash

# Note: Script is built to work in any directory it is placed

# Load environment variables from .env file
SCRIPT_DIR="$(dirname "$0")"
ENV_FILE="$SCRIPT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  export $(grep -v '^#' "$ENV_FILE" | xargs)
else
  echo ".env file not found. Exiting."
  exit 1
fi

# Define the path to the script directory and set the log file there
LOG_FILE="$SCRIPT_DIR/$(hostname)_proxmox_backup.log"

# Define retry parameters
MAX_RETRIES=5  # Number of times to retry
RETRY_DELAY=60  # Delay in seconds between retries

# Function to log backup details to file
log_to_file() {
  local status="$1"
  local retries="$2"
  local start_time="$3"
  local end_time="$4"
  local duration="$5"
  local message="$6"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Host: $(hostname), Status: $status, Retries: $retries, Start Time: $(date -d @$start_time), End Time: $(date -d @$end_time), Duration: $duration" >> "$LOG_FILE"
}

# Function to convert duration into minutes and seconds
convert_duration() {
  local total_seconds=$1
  local minutes=$((total_seconds / 60))
  local seconds=$((total_seconds % 60))

  echo "$minutes minutes and $seconds seconds"
}

# Function to send a notification to Discord with an enhanced embed
send_discord_notification() {
  local title="$1"
  local description="$2"
  local color="$3"
  local status="$4"
  local retries="$5"
  local duration="$6"
  local webhook_url="$7"

  curl -H "Content-Type: application/json" \
       -X POST \
       -d "{
            \"embeds\": [{
                \"title\": \"$title\",
                \"description\": \"$description\",
                \"color\": $color,
                \"fields\": [
                    { \"name\": \"Status\", \"value\": \"\`$status\`\", \"inline\": true },
                    { \"name\": \"Server\", \"value\": \"\`$(hostname)\`\", \"inline\": true },
                    { \"name\": \"Retries\", \"value\": \"\`$retries\`\", \"inline\": true },
                    { \"name\": \"Duration\", \"value\": \"\`$duration\`\", \"inline\": true },
                    { \"name\": \"Backup Target\", \"value\": \"\`$PBS_REPOSITORY\`\", \"inline\": false },
                    { \"name\": \"Excluded Directories\", \"value\": \"\`/dev, /proc, /sys, /run, /tmp\`\", \"inline\": false }
                ],
                \"footer\": {
                    \"text\": \"Backup Script\"
                },
                \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" 
            }]
        }" $webhook_url
}

# Run the backup command with retry logic
retry=0
success=false

# Capture the start time
start_time=$(date +%s)

while [ $retry -lt $MAX_RETRIES ]; do
  echo "Attempt $(($retry + 1)) of $MAX_RETRIES"

  # Run the backup command, excluding some directories
  proxmox-backup-client backup root.pxar:/ --exclude dev --exclude proc --exclude sys --exclude run --exclude tmp --repository $PBS_REPOSITORY
  
  # Check if the command was successful
  if [ $? -eq 0 ]; then
    success=true
    break
  else
    echo "Backup failed on attempt $(($retry + 1))"
    retry=$(($retry + 1))
    
    # Wait before retrying
    if [ $retry -lt $MAX_RETRIES ]; then
      echo "Waiting for $RETRY_DELAY seconds before retrying..."
      sleep $RETRY_DELAY
    fi
  fi
done

# Capture the end time and calculate duration
end_time=$(date +%s)
duration_seconds=$(($end_time - $start_time))

# Convert duration into minutes and seconds
duration=$(convert_duration $duration_seconds)

# Final status
if [ "$success" = false ]; then
  echo "Backup failed after $MAX_RETRIES attempts."

  # Log failure details
  log_to_file "Failed" "$retry" "$start_time" "$end_time" "$duration" "Backup failed after $MAX_RETRIES attempts."

  # Send failure notification to Discord (red color)
  send_discord_notification \
    "Backup Failed ❌" \
    "The backup process on \`$(hostname)\` has failed after multiple attempts." \
    16711680 "Failed ❌" "$retry" "$duration" "$DISCORD_WEBHOOK_URL"

  exit 1
fi

# Log success details
log_to_file "Successful" "$retry" "$start_time" "$end_time" "$duration" "Backup completed successfully."

# Send success notification to Discord (green color)
send_discord_notification \
  "Backup Successful ✅" \
  "The backup process on \`$(hostname)\` completed successfully without errors." \
  65280 "Successful ✅" "$retry" "$duration" "$DISCORD_WEBHOOK_URL"

exit 0
