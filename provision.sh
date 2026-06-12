#!/usr/bin/env bash
# provision.sh — orchestration. TWO subcommands, kept apart on purpose:
#
#   provision.sh disk     DESTRUCTIVE. Partition, subvolumes, pacstrap.
#                         Run once from the live ISO. Guarded + confirmed.
#
#   provision.sh system   RE-RUNNABLE. Packages, services, user, dotfiles.
#                         Safe to run repeatedly on a live box. Touches NO disks.
#
# The wall between these two is the whole safety story. Don't merge them.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config.sh"
source "$HERE/lib.sh"

MOUNT=/mnt
BTRFS_OPTS="noatime,compress=zstd,space_cache=v2"

# ====================================================================
# PHASE: disk   (DESTRUCTIVE — one-shot, from the live ISO)
# ====================================================================
# Partition naming. nvme/mmc use pN; sd/vd use N. Resolve once, here.
set_partitions() {
  if [[ "$TARGET_DISK" =~ (nvme|mmcblk|loop) ]]; then
    ESP="${TARGET_DISK}p1"; ROOT="${TARGET_DISK}p2"
  else
    ESP="${TARGET_DISK}1";  ROOT="${TARGET_DISK}2"
  fi
}

# ====================================================================
# PHASE: disk   (DESTRUCTIVE — from the live ISO)
# Detects state, then routes to fresh build or rebuild. Never both.
# ====================================================================
phase_disk() {
  require_disk
  set_partitions

  local state; state="$(detect_disk_state "$ROOT")"
  log "disk state: $state"

  case "$state" in
    fresh)
      confirm_wipe
      fresh_disk ;;
    rebuild)
      confirm_wipe
      rebuild_disk ;;
    ambiguous)
      die "disk state ambiguous on $TARGET_DISK — btrfs present but @data not found.
           Refusing to guess. If this really is a disposable disk, wipe it by hand first
           (e.g. wipefs -a $ROOT) and re-run for a fresh build." ;;
    *)
      die "unknown disk state: $state" ;;
  esac

  mount_tree
  install_base
  warn "bootloader (Limine) not implemented — install + config goes here"
}

# --- fresh: blank disk. The ONLY path allowed to mkfs. --------------
fresh_disk() {
  # --- partition (STUB) --------------------------------------------
  # Dies here so the skeleton can't format until you consciously enable it.
  #   sgdisk -Z "$TARGET_DISK"
  #   sgdisk -n1:0:+1G -t1:ef00 -n2:0:0 -t2:8300 "$TARGET_DISK"
  die "fresh partition+mkfs not implemented — fill in, then delete this line"
  # mkfs.fat -F32 "$ESP"
  # mkfs.btrfs -f "$ROOT"

  mount "$ROOT" "$MOUNT"
  for sv in "${WIPE_SUBVOLS[@]}"; do ensure_subvol "$MOUNT" "$sv"; done
  for sv in "${KEEP_SUBVOLS[@]}"; do ensure_subvol "$MOUNT" "$sv"; done
  umount "$MOUNT"
}

# --- rebuild: populated disk. mkfs is FORBIDDEN here. ---------------
rebuild_disk() {
  mount "$ROOT" "$MOUNT"
  for sv in "${WIPE_SUBVOLS[@]}"; do
    destroy_subvol "$MOUNT" "$sv"     # guarded: refuses @data
    ensure_subvol  "$MOUNT" "$sv"
  done
  for sv in "${KEEP_SUBVOLS[@]}"; do
    ensure_subvol  "$MOUNT" "$sv"     # @data: left alone if present
  done
  umount "$MOUNT"
}

# --- common: mount the freshly-laid tree and install base ----------
mount_tree() {
  mount -o "$BTRFS_OPTS,subvol=@"     "$ROOT" "$MOUNT"
  mkdir -p "$MOUNT"/{home,data,boot}
  mount -o "$BTRFS_OPTS,subvol=@home" "$ROOT" "$MOUNT/home"
  mount -o "$BTRFS_OPTS,subvol=@data" "$ROOT" "$MOUNT/data"
  mount "$ESP" "$MOUNT/boot"
}

install_base() {
  pacstrap -K "$MOUNT" "${PACKAGES[@]}"
  genfstab -U "$MOUNT" >> "$MOUNT/etc/fstab"
  cp -r "$HERE" "$MOUNT/root/provision"
  arch-chroot "$MOUNT" /root/provision/provision.sh system
}

# ====================================================================
# PHASE: system   (RE-RUNNABLE — idempotent, touches no disks)
# ====================================================================
phase_system() {
  log "locale / time / hostname (STUB — wire from config.sh)"
  # ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  # [[ "$(cat /etc/hostname 2>/dev/null)" == "$HOSTNAME" ]] || echo "$HOSTNAME" > /etc/hostname

  log "packages"
  pkg_install

  log "user"
  ensure_user "$USERNAME" "$USER_UID" "$USER_GROUPS"

  log "services"
  for s in "${SERVICES[@]}"; do ensure_service "$s"; done

  log "aur (STUB)"
  # bootstrap paru/yay once, then install "${AUR[@]}" guarded by `pacman -Qq`

  log "dotfiles — config is disposable, git owns it (STUB)"
  # [[ -d "$DOTFILES_DIR" ]] || git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
  # stow -d "$DOTFILES_DIR" -t "/home/$USERNAME" <packages>

  log "system phase complete"
}

# ====================================================================
case "${1:-}" in
  disk)   phase_disk   ;;
  system) phase_system ;;
  *) die "usage: $0 {disk|system}" ;;
esac
