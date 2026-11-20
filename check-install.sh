#!/bin/bash
# check-install.sh - read-only checks of a fresh install-gentoo.sh install, run on the live CD
# BEFORE the first reboot:
#     bash check-install.sh 2>&1 | tee /root/check.txt
# Works whether the pool is still imported/mounted (e.g. after a failed run) or
# exported (after a successful run; then it imports it READ-ONLY and asks for the
# passphrase). Nothing is changed. Password hashes are never printed.

set -u
POOL=gentoo
CHECKMNT=/mnt/check
ESPMNT=/mnt/esp-check
sec() { printf '\n===== %s =====\n' "$1"; }
same_file() { [ "$(od -An -tx1 "$1" 2>/dev/null)" = "$(od -An -tx1 "$2" 2>/dev/null)" ]; }

we_imported=0; we_mounted_esp=0
cleanup() {
    [ "$we_mounted_esp" = 1 ] && umount "$ESPMNT"
    [ "$we_imported" = 1 ] && zpool export "$POOL" && echo "(pool exported again)"
}
trap cleanup EXIT

sec "Installer log"
L=/root/install-gentoo.log
if [ -r "$L" ]; then
    echo "runtime failures: $(grep -ac '^FAILED' "$L")"
    grep -a '>>>' "$L" | tail -n 2 | sed 's/\x1b\[[0-9;]*m//g'
    grep -a '^initramfs for .* contains zfs' "$L" || echo "(initramfs check not reached)"
    grep -a 'ZFSBootMenu hooks\|hooks MISSING\|hooks not checked' "$L" || echo "(ZFSBootMenu hook check not reached)"
    grep -a '^SSH: \|sshd is not keys-only' "$L" || echo "(SSH check not reached)"
    grep -an '^FAILED\|^!!!' "$L" | tail -n 6 | cut -c1-300
    echo "--- last 25 lines of $L"
    tail -n 25 "$L" | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-300
else
    echo "$L: not present"
fi

sec "Firmware boot entries (short)"
efibootmgr | grep -E '^Boot(Current|Order)|ZFSBootMenu' || true
efibootmgr | grep -q ZFSBootMenu || echo ">>> No ZFSBootMenu entry yet - do NOT reboot"

sec "Pool"
if zpool list "$POOL" >/dev/null 2>&1; then
    echo "pool is imported (install not finished, or not exported yet)"
else
    zpool import -N -o readonly=on -R "$CHECKMNT" "$POOL" 2>/dev/null \
        || zpool import -f -N -o readonly=on -R "$CHECKMNT" "$POOL" || exit 1
    we_imported=1
fi
zpool status -P "$POOL" | grep -E 'state:|/dev/|errors:'
vdev="$(zpool status -P "$POOL" | awk '/\/dev\// {print $1; exit}')"   # the pool's partition
zpool get -H -o property,value bootfs,compatibility,autotrim,ashift "$POOL"
zfs get -H -o name,property,value org.zfsbootmenu:commandline "$POOL/ROOT"
zfs get -H -o name,property,value keylocation,gentoo-laptop:key-injection "$POOL"   # want prompt, on

if [ "$(zfs get -H -o value keystatus "$POOL")" != "available" ]; then
    echo "Enter the pool passphrase:"
    zfs load-key -L prompt "$POOL" || exit 1
fi
[ "$(zfs get -H -o value mounted "$POOL/ROOT/default")" = yes ] || zfs mount "$POOL/ROOT/default"
MNT="$(zfs get -H -o value mountpoint "$POOL/ROOT/default")"
echo "boot environment mounted at $MNT"
zfs list -o name,used,mountpoint,canmount,encryptionroot,keystatus -r "$POOL"

sec "Kernels and initramfs in the boot environment"
ls -l "$MNT/boot"

sec "Key, hostid and boot-related config"
keys="$(find "$MNT/etc/zfs" -maxdepth 1 -name '*.key' 2>/dev/null)"
if [ -z "$keys" ]; then echo "no key file in $MNT/etc/zfs (key injection)"; else echo "KEY FILE ON DISK: $keys"; fi
for h in load-key.d/50-key-injection boot-sel.d/90-key-injection; do
    stat -c '%a %U %n' "$MNT/etc/zfsbootmenu/hooks/$h" 2>/dev/null || echo "MISSING: /etc/zfsbootmenu/hooks/$h"
done
if same_file /etc/hostid "$MNT/etc/hostid"; then echo "hostid matches the live session"; else echo "hostid differs from the live session"; fi
for f in /etc/fstab /etc/dracut.conf.d/zfs.conf /etc/modprobe.d/zfs.conf \
         /etc/zfsbootmenu/config.yaml /etc/sudoers.d/wheel /etc/conf.d/hostname; do
    printf -- '--- %s\n' "$f"; grep -v '^[[:space:]]*#' "$MNT$f" | grep -v '^[[:space:]]*$'
done

sec "Swap"
disk="$(sed -E 's/(-part|p)?[0-9]+$//' <<<"$vdev")"
[ -b "$disk" ] || disk="$(sed -E 's/[0-9]+$//' <<<"$vdev")"
sgdisk -p "$disk" 2>/dev/null | sed -n '/^Number/,$p'
if grep -q '^swap=' "$MNT/etc/conf.d/dmcrypt" 2>/dev/null; then
    printf -- '--- %s\n' /etc/conf.d/dmcrypt; grep -E '^(swap|source|options)=' "$MNT/etc/conf.d/dmcrypt"
    u="$(sed -n "s/^source='PARTUUID=\(.*\)'$/\1/p" "$MNT/etc/conf.d/dmcrypt")"
    if d="$(blkid -l -t "PARTUUID=$u" -o device)"; then echo "PARTUUID $u is $d"; else echo ">>> PARTUUID $u: no such partition"; fi
    grep -q '^/dev/mapper/crypt-swap[[:space:]]' "$MNT/etc/fstab" || echo ">>> no crypt-swap line in /etc/fstab"
    [ -e "$MNT/etc/runlevels/boot/dmcrypt" ] || echo ">>> dmcrypt is not in the boot runlevel"
else
    echo "no swap partition: compressed swap in RAM (zram.start)"
fi

sec "Services enabled at boot"
for rl in boot default; do
    printf '[%s]' "$rl"; for f in "$MNT/etc/runlevels/$rl"/*; do printf ' %s' "${f##*/}"; done; echo
done

sec "Accounts (status only, no hashes)"
users="$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' "$MNT/etc/passwd" | paste -sd'|' -)"
awk -F: -v users="^(${users:-none})$" '$1=="root" || $1 ~ users {
    s = ($2 ~ /^[!*]/) ? "locked" : ($2 ~ /^\$/ ? "password set" : "no password")
    print $1 ": " s }' "$MNT/etc/shadow"
grep -E "^(${users:-none}):" "$MNT/etc/passwd"; grep -E '^(wheel|audio|video|usb|input):' "$MNT/etc/group"

sec "Portage profile and key packages"
readlink "$MNT/etc/portage/make.profile"
for d in "$MNT"/var/db/pkg/sys-fs/zfs* "$MNT"/var/db/pkg/sys-kernel/gentoo-kernel* \
         "$MNT"/var/db/pkg/sys-kernel/linux-firmware* "$MNT"/var/db/pkg/sys-kernel/dracut* \
         "$MNT"/var/db/pkg/sys-kernel/installkernel* "$MNT"/var/db/pkg/sys-boot/* \
         "$MNT"/var/db/pkg/sys-apps/systemd-utils*; do
    [ -e "$d" ] && echo "${d#"$MNT"/var/db/pkg/}"
done

sec "Files deployed from the checkout (./deploy)"
if [ -r "$MNT/var/lib/deploy/deployed" ]; then
    echo "groups: $(paste -sd' ' "$MNT/var/lib/deploy/groups" 2>/dev/null)"
    n=0; drift=0
    while read -r s _m _g d; do
        n=$((n + 1))
        [ "$(sha256sum "$MNT$d" 2>/dev/null | cut -d' ' -f1)" = "$s" ] || { echo "differs or missing: $d"; drift=1; }
    done < "$MNT/var/lib/deploy/deployed"
    if [ "$drift" = 0 ]; then echo "$n files, all as deployed"; else echo "$n files recorded"; fi
else
    echo "/var/lib/deploy/deployed: missing - deploy did not run in the chroot"
fi

sec "Local snapshots (sanoid)"
found=""; for d in "$MNT"/var/db/pkg/sys-fs/sanoid-*; do [ -e "$d" ] && found="${d#"$MNT"/var/db/pkg/}"; done
echo "${found:-sys-fs/sanoid: NOT installed}"
if [ -r "$MNT/etc/sanoid/sanoid.conf" ]; then
    grep -E '^\[|^ *(hourly|daily|weekly|monthly) ' "$MNT/etc/sanoid/sanoid.conf" | paste -sd' ' -
else echo "/etc/sanoid/sanoid.conf: missing"; fi
if [ -r "$MNT/etc/cron.d/sanoid-snapshots" ]; then grep -v '^#' "$MNT/etc/cron.d/sanoid-snapshots"
else echo "/etc/cron.d/sanoid-snapshots: missing"; fi

sec "EFI system partition"
esp="$(sed -E 's/[0-9]+$/1/' <<<"$vdev")"   # ZFS is partition 2, or 3 after a swap partition
espdir="$(findmnt -n -o TARGET --source "$(readlink -f "$esp")" | head -n1)"
if [ -z "$espdir" ]; then
    mkdir -p "$ESPMNT" && mount -o ro "$esp" "$ESPMNT" && we_mounted_esp=1 && espdir="$ESPMNT"
fi
echo "EFI partition $esp at ${espdir:-?}"
[ -n "$espdir" ] && find "$espdir" -type f -exec ls -l {} +
