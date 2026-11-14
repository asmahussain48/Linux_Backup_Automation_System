
#!/usr/bin/env bash
# =============================================================
# schedule.sh - Automated Backup Scheduling
# Developed by: Muhammad Zaid Shaikh
# =============================================================

set -u

BASE_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
LOG_DIR="$BASE_DIR/logs"
CRON_LOG="$LOG_DIR/cron.log"
CRON_TAG="# LBAS_AUTOMATED_BACKUP"

mkdir -p "$LOG_DIR"

# Display installed backup schedule
show_schedule() {

    echo "========== AUTOMATED BACKUP SCHEDULE =========="

    local entries
    entries=$(crontab -l 2>/dev/null | grep -F "$CRON_TAG" || true)

    if [[ -z $entries ]]; then
        echo "No automated backup schedule installed."
    else
        echo "$entries"
    fi

    echo "==============================================="
}

# Remove existing LBAS schedule
remove_schedule() {

    local current
    current=$(crontab -l 2>/dev/null || true)

    if ! grep -Fq "$CRON_TAG" <<< "$current"; then
        echo "No LBAS schedule found."
        return 0
    fi

    printf '%s\n' "$current" |
        grep -Fv "$CRON_TAG" |
        crontab -

    if [[ $? -eq 0 ]]; then
        echo "Automated backup schedule removed."
        echo "[$(date)] Schedule removed." >> "$CRON_LOG"
    else
        echo "Failed to remove schedule."
        return 1
    fi
}

# Install a new backup schedule
install_schedule() {

    local schedule="$1"
    local current command cron_entry

    # Validate that the schedule contains exactly five fields
    read -r -a fields <<< "$schedule"

    if [[ ${#fields[@]} -ne 5 || "$schedule" == *$'\n'* ]]; then
        echo "Invalid cron expression."
        echo 'Example: "0 2 * * *"'
        return 1
    fi

    # Validate cron command availability
    if ! command -v crontab >/dev/null 2>&1; then
        echo "crontab is not installed."
        return 1
    fi

    # Prevent duplicate LBAS schedules
    current=$(crontab -l 2>/dev/null || true)

    current=$(printf '%s\n' "$current" |
        grep -Fv "$CRON_TAG" || true)

    # Build the automatic backup command
    printf -v command '%q' "$BASE_DIR/lbas.sh"

    cron_entry="$schedule /usr/bin/env bash $command auto >> '$CRON_LOG' 2>&1 $CRON_TAG"

    # Install the updated crontab
    {
        [[ -z $current ]] || printf '%s\n' "$current"
        printf '%s\n' "$cron_entry"
    } | crontab -

    if [[ $? -eq 0 ]]; then
        echo "Automated backup schedule installed successfully."
        echo "Schedule: $schedule"
        echo "Command: $command auto"
        echo "Log file: $CRON_LOG"
        echo "[$(date)] Schedule installed: $schedule" >> "$CRON_LOG"
    else
        echo "Failed to install cron schedule."
        return 1
    fi
}

# Command-line argument handling
case "${1:-}" in

    install)
        if [[ $# -ne 2 ]]; then
            echo 'Usage: schedule.sh install "MIN HOUR DOM MON DOW"'
            exit 1
        fi

        install_schedule "$2"
        ;;

    show)
        show_schedule
        ;;

    remove)
        remove_schedule
        ;;

    *)
        echo "Usage:"
        echo '  schedule.sh install "0 2 * * *"'
        echo "  schedule.sh show"
        echo "  schedule.sh remove"
        exit 1
        ;;

esac
