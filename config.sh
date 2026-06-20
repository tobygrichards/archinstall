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

# --- Data binds (the @data persistence wiring) ----------------------
# Maps a folder INSIDE @data  ->  a path in the user's home. Each becomes a
# bind mount in the installed fstab, so apps saving to their normal home
# locations (~/Videos etc.) transparently land on @data and survive rebuilds.
# No per-app configuration is ever needed.
#
# Format: "subdir-in-@data|relative-path-in-home"
# The Resolve entry is special: its DATABASE lives in a hidden config path,
# so it needs its own bind to be preserved (project list/edits/grades).
DATA_BINDS=(
  "Videos|Videos"
  "Downloads|Downloads"
  "Documents|Documents"
  "Projects|Projects"
  ".resolve-db|.local/share/DaVinciResolve"
)

# --- Users ----------------------------------------------------------
# A LIST of users (one for now). Each record is pipe-delimited:
#   "name|uid|groups|shell"
# To add a second user later: append another line with a DISTINCT uid, and
# (if you want their data to persist) extend DATA_BINDS — see note there.
# UIDs must stay stable forever: @data files are owned by uid, not name.
USERS=(
  "toby|1000|wheel,audio,video,storage|/usr/bin/fish"
)

# The "primary" user — the one DATA_BINDS and single-user steps target.
# Derived from the first record so existing logic keeps working unchanged.
PRIMARY_USER="${USERS[0]%%|*}"
_primary_rest="${USERS[0]#*|}"
PRIMARY_UID="${_primary_rest%%|*}"

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

# --- Build profile (vm vs metal) ------------------------------------
# Gates hardware/environment-specific extras. "vm" adds guest tooling
# (e.g. spice-vdagent for auto-resize); "metal" skips it. Override at
# runtime:  PROFILE=metal ./provision.sh disk
PROFILE="${PROFILE:-vm}"

# Extras added per profile (merged into PACKAGES/SERVICES below).
declare -A PROFILE_PACKAGES=(
  [vm]="spice-vdagent"            # SPICE guest agent -> resolution auto-resize
  [metal]=""                      # add metal-only bits here (e.g. nvidia, firmware)
)
declare -A PROFILE_SERVICES=(
  [vm]="spice-vdagentd"           # the agent daemon
  [metal]=""
)

# --- Kernels --------------------------------------------------------
# A LIST of kernel packages. The FIRST is the default boot entry; the rest
# are fallback entries systemd-boot offers at the menu. Each name maps to
# /boot/vmlinuz-<name> + initramfs-<name>.img.
#   linux      -> stock (daily). Best-tested reference kernel.
#   linux-lts  -> fallback. Reboot into this if a rolling update breaks stock.
# The fallback is the real recovery path on a rolling release.
KERNELS=(linux linux-lts)

# Primary kernel — first in the list. Used where a single kernel reference is
# needed (kept for compatibility with anything expecting one name).
KERNEL="${KERNELS[0]}"

# --- Packages (Model A: this list is the source of truth) -----------
# BASE_PACKAGES: the minimum to produce a bootable, chroot-able system.
# pacstrap installs THESE (before multilib is enabled). Everything else is
# installed by pkg_install inside the chroot, AFTER multilib is on — which is
# why Steam (32-bit) must NOT be in the base set.
# Kernels (all of KERNELS) go here so they're present for the bootloader.
BASE_PACKAGES=(
  base base-devel "${KERNELS[@]}" linux-firmware
  btrfs-progs
  networkmanager
  sudo git stow fish
)

# PACKAGES: the full desired set, installed after multilib is enabled.
# (Includes the base set too; --needed makes the overlap a no-op.)
PACKAGES=(
  "${BASE_PACKAGES[@]}"

  # --- KDE Plasma (Wayland-only; X11 session is dropped from 6.8) ---
  plasma-desktop            # lean: NOT the 'plasma' meta (avoids KDE PIM etc.)
  kscreen                   # display config GUI (resolution/arrangement KCM) —
                            # NOT included in plasma-desktop alone
  plasma-nm                 # network applet in the system tray (GUI for NetworkManager)
  sddm                      # login manager (KDE-native, themes cleanly)
  layer-shell-qt            # REQUIRED for the Wayland SDDM greeter (Qt6)
  konsole dolphin           # terminal + file manager
  pipewire pipewire-pulse wireplumber   # audio (you capture audio)

  # --- KDE apps ---
  plasma-systemmonitor      # resource monitor (modern; ksysguard is deprecated)
  kate                      # text editor
  gwenview                  # image viewer (integrates with Dolphin)
  ark p7zip unzip           # archive handling from Dolphin

  # --- daily ---
  vlc                       # video player (watch footage without opening Resolve)
  btop                      # terminal system monitor
  steam                     # needs multilib (enabled before pkg_install)

  # --- fonts (a bare desktop renders poorly / shows tofu without these) ---
  ttf-dejavu ttf-liberation noto-fonts noto-fonts-emoji
)

# SDDM theme. "breeze" is the official KDE theme — clean, modern, dark-capable,
# and survives Plasma updates (unlike third-party/AUR themes). Empty => SDDM's
# dated embedded fallback (the "Windows 2000" look), so don't leave it empty.
SDDM_THEME="breeze"

AUR=(
  zen-browser-bin           # Zen browser (prebuilt; building from source is a long compile)

  # davinci-resolve         # DELIBERATELY manual: the PKGBUILD needs the installer
                            # fetched by hand from Blackmagic (licensing), so it won't
                            # install unattended. Do it by hand after first boot.
)

# --- Services to enable ---------------------------------------------
SERVICES=(
  NetworkManager
  sddm                      # start the graphical login at boot
)

# Merge the selected profile's extras into PACKAGES/SERVICES. word-splitting
# is intentional here (space-separated lists in the maps above).
# shellcheck disable=SC2206
[[ -n "${PROFILE_PACKAGES[$PROFILE]:-}" ]] && PACKAGES+=(${PROFILE_PACKAGES[$PROFILE]})
# shellcheck disable=SC2206
[[ -n "${PROFILE_SERVICES[$PROFILE]:-}" ]] && SERVICES+=(${PROFILE_SERVICES[$PROFILE]})

# --- Dotfiles (config is disposable — git owns it, not @home) -------
# A separate repo, cloned and stowed on every build. This is the other half
# of Model A: @home is wiped, the dotfiles repo restores your config.
# Leave DOTFILES_REPO empty to skip the whole step (e.g. early testing).
DOTFILES_REPO="https://github.com/tobygrichards/dotfiles.git"
DOTFILES_DIR="/home/${PRIMARY_USER}/.dotfiles"

# stow packages to apply (each is a top-level dir in the dotfiles repo).
DOTFILES_PACKAGES=(
  fish
  plasma                    # panel layout (applied once on first login)
)
