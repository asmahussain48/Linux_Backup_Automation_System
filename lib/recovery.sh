#!/usr/bin/env bash
# =============================================================
#  recovery.sh - Member 2: Recovery & Security (Asma Hussain)
#  1. Checks backups for damage (SHA-256, gzip, tar)
#  2. Restores a whole backup or one file, keeping permissions
#  3. Searches backups and shows what is inside them
# =============================================================


# Check ONE backup for damage.
# Usage: verify_archive FILE [quiet]     ("quiet" = do not print "Valid")
verify_archive() {
    local file=$1 mode=${2:-}
    local name=${file##*/}          # file name without the folder
    local ok=1

    if [[ ! -f $file ]]; then
        log ERROR "Archive not found: $name"
        return 1
    fi

    # Check 1: does the SHA-256 fingerprint still match?
    if [[ ! -f $file.sha256 ]]; then
        log WARN "No checksum file for $name"
    elif ! ( cd "${file%/*}" && sha256sum --status -c "$name.sha256" ); then
        log ERROR "Checksum MISMATCH (file changed or corrupted): $name"
        ok=0
    fi

    # Check 2: is the gzip compression OK?
    if ! gzip -t "$file" 2>/dev/null; then
        log ERROR "Compression test failed: $name"
        ok=0
    fi

    # Check 3: can tar read the list of files inside?
    if ! tar -tzf "$file" >/dev/null 2>&1; then
        log ERROR "Archive structure unreadable: $name"
        ok=0
    fi

    if (( ok == 0 )); then
        return 1
    fi
    [[ $mode == quiet ]] || log OK "Valid: $name"
    return 0
}


# Check EVERY backup and raise an alert if any is damaged.
verify_all() {
    local f bad=0
    collect_backups
    local total=${#BACKUP_LIST[@]}

    if (( total == 0 )); then
        log WARN "No backups to verify."
        return 0
    fi

    for f in "${BACKUP_LIST[@]}"; do
        verify_archive "$f" || bad=$((bad + 1))
    done

    if (( bad > 0 )); then
        log ERROR "$bad of $total backups are corrupted."
        send_alert "$bad corrupted backup(s) found during verification"
        return 1
    fi
    log OK "All $total backups verified successfully."
}


# Which backups are needed to rebuild TARGET?
# The full backup it belongs to, then every incremental up to TARGET.
# (BACKUP_LIST is in order: full, its incrementals, next full, ...)
backups_needed() {
    local target=$1 f
    local -a needed=()
    collect_backups

    for f in "${BACKUP_LIST[@]}"; do
        [[ ${f##*/} == full_* ]] && needed=()   # a full backup starts a new chain
        needed+=("$f")
        [[ $f == "$target" ]] && break           # stop at the chosen version
    done
    printf '%s\n' "${needed[@]}"
}


# Restore a backup.
# Usage: restore_backup BACKUP [DESTINATION] [ONE_FILE]
#   DESTINATION: default is the safe restored/ folder (live files are not touched)
#   ONE_FILE:    full path of one file/folder; empty = restore everything
restore_backup() {
    local target=$1
    local dest=${2:-$RESTORE_DIR}
    local one_file=${3:-}
    local f found=0
    local -a needed=() owner=()

    if [[ ! -f $target ]]; then
        log ERROR "Backup not found: $target"
        return 1
    fi
    mapfile -t needed < <(backups_needed "$target")

    # Safety first: never restore from a damaged backup
    log INFO "Restore needs ${#needed[@]} archive(s). Verifying first..."
    for f in "${needed[@]}"; do
        if ! verify_archive "$f" quiet; then
            log ERROR "Restore aborted: ${f##*/} is damaged."
            return 1
        fi
    done

    mkdir -p "$dest" || { log ERROR "Cannot create $dest"; return 1; }

    # Only root (sudo) may give files back to their original owner
    (( EUID == 0 )) && owner=(--same-owner)

    # tar saves paths without the first "/", so remove it (and any last "/")
    one_file=${one_file#/}
    one_file=${one_file%/}

    # Unpack in order: full backup first, then each incremental.
    #   --listed-incremental=/dev/null : files deleted later stay deleted
    #   --preserve-permissions         : 600 stays 600, 755 stays 755
    for f in "${needed[@]}"; do
        if [[ -z $one_file ]]; then
            log INFO "  Extracting ${f##*/}"
            if ! tar -xzf "$f" --listed-incremental=/dev/null --preserve-permissions \
                     "${owner[@]}" -C "$dest" 2>>"$LOG_FILE"; then
                log ERROR "Extraction failed: ${f##*/}"
                return 1
            fi
        elif tar -xzf "$f" --listed-incremental=/dev/null --preserve-permissions \
                 "${owner[@]}" -C "$dest" "$one_file" 2>/dev/null; then
            # one file: it does not have to be inside every incremental
            found=1
            log INFO "  $one_file found in ${f##*/}"
        fi
    done

    if [[ -n $one_file ]] && (( found == 0 )); then
        log ERROR "'/$one_file' is not in this backup. Try: ./lbas.sh search <name>"
        return 1
    fi

    log OK "Restore complete -> $dest${one_file:+/$one_file}"
    echo "[$(date '+%F %T')] restored ${target##*/} ${one_file:+(/$one_file) }to $dest" >> "$LOG_DIR/recovery.log"
}


# Find which backups contain a file name (not case-sensitive).
search_backups() {
    local word=$1 f matches found=0
    collect_backups

    for f in "${BACKUP_LIST[@]}"; do
        # list the files in this backup (skip folders) and keep the matching ones
        matches=$(tar -tzf "$f" 2>/dev/null | grep -v '/$' | grep -i -- "$word")
        if [[ -n $matches ]]; then
            found=1
            echo "${BLD}${f##*/}${RST}"
            echo "$matches" | sed 's|^|   /|'
        fi
    done

    if (( found == 0 )); then
        log WARN "No backup contains a file matching '$word'."
        return 1
    fi
}


# List the files inside one backup: permissions, owner, size, date, time, path.
show_contents() {
    tar -tzvf "$1" | grep -v '/$' | awk '{
        name = $0
        for (i = 1; i <= 5; i++) sub(/^[^ ]+ +/, "", name)   # remove first 5 columns; keeps names with spaces
        printf "%s  %-10s %8s  %s %s  /%s\n", $1, $2, $3, $4, $5, name
    }'
}
