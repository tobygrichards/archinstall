#!/usr/bin/env bash
# config.sh — the declarative "what". Data only, no logic.
# This is the file you edit to describe the machine. provision.sh never
# changes; this does. Diff it against `pacman -Qqe` to fold drift back in.

# --- Target machine -------------------------------------------------
HOSTNAME="archbox"
TIMEZONE="Europe/London"
LOCALE="en_GB.UTF-8"
KEYMAP="uk"

# --- Disk (DESTRUCTIVE phase only) ----------------------------------
# Supply at runtime, NOT committed with a path baked in:
#   TARGET_DISK=/dev/nvme0n1 ./provision.sh disk
# The ":-" means a runtime/env value wins; the committed default stays empty
# so a fresh clone never carries a disk path that was right for another machine.
# If left empty and you're at a terminal, the script offers a picker.
TARGET_DISK="${TARGET_DISK:-}"   # never hardcode a path here

# Subvolumes the clean build is ALLOWED to destroy and recreate.
# @data is deliberately NOT here. That absence is the safety boundary.
WIPE_SUBVOLS=(@ @home)

# Subvolumes that persist across a clean build. Never destroyed.
KEEP_SUBVOLS=(@data)

# --- User -----------------------------------------------------------
USERNAME="toby"
USER_UID=1000              # pinned: a persisted home stays correctly owned
USER_GROUPS="wheel,audio,video,storage"
USER_SHELL="/bin/bash"     # login shell. bash = max compatibility with most
                           # Linux instructions. Set to /usr/bin/fish if you
                           # want fish as login shell (ensure it's in PACKAGES).

# --- sudo -----------------------------------------------------------
# Grant the wheel group sudo. Password-required by default — safer on a box
# that holds real work/accounts. Set NOPASSWD=1 for passwordless (convenient,
# but anything running as you can escalate silently).
SUDO_NOPASSWD=0

# --- Passwords (HASHES, never plaintext) ----------------------------
# Three ways, in priority order:
#   1. Supply a hash at runtime (unattended):
#        ROOT_PASSWD_HASH='$6$...' ./provision.sh disk
#      Generate with:  openssl passwd -6   (or  mkpasswd -m sha-512)
#   2. Supply nothing and run at a terminal: you'll be PROMPTED during the
#      build (typed silently, hashed in memory, never stored — preferred).
#   3. Supply nothing, non-interactive: account left untouched (root locked).
# See the security note in lib.sh before you ever commit a real hash.
ROOT_PASSWD_HASH="${ROOT_PASSWD_HASH:-}"
USER_PASSWD_HASH="${USER_PASSWD_HASH:-}"

# --- Kernel (the boot entry's vmlinuz/initramfs names derive from this) ---
# Stock Arch: "linux" -> /boot/vmlinuz-linux + initramfs-linux.img
# CachyOS:    "linux-cachyos" -> vmlinuz-linux-cachyos, etc.
# Keep this in step with whatever kernel is in PACKAGES below.
KERNEL="linux"

# --- Packages (Model A: this list is the source of truth) -----------
PACKAGES=(
  base base-devel linux linux-firmware
  btrfs-progs
  networkmanager
  sudo git stow fish

  # --- KDE Plasma (Wayland-only; X11 session is dropped from 6.8) ---
  plasma-desktop            # lean: NOT the 'plasma' meta (avoids KDE PIM etc.)
  sddm                      # login manager (KDE-native, themes cleanly)
  layer-shell-qt            # REQUIRED for the Wayland SDDM greeter (Qt6)
  konsole dolphin           # terminal + file manager
  pipewire pipewire-pulse wireplumber   # audio (you capture audio)
  # ... your daily set goes here
)

# SDDM theme. "breeze" is the official KDE theme — clean, modern, dark-capable,
# and survives Plasma updates (unlike third-party/AUR themes). Empty => SDDM's
# dated embedded fallback (the "Windows 2000" look), so don't leave it empty.
SDDM_THEME="breeze"

AUR=(
  # davinci-resolve
)

# --- Services to enable ---------------------------------------------
SERVICES=(
  NetworkManager
  sddm                      # start the graphical login at boot
)

# --- Dotfiles (config is disposable — git owns it, not @home) -------
DOTFILES_REPO=""           # e.g. https://github.com/you/dotfiles
DOTFILES_DIR="/home/${USERNAME}/.dotfiles"
