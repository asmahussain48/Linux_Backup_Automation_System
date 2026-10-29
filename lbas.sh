#!/usr/bin/env bash
# =============================================================
#  Linux Backup Automation System (LBAS) - main program
#  Run without arguments for the interactive menu,
#  or ./lbas.sh help for command-line usage.
# =============================================================
set -uo pipefail

BASE_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CONFIG="${LBAS_CONFIG:-$BASE_DIR/config/lbas.conf}"
[[ -f $CONFIG ]] || { echo "Config file not found: $CONFIG" >&2; exit 1; }

# shellcheck source=/dev/null
source "$CONFIG"
source "$BASE_DIR/lib/common.sh"
source "$BASE_DIR/lib/backup.sh"     # Member 1
source "$BASE_DIR/lib/recovery.sh"   # Member 2
source "$BASE_DIR/lib/monitor.sh"    # Member 3

init_dirs
build_tar_excludes

# ---------- actions ----------
run_backup() {   # full | incr | auto
    local rc status
    acquire_lock || return 1
    LAST_RESULT=""; LAST_ARCHIVE=""
    case $1 in
        full) create_backup full ;;
        incr) create_backup incr ;;
        auto) auto_backup ;;
    esac
    rc=$?
    if (( rc != 0 ));                  then status="FAILED"
    elif [[ $LAST_RESULT == skipped ]]; then status="SKIPPED (no changes)"
    else                                    status="SUCCESS"
    fi
    generate_report "$status"
    syslog "Backup run: $status${LAST_ARCHIVE:+ ($(basename "$LAST_ARCHIVE"))}"
    release_lock
    return $rc
}

# Turn a backup number (from 'list') into a file path
backup_by_number() {
    collect_backups
    local n=$1
    if [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#BACKUP_LIST[@]} )); then
        echo "${BACKUP_LIST[n-1]}"
    else
        log ERROR "Invalid backup number: $n (see: ./lbas.sh list)"
        return 1
    fi
}

pick_backup() {
    list_backups || return 1
    local n
    read -rp "Enter backup number: " n
    PICKED=$(backup_by_number "$n") || return 1
}

ask_destination() {
    local d
    read -rp "Restore to [Enter = $RESTORE_DIR, / = original location]: " d
    d=${d:-$RESTORE_DIR}
    if [[ $d == / ]]; then
        echo "${YLW}Backed-up folders will be put back exactly as they were in this version:"
        echo "changed files are overwritten and files created after the backup are REMOVED.${RST}"
        confirm "Continue?" || return 1
    fi
    DEST=$d
}

schedule_menu() {
    echo "1) Daily at 02:00   2) Every 6 hours   3) Every hour   4) Custom   5) Show   6) Remove"
    local c s
    read -rp "Choice: " c
    case $c in
        1) s="0 2 * * *" ;;
        2) s="0 */6 * * *" ;;
        3) s="0 * * * *" ;;
        4) read -rp "Cron schedule (m h dom mon dow): " s ;;
        5) bash "$BASE_DIR/cron/schedule.sh" show; return ;;
        6) bash "$BASE_DIR/cron/schedule.sh" remove; return ;;
        *) echo "Invalid choice"; return ;;
    esac
    bash "$BASE_DIR/cron/schedule.sh" install "$s"
}

menu() {
    local c p
    while true; do
        echo
        echo "${BLD}=========== Linux Backup Automation System ===========${RST}"
        echo " Sources: ${SOURCES[*]}"
        echo "  1) Full backup              7) Restore single file/folder"
        echo "  2) Incremental backup       8) Search file in backups"
        echo "  3) Smart backup (auto)      9) System & storage status"
        echo "  4) List backups            10) Schedule automatic backups"
        echo "  5) Verify all backups      11) View recent logs"
        echo "  6) Restore complete backup 12) View backup contents"
        echo "  0) Exit"
        read -rp "Select option: " c || exit 0     # end of input (Ctrl+D)
        echo
        case $c in
            1) run_backup full ;;
            2) run_backup incr ;;
            3) run_backup auto ;;
            4) list_backups ;;
            5) verify_all ;;
            6) pick_backup && ask_destination && restore_backup "$PICKED" "$DEST" ;;
            7) if pick_backup; then
                   read -rp "Full path of file/folder (e.g. ${SOURCES[0]}/notes.txt): " p
                   ask_destination && restore_backup "$PICKED" "$DEST" "$p"
               fi ;;
            8) read -rp "File name or part of it: " p; search_backups "$p" ;;
            9) show_system_status ;;
            10) schedule_menu ;;
            11) show_logs ;;
            12) pick_backup && show_contents "$PICKED" ;;
            0) exit 0 ;;
            *) echo "Invalid option" ;;
        esac
        read -rp "Press Enter to continue..." _ || exit 0
    done
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [command]

  (no command)                  interactive menu
  full                          full backup
  incr                          incremental backup
  auto                          smart backup (used by cron)
  list                          list backup versions
  verify                        verify all backups
  contents <no>                 show files inside backup <no>
  restore <no> [dest]           restore backup <no> (default dest: $RESTORE_DIR)
  restore-file <no> <path> [dest]  restore one file/folder
  search <pattern>              find which backups contain a file
  status                        CPU / RAM / disk / storage status
  logs                          recent log, alerts and system journal
  schedule install "<cron>" | show | remove
  help                          this help
EOF
}

# ---------- command-line dispatch ----------
cmd=${1:-menu}
shift || true
case $cmd in
    menu)         menu ;;
    full|incr|auto) run_backup "$cmd" ;;
    list)         list_backups ;;
    verify)       verify_all ;;
    contents)     f=$(backup_by_number "${1:-}") && show_contents "$f" ;;
    restore)      f=$(backup_by_number "${1:-}") && restore_backup "$f" "${2:-}" ;;
    restore-file) [[ $# -ge 2 ]] || { usage; exit 1; }
                  f=$(backup_by_number "$1") && restore_backup "$f" "${3:-}" "$2" ;;
    search)       [[ $# -ge 1 ]] || { usage; exit 1; }; search_backups "$1" ;;
    status)       show_system_status ;;
    logs)         show_logs ;;
    schedule)     bash "$BASE_DIR/cron/schedule.sh" "$@" ;;
    help|-h|--help) usage ;;
    *)            usage; exit 1 ;;
esac
