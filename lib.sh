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

# Prompt for a password (twice, silently) and emit ONLY its hash on stdout.
# Prompts and messages go to stderr so command substitution captures the
# hash alone. Blank or mismatched => non-zero, caller decides what to do.
# Nothing is echoed, logged, or written to disk — the plaintext never leaves
# this function, and only the $6$ hash is ever forwarded onward.
prompt_password() {
  local who="$1" p1 p2
  read -rsp "Password for ${who} (blank to skip): " p1; echo >&2
  [[ -z "$p1" ]] && { warn "no password set for $who"; return 1; }
  read -rsp "Confirm ${who} password: " p2; echo >&2
  [[ "$p1" == "$p2" ]] || { warn "passwords did not match for $who"; return 1; }
  openssl passwd -6 "$p1"
}

# Apply a PRE-HASHED password. Empty hash => leave the account as-is
# (root therefore stays locked, which is the safe default). Idempotent:
# re-applying the same hash is a no-op in effect.
#
# SECURITY NOTE — read before committing a hash:
#   A $6$ SHA-512 crypt hash is NOT plaintext, but it IS crackable offline
#   by anyone who gets the file. If this repo is public, a committed hash is
#   a weak password away from being someone's root. Prefer the runtime env
#   override (ROOT_PASSWD_HASH=... ./provision.sh disk) or a .gitignored
#   local secrets file. The committed default stays empty for this reason.
set_password() {
  local who="$1" hash="$2"
  [[ -n "$hash" ]] || { warn "no password hash for '$who' — leaving account unchanged"; return 0; }
  id -u "$who" &>/dev/null || { warn "user '$who' does not exist — cannot set password"; return 0; }
  printf '%s:%s\n' "$who" "$hash" | chpasswd -e
  log "password set for $who"
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

# Partition node naming differs by device class: nvme/mmc/loop use pN,
# sd/vd use N. One helper so the picker and provision.sh never disagree.
part_node() {
  local disk="$1" num="$2"
  if [[ "$disk" =~ (nvme|mmcblk|loop) ]]; then
    echo "${disk}p${num}"
  else
    echo "${disk}${num}"
  fi
}

# --- Disk target validation -----------------------------------------
# Resolution order: runtime/env value -> interactive picker (if at a tty)
# -> refuse. We never silently default to a path.
require_disk() {
  if [[ -z "${TARGET_DISK:-}" ]]; then
    if [[ -t 0 ]]; then
      pick_disk
    else
      die "TARGET_DISK is empty and no terminal to pick from.
           Pass it at runtime, e.g.  TARGET_DISK=/dev/nvme0n1 ./provision.sh disk"
    fi
  fi
  [[ -b "$TARGET_DISK" ]] || die "TARGET_DISK ($TARGET_DISK) is not a block device."
}

# Probe whole disks (not partitions) and let the user choose. Each option
# is annotated with what's on it — including whether it already carries
# @data — so the data drive is obvious and hard to pick by mistake.
pick_disk() {
  mapfile -t disks < <(lsblk -dpn -o NAME,TYPE | awk '$2=="disk"{print $1}')
  (( ${#disks[@]} )) || die "no disks found by lsblk."

  warn "Select the TARGET disk. This is the one that gets partitioned/wiped."
  echo
  local i=1 line size model state flag
  for d in "${disks[@]}"; do
    size="$(lsblk -dn -o SIZE "$d")"
    model="$(lsblk -dn -o MODEL "$d" | xargs)"
    # annotate with detected state so a data-bearing disk stands out
    state="$(detect_disk_state "$(part_node "$d" 2)" 2>/dev/null || echo unknown)"
    case "$state" in
      rebuild)   flag="*** HAS @data — your data lives here ***" ;;
      fresh)     flag="(blank / no btrfs)" ;;
      ambiguous) flag="(existing btrfs, no @data — foreign?)" ;;
      *)         flag="" ;;
    esac
    printf "  %d) %-14s %6s  %-20s %s\n" "$i" "$d" "$size" "${model:-?}" "$flag"
    ((i++))
  done
  echo
  read -rp "Number (or q to abort): " choice
  [[ "$choice" == q ]] && die "aborted."
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#disks[@]} )) \
    || die "invalid selection."
  TARGET_DISK="${disks[choice-1]}"
  log "selected $TARGET_DISK"
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
