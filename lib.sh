#!/usr/bin/env bash
# lib.sh — the mechanism. Idempotent helpers and the GUARDED destructive
# primitives. Sourced by provision.sh; never run on its own.

# --- Logging --------------------------------------------------------
log()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

# Register the EFI NVRAM boot entry on FIRST REAL BOOT — the one task that
# CANNOT happen during the build, because a chroot has no firmware context to
# write EFI variables (hence the build-time "skipping EFI variable
# modifications"). Without it the system boots via the fallback path
# (/boot/EFI/BOOT/BOOTX64.EFI), which works in VMs and on forgiving firmware
# but can fail on some real motherboards. So we install a one-shot service
# that runs `bootctl install` once on first boot (where NVRAM IS writable),
# then disables itself. FAIL-SAFE: if it errors it logs and exits 0 — the
# fallback path still boots, so a failed registration is a non-event, never a
# wedged boot. Reinstalled fresh on every rebuild (since @ is wiped), so it
# re-registers after each build — intended.
configure_efi_firstboot() {
  install -d /usr/local/sbin
  cat > /usr/local/sbin/register-efi-entry <<'SCRIPT'
#!/usr/bin/env bash
# One-shot: register the systemd-boot EFI entry now that we're booted under
# real firmware. Fail-safe — never block boot.
set +e
if [[ -d /sys/firmware/efi/efivars ]]; then
    bootctl install && echo "register-efi-entry: EFI entry registered."
else
    echo "register-efi-entry: no efivars (not EFI / no NVRAM access) — leaving fallback path in place."
fi
# disable self regardless of outcome, so it only ever runs once per build
systemctl disable register-efi-entry.service 2>/dev/null
exit 0
SCRIPT
  chmod 0755 /usr/local/sbin/register-efi-entry

  cat > /etc/systemd/system/register-efi-entry.service <<'UNIT'
[Unit]
Description=Register systemd-boot EFI entry on first boot
# needs the ESP mounted; runs late, after local filesystems
After=local-fs.target
ConditionPathExists=/sys/firmware/efi

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/register-efi-entry
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
UNIT

  systemctl enable register-efi-entry.service &>/dev/null
  log "EFI first-boot registration service installed (runs once on real boot)"
}

# --- Idempotency guards (the entire "re-runnable" tax) --------------
# Enable the [multilib] repo (32-bit packages, needed by Steam). The stock
# pacman.conf ships it commented out as a 2-line block. Uncomment both lines
# idempotently. Must run BEFORE pkg_install if any 32-bit package is wanted.
enable_multilib() {
  grep -qE '^\[multilib\]' /etc/pacman.conf && { log "multilib already enabled"; return 0; }
  log "enabling [multilib] repo"
  # uncomment the [multilib] header and the Include line that follows it
  sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
  grep -qE '^\[multilib\]' /etc/pacman.conf || warn "multilib enable may have failed — check /etc/pacman.conf"
}

# Packages: --needed already skips what's installed. But pacman fails the
# WHOLE transaction if any one name doesn't resolve (renamed/removed). So we
# validate names first, report the bad ones clearly, and act per build mode:
#   fresh   -> abort (don't leave a half-built system silently missing things)
#   rebuild -> skip the bad ones, install the rest, warn (a working machine
#              missing one app beats no machine because one name drifted)
# mode is passed in ($1); defaults to "rebuild" (the safer-to-continue case).
pkg_install() {
  local mode="${1:-rebuild}"
  (( ${#PACKAGES[@]} )) || return 0

  # refresh the sync db once so resolution checks are against current names
  pacman -Sy --noconfirm &>/dev/null || warn "pacman -Sy failed; resolution checks may be stale"

  local good=() bad=() p
  for p in "${PACKAGES[@]}"; do
    # resolves if it's a real package OR something 'provides' it
    if pacman -Sp "$p" &>/dev/null; then
      good+=("$p")
    else
      bad+=("$p")
    fi
  done

  if (( ${#bad[@]} )); then
    warn "these package names no longer resolve: ${bad[*]}"
    if [[ "$mode" == fresh ]]; then
      die "aborting fresh build — fix the names in config.sh and re-run.
           (A first build shouldn't silently omit packages.)"
    fi
    warn "rebuild: skipping the unresolved names and continuing."
  fi

  (( ${#good[@]} )) || { warn "no resolvable packages to install"; return 0; }
  pacman -S --needed --noconfirm "${good[@]}"
}

# --- AUR -------------------------------------------------------------
# makepkg REFUSES to run as root (it executes arbitrary AUR build scripts).
# The provisioner runs as root, so every AUR action drops to $user via
# `sudo -u`. Requires: the user exists, base-devel + git are installed, and
# the user has working sudo (configure_sudo has run). Call AFTER those.
#
# THE SUDO WRINKLE: makepkg internally calls `sudo pacman` to install build
# deps and the finished package. With password-required sudo (our default),
# that prompt would HANG an unattended build. So we grant a NARROW, TEMPORARY
# passwordless rule (pacman only, this user only) for the build window, and
# remove it via trap so it's gone even if the build fails. Daily password-
# required sudo is untouched.
_aur_sudo_grant="/etc/sudoers.d/99-aur-build"
aur_grant_temp_sudo() {
  local user="$1"
  printf '%s ALL=(root) NOPASSWD: /usr/bin/pacman\n' "$user" > "$_aur_sudo_grant"
  chmod 0440 "$_aur_sudo_grant"
  visudo -cf "$_aur_sudo_grant" &>/dev/null || { rm -f "$_aur_sudo_grant"; die "temp AUR sudo grant failed validation"; }
}
aur_revoke_temp_sudo() { rm -f "$_aur_sudo_grant"; }

# Bootstrap the AUR helper itself. yay comes FROM the AUR, so the first
# install is a manual git-clone + makepkg as the user. Idempotent: if yay is
# already present, do nothing (so rebuilds skip the dance).
ensure_aur_helper() {
  local user="$1"
  command -v yay &>/dev/null && { log "yay present — skip bootstrap"; return 0; }
  log "bootstrapping yay (as $user)"
  local tmp="/tmp/yay-bootstrap"
  rm -rf "$tmp"
  sudo -u "$user" git clone --depth=1 https://aur.archlinux.org/yay-bin.git "$tmp" \
    || { warn "yay clone failed — AUR packages will be skipped"; return 1; }
  ( cd "$tmp" && sudo -u "$user" makepkg -si --noconfirm ) \
    || { warn "yay build failed — AUR packages will be skipped"; return 1; }
  rm -rf "$tmp"
  command -v yay &>/dev/null
}

# Install the AUR list as the user. Same resilience policy as pkg_install:
# AUR names drift/vanish MORE than repo names (maintainers orphan or delete
# packages), so a bad name warns and is skipped, never aborts a build.
# --needed makes it idempotent; yay skips already-installed packages.
aur_install() {
  local user="$1"
  (( ${#AUR[@]} )) || return 0
  command -v yay &>/dev/null || { warn "no yay — skipping all AUR packages"; return 0; }

  local p
  for p in "${AUR[@]}"; do
    if sudo -u "$user" yay -S --needed --noconfirm "$p"; then
      log "  aur: $p ok"
    else
      warn "  aur: '$p' failed (renamed/removed/build error) — skipping"
    fi
  done
}

ensure_service() {
  local unit="$1"
  systemctl is-enabled --quiet "$unit" 2>/dev/null && return 0
  log "enabling $unit"
  systemctl enable "$unit"
}

ensure_user() {
  local name="$1" uid="$2" groups="$3" shell="$4"
  if id -u "$name" &>/dev/null; then
    log "user $name exists — skip"
    return 0
  fi
  log "creating user $name (uid $uid, shell $shell)"
  useradd -m -u "$uid" -G "$groups" -s "$shell" "$name"
}

# Grant the wheel group sudo via a drop-in (never edit /etc/sudoers directly —
# a syntax error there can lock you out). Validate with `visudo -c` BEFORE the
# file is trusted; if it doesn't parse, remove it and fail loudly rather than
# ship a broken sudoers. Idempotent: rewrites the same drop-in each run.
configure_sudo() {
  local nopasswd="${1:-0}" line file="/etc/sudoers.d/10-wheel"
  if [[ "$nopasswd" == 1 ]]; then
    line='%wheel ALL=(ALL:ALL) NOPASSWD: ALL'
  else
    line='%wheel ALL=(ALL:ALL) ALL'
  fi
  printf '%s\n' "$line" > "$file"
  chmod 0440 "$file"
  if ! visudo -cf "$file" &>/dev/null; then
    rm -f "$file"
    die "sudoers drop-in failed validation — removed it rather than risk lockout."
  fi
  log "sudo configured for wheel (nopasswd=$nopasswd)"
}

# Configure SDDM for a Wayland-only system. The default greeter is X11
# (DisplayServer=x11) — on a box with no Xorg installed that produces a
# greeter that can't start, i.e. a black screen at boot. So we MUST set the
# Wayland greeter explicitly. KWin is the compositor; layer-shell-qt (in
# PACKAGES) is required for the themed Qt6 greeter. Theme set separately.
configure_sddm() {
  local theme="${1:-}"
  install -d /etc/sddm.conf.d
  cat > /etc/sddm.conf.d/10-wayland.conf <<'EOF'
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
EOF
  if [[ -n "$theme" ]]; then
    cat > /etc/sddm.conf.d/20-theme.conf <<EOF
[Theme]
Current=${theme}
EOF
    log "SDDM: Wayland greeter, theme '$theme'"
  else
    warn "SDDM: Wayland greeter set, but no theme — embedded fallback will look dated."
  fi
}

# Wire @data into the user's home via bind mounts, so apps save to their
# normal home locations and the files transparently live on @data (surviving
# rebuilds). Runs in the chroot: / is the installed system, @data is at /data,
# home at /home/$user. Writes to the INSTALLED fstab so the mounts persist on
# real boots — not just during the build.
#
# Order matters: create the @data source AND the home mountpoint, set
# ownership, THEN record the bind. Deep paths (the Resolve db) get their
# parents made first, or the mount fails silently and the app starts fresh.
configure_data_binds() {
  local user="$1" uid="$2"; shift 2
  local data=/data home="/home/$user"
  local gid; gid="$(id -g "$uid" 2>/dev/null || echo "$uid")"

  local entry src rel srcpath dstpath
  for entry in "$@"; do
    src="${entry%%|*}"            # subdir inside @data
    rel="${entry##*|}"            # path relative to home
    srcpath="$data/$src"
    dstpath="$home/$rel"

    # source on @data: create once, persists across builds; own it as the user
    install -d -o "$uid" -g "$gid" "$srcpath"

    # mountpoint in (freshly-wiped) home: parents too, for deep paths
    install -d -o "$uid" -g "$gid" "$dstpath"

    # idempotent fstab entry (don't duplicate on re-run)
    if ! grep -qsF " $dstpath " /etc/fstab; then
      printf '%s %s none bind 0 0\n' "$srcpath" "$dstpath" >> /etc/fstab
      log "  bind $srcpath -> $dstpath"
    fi
  done
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
  btrfs subvolume show "$mnt/$sv" &>/dev/null || return 0

  # A populated @ accumulates NESTED subvolumes (pacstrap/systemd create
  # e.g. var/lib/portables, var/lib/machines). btrfs refuses to delete a
  # parent while children exist, so delete children DEEPEST-FIRST. We scope
  # strictly to paths under "$sv/" so this can never wander into @data.
  local child
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    log "  destroying nested subvol $child"
    btrfs subvolume delete "$mnt/$child"
  done < <(
    btrfs subvolume list -o "$mnt/$sv" 2>/dev/null \
      | awk '{print $NF}' \
      | grep -E "^${sv}/" \
      | awk '{print length, $0}' | sort -rn | cut -d" " -f2-
  )

  log "destroying subvol $sv"
  btrfs subvolume delete "$mnt/$sv"
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
