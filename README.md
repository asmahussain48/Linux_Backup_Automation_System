# Linux Backup Automation System (LBAS)

Bash-based backup & recovery system: full/incremental backups, checksums,
restore (full or single file), permission preservation, retention,
cron scheduling, resource/storage monitoring, logs and reports.

## Project structure

```
Linux_Backup_Automation_System/
├── lbas.sh              main program (menu + commands)
├── config/lbas.conf     settings: sources, retention, warning limit
├── lib/
│   ├── common.sh        logging, alerts, locking (shared)
│   ├── backup.sh        Member 1 - backup management
│   ├── recovery.sh      Member 2 - recovery & security
│   └── monitor.sh       Member 3 - monitoring & reports
├── cron/schedule.sh     Member 3 - cron scheduling
├── tests/run_tests.sh   automatic test / demo
└── source/              sample folder to back up
# created automatically on first run:
├── backups/   snapshots/   logs/   reports/   restored/
```

## Setup (Ubuntu)

```bash
sudo apt install cron            # usually already installed
cd Linux_Backup_Automation_System
chmod +x lbas.sh cron/schedule.sh tests/run_tests.sh
./tests/run_tests.sh             # should print: 24 passed, 0 failed
```

Edit `config/lbas.conf` and set `SOURCES` to the folders you want to protect
(absolute paths, e.g. `"$HOME/Documents"`).

**Important when moving the project from Windows into the VM:**

- Copy the folder into the Linux home directory (e.g. `~/Linux_Backup_Automation_System`).
  Do **not** run it from a VirtualBox shared folder (`/media/sf_...`): shared
  folders ignore `chmod`, so the permission features and tests will fail there.
- If you see `$'\r': command not found`, the files got Windows line endings.
  Fix with: `sed -i 's/\r$//' lbas.sh lib/*.sh cron/*.sh tests/*.sh config/lbas.conf`

## Usage

```bash
./lbas.sh                         # interactive menu
./lbas.sh full                    # full backup
./lbas.sh incr                    # incremental backup
./lbas.sh auto                    # smart: full / incremental / skip
./lbas.sh list                    # show versions (numbered)
./lbas.sh verify                  # checksum + gzip + tar checks
./lbas.sh contents 2              # files inside backup #2
./lbas.sh restore 2               # restore version #2 into ./restored
./lbas.sh restore-file 1 /home/student/Documents/notes.txt
./lbas.sh search notes
./lbas.sh status                  # CPU, RAM, disk, storage
./lbas.sh logs                    # backup log, alerts, journalctl -t lbas
./lbas.sh schedule install "0 2 * * *"   # every day at 02:00
./lbas.sh schedule show | remove
```

## How it works

- **Full backup** - `tar --listed-incremental` with a new snapshot file (level 0).
- **Incremental** - same snapshot file, so tar stores only new/changed files
  and records deletions.
- **Chain** - a full backup plus its incrementals. Restoring version N extracts
  the full backup, then each incremental up to N, in order.
- **Smart mode** - `find -cnewer last_backup.marker` counts changes (content
  edits and `chmod`/`chown` changes, the same rule tar uses):
  0 → skip, no full yet or ≥ `MAX_INCREMENTALS` → full, else → incremental.
- **Integrity** - every archive gets a `.sha256`; verify also runs `gzip -t` and
  `tar -t`. Restore refuses damaged archives. Failed backups are renamed
  `.failed` and the snapshot is not updated.
- **Permissions** - tar stores mode/owner; restore uses `--preserve-permissions`
  (and `--same-owner` when run with sudo). Backup folders are `chmod 700`.
- **Retention** - keeps the newest `KEEP_CHAINS` chains (whole chains are removed,
  because incrementals are useless without their full backup).
- **Safety** - `flock` on `snapshots/.lbas.lock` prevents two backups at once
  (cron + manual); restore goes to `restored/` unless you choose `/` and confirm.
  Restoring to `/` puts folders back exactly as in that version, so files
  created after the backup are removed.
- **Logs** - `logs/lbas.log`, `alerts.log`, `recovery.log`, `cron.log`; every
  backup run, error and alert also goes to the system log (`journalctl -t lbas`).

## OS concepts covered

| Concept | Where in the project |
|---|---|
| File system | `tar` archives, snapshot files, `find`, `stat`, `du`, directory layout |
| Permissions | `chmod 700/600` on backups, `--preserve-permissions`, `--same-owner` |
| Processes | `ps` top processes, CPU usage from `/proc/stat`, load average |
| Synchronization | `flock` lock file - only one backup process at a time |
| Scheduling | `cron` jobs installed with `crontab` |
| Storage management | retention of old chains, `df` free-space checks, low-space warnings |
| Data integrity | `sha256sum`, `gzip -t`, `tar -t`, failed backups kept as `.failed` |
| System logging | `logger` → syslog/journal, read with `journalctl -t lbas` |

## Team split

| Member | Files | Features |
|---|---|---|
| 1 - Backup | `lib/backup.sh` | full, incremental, compression, versions, retention, smart mode |
| 2 - Recovery & Security | `lib/recovery.sh` | verify, checksums, restore, single file, permissions, search |
| 3 - Automation & Monitoring | `lib/monitor.sh`, `cron/schedule.sh` | cron, CPU/RAM/disk, storage warnings, reports, alerts |
| All | `lbas.sh`, `common.sh`, `tests/` | menu, integration, testing |

## Demo script (for presentation)

1. `./lbas.sh status` - system resources
2. Add files to `source/`, `./lbas.sh auto` → full backup
3. `./lbas.sh auto` again → "no changes, skipped"
4. Edit a file, delete a file → `./lbas.sh auto` → incremental
5. `./lbas.sh list`, `./lbas.sh verify`
6. `rm -rf source/*` (simulate loss) → `./lbas.sh restore 2 /` → files back
7. Restore the deleted file from version 1 with `restore-file`
8. Corrupt an archive (`echo x >> backups/full_*.tar.gz`) → `verify` catches it
9. `./lbas.sh schedule install "*/2 * * * *"`, wait, show `logs/cron.log`
10. Show `reports/` and `./lbas.sh logs` (includes `journalctl -t lbas`)
