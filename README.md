# archinstall

A declarative, re-runnable provisioner that builds an Arch Linux + KDE Plasma
desktop from a blank disk with a single command — and **rebuilds it cleanly
without touching your data**.

It runs from the official Arch ISO, partitions the disk, lays out btrfs
subvolumes, installs the base system and a full Plasma desktop, configures the
user, sudo, the bootloader and the display manager, and weaves a persistent
data area into the home directory. Run it again later — on the same machine or
a new one — and it rebuilds the OS while leaving your videos, projects and
documents untouched.

> Personal project for a single workstation. Not a general-purpose installer —
> the config describes *my* machine. Fork and edit `config.sh` for yours.

## What it does

- **Partitions and formats** a target disk (UEFI + GPT): a 1 GB ESP and a
  btrfs partition.
- **btrfs subvolumes** instead of fixed partitions:
  - `@` — the OS. **Wiped and rebuilt** on every clean build.
  - `@home` — user config/dotfiles. **Wiped** (config is treated as disposable).
  - `@data` — videos, projects, downloads, documents. **Preserved** across builds.
- **Installs** the base system and a lean KDE Plasma desktop (Wayland only),
  SDDM with the Breeze theme, a daily app set, and AUR packages via yay.
- **Wires `@data` into `$HOME`** with bind mounts, so apps save to their normal
  locations (`~/Videos`, `~/Downloads`, …) and the files transparently persist.
- **Re-runnable**: a second run detects the existing install and rebuilds the
  OS in place, preserving `@data`.
- **Encrypted backup** (`backup.sh`): LUKS-encrypted external-drive backup of
  `@data`, with restore — doubles as transport to a new machine.

## Design decisions

**Subvolumes, not partitions.** The persistence boundary is a subvolume
boundary, so a clean build is "delete and recreate `@`/`@home`, leave `@data`"
— no repartitioning, no fixed sizing, shared free space.

**Config is disposable; data is not (Model A).** Dotfiles and app config live
in `@home` and are rebuilt from a git-managed dotfiles repo (stow). Only `@data`
is precious. This keeps a "clean build" genuinely clean rather than inheriting
old cruft.

**Data vs mechanism.** `config.sh` is the declarative *what* (packages, users,
subvolumes, binds). `provision.sh` + `lib.sh` are the *how*. Editing the spec
never means touching the executor.

**Two separate phases.** `provision.sh disk` is destructive and one-shot;
`provision.sh system` is re-runnable and touches no disks. The wall between
them is the core safety boundary.

## Safety properties

- The destructive phase **detects** whether the disk is blank (`fresh`) or
  already holds an install (`rebuild`) and routes accordingly. If it can't tell
  confidently, it **refuses** rather than guessing — it never formats when unsure.
- `mkfs` lives in exactly one code path (`fresh`); the rebuild path cannot
  reformat.
- Subvolume deletion is **allow-listed**: `@data` can never be destroyed, even
  if passed by mistake.
- Disk target is never assumed — supplied at runtime or chosen from a picker
  that flags which disk holds `@data`.
- The AUR build's temporary passwordless-sudo grant is **always revoked** before
  the system boots (it never leaks onto the installed machine).

## Usage

From a booted, networked official Arch ISO:

```sh
pacman -Sy --needed --noconfirm git
git clone https://github.com/tobygrichards/archinstall.git /root/prov
cd /root/prov && chmod +x *.sh
./provision.sh disk
```

You'll choose the target disk (or pass `TARGET_DISK=/dev/sdX`), confirm the
wipe, and set passwords (prompted, or supplied as hashes via env).

Profiles:

```sh
./provision.sh disk                 # VM profile (default; adds guest tooling)
PROFILE=metal ./provision.sh disk   # real hardware
```

Edit `config.sh` to change the package set, users, subvolume layout, data
binds, or SDDM theme. Names that no longer resolve are reported clearly:
a fresh build aborts on a bad name; a rebuild skips it and continues.

For the VM test cycle (and troubleshooting), see [`TEST-RUNBOOK.md`](TEST-RUNBOOK.md).

### Backup

The backup is a separate script — the provisioner never touches the backup
drive, and the backup never touches the OS disk. The drive is LUKS-encrypted,
so a lost or stolen drive is unreadable without the passphrase.

```sh
sudo ./backup.sh init /dev/sdX     # ONCE per drive: erase + LUKS-encrypt it
sudo ./backup.sh backup            # /data -> drive (accumulates; no deletions propagate)
sudo ./backup.sh restore           # drive -> /data (recovery, or onto a new PC)
```

Add `--dry-run` to `backup`/`restore` to preview without writing. Edit the
config block at the top of `backup.sh` (drive label, excludes, restore UID).

**Before trusting it, prove the round trip** — back up, restore to a scratch
location, and diff against `/data`. A backup you have never restored from is a
hope, not a backup. **Store the LUKS passphrase somewhere safe that is NOT the
machine being backed up** — lose it and the backup is unrecoverable.

## Files

| File | Role |
|------|------|
| `bootstrap.sh` | One-command entry from the live ISO: network check, clone, hand off. |
| `provision.sh` | Orchestration. `disk` (destructive) and `system` (re-runnable) phases. |
| `lib.sh` | Mechanism: idempotent helpers and the guarded destructive primitives. |
| `config.sh` | Declarative spec — the only file you edit to change the machine. |
| `backup.sh` | Encrypted (LUKS) backup/restore of `@data` to an external drive. Separate from the provisioner by design. |
| `TEST-RUNBOOK.md` | Step-by-step VM test procedure and troubleshooting. |

## Status

Built and tested on a VM: the build-and-rebuild spine, desktop, data
persistence (verified `@data` survives a full OS rebuild), package management
and AUR.

Built but not yet verified on real hardware:
- **Backup** (`backup.sh`) — logic complete; needs a real-drive round-trip
  test (init -> backup -> restore -> diff) before it is trusted. This is the
  most important thing to actually test, as a backup is the only protection
  against a dead disk.
- **EFI boot entry** — a first-boot service registers the firmware boot entry
  (the build-time chroot can't). Works via the fallback path meanwhile; the
  registered entry only matters on real firmware, so it is unverified until metal.

Still to do:
- **Dotfiles** — git-managed config (stow) so a rebuild restores *my* desktop
  rather than stock Plasma. Best done after living in the machine long enough
  to have config worth capturing.
