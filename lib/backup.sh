#!/usr/bin/env bash
# =============================================================
#  backup.sh - Member 1: Backup Management (Eshwar Lal)
# =============================================================

# Config ke EXCLUDES se tar aur find ke options banata hai
build_tar_excludes() {
    TAR_EXCLUDES=()
    FIND_EXCLUDES=()
    local p
    for p in "${EXCLUDES[@]}"; do
        TAR_EXCLUDES+=(--exclude="$p")
        FIND_EXCLUDES+=(! -name "$p")
    done
}

# SOURCES mein se sirf wo folders rakhta hai jo sach mein maujood hain
check_sources() {
    VALID_SOURCES=()
    local s
    for s in "${SOURCES[@]}"; do
        if [[ -e $s ]]; then
            VALID_SOURCES+=("$s")
        else
            log WARN "Source not found, skipped: $s"
        fi
    done
    if (( ${#VALID_SOURCES[@]} == 0 )); then
        log ERROR "No valid source folder. Check SOURCES in config/lbas.conf"
        return 1
    fi
}

# BACKUP_LIST array bharta hai: purane se naya (time ke hisab se)
collect_backups() {
    BACKUP_LIST=()
    local f b line
    while IFS= read -r line; do
        BACKUP_LIST+=("${line#*$'\t'}")
    done < <(
        for f in "$BACKUP_DIR"/full_*.tar.gz "$BACKUP_DIR"/incr_*.tar.gz; do
            [[ -e $f ]] || continue
            b=${f##*/}
            printf '%s\t%s\n' "${b#*_}" "$f"
        done | sort
    )
}

# Numbered list of backup versions
list_backups() {
    collect_backups
    if (( ${#BACKUP_LIST[@]} == 0 )); then
        log WARN "No backups found. Create one with: ./lbas.sh full"
        return 1
    fi
    printf '%s%-4s %-6s %-20s %10s  %s%s\n' "$BLD" No Type Created Size File "$RST"
    local i f b type when
    for i in "${!BACKUP_LIST[@]}"; do
        f=${BACKUP_LIST[i]}
        b=${f##*/}
        type=${b%%_*}
        when=$(date -r "$f" '+%Y-%m-%d %H:%M:%S')
        printf '%-4s %-6s %-20s %10s  %s\n' "$((i+1))" "$type" "$when" \
            "$(human "$(stat -c %s "$f")")" "$b"
    done
}

# create_backup full|incr
create_backup() {
    local type=$1
    local snar="$SNAP_DIR/backup.snar"
    local new_snar="$SNAP_DIR/backup.snar.new"
    local marker="$SNAP_DIR/last_backup.marker"
    local new_marker="$SNAP_DIR/last_backup.marker.new"
    local ts archive name rc s
    local -a rel=()
    LAST_RESULT=""; LAST_ARCHIVE=""

    check_sources || return 1

    if [[ $type == incr && ! -f $snar ]]; then
        log WARN "No full backup exists yet - making a full backup instead."
        type=full
    fi

    ts=$(date '+%Y-%m-%d_%H-%M-%S')
    archive="$BACKUP_DIR/${type}_${ts}.tar.gz"
    name=${archive##*/}

    # Snapshot ki working copy: backup fail ho to asli snapshot nahi badlega
    rm -f "$new_snar"
    if [[ $type == incr ]]; then cp "$snar" "$new_snar"; fi
    touch "$new_marker"          # backup shuru hone ka waqt

    for s in "${VALID_SOURCES[@]}"; do rel+=("${s#/}"); done

    log INFO "Starting $type backup of: ${VALID_SOURCES[*]}"
    tar --create --gzip --file="$archive.part" \
        --listed-incremental="$new_snar" --preserve-permissions \
        -C / "${TAR_EXCLUDES[@]}" -- "${rel[@]}"
    rc=$?

    if (( rc > 1 )) || ! gzip -t "$archive.part" 2>/dev/null; then
        mv -f "$archive.part" "$archive.failed" 2>/dev/null
        rm -f "$new_snar" "$new_marker"
        log ERROR "Backup failed (tar exit code $rc). Kept as $name.failed"
        send_alert "Backup FAILED: $name"
        return 1
    fi
    (( rc == 1 )) && log WARN "Some files changed while being read (backup is still saved)."

    mv "$archive.part" "$archive"
    chmod 600 "$archive"
    ( cd "$BACKUP_DIR" && sha256sum "$name" > "$name.sha256" )
    chmod 600 "$archive.sha256"
    mv -f "$new_snar" "$snar"
    mv -f "$new_marker" "$marker"

    LAST_ARCHIVE=$archive
    LAST_RESULT=created
    log OK "$type backup created: $name ($(human "$(stat -c %s "$archive")"))"
    apply_retention
    return 0
}

# Sirf naye KEEP_CHAINS chains rakhta hai (full + uske incrementals)
apply_retention() {
    collect_backups
    local -a fulls=()
    local i cut
    for i in "${!BACKUP_LIST[@]}"; do
        [[ ${BACKUP_LIST[i]##*/} == full_* ]] && fulls+=("$i")
    done
    (( ${#fulls[@]} > KEEP_CHAINS )) || return 0
    cut=${fulls[${#fulls[@]}-KEEP_CHAINS]}      # sabse purani full jo rakhni hai
    for (( i=0; i<cut; i++ )); do
        rm -f "${BACKUP_LIST[i]}" "${BACKUP_LIST[i]}.sha256"
        log INFO "Retention: removed old backup ${BACKUP_LIST[i]##*/}"
    done
}

# Kitne incrementals pichli full ke baad bane hain
incrs_since_last_full() {
    collect_backups
    local n=0 i
    for (( i=${#BACKUP_LIST[@]}-1; i>=0; i-- )); do
        [[ ${BACKUP_LIST[i]##*/} == full_* ]] && break
        n=$((n+1))
    done
    echo "$n"
}

# Smart mode: skip / full / incremental
auto_backup() {
    local snar="$SNAP_DIR/backup.snar"
    local marker="$SNAP_DIR/last_backup.marker"
    local changed n

    check_sources || return 1
    if [[ ! -f $snar || ! -f $marker ]]; then
        log INFO "No previous backup found -> full backup"
        create_backup full
        return $?
    fi

    changed=$(find "${VALID_SOURCES[@]}" -cnewer "$marker" "${FIND_EXCLUDES[@]}" -print -quit 2>/dev/null)
    if [[ -z $changed ]]; then
        LAST_RESULT=skipped; LAST_ARCHIVE=""
        log INFO "No changes since the last backup -> skipped"
        return 0
    fi

    n=$(incrs_since_last_full)
    if (( n >= MAX_INCREMENTALS )); then
        log INFO "$n incrementals since the last full -> new full backup"
        create_backup full
    else
        log INFO "Changes found -> incremental backup"
        create_backup incr
    fi
}
