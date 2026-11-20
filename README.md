# Gentoo + Unity 7 on an encrypted ZFS laptop

These scripts install Gentoo Linux with OpenRC (no systemd) on a laptop: the whole disk is one
natively encrypted ZFS pool (AES-256-GCM), unlocked by a single passphrase in ZFSBootMenu at boot
(no key file on the disk: ZFSBootMenu hands the passphrase to the booted system in memory),
with the Unity 7 desktop from the gentoo-unity7 overlay on top (LightDM, PipeWire, Bluetooth,
network printing). Packages come prebuilt from Gentoo's binary host where possible; packages the
Unity overlay patches are always built from source.

Source: <https://github.com/kt97679/gentoo-zfs-laptop> (MIT license, see `LICENSE`).

They were written for, and so far tested only on, a ThinkPad P14s Gen 5 (AMD). Other x86-64 UEFI
laptops should work - CPU level and graphics drivers are detected - but have not been tried.

> **The install erases the disk you pick, completely.** Back up first.

## What is in this folder

| file | what it does |
|---|---|
| `install-gentoo.sh` | the base system, run from the Gentoo live USB: partitions, encrypted pool, stage3, kernel, ZFSBootMenu, your user, services |
| `check-install.sh` | read-only check from the live USB before the first reboot |
| `install-unity.sh` | the desktop, run on the installed system |
| `unity-apps.list` | the applications `install-unity.sh` adds - edit it to taste |
| `deploy`, `deploy.list` | install the system files from `files/` as root-owned copies; both installers use it, and you use it after changing a file |
| `files/` | those system files: update and snapshot tools, battery limits, ZFSBootMenu config, and so on |
| `LICENSE` | the MIT license |
| `PACKED` | in a packed archive only: which version of the scripts this is |

## What it assumes

- **Firmware:** UEFI, with Secure Boot **off** (the ZFSBootMenu image is unsigned).
- **Live USB:** a current Gentoo *Minimal Installation CD* (amd64) from
  <https://www.gentoo.org/downloads/>. It must include ZFS - step 3 checks.
- **Disk:** the internal disk, picked from a menu. Mounted disks are not offered.
- **Network:** wired or Wi-Fi during the whole install. It downloads from Gentoo's mirrors and
  binary host, GitHub (the Unity overlay), the vendors of some listed apps (Chrome, Zoom) and,
  later, ghcr.io (the Tribler image, if you keep it). The install stops at the first failed
  download.
- **Memory:** 4 GB and up; the installer sizes things from the RAM. The ZFS read cache gets a
  quarter of it (1 to 8 GiB), builds one job per 2 GB. From 16 GB: compressed swap in RAM (zram),
  no swap partition. Under 16 GB: a swap partition of twice the RAM (at most 16 GiB) between the
  EFI partition and ZFS, encrypted with a new random key at each boot, with zswap (a compressed
  cache in RAM) in front of it - the install itself swaps there too. `SWAP_GIB` and `ARC_MAX_GIB`
  in the *Settings* block (or the environment) override this; `SWAP_GIB=0` means no partition. On
  4 GB it works but is slow: what is built from source (the desktop, webkit-gtk) takes hours, and a
  browser with many tabs swaps.
- **Time:** roughly 30-60 minutes for the base system and 1-2 hours for the desktop.
- **Known issue - ThinkPad T14/P14s Gen 5 AMD:** on early BIOS versions sleep draws about 7 W
  (the embedded controller wakes the chip every second). BIOS 1.05 had it, 1.23 does not: update
  the firmware (see *Living with it*) if the battery empties overnight in sleep.

## Before you start

1. **Back up** everything on the laptop you want to keep.
2. In the firmware setup, **turn Secure Boot off**.
3. Write the Gentoo minimal ISO to a USB stick (`dd`, Ventoy or similar).
4. Decide on: a **host name**, your **user name**, your **time zone**, a **pool passphrase**
   (8+ characters; you type it at every boot - lose it and the data is gone) and a **user
   password**.
5. Look through `unity-apps.list` and the *Settings* block at the top of `install-gentoo.sh`. You
   can also edit the app list later, right before the desktop install (step 15).
6. Optional but handy: a second computer, so you can run the install over SSH and copy and paste.

## Phase 1 - boot the live system

1. Boot the laptop from the USB stick (use the firmware's boot menu key).
2. Network: wired connects by itself; for Wi-Fi run `net-setup` and pick the wireless interface.
   Check with `ping -c 3 gentoo.org`.
3. Run `zfs version`. It must print a version; if it does not, this ISO has no ZFS - get a
   current one.
4. Get the scripts onto the live system, one of these ways:
   - **From GitHub**, straight onto the live system (it is online already):

         wget -O scripts.tar.gz https://github.com/kt97679/gentoo-zfs-laptop/archive/refs/heads/main.tar.gz

     Logging in from a second computer is still worth it (the next way, without the `scp`): you
     can copy and paste, and `ssh-copy-id` carries your key into the installed system.
   - **From a second computer:** on the laptop run `passwd` (a temporary root password, for SSH
     only), `rc-service sshd start` and `ip -4 addr` (note the address). On the other computer:

         ssh-copy-id root@<address>
         scp gentoo-laptop-share-*.tar.gz root@<address>:
         ssh -t root@<address>

     `ssh-copy-id` matters (no key yet: `ssh-keygen` first): the installed system's SSH takes keys
     only, and the installer gives this key to your account. It also keeps the live system's host
     keys, so after the reboot SSH to the same address shows no "host key changed" warning.

   - **From a second USB stick:** find it with `lsblk`, then
     `mkdir /mnt/usb && mount /dev/<sdX1> /mnt/usb && cp /mnt/usb/gentoo-laptop-share-*.tar.gz ~`.
5. Unpack and enter the folder - the installers refuse to run from anywhere else:

       tar xzf scripts.tar.gz && cd gentoo-zfs-laptop-main            # from GitHub
       tar xzf gentoo-laptop-share-*.tar.gz && cd gentoo-laptop       # a pack

6. If the live system has `tmux` (or `screen`), start it now: a dropped SSH connection then does
   not stop the install (`tmux attach` gets you back).

## Phase 2 - the base system

7. Run the installer:

       bash install-gentoo.sh

   It shows a menu of disks, then asks for the host name, user name and time zone (a menu;
   *Other* lets you type any zone). Next it shows a summary - host, user, time zone, CPU level,
   graphics drivers, the memory plan (swap, ZFS cache, build jobs), disk - check it and type
   `YES`. Then the pool passphrase twice and your user
   password twice. After that it runs on its own and ends with **Done** and a list of next steps.

   You can give the answers up front instead, e.g.
   `HOSTNAME_NEW=mylaptop USERNAME=alice TIMEZONE=Europe/Berlin bash install-gentoo.sh`. Also
   recognised: `DISK=/dev/disk/by-id/...` (skips the menu), `BINHOST_ARCH=x86-64`,
   `VIDEO_CARDS=...` (override the detection), `SWAP_GIB=...` and `ARC_MAX_GIB=...` (override the
   memory plan).

   The log is `/root/install-gentoo.log` (also copied into the new system's `/root`). If something
   went wrong, the lines that matter are:

       grep -an '^FAILED\|^!!!\|ERROR' /root/install-gentoo.log \
           | grep -v 'binary packages have been ignored' | tail

   (Portage's notices that some "binary packages have been ignored" are normal - it built those
   packages itself instead - so the second grep leaves them out.)

8. Recommended - check before rebooting (it changes nothing):

       bash check-install.sh 2>&1 | tee /root/check.txt

   Look for: `runtime failures: 0`; a ZFSBootMenu entry first in the boot order; `initramfs ...
   contains zfs and no pool key`; `ZFSBootMenu hooks in the image: ...` (two); `no key file`;
   `keylocation prompt` and `gentoo-laptop:key-injection on`; `SSH: keys only; 1 key(s) ...` and
   `SSH: sshd's settings checked`; `N files, all as deployed`; sanoid
   installed. If it prints
   **No ZFSBootMenu entry yet - do NOT reboot**, don't: something failed - see the log.
9. `reboot`, and remove the USB stick.

To start the base install over, run `install-gentoo.sh` again; if the pool is still imported,
`zpool export gentoo` first.

## Phase 3 - first boot (text console)

10. ZFSBootMenu asks for the pool passphrase, once (`Enter passphrase for 'gentoo' (key
    injection):`), and boots. If the firmware shows its own setup
    screen or boot menu instead, pick the internal disk; once logged in, `sudo efibootmgr` lists
    the entries and `sudo efibootmgr -o <ZFSBootMenu's number>,<the others>` puts ZFSBootMenu
    first.
11. Log in as your user. Root has no password (locked); you administer with `sudo`.
12. Wi-Fi: `sudo nmtui`. Wired works by itself.
13. Thunderbolt dock, if you have one: `boltctl list`. If it shows as not stored, run
    `sudo boltctl enroll --policy auto <uuid>`.
14. Take a snapshot to come back to: `sudo zfs snapshot -r gentoo@base-install`.

## Phase 4 - the desktop

15. The installer left a copy of this folder in your home: `cd ~/gentoo-laptop`. Edit
    `unity-apps.list` now if you want different applications: one or more package names
    (`category/name`, see <https://packages.gentoo.org>) per line, `#` starts a comment;
    misspelled or unavailable entries are skipped with a warning.
16. Install the desktop (1-2 hours; it is safe to run again if it gets interrupted):

        sudo bash install-unity.sh

    Log: `/root/install-unity.log`; failing lines as in step 7.
17. At the end it lists packages that are no longer needed. If the list is not empty and looks
    right: `sudo emerge --depclean`.
18. `sudo reboot` - you get the Unity login screen.

## Phase 5 - one-time setup in the desktop

19. **Printer** (network printer, no driver needed): Settings -> Printers may find it by itself.
    The way that is known to work:

        getent ahostsv4 <printer-name>.local        # must print an address
        sudo lpadmin -p MyPrinter -E -v ipps://<printer-name>.local:631/ipp/print -m everywhere

    then print a test page from Settings -> Printers.
20. **Flameshot** (if you kept it): Settings -> Keyboard -> Shortcuts - disable the three
    Screenshot entries, then add a custom shortcut `flameshot gui` on the Print key.
21. **GNOME Text Editor:** Preferences -> turn **Restore session** on. The editor is patched to
    quit without asking about unsaved documents; with this setting on, their text is kept as
    drafts and comes back next time.
22. **Tribler** (if `podman` is in your app list): the panel indicator -> Start (the first start
    downloads the image: a few minutes) -> Open. To update it: Stop -> Update Tribler image ->
    Start; your settings and downloads stay.
23. **Brave** (optional): in `~/gentoo-laptop` run `sudo ./deploy --group brave`, then
    `sudo world-update`. It asks you to confirm Brave's signing key: compare the fingerprints with
    <https://brave.com/signing-keys/> before you say yes.
24. **EiskaltDC++** (optional; the Qt 6 fork, as Gentoo has no EiskaltDC++ any more): in
    `~/gentoo-laptop` run `sudo ./deploy --group eiskaltdcpp`, then `sudo world-update` - it writes
    the package and builds it. Releases only by default; for previews put
    `EISKALTDCPP_CHANNEL=pre` in `/etc/world-update.d/60-eiskaltdcpp.conf`. Your existing
    `~/.config/eiskaltdc++` is read (and may be converted) - copy it first.
25. Bluetooth pairing, display settings, your accounts; `eselect news read`.
26. Snapshot the finished desktop: `sudo zfs snapshot -r gentoo@clean-desktop`.

## Living with it

- **Updates:** `sudo world-update`. It syncs the package tree, snapshots the system (not the
  homes: rolling back an update from ZFSBootMenu leaves your files alone), updates everything,
  rebuilds ZFSBootMenu when the kernel or ZFS changed, removes old kernels and unneeded packages,
  and reports security advisories, any log over 50 MB in `/var/log` or the homes, and whether the
  session's memory cap slowed it (see "What else it sets up"). The package
  tree also syncs once a day by itself. Its log, `/var/log/world-update.log`, starts afresh each
  month (or past 20 MB), the six before kept compressed; Portage's logs rotate too.
- **Never run `zpool upgrade`** until ZFSBootMenu has been rebuilt for the new ZFS
  (`sudo update-zbm`; `world-update` does it for you): an older ZFSBootMenu cannot open an
  upgraded pool, and the laptop would not boot.
- **The pool passphrase** is asked once, by ZFSBootMenu, and handed to the system's own startup
  (its initramfs) in memory for that boot only; no key file exists on the disk or in `/boot`.
  `sudo zfs set gentoo-laptop:key-injection=off gentoo` turns that off: then the system asks a
  second time after ZFSBootMenu (`Encrypted ZFS password for gentoo`); `=on` turns it back on.
  The same second prompt appears whenever the hand-over cannot be made - the boot goes on. On
  rescue media, `zpool import -N gentoo && zfs load-key gentoo` asks for the passphrase. To change
  it: `sudo zfs change-key gentoo`.
- **When something eats memory or CPU** (a browser tab, say): atop records every process once a
  minute and keeps 28 days in `/var/log/atop`. Replay a moment afterwards with
  `atop -r /var/log/atop/atop_20261118 -b 14:20`, then `m` for memory, `c` for command lines, `t`
  and `T` to step. While it happens: Brave's own task manager (Shift+Esc) names the tab; if the
  desktop no longer responds, Ctrl+Alt+F2 gives a text console outside the desktop's memory cap -
  log in, run `htop`, kill only the top process.
- **SSH** takes keys only (`/etc/ssh/sshd_config.d/10-keys-only.conf`); passwords are refused over
  the network. Another computer's key goes into `~/.ssh/authorized_keys` from a session that
  already works, or at the laptop itself.
- **Snapshots** of the system and your home are automatic (sanoid, checked every 15 minutes):
  hourly ones kept for a day, daily for a week, weekly for a month, monthly for three months.
  `zfs list -t snapshot` shows them. `/home/storage`, a dataset of its own for media and other
  large files, gets daily ones kept for a week and weekly for a month, so a deleted file's space
  comes back within a month. `/var/tmp` and the container storage are not snapshotted.
  Snapshots you take yourself (steps 14 and 26) are never pruned: they keep the space of what has
  changed since, until you remove them with `sudo zfs destroy -r gentoo@<name>`.
- **Battery** (laptops with charge thresholds, such as ThinkPads): on a dock - any Thunderbolt
  device connected - it charges between 75 and 80 %, which is kinder to a battery that lives
  plugged in; anywhere else to 100 %. `battery-limits status` shows the state; before a trip
  `sudo battery-limits full` charges to 100 % on the dock too, until you undock or reboot. On the
  dock between the limits the battery says "Not charging": expected. Laptops without charge
  thresholds are left alone.
- **More users:** Settings -> User Accounts, or

      sudo useradd -m -s /bin/bash -G audio,video,usb,input,plugdev NAME    # add wheel for sudo
      sudo passwd NAME

  A hook that useradd runs itself (`/etc/shadow-maint/useradd-post.d/50-zfs-home`) makes the
  new home a ZFS dataset, snapshotted like yours, plus container storage if Podman is installed.
  `sudo userdel NAME` keeps the home; `sudo userdel -r NAME` deletes it with its snapshots.
- **Home folders** are readable by the other users (mode 755, `HOME_MODE` in `/etc/login.defs`),
  so you can share files; `chmod 700 ~` makes yours private. Programs keep their own secrets (SSH
  and GnuPG keys, browser profiles) private either way.
- **System files** all come from `files/` (listed in `deploy.list`). To change one, edit it in
  `~/gentoo-laptop/files/`, then `sudo ./deploy` in `~/gentoo-laptop`: it shows every difference
  and asks before installing. `sudo ./deploy --dry-run` only shows.
- **A newer version of the scripts** (from GitHub as in step 4, or a pack): unpack it next to the
  old folder, carry over any changes of your own (`diff -ru ~/gentoo-laptop <new folder>` shows
  them), then run `sudo ./deploy` from the new folder and use it from then on.
- **Firmware** (BIOS, and other devices that support it) updates through fwupd:
  `sudo fwupdmgr refresh && sudo fwupdmgr get-updates`, then `sudo fwupdmgr update` - on the
  charger; the reboot applies it. fwupd's daemon starts by itself when needed.
- **Tor** is installed but not started: `sudo rc-update add tor default` to have it.

## What else it sets up

So that nothing surprises you: compressed swap in RAM (zram) and no swap partition - under 16 GB
of RAM instead an encrypted swap partition with zswap (its key is new at each boot, so there is no
hibernation); the ZFS read cache capped (`ARC_MAX_GIB`); a soft memory cap on each desktop session, 5/8 of RAM (systemd's
`MemoryHigh` without systemd; `MEMORY_HIGH=` in `/etc/session-memory-limit.conf` changes it); network settings so that a dock's Ethernet and the Wi-Fi can be on
the same network at once without NetworkManager dropping both addresses; a small helper that puts
windows back where they were when you re-dock; container images (with Podman) in
/var/lib/containers/<user>, outside your home, so backups of /home skip them; a local patch to
GNOME Text Editor (step 21); sudo through the `wheel` group with root locked; fwupd for firmware
updates; a few admin tools (nmap, tcpdump, byobu, vim, git, tmux, htop) and btrfs-progs (mkfs.btrfs,
btrfs scrub) for drives formatted with btrfs. The comments at the top of each
script and of each file in `files/` explain the details.
