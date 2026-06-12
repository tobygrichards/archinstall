#!/usr/bin/env bash
# bootstrap.sh — the ONE command you run from a stock Arch ISO.
#
#   1. Boot the official Arch ISO (VM: point at the .iso; metal: dd to USB).
#   2. Get online:  wired is automatic; wifi -> `iwctl` then station scan/connect.
#   3. curl -sL <raw-url>/bootstrap.sh | bash      (or clone the repo and run it)
#
# It clones the repo and hands straight off to `provision.sh disk`, which
# detects fresh-vs-rebuild itself. This script does no disk work of its own.

set -euo pipefail

REPO="${REPO:-https://github.com/you/your-provisioner}"   # override: REPO=... bash bootstrap.sh
DEST="${DEST:-/root/provisioner}"

log() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

# --- sanity: are we actually on the live ISO? -----------------------
[[ -d /run/archiso ]] || die "this doesn't look like the Arch live ISO — refusing."

# --- network check (don't proceed blind) ----------------------------
log "checking connectivity"
ping -c1 -W3 archlinux.org &>/dev/null \
  || die "no network. Wired should be automatic; for wifi use iwctl, then re-run."

# --- clock, else pacstrap key checks get cranky ---------------------
timedatectl set-ntp true || true

# --- fetch the provisioner ------------------------------------------
log "cloning $REPO -> $DEST"
pacman -Sy --needed --noconfirm git
rm -rf "$DEST"
git clone --depth=1 "$REPO" "$DEST"

# --- hand off -------------------------------------------------------
log "handing off to provision.sh disk"
chmod +x "$DEST"/*.sh
"$DEST/provision.sh" disk

log "bootstrap complete — reboot and remove the install media."
