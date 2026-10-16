#!/usr/bin/env bash
#
#==============================================================================
# el10-zbm-install-testing.sh
#
#   Rocky Linux 10 / AlmaLinux 10, root on encrypted ZFS, rEFInd -> ZFSBootMenu.
#   TESTING VARIANT: installs every ZFSBootMenu binary image you ask for
#   (release + recovery, Linux 6.6 / 6.12 / 6.18) side by side, plus a backup
#   copy of each release image, so you can find out empirically which one
#   drives your hardware.
#
#   This is the Enterprise Linux sibling of debian13-zbm-install-testing.sh.
#   Same ESP layout, same testing philosophy, same ZFS dataset tree; the whole
#   distro-facing half is different.
#==============================================================================
#
# Based on:
#   https://docs.zfsbootmenu.org/en/v3.1.x/guides/almalinux/uefi.html
#   (encrypted variant, rEFInd boot-entry variant)
#
# Guide steps are tagged [GUIDE]; departures are tagged [DEVIATION];
# things that exist only because this is EL and not Debian are tagged [EL].
#
#------------------------------------------------------------------------------
# WHAT CHANGED COMING FROM THE DEBIAN SCRIPT
#------------------------------------------------------------------------------
#   initramfs-tools   -> dracut            (/etc/dracut.conf.d/zol.conf)
#   apt / debootstrap -> dnf --installroot (groupinstall "Minimal Install")
#   sources.list      -> dnf repos: baseos/appstream + CRB + EPEL + zfsonlinux
#   zfs-dkms          -> zfs + zfs-dracut  (DKMS by default, kmod optional)
#   initramfs key     -> dracut install_items+=" /etc/zfs/zroot.key "
#   intel/amd-microcode -> microcode_ctl   (one package, both vendors)
#   firmware-*        -> linux-firmware    (one package)
#   systemd-timesyncd -> chrony
#   console-setup     -> /etc/vconsole.conf + /etc/X11/xorg.conf.d/00-keyboard.conf
#   (nothing)         -> SELinux: relabel the whole tree before first boot
#   (nothing)         -> dnf5 on EL10: `config-manager setopt`, `--use-host-config`
#   refind package    -> upstream RPM/zip; EL has no rEFInd package at all
#
# The biggest practical difference is SELinux. A file tree assembled by
# dnf --installroot into a chroot gets labels from the host's policy, or no
# labels at all. Boot that unlabelled and systemd lands you in an emergency
# shell with a screenful of AVC denials. So this script relabels at the end of
# the chroot stage AND drops /.autorelabel as a second chance.
#
#------------------------------------------------------------------------------
# ALMALINUX 10 vs ROCKY LINUX 10 -- ONE SCRIPT COVERS BOTH
#------------------------------------------------------------------------------
# Everything this installer touches is identical on the two. Specifically:
#
#   same : repository layout (BaseOS / AppStream / CRB, repo id 'crb'),
#          epel-release available from extras, dnf5, dracut, SELinux policy,
#          package names for the kernel, ZFS, GNOME, KDE and everything else,
#          systemd unit names, group names (wheel), bootloader situation
#   differ: $ID in /etc/os-release -> 'almalinux' vs 'rocky'
#           the distro release package -> almalinux-release vs rocky-release
#           the live ISO you boot
#           AlmaLinux additionally publishes an x86_64_v2 build for CPUs that
#           predate RHEL 10's x86_64-v3 baseline; Rocky 10 is v3 only
#
# The script reads $ID from the live environment and uses it for both the
# release package and the boot environment name, so booting an Alma live image
# gives you zroot/ROOT/almalinux and a Rocky one gives zroot/ROOT/rocky. That
# is the ONLY difference in the result. Override with DISTRO_ID= if you are
# installing one from the other's live media.
#
#   AlmaLinux 10 live:
#     https://repo.almalinux.org/almalinux/10/live/x86_64/AlmaLinux-10-latest-x86_64-Live-GNOME.iso
#   Rocky Linux 10 live:
#     https://download.rockylinux.org/pub/rocky/10/live/x86_64/
#
# If you are on an older CPU, take AlmaLinux's x86_64_v2 media -- Rocky 10 has
# no equivalent and will not boot on pre-v3 hardware.
#
#------------------------------------------------------------------------------
# WHICH ZBM IMAGE IS THE RIGHT ONE? THAT IS YOUR JOB.
#------------------------------------------------------------------------------
# All ZFSBootMenu v3.1.0 binary images embed the SAME OpenZFS (2.4.0). The only
# difference between the 6.6, 6.12 and 6.18 builds is the Linux kernel, i.e.
# HARDWARE SUPPORT -- NVMe controllers, RAID HBAs, GPUs, USB controllers.
# Picking a different kernel does NOT change ZFS capability or feature-flag
# compatibility.
#
# So: install several, boot each once, and keep whichever reaches the menu
# fastest and most reliably. This script deliberately makes no claim about
# which will work on your machine, and none of them is marked "correct".
#
#   release  = normal ZFSBootMenu image
#   recovery = same, plus networking, curl, sgdisk, cryptsetup, an SSH client.
#              This is the one that turns "go find a live USB" into
#              "pick the next menu entry". Install at least one.
#   backup   = byte-identical copy of each release image, kept in its own
#              directory so a botched in-place update cannot take out both.
#
# NOTE ON OpenZFS VERSION: this script installs the NEWEST OpenZFS branch, not
# the conservative one. zfs-release leaves the 'zfs' repo enabled, which on EL
# is the old maintenance branch (2.2.x); ZFS_BRANCH=latest switches to
# 'zfs-latest' instead, which is 2.4.x. The ZBM v3.1.0 images embed OpenZFS
# 2.4.0, so userland and boot images are on the same major branch and the pool
# is created with NO compatibility pin -- every feature your installed zfs
# supports is enabled. Set POOL_COMPATIBILITY or ZFS_BRANCH if you want the
# cautious version back.
#
#------------------------------------------------------------------------------
# ESP LAYOUT (this is what makes rEFInd behave)
#------------------------------------------------------------------------------
# rEFInd auto-detects files named vmlinuz*/bzImage*/kernel* as Linux kernels,
# and fold_linux_kernels (default true) collapses every kernel found IN THE
# SAME DIRECTORY into ONE menu tag -- picking as primary whichever filename
# version-sorts highest. That is why an install with VMLINUZ.EFI and
# VMLINUZ-BACKUP.EFI in one directory shows only the backup: "-BACKUP" sorts
# above the empty string.
#
# Folding is per-directory, so one directory per image sidesteps it entirely
# while keeping the vmlinuz name that triggers autodetection:
#
#   /boot/efi/EFI/ZBM-6.6/vmlinuz.EFI            + refind_linux.conf
#   /boot/efi/EFI/ZBM-6.12/vmlinuz.EFI           + refind_linux.conf
#   /boot/efi/EFI/ZBM-6.18/vmlinuz.EFI           + refind_linux.conf
#   /boot/efi/EFI/ZBM-RECOVERY-6.6/vmlinuz.EFI   + refind_linux.conf
#   /boot/efi/EFI/ZBM-RECOVERY-6.12/vmlinuz.EFI  + refind_linux.conf
#   /boot/efi/EFI/ZBM-RECOVERY-6.18/vmlinuz.EFI  + refind_linux.conf
#   /boot/efi/EFI/ZBM-BACKUP/vmlinuz-6.6.EFI
#                            vmlinuz-6.12.EFI    + refind_linux.conf
#                            vmlinuz-6.18.EFI
#
# The backups DO share a directory on purpose: they fold into a single tag so
# they do not clutter the menu. Press F2 or Insert on that entry to reach the
# individual ones.
#
#------------------------------------------------------------------------------
# [EL] THERE IS NO rEFInd PACKAGE ON ALMALINUX OR ROCKY LINUX. CHECKED.
#------------------------------------------------------------------------------
# Debian has a 'refind' package with a working refind-install. EL has nothing:
#
#   * The base repositories (BaseOS, AppStream, CRB) of both AlmaLinux 10 and
#     Rocky Linux 10 do not ship it. Red Hat only ships GRUB2 and shim.
#   * EPEL does not ship it either -- not on EPEL 10, and not on 8 or 9. The
#     Fedora package is named rEFInd (capitals, maintainers ngompa/dcavalca/
#     sentry) and its release table lists Fedora branches ONLY: Rawhide, 45,
#     44, 43. There is no epelN branch to rebuild from.
#       https://packages.fedoraproject.org/pkgs/rEFInd/rEFInd-tools/
#   * No Alma or Rocky extras/plus/devel repository carries it.
#
# So 'dnf install rEFInd' will fail on a stock Alma 10 or Rocky 10 box. rEFInd
# has to come from outside the distribution, in one of two upstream forms:
#
#   1. refind-bin-<ver>.zip        -- the binaries plus upstream's refind-install
#   2. refind-<ver>-1.x86_64.rpm   -- a real RPM whose %post runs refind-install
#
# THE ZIP IS THE BETTER CHOICE HERE, and it is the default. Why:
#
#   * Control. The zip is inert until you run refind-install yourself, so the
#     install happens at a point in this script where /boot/efi is mounted,
#     efivarfs is mounted and a failure is visible. The RPM runs refind-install
#     from a %post scriptlet in the middle of a dnf transaction; if that
#     scriptlet fails, dnf still reports success and you find out at reboot.
#   * No unsigned-package exception. The upstream RPM is not signed by anyone
#     your system trusts, so installing it means --nogpgcheck. The zip needs no
#     such hole because nothing is pretending it is a trusted package.
#   * No phantom rpmdb entry. An RPM that no repository will ever update is a
#     package the system believes it manages and cannot. If EPEL ever does ship
#     rEFInd, that stale entry is what you will be fighting.
#   * It is upstream's canonical form. rodsbooks' own documentation treats the
#     binary zip as the primary distribution and notes that distro packages
#     only place the files -- you still run refind-install afterwards.
#
# The RPM's single advantage is that 'rpm -q refind' answers yes. That is worth
# very little when nothing will ever update it. REFIND_SOURCE=rpm is kept for
# when you want it anyway; 'auto' tries the zip and then the RPM.
#
# If BOTH fail (no network, a mangled download, ...), the script falls back to
# direct EFI NVRAM entries via efibootmgr -- one per release and recovery
# image, which is exactly what the guide's "Direct" variant does, just more of
# them. That fallback always works and needs no third-party anything. It gives
# you your firmware's own boot menu instead of rEFInd's, which is uglier and
# has no per-entry sub-options, but it boots.
#
# DOWNLOAD SOURCE: both default URLs point at the gh4rib/trixie-zfs-installer
# GitHub release rather than SourceForge. GitHub serves the asset directly over
# a plain redirect; SourceForge answers with an HTML mirror-selection page often
# enough that the old defaults needed a 'is this actually a zip?' guard. The
# guard is still here, because a 404 or a proxy login page would look the same.
# Set REFIND_ZIP_SHA256 / REFIND_RPM_SHA256 if you want the download checked
# against a known digest instead of merely checked for being the right format.
#
#------------------------------------------------------------------------------
# Disk layout on $DISK (a /dev/disk/by-id/... path; GPT, fully wiped)
#------------------------------------------------------------------------------
#   -part1   2048 MiB (default)   ef00   ESP -> /boot/efi
#   -part2   1024 MiB          8309/8200 encrypted swap (plain dm-crypt default)
#   -part3   rest - 10 MiB        bf00   zroot
#
#------------------------------------------------------------------------------
# Usage
#------------------------------------------------------------------------------
#   Boot the Rocky 10 or AlmaLinux 10 LIVE image in UEFI mode, then:
#
#   sudo -i
#   DISK=/dev/disk/by-id/nvme-... ZBM_KERNELS=all ADMIN_USER=alireza \
#   TIMEZONE=Europe/Berlin DESKTOP=gnome ./el10-zbm-install-testing.sh
#
# Run with DISK unset to list candidate disks.
# Run with LIST_KEYBOARD=yes to list keyboard variants for your layout.
#
# THIS DESTROYS ALL DATA ON $DISK.
#==============================================================================

set -euo pipefail

#==============================================================================
# [EL] Identify the live environment
#==============================================================================
# The guide sources /etc/os-release and uses $ID both as the boot-environment
# name and to pick package names. Rocky gives ID=rocky, Alma gives
# ID=almalinux. $VERSION_ID is 10.x; dnf wants the major number.

LIVE_ID=""
LIVE_VERSION_ID=""
if [[ -r /etc/os-release ]]; then
	LIVE_ID="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")"
	LIVE_VERSION_ID="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}")"
fi
LIVE_MAJOR="${LIVE_VERSION_ID%%.*}"

#==============================================================================
# Keyboard detection from the live environment
#==============================================================================
# [EL] EL stores the X11/Wayland layout in /etc/X11/xorg.conf.d/00-keyboard.conf
# (written by localectl) and the console keymap in /etc/vconsole.conf. There is
# no /etc/default/keyboard. Read whichever of the two the live image has.

_LIVE_XKBLAYOUT=""
_LIVE_XKBVARIANT=""
if [[ -r /etc/X11/xorg.conf.d/00-keyboard.conf ]]; then
	_LIVE_XKBLAYOUT="$(awk -F'"' '/XkbLayout/{print $4; exit}'  /etc/X11/xorg.conf.d/00-keyboard.conf 2>/dev/null || true)"
	_LIVE_XKBVARIANT="$(awk -F'"' '/XkbVariant/{print $4; exit}' /etc/X11/xorg.conf.d/00-keyboard.conf 2>/dev/null || true)"
fi
if [[ -z "$_LIVE_XKBLAYOUT" && -r /etc/vconsole.conf ]]; then
	# Fall back to the console keymap. For the common layouts (us, de, fr, ...)
	# the console keymap name and the XKB layout name are the same string.
	_LIVE_XKBLAYOUT="$(. /etc/vconsole.conf 2>/dev/null; printf '%s' "${KEYMAP:-}")"
fi

XKB_LST="/usr/share/X11/xkb/rules/base.lst"

list_variants() {
	local layout="$1"
	if [[ ! -r "$XKB_LST" ]]; then
		echo "  (xkeyboard-config not installed; cannot list)" >&2
		return 0
	fi
	printf '  %-18s %s\n' "(none)" "standard layout for '${layout}'" >&2
	awk -v l="${layout}:" '
		/^! variant/ { f = 1; next }
		/^!/         { f = 0 }
		f && NF > 1 && $2 == l {
			name = $1; $1 = ""; $2 = ""; sub(/^ +/, "")
			printf "  %-18s %s\n", name, $0
		}' "$XKB_LST" >&2
	return 0
}

if [[ -n "${LIST_KEYBOARD:-}" ]]; then
	_l="${LIST_KEYBOARD}"
	[[ "$_l" == "yes" ]] && _l="${KEYMAP:-${_LIVE_XKBLAYOUT:-us}}"
	echo "Keyboard variants for layout '${_l}':" >&2
	list_variants "$_l"
	exit 0
fi

#==============================================================================
# CONFIGURATION
#==============================================================================

#--- Target disk (REQUIRED, /dev/disk/by-id/... whole-disk path) --------------
DISK="${DISK:-}"

#--- [EL] Distribution --------------------------------------------------------
# DISTRO_ID is what the installed system calls itself and, by default, the name
# of the boot environment (the guide uses zroot/ROOT/${ID}). Detected from the
# live image; override if you are installing Rocky from an Alma live ISO or the
# other way round.
DISTRO_ID="${DISTRO_ID:-${LIVE_ID:-rocky}}"
RELEASEVER="${RELEASEVER:-${LIVE_MAJOR:-10}}"

# The package group dnf installs into the empty root. "Minimal Install" is what
# the guide uses. @core is smaller and leaves out things you will want.
BASE_GROUP="${BASE_GROUP:-Minimal Install}"

#--- [EL] ZFS packaging -------------------------------------------------------
# The zfs-release RPM that configures the zfsonlinux.org repos and installs the
# signing key. zfs-release-3-0 is the current one for EL8-10 and is the only one
# that carries the branch-specific repo definitions used below. No fallback to
# an older release package: if this URL does not resolve, something is wrong
# with the network or the mirror and silently installing an ancient repo
# definition would only hide it.
ZFS_RELEASE_PKG="${ZFS_RELEASE_PKG:-zfs-release-3-0}"
ZFS_RELEASE_BASE="${ZFS_RELEASE_BASE:-https://zfsonlinux.org/epel}"

# WHICH OpenZFS BRANCH. This is the important one.
#
# zfs-release-3-0 defines several repo pairs, and the one it leaves ENABLED by
# default is the conservative 'zfs' repo, which on EL is the old maintenance
# branch (2.2.x at the time of writing). That is not what this rig wants.
#
#   latest : 'zfs-latest' -- the newest released OpenZFS, actively developed,
#            newest features. Upstream calls it stable; it simply has less
#            real-world mileage than legacy. Equivalent to Fedora's default
#            zfs repo. THIS IS THE DEFAULT HERE.
#   legacy : 'zfs-legacy' -- the previous released branch, still updated.
#   default: whatever zfs-release leaves enabled. The old maintenance branch.
#   2.4 / 2.3 / 2.2 (or any x.y): pin to that branch via the 'zfs-x.y' repos.
#
# Every option disables all other zfs* repos first, so dnf is never left
# choosing between two branches on its own.
ZFS_BRANCH="${ZFS_BRANCH:-latest}"

# dkms : rebuilt against whatever kernel you install. Survives kernel updates
#        at the cost of a build on every one. THIS IS THE DEFAULT and what the
#        guide uses -- and it is the right pairing with ZFS_BRANCH=latest,
#        because the kmod builds track the distribution kABI and the newest
#        branch is the most likely to outrun it.
# kmod : kABI-tracking prebuilt module. Much faster to install, but it tracks
#        the RHEL kABI and breaks the day a kernel update moves outside it.
ZFS_PKG_STYLE="${ZFS_PKG_STYLE:-dkms}"

# EL10 is new enough that the zfsonlinux EL10 packages have, at times, been
# unsigned. Set to yes only if dnf refuses them and you have decided you are
# fine with that.
ZFS_NOGPGCHECK="${ZFS_NOGPGCHECK:-no}"

#--- ZFSBootMenu image selection ----------------------------------------------
# Pinned, not "latest": a testing rig should be reproducible.
ZBM_VERSION="${ZBM_VERSION:-v3.1.0}"
ZBM_BASE_URL="${ZBM_BASE_URL:-https://github.com/zbm-dev/zfsbootmenu/releases/download}"

# Which Linux kernel series to install images for.
#   all            -> 6.6 6.12 6.18
#   "6.12"         -> just that one
#   "6.6 6.18"     -> any space-separated subset
ZBM_KERNELS="${ZBM_KERNELS:-all}"

# Install the recovery build alongside each release build. Strongly recommended:
# the recovery image has networking and disk tooling and can rescue the system
# without a live USB.
ZBM_RECOVERY="${ZBM_RECOVERY:-yes}"

# Keep a second copy of every release image under EFI/ZBM-BACKUP.
ZBM_BACKUP="${ZBM_BACKUP:-yes}"

# Which release image is copied to EFI/BOOT/BOOTX64.EFI as the removable-media
# fallback, for firmware that silently drops NVRAM boot entries. Must be one of
# the kernels you selected. Empty disables the fallback.
ZBM_FALLBACK_KERNEL="${ZBM_FALLBACK_KERNEL:-6.12}"

#--- [EL] Boot manager --------------------------------------------------------
# refind     : rEFInd menu in front of ZFSBootMenu (what the Debian script does)
# efibootmgr : no rEFInd at all; one firmware NVRAM entry per ZBM image, which
#              is the guide's "Direct" variant scaled up to a testing rig
BOOTLOADER="${BOOTLOADER:-refind}"

# Where rEFInd comes from when BOOTLOADER=refind. There is no distro package
# on Alma or Rocky (see the header), so every option here is upstream:
#   zip  : binary zip, run upstream's refind-install ourselves. THE DEFAULT,
#          and the one to use unless you have a specific reason not to.
#   rpm  : upstream RPM, %post does the install. Needs --nogpgcheck.
#   auto : zip, then rpm, then fall back to efibootmgr NVRAM entries
REFIND_SOURCE="${REFIND_SOURCE:-zip}"
REFIND_VERSION="${REFIND_VERSION:-0.14.2}"
REFIND_ASSET_BASE="${REFIND_ASSET_BASE:-https://github.com/gh4rib/trixie-zfs-installer/releases/download/rEFInd-${REFIND_VERSION}}"
REFIND_ZIP_URL="${REFIND_ZIP_URL:-${REFIND_ASSET_BASE}/refind-bin-${REFIND_VERSION}.zip}"
REFIND_RPM_URL="${REFIND_RPM_URL:-${REFIND_ASSET_BASE}/refind-${REFIND_VERSION}-1.x86_64.rpm}"
# Optional integrity check. Leave empty to skip; set to the sha256sum of the
# asset to have the download rejected if it does not match. Get them with:
#   sha256sum refind-bin-0.14.2.zip refind-0.14.2-1.x86_64.rpm
REFIND_ZIP_SHA256="${REFIND_ZIP_SHA256:-}"
REFIND_RPM_SHA256="${REFIND_RPM_SHA256:-}"

# Register NVRAM entries for every release/recovery image even when rEFInd went
# in fine. Harmless, and it means a firmware that refuses to chainload still
# reaches a menu. Costs you a long F-key boot list.
EFI_ENTRIES_ALWAYS="${EFI_ENTRIES_ALWAYS:-no}"

#--- rEFInd -------------------------------------------------------------------
# 30 seconds is long enough to read the menu and pick an image deliberately.
# Use 0 if you want rEFInd to wait indefinitely instead.
REFIND_TIMEOUT="${REFIND_TIMEOUT:-30}"
# Left EMPTY on purpose: no image is nominated as "the" default, so rEFInd
# highlights the first entry and lets you choose. Once you know which image
# your hardware likes, set this to a substring of its title, e.g.
# REFIND_DEFAULT="ZBM-6.12", or edit refind.conf afterwards.
REFIND_DEFAULT="${REFIND_DEFAULT:-}"

#--- Kernel command lines -----------------------------------------------------
# ZBM_CMDLINE     configures ZFSBootMenu's OWN kernel (via refind_linux.conf).
# KERNEL_CMDLINE  is org.zfsbootmenu:commandline, i.e. what ZBM hands to EL.
# Both verbose: 'quiet' and 'rhgb' appear nowhere, unlike the guide's default.
#
# [EL] rd.luks=0 is deliberate. dracut's crypt module reads /etc/crypttab and
# will happily try to unlock the swap volume from the initramfs -- where the
# keyfile (which lives on the not-yet-mounted ZFS root) does not exist, so it
# prompts for a passphrase that was never set and the boot stalls there.
# Root is ZFS and needs no LUKS at initramfs time, so switching the whole
# mechanism off early is the clean fix. systemd unlocks swap later, from the
# real root, where the key actually is.
ZBM_CMDLINE="${ZBM_CMDLINE:-loglevel=6}"
KERNEL_CMDLINE="${KERNEL_CMDLINE:-loglevel=6 systemd.show_status=yes rd.luks=0}"
# Seconds ZFSBootMenu waits on its own countdown before booting bootfs.
# 0 boots immediately, -1 waits forever.
ZBM_TIMEOUT="${ZBM_TIMEOUT:-30}"

#--- Partition sizes (MiB) ----------------------------------------------------
# 2048 by default: nine ZBM images run to roughly 650 MB, and you want headroom
# to add more without repartitioning. (The guide's 512 MiB ESP fits exactly one
# image and one backup; it is not enough for this script.)
ESP_SIZE_MIB="${ESP_SIZE_MIB:-2048}"
SWAP_SIZE_MIB="${SWAP_SIZE_MIB:-1024}"

#--- Swap ---------------------------------------------------------------------
# luks   : persistent LUKS2, unlocked from a random 512-byte keyfile that lives
#          on the encrypted root. Root is already open when crypttab is
#          processed, so it never prompts. Partition type 8309 (Linux LUKS),
#          which is what systemd expects to see on a real LUKS volume.
# random : plain dm-crypt, fresh key from $SWAP_RANDOM_SOURCE every boot.
#          Nothing survives a reboot. Partition type 8200 (Linux swap) --
#          typing it 8309 makes systemd-gpt-auto-generator try to unlock it as
#          LUKS, which fails and drags the real swap unit down with it.
#          THIS IS THE DEFAULT.
# none   : no swap partition at all
#
# Either way hibernation is not configured; the dracut resume module is omitted.
SWAP_MODE="${SWAP_MODE:-random}"
SWAP_RANDOM_SOURCE="${SWAP_RANDOM_SOURCE:-/dev/urandom}"
SWAP_CIPHER="${SWAP_CIPHER:-aes-xts-plain64}"
SWAP_KEYSIZE="${SWAP_KEYSIZE:-512}"
SWAP_MAPPER="${SWAP_MAPPER:-cswap}"

#--- ZFS ----------------------------------------------------------------------
POOL_NAME="${POOL_NAME:-zroot}"
# [GUIDE] The guide names the boot environment after $ID, e.g. zroot/ROOT/rocky.
BE_NAME="${BE_NAME:-${DISTRO_ID}}"
BASELINE_NAME="${BASELINE_NAME:-baseline}"
BASELINE_MODE="${BASELINE_MODE:-clone}"     # clone | send | none
ASHIFT="${ASHIFT:-12}"
COMPRESSION="${COMPRESSION:-lz4}"
ENCRYPTION_ALGO="${ENCRYPTION_ALGO:-aes-256-gcm}"
DATASET_TUNING="${DATASET_TUNING:-yes}"
# [DEVIATION] The guide sets compatibility=openzfs-2.3-linux as "a conservative
# choice". Empty here on purpose: with ZFS_BRANCH=latest the installed userland
# is the newest OpenZFS branch, and pinning the pool to an older feature set
# would throw away exactly what you asked for. The pool gets every feature the
# installed zfs supports.
#
# The thing this costs you: a pool created by a newer OpenZFS may enable
# features an older ZFSBootMenu image cannot read. ZBM v3.1.0 embeds 2.4.0, so
# as long as your installed zfs is 2.4.x you are fine. If you later downgrade
# ZBM images, or you pin ZFS_BRANCH to something newer than your images, set
# this to the matching openzfs-x.y-linux instead.
POOL_COMPATIBILITY="${POOL_COMPATIBILITY:-}"

#--- Identity -----------------------------------------------------------------
TARGET_HOSTNAME="${TARGET_HOSTNAME:-el10-zbm}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_FULLNAME="${ADMIN_FULLNAME:-System Administrator}"
# [EL] 'wheel' is EL's sudo group. There is no adm/plugdev/netdev/dip the way
# Debian has them; dialout and lp exist, cdrom does not.
ADMIN_GROUPS="${ADMIN_GROUPS:-wheel,users,audio,video,dialout}"

#--- Locale / time / keyboard -------------------------------------------------
TIMEZONE="${TIMEZONE:-Etc/UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-${_LIVE_XKBLAYOUT:-us}}"
KEYBOARD_VARIANT="${KEYBOARD_VARIANT-${_LIVE_XKBVARIANT}}"
# [EL] The console keymap is a separate namespace from the XKB layout. For
# us/de/fr/es/it the names coincide; for anything exotic set this yourself.
VCONSOLE_KEYMAP="${VCONSOLE_KEYMAP:-${KEYMAP}}"

#--- [EL] Repositories --------------------------------------------------------
# CRB (CodeReady Builder) has the -devel packages EPEL links against. EPEL has
# rEFInd, KDE, and a long tail of desktop packages EL does not ship itself.
ENABLE_CRB="${ENABLE_CRB:-yes}"
ENABLE_EPEL="${ENABLE_EPEL:-yes}"
# EL's equivalent of Debian's -proposed-updates does not exist in the same form;
# what you do get is the next minor release when it lands. Nothing to toggle.

INSTALL_FIRMWARE="${INSTALL_FIRMWARE:-yes}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

#--- [EL] SELinux -------------------------------------------------------------
# enforcing : the EL default and what you should run
# permissive: logs denials, blocks nothing. Useful the first week.
# disabled  : on EL10 this is deprecated and only half works; prefer permissive.
SELINUX_MODE="${SELINUX_MODE:-enforcing}"
# fixfiles    : relabel inside the chroot, at the end of the install [GUIDE]
# autorelabel : drop /.autorelabel and let the first boot do it (slower, but it
#               runs under the target's own policy, which is strictly correct)
# both        : belt and braces. THIS IS THE DEFAULT, because an unlabelled
#               root on EL is an emergency shell, not a boot.
SELINUX_RELABEL="${SELINUX_RELABEL:-both}"

#--- Desktop ------------------------------------------------------------------
# [EL] GNOME is what Red Hat ships. KDE on EL10 comes from EPEL and is not
# guaranteed to be there -- the script checks and tells you rather than failing.
DESKTOP="${DESKTOP:-gnome}"               # gnome | kde | none
DESKTOP_SIZE="${DESKTOP_SIZE:-minimal}"   # minimal | full
DESKTOP_EXTRAS="${DESKTOP_EXTRAS:-yes}"
INSTALL_MEDIA_ACCEL="${INSTALL_MEDIA_ACCEL:-yes}"   # VA-API / VDPAU / Vulkan
INSTALL_FLATPAK="${INSTALL_FLATPAK:-no}"
INSTALL_OFFICE="${INSTALL_OFFICE:-no}"
INSTALL_AUTO_UPDATES="${INSTALL_AUTO_UPDATES:-no}"  # dnf-automatic

#--- Passwords (prompted if unset) --------------------------------------------
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ZFS_PASSPHRASE="${ZFS_PASSPHRASE:-}"

#--- Misc ---------------------------------------------------------------------
FORCE="${FORCE:-no}"
HOSTID="${HOSTID:-0x00bab10c}"

#==============================================================================
# Helpers
#==============================================================================

log()  { printf '\n\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2; exit 1; }

prompt_pass() {
	local __var="$1" label="$2" minlen="${3:-1}" p1 p2
	while :; do
		read -rsp "  ${label}: " p1; echo
		read -rsp "  Confirm ${label}: " p2; echo
		if   [[ -z "$p1" ]];        then warn "Empty. Try again."
		elif [[ "$p1" != "$p2" ]];  then warn "Passwords do not match. Try again."
		elif (( ${#p1} < minlen )); then warn "Need at least ${minlen} characters."
		else break
		fi
	done
	printf -v "$__var" '%s' "$p1"
	return 0
}

list_disks() {
	local l
	echo "Whole disks under /dev/disk/by-id/:" >&2
	for l in /dev/disk/by-id/*; do
		[[ "$l" == *-part* ]] && continue
		[[ -b "$l" ]] || continue
		[[ "$(lsblk -dno TYPE "$l" 2>/dev/null)" == "disk" ]] || continue
		printf '  %-72s %s\n' "$l" "$(lsblk -dno SIZE,MODEL "$l" 2>/dev/null)" >&2
	done
	return 0
}

#------------------------------------------------------------------------------
# [EL] dnf4 / dnf5 compatibility
#------------------------------------------------------------------------------
# EL10 ships dnf5, which dropped several dnf4 spellings. Rather than detect the
# version and branch (and get it wrong on the one machine that has both), try
# the dnf5 form and fall back to the dnf4 form.

dnf_enable_repo() {
	# $1 = repo id
	dnf -y config-manager setopt "${1}.enabled=1" 2>/dev/null && return 0
	dnf -y config-manager --set-enabled "$1"      2>/dev/null && return 0
	return 1
}

#==============================================================================
# Preflight
#==============================================================================

[[ $EUID -eq 0 ]] || die "Run this script as root (sudo -i)."
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode. This script is UEFI-only."
command -v dnf >/dev/null || die "No dnf in the live environment. Is this really an EL live image?"

case "$LIVE_ID" in
	rocky|almalinux|centos|rhel) ;;
	"") warn "Could not read /etc/os-release; assuming an EL live environment." ;;
	*)  warn "Live environment reports ID='${LIVE_ID}', which is not an EL distribution."
	    warn "The dnf/SELinux/dracut steps below assume EL. Continue at your own risk." ;;
esac
if [[ -n "$LIVE_MAJOR" && "$LIVE_MAJOR" != "$RELEASEVER" ]]; then
	warn "Live environment is EL${LIVE_MAJOR} but RELEASEVER=${RELEASEVER}."
	warn "Installing across major versions mostly works but is not what the guide does."
fi

if [[ -z "$DISK" ]]; then
	list_disks
	die "DISK is not set. Pass a /dev/disk/by-id/... path."
fi
if [[ "$DISK" != /dev/disk/by-id/* ]]; then
	list_disks
	die "DISK must be a /dev/disk/by-id/... path (got: ${DISK})."
fi
if [[ "$DISK" == *-part* ]]; then
	die "DISK must point at a whole disk, not a partition."
fi
if [[ ! -b "$DISK" ]]; then
	list_disks
	die "${DISK} is not a block device."
fi

DISK_REAL="$(readlink -f "$DISK")"
[[ "$(lsblk -dno TYPE "$DISK_REAL")" == "disk" ]] || die "${DISK} does not resolve to a whole disk."

case "$DESKTOP"         in gnome|kde|none)        ;; *) die "DESKTOP must be gnome, kde or none." ;; esac
case "$DESKTOP_SIZE"    in minimal|full)          ;; *) die "DESKTOP_SIZE must be minimal or full." ;; esac
case "$BASELINE_MODE"   in clone|send|none)       ;; *) die "BASELINE_MODE must be clone, send or none." ;; esac
case "$SWAP_MODE"       in random|luks|none)      ;; *) die "SWAP_MODE must be random, luks or none." ;; esac
case "$ZFS_PKG_STYLE"   in dkms|kmod)             ;; *) die "ZFS_PKG_STYLE must be dkms or kmod." ;; esac
case "$ZFS_BRANCH" in
	latest|legacy|default) ;;
	[0-9]*.[0-9]*)         ;;
	*) die "ZFS_BRANCH must be latest, legacy, default, or a branch like 2.4." ;;
esac
case "$BOOTLOADER"      in refind|efibootmgr)     ;; *) die "BOOTLOADER must be refind or efibootmgr." ;; esac
case "$REFIND_SOURCE"   in auto|rpm|zip)          ;; *) die "REFIND_SOURCE must be zip, rpm or auto." ;; esac
case "$SELINUX_MODE"    in enforcing|permissive|disabled) ;; *) die "SELINUX_MODE must be enforcing, permissive or disabled." ;; esac
case "$SELINUX_RELABEL" in fixfiles|autorelabel|both|none) ;; *) die "SELINUX_RELABEL must be fixfiles, autorelabel, both or none." ;; esac

if [[ ! "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
	die "ADMIN_USER '${ADMIN_USER}' is not a valid Unix username."
fi
if [[ "$ADMIN_USER" == "root" ]]; then
	die "ADMIN_USER cannot be root."
fi
if [[ ! "$BE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]*$ ]]; then
	die "BE_NAME '${BE_NAME}' is not a valid ZFS dataset component."
fi

if [[ "$SELINUX_MODE" == "disabled" ]]; then
	warn "SELINUX_MODE=disabled. On EL10, disabling SELinux via /etc/selinux/config is"
	warn "deprecated and leaves the system in a half-configured state. Prefer permissive."
fi

#--- Resolve the kernel selection ---------------------------------------------
ZBM_ALL_KERNELS="6.6 6.12 6.18"
if [[ "$ZBM_KERNELS" == "all" ]]; then
	ZBM_KERNEL_LIST="$ZBM_ALL_KERNELS"
else
	ZBM_KERNEL_LIST="$ZBM_KERNELS"
fi

SELECTED_KERNELS=()
for k in $ZBM_KERNEL_LIST; do
	case " $ZBM_ALL_KERNELS " in
		*" $k "*) SELECTED_KERNELS+=("$k") ;;
		*) die "ZBM_KERNELS: '${k}' is not one of: ${ZBM_ALL_KERNELS} (or 'all')." ;;
	esac
done
(( ${#SELECTED_KERNELS[@]} > 0 )) || die "ZBM_KERNELS selected nothing."

if [[ -n "$ZBM_FALLBACK_KERNEL" ]]; then
	_found=no
	for k in "${SELECTED_KERNELS[@]}"; do
		[[ "$k" == "$ZBM_FALLBACK_KERNEL" ]] && _found=yes
	done
	if [[ "$_found" != yes ]]; then
		warn "ZBM_FALLBACK_KERNEL=${ZBM_FALLBACK_KERNEL} was not selected; using ${SELECTED_KERNELS[0]}."
		ZBM_FALLBACK_KERNEL="${SELECTED_KERNELS[0]}"
	fi
fi

#--- ESP capacity sanity check ------------------------------------------------
# Observed v3.1.0 sizes: release images run 60-70 MB, recovery images 77-84 MB.
N_KERNELS=${#SELECTED_KERNELS[@]}
EST_MIB=$(( N_KERNELS * 70 ))
[[ "$ZBM_BACKUP"   == "yes" ]] && EST_MIB=$(( EST_MIB + N_KERNELS * 70 ))
[[ "$ZBM_RECOVERY" == "yes" ]] && EST_MIB=$(( EST_MIB + N_KERNELS * 85 ))
[[ -n "$ZBM_FALLBACK_KERNEL" ]] && EST_MIB=$(( EST_MIB + 70 ))
EST_MIB=$(( EST_MIB + 60 ))   # rEFInd, FAT overhead, slack

if (( ESP_SIZE_MIB < EST_MIB )); then
	die "ESP_SIZE_MIB=${ESP_SIZE_MIB} is too small for this selection (~${EST_MIB} MiB needed). Raise it."
fi

#--- Keyboard / locale / timezone validation ----------------------------------
if [[ -r "$XKB_LST" ]]; then
	if ! awk '/^! layout/{f=1;next} /^!/{f=0} f&&NF{print $1}' "$XKB_LST" | grep -qx "$KEYMAP"; then
		die "KEYMAP='${KEYMAP}' is not a known XKB layout."
	fi
	if [[ -n "$KEYBOARD_VARIANT" ]]; then
		if ! awk -v l="${KEYMAP}:" '/^! variant/{f=1;next} /^!/{f=0} f&&NF>1&&$2==l{print $1}' \
			"$XKB_LST" | grep -qx "$KEYBOARD_VARIANT"; then
			warn "KEYBOARD_VARIANT='${KEYBOARD_VARIANT}' is not valid for layout '${KEYMAP}'."
			echo "Valid variants for '${KEYMAP}':" >&2
			list_variants "$KEYMAP"
			die "Pick one of the above, or leave KEYBOARD_VARIANT empty."
		fi
	fi
else
	warn "xkeyboard-config not available; skipping keyboard validation."
fi

[[ -e "/usr/share/zoneinfo/${TIMEZONE}" ]] || die "TIMEZONE='${TIMEZONE}' is not a known zoneinfo name."
case "$LOCALE" in
	*.UTF-8|*.utf8) ;;
	*) die "LOCALE='${LOCALE}' must be a UTF-8 locale, e.g. en_US.UTF-8." ;;
esac
# [EL] There is no locale-gen. Locales come from glibc-langpack-<lang>, so the
# thing to check is that such a package plausibly exists.
LOCALE_LANG="${LOCALE%%_*}"
LOCALE_LANG="${LOCALE_LANG%%.*}"
[[ -n "$LOCALE_LANG" ]] || die "Could not derive a language code from LOCALE='${LOCALE}'."

#--- Partition devices --------------------------------------------------------
BOOT_PART=1
SWAP_PART=2
POOL_PART=3
if (( SWAP_SIZE_MIB <= 0 )); then
	SWAP_MODE="none"
	POOL_PART=2
fi
BOOT_DEVICE="${DISK}-part${BOOT_PART}"
SWAP_DEVICE="${DISK}-part${SWAP_PART}"
POOL_DEVICE="${DISK}-part${POOL_PART}"

KEYFILE="/etc/zfs/${POOL_NAME}.key"

log "Planned configuration"
cat <<EOF
  Distribution     : ${DISTRO_ID} ${RELEASEVER}   (live env: ${LIVE_ID:-?} ${LIVE_VERSION_ID:-?})
  Base group       : ${BASE_GROUP}
  Disk             : ${DISK}
                     -> ${DISK_REAL}  ($(lsblk -dno SIZE,MODEL "$DISK_REAL"))
  ESP              : ${BOOT_DEVICE}   ${ESP_SIZE_MIB} MiB  vfat  /boot/efi
                     (~${EST_MIB} MiB will be used by ZBM images)
  Swap             : $( [[ "$SWAP_MODE" != none ]] && echo "${SWAP_DEVICE}   ${SWAP_SIZE_MIB} MiB  mode=${SWAP_MODE}" || echo "disabled" )
  Pool vdev        : ${POOL_DEVICE}
  Pool             : ${POOL_NAME}  ashift=${ASHIFT}  compression=${COMPRESSION}
  Compatibility    : ${POOL_COMPATIBILITY:-none (all features of the installed zfs)}
  Encryption       : ${ENCRYPTION_ALGO}, native, passphrase (mandatory)
  Boot environment : ${POOL_NAME}/ROOT/${BE_NAME}
  Baseline BE      : $( [[ "$BASELINE_MODE" == none ]] && echo "disabled" || echo "${POOL_NAME}/ROOT/${BASELINE_NAME} (${BASELINE_MODE})" )
  ZFS packaging    : ${ZFS_PKG_STYLE}, branch=${ZFS_BRANCH}  via ${ZFS_RELEASE_PKG}

  ZFSBootMenu      : ${ZBM_VERSION}
    kernels        : ${SELECTED_KERNELS[*]}
    release images : yes  (EFI/ZBM-<ver>/vmlinuz.EFI)
    recovery images: ${ZBM_RECOVERY}  (EFI/ZBM-RECOVERY-<ver>/vmlinuz.EFI)
    backup copies  : ${ZBM_BACKUP}  (EFI/ZBM-BACKUP/vmlinuz-<ver>.EFI)
    BOOTX64 fallback: ${ZBM_FALLBACK_KERNEL:-disabled}
  Boot manager     : ${BOOTLOADER}$( [[ "$BOOTLOADER" == refind ]] && echo " (source: ${REFIND_SOURCE})" )
  rEFInd           : timeout ${REFIND_TIMEOUT} $( [[ "$REFIND_TIMEOUT" == 0 ]] && echo "(waits for you; nothing auto-boots)" ), default_selection $( [[ -n "$REFIND_DEFAULT" ]] && echo "'${REFIND_DEFAULT}'" || echo "not set" )
  ZBM cmdline      : ${ZBM_CMDLINE}   (countdown ${ZBM_TIMEOUT}s)
  EL cmdline       : ${KERNEL_CMDLINE}

  Hostname         : ${TARGET_HOSTNAME}
  Admin user       : ${ADMIN_USER}  (groups: ${ADMIN_GROUPS})
  Desktop          : ${DESKTOP} (${DESKTOP_SIZE})  extras=${DESKTOP_EXTRAS}
  Locale / TZ      : ${LOCALE} / ${TIMEZONE}
  Keyboard         : xkb=${KEYMAP} variant=$( [[ -n "$KEYBOARD_VARIANT" ]] && echo "$KEYBOARD_VARIANT" || echo "(none)" )  console=${VCONSOLE_KEYMAP}
  SELinux          : ${SELINUX_MODE}, relabel=${SELINUX_RELABEL}
  Repositories     : baseos appstream$( [[ "$ENABLE_CRB" == yes ]] && echo " crb" )$( [[ "$ENABLE_EPEL" == yes ]] && echo " epel" ) zfsonlinux
EOF

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DISK_REAL" || true

if [[ "$FORCE" != "yes" ]]; then
	echo
	warn "EVERY PARTITION AND ALL DATA ON ${DISK_REAL} WILL BE DESTROYED."
	read -rp "Type ERASE to continue: " confirm
	[[ "$confirm" == "ERASE" ]] || die "Aborted."
fi

log "Collecting passwords"
[[ -n "$ROOT_PASSWORD" ]]  || prompt_pass ROOT_PASSWORD  "root password" 1
[[ -n "$ADMIN_PASSWORD" ]] || prompt_pass ADMIN_PASSWORD "password for ${ADMIN_USER}" 1
if [[ -z "$ZFS_PASSPHRASE" ]]; then
	# [GUIDE] "It's critical that your passphrase be something you can type on
	# your keyboard, since you will need to type it in to unlock the pool on
	# boot." ZFSBootMenu uses its own minimal keymap.
	echo "  Typed inside ZFSBootMenu at every boot, on a basic keymap."
	echo "  Prefer unshifted ASCII you can find blind."
	prompt_pass ZFS_PASSPHRASE "ZFS pool passphrase" 8
fi

#==============================================================================
# [GUIDE] Configure Live Environment
#==============================================================================

DNF_OPTS=()
[[ "$ZFS_NOGPGCHECK" == "yes" ]] && DNF_OPTS+=(--nogpgcheck)

# [EL] The zfs-release RPM carries the repo definitions and the signing key.
# One package, one URL, no fallback: a 404 here means the mirror or the network
# is broken, and quietly reaching for an older release package would give you a
# repo file with none of the branch-specific repos this script relies on.
install_zfs_release() {
	local dist url
	dist="$(rpm --eval '%{dist}')"
	if rpm -q zfs-release >/dev/null 2>&1; then
		echo "  zfs-release is already installed"
		return 0
	fi
	url="${ZFS_RELEASE_BASE}/${ZFS_RELEASE_PKG}${dist}.noarch.rpm"
	echo "  installing ${url}"
	dnf install -y "${DNF_OPTS[@]}" "$url"
}

#------------------------------------------------------------------------------
# [EL] Pick exactly one OpenZFS branch repo
#------------------------------------------------------------------------------
# zfs-release-3-0 defines zfs, zfs-kmod, zfs-latest, zfs-latest-kmod,
# zfs-legacy, zfs-legacy-kmod and a zfs-x.y[-kmod] pair per supported branch.
# It leaves 'zfs' enabled, which on EL is the old maintenance branch.
#
# Upstream's documented procedure is: disable every zfs* repo, then enable the
# one you want. Leaving two enabled lets dnf satisfy 'zfs' from whichever has
# the higher version, which is not a decision you want made for you between
# reboots.
zfs_repo_name() {
	local base
	case "$ZFS_BRANCH" in
		latest)  base="zfs-latest" ;;
		legacy)  base="zfs-legacy" ;;
		default) base="zfs" ;;
		*)       base="zfs-${ZFS_BRANCH}" ;;
	esac
	[[ "$ZFS_PKG_STYLE" == "kmod" ]] && base="${base}-kmod"
	printf '%s' "$base"
}

select_zfs_repo() {
	local want
	want="$(zfs_repo_name)"
	echo "  OpenZFS branch '${ZFS_BRANCH}' + ${ZFS_PKG_STYLE} -> repo '${want}'"

	# Disable them all first. dnf5 takes a glob in setopt; dnf4 wants the
	# --disable form. Neither is fatal if it fails -- the enable below plus the
	# explicit repo check afterwards is what actually matters.
	dnf -y config-manager setopt "zfs*.enabled=0" 2>/dev/null \
		|| dnf -y config-manager --disable "zfs*" 2>/dev/null \
		|| warn "Could not bulk-disable the zfs* repos."

	dnf_enable_repo "$want" || die "Could not enable the '${want}' repository.
Check that ${ZFS_RELEASE_PKG} really defines it: grep '\[zfs' /etc/yum.repos.d/zfs.repo"

	# Prove it: if the repo is empty for this EL minor release, better to find
	# out here than three minutes into a DKMS build.
	if ! dnf -q repoquery --repo "$want" zfs >/dev/null 2>&1; then
		warn "Repository '${want}' is enabled but has no 'zfs' package for this release."
		warn "EL10 repos are per-minor-version and can lag a point release."
		warn "Either wait, or re-run with ZFS_BRANCH=legacy."
	fi
	return 0
}

log "Enabling CRB and EPEL in the live environment"
if [[ "$ENABLE_CRB" == "yes" ]]; then
	# Rocky and Alma both call it 'crb'. RHEL proper calls it
	# codeready-builder-for-rhel-10-<arch>-rpms and needs subscription-manager.
	dnf_enable_repo crb || warn "Could not enable CRB; EPEL packages may fail to resolve."
fi
if [[ "$ENABLE_EPEL" == "yes" ]]; then
	dnf install -y epel-release 2>/dev/null \
		|| dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${RELEASEVER}.noarch.rpm" \
		|| warn "EPEL could not be enabled in the live environment."
fi

log "Installing ZFS in the live environment (branch=${ZFS_BRANCH}, ${ZFS_PKG_STYLE})"
install_zfs_release || die "Could not install ${ZFS_RELEASE_PKG}. Check the network and ZFS_RELEASE_BASE."
select_zfs_repo

if [[ "$ZFS_PKG_STYLE" == "dkms" ]]; then
	# [GUIDE] dnf install -y "kernel-devel-uname-r == $(uname -r)"
	# On a live image the running kernel is whatever was on the ISO, which may
	# be older than anything still in the repos. Exact match first, then any
	# kernel-devel, then say so clearly rather than failing inside DKMS.
	if ! dnf install -y "kernel-devel-uname-r == $(uname -r)"; then
		warn "No kernel-devel matching the live kernel $(uname -r)."
		warn "Trying plain kernel-devel; if the DKMS build fails, re-run with ZFS_PKG_STYLE=kmod."
		dnf install -y kernel-devel || warn "kernel-devel is unavailable."
	fi
	dnf install -y "${DNF_OPTS[@]}" zfs gdisk || die "Failed to install zfs in the live environment."
else
	dnf install -y "${DNF_OPTS[@]}" kmod-zfs zfs gdisk || die "Failed to install kmod-zfs in the live environment."
fi

dnf install -y cryptsetup dosfstools curl util-linux || warn "Some live-environment tools are missing."

modprobe zfs || die "zfs module failed to load in the live environment.
If this was a DKMS build, check /var/lib/dkms/zfs/*/build/make.log.
If the live image simply has too little writable space for a build, re-run with ZFS_PKG_STYLE=kmod."

zfs version || true

# [GUIDE] Generate /etc/hostid
log "Generating /etc/hostid"
zgenhostid -f "$HOSTID"

#==============================================================================
# [GUIDE] Disk preparation
#==============================================================================

# A pool of the same name already imported in the live environment would make
# every later "zpool export/import ${POOL_NAME}" ambiguous, and could have the
# script operate on the wrong pool entirely.
log "Checking for an already-imported pool named ${POOL_NAME}"
if zpool list -H -o name 2>/dev/null | grep -qx "$POOL_NAME"; then
	echo >&2
	warn "A pool named '${POOL_NAME}' is ALREADY IMPORTED in this live environment."
	warn "Export it first:   zpool export ${POOL_NAME}"
	warn "or re-run with a different name, e.g.   POOL_NAME=zzroot"
	die "Refusing to continue with an ambiguous pool name."
fi

log "Wiping ${DISK}"
swapoff -a || true
zpool labelclear -f "$DISK" 2>/dev/null || true
for p in "${DISK}"-part*; do
	[[ -b "$p" ]] || continue
	zpool labelclear -f "$p" 2>/dev/null || true
	wipefs -a "$p" || true
done
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"
udevadm settle

log "Creating partitions"
sgdisk -n "${BOOT_PART}:1m:+${ESP_SIZE_MIB}m" -t "${BOOT_PART}:ef00" -c "${BOOT_PART}:EFI" "$DISK"
if (( SWAP_SIZE_MIB > 0 )); then
	# 8200 = Linux swap, 8309 = Linux LUKS. Getting this wrong makes
	# systemd-gpt-auto-generator create a competing unit that cannot succeed.
	swap_type=8200
	[[ "$SWAP_MODE" == "luks" ]] && swap_type=8309
	sgdisk -n "${SWAP_PART}:0:+${SWAP_SIZE_MIB}m" -t "${SWAP_PART}:${swap_type}" -c "${SWAP_PART}:swap" "$DISK"
fi
sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" -c "${POOL_PART}:${POOL_NAME}" "$DISK"

partprobe "$DISK_REAL" || true
udevadm settle
sleep 2
sgdisk -p "$DISK"

for p in "$BOOT_DEVICE" "$POOL_DEVICE"; do
	[[ -b "$p" ]] || die "Expected partition link $p does not exist after partitioning."
done
if (( SWAP_SIZE_MIB > 0 )) && [[ ! -b "$SWAP_DEVICE" ]]; then
	die "Expected partition link $SWAP_DEVICE does not exist."
fi

#==============================================================================
# Pool name collision check
#==============================================================================

# Run AFTER the wipe on purpose: any previous pool on the target disk is gone
# by now, so anything still found lives on a DIFFERENT disk and is a genuine
# conflict rather than a leftover of the install we are replacing.
log "Checking other disks for a pool named ${POOL_NAME}"
OTHER_POOL=no
if zpool import 2>/dev/null | awk '$1 == "pool:" { print $2 }' | grep -qx "$POOL_NAME"; then
	OTHER_POOL=yes
	echo >&2
	warn "Another pool named '${POOL_NAME}' exists on this machine, on a different disk."
	warn ""
	warn "The install itself is safe: the new pool is imported by GUID with the"
	warn "search restricted to ${POOL_DEVICE}, so the other pool is never touched."
	warn ""
	warn "The problem is later. ZFS cannot have two pools of the same name imported"
	warn "at once, so at boot ZFSBootMenu will see both and can only use one. Renaming"
	warn "a root pool afterwards is awkward."
	warn ""
	warn "Strongly recommended: abort and re-run with a unique name, e.g."
	warn "    POOL_NAME=zzroot ${0##*/} ..."
	if [[ "$FORCE" != "yes" ]]; then
		echo
		read -rp "Continue anyway with POOL_NAME=${POOL_NAME}? Type YES to proceed: " _pc
		[[ "$_pc" == "YES" ]] || die "Aborted. Re-run with a different POOL_NAME."
	fi
fi

#==============================================================================
# [GUIDE] ZFS pool creation (encrypted variant)
#==============================================================================

# [GUIDE] echo 'SomeKeyphrase' > /etc/zfs/zroot.key ; chmod 000 /etc/zfs/zroot.key
# printf, not echo: echo appends a newline and the newline becomes part of the
# passphrase, which you then have to reproduce by hand in ZFSBootMenu.
log "Writing pool key to ${KEYFILE}"
mkdir -p /etc/zfs
printf '%s' "$ZFS_PASSPHRASE" > "$KEYFILE"
chmod 000 "$KEYFILE"

log "Creating encrypted zpool ${POOL_NAME} on ${POOL_DEVICE}"
zpool_opts=(
	-f
	-o "ashift=${ASHIFT}"
	-O "compression=${COMPRESSION}"
	-O acltype=posixacl
	-O xattr=sa
	-O relatime=off
	-O atime=off
	-O logbias=throughput
	-O "encryption=${ENCRYPTION_ALGO}"
	-O "keylocation=file://${KEYFILE}"
	-O keyformat=passphrase
	-o autotrim=on
)
# [EL] xattr=sa is not optional here the way it is on Debian: SELinux stores
# security contexts in extended attributes, and sa-backed xattrs are the
# difference between a usable relabel and a directory-per-file nightmare.
[[ -n "$POOL_COMPATIBILITY" ]] && zpool_opts+=(-o "compatibility=${POOL_COMPATIBILITY}")

zpool create "${zpool_opts[@]}" -m none "$POOL_NAME" "$POOL_DEVICE"

# A pool's GUID is unique and unambiguous where its name is not. Everything
# below re-imports by GUID so the script can never grab a same-named pool that
# happens to live on another disk.
POOL_GUID="$(zpool get -H -o value guid "$POOL_NAME")"
[[ -n "$POOL_GUID" ]] || die "Could not read the GUID of the new pool."
echo "  pool GUID: ${POOL_GUID}"

#------------------------------------------------------------------------------
# [GUIDE] Create initial file systems
# "canmount is not inheritable ... It is necessary to explicitly set
#  canmount=noauto on every boot environment you create."
#------------------------------------------------------------------------------

log "Creating boot environment datasets"
zfs create -o mountpoint=none -o canmount=off    "${POOL_NAME}/ROOT"
zfs create -o mountpoint=/    -o canmount=noauto "${POOL_NAME}/ROOT/${BE_NAME}"
zpool set "bootfs=${POOL_NAME}/ROOT/${BE_NAME}" "$POOL_NAME"

log "Creating data datasets"
zfs create -o mountpoint=none -o canmount=off    "${POOL_NAME}/data"
zfs create -o mountpoint=/home                   "${POOL_NAME}/data/home"
zfs create -o mountpoint=/root                   "${POOL_NAME}/data/home/root"
zfs create -o mountpoint="/home/${ADMIN_USER}"   "${POOL_NAME}/data/home/${ADMIN_USER}"
zfs create -o mountpoint=/opt                    "${POOL_NAME}/data/opt"
zfs create -o mountpoint=/srv                    "${POOL_NAME}/data/srv"
zfs create -o mountpoint=none -o canmount=off    "${POOL_NAME}/data/var"
zfs create -o mountpoint=none -o canmount=off    "${POOL_NAME}/data/var/lib"
zfs create -o mountpoint=none -o canmount=off    "${POOL_NAME}/data/usr"
zfs create -o mountpoint=/usr/local              "${POOL_NAME}/data/usr/local"
zfs create -o mountpoint=/var/lib/containers     "${POOL_NAME}/data/var/lib/containers"
zfs create -o mountpoint=/var/lib/containerd     "${POOL_NAME}/data/var/lib/containerd"
zfs create -o mountpoint=/var/lib/libvirt        "${POOL_NAME}/data/var/lib/libvirt"
zfs create -o mountpoint=/var/log                "${POOL_NAME}/data/var/log"
zfs create -o mountpoint=/var/spool              "${POOL_NAME}/data/var/spool"
zfs create -o mountpoint=/var/tmp                "${POOL_NAME}/data/var/tmp"

# [EL] /var/lib/docker and /var/lib/lxc are Debian-isms. EL ships podman and
# its storage lives in /var/lib/containers, which is already a dataset above.
# If you add docker-ce later, give it its own dataset then.

if [[ "$DATASET_TUNING" == "yes" ]]; then
	log "Applying per-dataset tuning"
	zfs set atime=off                       "${POOL_NAME}/data/var"
	zfs set setuid=off devices=off          "${POOL_NAME}/data/var/tmp"
	zfs set compression=zstd recordsize=64K "${POOL_NAME}/data/var/log"
	zfs set recordsize=64K                  "${POOL_NAME}/data/var/lib/libvirt"
	zfs set recordsize=32K                  "${POOL_NAME}/data/var/lib/containers"
	zfs set recordsize=32K                  "${POOL_NAME}/data/var/lib/containerd"
	zfs set com.sun:auto-snapshot=false     "${POOL_NAME}/data/var/lib/containers"
	zfs set com.sun:auto-snapshot=false     "${POOL_NAME}/data/var/lib/containerd"
	zfs set com.sun:auto-snapshot=false     "${POOL_NAME}/data/var/lib/libvirt"
fi

log "Exporting and re-importing at /mnt"
zpool export "$POOL_NAME"

# [DEVIATION] The guide does: zpool import -N -R /mnt zroot
# Importing by NAME picks whichever pool of that name the scan finds first,
# which is a coin toss when a second pool shares the name -- and the failure
# mode is importing, and then installing over, the wrong pool.
#
# Two changes make this deterministic:
#   -d "$POOL_DEVICE"  restricts the device scan to the partition just created
#   "$POOL_GUID"       identifies the pool by its unique GUID, not its name
if ! zpool import -N -R /mnt -d "$POOL_DEVICE" "$POOL_GUID"; then
	warn "Import with -d ${POOL_DEVICE} failed; retrying against /dev/disk/by-id"
	zpool import -N -R /mnt -d /dev/disk/by-id "$POOL_GUID" \
		|| die "Could not import pool ${POOL_GUID}."
fi

IMPORTED_GUID="$(zpool get -H -o value guid "$POOL_NAME" 2>/dev/null || true)"
if [[ "$IMPORTED_GUID" != "$POOL_GUID" ]]; then
	die "Imported pool GUID '${IMPORTED_GUID}' does not match the pool just created ('${POOL_GUID}')."
fi

zfs load-key "$POOL_NAME"
zfs mount "${POOL_NAME}/ROOT/${BE_NAME}"
zfs mount -a

echo
zfs list -o name,used,mountpoint,canmount -r "$POOL_NAME"
mount | grep -q ' /mnt ' || die "${POOL_NAME}/ROOT/${BE_NAME} is not mounted at /mnt."
for d in /mnt/home /mnt/root /mnt/opt /mnt/srv /mnt/var/log /mnt/var/spool /mnt/var/tmp; do
	mountpoint -q "$d" || die "Expected dataset not mounted: $d"
done

# [GUIDE] Update device symlinks
udevadm trigger

#==============================================================================
# [GUIDE] Install Rocky / Alma
#==============================================================================

log "Preparing chroot mounts"
mkdir -p /mnt/proc /mnt/sys /mnt/dev /mnt/dev/pts /mnt/run
mount -t proc  proc  /mnt/proc
mount -t sysfs sys   /mnt/sys
mount -B /dev        /mnt/dev
mount -t devpts pts  /mnt/dev/pts
mount -t tmpfs tmpfs /mnt/run
mkdir -p /mnt/run/lock
mkdir -p /mnt/sys/firmware/efi/efivars
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars 2>/dev/null || \
	warn "Could not mount efivarfs; EFI boot entries may fail to register."

log "Installing the base system into /mnt (${BASE_GROUP})"
# [GUIDE] dnf --installroot=/mnt --releasever=10 -y groupinstall "Minimal Install"
#
# [EL] Two things the guide's one-liner glosses over:
#   * dnf5 (EL10) spells it `group install`, dnf4 spells it `groupinstall`
#   * with --installroot, dnf looks for repo definitions INSIDE the installroot
#     first. It is empty. --use-host-config points it at the live image's repos,
#     which is the only place they exist at this point. dnf4 does this
#     implicitly; dnf5 does not always, so ask for it and fall back if the
#     option is not recognised.
dnf_installroot_group() {
	local g="$1" opt
	for opt in "--use-host-config" ""; do
		# shellcheck disable=SC2086
		if dnf --installroot=/mnt --releasever="$RELEASEVER" $opt -y group install "$g" 2>/dev/null; then
			return 0
		fi
		# shellcheck disable=SC2086
		if dnf --installroot=/mnt --releasever="$RELEASEVER" $opt -y groupinstall "$g" 2>/dev/null; then
			return 0
		fi
	done
	return 1
}

if ! dnf_installroot_group "$BASE_GROUP"; then
	warn "group '${BASE_GROUP}' could not be installed; falling back to @core plus essentials."
	dnf --installroot=/mnt --releasever="$RELEASEVER" --use-host-config -y install \
		"${DISTRO_ID}-release" dnf systemd systemd-udev passwd sudo \
		2>/dev/null \
	|| dnf --installroot=/mnt --releasever="$RELEASEVER" -y install \
		"${DISTRO_ID}-release" dnf systemd systemd-udev passwd sudo \
	|| die "Could not install a base system into /mnt."
	dnf_installroot_group "core" || warn "@core could not be installed either."
fi

[[ -x /mnt/usr/bin/dnf || -x /mnt/bin/dnf ]] || die "/mnt has no dnf; the base install did not work."

log "Fixing permissions on dataset-backed directories"
chmod 0700 /mnt/root
chmod 1777 /mnt/var/tmp
chmod 0755 /mnt/home /mnt/opt /mnt/srv /mnt/var/log /mnt/var/spool

# [GUIDE] Copy files into the new install (encrypted variant)
log "Copying host files into the new install"
mkdir -p /mnt/etc/zfs
cp /etc/hostid /mnt/etc/
cp -L /etc/resolv.conf /mnt/etc/
cp "$KEYFILE" "/mnt${KEYFILE}"
chmod 000 "/mnt${KEYFILE}"

#==============================================================================
# Write configuration + chroot script
#==============================================================================

log "Writing chroot payload"

{
	printf 'DISTRO_ID=%q\n'             "$DISTRO_ID"
	printf 'RELEASEVER=%q\n'            "$RELEASEVER"
	printf 'POOL_NAME=%q\n'             "$POOL_NAME"
	printf 'BE_NAME=%q\n'               "$BE_NAME"
	printf 'KEYFILE=%q\n'               "$KEYFILE"
	printf 'TARGET_HOSTNAME=%q\n'       "$TARGET_HOSTNAME"
	printf 'ADMIN_USER=%q\n'            "$ADMIN_USER"
	printf 'ADMIN_FULLNAME=%q\n'        "$ADMIN_FULLNAME"
	printf 'ADMIN_GROUPS=%q\n'          "$ADMIN_GROUPS"
	printf 'ROOT_PASSWORD=%q\n'         "$ROOT_PASSWORD"
	printf 'ADMIN_PASSWORD=%q\n'        "$ADMIN_PASSWORD"
	printf 'TIMEZONE=%q\n'              "$TIMEZONE"
	printf 'LOCALE=%q\n'                "$LOCALE"
	printf 'LOCALE_LANG=%q\n'           "$LOCALE_LANG"
	printf 'KEYMAP=%q\n'                "$KEYMAP"
	printf 'KEYBOARD_VARIANT=%q\n'      "$KEYBOARD_VARIANT"
	printf 'VCONSOLE_KEYMAP=%q\n'       "$VCONSOLE_KEYMAP"
	printf 'ENABLE_CRB=%q\n'            "$ENABLE_CRB"
	printf 'ENABLE_EPEL=%q\n'           "$ENABLE_EPEL"
	printf 'ZFS_RELEASE_PKG=%q\n'       "$ZFS_RELEASE_PKG"
	printf 'ZFS_BRANCH=%q\n'            "$ZFS_BRANCH"
	printf 'ZFS_RELEASE_BASE=%q\n'      "$ZFS_RELEASE_BASE"
	printf 'ZFS_PKG_STYLE=%q\n'         "$ZFS_PKG_STYLE"
	printf 'ZFS_NOGPGCHECK=%q\n'        "$ZFS_NOGPGCHECK"
	printf 'INSTALL_FIRMWARE=%q\n'      "$INSTALL_FIRMWARE"
	printf 'EXTRA_PACKAGES=%q\n'        "$EXTRA_PACKAGES"
	printf 'SELINUX_MODE=%q\n'          "$SELINUX_MODE"
	printf 'SELINUX_RELABEL=%q\n'       "$SELINUX_RELABEL"
	printf 'DESKTOP=%q\n'               "$DESKTOP"
	printf 'DESKTOP_SIZE=%q\n'          "$DESKTOP_SIZE"
	printf 'DESKTOP_EXTRAS=%q\n'        "$DESKTOP_EXTRAS"
	printf 'INSTALL_MEDIA_ACCEL=%q\n'   "$INSTALL_MEDIA_ACCEL"
	printf 'INSTALL_FLATPAK=%q\n'       "$INSTALL_FLATPAK"
	printf 'INSTALL_OFFICE=%q\n'        "$INSTALL_OFFICE"
	printf 'INSTALL_AUTO_UPDATES=%q\n'  "$INSTALL_AUTO_UPDATES"
	printf 'DISK_REAL=%q\n'             "$DISK_REAL"
	printf 'BOOT_PART=%q\n'             "$BOOT_PART"
	printf 'BOOT_DEVICE=%q\n'           "$BOOT_DEVICE"
	printf 'SWAP_DEVICE=%q\n'           "$SWAP_DEVICE"
	printf 'SWAP_SIZE_MIB=%q\n'         "$SWAP_SIZE_MIB"
	printf 'SWAP_MODE=%q\n'             "$SWAP_MODE"
	printf 'SWAP_RANDOM_SOURCE=%q\n'    "$SWAP_RANDOM_SOURCE"
	printf 'SWAP_CIPHER=%q\n'           "$SWAP_CIPHER"
	printf 'SWAP_KEYSIZE=%q\n'          "$SWAP_KEYSIZE"
	printf 'SWAP_MAPPER=%q\n'           "$SWAP_MAPPER"
	printf 'ZBM_VERSION=%q\n'           "$ZBM_VERSION"
	printf 'ZBM_BASE_URL=%q\n'          "$ZBM_BASE_URL"
	printf 'ZBM_KERNEL_LIST=%q\n'       "${SELECTED_KERNELS[*]}"
	printf 'ZBM_RECOVERY=%q\n'          "$ZBM_RECOVERY"
	printf 'ZBM_BACKUP=%q\n'            "$ZBM_BACKUP"
	printf 'ZBM_FALLBACK_KERNEL=%q\n'   "$ZBM_FALLBACK_KERNEL"
	printf 'ZBM_CMDLINE=%q\n'           "$ZBM_CMDLINE"
	printf 'ZBM_TIMEOUT=%q\n'           "$ZBM_TIMEOUT"
	printf 'KERNEL_CMDLINE=%q\n'        "$KERNEL_CMDLINE"
	printf 'BOOTLOADER=%q\n'            "$BOOTLOADER"
	printf 'REFIND_SOURCE=%q\n'         "$REFIND_SOURCE"
	printf 'REFIND_VERSION=%q\n'        "$REFIND_VERSION"
	printf 'REFIND_RPM_URL=%q\n'        "$REFIND_RPM_URL"
	printf 'REFIND_ZIP_URL=%q\n'        "$REFIND_ZIP_URL"
	printf 'REFIND_ZIP_SHA256=%q\n'     "$REFIND_ZIP_SHA256"
	printf 'REFIND_RPM_SHA256=%q\n'     "$REFIND_RPM_SHA256"
	printf 'REFIND_DEFAULT=%q\n'        "$REFIND_DEFAULT"
	printf 'REFIND_TIMEOUT=%q\n'        "$REFIND_TIMEOUT"
	printf 'EFI_ENTRIES_ALWAYS=%q\n'    "$EFI_ENTRIES_ALWAYS"
} > /mnt/root/zbm-install.env
chmod 600 /mnt/root/zbm-install.env

cat > /mnt/root/zbm-chroot.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
source /root/zbm-install.env

WARNFILE=/root/INSTALL-WARNINGS.txt

log()  { printf '\n\033[1;36m -->\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() {
	printf '\033[1;33m [!]\033[0m %s\n' "$*" >&2
	printf '%s\n' "$*" >> "$WARNFILE"
}
die() {
	warn "$*"
	printf '\033[1;31m [X]\033[0m FATAL: %s\n' "$*" >&2
	exit 1
}

DNF_OPTS=()
[[ "$ZFS_NOGPGCHECK" == "yes" ]] && DNF_OPTS+=(--nogpgcheck)

#------------------------------------------------------------------------------
# [EL] dnf4 / dnf5 compatibility shims, again -- the chroot is a separate script
#------------------------------------------------------------------------------
dnf_enable_repo() {
	dnf -y config-manager setopt "${1}.enabled=1" 2>/dev/null && return 0
	dnf -y config-manager --set-enabled "$1"      2>/dev/null && return 0
	return 1
}

# Install only the packages that actually exist in the enabled repositories.
# EL splits and renames packages between minor releases, EPEL comes and goes,
# and one bad name would otherwise abort the whole transaction.
dnf_install_available() {
	local label="$1"; shift
	local avail=() p
	for p in "$@"; do
		if dnf -q info "$p" >/dev/null 2>&1 || dnf -q list --available "$p" >/dev/null 2>&1; then
			avail+=("$p")
		else
			echo "    skip (not in any enabled repo): ${p}"
		fi
	done
	if (( ${#avail[@]} > 0 )); then
		echo "    installing ${label}: ${avail[*]}"
		dnf install -y "${avail[@]}" || warn "Some ${label} packages failed to install."
	fi
	return 0
}

#--- [EL] machine-id ----------------------------------------------------------
# dnf --installroot does not create one, and kernel-install, systemd and the
# BLS machinery all want it. Without it the kernel scriptlets emit confusing
# errors and journald has nowhere to put persistent logs.
log "Initialising machine-id"
systemd-machine-id-setup || warn "systemd-machine-id-setup failed."

#--- [GUIDE] Set hostname -----------------------------------------------------
log "Setting hostname"
echo "$TARGET_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1	localhost localhost.localdomain
127.0.1.1	${TARGET_HOSTNAME}
::1		localhost localhost.localdomain ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

#--- [EL] Repositories inside the target --------------------------------------
log "Configuring repositories"
dnf -y makecache || warn "Initial makecache failed; check /etc/resolv.conf in the chroot."

if [[ "$ENABLE_CRB" == "yes" ]]; then
	dnf_enable_repo crb || warn "Could not enable CRB inside the target."
fi
if [[ "$ENABLE_EPEL" == "yes" ]]; then
	dnf install -y epel-release 2>/dev/null \
		|| dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${RELEASEVER}.noarch.rpm" \
		|| warn "EPEL could not be enabled inside the target."
fi

# [GUIDE] dnf install -y https://zfsonlinux.org/epel/zfs-release-<ver>$(rpm --eval "%{dist}").noarch.rpm
# One URL, no fallback to an older release package: only zfs-release-3-0 ships
# the branch-specific repo definitions, so falling back would silently give you
# the old maintenance branch under a name that says otherwise.
DIST_TAG="$(rpm --eval '%{dist}')"
ZFS_RELEASE_URL="${ZFS_RELEASE_BASE}/${ZFS_RELEASE_PKG}${DIST_TAG}.noarch.rpm"
log "Installing ${ZFS_RELEASE_PKG}"
echo "  ${ZFS_RELEASE_URL}"
dnf install -y "${DNF_OPTS[@]}" "$ZFS_RELEASE_URL" \
	|| die "Could not install ${ZFS_RELEASE_PKG} inside the target."

#--- [EL] Pick exactly one OpenZFS branch repo --------------------------------
# zfs-release leaves the conservative 'zfs' repo enabled, which on EL is the old
# maintenance branch. ZFS_BRANCH=latest switches to 'zfs-latest', the newest
# released OpenZFS. Upstream's documented procedure is to disable every zfs*
# repo and then enable the one you want -- leaving two enabled lets dnf satisfy
# 'zfs' from whichever happens to carry the higher version, which is not a
# decision you want made for you during some future 'dnf update'.
case "$ZFS_BRANCH" in
	latest)  ZFS_REPO="zfs-latest" ;;
	legacy)  ZFS_REPO="zfs-legacy" ;;
	default) ZFS_REPO="zfs" ;;
	*)       ZFS_REPO="zfs-${ZFS_BRANCH}" ;;
esac
[[ "$ZFS_PKG_STYLE" == "kmod" ]] && ZFS_REPO="${ZFS_REPO}-kmod"
log "OpenZFS branch '${ZFS_BRANCH}' + ${ZFS_PKG_STYLE} -> repo '${ZFS_REPO}'"

dnf -y config-manager setopt "zfs*.enabled=0" 2>/dev/null \
	|| dnf -y config-manager --disable "zfs*" 2>/dev/null \
	|| warn "Could not bulk-disable the zfs* repos."

dnf_enable_repo "$ZFS_REPO" \
	|| die "Could not enable '${ZFS_REPO}'. Check /etc/yum.repos.d/zfs.repo for the repo ids ${ZFS_RELEASE_PKG} actually defines."

dnf -y makecache || true

# Fail here rather than three minutes into a DKMS build.
if ! dnf -q repoquery --repo "$ZFS_REPO" zfs >/dev/null 2>&1; then
	warn "Repository '${ZFS_REPO}' is enabled but has no 'zfs' package for this release."
	warn "OpenZFS EL repos are per-minor-version and can lag a point release by weeks."
	warn "If the install fails below, re-run with ZFS_BRANCH=legacy."
fi
echo "  available in ${ZFS_REPO}:"
dnf -q repoquery --repo "$ZFS_REPO" --queryformat '    %{name}-%{version}-%{release}\n' zfs 2>/dev/null | tail -n 3 || true

#--- [EL] Locale, timezone, keyboard ------------------------------------------
# There is no locale-gen, no /etc/default/keyboard and no console-setup here.
# Locales ship as glibc-langpack-* RPMs; the keyboard lives in two separate
# files that cover two separate stacks (text console vs X11/Wayland).
log "Configuring locale, timezone and keyboard"
dnf_install_available "locale" "glibc-langpack-${LOCALE_LANG}" glibc-langpack-en langpacks-en
dnf install -y tzdata xkeyboard-config kbd || warn "Some locale/keyboard packages are missing."

echo "LANG=${LOCALE}" > /etc/locale.conf

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "$TIMEZONE" > /etc/timezone 2>/dev/null || true

# Text console (vconsole.conf KEYMAP is a kbd keymap name, NOT an XKB layout).
{
	echo "KEYMAP=${VCONSOLE_KEYMAP}"
	echo "FONT=eurlatgr"
} > /etc/vconsole.conf
if ! find /usr/lib/kbd/keymaps /lib/kbd/keymaps -name "${VCONSOLE_KEYMAP}.map*" 2>/dev/null | grep -q .; then
	warn "Console keymap '${VCONSOLE_KEYMAP}' was not found under /usr/lib/kbd/keymaps."
	warn "The text console will fall back to us. Set VCONSOLE_KEYMAP to a name from"
	warn "'localectl list-keymaps' if you care about the console layout."
fi

# X11 / Wayland. This is what localectl set-x11-keymap writes; writing it
# directly avoids needing a running dbus inside the chroot.
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
# Written by el10-zbm-install-testing.sh. Change with:
#   localectl set-x11-keymap <layout> <model> <variant>
Section "InputClass"
	Identifier "system-keyboard"
	MatchIsKeyboard "on"
	Option "XkbLayout" "${KEYMAP}"
	Option "XkbVariant" "${KEYBOARD_VARIANT}"
EndSection
EOF

#--- [GUIDE] Configure Dracut to load ZFS support -----------------------------
# This is the single biggest structural difference from the Debian script.
# Debian's initramfs-tools pulls /etc/zfs in wholesale, so the pool key lands in
# the initramfs for free. Dracut copies nothing it was not told about, so the
# key has to be named explicitly with install_items -- without this line the
# kernel reaches the encrypted root with no key and the boot dies after
# ZFSBootMenu has already done its job, which is a confusing place to fail.
log "Configuring dracut"
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/zol.conf <<EOF
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs resume "
install_items+=" ${KEYFILE} "
EOF
# 'resume' is omitted because swap here is either absent or encrypted with a key
# that does not survive a reboot. Leaving the module in means the initramfs
# hunts for a resume device it will never find and stalls while it does.

#--- [GUIDE] Install required packages ----------------------------------------
log "Installing kernel and ZFS (branch=${ZFS_BRANCH}, ${ZFS_PKG_STYLE})"
dnf install -y kernel kernel-core kernel-modules sudo efibootmgr dosfstools gdisk \
	|| die "Could not install the kernel."

if [[ "$ZFS_PKG_STYLE" == "dkms" ]]; then
	dnf install -y kernel-devel || die "kernel-devel is required for the DKMS build."
	dnf install -y "${DNF_OPTS[@]}" zfs zfs-dracut || die "Could not install zfs."
else
	dnf install -y "${DNF_OPTS[@]}" kmod-zfs zfs zfs-dracut || die "Could not install kmod-zfs."
fi

# [GUIDE] "Missing kernel messages can be ignored during this step."
# The reinstall is not cosmetic: kernel-core's scriptlets build the initramfs,
# and the first time they ran, zfs-dracut did not exist yet. Reinstalling
# re-triggers them with the ZFS dracut module in place.
log "Reinstalling kernel-core so its scriptlets run with zfs-dracut present"
dnf reinstall -y kernel-core || warn "kernel-core reinstall failed; relying on the explicit dracut run below."

#--- [GUIDE] Regenerate initramfs ---------------------------------------------
# [GUIDE] "Ignore any messages about findmnt or syslog."
log "Regenerating every initramfs"
dracut --force --regenerate-all || die "dracut failed. The system will not boot; fix this before rebooting."

# Prove the key and the zfs module actually landed, rather than finding out at
# the passphrase prompt that never appears.
for _img in /boot/initramfs-*.img; do
	[[ -f "$_img" ]] || continue
	if command -v lsinitrd >/dev/null 2>&1; then
		if ! lsinitrd "$_img" 2>/dev/null | grep -q 'zfs'; then
			warn "${_img##*/} does not appear to contain the ZFS dracut module."
		fi
		if ! lsinitrd "$_img" 2>/dev/null | grep -q "${KEYFILE#/}"; then
			warn "${_img##*/} does not appear to contain ${KEYFILE}."
			warn "Root will not unlock. Check install_items in /etc/dracut.conf.d/zol.conf."
		fi
	fi
done
CHROOT_EOF

cat >> /mnt/root/zbm-chroot.sh <<'CHROOT_EOF'

#--- Microcode and firmware ---------------------------------------------------
if [[ "$INSTALL_FIRMWARE" == "yes" ]]; then
	# [EL] Much simpler than Debian. One microcode package covers both vendors,
	# and linux-firmware is a single monolith instead of two dozen firmware-*
	# packages you have to name individually.
	log "Installing microcode and device firmware"
	dnf_install_available "microcode" microcode_ctl
	dnf_install_available "firmware"  linux-firmware
	dnf_install_available "wireless tooling" wireless-regdb iw wpa_supplicant NetworkManager-wifi
fi

#--- [GUIDE] ZFS systemd services ---------------------------------------------
log "Enabling ZFS systemd units"
systemctl enable zfs.target          || warn "zfs.target could not be enabled."
systemctl enable zfs-import-cache    || warn "zfs-import-cache could not be enabled."
systemctl enable zfs-mount           || warn "zfs-mount could not be enabled."
systemctl enable zfs-import.target   || warn "zfs-import.target could not be enabled."
systemctl enable zfs-zed             || warn "zfs-zed could not be enabled."

#--- Encrypted swap -----------------------------------------------------------
if [[ "$SWAP_MODE" != "none" ]]; then
	log "Configuring encrypted swap (${SWAP_MODE})"
	# [EL] No cryptsetup-initramfs equivalent to agonise over: dracut's crypt
	# module is built in, and KERNEL_CMDLINE carries rd.luks=0 so it stays out
	# of the way at boot. systemd-cryptsetup handles the volume from the real
	# root, after ZFS is up and the keyfile is reachable.
	dnf install -y cryptsetup || die "cryptsetup is required for encrypted swap."

	if [[ "$SWAP_MODE" == "luks" ]]; then
		install -d -m 700 /etc/cryptsetup-keys.d
		dd if=/dev/urandom of=/etc/cryptsetup-keys.d/swap.key bs=512 count=1 status=none
		chmod 400 /etc/cryptsetup-keys.d/swap.key

		cryptsetup luksFormat --type luks2 --batch-mode \
			--cipher "$SWAP_CIPHER" --key-size "$SWAP_KEYSIZE" \
			--key-file /etc/cryptsetup-keys.d/swap.key "$SWAP_DEVICE" \
			|| die "luksFormat failed on ${SWAP_DEVICE}."
		cryptsetup open --key-file /etc/cryptsetup-keys.d/swap.key \
			"$SWAP_DEVICE" "$SWAP_MAPPER" \
			|| die "Could not open the LUKS swap volume."
		for _i in 1 2 3 4 5 6 7 8 9 10; do
			[[ -e "/dev/mapper/${SWAP_MAPPER}" ]] && break
			sleep 1
		done
		[[ -e "/dev/mapper/${SWAP_MAPPER}" ]] \
			|| die "/dev/mapper/${SWAP_MAPPER} never appeared."
		mkswap -L swap "/dev/mapper/${SWAP_MAPPER}"

		SWAP_UUID="$(blkid -s UUID -o value "$SWAP_DEVICE")"
		cat >> /etc/crypttab <<EOF
${SWAP_MAPPER}	UUID=${SWAP_UUID}	/etc/cryptsetup-keys.d/swap.key	luks,discard
EOF
		cryptsetup close "$SWAP_MAPPER"
	else
		# Plain dm-crypt: crypttab's 'swap' option takes a fresh key from the
		# source device and runs mkswap on every boot.
		SWAP_PARTUUID="$(blkid -s PARTUUID -o value "$SWAP_DEVICE")"
		cat >> /etc/crypttab <<EOF
${SWAP_MAPPER}	/dev/disk/by-partuuid/${SWAP_PARTUUID}	${SWAP_RANDOM_SOURCE}	swap,cipher=${SWAP_CIPHER},size=${SWAP_KEYSIZE},discard
EOF
	fi
	chmod 0600 /etc/crypttab

	# 'sw' alone is not enough. The fstab generator makes dev-mapper-cswap.swap
	# Require the device, but nothing states that the device only appears after
	# systemd-cryptsetup@ has run -- so systemd can wait the full 90s
	# DefaultTimeoutStartSec and then fail. x-systemd.requires makes the
	# ordering explicit; nofail means a swap problem never blocks boot.
	echo "/dev/mapper/${SWAP_MAPPER}	none	swap	sw,nofail,x-systemd.requires=systemd-cryptsetup@${SWAP_MAPPER}.service	0	0" >> /etc/fstab
fi

#--- [GUIDE] ZFSBootMenu dataset properties -----------------------------------
log "Setting ZFSBootMenu dataset properties"
# Hostid is left entirely to ZFSBootMenu. zbm.set_hostid is enabled by default
# and makes ZBM set spl.spl_hostid for the booted environment to the hostid it
# actually imported the pool with. What matters on EL is /etc/hostid inside the
# dracut image, which the copy from the live environment plus the dracut run
# above already provides.
#
# [DEVIATION] The guide sets commandline="quiet rhgb". This is a testing rig:
# 'quiet' hides exactly the messages you installed three kernels to read.
zfs set "org.zfsbootmenu:commandline=${KERNEL_CMDLINE}" "${POOL_NAME}/ROOT"
zfs set "org.zfsbootmenu:keysource=${POOL_NAME}/ROOT/${BE_NAME}" "$POOL_NAME"
zfs get -o property,value org.zfsbootmenu:commandline "${POOL_NAME}/ROOT"

#--- [GUIDE] ESP filesystem and mount -----------------------------------------
log "Creating vfat filesystem on the ESP and mounting /boot/efi"
mkfs.vfat -F32 -n EFI "$BOOT_DEVICE"
ESP_UUID="$(blkid -s UUID -o value "$BOOT_DEVICE")"
echo "UUID=${ESP_UUID}	/boot/efi	vfat	umask=0077,shortname=winnt	0	0" >> /etc/fstab
mkdir -p /boot/efi
mount /boot/efi

#==============================================================================
# ZFSBootMenu images
#==============================================================================

log "Downloading ZFSBootMenu ${ZBM_VERSION} images"
dnf install -y curl ca-certificates || warn "curl/ca-certificates may be missing."

# fetch_zbm <build> <kernel> <destination>
#   build = release | recovery
fetch_zbm() {
	local build="$1" kern="$2" dest="$3"
	local fname="zfsbootmenu-${build}-x86_64-${ZBM_VERSION}-linux${kern}.EFI"
	local url="${ZBM_BASE_URL}/${ZBM_VERSION}/${fname}"
	local tmp="/root/${fname}"

	if [[ ! -f "$tmp" ]]; then
		echo "  fetching ${fname}"
		curl -fSL --retry 3 --retry-delay 2 -o "$tmp" "$url" \
			|| { rm -f "$tmp"; echo "download failed: $url" >&2; return 1; }
	fi

	mkdir -p "$(dirname "$dest")"
	cp "$tmp" "$dest"
	return 0
}

# Each image gets its own directory. rEFInd folds kernels only WITHIN a
# directory, so this keeps the vmlinuz name (which is what makes rEFInd
# recognise it as a Linux kernel and apply refind_linux.conf) while still
# giving every image its own top-level menu entry.
#
# write_rlc <directory> <label>
write_rlc() {
	local dir="$1" label="$2"
	cat > "${dir}/refind_linux.conf" <<EOF
"${label} - boot default"      "${ZBM_CMDLINE} zbm.timeout=${ZBM_TIMEOUT}"
"${label} - boot to menu"      "${ZBM_CMDLINE} zbm.show"
"${label} - boot immediately"  "${ZBM_CMDLINE} zbm.skip"
"${label} - verbose debug"     "loglevel=7 zbm.show"
EOF
	return 0
}

INSTALLED_IMAGES=()
RELEASE_IMAGES=()      # "<kernel>:<EFI path>" -- used for NVRAM entries later
RECOVERY_IMAGES=()

for KV in $ZBM_KERNEL_LIST; do
	log "ZFSBootMenu image set for Linux ${KV}"

	if fetch_zbm release "$KV" "/boot/efi/EFI/ZBM-${KV}/vmlinuz.EFI"; then
		write_rlc "/boot/efi/EFI/ZBM-${KV}" "ZBM ${KV}"
		INSTALLED_IMAGES+=("EFI/ZBM-${KV}/vmlinuz.EFI")
		RELEASE_IMAGES+=("${KV}:\\EFI\\ZBM-${KV}\\vmlinuz.EFI")
	else
		warn "Release image for Linux ${KV} could not be installed."
	fi

	if [[ "$ZBM_RECOVERY" == "yes" ]]; then
		if fetch_zbm recovery "$KV" "/boot/efi/EFI/ZBM-RECOVERY-${KV}/vmlinuz.EFI"; then
			write_rlc "/boot/efi/EFI/ZBM-RECOVERY-${KV}" "ZBM RECOVERY ${KV}"
			INSTALLED_IMAGES+=("EFI/ZBM-RECOVERY-${KV}/vmlinuz.EFI")
			RECOVERY_IMAGES+=("${KV}:\\EFI\\ZBM-RECOVERY-${KV}\\vmlinuz.EFI")
		else
			warn "Recovery image for Linux ${KV} could not be installed."
		fi
	fi

	# Backup copy of the release image, in a shared directory. These DO fold
	# into one rEFInd tag on purpose; press F2/Insert to reach the others.
	if [[ "$ZBM_BACKUP" == "yes" ]]; then
		if [[ -f "/boot/efi/EFI/ZBM-${KV}/vmlinuz.EFI" ]]; then
			mkdir -p /boot/efi/EFI/ZBM-BACKUP
			cp "/boot/efi/EFI/ZBM-${KV}/vmlinuz.EFI" \
			   "/boot/efi/EFI/ZBM-BACKUP/vmlinuz-${KV}.EFI"
			INSTALLED_IMAGES+=("EFI/ZBM-BACKUP/vmlinuz-${KV}.EFI")
		fi
	fi
done

if [[ -d /boot/efi/EFI/ZBM-BACKUP ]]; then
	write_rlc /boot/efi/EFI/ZBM-BACKUP "ZBM BACKUP"
fi

if (( ${#INSTALLED_IMAGES[@]} == 0 )); then
	echo "No ZFSBootMenu images were installed. The system will not boot." >&2
	exit 1
fi

rm -f /root/zfsbootmenu-*.EFI
CHROOT_EOF

cat >> /mnt/root/zbm-chroot.sh <<'CHROOT_EOF'

#==============================================================================
# [GUIDE] Configure EFI boot entries
#==============================================================================

mountpoint -q /sys/firmware/efi/efivars || \
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true

REFIND_CONF=/boot/efi/EFI/refind/refind.conf
REFIND_OK=no

#------------------------------------------------------------------------------
# [EL] rEFInd comes from upstream. There is no Alma/Rocky/EPEL package.
#------------------------------------------------------------------------------
# Verified: the rEFInd Fedora package has Fedora branches only (Rawhide/45/44/
# 43) and no epelN branch, and neither Alma 10 nor Rocky 10 ship it in BaseOS,
# AppStream, CRB or extras. So no 'dnf install rEFInd' attempt is made at all --
# it would only waste a round trip and print a confusing "No match" error.
#
# Both assets below are mirrored on a GitHub release, which serves the file
# directly over a redirect. A 404, a captive portal or a proxy login page would
# still come back as 200-and-HTML, so every download is checked for being the
# right file format before it is trusted, and against a sha256 digest as well
# if REFIND_*_SHA256 was set.

refind_fetch() {
	# $1 = url, $2 = destination path, $3 = expected sha256 ("" to skip)
	local url="$1" dest="$2" want="${3:-}" got
	echo "  fetching ${url}"
	if ! curl -fSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$dest" "$url"; then
		warn "Download failed: ${url}"
		rm -f "$dest"
		return 1
	fi
	if [[ ! -s "$dest" ]]; then
		warn "Downloaded file is empty: ${url}"
		rm -f "$dest"
		return 1
	fi
	if [[ -n "$want" ]]; then
		got="$(sha256sum "$dest" | awk '{print $1}')"
		if [[ "$got" != "$want" ]]; then
			warn "sha256 mismatch for ${dest##*/}"
			warn "  expected ${want}"
			warn "  got      ${got}"
			rm -f "$dest"
			return 1
		fi
		echo "  sha256 verified"
	fi
	return 0
}

#------------------------------------------------------------------------------
# rEFInd from the binary zip -- the default and the recommended path
#------------------------------------------------------------------------------
# The zip holds the EFI binaries, drivers, icons, fonts, the refind.conf sample
# and upstream's own refind-install script. Nothing happens until we run that
# script, here, with /boot/efi and efivarfs already mounted and with a visible
# exit status. That is the whole argument for preferring it over the RPM.
install_refind_zip() {
	local tmp=/root/refind-bin dir
	dnf install -y unzip curl || { warn "unzip/curl unavailable; cannot use the rEFInd zip."; return 1; }
	rm -rf "$tmp"; mkdir -p "$tmp"

	refind_fetch "$REFIND_ZIP_URL" /root/refind.zip "$REFIND_ZIP_SHA256" || return 1

	# Catches an HTML error page that arrived with a 200.
	if ! unzip -tq /root/refind.zip >/dev/null 2>&1; then
		warn "The downloaded rEFInd archive is not a valid zip."
		warn "Check REFIND_ZIP_URL -- a 404 or a proxy page looks like this."
		rm -f /root/refind.zip
		return 1
	fi
	unzip -q /root/refind.zip -d "$tmp" || { warn "Could not unpack the rEFInd zip."; return 1; }

	dir="$(find "$tmp" -maxdepth 2 -type d -name 'refind-bin-*' | head -n1)"
	[[ -n "$dir" ]] || dir="$tmp"
	[[ -f "${dir}/refind-install" ]] || { warn "refind-install not found in the archive."; return 1; }
	chmod +x "${dir}/refind-install"

	# --yes suppresses the interactive prompts (shim/Secure Boot questions).
	# Older builds do not know the flag, so fall back to a bare run with stdin
	# closed, which answers every prompt with its default.
	if ! ( cd "$dir" && ./refind-install --yes < /dev/null ); then
		warn "refind-install --yes failed; retrying without the flag."
		( cd "$dir" && ./refind-install < /dev/null ) \
			|| { warn "The bundled refind-install failed."; return 1; }
	fi

	# Keep the sample config and the tools where a future you can find them;
	# dnf will never put them back.
	mkdir -p "/usr/local/share/refind-${REFIND_VERSION}"
	cp -a "${dir}/." "/usr/local/share/refind-${REFIND_VERSION}/" 2>/dev/null || true
	return 0
}

#------------------------------------------------------------------------------
# rEFInd from the upstream RPM -- opt-in
#------------------------------------------------------------------------------
# Kept because you asked for both. Note what you are accepting: an unsigned
# package installed with --nogpgcheck, whose %post runs refind-install inside a
# dnf transaction where a failure does not fail the transaction.
install_refind_rpm() {
	local rpmfile=/root/refind-upstream.rpm

	refind_fetch "$REFIND_RPM_URL" "$rpmfile" "$REFIND_RPM_SHA256" || return 1

	if ! rpm -qp "$rpmfile" >/dev/null 2>&1; then
		warn "The downloaded file is not an RPM."
		warn "Check REFIND_RPM_URL -- a 404 or a proxy page looks like this."
		rm -f "$rpmfile"
		return 1
	fi
	if ! dnf install -y --nogpgcheck "$rpmfile"; then
		warn "The rEFInd RPM failed to install."
		return 1
	fi
	command -v refind-install >/dev/null 2>&1 \
		|| { warn "refind-install not found after the RPM install."; return 1; }
	# The %post has probably already run it. Running it again is idempotent and
	# covers the case where the scriptlet declined to act inside a chroot --
	# which is exactly the failure mode you cannot see from dnf's output.
	if ! refind-install --yes < /dev/null; then
		warn "refind-install --yes failed; retrying without the flag."
		refind-install < /dev/null || { warn "refind-install failed."; return 1; }
	fi
	return 0
}

if [[ "$BOOTLOADER" == "refind" ]]; then
	log "Installing rEFInd from upstream (source: ${REFIND_SOURCE})"
	case "$REFIND_SOURCE" in
		zip) install_refind_zip && REFIND_OK=yes ;;
		rpm) install_refind_rpm && REFIND_OK=yes ;;
		auto)
			if install_refind_zip; then
				REFIND_OK=yes
			else
				warn "The binary zip did not work out; trying the upstream RPM."
				install_refind_rpm && REFIND_OK=yes
			fi
			;;
	esac

	# refind-install picks the ESP itself and does not always land where this
	# script expects, so find the config it actually wrote rather than assuming.
	if [[ "$REFIND_OK" == "yes" ]]; then
		for _c in /boot/efi/EFI/refind/refind.conf /boot/efi/EFI/BOOT/refind.conf /boot/efi/refind.conf; do
			[[ -f "$_c" ]] && { REFIND_CONF="$_c"; break; }
		done
		if [[ ! -f "$REFIND_CONF" ]]; then
			# refind-install copied binaries but no config, or copied the
			# sample under a different name. Recover rather than leave rEFInd
			# running on built-in defaults with no timeout and no folding rules.
			_dir="$(dirname "$REFIND_CONF")"
			mkdir -p "$_dir"
			_sample="$(find /usr/local/share/refind-* /usr/share/refind-* "$_dir" \
				-maxdepth 3 -name 'refind.conf-sample' 2>/dev/null | head -n1)"
			if [[ -n "$_sample" ]]; then
				cp "$_sample" "$REFIND_CONF"
				warn "refind.conf was missing; created it from ${_sample}."
			else
				printf '# created by el10-zbm-install-testing.sh\n' > "$REFIND_CONF"
				warn "refind.conf and refind.conf-sample were both missing; wrote a minimal one."
			fi
		fi
		if ! find /boot/efi/EFI -maxdepth 2 -iname 'refind_x64.efi' | grep -q .; then
			warn "No refind_x64.efi found on the ESP. refind-install reported success but"
			warn "does not appear to have copied anything -- check /boot/efi/EFI."
		fi
	fi

	if [[ "$REFIND_OK" != "yes" ]]; then
		warn "rEFInd was not installed. Falling back to direct EFI entries (the guide's"
		warn "'Direct' variant). You will get your firmware's boot menu instead of rEFInd's:"
		warn "no per-image sub-entries, no zbm.show / zbm.skip choices from the menu."
		BOOTLOADER=efibootmgr
	fi
fi

if [[ "$REFIND_OK" == "yes" ]]; then
	log "Configuring rEFInd (${REFIND_CONF})"

	# [GUIDE] rm /boot/refind_linux.conf
	# refind-install drops one next to the distro kernel, which would make
	# rEFInd offer to boot the EL kernel directly and skip ZFSBootMenu -- and
	# that kernel has no idea how to import an encrypted pool on its own.
	rm -f /boot/refind_linux.conf

	{
		echo ""
		echo "#--- added by el10-zbm-install-testing.sh ----------------------------------"
		echo "# 0 = wait indefinitely. Nothing auto-boots: every ZFSBootMenu image is"
		echo "# listed and you choose. Set a positive number for a countdown once you"
		echo "# have decided which image to keep."
		echo "timeout ${REFIND_TIMEOUT}"
		echo ""
		echo "# LOAD-BEARING. The ZBM images are named vmlinuz*.EFI, which is what makes"
		echo "# rEFInd treat them as Linux kernels and therefore read the"
		echo "# refind_linux.conf sitting next to each one. Turn this off and the four"
		echo "# sub-entries (boot default / boot to menu / boot immediately / verbose"
		echo "# debug) disappear and every image boots with no arguments at all."
		echo "scan_all_linux_kernels true"
		echo ""
		echo "# Left at the default (true) deliberately. Every ZBM image lives in its"
		echo "# own directory, so folding has nothing to group -- except the backups,"
		echo "# which share EFI/ZBM-BACKUP and collapse into a single tag on purpose."
		echo "# Press F2 or Insert on that entry to reach the individual backups."
		echo "fold_linux_kernels true"
		echo ""
		echo "# Nothing is excluded from scanning. The distribution kernel is NOT"
		echo "# reachable from here anyway: it lives in the encrypted ZFS boot"
		echo "# environment, which rEFInd cannot read. The only way it could have"
		echo "# appeared in this menu was via the /boot/refind_linux.conf that"
		echo "# refind-install writes, and the installer deleted that."
		echo ""
		echo "# EFI/BOOT is scanned. Whatever claimed BOOTX64.EFI shows up in the"
		echo "# menu and can be tested like any other entry (rEFInd skips its own)."
		if [[ -n "$REFIND_DEFAULT" ]]; then
			echo ""
			echo "default_selection \"${REFIND_DEFAULT}\""
		else
			echo ""
			echo "# No default_selection: no image is nominated as correct. Add one"
			echo "# yourself once testing tells you which to trust, e.g."
			echo "#   default_selection \"ZBM-6.12\""
		fi
		echo "#--------------------------------------------------------------------------"
	} >> "$REFIND_CONF"

	echo "  rEFInd files on the ESP:"
	find /boot/efi/EFI -maxdepth 2 -iname 'refind*' | sort | sed 's/^/    /'
fi

#------------------------------------------------------------------------------
# Direct NVRAM entries
#------------------------------------------------------------------------------
# [GUIDE] efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu" -l '\EFI\ZBM\VMLINUZ.EFI'
# The guide creates two. A testing rig wants one per image, so the firmware menu
# becomes the image chooser when rEFInd is not in play.
#
# Entries are created newest-last so the LAST one registered ends up first in
# BootOrder -- which on most firmware means the first one highlighted.
register_efi_entries() {
	local spec kv path n=0
	for spec in "${RECOVERY_IMAGES[@]:-}"; do
		[[ -n "$spec" ]] || continue
		kv="${spec%%:*}"; path="${spec#*:}"
		efibootmgr -q -c -d "$DISK_REAL" -p "$BOOT_PART" \
			-L "ZFSBootMenu recovery ${kv}" -l "$path" \
			&& n=$(( n + 1 )) || warn "Could not register NVRAM entry for recovery ${kv}."
	done
	for spec in "${RELEASE_IMAGES[@]:-}"; do
		[[ -n "$spec" ]] || continue
		kv="${spec%%:*}"; path="${spec#*:}"
		efibootmgr -q -c -d "$DISK_REAL" -p "$BOOT_PART" \
			-L "ZFSBootMenu ${kv}" -l "$path" \
			&& n=$(( n + 1 )) || warn "Could not register NVRAM entry for ${kv}."
	done
	echo "  registered ${n} EFI boot entries"
	(( n > 0 ))
}

if [[ "$BOOTLOADER" == "efibootmgr" || "$EFI_ENTRIES_ALWAYS" == "yes" ]]; then
	log "Registering direct EFI boot entries"
	if ! register_efi_entries; then
		warn "No NVRAM boot entries could be registered. The EFI/BOOT/BOOTX64.EFI"
		warn "fallback below is now the only thing that will start this machine."
	fi
	efibootmgr -v 2>/dev/null | head -n 40 || true
fi

#--- Removable-media fallback -------------------------------------------------
# Some firmware silently drops NVRAM boot entries and will only start
# EFI/BOOT/BOOTX64.EFI. refind-install often puts rEFInd there itself, which is
# the better outcome: you reach the full menu rather than one hard-wired image.
# So only fill the slot if it is still empty.
if [[ -e /boot/efi/EFI/BOOT/BOOTX64.EFI ]]; then
	log "EFI/BOOT/BOOTX64.EFI already present (installed by refind-install); left alone"
elif [[ -n "$ZBM_FALLBACK_KERNEL" && -f "/boot/efi/EFI/ZBM-${ZBM_FALLBACK_KERNEL}/vmlinuz.EFI" ]]; then
	log "Installing EFI/BOOT/BOOTX64.EFI fallback (ZBM, Linux ${ZBM_FALLBACK_KERNEL})"
	mkdir -p /boot/efi/EFI/BOOT
	cp "/boot/efi/EFI/ZBM-${ZBM_FALLBACK_KERNEL}/vmlinuz.EFI" \
	   /boot/efi/EFI/BOOT/BOOTX64.EFI
else
	warn "No EFI/BOOT/BOOTX64.EFI fallback installed. If this machine ignores"
	warn "NVRAM boot entries it may not boot without one."
fi

# [EL] grubby and the BLS machinery come along with @core and will keep writing
# /boot/loader/entries on every kernel update. Nothing reads them here -- ZBM
# finds kernels by scanning the boot environment's /boot directly -- but they
# are harmless and leaving them means a future switch back to GRUB is one
# package away. Mentioned so the stray directory does not puzzle you later.
CHROOT_EOF

cat >> /mnt/root/zbm-chroot.sh <<'CHROOT_EOF'

#==============================================================================
# Accounts
#==============================================================================

log "Creating accounts"
dnf install -y sudo passwd shadow-utils || die "Could not install sudo/passwd."
echo "root:${ROOT_PASSWORD}" | chpasswd

# /home/${ADMIN_USER} already exists as a mounted dataset. useradd -m REFUSES
# to populate a directory that already exists -- it prints "Not copying any
# file from skel directory into it" and carries on, silently leaving the
# account with no .bashrc or .bash_profile. So use -M and copy skel by hand.
# useradd ABORTS if any group in -G does not exist, which would leave the
# system with no user account at all. Keep only the groups really present.
WANTED_GROUPS="${ADMIN_GROUPS},wheel"
REAL_GROUPS=""
IFS=',' read -ra _grps <<< "$WANTED_GROUPS"
for _g in "${_grps[@]}"; do
	[[ -z "$_g" ]] && continue
	case ",${REAL_GROUPS}," in *",${_g},"*) continue ;; esac
	if getent group "$_g" >/dev/null 2>&1; then
		REAL_GROUPS="${REAL_GROUPS:+${REAL_GROUPS},}${_g}"
	else
		echo "    skip (no such group): ${_g}"
	fi
done
echo "  groups: ${REAL_GROUPS}"

if [[ -n "$REAL_GROUPS" ]]; then
	useradd -M -d "/home/${ADMIN_USER}" -s /bin/bash \
		-c "$ADMIN_FULLNAME" -G "$REAL_GROUPS" "$ADMIN_USER"
else
	warn "No supplementary groups exist; creating ${ADMIN_USER} without any."
	useradd -M -d "/home/${ADMIN_USER}" -s /bin/bash \
		-c "$ADMIN_FULLNAME" "$ADMIN_USER"
fi

# [EL] 'wheel', not 'sudo'. EL's stock /etc/sudoers enables %wheel, but a
# minimal install is a good place for that assumption to quietly not hold, so
# check and drop in a rule rather than discover it when you need root.
if ! id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx wheel; then
	warn "${ADMIN_USER} is NOT in the wheel group. Use the root account to fix this."
fi
if ! grep -Eq '^[[:space:]]*%wheel[[:space:]]+ALL=\(ALL' /etc/sudoers 2>/dev/null; then
	install -d -m 750 /etc/sudoers.d
	echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/90-wheel
	chmod 0440 /etc/sudoers.d/90-wheel
	warn "%wheel was not enabled in /etc/sudoers; added /etc/sudoers.d/90-wheel."
fi

cp -a /etc/skel/. "/home/${ADMIN_USER}/"
echo "${ADMIN_USER}:${ADMIN_PASSWORD}" | chpasswd
chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}"
chmod 0750 "/home/${ADMIN_USER}"

if [[ ! -f "/home/${ADMIN_USER}/.bashrc" ]]; then
	warn "/home/${ADMIN_USER}/.bashrc missing -- skel copy did not work."
fi

#==============================================================================
# Base userland
#==============================================================================

log "Installing base userland"
dnf install -y \
	NetworkManager openssh-clients openssh-server ca-certificates \
	bash-completion less nano vim-minimal curl wget rsync \
	man-db man-pages pciutils usbutils zstd git tar unzip \
	cryptsetup gdisk util-linux-user policycoreutils policycoreutils-python-utils \
	|| warn "Some base packages failed to install."

# [EL] systemd-timesyncd is not a thing here. chrony is.
dnf_install_available "time sync" chrony
dnf_install_available "diagnostics" smartmontools lm_sensors mlocate tree htop

systemctl enable NetworkManager || warn "NetworkManager could not be enabled."
systemctl enable chronyd        || warn "chronyd could not be enabled."
systemctl enable sshd           || warn "sshd could not be enabled."

if [[ -n "$EXTRA_PACKAGES" ]]; then
	# Deliberately unquoted: EXTRA_PACKAGES is a space-separated list.
	# shellcheck disable=SC2086
	dnf install -y $EXTRA_PACKAGES || warn "Some EXTRA_PACKAGES failed to install."
fi

#==============================================================================
# Desktop
#==============================================================================

# [EL] No group installs. On EL10 the environment/group names move around
# between Alma, Rocky and minor releases ("Workstation", "Server with GUI",
# "KDE Plasma Workspaces" are not all present everywhere), and a group pulls in
# a few hundred packages you did not choose. Explicit package lists are
# predictable, identical on AlmaLinux 10 and Rocky Linux 10, and skip cleanly
# when a name is missing instead of aborting the transaction.

case "$DESKTOP" in
	gnome)
		log "Installing GNOME (${DESKTOP_SIZE})"
		# Everything here is in the EL10 AppStream repository. GNOME is what
		# Red Hat actually ships and supports, so this list is the safe choice.
		dnf_install_available "GNOME session" \
			gnome-shell gnome-session gnome-settings-daemon \
			gnome-control-center gdm \
			mutter gnome-keyring gnome-menus \
			xdg-desktop-portal-gnome
		dnf_install_available "GNOME applications" \
			nautilus gnome-terminal gnome-system-monitor gnome-text-editor \
			gnome-disk-utility gnome-calculator file-roller \
			xdg-user-dirs-gtk
		if [[ "$DESKTOP_SIZE" == "full" ]]; then
			dnf_install_available "GNOME extras" \
				gnome-software gnome-tweaks gnome-characters gnome-logs \
				gnome-color-manager gnome-remote-desktop \
				eog evince totem gnome-weather gnome-calendar gnome-clocks \
				gnome-shell-extension-common gnome-shell-extension-appindicator \
				dconf-editor seahorse simple-scan
		fi
		if ! rpm -q gdm >/dev/null 2>&1; then
			warn "gdm is not installed; GNOME will not start a login screen."
			warn "Check that the AppStream repository is enabled."
			systemctl set-default multi-user.target
		else
			systemctl enable gdm || warn "gdm could not be enabled."
			systemctl set-default graphical.target
		fi
		;;
	kde)
		log "Installing KDE Plasma (${DESKTOP_SIZE})"
		# [EL] Red Hat dropped KDE after EL8. On EL10 every package below comes
		# from EPEL, for BOTH AlmaLinux and Rocky -- neither distribution has a
		# KDE repository of its own. EPEL 10 is also branched per MINOR release
		# (10.0, 10.1, ...), so the Plasma stack can be incomplete for a few
		# weeks after a point release while Qt rebuilds catch up. That is why
		# every name goes through dnf_install_available and why sddm is checked
		# explicitly afterwards.
		if [[ "$ENABLE_EPEL" != "yes" ]]; then
			warn "DESKTOP=kde with ENABLE_EPEL=no. KDE is not in the EL base repositories"
			warn "on either AlmaLinux or Rocky Linux. Nothing below will install."
		fi
		dnf_install_available "Plasma session" \
			plasma-desktop plasma-workspace plasma-workspace-wayland \
			kwin kwin-wayland sddm sddm-breeze sddm-kcm \
			plasma-nm plasma-pa plasma-systemmonitor \
			kscreen kmenuedit breeze-icon-theme \
			xdg-desktop-portal-kde kf6-kio-extras
		dnf_install_available "KDE applications" \
			konsole dolphin kate ark okular gwenview spectacle kcalc \
			kwrite kfind kcharselect
		if [[ "$DESKTOP_SIZE" == "full" ]]; then
			dnf_install_available "KDE extras" \
				plasma-discover kdeplasma-addons kdeconnectd \
				kcolorchooser kruler filelight kdialog \
				khelpcenter kinfocenter print-manager
		fi
		if ! rpm -q sddm >/dev/null 2>&1 || ! rpm -q plasma-workspace >/dev/null 2>&1; then
			warn "The KDE stack is incomplete (sddm and/or plasma-workspace missing)."
			warn "EPEL 10 for this minor release does not have a usable Plasma yet."
			warn "Boot to a text console and either wait for EPEL to catch up, or"
			warn "reinstall with DESKTOP=gnome."
			systemctl set-default multi-user.target
		else
			systemctl enable sddm || warn "sddm could not be enabled."
			systemctl set-default graphical.target
		fi
		;;
	none)
		log "Skipping desktop install"
		systemctl set-default multi-user.target
		;;
esac

if [[ "$DESKTOP" != "none" && "$DESKTOP_EXTRAS" == "yes" ]]; then
	log "Installing desktop integration packages"

	dnf_install_available "session integration" \
		xdg-user-dirs xdg-utils xdg-desktop-portal \
		gvfs gvfs-fuse gvfs-mtp gvfs-smb udisks2 upower

	dnf_install_available "audio" \
		pipewire pipewire-pulseaudio pipewire-alsa wireplumber pipewire-utils

	dnf_install_available "bluetooth" bluez bluez-tools

	# [EL] Codecs are the one place EL is genuinely poorer than Debian: the
	# patent-encumbered gstreamer plugins are not shipped and are not in EPEL.
	# What is here covers free formats; for the rest you want RPM Fusion, which
	# this script deliberately does not enable for you.
	dnf_install_available "codecs" \
		gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-plugin-openh264

	dnf_install_available "archives and filesystems" \
		p7zip p7zip-plugins unzip zip xz ntfs-3g exfatprogs dosfstools

	dnf_install_available "hardware services" fwupd power-profiles-daemon

	dnf_install_available "browser" firefox

	dnf_install_available "fonts" \
		google-noto-sans-fonts google-noto-serif-fonts google-noto-emoji-color-fonts \
		liberation-fonts dejavu-sans-fonts

	if [[ "$INSTALL_MEDIA_ACCEL" == "yes" ]]; then
		dnf_install_available "video acceleration" \
			libva libva-utils libvdpau mesa-va-drivers mesa-vdpau-drivers \
			mesa-vulkan-drivers vulkan-loader intel-media-driver
	fi

	if [[ "$INSTALL_FLATPAK" == "yes" ]]; then
		dnf_install_available "flatpak" flatpak
		case "$DESKTOP" in
			gnome) dnf_install_available "flatpak backend" gnome-software ;;
			kde)   dnf_install_available "flatpak backend" plasma-discover ;;
		esac
	fi

	if [[ "$INSTALL_OFFICE" == "yes" ]]; then
		dnf_install_available "office" \
			libreoffice-writer libreoffice-calc libreoffice-impress
	fi
fi

if [[ "$INSTALL_AUTO_UPDATES" == "yes" ]]; then
	dnf_install_available "automatic updates" dnf-automatic
	systemctl enable dnf-automatic.timer 2>/dev/null || true
fi

#==============================================================================
# [EL] SELinux
#==============================================================================
# Nothing in this section has a Debian counterpart, and skipping it is the most
# likely way to end up at an emergency shell on first boot.
#
# dnf --installroot writes files with whatever labels the HOST policy produced,
# or with none at all where the host had no matching rule. systemd, sshd, gdm
# and the rest then get denied access to their own files. Relabelling rewrites
# every security.selinux xattr from the target's own file_contexts.

log "Configuring SELinux (${SELINUX_MODE}, relabel=${SELINUX_RELABEL})"
dnf_install_available "SELinux policy" selinux-policy selinux-policy-targeted policycoreutils

if [[ -f /etc/selinux/config ]]; then
	sed -i "s/^SELINUX=.*/SELINUX=${SELINUX_MODE}/" /etc/selinux/config
	sed -i "s/^SELINUXTYPE=.*/SELINUXTYPE=targeted/" /etc/selinux/config
else
	warn "/etc/selinux/config is missing; SELinux mode was not set."
fi

if [[ "$SELINUX_MODE" != "disabled" ]]; then
	case "$SELINUX_RELABEL" in
		fixfiles|both)
			# [GUIDE] fixfiles -F -f relabel
			# -F forces a reset of customisable types too; -f skips the prompt.
			# The ESP is vfat and holds no xattrs, so unmount it first rather
			# than wade through thousands of "operation not supported" lines.
			log "Relabelling the filesystem (this takes a while)"
			umount /boot/efi 2>/dev/null || true
			if ! fixfiles -F -f relabel; then
				warn "fixfiles relabel did not complete cleanly."
				warn "Falling back to /.autorelabel so the first boot tries again."
				touch /.autorelabel
			fi
			mount /boot/efi 2>/dev/null || warn "Could not remount /boot/efi after relabel."
			;;
	esac
	case "$SELINUX_RELABEL" in
		autorelabel|both)
			# A second chance that runs under the target's own kernel and
			# policy. Costs one extra reboot on the very first boot and then
			# removes itself. Cheap insurance for a tree assembled in a chroot.
			touch /.autorelabel
			;;
	esac
else
	rm -f /.autorelabel
fi

#--- Cleanup ------------------------------------------------------------------
log "Cleaning up"
rm -rf /root/refind-bin /root/refind.zip /root/refind-upstream.rpm
dnf -y autoremove || true
dnf clean all || true

log "ESP contents"
find /boot/efi/EFI -maxdepth 2 \( -name '*.EFI' -o -name '*.efi' \) | sort
df -h /boot/efi
CHROOT_EOF

chmod 700 /mnt/root/zbm-chroot.sh

#==============================================================================
# Run the chroot stage
#==============================================================================

log "Entering chroot"
chroot /mnt /usr/bin/env bash /root/zbm-chroot.sh

#==============================================================================
# Baseline boot environment
#==============================================================================

log "Removing installer artefacts"
rm -f /mnt/root/zbm-install.env /mnt/root/zbm-chroot.sh

if [[ "$BASELINE_MODE" != "none" ]]; then
	log "Creating factory baseline boot environment (${BASELINE_MODE})"
	zfs snapshot "${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}"
	if [[ "$BASELINE_MODE" == "clone" ]]; then
		zfs clone -o canmount=noauto -o mountpoint=/ \
			"${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}" \
			"${POOL_NAME}/ROOT/${BASELINE_NAME}"
	else
		zfs send "${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}" | \
			zfs recv -u "${POOL_NAME}/ROOT/${BASELINE_NAME}"
		zfs set canmount=noauto "${POOL_NAME}/ROOT/${BASELINE_NAME}"
		zfs set mountpoint=/    "${POOL_NAME}/ROOT/${BASELINE_NAME}"
	fi
fi

#==============================================================================
# Finish
#==============================================================================

log "Final dataset layout"
zfs list -o name,used,refer,mountpoint,canmount -r "$POOL_NAME"

if [[ -s /mnt/root/INSTALL-WARNINGS.txt ]]; then
	echo
	warn "Warnings were recorded during installation:"
	sed 's/^/    /' /mnt/root/INSTALL-WARNINGS.txt >&2
	warn "Kept at /root/INSTALL-WARNINGS.txt on the new system."
fi

log "Unmounting and exporting the pool"
umount -n -R /mnt || {
	warn "Lazy-unmounting stragglers"
	umount -n -R -l /mnt || true
}
sleep 2
zpool export "$POOL_NAME"

log "Done"
cat <<EOF

Installation complete. Remove the live medium and reboot.

$( [[ "$OTHER_POOL" == yes ]] && printf '%s\n' \
"POOL NAME COLLISION -- READ THIS" \
"  Another pool named '${POOL_NAME}' exists on a different disk in this machine." \
"  Only one pool of a given name can be imported at a time, so ZFSBootMenu will" \
"  see both and use only one of them. If the wrong one wins you will not boot." \
"  Either disconnect or rename the other pool, or reinstall with a unique" \
"  POOL_NAME. To rename the OTHER pool from a live ISO:" \
"      zpool export ${POOL_NAME}" \
"      zpool import <guid-of-the-other-pool> othername" \
"" )
WHAT YOU WILL SEE
  firmware -> ${BOOTLOADER} -> (a ZFSBootMenu image you pick) -> ${POOL_NAME}/ROOT/${BE_NAME}

$( [[ "$BOOTLOADER" == refind ]] && printf '%s\n' \
"  rEFInd lists one entry per ZFSBootMenu image, plus one folded entry for the" \
"  backups and one for the EFI/BOOT fallback copy. Nothing is marked default and" \
"  the timeout is ${REFIND_TIMEOUT} (0 = wait forever), so the menu sits there until you" \
"  choose. Each entry has four sub-entries (F2 or Insert to open):" \
"      boot default      ${ZBM_TIMEOUT}s countdown, then boots bootfs" \
"      boot to menu      always show the boot-environment selector" \
"      boot immediately  no menu, no countdown" \
"      verbose debug     loglevel=7, ZBM's full internal tracing" )
$( [[ "$BOOTLOADER" == efibootmgr ]] && printf '%s\n' \
"  There is no rEFInd. Your firmware's own boot menu (usually F8/F11/F12 during" \
"  POST) lists one entry per ZFSBootMenu image. There are no sub-entries, so to" \
"  reach the boot-environment selector use ZFSBootMenu's own hotkeys once it" \
"  starts, or edit the images' refind_linux.conf is NOT relevant here -- instead" \
"  set the countdown with:  zfs set org.zfsbootmenu:timeout=-1 ${POOL_NAME}" \
"  Review and reorder the entries with:  efibootmgr -v  /  efibootmgr -o ..." )

$( [[ "$SELINUX_MODE" != disabled ]] && printf '%s\n' \
"FIRST BOOT RELABELS ITSELF" \
"  /.autorelabel was left in place, so the very first boot walks the whole" \
"  filesystem rewriting SELinux labels and then REBOOTS ON ITS OWN. That is" \
"  expected, it takes a few minutes, and it only happens once. Do not interrupt" \
"  it. If you land in an emergency shell instead, boot a ZBM recovery image," \
"  import the pool, chroot in and run:  fixfiles -F -f relabel" \
"" )
NOW GO FIND OUT WHICH IMAGE WORKS
  Kernels installed: ${SELECTED_KERNELS[*]}

  All of these embed the SAME OpenZFS. They differ only in Linux kernel, so
  the question is purely whether the kernel can see your disk controller,
  keyboard and display. Boot each once and note:

    - does it reach the ZFSBootMenu prompt at all?
    - is your keyboard usable at the passphrase prompt?
    - does it find and import ${POOL_NAME}?
    - how long does it take?

$( [[ "$BOOTLOADER" == refind ]] && printf '%s\n' \
"  Then pin your winner by adding a default_selection to refind.conf:" \
"    sudo nano /boot/efi/EFI/refind/refind.conf" \
"      default_selection \"ZBM-6.12\"" \
"      timeout 5" \
"  and, if you want the firmware fallback to match:" \
"    sudo cp /boot/efi/EFI/ZBM-<ver>/vmlinuz.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI" \
"" \
"  Removing the images you rejected is just deleting their directory under" \
"  /boot/efi/EFI/ -- rEFInd rescans the ESP on every boot, nothing to regenerate." )
$( [[ "$BOOTLOADER" == efibootmgr ]] && printf '%s\n' \
"  Then pin your winner by putting its entry first in BootOrder:" \
"    sudo efibootmgr -v            # find the Boot#### number you want" \
"    sudo efibootmgr -o 0003,0001  # winner first" \
"  and delete the ones you rejected:" \
"    sudo efibootmgr -b 0005 -B" \
"  Their files under /boot/efi/EFI/ can go too." )

ZFS PACKAGING ON EL -- THE THING THAT WILL BITE YOU
  This install uses ${ZFS_PKG_STYLE} packages from the '${ZFS_BRANCH}' OpenZFS
  branch at zfsonlinux.org, NOT the conservative default. Check what you got:
    zfs version
    dnf repolist enabled | grep zfs

  Only one zfs* repository is enabled. Keep it that way: with two enabled, a
  future 'dnf update' will quietly migrate you to whichever carries the higher
  version, and a pool created on the newer branch may then refuse to import on
  the older one. To change branch deliberately:
    sudo dnf config-manager setopt 'zfs*.enabled=0'
    sudo dnf config-manager setopt zfs-legacy.enabled=1    # or zfs-2.3, zfs-latest, ...
    sudo dnf distro-sync 'zfs*' 'libzfs*' 'libzpool*' 'libnvpair*' 'libuutil*'
  Downgrading a branch AFTER the pool has enabled newer features will not work.
  Check first:  zpool get all ${POOL_NAME} | grep feature | grep -v disabled
$( [[ "$ZFS_PKG_STYLE" == dkms ]] && printf '%s\n' \
"  DKMS rebuilds the module for every new kernel, during the dnf transaction." \
"  If that build fails -- and on a .0 release of a new EL major it sometimes" \
"  does -- you get a kernel with no ZFS and a root you cannot mount. Two habits" \
"  make that survivable:" \
"    1. Snapshot the BE before every kernel update:" \
"         sudo zfs snapshot ${POOL_NAME}/ROOT/${BE_NAME}@pre-\$(date +%F)" \
"       ZFSBootMenu can boot a snapshot directly, so a bad update is one menu" \
"       entry away from undone." \
"    2. Keep the old kernel. EL does by default (installonly_limit=3); do not" \
"       lower it." )
$( [[ "$ZFS_PKG_STYLE" == kmod ]] && printf '%s\n' \
"  kABI-tracking kmods do not rebuild, which is faster but means a kernel that" \
"  steps outside the tracked kABI leaves you with no ZFS module at all. Snapshot" \
"  before kernel updates and keep the previous kernel installed:" \
"    sudo zfs snapshot ${POOL_NAME}/ROOT/${BE_NAME}@pre-\$(date +%F)" )

  To exclude kernel updates until you choose to take them:
    sudo dnf config-manager setopt excludepkgs=kernel\*
  and update deliberately with:
    sudo dnf --disableexcludes=all update kernel\*

rEFInd IS NOT PACKAGED BY YOUR DISTRIBUTION
  Installed from ${REFIND_SOURCE} at:
    ${REFIND_ASSET_BASE}
  Not from Alma, Rocky or EPEL -- none of which ship rEFInd at all. dnf will
  therefore never update it. When upstream cuts a new release, fetch the new
  asset and re-run upstream's installer by hand:
    cd /usr/local/share/refind-${REFIND_VERSION} && sudo ./refind-install --yes
  (the zip path keeps a copy of the whole tree there for exactly this).
  Nothing else on this system knows rEFInd exists, so nothing else will keep it
  current -- and nothing else will break it either.

NOT INSTALLED, ON PURPOSE
  * RPM Fusion. EL ships no patent-encumbered codecs and EPEL does not carry
    them either, so h264/h265/mp3 playback in the stock gstreamer stack is
    partial. If you want the rest, enable RPM Fusion yourself -- it is a
    third-party repository and this script will not add one behind your back.
  * cups/avahi printing. Add with:
      sudo dnf install cups cups-filters avahi$( [[ "$DESKTOP" == gnome ]] && echo " system-config-printer" )$( [[ "$DESKTOP" == kde ]] && echo " print-manager" )
      sudo systemctl enable --now cups

RECOVERY IMAGES
  EFI/ZBM-RECOVERY-* include networking, curl, sgdisk and cryptsetup. Keep at
  least one even after you have picked a favourite: it is the difference
  between fixing a broken pool from the boot menu and going to find a USB
  stick.

BOOT VERBOSITY
  'quiet' and 'rhgb' are set nowhere, unlike the guide's default.
    ZFSBootMenu's own kernel : ${ZBM_CMDLINE}
    ${DISTRO_ID}'s kernel    : ${KERNEL_CMDLINE}

  Change the OS kernel's cmdline without touching the bootloader:
    sudo zfs set org.zfsbootmenu:commandline="loglevel=7 rd.luks=0" ${POOL_NAME}/ROOT
$( [[ "$BOOTLOADER" == refind ]] && printf '%s\n' \
"  Change ZFSBootMenu's own: edit the refind_linux.conf inside each" \
"  /boot/efi/EFI/ZBM-*/ directory. No regeneration needed." )

  rd.luks=0 is in there deliberately. Drop it only if you add a LUKS volume
  that genuinely has to be unlocked from the initramfs; the swap volume does
  not, and leaving dracut free to try makes the boot hang at a passphrase
  prompt for a key that lives on the not-yet-mounted root.

DRACUT, NOT initramfs-tools
  After anything that changes /etc/dracut.conf.d or the pool key:
    sudo dracut --force --regenerate-all
  Verify the key really made it in:
    sudo lsinitrd /boot/initramfs-\$(uname -r).img | grep ${POOL_NAME}.key

NEW BOOT ENVIRONMENTS
  canmount is NOT inheritable. Set it explicitly or the system will try to
  mount two filesystems at / and fail to boot:
    sudo zfs snapshot ${POOL_NAME}/ROOT/${BE_NAME}@pre-upgrade
    sudo zfs clone -o canmount=noauto -o mountpoint=/ \\
        ${POOL_NAME}/ROOT/${BE_NAME}@pre-upgrade ${POOL_NAME}/ROOT/new

NEW USERS
  useradd will NOT copy /etc/skel into a home directory that already exists,
  and a per-user dataset makes it exist:
    sudo zfs create -o mountpoint=/home/NAME ${POOL_NAME}/data/home/NAME
    sudo useradd -M -d /home/NAME -s /bin/bash -G wheel NAME
    sudo cp -a /etc/skel/. /home/NAME/
    sudo chown -R NAME:NAME /home/NAME && sudo chmod 0750 /home/NAME
    sudo passwd NAME
    sudo restorecon -R /home/NAME      # SELinux: the new dataset has no labels

POOL FEATURES AND UPGRADES
  Pool compatibility: ${POOL_COMPATIBILITY:-none -- every feature the installed zfs supports}
  ZFSBootMenu ${ZBM_VERSION} images embed OpenZFS 2.4.0, and ZFS_BRANCH=${ZFS_BRANCH} means
  the installed userland is on the newest branch too. Same major version on
  both sides is the point: the pool can use everything and the boot images can
  still read it.

  What breaks that pairing, in order of likelihood:
    1. Replacing these ZBM images with an OLDER release after a zpool upgrade.
       Do any image downgrade BEFORE the upgrade, never after.
    2. Switching ZFS_BRANCH downwards later. See the previous section.
    3. A future OpenZFS branch that outruns the ZBM images you have. Check the
       ZBM release notes for the embedded OpenZFS version before upgrading
       either side, and upgrade the images first.
$( [[ -n "$POOL_COMPATIBILITY" ]] && printf '%s\n' \
"  To lift the compatibility pin later:" \
"    sudo zpool set compatibility=off ${POOL_NAME}" \
"    sudo zpool upgrade ${POOL_NAME}" )

SELINUX
  Mode: ${SELINUX_MODE}. If something that worked on Debian is mysteriously
  denied here, that is the first place to look:
    sudo ausearch -m avc -ts recent
    sudo sealert -a /var/log/audit/audit.log      # setroubleshoot, if installed
  Temporarily, to confirm SELinux is the culprit and not something else:
    sudo setenforce 0        # permissive until reboot

EOF
