#!/usr/bin/env bash
# =============================================================
# monitor.sh - Automation & Monitoring
# Developed by: Muhammad Zaid Shaikh
# =============================================================

# Display CPU, memory, and disk usage
show_system_status() {

    echo
    echo "========== SYSTEM RESOURCE STATUS =========="
    echo

    # CPU information
    echo "---- CPU Usage ----"
    top -bn1 | grep "Cpu(s)" || true

    # Memory information
    echo
    echo "---- Memory Usage ----"
    free -h

    # Disk information
    echo
    echo "---- Disk Usage ----"
    df -h "$BACKUP_DIR"

    # Backup storage warning
    check_storage

    echo
    echo "============================================="
}

# Check backup storage usage
check_storage() {

    local usage

    usage=$(df -P "$BACKUP_DIR" | awk 'NR==2 {gsub("%","",$5); print $5}')

    if [[ -z $usage ]]; then
        log ERROR "Unable to determine backup storage usage."
        return 1
    fi

    if (( usage >= STORAGE_WARN_PERCENT )); then
        send_alert "Low backup storage: ${usage}% used"
        log WARN "Backup storage usage is ${usage}%."
    else
        log OK "Backup storage usage is ${usage}%."
    fi
}

# Generate a report after every backup execution
generate_report() {

    local status=$1
    local timestamp
    local report

    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    report="$REPORT_DIR/report_${timestamp}.txt"

    {
        echo "========================================"
        echo "       LINUX BACKUP AUTOMATION SYSTEM"
        echo "             BACKUP REPORT"
        echo "========================================"
        echo
        echo "Date: $(date)"
        echo "Backup Status: $status"
        echo "Last Archive: ${LAST_ARCHIVE:-None}"
        echo
        echo "----- SYSTEM RESOURCES -----"
        echo
        echo "Memory:"
        free -h
        echo
        echo "Disk:"
        df -h "$BACKUP_DIR"
        echo
        echo "========================================"
    } > "$report"

    log OK "Backup report generated: $report"

    # Keep only the latest configured number of reports
    find "$REPORT_DIR" -maxdepth 1 -type f \
        -name 'report_*.txt' -printf '%T@ %p\n' |
        sort -rn |
        awk -v keep="$KEEP_REPORTS" 'NR > keep {print $2}' |
        while IFS= read -r old_report; do
            rm -f -- "$old_report"
        done
}

# Show recent logs, alerts and the system journal
show_logs() {
    echo "${BLD}---- Last 20 log lines ($LOG_FILE) ----${RST}"
    tail -n 20 "$LOG_FILE" 2>/dev/null || echo "No log yet."
    echo
    echo "${BLD}---- Alerts ($ALERT_FILE) ----${RST}"
    tail -n 10 "$ALERT_FILE" 2>/dev/null || echo "No alerts."
    echo
    echo "${BLD}---- System journal (lbas) ----${RST}"
    journalctl -t lbas -n 10 --no-pager 2>/dev/null || echo "journalctl not available."
}
