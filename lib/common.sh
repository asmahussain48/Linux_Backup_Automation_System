#!/usr/bin/env bash
# =============================================================
#  common.sh - shared helpers: logging, alerts, locking, dirs
# =============================================================

LOG_FILE="$LOG_DIR/lbas.log"
ALERT_FILE="$LOG_DIR/alerts.log"

# Colours only when printing to a terminal (not in cron logs)
if [[ -t 1 ]]; then
    RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; RST=$'\e[0m'
else
    RED=""; GRN=""; YLW=""; BLU=""; BLD=""; RST=""
fi

# log LEVEL message...   LEVEL = INFO | OK | WARN | ERROR
log() {
    local level=$1; shift
    local msg="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$LOG_FILE"
    case $level in
        ERROR) echo "${RED}[ERROR]${RST} $msg" >&2
               syslog "ERROR: $msg" ;;
        WARN)  echo "${YLW}[WARN]${RST}  $msg" ;;
        OK)    echo "${GRN}[ OK ]${RST}  $msg" ;;
        *)     echo "${BLU}[INFO]${RST}  $msg" ;;
    esac
}

# System log (syslog/journal) - read it with: journalctl -t lbas
syslog() { command -v logger >/dev/null && logger -t lbas "$*"; return 0; }

# Alerts: alerts.log + system log (syslog/journal) + desktop popup if available
send_alert() {
    local msg="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$ALERT_FILE"
    syslog "ALERT: $msg"
    if command -v notify-send >/dev/null && [[ -n ${DISPLAY:-} ]]; then
        notify-send "Backup System" "$msg" 2>/dev/null
    fi
}

init_dirs() {
    mkdir -p "$BACKUP_DIR" "$SNAP_DIR" "$LOG_DIR" "$REPORT_DIR" "$RESTORE_DIR" \
        || { echo "Cannot create data folders" >&2; exit 1; }
    # Backups may contain private data: only the owner may read them
    chmod 700 "$BACKUP_DIR" "$SNAP_DIR"
    touch "$LOG_FILE"
}

# Prevents two backups (e.g. cron + manual) from running at the same time
acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        exec 9>&-
        log ERROR "Another backup process is already running."
        return 1
    fi
}

# Closing the file releases the lock (so the menu does not block cron)
release_lock() { exec 9>&-; }

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

confirm() {
    local ans
    read -rp "$1 [y/N]: " ans
    [[ $ans =~ ^[Yy]$ ]]
}
