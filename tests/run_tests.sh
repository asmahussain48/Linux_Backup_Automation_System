#!/usr/bin/env bash
# =============================================================
#  run_tests.sh - automatic test / live demo of all features
#  Uses a temporary copy of the project so real data is untouched.
# =============================================================
PROJECT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T=$(mktemp -d)
cp -r "$PROJECT"/{lbas.sh,lib,config,cron} "$T"/
L="$T/lbas.sh"
SRC="$T/source"
PASS=0; FAIL=0

check() {  # check "description" command...
    local d=$1; shift
    if "$@" >/dev/null 2>&1; then echo "  PASS  $d"; ((PASS++)); else echo "  FAIL  $d"; ((FAIL++)); fi
}
step() { echo; echo "== $* =="; }

step "1. Prepare test data"
mkdir -p "$SRC/docs"
echo "hello"        > "$SRC/file1.txt"
echo "world"        > "$SRC/file2.txt"
echo "secret"       > "$SRC/docs/private.txt"; chmod 600 "$SRC/docs/private.txt"
printf '#!/bin/bash\necho hi\n' > "$SRC/run.sh"; chmod 755 "$SRC/run.sh"
echo "notes"        > "$SRC/my notes.txt"
echo "junk"         > "$SRC/ignore.tmp"

step "2. Smart backup with no history -> full"
"$L" auto
check "full backup created" compgen -G "$T/backups/full_*.tar.gz"
check "checksum file created" compgen -G "$T/backups/full_*.sha256"
check "*.tmp excluded" bash -c "! tar -tzf $T/backups/full_*.tar.gz | grep -q ignore.tmp"
check "report generated" compgen -G "$T/reports/report_*.txt"

step "3. Smart backup with no changes -> skipped"
sleep 1; "$L" auto
check "no incremental created" bash -c "! compgen -G '$T/backups/incr_*'"

step "4. Change files -> incremental"
sleep 1
echo "hello v2" > "$SRC/file1.txt"
echo "new"      > "$SRC/new.txt"
rm "$SRC/file2.txt"
"$L" auto
check "incremental created" compgen -G "$T/backups/incr_*.tar.gz"
check "incremental contains only changed file" bash -c "! tar -tzf $T/backups/incr_*.tar.gz | grep -q run.sh"

step "5. Permission change only (chmod) -> incremental"
sleep 1
chmod 640 "$SRC/new.txt"
"$L" auto
check "chmod alone is detected as a change" test "$(ls "$T"/backups/incr_*.tar.gz | wc -l)" -eq 2

step "6. List, verify & contents"
"$L" list
check "all backups valid" "$L" verify
check "contents shows names with spaces" bash -c "'$L' contents 1 | grep -q 'my notes.txt\$'"

step "7. Full restore of version 2 (full + incremental)"
"$L" restore 2 "$T/r1"
R="$T/r1${SRC}"
check "modified file has new content" grep -q "hello v2" "$R/file1.txt"
check "new file restored" test -f "$R/new.txt"
check "deleted file stays deleted" test ! -e "$R/file2.txt"
check "permission 600 preserved" test "$(stat -c %a "$R/docs/private.txt")" = 600
check "permission 755 preserved" test "$(stat -c %a "$R/run.sh")" = 755

step "8. Restore version 3 (permission change only)"
"$L" restore 3 "$T/r4"
check "new permission 640 restored" test "$(stat -c %a "$T/r4${SRC}/new.txt")" = 640

step "9. Restore old version of a single file"
"$L" restore-file 1 "$SRC/file2.txt" "$T/r2"
check "deleted file recovered from full backup" grep -q world "$T/r2${SRC}/file2.txt"

step "10. Search"
"$L" search private
check "search finds a file" bash -c "'$L' search private | grep -q docs/private.txt"
check "search reports unknown name" bash -c "! '$L' search no_such_file"

step "11. Corruption detection"
f=$(ls "$T"/backups/incr_*.tar.gz | head -1)
cp "$f" "$T/good.bak"
printf 'CORRUPT' | dd of="$f" bs=1 seek=20 conv=notrunc 2>/dev/null
check "verify detects corruption" bash -c "! $L verify"
check "restore refuses corrupted chain" bash -c "! $L restore 2 $T/r3"
cp "$T/good.bak" "$f"

step "12. Locking (flock)"
# hold the lock from outside, like a running cron job would
check "second backup refused while one is running" bash -c "! flock '$T/snapshots/.lbas.lock' '$L' full"

step "13. Retention (KEEP_CHAINS=3)"
for i in 1 2 3 4; do sleep 1; "$L" full >/dev/null; done
check "only 3 chains kept" test "$(ls "$T"/backups/full_*.tar.gz | wc -l)" -eq 3

step "14. Status & low-storage warning"
sed 's/^STORAGE_WARN_PERCENT=.*/STORAGE_WARN_PERCENT=1/' "$T/config/lbas.conf" > "$T/low.conf"
: > "$T/logs/alerts.log"
LBAS_CONFIG="$T/low.conf" "$L" status > "$T/status.txt"
head -n 6 "$T/status.txt"
check "low storage raises an alert" grep -q "Low backup storage" "$T/logs/alerts.log"

echo; echo "RESULT: $PASS passed, $FAIL failed   (test folder: $T)"
(( FAIL == 0 ))
