#!/bin/bash
# install-unity.sh - Unity7 desktop for the Gentoo system made by install-gentoo.sh:
#   * gentoo-unity7 overlay with its (experimental) OpenRC profile
#   * minimal Unity (core desktop + fonts), LightDM login with Unity's greeter
#   * PipeWire audio (with Bluetooth), BlueZ, Xorg on amdgpu
#   * redock-watch: puts windows back where they were after re-docking
#   * the applications listed in unity-apps.list (optional, next to this script)
#   * this project's desktop files (redock-watch, tribler-tray, ...) via ./deploy
#
# Run on the installed system, inside the gentoo-laptop checkout:   sudo bash install-unity.sh
# Safe to re-run after a failure: finished steps are quick. Repositories are synced at
# most once per 24 hours. Snapshots of the system and your home are taken first.

set -Eeuo pipefail
USERNAME="${USERNAME:-${SUDO_USER:-}}"   # the desktop user: whoever ran sudo
LOG="/root/install-unity.log"
STAMP="pre-unity-$(date +%Y%m%d-%H%M)"
HERE="${HERE:-$(dirname "$(readlink -f "$0")")}"   # the checkout: deploy, deploy.list, files/
APPS_LIST="${APPS_LIST:-$HERE/unity-apps.list}"
STAMPDIR="/var/lib/install-unity"

die()  { echo "ERROR: $*" >&2; exit 1; }
[ -x "$HERE/deploy" ] && [ -f "$HERE/deploy.list" ] && [ -d "$HERE/files" ] \
    || die "run this from the gentoo-laptop checkout: deploy, deploy.list and files/ must be next to it"
step() { printf '\n\033[1;32m>>> %s\033[0m\n' "$*"; }

# Container images: a dataset per user under $POOL/containers (canmount=off; never snapshotted),
# mounted at /var/lib/containers/USER - outside the home, so backups of /home do not copy
# re-downloadable images. /etc/containers/storage.conf (deploy, group tribler) points rootless
# Podman there. Safe to run again; refuses the older layout (the parent itself mounted).
containers_dataset() {   # containers_dataset USER
    local parent="$POOL/containers" child="$POOL/containers/$1" dir="/var/lib/containers/$1"
    if zfs list -H -o name "$parent" >/dev/null 2>&1; then
        if [ "$(zfs get -H -o value canmount "$parent")" != off ]; then
            # older layout: one store, its owner's - not necessarily $1 (the account hook calls
            # this for later users too): the owner of its mounted directory
            local owner
            owner="$(stat -c %U "$(zfs get -H -o value mountpoint "$parent")" 2>/dev/null)" || owner=""
            case "$owner" in ""|root|UNKNOWN) owner=OWNER ;; esac   # OWNER: whose images it holds
            die "$parent is mounted itself (older layout, $owner's images). Convert it:" \
                "zfs rename $parent $POOL/containers-old;" \
                "zfs create -o canmount=off -o mountpoint=/var/lib/containers" \
                "-o com.sun:auto-snapshot=false $parent;" \
                "zfs rename $POOL/containers-old $POOL/containers/$owner;" \
                "zfs inherit mountpoint $POOL/containers/$owner${CONVERT_THEN:-}"
        fi
    else
        zfs create -o canmount=off -o mountpoint=/var/lib/containers \
            -o com.sun:auto-snapshot=false "$parent"
    fi
    zfs list -H -o name "$child" >/dev/null 2>&1 || zfs create "$child"
    chown "$1:$1" "$dir"
    chmod 700 "$dir"
}
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -n "$USERNAME" ] && [ "$USERNAME" != root ] \
    || die "run it with sudo from your own account (or set USERNAME=yourname)"
HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
[ -d "$HOME_DIR" ] || die "no home directory for $USERNAME"
ROOT_DS="$(findmnt -n -o SOURCE /)"
POOL="${ROOT_DS%%/*}"
zfs list -H -o name "$ROOT_DS" >/dev/null 2>&1 || die "/ is not a ZFS dataset ($ROOT_DS)"

exec > >(tee -a "$LOG") 2>&1
echo "Unity install started $(date -Is) on $ROOT_DS for $USERNAME"

conf() {    # conf KIND NAME: write stdin to /etc/portage/KIND/NAME (append if KIND is a file)
    local d="/etc/portage/$1"
    if [ -f "$d" ]; then cat >> "$d"; else mkdir -p "$d"; cat > "$d/$2"; fi
}
gentoo_tree_fresh() {   # Gentoo tree snapshot younger than 24 h (any sync method counts)
    local f=/var/db/repos/gentoo/metadata/timestamp.chk t
    [ -r "$f" ] || return 1
    t="$(date -d "$(head -n1 "$f")" +%s 2>/dev/null)" || return 1
    [ $(( $(date +%s) - t )) -lt 86400 ]
}
sync_once_a_day() {     # sync_once_a_day REPO
    if [ "$1" = gentoo ] && gentoo_tree_fresh; then
        echo "Gentoo tree is less than 24 h old - not syncing"; return 0
    fi
    if [ "$1" != gentoo ] && [ -n "$(find "$STAMPDIR/sync-$1" -mmin -1440 2>/dev/null)" ]; then
        echo "repository $1 was synced less than 24 h ago - not syncing"; return 0
    fi
    emaint sync -r "$1"
    mkdir -p "$STAMPDIR" && touch "$STAMPDIR/sync-$1"
}

### Safety net ##################################################################
step "Snapshots ($STAMP)"
snaps=("$ROOT_DS@$STAMP")
zfs list -H -o name "$POOL/home/$USERNAME" >/dev/null 2>&1 && snaps+=("$POOL/home/$USERNAME@$STAMP")
zfs snapshot "${snaps[@]}"
echo "To undo: pick snapshot @$STAMP in ZFSBootMenu's snapshot menu."

### Portage settings ############################################################
step "Portage settings"
conf package.use unity <<'EOF'
# Xorg: radeonsi on xorg-drivers pulls the legacy ATI X driver; the Radeon 780M uses amdgpu
x11-base/xorg-drivers -video_cards_radeonsi
# PipeWire is the sound server, including Bluetooth audio
media-video/pipewire sound-server bluetooth
# Minimal Unity: core desktop and its fonts only (no app/game/GNOME/accessibility bundles)
unity-base/unity-meta -accessibility -apps -extra -games -gnome
unity-base/unity-control-center -accessibility -sharing -kerberos -gnome-online-accounts -v4l
# Clock indicator without calendar events (avoids Evolution Data Server)
unity-indicators/indicator-datetime -eds
# Zoom talks to PipeWire through the PulseAudio API (only used if Zoom is in the app list)
net-im/zoom pulseaudio
# CUPS finds network printers through Avahi (DNS-SD); only used if printing is in the app list
net-print/cups zeroconf
EOF
conf package.license unity <<'EOF'
x11-themes/ubuntu-unity-backgrounds CC-BY-NC-SA-4.0
net-im/zoom *
www-client/google-chrome google-chrome
EOF
conf package.accept_keywords unity <<'EOF'
net-im/zoom ~amd64
app-misc/glow ~amd64
EOF

step "System files of this project (deploy, group desktop)"
# From this checkout (deploy.list): ehooks-from-source, the GNOME Text Editor patch (Gentoo applies
# /etc/portage/patches/<category>/<package>/ when that package is built from source), redock-watch
# and its autostart entry. Later changes: edit files/, then sudo ./deploy in the checkout.
"$HERE/deploy" --yes --group desktop

### Overlay #####################################################################
step "gentoo-unity7 overlay"
emerge --quiet-build=y --noreplace app-eselect/eselect-repository dev-vcs/git
repos="$(eselect repository list -i)"   # captured first: grep -q in a pipe can SIGPIPE the writer (pipefail)
grep -q 'gentoo-unity7' <<<"$repos" || eselect repository enable gentoo-unity7
sync_once_a_day gentoo-unity7
repo="$(portageq get_repo_path / gentoo-unity7)"
echo "overlay at $repo (its ehooks patches are in $repo/profiles/ehooks/)"

step "OpenRC profile of the overlay"
prof="$(eselect profile list | grep -o 'gentoo-unity7:[^ ]*/unity/openrc' | head -n1 || true)"
[ -n "$prof" ] || die "OpenRC profile not found; check: eselect profile list | grep unity"
eselect profile set "$prof"
eselect profile show

step "Accepting ehooks (overlay patches applied to Gentoo packages)"
grep -q '^ACCEPT_EHOOKS="yes"' /etc/portage/make.conf \
    || printf '\n# gentoo-unity7: allow overlay patches (ehooks) on Gentoo packages\nACCEPT_EHOOKS="yes"\n' >> /etc/portage/make.conf

step "Packages patched by the overlay (or by us) are always built from source"
# The overlay patches packages while they compile; a prebuilt binary package skips those patches
# (that broke overlay-scrollbar before). The helper lists every package with a src_* phase hook
# in the overlay's ehooks/, plus local patches, and keeps make.conf's --usepkg-exclude in step;
# world-update runs it after every sync. Its first version here was a hand-made list that missed
# glib, gtk+:3, nm-applet, nemo, lightdm and more.
/usr/local/sbin/ehooks-from-source
excl="$(paste -sd' ' /etc/portage/ehooks-from-source)"

step "Unity build environment"
emerge --quiet-build=y --noreplace gentoo-unity-env

step "Rebuilding already-installed patched packages from source"
emerge --quiet-build=y --oneshot --usepkg-exclude "$excl" @ehooks-rebuild

step "Gentoo tree: sync if older than a day (binary packages are built from the current tree)"
sync_once_a_day gentoo

step "Updating @world for the new profile"
emerge --quiet-build=y -uDU --with-bdeps=y @world @ehooks-rebuild

### Desktop #####################################################################
step "Installing Unity, LightDM, Xorg, PipeWire, BlueZ and the re-dock tools"
# Unity's core needs one text editor (pluma, gedit or GNOME Text Editor) and Portage takes the
# first unless one is installed: put ours in first, or pluma comes along and is left for
# depclean once the app list installs GNOME Text Editor (seen on a clean install).
emerge --quiet-build=y --noreplace app-editors/gnome-text-editor
emerge --quiet-build=y -uDU --with-bdeps=y \
    unity-meta unity-greeter x11-misc/lightdm \
    x11-base/xorg-server x11-apps/xinit \
    media-video/pipewire media-video/wireplumber net-wireless/bluez \
    x11-apps/xev x11-apps/xprop x11-apps/xrandr x11-misc/wmctrl
if [ -f /usr/include/gtk-2.0/gtk/gtkmain.h ]; then
    grep -q ubuntu_gtk_get_use_overlay_scrollbar /usr/include/gtk-2.0/gtk/gtkmain.h \
        || die "gtk+:2 lacks the overlay's patches (it must be built from source)"
fi

step "Applications from $APPS_LIST"
apps=()
if [ -f "$APPS_LIST" ]; then
    while read -r line; do
        line="${line%%#*}"
        read -ra atoms <<<"$line"
        [ "${#atoms[@]}" -gt 0 ] && apps+=("${atoms[@]}")
    done < "$APPS_LIST"
fi
ok=()
for a in "${apps[@]}"; do      # a typo or an unavailable package should not stop the install
    if [ -n "$(portageq best_visible / ebuild "$a" 2>/dev/null)" ]; then ok+=("$a")
    else echo "WARNING: $a is not available (wrong name, masked or missing) - skipped"; fi
done
if [ "${#ok[@]}" -gt 0 ]; then
    echo "installing: ${ok[*]}"
    emerge --quiet-build=y -uDU --with-bdeps=y --noreplace "${ok[@]}"
else
    echo "no applications to install"
fi

### Login, services, user #######################################################
step "LightDM with Unity's greeter as the graphical login"
session=""
for f in /usr/share/xsessions/unity*.desktop; do
    [ -e "$f" ] && { session="$(basename "$f" .desktop)"; break; }
done
[ -n "$session" ] || die "no Unity session file in /usr/share/xsessions"
echo "Unity session: $session"
# Fallback for a text console if the graphical login ever fails: startx /usr/local/share/unity-xinitrc
# (-D: a fresh Gentoo has no /usr/local/share - baselayout makes only bin and sbin)
[ -f "$repo/unity-base/unity/files/xinitrc" ] \
    && install -D -m 755 "$repo/unity-base/unity/files/xinitrc" /usr/local/share/unity-xinitrc
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-unity.conf <<EOF
[Seat:*]
greeter-session=unity-greeter
user-session=$session
EOF
sed -i 's/^DISPLAYMANAGER=.*/DISPLAYMANAGER="lightdm"/' /etc/conf.d/display-manager
grep -q '^DISPLAYMANAGER="lightdm"' /etc/conf.d/display-manager \
    || echo 'DISPLAYMANAGER="lightdm"' >> /etc/conf.d/display-manager

step "Services"
svc() { if [ -e "/etc/init.d/$1" ]; then rc-update add "$1" "$2" || true; else echo "skipped $1 (not installed)"; fi; }
svc bluetooth default
svc display-manager default
svc cupsd default            # only if printing is in the app list
svc avahi-daemon default     # network printer discovery (only if Avahi is in the app list)

step "Name resolution for .local hosts (network printers announce themselves as name.local)"
if ls /usr/lib*/libnss_mdns_minimal.so* >/dev/null 2>&1; then
    # Look at the hosts line only: glibc's stock file mentions mdns in a comment, which made this
    # step skip itself and left .local names unresolvable.
    if grep -q '^hosts:.*mdns' /etc/nsswitch.conf; then
        echo "the hosts line already uses mdns"
    else
        sed -i -E 's/^(hosts:[[:space:]]+files)/\1 mdns_minimal [NOTFOUND=return]/' /etc/nsswitch.conf
    fi
    grep '^hosts:' /etc/nsswitch.conf
    grep -q '^hosts:.*mdns' /etc/nsswitch.conf \
        || die "could not add mdns_minimal to the hosts line of /etc/nsswitch.conf (shown above)"
else
    echo "nss-mdns not installed - skipped"
fi

step "Groups for $USERNAME"
# plugdev: Bluetooth and network settings, kvm: QEMU acceleration, lpadmin: printer admin
for g in plugdev kvm lpadmin; do
    if getent group "$g" >/dev/null; then gpasswd -a "$USERNAME" "$g"; else echo "no $g group - skipped"; fi
done

step "Podman (rootless) and the Tribler indicator - only if Podman is in the app list"
if command -v podman >/dev/null; then
    # rootless containers need subordinate user/group id ranges for your account
    grep -q "^$USERNAME:" /etc/subuid || usermod --add-subuids 100000-165535 "$USERNAME"
    grep -q "^$USERNAME:" /etc/subgid || usermod --add-subgids 100000-165535 "$USERNAME"
    # cgroup v2 ("unified"), which Podman expects; takes effect at the next boot
    if grep -qE '^#?rc_cgroup_mode=' /etc/rc.conf; then
        sed -i -E 's/^#?rc_cgroup_mode=.*/rc_cgroup_mode="unified"/' /etc/rc.conf
    else
        echo 'rc_cgroup_mode="unified"' >> /etc/rc.conf
    fi
    containers_dataset "$USERNAME"   # images in /var/lib/containers/USER, outside the home
    # the indicator: Python GObject bindings + the tray script, started in Unity sessions
    emerge --quiet-build=y --noreplace dev-python/pygobject
    "$HERE/deploy" --yes --group tribler   # tribler-tray, its autostart entry, storage.conf
    echo "Tribler: use the panel indicator (first Start downloads the official image)"
else
    echo "Podman not installed - skipped"
fi

### Report ######################################################################
step "Checks"
echo "--- packages emerge --depclean would remove. Expected: only what the desktop stage3 brought and"
echo "    this system no longer needs - app-editors/nano, dev-util/mesa_clc and its LLVM/clang chain"
echo "    (seen on a clean install). Anything else is worth a look before running depclean."
emerge --depclean --pretend 2>/dev/null | grep -E '^ +[a-z0-9-]+/' || echo "    none"
echo "--- your world file (packages you asked for):"
cat /var/lib/portage/world
echo "--- name resolution for .local hosts (hosts line of /etc/nsswitch.conf):"
grep '^hosts:' /etc/nsswitch.conf
echo "--- services in the default runlevel:"
rc-update show default

cat <<EOF

Done. Log: $LOG
Reboot: ZFSBootMenu asks for the pool passphrase, then the Unity login screen appears.
If the login screen fails: Ctrl+Alt+F2, log in, and start Unity by hand with
  startx /usr/local/share/unity-xinitrc
then look for the reason in /var/log/lightdm/lightdm.log.
EOF
