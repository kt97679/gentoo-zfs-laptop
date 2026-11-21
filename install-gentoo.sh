#!/bin/bash
# install-gentoo.sh - Gentoo (OpenRC) on a single natively encrypted ZFS pool,
# booted by ZFSBootMenu that is BUILT LOCALLY from the installed kernel, ZFS and dracut.
#
# Run as root from the Gentoo minimal installation CD on the target laptop, inside the
# gentoo-laptop checkout (deploy, deploy.list and files/ are used, and local.conf - this machine's
# settings, local.conf.example explains them - when there is one; copy the whole directory):
#     bash install-gentoo.sh            (shows a menu of disks to choose from)
#     DISK=/dev/disk/by-id/nvme-XXXX bash install-gentoo.sh   (skip the menu)
# Root gets no password (account locked); administration is via sudo.
#
# !!! THIS DESTROYS EVERYTHING ON $DISK !!!
# Secure Boot must be disabled in the firmware (the ZFSBootMenu image is unsigned).
#
# Layout:  $DISK-part1  1 GiB EFI system partition  -> /efi
#          $DISK-part2  rest of disk                -> ZFS pool "$POOL"
#   under 16 GB of RAM (SWAP_GIB below) a swap partition comes between them, and ZFS is part3:
#          $DISK-part2  swap, encrypted with a new random key at each boot, zswap in front of it
#   gentoo                 aes-256-gcm, passphrase (one encryption root, one prompt)
#   gentoo/ROOT/default    /               boot environment, kernels in its /boot
#   gentoo/home/<user>     /home/<user>
#   gentoo/scratch         /var/tmp        (exclude from snapshots/replication later)
#   swap: zram (never swap on ZFS); with a swap partition zswap instead

set -Eeuo pipefail

### Settings - review before running ###########################################
DISK="${DISK:-}"                  # optional: if empty, a menu lets you pick the disk
POOL="gentoo"
POOL_COMPAT="openzfs-2.2"         # pool features any ZFS 2.2+ can import: the installed system
                                  # and ZFSBootMenu (same version) and rescue media such as the
                                  # Ubuntu 24.04 live USB (2.2.x); 2.3/2.4 add nothing a laptop
                                  # needs. Relax later with "zpool set compatibility=off" +
                                  # "zpool upgrade" - never before ZFSBootMenu is rebuilt
# When empty, host and user are asked for and the time zone is picked from a menu; any setting
# here can also come from the environment, e.g.
#   HOSTNAME_NEW=mylaptop USERNAME=alice TIMEZONE=Europe/Berlin bash install-gentoo.sh
HOSTNAME_NEW="${HOSTNAME_NEW:-}"
USERNAME="${USERNAME:-}"          # your login (sudo through the wheel group; root stays locked)
TIMEZONE="${TIMEZONE:-}"          # e.g. America/Los_Angeles; empty: menu of common zones
LOCALE="${LOCALE:-en_US.UTF-8}"
BINHOST_ARCH="${BINHOST_ARCH:-}"  # empty: x86-64-v3 if this CPU supports it, else x86-64
VIDEO_CARDS="${VIDEO_CARDS-auto}" # auto: from the graphics hardware found (AMD: amdgpu radeonsi,
                                  # Intel: intel, NVIDIA: nouveau); empty: the profile's default
ARC_MAX_GIB="${ARC_MAX_GIB:-auto}" # cap of the ZFS read cache in GiB (ZFS's own default is ~all
                                  # RAM); auto: a quarter of the RAM, 1 to 8
SWAP_GIB="${SWAP_GIB:-auto}"       # swap partition in GiB, encrypted with a new random key at each
                                  # boot, with zswap in front of it; auto: under 16 GB of RAM twice
                                  # the RAM (at most 16), else none - compressed swap in RAM (zram)
                                  # does then; 0: none
ESP_SIZE="1G"
MIRROR="https://distfiles.gentoo.org"
TARGET="/mnt/gentoo"
LOG="/root/install-gentoo.log"
################################################################################

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n\033[1;32m>>> %s\033[0m\n' "$*"; }
HERE="$(dirname "$(readlink -f "$0")")"   # the checkout: its system files are deployed in the chroot
[ -x "$HERE/deploy" ] && [ -f "$HERE/deploy.list" ] && [ -d "$HERE/files" ] \
    || die "run this from the gentoo-laptop checkout: deploy, deploy.list and files/ must be next to it"
check_local_conf() {   # local.conf (this machine's settings), checked by deploy now - not in the
    # chroot an hour into the install - with a dry run into an empty directory
    [ -f "$HERE/local.conf" ] || return 0
    local chk; chk="$(mktemp -d)"
    "$HERE/deploy" --root "$chk" --dry-run --group base > "$chk.out" 2>&1 \
        || { cat "$chk.out" >&2; rm -rf "$chk" "$chk.out"; die "local.conf has errors (above) - fix them, or move it away, and run again"; }
    rm -rf "$chk" "$chk.out"
    echo "local.conf: this machine's settings, installed with the system files"
}
check_local_conf
memory_plan() {   # memory_plan MEMTOTAL_KB THREADS - prints "RAM ARC SWAP JOBS": the RAM's nominal
    # size in GB (MemTotal up to a multiple of 4: firmware and integrated graphics keep part of it,
    # so a 16 GB laptop reports 13-15 GiB), the ZFS cache cap and the swap partition in GiB, and
    # make jobs (one per 2 GB of RAM, at most one per thread)
    local kb="$1" threads="$2" ram arc swap jobs
    ram=$(( (kb + 4194303) / 4194304 ))   # whole units of 4 GiB, rounded up
    ram=$(( ram * 4 ))
    if [ "$ARC_MAX_GIB" = auto ]; then
        arc=$(( ram / 4 )); [ "$arc" -ge 1 ] || arc=1; [ "$arc" -le 8 ] || arc=8
    else
        arc="$ARC_MAX_GIB"
    fi
    if [ "$SWAP_GIB" != auto ]; then swap="$SWAP_GIB"
    elif [ "$ram" -lt 16 ]; then swap=$(( ram * 2 )); [ "$swap" -le 16 ] || swap=16
    else swap=0; fi
    jobs=$(( ram / 2 )); [ "$jobs" -ge 1 ] || jobs=1; [ "$jobs" -le "$threads" ] || jobs="$threads"
    echo "$ram $arc $swap $jobs"
}

part() {  # partition path for partition number $1
    case "$DISK" in
        /dev/disk/by-id/*|/dev/disk/by-path/*) echo "${DISK}-part$1" ;;
        *[0-9]) echo "${DISK}p$1" ;;
        *) echo "${DISK}$1" ;;
    esac
}
by_id() {  # stable /dev/disk/by-id name for a whole disk, preferring model_serial names
    local dev="$1" link best=""
    for link in /dev/disk/by-id/*; do
        case "$link" in *-part*) continue ;; esac
        [ "$(readlink -f "$link")" = "$dev" ] || continue
        case "${link##*/}" in
            nvme-eui.*|nvme-nvme.*|wwn-*) [ -z "$best" ] && best="$link" ;;
            *) best="$link"; break ;;
        esac
    done
    echo "${best:-$dev}"
}
choose_disk() {  # menu of whole disks without mounted partitions (hides the live USB)
    local dev type size tran model serial
    local -a devs=() labels=()
    while read -r dev type; do
        [ "$type" = "disk" ] || continue
        case "$dev" in /dev/zram*|/dev/loop*|/dev/sr*) continue ;; esac
        [ -z "$(lsblk -no MOUNTPOINTS "$dev" | tr -d '[:space:]')" ] || continue
        size="$(lsblk -dno SIZE "$dev" | xargs)"
        tran="$(lsblk -dno TRAN "$dev" | xargs)"
        model="$(lsblk -dno MODEL "$dev" | xargs)"
        serial="$(lsblk -dno SERIAL "$dev" | xargs)"
        devs+=("$dev")
        labels+=("$(printf '%-14s %8s  %-5s %s %s' "$dev" "$size" "${tran:-?}" "${model:-?}" "$serial")")
    done < <(lsblk -dpno NAME,TYPE)
    [ "${#devs[@]}" -gt 0 ] || die "no suitable disks found"
    echo "Disks available for installation (disks with mounted partitions are hidden):" >&2
    PS3="Number of the disk to ERASE: "
    select _ in "${labels[@]}"; do
        if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#devs[@]}" ]; then
            echo "${devs[$((REPLY - 1))]}"
            return
        fi
        echo "Invalid choice" >&2
    done
    die "no disk selected"
}
ask() {  # ask VAR QUESTION REGEX EXAMPLE: read VAR until it matches REGEX (if it is still empty)
    local var="$1" a
    while [ -z "${!var}" ]; do
        read -rp "$2: " a
        if [[ "$a" =~ $3 ]]; then printf -v "$var" '%s' "$a"; else echo "  not valid - e.g. $4" >&2; fi
    done
    [[ "${!var}" =~ $3 ]] || die "$var=\"${!var}\" is not valid - e.g. $4"
}
# The minimal live CD has no time zone database, so the menu is built in: one zone per set of
# clock rules, west to east. Labels give standard time; the zone itself handles daylight saving.
TIMEZONES=(
    "Pacific/Honolulu|UTC-10    Hawaii"
    "America/Anchorage|UTC-9     Alaska"
    "America/Los_Angeles|UTC-8     US & Canada Pacific (Los Angeles, Vancouver)"
    "America/Denver|UTC-7     US & Canada Mountain (Denver, Calgary)"
    "America/Phoenix|UTC-7     Arizona (no daylight saving)"
    "America/Chicago|UTC-6     US & Canada Central (Chicago, Winnipeg)"
    "America/Mexico_City|UTC-6     Mexico (Mexico City)"
    "America/New_York|UTC-5     US & Canada Eastern (New York, Toronto)"
    "America/Bogota|UTC-5     Colombia, Peru, Ecuador (Bogota, Lima)"
    "America/Halifax|UTC-4     Canada Atlantic (Halifax)"
    "America/Santiago|UTC-4     Chile (Santiago)"
    "America/Sao_Paulo|UTC-3     Brazil (Sao Paulo, Rio de Janeiro)"
    "America/Argentina/Buenos_Aires|UTC-3     Argentina (Buenos Aires)"
    "UTC|UTC       Coordinated Universal Time"
    "Europe/London|UTC+0     UK, Ireland (London, Dublin)"
    "Europe/Berlin|UTC+1     Central Europe (Berlin, Paris, Madrid, Rome, Warsaw)"
    "Africa/Lagos|UTC+1     West Africa (Lagos)"
    "Europe/Athens|UTC+2     Eastern Europe (Athens, Kyiv, Helsinki, Bucharest)"
    "Africa/Cairo|UTC+2     Egypt (Cairo)"
    "Africa/Johannesburg|UTC+2     Southern Africa (Johannesburg)"
    "Asia/Jerusalem|UTC+2     Israel (Jerusalem)"
    "Europe/Istanbul|UTC+3     Turkey (Istanbul)"
    "Europe/Moscow|UTC+3     Russia, Moscow time"
    "Asia/Tehran|UTC+3:30  Iran (Tehran)"
    "Asia/Dubai|UTC+4     Gulf (Dubai, Abu Dhabi)"
    "Asia/Karachi|UTC+5     Pakistan (Karachi)"
    "Asia/Kolkata|UTC+5:30  India (Mumbai, Delhi, Kolkata)"
    "Asia/Dhaka|UTC+6     Bangladesh (Dhaka)"
    "Asia/Bangkok|UTC+7     Indochina, western Indonesia (Bangkok, Hanoi, Jakarta)"
    "Asia/Shanghai|UTC+8     China (Beijing, Shanghai)"
    "Asia/Singapore|UTC+8     Singapore, Malaysia, Philippines"
    "Asia/Tokyo|UTC+9     Japan, Korea (Tokyo, Seoul)"
    "Australia/Adelaide|UTC+9:30  Australia Central (Adelaide)"
    "Australia/Brisbane|UTC+10    Queensland (Brisbane, no daylight saving)"
    "Australia/Sydney|UTC+10    Australia East (Sydney, Melbourne)"
    "Pacific/Auckland|UTC+12    New Zealand (Auckland)"
)
choose_timezone() {  # menu of TIMEZONES plus "type another"; prints the zone
    local typed="" entry
    local -a labels=()
    for entry in "${TIMEZONES[@]}"; do labels+=("${entry#*|}"); done
    labels+=("Other: type a zone name (e.g. Asia/Hong_Kong)")
    echo "Time zone (standard-time offsets; daylight saving follows the zone):" >&2
    PS3="Time zone number: "
    select _ in "${labels[@]}"; do
        if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#TIMEZONES[@]}" ]; then
            echo "${TIMEZONES[$((REPLY - 1))]%%|*}"
            return
        elif [ "$REPLY" = "${#labels[@]}" ]; then
            ask typed "Time zone name" '^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$' "Asia/Hong_Kong"
            echo "$typed"
            return
        fi
        echo "Invalid choice" >&2
    done
    die "no time zone chosen"
}
detect_video_cards() {  # VIDEO_CARDS for the display controllers on the PCI bus
    local d
    local -a cards=()
    for d in /sys/bus/pci/devices/*; do
        case "$(cat "$d/class" 2>/dev/null)" in 0x03*) ;; *) continue ;; esac
        case "$(cat "$d/vendor" 2>/dev/null)" in
            0x1002) cards+=(amdgpu radeonsi) ;;
            0x8086) cards+=(intel) ;;
            0x10de) cards+=(nouveau) ;;
        esac
    done
    printf '%s\n' "${cards[@]}" | sort -u | paste -sd' ' -
}
detect_binhost_arch() {  # x86-64-v3 binary packages need AVX2 & co.; glibc's loader knows
    local help                          # captured first: grep -q in a pipe can SIGPIPE ld.so (pipefail)
    help="$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null || true)"
    if grep -q 'x86-64-v3 (supported' <<<"$help"; then
        echo x86-64-v3
    else
        echo x86-64
    fi
}
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR

### Pre-flight checks ###########################################################
[ "$(id -u)" -eq 0 ] || die "run as root"
[ -d /sys/firmware/efi ] || die "not booted in UEFI mode"
command -v sgdisk >/dev/null || die "sgdisk not found"
[ -n "$DISK" ] || DISK="$(choose_disk)"
[ -b "$DISK" ] || die "$DISK is not a block device"
case "$DISK" in /dev/disk/by-id/*) ;; *) DISK="$(by_id "$(readlink -f "$DISK")")" ;; esac
[ -z "$(lsblk -no MOUNTPOINTS "$DISK" | tr -d '[:space:]')" ] || die "$DISK has mounted partitions"
command -v zpool >/dev/null || die "zpool not found - is ZFS available on this live CD?"
[ -e "/usr/share/zfs/compatibility.d/$POOL_COMPAT" ] || \
    die "compatibility set $POOL_COMPAT not found; available: $(cd /usr/share/zfs/compatibility.d && printf '%s ' *)"
zpool list "$POOL" >/dev/null 2>&1 && die "a pool named $POOL is already imported; export or destroy it first"
wget -q --spider "$MIRROR/releases/" || die "no network access to $MIRROR"
[ -r /usr/share/openpgp-keys/gentoo-release.asc ] || die "Gentoo release key not found on the live CD"

ask HOSTNAME_NEW "Host name for the new system" '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' "mylaptop"
ask USERNAME "Your user name" '^[a-z_][a-z0-9_-]{0,31}$' "alice"
[ "$USERNAME" != root ] || die "choose a user name other than root"
[ -n "$TIMEZONE" ] || TIMEZONE="$(choose_timezone)"
[[ "$TIMEZONE" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || die "TIMEZONE=\"$TIMEZONE\" is not valid - e.g. Europe/Berlin"
# Whether the zone exists is checked once the stage3 is unpacked: the minimal live CD has an empty
# /usr/share/zoneinfo, so checking here rejected every zone.
[ -n "$BINHOST_ARCH" ] || BINHOST_ARCH="$(detect_binhost_arch)"
[ "$VIDEO_CARDS" != auto ] || VIDEO_CARDS="$(detect_video_cards)"
[[ "$ARC_MAX_GIB" =~ ^(auto|[1-9][0-9]*)$ ]] || die "ARC_MAX_GIB=\"$ARC_MAX_GIB\": a whole number of GiB, or auto"
[[ "$SWAP_GIB" =~ ^(auto|0|[1-9][0-9]*)$ ]] || die "SWAP_GIB=\"$SWAP_GIB\": a whole number of GiB (0: none), or auto"
read -r RAM_GB ARC_GIB SWAP_N BUILD_JOBS < <(memory_plan "$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)" "$(nproc)")

zfs version
echo; echo "Host $HOSTNAME_NEW, user $USERNAME, time zone $TIMEZONE, locale $LOCALE"
echo "Binary packages for $BINHOST_ARCH; VIDEO_CARDS: ${VIDEO_CARDS:-(profile default)}"
if [ "$SWAP_N" -gt 0 ]; then swap_word="a $SWAP_N GiB encrypted swap partition with zswap"
else swap_word="compressed swap in RAM (zram), no swap partition"; fi
echo "RAM ${RAM_GB} GB: $swap_word; ZFS cache up to $ARC_GIB GiB; $BUILD_JOBS build jobs"
echo "Selected: $DISK"
lsblk -o NAME,SIZE,TRAN,MODEL,SERIAL,FSTYPE "$DISK"
read -rp "Type YES to ERASE $DISK and install Gentoo: " answer
[ "$answer" = "YES" ] || die "aborted"

### Secrets (never written to the log) ##########################################
read -rsp "ZFS encryption passphrase (min. 8 chars): " PASSPHRASE; echo
read -rsp "Repeat passphrase: " PASSPHRASE2; echo
[ "$PASSPHRASE" = "$PASSPHRASE2" ] || die "passphrases differ"
[ "${#PASSPHRASE}" -ge 8 ] || die "passphrase too short"
read -rsp "Password for $USERNAME (used for login and sudo): " USER_PW; echo
read -rsp "Repeat password: " USER_PW2; echo
[ "$USER_PW" = "$USER_PW2" ] || die "passwords differ"
[ -n "$USER_PW" ] || die "empty password"
unset PASSPHRASE2 USER_PW2

exec > >(tee -a "$LOG") 2>&1
echo "Install started $(date -Is), disk $DISK"

### Partitioning ################################################################
partition_disk() {   # EFI, then the swap partition if SWAP_N > 0, then ZFS; sets ESP, SWAPPART,
    # ZPART and SWAP_PARTUUID (lower case, as blkid gives it; empty without swap)
    SWAPPART="" SWAP_PARTUUID=""
    if [ "$SWAP_N" -gt 0 ]; then
        sgdisk -n1:1M:+"$ESP_SIZE" -t1:EF00 -c1:EFI \
               -n2:0:+"${SWAP_N}G" -t2:8200 -c2:swap \
               -n3:0:0             -t3:BF00 -c3:zfs "$DISK"
    else
        sgdisk -n1:1M:+"$ESP_SIZE" -t1:EF00 -c1:EFI \
               -n2:0:0             -t2:BF00 -c2:zfs "$DISK"
    fi
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle; sleep 2
    ESP="$(part 1)"
    if [ "$SWAP_N" -gt 0 ]; then
        SWAPPART="$(part 2)" ZPART="$(part 3)"
        [ -b "$SWAPPART" ] || die "partition $SWAPPART did not appear"
        wipefs -aq "$SWAPPART"   # no old signature in it; the swap is made at boot, encrypted
        SWAP_PARTUUID="$(sgdisk -i 2 "$DISK" | sed -n 's/^Partition unique GUID: //p' | tr 'A-F' 'a-f')"
        [[ "$SWAP_PARTUUID" =~ ^[0-9a-f-]{36}$ ]] || die "no partition GUID for $SWAPPART: '$SWAP_PARTUUID'"
    else
        ZPART="$(part 2)"
    fi
    [ -b "$ESP" ] && [ -b "$ZPART" ] || die "partitions $ESP / $ZPART did not appear"
}
INSTALL_SWAP=install-swap
live_swap() {   # live_swap on|off - the swap partition as swap for the install itself (a small
    # machine's builds need it): a throwaway random key, the cipher the system uses at boot; gone at
    # reboot, when the installed system opens the partition with a key of its own. off: before the
    # disk is wiped again (a rerun) - a partition in use keeps the old partition table.
    case "$1" in
    on)
        command -v cryptsetup >/dev/null || { echo "no cryptsetup in this live system - the install runs without swap"; return 0; }
        if cryptsetup open --type plain --batch-mode -c aes-xts-plain64 -s 512 -d /dev/urandom "$SWAPPART" "$INSTALL_SWAP" \
            && mkswap "/dev/mapper/$INSTALL_SWAP" >/dev/null && swapon "/dev/mapper/$INSTALL_SWAP"; then
            echo "swap for the install: $SWAP_N GiB on $SWAPPART, encrypted with a throwaway key"
        else
            echo "could not use $SWAPPART as swap - the install runs without swap"
        fi
        ;;
    off)
        [ -e "/dev/mapper/$INSTALL_SWAP" ] || return 0
        swapoff "/dev/mapper/$INSTALL_SWAP" 2>/dev/null || true
        cryptsetup close "$INSTALL_SWAP" || die "the swap of an earlier run (/dev/mapper/$INSTALL_SWAP) is still in use"
        ;;
    esac
}
step "Wiping and partitioning $DISK"
live_swap off   # a rerun: the swap of the first run is on the disk about to be wiped
for p in "$DISK"*; do [ -b "$p" ] && zpool labelclear -f "$p" 2>/dev/null || true; done
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
partition_disk
mkfs.vfat -F32 -n EFI "$ESP"
[ -z "$SWAPPART" ] || live_swap on

### Pool and datasets ###########################################################
copy_live_ssh() {   # into $TARGET: the live session's SSH login key and the host keys it made
    # sshd takes keys only (files/sshd-keys-only.conf): the key this install runs with over SSH, if
    # any, becomes the user's in the chroot (README, phase 1: ssh-copy-id to the live system)
    rm -f "$TARGET/tmp/live-authorized_keys"
    [ ! -s /root/.ssh/authorized_keys ] || install -D -m 600 /root/.ssh/authorized_keys "$TARGET/tmp/live-authorized_keys"
    # Host keys made by this live session - newer than its boot; one shipped inside the ISO would be
    # the same on every copy of it and is never taken. The computer you install from then meets the
    # same host key after the reboot, not a "host key changed" warning; sshd makes the missing ones.
    local boot n=0 k
    boot=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))
    for k in /etc/ssh/ssh_host_*_key; do
        if [ -s "$k" ] && [ -s "$k.pub" ] && [ "$(stat -c %Y "$k")" -ge "$boot" ]; then
            install -D -m 600 "$k" "$TARGET$k"
            install -D -m 644 "$k.pub" "$TARGET$k.pub"
            n=$((n + 1))
        fi
    done
    echo "SSH: $n host key(s) from the live session$([ "$n" -gt 0 ] || echo ' (none made by it) - new ones at first start')"
}

swap_setup() {   # in $TARGET: the swap partition SWAP_PARTUUID, opened at boot by the dmcrypt service
    # (sys-fs/cryptsetup, boot runlevel) with a new random key, made a swap there and used through
    # fstab; zswap.start (files/) puts zswap in front of it. Appended after the package wrote its
    # /etc/conf.d/dmcrypt. A random key: nothing survives a reboot - no hibernation. The source as a
    # tag, as that file advises: the service then finds the partition with blkid, waiting up to 5 s
    # for it, and needs no /dev/disk/by-partuuid link from udev. --batch-mode: cryptsetup asks to
    # type YES when it sees an old signature on the partition (one wipefs missed, or ciphertext that
    # happens to look like one), and the boot would wait at that prompt; the partition is this
    # one by its GUID, and the service itself refuses a LUKS partition.
    local conf="$TARGET/etc/conf.d/dmcrypt"
    [ -f "$conf" ] || die "$conf is missing - sys-fs/cryptsetup did not install"
    if ! grep -q '^swap=crypt-swap$' "$conf"; then
        cat >> "$conf" <<EOF

# gentoo-laptop (install-gentoo.sh): the swap partition, opened with a new random key at each boot
swap=crypt-swap
source='PARTUUID=$SWAP_PARTUUID'
options='--batch-mode -c aes-xts-plain64 -s 512 -d /dev/urandom'
EOF
    fi
    grep -q '^/dev/mapper/crypt-swap[[:space:]]' "$TARGET/etc/fstab" \
        || echo "/dev/mapper/crypt-swap  none  swap  sw,pri=10  0 0" >> "$TARGET/etc/fstab"
    echo "swap: $SWAP_N GiB partition (PARTUUID $SWAP_PARTUUID), a new random key at each boot, zswap in front"
}

step "Creating hostid and encrypted pool"
zgenhostid -f
mkdir -p /etc/zfs
# No key file anywhere: keylocation=prompt (zpool reads the passphrase from a pipe as it would from
# a file). At boot ZFSBootMenu asks once and its key-injection hook hands the passphrase to the
# system's initramfs in RAM (files/zbm-key-injection); without it the initramfs asks itself.
printf '%s' "$PASSPHRASE" | zpool create -f \
    -o ashift=12 -o autotrim=on -o compatibility="$POOL_COMPAT" \
    -O encryption=aes-256-gcm -O keyformat=passphrase \
    -O keylocation=prompt \
    -O compression=lz4 -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
    -O relatime=on -O normalization=formD \
    -O mountpoint=none -O canmount=off \
    -R "$TARGET" "$POOL" "$ZPART"
unset PASSPHRASE
# The live system's ZFS cache capped as the installed system's will be: by default it may take
# nearly all of the RAM, and on a small machine the install's builds need it.
echo "$((ARC_GIB * 1024 * 1024 * 1024))" > /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null \
    || echo "(the live system's ZFS cache left as it is)"

zfs create -o mountpoint=none -o canmount=off "$POOL/ROOT"
zfs create -o mountpoint=/ -o canmount=noauto "$POOL/ROOT/default"
zfs mount "$POOL/ROOT/default"
zfs create -o mountpoint=/home "$POOL/home"
zfs create "$POOL/home/$USERNAME"
zfs create -o mountpoint=/var/tmp -o com.sun:auto-snapshot=false "$POOL/scratch"
# Media and other large files, as on dream: beside the homes, not under gentoo/home, so sanoid
# gives it its own lighter policy (files/sanoid.conf); 1 MiB records suit large files. The owner
# is set in the chroot, once the user exists.
zfs create -o mountpoint=/home/storage -o recordsize=1M "$POOL/storage"

zpool set bootfs="$POOL/ROOT/default" "$POOL"
zpool set cachefile=/etc/zfs/zpool.cache "$POOL"
zfs set org.zfsbootmenu:commandline="rw quiet loglevel=4" "$POOL/ROOT"
zfs set gentoo-laptop:key-injection=on "$POOL"   # the hook's switch (off: the system asks again)
zfs list -o name,mountpoint,canmount,encryptionroot

### Stage 3 #####################################################################
step "Downloading and verifying stage3 (desktop, OpenRC)"
cd "$TARGET"
base="$MIRROR/releases/amd64/autobuilds"
path="$(wget -qO- "$base/latest-stage3-amd64-desktop-openrc.txt" \
        | grep -E '^[0-9].*\.tar\.xz' | cut -d' ' -f1 | sed -n 1p)"   # sed reads all: no SIGPIPE
[ -n "$path" ] || die "could not determine the latest stage3"
wget -q --show-progress "$base/$path" "$base/$path.asc"
stage3="$(basename "$path")"
gpg --batch --import /usr/share/openpgp-keys/gentoo-release.asc
gpg --batch --verify "$stage3.asc" "$stage3" || die "stage3 signature verification FAILED"
tar xpf "$stage3" --xattrs-include='*.*' --numeric-owner -C "$TARGET"
rm -f "$stage3" "$stage3.asc"
chmod 1777 "$TARGET/var/tmp"

### Configuration written from outside the chroot ###############################
step "Writing configuration"
mkdir -p "$TARGET/efi"
mount "$ESP" "$TARGET/efi"

cp --dereference /etc/resolv.conf "$TARGET/etc/"
cp /etc/hostid "$TARGET/etc/hostid"
mkdir -p "$TARGET/etc/zfs"
cp /etc/zfs/zpool.cache "$TARGET/etc/zfs/"

cat >> "$TARGET/etc/portage/make.conf" <<EOF

# --- added by install-gentoo.sh ---
COMMON_FLAGS="-march=$BINHOST_ARCH -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j$BUILD_JOBS -l$(nproc)"
FEATURES="\${FEATURES} getbinpkg binpkg-request-signature"
USE="dist-kernel"
ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"
EOF
[ -z "$VIDEO_CARDS" ] || echo "VIDEO_CARDS=\"$VIDEO_CARDS\"" >> "$TARGET/etc/portage/make.conf"

if [ "$BINHOST_ARCH" != "x86-64" ]; then
    sed -i "s#/binpackages/23.0/x86-64/#/binpackages/23.0/$BINHOST_ARCH/#" \
        "$TARGET"/etc/portage/binrepos.conf/*.conf
fi

# portage_conf KIND NAME: write stdin to /etc/portage/KIND/NAME (or append if KIND is a file)
portage_conf() {
    local dir="$TARGET/etc/portage/$1"
    if [ -f "$dir" ]; then cat >> "$dir"; else mkdir -p "$dir"; cat > "$dir/$2"; fi
}
portage_conf package.use install <<'EOF'
sys-kernel/installkernel dracut
# EFI stub for the ZFSBootMenu bundle; the ebuild requires kernel-install together with boot
sys-apps/systemd-utils boot kernel-install
# fwupd: the uefi plugin is what offers BIOS updates (off by default)
sys-apps/fwupd uefi
EOF
# Trims carried over from your VMs (small packages: no effect on binary packages elsewhere)
portage_conf package.use trims <<'EOF'
app-admin/sudo -sendmail
sys-apps/shadow -cracklib
dev-vcs/git -cgi -highlight -mediawiki -mediawiki-experimental -ppcsha1 -subversion -tk -xinetd -perl
dev-libs/newt python
EOF
portage_conf package.mask install <<'EOF'
sys-apps/systemd
net-misc/dhcp
EOF
echo "sys-boot/zfsbootmenu ~amd64" | portage_conf package.accept_keywords zfsbootmenu
echo "sys-fs/sanoid ~amd64" | portage_conf package.accept_keywords sanoid   # only ~amd64 in the tree
# Fewer make jobs for the heaviest C++ build: world-update builds inside the desktop session's soft
# memory cap (session-memory-limit: 5/8 of RAM), and webkit-gtk at one job per thread went over it
# (a 64 GB laptop). About 3 GiB of the cap per job: 64 GB 12 jobs, 32 GB 6.
heavy_jobs=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) * 5 / 8 / 1024 / 3072 ))
[ "$heavy_jobs" -ge 1 ] || heavy_jobs=1
[ "$heavy_jobs" -le "$(nproc)" ] || heavy_jobs="$(nproc)"
portage_conf env fewer-jobs.conf <<EOF
# install-gentoo.sh: about 3 GiB of the session's memory cap (5/8 of RAM) per make job
MAKEOPTS="-j$heavy_jobs -l$(nproc)"
EOF
echo "net-libs/webkit-gtk fewer-jobs.conf" | portage_conf package.env heavy-builds

# Initramfs of the installed system: generic (works on any machine), with ZFS and the ARC cap; no
# pool key (ZFSBootMenu brings it at boot, in RAM).
mkdir -p "$TARGET/etc/dracut.conf.d" "$TARGET/etc/modprobe.d"
# (dracut config: files/dracut-zfs.conf, deployed in the chroot)
echo "options zfs zfs_arc_max=$((ARC_GIB * 1024 * 1024 * 1024))" > "$TARGET/etc/modprobe.d/zfs.conf"

# zram swap, the daily sync, the ARP settings, battery limits, update-zbm, world-update and the other
# system files of this project come from the checkout: deploy.list (group base), installed by
# ./deploy in the chroot below. Change them in files/ and run sudo ./deploy on the laptop.

echo "UUID=$(blkid -s UUID -o value "$ESP")  /efi  vfat  defaults,umask=0077  0 2" >> "$TARGET/etc/fstab"
echo "hostname=\"$HOSTNAME_NEW\"" > "$TARGET/etc/conf.d/hostname"
echo "$HOSTNAME_NEW" > "$TARGET/etc/hostname"
# Time zone check against the stage3's database (the live CD has none): a typed name that does not
# exist would leave a dangling /etc/localtime, so fall back to UTC and say so at the end.
TZ_NOTE=""
if [ ! -f "$TARGET/usr/share/zoneinfo/$TIMEZONE" ]; then
    TZ_NOTE="WARNING: there is no time zone \"$TIMEZONE\"; the system uses UTC. Fix it after the first
         boot with: sudo ln -sf ../usr/share/zoneinfo/Region/City /etc/localtime"
    echo "$TZ_NOTE" >&2
    TIMEZONE=UTC
fi
ln -sf "../usr/share/zoneinfo/$TIMEZONE" "$TARGET/etc/localtime"
echo "$LOCALE ${LOCALE##*.}" >> "$TARGET/etc/locale.gen"

### Chroot ######################################################################
step "Entering chroot"
mkdir -p "$TARGET/tmp/gentoo-laptop"   # what deploy needs, for the chroot; removed afterwards
cp -a "$HERE/deploy" "$HERE/deploy.list" "$HERE/files" "$TARGET/tmp/gentoo-laptop/"
[ ! -f "$HERE/local.conf" ] || cp "$HERE/local.conf" "$TARGET/tmp/gentoo-laptop/"   # deploy installs it too
copy_live_ssh   # the live session's SSH key for the user, and its host keys
mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars
mount --types proc /proc "$TARGET/proc"
mount --rbind /sys "$TARGET/sys";  mount --make-rslave "$TARGET/sys"
mount --rbind /dev "$TARGET/dev";  mount --make-rslave "$TARGET/dev"
mount --bind /run "$TARGET/run";   mount --make-slave "$TARGET/run"

chroot "$TARGET" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-xterm}" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    POOL="$POOL" USERNAME="$USERNAME" LOCALE="$LOCALE" \
    DISK_DEV="$(readlink -f "$DISK")" SWAP_PARTUUID="$SWAP_PARTUUID" \
    /bin/bash -s <<'CHROOT'
set -Eeuo pipefail
trap 'echo "FAILED (chroot) at line $LINENO: $BASH_COMMAND" >&2' ERR
set +u; source /etc/profile; set -u
step() { printf '\n\033[1;32m>>> %s\033[0m\n' "$*"; }

step "Syncing the Portage tree"
emerge-webrsync -q

step "Selecting the OpenRC desktop profile"
eselect profile set default/linux/amd64/23.0/desktop

step "Setting up binary package host keys"
getuto

step "Updating @world (binary packages where available)"
emerge --quiet-build=y --update --deep --newuse @world

step "GURU overlay (sys-boot/zfsbootmenu, and app-misc/glow in unity-apps.list, are only there)"
emerge --quiet-build=y --noreplace app-eselect/eselect-repository dev-vcs/git
repos="$(eselect repository list -i)"   # captured first: grep -q in a pipe can SIGPIPE the writer (pipefail)
grep -qw 'guru' <<<"$repos" || eselect repository enable guru
emaint sync -r guru

step "Installing kernel, ZFS, firmware, ZFSBootMenu and base tools"
emerge --quiet-build=y --noreplace \
    sys-kernel/linux-firmware sys-kernel/gentoo-kernel-bin \
    sys-fs/zfs sys-kernel/dracut sys-boot/zfsbootmenu sys-boot/efibootmgr \
    sys-fs/dosfstools sys-fs/btrfs-progs net-misc/networkmanager app-admin/sudo \
    sys-process/cronie app-admin/sysklogd net-misc/chrony \
    app-editors/vim app-portage/gentoolkit dev-vcs/git app-misc/tmux \
    net-vpn/tor net-analyzer/nmap net-analyzer/tcpdump app-misc/byobu \
    app-shells/bash-completion sys-process/lsof sys-process/htop sys-process/atop sys-apps/pciutils \
    sys-apps/lshw app-admin/logrotate sys-apps/bolt sys-fs/sanoid sys-apps/fwupd \
    ${SWAP_PARTUUID:+sys-fs/cryptsetup}   # the swap partition's encryption (dmcrypt service)

step "System files of this project (deploy, group base)"
# After the packages, so sanoid.conf and ZFSBootMenu's config.yaml replace the packages' examples
# (written earlier, Portage would keep ours and leave the examples as ._cfg files to merge).
/tmp/gentoo-laptop/deploy --yes --group base

step "Locale and default editor"
locale-gen
eselect locale set "${LOCALE/UTF-8/utf8}"
# vim for sudoedit, crontab -e, git...: without EDITOR the editor wrapper falls back to nano,
# which is not installed (the file eselect editor manages, same format)
echo 'EDITOR="/usr/bin/vim"' > /etc/env.d/99editor
env-update
# homes readable by the other users (to share files), like the first user's below: shadow's
# HOME_MODE, set explicitly (useradd -m and the desktop's User Accounts panel use it; unset, it
# follows UMASK). For private homes use 0700 here and in the chmod below.
if grep -qE '^#?[[:space:]]*HOME_MODE' /etc/login.defs; then
    sed -i -E 's/^#?[[:space:]]*HOME_MODE.*/HOME_MODE\t0755/' /etc/login.defs
else
    printf 'HOME_MODE\t0755\n' >> /etc/login.defs
fi

step "Rebuilding the initramfs with ZFS, then checking it (zfs in it, no pool key)"
emerge --config sys-kernel/gentoo-kernel-bin
# Newest kernel that has a modules directory (ignores installkernel's *.old backups)
kver="$(for d in /lib/modules/*; do v="${d##*/}"; if [ -e "/boot/vmlinuz-$v" ]; then echo "$v"; fi; done | sort -V | tail -n1)"
[ -n "$kver" ] || { echo "FAILED (chroot): no installed kernel found in /boot"; exit 1; }
initrd="/boot/initramfs-$kver.img"
listing="$(lsinitrd "$initrd")"   # captured first: grep -q in a pipe would trip pipefail
grep -q '/zfs\.ko' <<<"$listing" || { echo "FAILED (chroot): zfs module missing from $initrd"; exit 1; }
! grep -qE 'etc/zfs/[^ ]*\.key$' <<<"$listing" || { echo "FAILED (chroot): a pool key file is in $initrd"; exit 1; }
# root only all the same (files/initramfs-private, an installkernel hook deployed above)
[ "$(stat -c %a "$initrd")" = 600 ] || { echo "FAILED (chroot): $initrd is readable by other users"; exit 1; }
echo "initramfs for $kver contains zfs and no pool key"
# sys-fs/zfs re-installed the kernel during the package step, before deploy put our dracut config
# in place: that image (dracut's defaults - host-only, no pool key, a copy of the then passwordless
# /etc/shadow) is now installkernel's *.old backup of this kernel. Stale, so removed.
rm -f /boot/*.old

step "Enabling services"
add() { if [ -e "/etc/init.d/$1" ]; then rc-update add "$1" "$2" || true; else echo "skipped $1 (not installed)"; fi; }
add zfs-import boot
add zfs-mount boot
add zfs-zed default
add elogind boot
add dbus default
add NetworkManager default
add sshd default
add cronie default
add sysklogd default
add chronyd default
add boltd default          # Thunderbolt/USB4 device authorization (docks)
add atop default           # every process once a minute, 28 days (files/atop.default)
[ -z "$SWAP_PARTUUID" ] || add dmcrypt boot   # the swap partition, opened with a random key

step "Creating user $USERNAME"
if ! id "$USERNAME" >/dev/null 2>&1; then
    groups=""
    for g in wheel audio video usb input; do
        getent group "$g" >/dev/null && groups="${groups:+$groups,}$g"
    done
    useradd -M -s /bin/bash -G "$groups" "$USERNAME"
fi
cp -rT /etc/skel "/home/$USERNAME"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
chmod 755 "/home/$USERNAME"   # HOME_MODE above
chown "$USERNAME:$USERNAME" /home/storage && chmod 755 /home/storage   # the gentoo/storage dataset
# SSH: keys only (files/sshd-keys-only.conf, deployed above); the live session's key, if any
if [ -s /tmp/live-authorized_keys ]; then
    install -d -m 700 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.ssh"
    install -m 600 -o "$USERNAME" -g "$USERNAME" /tmp/live-authorized_keys "/home/$USERNAME/.ssh/authorized_keys"
    rm -f /tmp/live-authorized_keys
    echo "SSH: keys only; $(grep -c '^ssh-\|^ecdsa-\|^sk-' "/home/$USERNAME/.ssh/authorized_keys" || true) key(s) from the live session for $USERNAME"
else
    echo "SSH: keys only; no key for $USERNAME yet (the install did not run over SSH with a key) - add one at the console"
fi
ssh-keygen -A >/dev/null   # host keys now rather than at sshd's first start: sshd -T needs them
eff="$(sshd -T 2>&1 | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|authenticationmethods) ' | sort | paste -sd' ' || true)"
if [ "$eff" = "authenticationmethods publickey kbdinteractiveauthentication no passwordauthentication no permitrootlogin no" ]; then
    echo "SSH: sshd's settings checked (sshd -T): $eff"
else
    echo "WARNING: sshd is not keys-only - sshd -T says: ${eff:-nothing}"
fi
command -v sudo >/dev/null || emerge --quiet-build=y --noreplace app-admin/sudo
mkdir -p /etc/sudoers.d
chmod 750 /etc/sudoers.d
grep -Eq '^[@#]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers \
    || echo '@includedir /etc/sudoers.d' >> /etc/sudoers
[ -f /etc/sudoers.d/wheel ] || { echo "FAILED (chroot): /etc/sudoers.d/wheel was not deployed"; exit 1; }
visudo -c
# root gets locked below, so prove that the sudo rule is really in effect first
perms="$(sudo -l -U "$USERNAME" 2>&1 || true)"
grep -q '(ALL *: *ALL) ALL' <<<"$perms" || { echo "FAILED (chroot): sudo rule for $USERNAME is not effective:"; echo "$perms"; exit 1; }
echo "sudo is effective for $USERNAME"
passwd -l root          # no root password: use sudo (or ZFSBootMenu's recovery shell)

step "Building ZFSBootMenu from the installed kernel, ZFS and dracut"
# (config: files/zfsbootmenu-config.yaml and the key-injection hooks, deployed above; update-zbm
# says whether the image holds the hooks - check-install.sh shows that line)
for h in load-key.d/50-key-injection boot-sel.d/90-key-injection; do
    [ -x "/etc/zfsbootmenu/hooks/$h" ] || { echo "FAILED (chroot): /etc/zfsbootmenu/hooks/$h missing - deploy"; exit 1; }
done
/usr/local/sbin/update-zbm

[ -e /efi/EFI/zbm/vmlinuz.EFI ] || { echo "FAILED (chroot): ZFSBootMenu image was not created"; exit 1; }
# Keep a ZFSBootMenu entry only if it points at THIS EFI partition. A reinstall creates a
# new partition with a new GUID, so an entry left over from an earlier install is stale.
esp_partuuid="$(blkid -s PARTUUID -o value "$(findmnt -n -o SOURCE /efi)")"
[ -n "$esp_partuuid" ] || { echo "FAILED (chroot): cannot read the EFI partition's GUID"; exit 1; }
entries="$(efibootmgr)"
found=0
while read -r b; do
    line="$(grep "^Boot$b" <<<"$entries")"
    if grep -qi "$esp_partuuid" <<<"$line"; then
        found=1; echo "ZFSBootMenu boot entry Boot$b already points at this EFI partition"
    else
        echo "removing stale ZFSBootMenu entry Boot$b (points at a partition that no longer exists)"
        efibootmgr -q -b "$b" -B
    fi
done < <(sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\} ZFSBootMenu.*/\1/p' <<<"$entries")
if [ "$found" = 0 ]; then
    efibootmgr --create --disk "$DISK_DEV" --part 1 --label "ZFSBootMenu" \
        --loader '\EFI\zbm\vmlinuz.EFI'
fi
efibootmgr
CHROOT

rm -rf "$TARGET/tmp/gentoo-laptop"   # the copy of deploy used in the chroot
if [ -n "$SWAP_PARTUUID" ]; then
    step "Encrypted swap partition"
    swap_setup
fi

step "This checkout in $USERNAME's home (for install-unity.sh and later ./deploy)"
if [ -e "$TARGET/home/$USERNAME/gentoo-laptop" ]; then
    echo "/home/$USERNAME/gentoo-laptop exists - left as it is"
else
    cp -a "$HERE" "$TARGET/home/$USERNAME/gentoo-laptop"
    chroot "$TARGET" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/gentoo-laptop"
    echo "copied to /home/$USERNAME/gentoo-laptop (owned by $USERNAME)"
fi

step "Setting the password for $USERNAME"
printf '%s:%s\n' "$USERNAME" "$USER_PW" | chroot "$TARGET" chpasswd
unset USER_PW

### Cleanup #####################################################################
step "Unmounting and exporting the pool"
cp "$LOG" "$TARGET/root/" || true
cd /
umount -l -R "$TARGET/dev" "$TARGET/sys" "$TARGET/proc" "$TARGET/run"
umount "$TARGET/efi"
zfs umount -a
zpool export "$POOL"

cat <<EOF

Done. Log: $LOG
Next:
  1. Make sure Secure Boot is disabled, then reboot and remove the USB stick.
  2. ZFSBootMenu asks for the pool passphrase once, then boots $POOL/ROOT/default.
  3. Log in as $USERNAME (root is locked; use sudo). Connect Wi-Fi with: sudo nmtui
  4. After any ZFS (or kernel) update, run: sudo update-zbm
     Never run 'zpool upgrade' before ZFSBootMenu has been rebuilt.
  5. Tor is installed but not started; enable it with: sudo rc-update add tor default
  6. For the desktop: cd ~/gentoo-laptop && sudo bash install-unity.sh   (this checkout, copied there)
     After changing files/ later: sudo ./deploy (from the checkout)
  7. Later, to update the whole system: sudo world-update
EOF
[ -z "$TZ_NOTE" ] || printf '\n%s\n' "$TZ_NOTE"
