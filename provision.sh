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
# Partition nodes, via the shared helper in lib.sh (single source of truth).
set_partitions() {
  ESP="$(part_node "$TARGET_DISK" 1)"
  ROOT="$(part_node "$TARGET_DISK" 2)"
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
  resolve_passwords
  install_base
  # systemd-boot is installed inside the chroot by phase_system.
}

# Resolve passwords to hashes BEFORE the chroot (where we have a terminal).
# Priority: env-supplied hash wins (unattended) -> else prompt if interactive
# -> else leave empty (account untouched). The hash, not the plaintext, is
# what install_base forwards across the chroot boundary.
resolve_passwords() {
  if [[ -z "${ROOT_PASSWD_HASH:-}" && -t 0 ]]; then
    ROOT_PASSWD_HASH="$(prompt_password root || true)"
  fi
  if [[ -z "${USER_PASSWD_HASH:-}" && -t 0 ]]; then
    USER_PASSWD_HASH="$(prompt_password "$USERNAME" || true)"
  fi
}

# --- fresh: blank disk. The ONLY path allowed to mkfs. --------------
fresh_disk() {
  # Defence in depth: we only get here from the `fresh` branch, but this
  # is the irreversible line, so re-probe RIGHT before destroying. If a
  # @data ever shows up between detection and now, abort — never format it.
  local recheck; recheck="$(detect_disk_state "$ROOT")"
  [[ "$recheck" == fresh ]] \
    || die "pre-wipe re-check returned '$recheck', expected 'fresh' — refusing to format $TARGET_DISK."

  log "wiping signatures on $TARGET_DISK"
  wipefs -a "$TARGET_DISK"
  sgdisk -Z "$TARGET_DISK"                      # zap any GPT/MBR remnants

  log "creating GPT: ESP (1G) + btrfs (rest)"
  sgdisk -o \
    -n 1:0:+1G  -t 1:ef00 -c 1:ESP \
    -n 2:0:0    -t 2:8300 -c 2:root \
    "$TARGET_DISK"

  # Let the kernel/udev catch up before the nodes are used.
  partprobe "$TARGET_DISK" || true
  udevadm settle || true
  local n
  for n in {1..10}; do [[ -b "$ESP" && -b "$ROOT" ]] && break; sleep 0.5; done
  [[ -b "$ESP" && -b "$ROOT" ]] || die "partition nodes ($ESP, $ROOT) did not appear."

  log "making filesystems"
  mkfs.fat -F32 -n ESP "$ESP"
  mkfs.btrfs -f -L SYSTEM "$ROOT"

  log "creating subvolumes"
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
  # arch-chroot starts a clean environment, so runtime secrets set on the
  # ISO (e.g. ROOT_PASSWD_HASH=... ./provision.sh disk) would NOT survive
  # the boundary. Forward them explicitly via env, not via a file on disk.
  arch-chroot "$MOUNT" env \
    ROOT_PASSWD_HASH="${ROOT_PASSWD_HASH:-}" \
    USER_PASSWD_HASH="${USER_PASSWD_HASH:-}" \
    /root/provision/provision.sh system
  # Don't leave the provisioner (and any config) sitting in the new /root.
  rm -rf "$MOUNT/root/provision"
}

# ====================================================================
# PHASE: system   (RE-RUNNABLE — idempotent, runs inside the chroot
# on first build, or on the live box thereafter. Touches no disks.)
# ====================================================================
phase_system() {
  log "locale / time / hostname"
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  hwclock --systohc || true
  sed -i "s/^#\s*\(${LOCALE}\)/\1/" /etc/locale.gen
  locale-gen
  echo "LANG=$LOCALE"   > /etc/locale.conf
  echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
  [[ "$(cat /etc/hostname 2>/dev/null)" == "$HOSTNAME" ]] || echo "$HOSTNAME" > /etc/hostname

  log "initramfs (btrfs needs no extra hooks, but regenerate to be sure)"
  mkinitcpio -P

  log "packages"
  pkg_install

  log "user"
  ensure_user "$USERNAME" "$USER_UID" "$USER_GROUPS"
  set_password root        "$ROOT_PASSWD_HASH"
  set_password "$USERNAME" "$USER_PASSWD_HASH"

  log "services"
  for s in "${SERVICES[@]}"; do ensure_service "$s"; done

  log "bootloader"
  install_systemd_boot

  log "aur (STUB)"
  # bootstrap paru/yay once, then install "${AUR[@]}" guarded by `pacman -Qq`

  log "dotfiles — config is disposable, git owns it (STUB)"
  # [[ -d "$DOTFILES_DIR" ]] || git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
  # stow -d "$DOTFILES_DIR" -t "/home/$USERNAME" <packages>

  log "system phase complete"
}

# systemd-boot. Deliberately dumb: it does NOT autodetect kernels, so the
# loader entry is hand-written. The two failure modes that produce a dead
# prompt are (1) wrong root identity, (2) missing initramfs line — both
# guarded against below by deriving the PARTUUID live and asserting it.
install_systemd_boot() {
  local root_dev partuuid
  # The device backing / right now (resolves the @ subvol mount to its node).
  root_dev="$(findmnt -no SOURCE / | sed 's/\[.*\]//')"   # strip [/@] subvol suffix
  partuuid="$(blkid -s PARTUUID -o value "$root_dev")"
  [[ -n "$partuuid" ]] || die "could not derive PARTUUID for $root_dev — refusing to write a boot entry that won't boot."

  bootctl install

  cat > /boot/loader/loader.conf <<EOF
default arch.conf
timeout 3
console-mode max
editor no
EOF

  cat > /boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-${KERNEL}
initrd  /initramfs-${KERNEL}.img
options root=PARTUUID=${partuuid} rootflags=subvol=@ rw
EOF

  # Assert the entry references an initramfs that actually exists.
  [[ -e "/boot/initramfs-${KERNEL}.img" ]] \
    || warn "initramfs-${KERNEL}.img missing in /boot — entry will not boot until mkinitcpio has run."
  log "systemd-boot installed; root=PARTUUID=${partuuid} subvol=@"
}

# ====================================================================
case "${1:-}" in
  disk)   phase_disk   ;;
  system) phase_system ;;
  *) die "usage: $0 {disk|system}" ;;
esac
