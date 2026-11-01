#!/usr/bin/env bash
# =============================================================
#  recovery.sh - MEMBER 2: Recovery & Security
#  Verification, checksums, restore (full / single file),
#  permission preservation, error handling
# =============================================================

# verify_archive FILE [quiet]  -> 3 checks: checksum, gzip, tar structure
verify_archive() {
    local a=$1 mode=${2:-} name dir bad=0
    name=$(basename "$a"); dir=$(dirname "$a")

    [[ -f $a ]] || { log ERROR "Archive not found: $a"; return 1; }

    if [[ -f $a.sha256 ]]; then
        ( cd "$dir" && sha256sum --status -c "$name.sha256" ) \
            || { log ERROR "Checksum MISMATCH (file changed or corrupted): $name"; bad=1; }
    else
        log WARN "No checksum file for $name"
    fi
    gzip -t "$a" 2>/dev/null      || { log ERROR "Compression test failed: $name"; bad=1; }
    tar -tzf "$a" >/dev/null 2>&1 || { log ERROR "Archive structure unreadable: $name"; bad=1; }

    if (( bad == 0 )) && [[ $mode != quiet ]]; then
        log OK "Valid: $name"
    fi
    return $bad
}

verify_all() {
    collect_backups
    (( ${#BACKUP_LIST[@]} )) || { log WARN "No backups to verify."; return 0; }
    local f bad=0
    for f in "${BACKUP_LIST[@]}"; do verify_archive "$f" || ((bad++)); done
    if (( bad )); then
        log ERROR "$bad of ${#BACKUP_LIST[@]} backups are corrupted."
        send_alert "$bad corrupted backup(s) found during verification"
        return 1
    fi
    log OK "All ${#BACKUP_LIST[@]} backups verified successfully."
}

# Archives needed to rebuild the state of TARGET: its full + incrementals up to it
chain_up_to() {
    local target=$1 base chain f
    base=$(basename "$target")
    chain=${base:5:15}                     # works for full_YYYYmmdd_HHMMSS and incr_YYYYmmdd_HHMMSS_...
    echo "$BACKUP_DIR/full_$chain.tar.gz"
    for f in "$BACKUP_DIR"/incr_"$chain"_*.tar.gz; do
        [[ -e $f ]] || continue
        [[ $f > $target ]] && break
        echo "$f"
    done
}

# restore_backup ARCHIVE [DEST] [PATH]
#   DEST defaults to RESTORE_DIR (safe - does not overwrite live files)
#   PATH restores only one file/folder, e.g. /home/student/Documents/notes.txt
restore_backup() {
    local target=$1 dest=${2:-$RESTORE_DIR} path=${3:-} a found=0
    local -a files owner_opt=()

    [[ -f $target ]] || { log ERROR "Backup not found: $target"; return 1; }
    mapfile -t files < <(chain_up_to "$target")

    log INFO "Restore needs ${#files[@]} archive(s). Verifying first..."
    for a in "${files[@]}"; do
        verify_archive "$a" quiet || { log ERROR "Restore aborted: $(basename "$a") is damaged."; return 1; }
    done

    mkdir -p "$dest" || { log ERROR "Cannot create $dest"; return 1; }
    # root can restore original owners too; normal users keep permission bits
    (( EUID == 0 )) && owner_opt=(--same-owner)
    path=${path#/}; path=${path%/}

    for a in "${files[@]}"; do
        if [[ -n $path ]]; then
            # The file may not be inside every incremental - that is normal
            if tar -xzf "$a" --listed-incremental=/dev/null --preserve-permissions \
                   "${owner_opt[@]}" -C "$dest" "$path" 2>/dev/null; then
                found=1
                log INFO "  $path found in $(basename "$a")"
            fi
        else
            log INFO "  Extracting $(basename "$a")"
            tar -xzf "$a" --listed-incremental=/dev/null --preserve-permissions \
                "${owner_opt[@]}" -C "$dest" 2>>"$LOG_FILE" \
                || { log ERROR "Extraction failed: $(basename "$a")"; return 1; }
        fi
    done

    if [[ -n $path ]] && (( ! found )); then
        log ERROR "'/$path' is not in this backup. Try: ./lbas.sh search <name>"
        return 1
    fi
    log OK "Restore complete -> $dest${path:+/$path}"
    echo "[$(date '+%F %T')] restored $(basename "$target") ${path:+(/$path) }to $dest" >> "$LOG_DIR/recovery.log"
}

# Find which backups contain a file name/pattern
search_backups() {
    local pattern=$1 f hits found=0
    collect_backups
    for f in "${BACKUP_LIST[@]}"; do
        hits=$(tar -tzf "$f" 2>/dev/null | grep -v '/$' | grep -i -- "$pattern")
        if [[ -n $hits ]]; then
            found=1
            echo "${BLD}$(basename "$f")${RST}"; sed 's|^|   /|' <<< "$hits"
        fi
    done
    (( found )) || { log WARN "No backup contains a file matching '$pattern'."; return 1; }
}

# Columns: permissions, owner/group, size, date, time, name (name may contain spaces)
show_contents() {
    tar -tzvf "$1" | grep -v '/$' | awk '{
        name = $0
        for (i = 1; i <= 5; i++) sub(/^[^ ]+ +/, "", name)
        printf "%s  %-10s %8s  %s %s  /%s\n", $1, $2, $3, $4, $5, name
    }'
}
