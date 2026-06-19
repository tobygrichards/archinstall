#!/usr/bin/env bash
# backup.sh — encrypted backup of /data to an external drive, and restore.
#
# SEPARATE from the provisioner by design: the thing that can wipe @ must never
# be the thing that touches your backup. This script never partitions the OS
# disk and the provisioner never touches the backup drive.
#
# The backup drive is LUKS-encrypted: unreadable to anyone who steals it. The
# data layer is a plain filesystem INSIDE the LUKS container, so the rsync is
# ordinary — encryption is just an unlock/lock wrapper around it.
#
# Modes:
#   init            ONE-TIME. LUKS-format a NEW drive. DESTRUCTIVE. Run once.
#   backup          /data -> drive. Accumulates (never deletes from backup).
#   restore         drive -> /data. For recovery or moving to a new PC.
#   any + --dry-run Show what would change; touch nothing.
#
# Usage:
#   sudo ./backup.sh init /dev/sdX
#   sudo ./backup.sh backup [--dry-run]
#   sudo ./backup.sh restore [--dry-run]

set -euo pipefail

# ====================================================================
# CONFIG
# ====================================================================
SOURCE=/data                      # what gets backed up
BACKUP_LABEL=archbackup           # LUKS+fs label; how the drive is found
MOUNT=/run/backup-mnt             # where the unlocked drive is mounted
MAPPER=backupcrypt                # /dev/mapper/<this> when unlocked
RESTORE_UID=1000                  # uid to chown restored files to (new-PC case)
RESTORE_GID=1000

# Paths under $SOURCE to skip. Resolve DB and Steam-ish caches aren't worth it.
EXCLUDES=(
  ".resolve-db/.cache"
  "lost+found"
)

# ====================================================================
# helpers
# ====================================================================
log()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo (needs cryptsetup + mount)."

# Find the backup drive's PARTITION by its LUKS label. Returns the device node.
# We match the LUKS label, not a filesystem label (the fs is inside LUKS).
find_backup_dev() {
  local dev
  dev="$(blkid -t TYPE=crypto_LUKS -o device | while read -r d; do
            if cryptsetup luksDump "$d" 2>/dev/null | grep -q "Label:.*$BACKUP_LABEL"; then
              echo "$d"; break
            fi
          done)"
  # fallback: some setups label by partlabel
  [[ -z "$dev" ]] && dev="$(blkid -t PARTLABEL="$BACKUP_LABEL" -o device 2>/dev/null | head -1)"
  printf '%s' "$dev"
}

# Unlock + mount, with a trap so we ALWAYS lock + unmount on exit (even on
# failure). Same lesson as the provisioner's temp-sudo: paired teardown.
_unlocked=0; _mounted=0
open_drive() {
  local dev="$1"
  log "unlocking $dev (passphrase prompt follows)"
  cryptsetup luksOpen "$dev" "$MAPPER"; _unlocked=1
  install -d "$MOUNT"
  mount "/dev/mapper/$MAPPER" "$MOUNT"; _mounted=1
  trap close_drive EXIT
}
close_drive() {
  (( _mounted )) && { umount "$MOUNT" 2>/dev/null && _mounted=0; }
  (( _unlocked )) && { cryptsetup luksClose "$MAPPER" 2>/dev/null && _unlocked=0; }
  trap - EXIT
}

build_excludes() {
  local e; EXCLUDE_ARGS=()
  for e in "${EXCLUDES[@]}"; do EXCLUDE_ARGS+=(--exclude="$e"); done
}

# ====================================================================
# init — ONE-TIME, DESTRUCTIVE. The single most dangerous action here.
# ====================================================================
mode_init() {
  local dev="${1:-}"
  [[ -n "$dev" ]] || die "init needs the target device, e.g. sudo $0 init /dev/sdX"
  [[ -b "$dev" ]] || die "$dev is not a block device."

  # refuse anything mounted as a system path — guard against hitting the OS disk
  if lsblk -no MOUNTPOINT "$dev" | grep -qE '^/$|^/boot|^/home|^/data'; then
    die "$dev has system mountpoints — refusing. This is for an EXTERNAL drive only."
  fi

  warn "About to ERASE and LUKS-encrypt: $dev"
  lsblk "$dev"
  warn "This destroys everything on it, irreversibly."
  read -rp "Type the device path to confirm: " ans
  [[ "$ans" == "$dev" ]] || die "mismatch — aborting."

  warn "Choose a STRONG passphrase. If you lose it, the backup is unrecoverable —"
  warn "to you AND to a thief. Store it somewhere safe that is NOT this machine."

  log "LUKS-formatting $dev"
  cryptsetup luksFormat --label "$BACKUP_LABEL" "$dev"
  log "unlocking to create the filesystem"
  cryptsetup luksOpen "$dev" "$MAPPER"; _unlocked=1
  trap close_drive EXIT
  mkfs.ext4 -L "$BACKUP_LABEL" "/dev/mapper/$MAPPER"
  close_drive
  log "init complete. The drive is ready for: sudo $0 backup"
}

# ====================================================================
# backup — /data -> drive. Accumulates (NO --delete).
# ====================================================================
mode_backup() {
  local dry="${1:-}"
  [[ -d "$SOURCE" ]] || die "$SOURCE does not exist — nothing to back up."
  local dev; dev="$(find_backup_dev)"
  [[ -n "$dev" ]] || die "backup drive (label '$BACKUP_LABEL') not found. Plugged in?"

  log "found backup drive: $dev"
  lsblk "$dev"
  read -rp "Back up $SOURCE to this drive? [y/N] " ans
  [[ "$ans" == [yY] ]] || die "aborted."

  open_drive "$dev"
  build_excludes
  local rsync_opts=(-aH --info=stats2,progress2 "${EXCLUDE_ARGS[@]}")
  [[ "$dry" == "--dry-run" ]] && { rsync_opts+=(--dry-run); warn "DRY RUN — nothing written."; }

  # NO --delete: deletions in /data do not propagate. Backup accumulates.
  rsync "${rsync_opts[@]}" "$SOURCE"/ "$MOUNT"/
  sync
  close_drive
  log "backup complete."
}

# ====================================================================
# restore — drive -> /data. Recovery, or onto a new PC.
# ====================================================================
mode_restore() {
  local dry="${1:-}"
  local dev; dev="$(find_backup_dev)"
  [[ -n "$dev" ]] || die "backup drive (label '$BACKUP_LABEL') not found. Plugged in?"

  log "found backup drive: $dev"
  warn "Restore will COPY from the drive into $SOURCE (existing files updated)."
  read -rp "Proceed? [y/N] " ans
  [[ "$ans" == [yY] ]] || die "aborted."

  install -d "$SOURCE"
  open_drive "$dev"
  build_excludes
  local rsync_opts=(-aH --info=stats2,progress2 "${EXCLUDE_ARGS[@]}")
  [[ "$dry" == "--dry-run" ]] && { rsync_opts+=(--dry-run); warn "DRY RUN — nothing written."; }

  rsync "${rsync_opts[@]}" "$MOUNT"/ "$SOURCE"/
  if [[ "$dry" != "--dry-run" ]]; then
    # new-PC case: restored files may carry a different uid. Normalise ownership.
    log "fixing ownership to ${RESTORE_UID}:${RESTORE_GID}"
    chown -R "${RESTORE_UID}:${RESTORE_GID}" "$SOURCE"
  fi
  sync
  close_drive
  log "restore complete."
}

# ====================================================================
case "${1:-}" in
  init)    mode_init    "${2:-}" ;;
  backup)  mode_backup  "${2:-}" ;;
  restore) mode_restore "${2:-}" ;;
  *) die "usage: sudo $0 {init <dev>|backup|restore} [--dry-run]" ;;
esac
