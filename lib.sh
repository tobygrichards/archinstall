#!/usr/bin/env bash
# lib.sh — the mechanism. Idempotent helpers and the GUARDED destructive
# primitives. Sourced by provision.sh; never run on its own.

# --- Logging --------------------------------------------------------
log()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

# --- Idempotency guards (the entire "re-runnable" tax) --------------
# Packages: --needed already skips what's installed. Nothing more needed.
pkg_install() {
  (( ${#PACKAGES[@]} )) || return 0
  pacman -S --needed --noconfirm "${PACKAGES[@]}"
}

ensure_service() {
  local unit="$1"
  systemctl is-enabled --quiet "$unit" 2>/dev/null && return 0
  log "enabling $unit"
  systemctl enable "$unit"
}

ensure_user() {
  local name="$1" uid="$2" groups="$3"
  if id -u "$name" &>/dev/null; then
    log "user $name exists — skip"
    return 0
  fi
  log "creating user $name (uid $uid)"
  useradd -m -u "$uid" -G "$groups" -s /usr/bin/fish "$name"
}

# --- Destructive primitives — GUARDED -------------------------------
# This is the guard we agreed to write BEFORE the feature. destroy_subvol
# refuses anything not explicitly allowlisted, and refuses a KEEP subvol
# unconditionally — even if a caller passes it by mistake.
destroy_subvol() {
  local mnt="$1" sv="$2"
  [[ " ${KEEP_SUBVOLS[*]} " == *" $sv "* ]] && die "refusing to destroy protected subvol: $sv"
  [[ " ${WIPE_SUBVOLS[*]} " == *" $sv "* ]] || die "refusing to destroy non-allowlisted subvol: $sv"
  if btrfs subvolume show "$mnt/$sv" &>/dev/null; then
    log "destroying subvol $sv"
    btrfs subvolume delete "$mnt/$sv"
  fi
}

ensure_subvol() {
  local mnt="$1" sv="$2"
  btrfs subvolume show "$mnt/$sv" &>/dev/null && return 0
  log "creating subvol $sv"
  btrfs subvolume create "$mnt/$sv"
}

# --- Disk target validation -----------------------------------------
require_disk() {
  [[ -n "${TARGET_DISK:-}" ]] || die "TARGET_DISK is empty. Set it in config.sh — never guessed."
  [[ -b "$TARGET_DISK" ]]     || die "TARGET_DISK ($TARGET_DISK) is not a block device."
}

# --- Disk state detection (the most dangerous decision in the project) ---
# Three states, not two:
#   fresh      — no btrfs / no @data. Safe to mkfs.
#   rebuild    — btrfs present AND @data present. MUST NOT mkfs.
#   ambiguous  — btrfs present but @data missing (half-finished first build,
#                foreign disk, etc). REFUSE. We never guess towards mkfs.
#
# Echoes one of: fresh | rebuild | ambiguous
detect_disk_state() {
  local root="$1"            # the btrfs partition, e.g. /dev/vda2
  # No btrfs signature at all -> genuinely fresh.
  if ! blkid -t TYPE=btrfs "$root" &>/dev/null; then
    echo fresh; return
  fi
  # btrfs exists — is @data on it? Probe by mounting top-level read-only.
  local probe; probe="$(mktemp -d)"
  if mount -o ro,subvolid=5 "$root" "$probe" &>/dev/null; then
    local found=ambiguous
    btrfs subvolume show "$probe/@data" &>/dev/null && found=rebuild
    umount "$probe"; rmdir "$probe"
    echo "$found"; return
  fi
  rmdir "$probe"
  echo ambiguous            # btrfs claimed but unmountable -> refuse, don't format
}

confirm_wipe() {
  warn "About to WIPE and rebuild the OS on: $TARGET_DISK"
  warn "Destroy : ${WIPE_SUBVOLS[*]}"
  warn "Preserve: ${KEEP_SUBVOLS[*]}"
  lsblk "$TARGET_DISK" || true
  read -rp "Type the disk path exactly to confirm: " ans
  [[ "$ans" == "$TARGET_DISK" ]] || die "mismatch — aborting."
}
