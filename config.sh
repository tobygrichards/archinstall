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

# --- Packages (Model A: this list is the source of truth) -----------
PACKAGES=(
  base base-devel linux linux-firmware
  btrfs-progs
  networkmanager
  sudo git stow fish
  # ... your daily set goes here
)

AUR=(
  # davinci-resolve
)

# --- Services to enable ---------------------------------------------
SERVICES=(
  NetworkManager
)

# --- Dotfiles (config is disposable — git owns it, not @home) -------
DOTFILES_REPO=""           # e.g. https://github.com/you/dotfiles
DOTFILES_DIR="/home/${USERNAME}/.dotfiles"
