# Test runbook — archinstall provisioner

Quick reference for a rebuild test cycle. Two environments are involved and
they are easy to confuse:

- **Live ISO** (`root@archiso`): throwaway. Used only to RUN the installer.
- **Installed system** (`toby@archbox`): the real box the installer built.

`/data` only contains your files when viewed from the INSTALLED system (fstab
mounts `@data` there). From the live ISO, `/data` is an empty directory on the
ISO — so never judge data survival from the ISO.

The desktop + daily packages + AUR builds make this a LONG run now. Slow is not
stuck — Plasma is a big download and yay/Zen are compiled/fetched.

---

## 1. Boot the ISO

If the VM keeps booting the disk instead of the ISO:
- Power on and immediately press **Esc** (or F2/F12) to reach the OVMF firmware
  menu -> **Boot Manager** -> pick the CD/DVD (ISO) entry.
- Or fully shut down and untick/detach the disk so the ISO is the only option.

Tip: snapshot the VM at the blank-disk state so fresh-build tests reset in
seconds instead of rebuilding the VM by hand.

## 2. From the live ISO (`root@archiso`)

```sh
timedatectl set-ntp true
ping -c1 archlinux.org
pacman -Sy --needed --noconfirm git
git clone https://github.com/tobygrichards/archinstall.git /root/prov
cd /root/prov && chmod +x *.sh
./provision.sh disk
```

At the prompts:
- Pick the disk (or `TARGET_DISK=/dev/sda ./provision.sh disk` to skip the picker).
- **Watch the detection line.** On a populated disk it MUST say
  `disk state: rebuild`. If it says `fresh` on a disk that holds your data,
  Ctrl-C at the confirm prompt and stop — that is the dangerous misfire.
- Type the disk path back to confirm (e.g. `/dev/sda`).
- Enter root + user passwords when prompted (silently).

Profiles:
- Default is the VM profile (adds spice-vdagent for auto-resize).
- For the real machine later: `PROFILE=metal ./provision.sh disk`.

## 3. What to watch during the run (the NEW stuff)

In rough order:
- `destroying nested subvol @/...` before `destroying subvol @`  (rebuild only)
- `enabling [multilib] repo`  then packages resolve incl. steam
- pacstrap installs the minimal BASE set; full set installs later in chroot
- `bootstrapping yay` -> git clone -> build  (first real AUR test)
- Zen installing via yay
- `system phase complete`

Looks-like-a-failure-but-isn't:
- Steam installs but games won't run — no real GPU in the VM.
- Zen may have streaming-DRM quirks — it's a Firefox fork, not a build fault.
- Resolve is deliberately commented out; it should not try to install.

## 4. Boot the installed system

Shut down, detach the ISO (or set disk first in boot order), power on.
Expect the **SDDM Breeze greeter**, then log in as toby to Plasma (Wayland).

## 5. Post-boot checks (run as toby on the INSTALLED system)

```sh
cat /data/MARKER          # data survival (must show the line you wrote)
ls /etc/sudoers.d/        # must NOT list 99-aur-build (temp AUR grant revoked)
which zen-browser         # AUR bootstrap + install worked
echo $SHELL               # -> /bin/bash
sudo whoami               # -> root (password-required sudo still works)
mount | grep -E 'on /data|Videos|Downloads'   # @data mounted + binds on top
```

The `ls /etc/sudoers.d/` check is the important NEW one: it confirms the
temporary passwordless-sudo grant used during the AUR build was removed and
did NOT leak onto the booted system. If `99-aur-build` is present, that's a
real finding — stop and report it.

Optional bind-mount proof:
```sh
touch ~/Videos/test.txt && ls -l /data/Videos/   # write to home, see it on @data
```

## 6. Write a fresh marker (do this BEFORE the next rebuild, as toby)

```sh
echo "survived $(date)" | sudo tee /data/MARKER
cat /data/MARKER          # confirm it is actually there before rebooting
```

---

## If the graphical login does NOT appear

Get to a text console with **Ctrl-Alt-F2**, log in as toby, then:

```sh
journalctl -b -u sddm --no-pager | tail -40
```

- Greeter-can't-start (layer-shell / Wayland errors) -> config/package issue.
- GPU/DRM/rendering errors -> VM needs virtio-GPU with 3D acceleration (virgl)
  enabled; this is a VM limitation, not a spec bug.

## If the resolution is wrong / fixed small

The VM profile installs spice-vdagent for auto-resize. If it didn't take:
```sh
systemctl status spice-vdagentd
kscreen-doctor -o                                   # list available modes
kscreen-doctor output.Virtual-1.mode.1920x1080@60   # set one manually
```

## If the AUR build failed

```sh
command -v yay                 # is the helper even present?
ls /etc/sudoers.d/             # 99-aur-build should be GONE post-build
```
A vanished/broken AUR package is skipped-and-warned on a rebuild (not fatal);
on a fresh build a bad OFFICIAL package name aborts. Check the run log for
`aur: '<pkg>' failed` or `these package names no longer resolve` lines.

---

## Inspecting @data from the live ISO (without booting the system)

If you want to check the marker without a full boot, from `root@archiso`:

```sh
mount -o subvol=@data /dev/sda2 /mnt
cat /mnt/MARKER
umount /mnt
```

---

## Backup round-trip test (do this BEFORE trusting backup.sh)

A backup you have never restored from is a hope, not a backup. The LUKS layer
adds a second thing that must round-trip, so test the full cycle on a SCRATCH
drive first — never your only copy of anything.

1. **Init a scratch drive** (erases it):
   ```sh
   lsblk                                  # identify the external drive, e.g. /dev/sdb
   sudo ./backup.sh init /dev/sdb         # type the path to confirm; set a passphrase
   ```
   Store the passphrase somewhere safe that is NOT this machine.

2. **Put a known marker in /data, then back up:**
   ```sh
   echo "backup-test $(date)" | sudo tee /data/BACKUP-MARKER
   sudo ./backup.sh backup --dry-run      # preview first
   sudo ./backup.sh backup                # real run; enter passphrase
   ```

3. **Restore to a SCRATCH location and diff** (don't overwrite the real /data):
   Temporarily point restore at an empty dir by editing `SOURCE=/data` in
   backup.sh to e.g. `SOURCE=/tmp/restore-test`, then:
   ```sh
   sudo mkdir -p /tmp/restore-test
   sudo ./backup.sh restore               # enter passphrase
   sudo diff -r /data /tmp/restore-test    # expect: no differences (bar excludes)
   cat /tmp/restore-test/BACKUP-MARKER     # the marker should be present
   ```
   Then restore the real `SOURCE=/data` line in backup.sh.

4. **Confirm the drive locks itself.** After any run, the drive should be
   unmounted and re-locked (no `/dev/mapper/backupcrypt`, nothing at the mount
   point). Check:
   ```sh
   ls /dev/mapper/ | grep backupcrypt && echo "STILL UNLOCKED - investigate" || echo "locked (correct)"
   ```

Only once the diff is clean and the round trip works should you trust it with
real footage. After that, routine use is just: plug in, `sudo ./backup.sh
backup`, enter passphrase, unplug.
