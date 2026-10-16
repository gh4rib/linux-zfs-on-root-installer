#!/usr/bin/env bash
#
#==============================================================================
# fedora-zbm-install-testing.sh
#
#   Fedora (43/44/45), root on encrypted ZFS, rEFInd -> ZFSBootMenu.
#   TESTING VARIANT: installs every ZFSBootMenu binary image you ask for
#   (release + recovery, Linux 6.6 / 6.12 / 6.18) side by side, plus a backup
#   copy of each release image, so you can find out empirically which one
#   drives your hardware.
#
#   Sibling of debian13-zbm-install-testing.sh and el10-zbm-install-testing.sh.
#   Same ESP layout, same testing philosophy, same ZFS dataset tree.
#==============================================================================
#
# There is no ZFSBootMenu guide for Fedora. This follows the AlmaLinux UEFI
# guide for the ZFS and ZFSBootMenu half:
#   https://docs.zfsbootmenu.org/en/v3.1.x/guides/almalinux/uefi.html
# and OpenZFS's own Fedora page for the packaging half:
#   https://openzfs.github.io/openzfs-docs/Getting%20Started/Fedora/index.html
#
# Guide steps are tagged [GUIDE]; departures are tagged [DEVIATION];
# things that exist only because this is Fedora are tagged [FEDORA].
#
#------------------------------------------------------------------------------
# WHAT IS DIFFERENT FROM THE ALMA / ROCKY SCRIPT
#------------------------------------------------------------------------------
# Good news first:
#
#   rEFInd IS PACKAGED. Fedora ships it as 'rEFInd' (capitals), currently
#   0.14.2, built for F43, F44 and F45, maintained by ngompa/dcavalca/sentry.
#   No SourceForge download, no GitHub mirror, no unsigned RPM, no
#   --nogpgcheck. 'dnf install rEFInd' and you are done. This is the single
#   biggest reason to prefer Fedora over EL for this particular setup.
#
#   The EFI binaries live in a separate 'rEFInd-unsigned-x64' subpackage and
#   the helper scripts in 'rEFInd-tools'. The script installs all three,
#   because which one carries refind-install has moved between builds.
#
# Now the bad news, which is all one problem wearing three hats:
#
#   FEDORA KERNELS MOVE FASTER THAN OpenZFS DOES.
#
#   Fedora ships a new kernel most weeks and jumps a whole major version every
#   release (F45 is on Linux 7.2). OpenZFS supports a kernel when it supports
#   it. On EL you get a kernel that barely moves for a decade; here you get one
#   that can outrun the only filesystem your root is on. Three consequences:
#
#     1. DKMS ONLY. There is no kABI-tracking kmod repo for Fedora -- the
#        concept does not apply to a kernel that changes ABI constantly. Every
#        kernel update rebuilds the module, and a rebuild can fail.
#     2. A failed rebuild gives you a newly-installed default kernel with no
#        zfs.ko. ZFSBootMenu will happily offer it and it will not boot.
#        KERNEL_POLICY below decides how hard the script works to stop that.
#     3. Upgrading Fedora releases is a real event, not a background task. Do
#        it from a snapshot, with a ZBM recovery image to hand.
#
#   Other Fedora-only items the script handles:
#     * zfs-fuse. Fedora's own repositories carry this ancient FUSE
#       implementation and it conflicts with real ZFS. OpenZFS's docs open
#       with "remove it first, it should not be used under any circumstance".
#       The script excludes it and removes it if it appears.
#     * The ZFS repo lives at zfsonlinux.org/FEDORA, not /epel, and its
#       default 'zfs' repo is already the newest OpenZFS branch -- the EL
#       zfs-latest / zfs-legacy split does not exist here.
#     * kernel-devel must be installed BEFORE the zfs package, not after.
#     * Secure Boot. DKMS modules are unsigned, and Fedora's rEFInd is in an
#       '-unsigned-' subpackage for a reason. With Secure Boot on, neither
#       will load. The script detects this and tells you before it is too
#       late to care.
#     * Fedora 45 moved repository configuration from /etc to /usr and turned
#       on RPM signature enforcement. Both are handled below.
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
# NOTE ON OpenZFS VERSION: Fedora's default zfs repo is already the newest
# released branch -- the thing the EL script has to switch to deliberately. So
# userland and the ZBM images are both on 2.4.x and the pool is created with NO
# compatibility pin. Set POOL_COMPATIBILITY if you want the cautious version.
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
# Disk layout on $DISK (a /dev/disk/by-id/... path; GPT, fully wiped)
#------------------------------------------------------------------------------
#   -part1   2048 MiB (default)   ef00   ESP -> /boot/efi
#   -part2   1024 MiB          8309/8200 encrypted swap (plain dm-crypt default)
#   -part3   rest - 10 MiB        bf00   zroot
#
#------------------------------------------------------------------------------
# Usage
#------------------------------------------------------------------------------
#   Boot a Fedora LIVE image in UEFI mode (Workstation or KDE spin both work),
#   then:
#
#   sudo -i
#   DISK=/dev/disk/by-id/nvme-... ZBM_KERNELS=all ADMIN_USER=alireza \
#   TIMEZONE=Europe/Berlin DESKTOP=gnome ./fedora-zbm-install-testing.sh
#
#   A live session has a small zram-backed overlay and the DKMS build needs
#   room. If the build dies with no space left, reboot the live image and add
#   rd.live.overlay.size=8192 to its kernel command line.
#
# Run with DISK unset to list candidate disks.
# Run with LIST_KEYBOARD=yes to list keyboard variants for your layout.
#
# THIS DESTROYS ALL DATA ON $DISK.
#==============================================================================

set -euo pipefail

#==============================================================================
# [FEDORA] Identify the live environment
#==============================================================================

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
# Fedora stores the X11/Wayland layout in /etc/X11/xorg.conf.d/00-keyboard.conf
# (written by localectl) and the console keymap in /etc/vconsole.conf.

_LIVE_XKBLAYOUT=""
_LIVE_XKBVARIANT=""
if [[ -r /etc/X11/xorg.conf.d/00-keyboard.conf ]]; then
	_LIVE_XKBLAYOUT="$(awk -F'"' '/XkbLayout/{print $4; exit}'  /etc/X11/xorg.conf.d/00-keyboard.conf 2>/dev/null || true)"
	_LIVE_XKBVARIANT="$(awk -F'"' '/XkbVariant/{print $4; exit}' /etc/X11/xorg.conf.d/00-keyboard.conf 2>/dev/null || true)"
fi
if [[ -z "$_LIVE_XKBLAYOUT" && -r /etc/vconsole.conf ]]; then
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

#--- [FEDORA] Release ---------------------------------------------------------
# Detected from the live image. Installing across releases works but means the
# live kernel and the target kernel differ, which is one more thing to debug
# if the DKMS build misbehaves.
RELEASEVER="${RELEASEVER:-${LIVE_MAJOR:-44}}"

# What dnf installs into the empty root. Fedora's @core is a genuine minimal
# system, unlike EL's; @minimal-environment is roughly the same thing with a
# different name depending on release.
BASE_GROUP="${BASE_GROUP:-@core}"

#--- [FEDORA] ZFS packaging ---------------------------------------------------
# NOTE THE PATH: /fedora, not /epel. Different repo, different package set.
ZFS_RELEASE_PKG="${ZFS_RELEASE_PKG:-zfs-release-3-0}"
ZFS_RELEASE_BASE="${ZFS_RELEASE_BASE:-https://zfsonlinux.org/fedora}"

# [FEDORA] Fedora 45 enforces RPM signature checking by default. The
# zfs-release package is signed with the OpenZFS key -- which the system does
# not trust yet, because trusting it is what zfs-release is for. Importing the
# key first breaks that circle without reaching for --nogpgcheck.
# Signing key 2 covers EL9+ and Fedora 37+.
ZFS_GPG_KEY_URL="${ZFS_GPG_KEY_URL:-https://raw.githubusercontent.com/zfsonlinux/zfsonlinux.github.com/master/zfs-release/RPM-GPG-KEY-openzfs-key2}"
ZFS_GPG_FINGERPRINT="${ZFS_GPG_FINGERPRINT:-7DC7299DCF7C7FD9CD87701BA599FD5E9DB84141}"

# default : the 'zfs' repo. On Fedora this is ALREADY the newest released
#           OpenZFS branch -- the thing the EL script has to opt into.
# testing : the 'zfs-testing' repo, OpenZFS under active development. Only if
#           the stable branch does not build against your kernel yet and you
#           would rather run a pre-release than an older kernel.
ZFS_BRANCH="${ZFS_BRANCH:-default}"

# [FEDORA] There is no kmod option. Fedora's kernel changes ABI too often for
# kABI-tracking packages to mean anything, so OpenZFS does not build them.
# This variable exists only to say so out loud.
ZFS_PKG_STYLE="dkms"

#--- [FEDORA] Kernel update policy --------------------------------------------
# The core Fedora-on-ZFS problem: a kernel update whose DKMS build fails leaves
# you with a default kernel that cannot mount root.
#
# protect : write /etc/dnf/protected.d/zfs.conf so dnf refuses to remove the
#           zfs packages, and print the manual update ritual at the end.
#           Kernels still update. THIS IS THE DEFAULT -- it does not silently
#           freeze your kernel, which also means it does not silently freeze
#           your kernel security fixes.
# pin     : the above, plus exclude=kernel* in /etc/dnf/dnf.conf, so kernels
#           only move when you say so. Safest for an unattended machine, at
#           the cost of having to remember.
# none    : neither. You are on your own.
KERNEL_POLICY="${KERNEL_POLICY:-protect}"

# zfs-fuse is a different, obsolete project that happens to share the name and
# conflicts with real ZFS. OpenZFS's Fedora page opens by telling you to remove
# it. Excluding it costs nothing.
EXCLUDE_ZFS_FUSE="${EXCLUDE_ZFS_FUSE:-yes}"

#--- ZFSBootMenu image selection ----------------------------------------------
ZBM_VERSION="${ZBM_VERSION:-v3.1.0}"
ZBM_BASE_URL="${ZBM_BASE_URL:-https://github.com/zbm-dev/zfsbootmenu/releases/download}"

# Which Linux kernel series to install images for.
#   all            -> 6.6 6.12 6.18
#   "6.12"         -> just that one
#   "6.6 6.18"     -> any space-separated subset
ZBM_KERNELS="${ZBM_KERNELS:-all}"

ZBM_RECOVERY="${ZBM_RECOVERY:-yes}"
ZBM_BACKUP="${ZBM_BACKUP:-yes}"
ZBM_FALLBACK_KERNEL="${ZBM_FALLBACK_KERNEL:-6.12}"

#--- [FEDORA] Boot manager ----------------------------------------------------
# refind     : rEFInd menu in front of ZFSBootMenu. Comes from Fedora's own
#              repository, so this is the easy path here.
# efibootmgr : no rEFInd; one firmware NVRAM entry per ZBM image, which is the
#              guide's "Direct" variant scaled up to a testing rig.
BOOTLOADER="${BOOTLOADER:-refind}"

# Fedora's rEFInd package set. All three are attempted; which one carries
# refind-install has moved between builds, and the EFI binaries themselves are
# in the -unsigned-x64 subpackage.
REFIND_PACKAGES="${REFIND_PACKAGES:-rEFInd rEFInd-tools rEFInd-unsigned-x64}"

# Register NVRAM entries for every release/recovery image even when rEFInd went
# in fine. Harmless, and it means a firmware that refuses to chainload still
# reaches a menu. Costs you a long F-key boot list.
EFI_ENTRIES_ALWAYS="${EFI_ENTRIES_ALWAYS:-no}"

#--- rEFInd -------------------------------------------------------------------
REFIND_TIMEOUT="${REFIND_TIMEOUT:-30}"
# Left EMPTY on purpose: no image is nominated as "the" default, so rEFInd
# highlights the first entry and lets you choose.
REFIND_DEFAULT="${REFIND_DEFAULT:-}"

#--- Kernel command lines -----------------------------------------------------
# ZBM_CMDLINE     configures ZFSBootMenu's OWN kernel (via refind_linux.conf).
# KERNEL_CMDLINE  is org.zfsbootmenu:commandline, i.e. what ZBM hands to Fedora.
# Both verbose: 'quiet' and 'rhgb' appear nowhere.
#
# rd.luks=0 is deliberate. dracut's crypt module reads /etc/crypttab and will
# try to unlock the swap volume from the initramfs -- where the keyfile (which
# lives on the not-yet-mounted ZFS root) does not exist, so it prompts for a
# passphrase that was never set and the boot stalls. Root is ZFS and needs no
# LUKS that early, so switching the mechanism off is the clean fix.
ZBM_CMDLINE="${ZBM_CMDLINE:-loglevel=6}"
KERNEL_CMDLINE="${KERNEL_CMDLINE:-loglevel=6 systemd.show_status=yes rd.luks=0}"
ZBM_TIMEOUT="${ZBM_TIMEOUT:-30}"

#--- Partition sizes (MiB) ----------------------------------------------------
ESP_SIZE_MIB="${ESP_SIZE_MIB:-2048}"
SWAP_SIZE_MIB="${SWAP_SIZE_MIB:-1024}"

#--- Swap ---------------------------------------------------------------------
# luks   : persistent LUKS2, unlocked from a random 512-byte keyfile on the
#          encrypted root. Root is already open when crypttab is processed, so
#          it never prompts. Partition type 8309 (Linux LUKS).
# random : plain dm-crypt, fresh key every boot. Nothing survives a reboot.
#          Partition type 8200 (Linux swap) -- typing it 8309 makes
#          systemd-gpt-auto-generator try to unlock it as LUKS, which fails and
#          drags the real swap unit down with it. THIS IS THE DEFAULT.
# none   : no swap partition at all
#
# Hibernation is not configured either way; the dracut resume module is omitted.
SWAP_MODE="${SWAP_MODE:-random}"
SWAP_RANDOM_SOURCE="${SWAP_RANDOM_SOURCE:-/dev/urandom}"
SWAP_CIPHER="${SWAP_CIPHER:-aes-xts-plain64}"
SWAP_KEYSIZE="${SWAP_KEYSIZE:-512}"
SWAP_MAPPER="${SWAP_MAPPER:-cswap}"

#--- ZFS ----------------------------------------------------------------------
POOL_NAME="${POOL_NAME:-zroot}"
BE_NAME="${BE_NAME:-fedora}"
BASELINE_NAME="${BASELINE_NAME:-baseline}"
BASELINE_MODE="${BASELINE_MODE:-clone}"     # clone | send | none
ASHIFT="${ASHIFT:-12}"
COMPRESSION="${COMPRESSION:-lz4}"
ENCRYPTION_ALGO="${ENCRYPTION_ALGO:-aes-256-gcm}"
DATASET_TUNING="${DATASET_TUNING:-yes}"
# Empty on purpose: Fedora's zfs IS the newest branch and the ZBM v3.1.0 images
# embed 2.4.0, so both sides agree and the pool can use everything. Set to
# openzfs-2.3-linux (or similar) only if you intend to downgrade one side.
POOL_COMPATIBILITY="${POOL_COMPATIBILITY:-}"

#--- Identity -----------------------------------------------------------------
TARGET_HOSTNAME="${TARGET_HOSTNAME:-fedora-zbm}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_FULLNAME="${ADMIN_FULLNAME:-System Administrator}"
# 'wheel' is the sudo group. No adm/plugdev/netdev/cdrom here.
ADMIN_GROUPS="${ADMIN_GROUPS:-wheel,users,audio,video,dialout}"

#--- Locale / time / keyboard -------------------------------------------------
TIMEZONE="${TIMEZONE:-Etc/UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-${_LIVE_XKBLAYOUT:-us}}"
KEYBOARD_VARIANT="${KEYBOARD_VARIANT-${_LIVE_XKBVARIANT}}"
# The console keymap is a separate namespace from the XKB layout. For
# us/de/fr/es/it the names coincide; for anything exotic set this yourself.
VCONSOLE_KEYMAP="${VCONSOLE_KEYMAP:-${KEYMAP}}"

#--- Repositories -------------------------------------------------------------
# [FEDORA] No EPEL, no CRB -- Fedora is the upstream those exist to backfill.
# RPM Fusion is the only third-party repo worth considering, for codecs and
# NVIDIA drivers. Off by default: this script does not enable third-party
# repositories behind your back.
ENABLE_RPMFUSION="${ENABLE_RPMFUSION:-no}"

INSTALL_FIRMWARE="${INSTALL_FIRMWARE:-yes}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

#--- SELinux ------------------------------------------------------------------
# enforcing : the Fedora default and what you should run
# permissive: logs denials, blocks nothing. Useful the first week.
# disabled  : deprecated on modern Fedora and only half works; prefer permissive.
SELINUX_MODE="${SELINUX_MODE:-enforcing}"
# fixfiles    : relabel inside the chroot, at the end of the install
# autorelabel : drop /.autorelabel and let the first boot do it
# both        : belt and braces. THE DEFAULT -- an unlabelled root is an
#               emergency shell, not a boot.
SELINUX_RELABEL="${SELINUX_RELABEL:-both}"

#--- Desktop ------------------------------------------------------------------
# Both are MINIMAL package lists by default: a session that starts, a login
# manager, a file manager, a terminal, settings. Not the Workstation or KDE
# spin package set, which is several hundred packages of things you did not
# choose. DESKTOP_SIZE=full adds the usual applications.
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
# [FEDORA] dnf5
#------------------------------------------------------------------------------
# Fedora has been on dnf5 since F41. The dnf4 spellings are kept as fallbacks
# only so this still works if you point it at an older release.
dnf_enable_repo() {
	dnf -y config-manager setopt "${1}.enabled=1" 2>/dev/null && return 0
	dnf -y config-manager --set-enabled "$1"      2>/dev/null && return 0
	return 1
}

#------------------------------------------------------------------------------
# [FEDORA] Secure Boot detection
#------------------------------------------------------------------------------
# Two things in this install are unsigned: the DKMS-built zfs.ko and Fedora's
# rEFInd, which ships its binaries in a package literally named
# rEFInd-unsigned-x64. With Secure Boot enabled, neither loads, and the symptom
# is an unhelpful "Key was rejected by service" or a firmware that silently
# refuses to start the boot manager. Better to say so now.
secureboot_state() {
	local f v
	f="$(find /sys/firmware/efi/efivars -maxdepth 1 -name 'SecureBoot-*' 2>/dev/null | head -n1)"
	if [[ -n "$f" ]]; then
		# 4-byte EFI variable attribute prefix, then one byte of value.
		v="$(od -An -t u1 -j 4 -N 1 "$f" 2>/dev/null | tr -d ' ')"
		case "$v" in
			1) printf 'enabled';  return 0 ;;
			0) printf 'disabled'; return 0 ;;
		esac
	fi
	if command -v mokutil >/dev/null 2>&1; then
		if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then printf 'enabled'; return 0; fi
		if mokutil --sb-state 2>/dev/null | grep -qi 'disabled'; then printf 'disabled'; return 0; fi
	fi
	printf 'unknown'
	return 0
}

#==============================================================================
# Preflight
#==============================================================================

[[ $EUID -eq 0 ]] || die "Run this script as root (sudo -i)."
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode. This script is UEFI-only."
command -v dnf >/dev/null || die "No dnf in the live environment. Is this really a Fedora live image?"

case "$LIVE_ID" in
	fedora) ;;
	"") warn "Could not read /etc/os-release; assuming a Fedora live environment." ;;
	*)  warn "Live environment reports ID='${LIVE_ID}', not fedora."
	    warn "If this is AlmaLinux or Rocky, use el10-zbm-install-testing.sh instead:"
	    warn "the ZFS repo path, the kmod option and the rEFInd source are all different." ;;
esac
if [[ -n "$LIVE_MAJOR" && "$LIVE_MAJOR" != "$RELEASEVER" ]]; then
	warn "Live environment is Fedora ${LIVE_MAJOR} but RELEASEVER=${RELEASEVER}."
	warn "This works, but the live kernel and the installed kernel will differ, which"
	warn "makes a DKMS failure harder to attribute. Prefer matching live media."
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
case "$BOOTLOADER"      in refind|efibootmgr)     ;; *) die "BOOTLOADER must be refind or efibootmgr." ;; esac
case "$ZFS_BRANCH"      in default|testing)       ;; *) die "ZFS_BRANCH must be default or testing." ;; esac
case "$KERNEL_POLICY"   in protect|pin|none)      ;; *) die "KERNEL_POLICY must be protect, pin or none." ;; esac
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
	warn "SELINUX_MODE=disabled. On modern Fedora, disabling SELinux through"
	warn "/etc/selinux/config is deprecated and leaves the system half-configured."
	warn "Prefer permissive."
fi

#--- [FEDORA] Secure Boot -----------------------------------------------------
SB_STATE="$(secureboot_state)"
if [[ "$SB_STATE" == "enabled" ]]; then
	echo >&2
	warn "SECURE BOOT IS ENABLED. Two parts of this install are unsigned:"
	warn ""
	warn "  1. zfs.ko, built locally by DKMS. The kernel will refuse to load it:"
	warn "       modprobe: ERROR: could not insert 'zfs': Key was rejected by service"
	warn "     Even in the LIVE environment, a few steps from now."
	warn "  2. rEFInd. Fedora ships its binaries in 'rEFInd-unsigned-x64'. Your"
	warn "     firmware will not start it."
	warn ""
	warn "Your options, in increasing order of effort:"
	warn "  * Turn Secure Boot off in firmware setup. Simplest, and what most"
	warn "    people running root-on-ZFS end up doing."
	warn "  * Generate a Machine Owner Key, enrol it with mokutil, and sign both"
	warn "    the zfs modules and the rEFInd binary after every rebuild. Real,"
	warn "    documented, and a standing maintenance task."
	warn ""
	warn "This script does NOT sign anything for you."
	if [[ "$FORCE" != "yes" ]]; then
		echo
		read -rp "Continue with Secure Boot enabled? Type YES to proceed: " _sb
		[[ "$_sb" == "YES" ]] || die "Aborted. Disable Secure Boot, or re-run with FORCE=yes."
	fi
elif [[ "$SB_STATE" == "unknown" ]]; then
	warn "Could not determine Secure Boot state. If it turns out to be on, the DKMS"
	warn "module and rEFInd will both be rejected as unsigned."
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
# No locale-gen on Fedora: locales come from glibc-langpack-<lang>.
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
  Distribution     : Fedora ${RELEASEVER}   (live env: ${LIVE_ID:-?} ${LIVE_VERSION_ID:-?})
  Base group       : ${BASE_GROUP}
  Secure Boot      : ${SB_STATE}$( [[ "$SB_STATE" == enabled ]] && echo "  <-- unsigned zfs.ko and rEFInd will be rejected" )
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
  ZFS packaging    : DKMS (Fedora has no kmod option), repo=${ZFS_BRANCH}
  Kernel policy    : ${KERNEL_POLICY}

  ZFSBootMenu      : ${ZBM_VERSION}
    kernels        : ${SELECTED_KERNELS[*]}
    release images : yes  (EFI/ZBM-<ver>/vmlinuz.EFI)
    recovery images: ${ZBM_RECOVERY}  (EFI/ZBM-RECOVERY-<ver>/vmlinuz.EFI)
    backup copies  : ${ZBM_BACKUP}  (EFI/ZBM-BACKUP/vmlinuz-<ver>.EFI)
    BOOTX64 fallback: ${ZBM_FALLBACK_KERNEL:-disabled}
  Boot manager     : ${BOOTLOADER}$( [[ "$BOOTLOADER" == refind ]] && echo " (Fedora package: ${REFIND_PACKAGES})" )
  rEFInd           : timeout ${REFIND_TIMEOUT} $( [[ "$REFIND_TIMEOUT" == 0 ]] && echo "(waits for you; nothing auto-boots)" ), default_selection $( [[ -n "$REFIND_DEFAULT" ]] && echo "'${REFIND_DEFAULT}'" || echo "not set" )
  ZBM cmdline      : ${ZBM_CMDLINE}   (countdown ${ZBM_TIMEOUT}s)
  Fedora cmdline   : ${KERNEL_CMDLINE}

  Hostname         : ${TARGET_HOSTNAME}
  Admin user       : ${ADMIN_USER}  (groups: ${ADMIN_GROUPS})
  Desktop          : ${DESKTOP} (${DESKTOP_SIZE})  extras=${DESKTOP_EXTRAS}
  Locale / TZ      : ${LOCALE} / ${TIMEZONE}
  Keyboard         : xkb=${KEYMAP} variant=$( [[ -n "$KEYBOARD_VARIANT" ]] && echo "$KEYBOARD_VARIANT" || echo "(none)" )  console=${VCONSOLE_KEYMAP}
  SELinux          : ${SELINUX_MODE}, relabel=${SELINUX_RELABEL}
  RPM Fusion       : ${ENABLE_RPMFUSION}
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
# [FEDORA] Configure the live environment
#==============================================================================

#------------------------------------------------------------------------------
# zfs-fuse
#------------------------------------------------------------------------------
# Fedora's own repositories carry zfs-fuse, an unrelated and unmaintained FUSE
# implementation that happens to own the name. OpenZFS's Fedora page opens by
# telling you to remove it before doing anything else. If it is present, the
# real zfs package will not install cleanly.
purge_zfs_fuse() {
	local root="${1:-}"
	local -a rpmargs=()
	[[ -n "$root" ]] && rpmargs=(--root "$root")
	if rpm "${rpmargs[@]}" -q zfs-fuse >/dev/null 2>&1; then
		warn "zfs-fuse is installed${root:+ in ${root}}; removing it (it conflicts with OpenZFS)."
		rpm "${rpmargs[@]}" -e --nodeps zfs-fuse || warn "Could not remove zfs-fuse."
	fi
	return 0
}

#------------------------------------------------------------------------------
# The OpenZFS repository
#------------------------------------------------------------------------------
# [FEDORA] /fedora, not /epel. And import the signing key BEFORE installing
# zfs-release: Fedora 45 enforces RPM signature checking by default, and
# zfs-release is itself signed with the key that zfs-release installs. Pulling
# the key in first breaks that circle without reaching for --nogpgcheck.
install_zfs_release() {
	local dist url
	dist="$(rpm --eval '%{dist}')"

	if [[ -n "$ZFS_GPG_KEY_URL" ]]; then
		echo "  importing the OpenZFS signing key"
		echo "    expected fingerprint: ${ZFS_GPG_FINGERPRINT}"
		rpm --import "$ZFS_GPG_KEY_URL" \
			|| warn "Could not import the OpenZFS key; the zfs-release install may be refused."
	fi

	if rpm -q zfs-release >/dev/null 2>&1; then
		echo "  zfs-release is already installed"
		return 0
	fi
	url="${ZFS_RELEASE_BASE}/${ZFS_RELEASE_PKG}${dist}.noarch.rpm"
	echo "  installing ${url}"
	dnf install -y "$url"
}

# [FEDORA] No zfs-latest / zfs-legacy split here. The default 'zfs' repo on
# Fedora already tracks the newest released OpenZFS branch -- it is the thing
# the EL script has to switch to on purpose. zfs-testing is OpenZFS under
# active development, and exists for the case where the released branch does
# not build against a kernel Fedora has already shipped.
select_zfs_repo() {
	if [[ "$ZFS_BRANCH" == "testing" ]]; then
		warn "ZFS_BRANCH=testing: using pre-release OpenZFS. This is the right call only"
		warn "if the stable branch will not build against this kernel."
		dnf_enable_repo zfs-testing || die "Could not enable the zfs-testing repository."
	fi
	return 0
}

log "Preparing the live environment"
[[ "$EXCLUDE_ZFS_FUSE" == "yes" ]] && purge_zfs_fuse

log "Adding the OpenZFS repository"
install_zfs_release || die "Could not install ${ZFS_RELEASE_PKG}. Check the network and ZFS_RELEASE_BASE."
select_zfs_repo

log "Installing ZFS in the live environment (DKMS build, be patient)"
# [GUIDE] "kernel-devel package must be installed before zfs package."
# This is not advisory. DKMS needs the headers present at install time, and the
# zfs package's scriptlet is what triggers the build.
if ! dnf install -y "kernel-devel-$(uname -r)"; then
	warn "No kernel-devel matching the live kernel $(uname -r)."
	warn "A live ISO's kernel is frozen at compose time and can be older than"
	warn "anything still in the repositories. Trying plain kernel-devel."
	dnf install -y kernel-devel || warn "kernel-devel is unavailable."
fi

dnf install -y zfs gdisk cryptsetup dosfstools curl util-linux \
	|| die "Failed to install zfs in the live environment."

if ! modprobe zfs; then
	echo >&2
	warn "The zfs module did not load. The likely causes, in order:"
	if [[ "$SB_STATE" == "enabled" ]]; then
	warn "  * SECURE BOOT. The DKMS module is unsigned and the kernel rejected it."
	warn "    This is almost certainly it. Disable Secure Boot and re-run."
	fi
	warn "  * The DKMS build failed. Check /var/lib/dkms/zfs/*/build/make.log"
	warn "  * OpenZFS does not support this kernel yet. Fedora ships kernels"
	warn "    faster than OpenZFS adds support; try ZFS_BRANCH=testing, or use"
	warn "    older live media."
	warn "  * The live overlay ran out of space mid-build. Reboot the live image"
	warn "    with rd.live.overlay.size=8192 on its kernel command line."
	die "Cannot continue without a working zfs module."
fi

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

# printf, not echo: echo appends a newline, the newline becomes part of the
# passphrase, and you then have to reproduce it by hand inside ZFSBootMenu.
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
# xattr=sa is not optional here the way it is on Debian: SELinux keeps security
# contexts in extended attributes, and sa-backed xattrs are the difference
# between a usable relabel and a miserable one.
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
zfs create -o mountpoint=/var/lib/libvirt        "${POOL_NAME}/data/var/lib/libvirt"
zfs create -o mountpoint=/var/log                "${POOL_NAME}/data/var/log"
zfs create -o mountpoint=/var/spool              "${POOL_NAME}/data/var/spool"
zfs create -o mountpoint=/var/tmp                "${POOL_NAME}/data/var/tmp"

# [FEDORA] podman's storage is /var/lib/containers, already covered above.
# There is no /var/lib/docker or /var/lib/lxc dataset: neither is a Fedora
# default. Add one if you install docker-ce later.

if [[ "$DATASET_TUNING" == "yes" ]]; then
	log "Applying per-dataset tuning"
	zfs set atime=off                       "${POOL_NAME}/data/var"
	zfs set setuid=off devices=off          "${POOL_NAME}/data/var/tmp"
	zfs set compression=zstd recordsize=64K "${POOL_NAME}/data/var/log"
	zfs set recordsize=64K                  "${POOL_NAME}/data/var/lib/libvirt"
	zfs set recordsize=32K                  "${POOL_NAME}/data/var/lib/containers"
	zfs set com.sun:auto-snapshot=false     "${POOL_NAME}/data/var/lib/containers"
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
# [GUIDE] Install Fedora
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
# [FEDORA] Three things the usual one-liner glosses over:
#
#   * --use-host-config. With --installroot, dnf looks for repo definitions
#     INSIDE the installroot first, and it is empty. This points it at the live
#     image's repos, which is the only place they exist yet. Fedora 45 also
#     moved repo configuration from /etc to /usr, so hand-copying repo files
#     is no longer a reliable substitute.
#   * --exclude=zfs-fuse, so a dependency resolution cannot drag the obsolete
#     FUSE implementation into a system whose root is real ZFS.
#   * @core, not a desktop environment group. The desktop goes in later, as an
#     explicit package list, so you get a session rather than a spin.
dnf_installroot_install() {
	local opt
	for opt in "--use-host-config" ""; do
		# shellcheck disable=SC2086
		if dnf --installroot=/mnt --releasever="$RELEASEVER" $opt -y \
			--exclude=zfs-fuse install "$@" 2>/dev/null; then
			return 0
		fi
	done
	return 1
}

if ! dnf_installroot_install "$BASE_GROUP"; then
	warn "'${BASE_GROUP}' could not be installed; falling back to an explicit package set."
	dnf_installroot_install fedora-release fedora-repos dnf systemd systemd-udev \
		passwd sudo util-linux coreutils rpm \
		|| die "Could not install a base system into /mnt."
fi

[[ -x /mnt/usr/bin/dnf ]] || die "/mnt has no dnf; the base install did not work."

[[ "$EXCLUDE_ZFS_FUSE" == "yes" ]] && purge_zfs_fuse /mnt

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
	printf 'ZFS_RELEASE_PKG=%q\n'       "$ZFS_RELEASE_PKG"
	printf 'ZFS_RELEASE_BASE=%q\n'      "$ZFS_RELEASE_BASE"
	printf 'ZFS_GPG_KEY_URL=%q\n'       "$ZFS_GPG_KEY_URL"
	printf 'ZFS_BRANCH=%q\n'            "$ZFS_BRANCH"
	printf 'KERNEL_POLICY=%q\n'         "$KERNEL_POLICY"
	printf 'EXCLUDE_ZFS_FUSE=%q\n'      "$EXCLUDE_ZFS_FUSE"
	printf 'ENABLE_RPMFUSION=%q\n'      "$ENABLE_RPMFUSION"
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
	printf 'REFIND_PACKAGES=%q\n'       "$REFIND_PACKAGES"
	printf 'REFIND_DEFAULT=%q\n'        "$REFIND_DEFAULT"
	printf 'REFIND_TIMEOUT=%q\n'        "$REFIND_TIMEOUT"
	printf 'EFI_ENTRIES_ALWAYS=%q\n'    "$EFI_ENTRIES_ALWAYS"
	printf 'SB_STATE=%q\n'              "$SB_STATE"
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

dnf_enable_repo() {
	dnf -y config-manager setopt "${1}.enabled=1" 2>/dev/null && return 0
	dnf -y config-manager --set-enabled "$1"      2>/dev/null && return 0
	return 1
}

# Install only the packages that actually exist in the enabled repositories.
# Fedora renames and splits packages every six months -- gnome-terminal to
# ptyxis, eog to loupe, and so on -- and one bad name would otherwise abort the
# whole transaction. Skipping and reporting beats failing.
dnf_install_available() {
	local label="$1"; shift
	local avail=() p
	for p in "$@"; do
		if dnf -q list --available "$p" >/dev/null 2>&1 || dnf -q list --installed "$p" >/dev/null 2>&1; then
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

#--- machine-id ---------------------------------------------------------------
# dnf --installroot does not create one, and kernel-install, systemd and
# journald all want it. Without it the kernel scriptlets emit confusing errors
# and journald has nowhere to put persistent logs.
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

#--- Repositories inside the target -------------------------------------------
log "Configuring repositories"
dnf -y makecache || warn "Initial makecache failed; check /etc/resolv.conf in the chroot."

# Same circle as in the live environment: import the OpenZFS key before the
# package that would have installed it, because Fedora 45 enforces signature
# checking by default.
if [[ -n "$ZFS_GPG_KEY_URL" ]]; then
	rpm --import "$ZFS_GPG_KEY_URL" || warn "Could not import the OpenZFS signing key."
fi

DIST_TAG="$(rpm --eval '%{dist}')"
ZFS_RELEASE_URL="${ZFS_RELEASE_BASE}/${ZFS_RELEASE_PKG}${DIST_TAG}.noarch.rpm"
log "Installing ${ZFS_RELEASE_PKG}"
echo "  ${ZFS_RELEASE_URL}"
dnf install -y "$ZFS_RELEASE_URL" || die "Could not install ${ZFS_RELEASE_PKG} inside the target."

if [[ "$ZFS_BRANCH" == "testing" ]]; then
	dnf_enable_repo zfs-testing || die "Could not enable the zfs-testing repository."
fi

# [FEDORA] Keep zfs-fuse permanently out of the way. An excludepkgs line is
# cheaper than discovering the conflict during an unattended update.
if [[ "$EXCLUDE_ZFS_FUSE" == "yes" ]]; then
	mkdir -p /etc/dnf
	if ! grep -q '^excludepkgs=.*zfs-fuse' /etc/dnf/dnf.conf 2>/dev/null; then
		echo "excludepkgs=zfs-fuse" >> /etc/dnf/dnf.conf
	fi
fi

if [[ "$ENABLE_RPMFUSION" == "yes" ]]; then
	log "Enabling RPM Fusion (third-party)"
	dnf install -y \
		"https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${RELEASEVER}.noarch.rpm" \
		"https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${RELEASEVER}.noarch.rpm" \
		|| warn "RPM Fusion could not be enabled."
fi

dnf -y makecache || true

#--- Locale, timezone, keyboard -----------------------------------------------
# No locale-gen, no /etc/default/keyboard, no console-setup. Locales ship as
# glibc-langpack-* RPMs; the keyboard lives in two files covering two separate
# stacks (text console vs X11/Wayland).
log "Configuring locale, timezone and keyboard"
dnf_install_available "locale" "glibc-langpack-${LOCALE_LANG}" glibc-langpack-en
dnf install -y tzdata xkeyboard-config kbd || warn "Some locale/keyboard packages are missing."

echo "LANG=${LOCALE}" > /etc/locale.conf

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

# Text console. KEYMAP here is a kbd keymap name, NOT an XKB layout.
# [FEDORA] F45 replaces the in-kernel fbcon with userspace kmscon; vconsole.conf
# is still how the keymap is set either way.
{
	echo "KEYMAP=${VCONSOLE_KEYMAP}"
	echo "FONT=eurlatgr"
} > /etc/vconsole.conf
if ! find /usr/lib/kbd/keymaps /lib/kbd/keymaps -name "${VCONSOLE_KEYMAP}.map*" 2>/dev/null | grep -q .; then
	warn "Console keymap '${VCONSOLE_KEYMAP}' was not found under /usr/lib/kbd/keymaps."
	warn "The text console will fall back to us. Pick a name from 'localectl list-keymaps'"
	warn "and set VCONSOLE_KEYMAP if you care about the console layout."
fi

# X11 / Wayland. This is what localectl set-x11-keymap writes; writing it
# directly avoids needing a running dbus inside the chroot.
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
# Written by fedora-zbm-install-testing.sh. Change with:
#   localectl set-x11-keymap <layout> <model> <variant>
Section "InputClass"
	Identifier "system-keyboard"
	MatchIsKeyboard "on"
	Option "XkbLayout" "${KEYMAP}"
	Option "XkbVariant" "${KEYBOARD_VARIANT}"
EndSection
EOF

#--- [GUIDE] Configure dracut to load ZFS support -----------------------------
# The single biggest structural difference from the Debian script. Debian's
# initramfs-tools pulls /etc/zfs in wholesale, so the pool key lands in the
# initramfs for free. Dracut copies nothing it was not told about, so the key
# has to be named explicitly with install_items -- without this line the kernel
# reaches the encrypted root with no key and the boot dies AFTER ZFSBootMenu
# has already done its job, which is a confusing place to fail.
log "Configuring dracut"
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/zol.conf <<EOF
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs resume "
install_items+=" ${KEYFILE} "
EOF
# 'resume' is omitted because swap here is either absent or encrypted with a
# key that does not survive a reboot. Leaving the module in means the initramfs
# hunts for a resume device it will never find and stalls while it does.

#--- [GUIDE] Install kernel and ZFS -------------------------------------------
# [FEDORA] ORDER MATTERS. kernel-devel must be in place before the zfs package,
# because installing zfs is what triggers the DKMS build.
log "Installing kernel and kernel-devel"
dnf install -y kernel kernel-core kernel-modules kernel-devel \
	sudo efibootmgr dosfstools gdisk \
	|| die "Could not install the kernel."

TARGET_KVER="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | sort -V | tail -n1)"
echo "  target kernel: ${TARGET_KVER}"

log "Installing ZFS (DKMS build against ${TARGET_KVER})"
if ! dnf install -y zfs zfs-dracut; then
	die "Could not install zfs. If this is a dependency or build failure, the usual
causes are that OpenZFS does not support Fedora ${RELEASEVER}'s kernel yet (try
ZFS_BRANCH=testing) or that kernel-devel and the kernel are different versions."
fi

# Confirm the module was actually built for the kernel that will boot, not just
# for whatever the live environment is running. A DKMS package installs happily
# and leaves no module behind if the build failed.
if ! find "/lib/modules/${TARGET_KVER}" -name 'zfs.ko*' 2>/dev/null | grep -q .; then
	warn "No zfs.ko under /lib/modules/${TARGET_KVER}."
	warn "Check: dkms status ; /var/lib/dkms/zfs/*/build/make.log"
	die "The installed kernel has no ZFS module. It cannot mount root. Fix before rebooting."
fi
echo "  zfs.ko present for ${TARGET_KVER}"

#--- [GUIDE] Regenerate the initramfs -----------------------------------------
# [GUIDE] "Ignore any messages about findmnt or syslog."
# kernel-core's scriptlets built an initramfs before zfs-dracut existed, so the
# first one has no ZFS in it. Rebuild every image now that it does.
log "Regenerating every initramfs"
dracut --force --regenerate-all || die "dracut failed. The system will not boot; fix this before rebooting."

# Prove the key and the zfs module landed, rather than finding out at a
# passphrase prompt that never appears.
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

#--- [FEDORA] Kernel update policy --------------------------------------------
# The Fedora-on-ZFS failure mode: a kernel update lands, its DKMS build fails,
# and the new default kernel cannot mount root. ZFSBootMenu will still offer
# it, and you will still be able to boot the previous one -- but only if you
# know that is what happened.
case "$KERNEL_POLICY" in
	protect|pin)
		log "Applying kernel policy: ${KERNEL_POLICY}"
		# dnf refuses to remove a protected package, so a transaction that
		# would orphan ZFS fails loudly instead of quietly.
		mkdir -p /etc/dnf/protected.d
		echo 'zfs' > /etc/dnf/protected.d/zfs.conf

		# Keep more old kernels around than Fedora's default of 3. Each one is
		# a boot environment that still has a working module.
		if ! grep -q '^installonly_limit' /etc/dnf/dnf.conf 2>/dev/null; then
			echo 'installonly_limit=5' >> /etc/dnf/dnf.conf
		else
			sed -i 's/^installonly_limit=.*/installonly_limit=5/' /etc/dnf/dnf.conf
		fi
		;;
esac
if [[ "$KERNEL_POLICY" == "pin" ]]; then
	# Kernels now move only when you say so. This also freezes kernel security
	# fixes, which is the trade you are making.
	if ! grep -q '^exclude=.*kernel' /etc/dnf/dnf.conf 2>/dev/null; then
		echo 'exclude=kernel kernel-core kernel-modules kernel-devel kernel-modules-extra' >> /etc/dnf/dnf.conf
	fi
	warn "KERNEL_POLICY=pin: kernel updates are excluded in /etc/dnf/dnf.conf."
	warn "That includes kernel SECURITY updates. Update deliberately with"
	warn "  sudo dnf --disableexcludes=all update 'kernel*'"
fi
CHROOT_EOF

cat >> /mnt/root/zbm-chroot.sh <<'CHROOT_EOF'

#--- Microcode and firmware ---------------------------------------------------
if [[ "$INSTALL_FIRMWARE" == "yes" ]]; then
	# Much simpler than Debian. One microcode package covers both vendors and
	# linux-firmware is a single monolith instead of two dozen firmware-*
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
	# No cryptsetup-initramfs equivalent to agonise over: dracut's crypt module
	# is built in, and KERNEL_CMDLINE carries rd.luks=0 so it stays out of the
	# way at boot. systemd-cryptsetup handles the volume from the real root,
	# after ZFS is up and the keyfile is reachable.
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
# Hostid is left entirely to ZFSBootMenu. zbm.set_hostid is on by default and
# makes ZBM set spl.spl_hostid for the booted environment to the hostid it
# actually imported the pool with. What matters here is /etc/hostid inside the
# dracut image, which the copy from the live environment plus the dracut run
# above already provides.
#
# [DEVIATION] The guide sets commandline="quiet rhgb". This is a testing rig:
# 'quiet' hides exactly the messages you installed three ZBM images to read.
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
# [FEDORA] rEFInd comes from Fedora's own repository
#------------------------------------------------------------------------------
# This is the part that is simply better here than on AlmaLinux or Rocky, where
# rEFInd is in no repository at all and has to be fetched from upstream.
# Fedora packages it as 'rEFInd' (capitals -- it is a Fedora package name),
# currently 0.14.2, built for F43/44/45.
#
# Three packages, because the split has moved between builds:
#   rEFInd              the package proper
#   rEFInd-tools        mkrlconf, mvrefind and friends
#   rEFInd-unsigned-x64 the actual x86_64 EFI binaries
# Installing all three and then running refind-install is the reliable order.
if [[ "$BOOTLOADER" == "refind" ]]; then
	log "Installing rEFInd from the Fedora repository"

	if [[ "$SB_STATE" == "enabled" ]]; then
		warn "Secure Boot is on and Fedora's rEFInd binaries come from a package named"
		warn "rEFInd-unsigned-x64. Your firmware will refuse to start it until you sign"
		warn "it with an enrolled MOK."
	fi

	# shellcheck disable=SC2086
	if dnf install -y $REFIND_PACKAGES; then
		if command -v refind-install >/dev/null 2>&1; then
			# --yes suppresses the shim / Secure Boot prompts. Older builds do
			# not know the flag; fall back to a bare run with stdin closed,
			# which answers every prompt with its default.
			if refind-install --yes < /dev/null || refind-install < /dev/null; then
				REFIND_OK=yes
			else
				warn "refind-install failed."
			fi
		else
			warn "refind-install is not on PATH after installing: ${REFIND_PACKAGES}"
			warn "Check 'rpm -ql rEFInd rEFInd-tools' for where it went."
		fi
	else
		warn "Could not install the rEFInd packages from the Fedora repository."
	fi

	if [[ "$REFIND_OK" == "yes" ]]; then
		# refind-install picks the ESP itself and does not always land where
		# this script expects, so find the config it actually wrote.
		for _c in /boot/efi/EFI/refind/refind.conf /boot/efi/EFI/BOOT/refind.conf /boot/efi/refind.conf; do
			[[ -f "$_c" ]] && { REFIND_CONF="$_c"; break; }
		done
		if [[ ! -f "$REFIND_CONF" ]]; then
			# Binaries copied but no config, or the sample landed under a
			# different name. Recover rather than leave rEFInd running on
			# built-in defaults with no timeout and no folding rules.
			_dir="$(dirname "$REFIND_CONF")"
			mkdir -p "$_dir"
			_sample="$(find /usr/share/refind* /usr/share/rEFInd* "$_dir" \
				-maxdepth 3 -name 'refind.conf-sample' 2>/dev/null | head -n1)"
			if [[ -n "$_sample" ]]; then
				cp "$_sample" "$REFIND_CONF"
				warn "refind.conf was missing; created it from ${_sample}."
			else
				printf '# created by fedora-zbm-install-testing.sh\n' > "$REFIND_CONF"
				warn "refind.conf and refind.conf-sample were both missing; wrote a minimal one."
			fi
		fi
		if ! find /boot/efi/EFI -maxdepth 2 -iname 'refind_x64.efi' | grep -q .; then
			warn "No refind_x64.efi found on the ESP. refind-install reported success but"
			warn "does not appear to have copied anything -- check /boot/efi/EFI, and that"
			warn "rEFInd-unsigned-x64 is actually installed."
		fi
	else
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
	# rEFInd offer to boot the Fedora kernel directly and skip ZFSBootMenu --
	# and that kernel has no idea how to import an encrypted pool on its own.
	rm -f /boot/refind_linux.conf

	{
		echo ""
		echo "#--- added by fedora-zbm-install-testing.sh --------------------------------"
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
		echo "# Nothing is excluded from scanning. The Fedora kernel is NOT reachable"
		echo "# from here anyway: it lives in the encrypted ZFS boot environment, which"
		echo "# rEFInd cannot read. The only way it could have appeared in this menu was"
		echo "# via the /boot/refind_linux.conf that refind-install writes, and the"
		echo "# installer deleted that."
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
# The guide creates two. A testing rig wants one per image, so the firmware
# menu becomes the image chooser when rEFInd is not in play.
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

# [FEDORA] grubby and the BLS machinery come along with @core and will keep
# writing /boot/loader/entries on every kernel update. Nothing reads them here
# -- ZBM finds kernels by scanning the boot environment's /boot directly -- but
# they are harmless, and leaving them means a future switch back to GRUB is one
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

# 'wheel', not 'sudo'. Fedora's stock sudoers enables %wheel, but @core is a
# good place for that assumption to quietly not hold.
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
	cryptsetup gdisk policycoreutils policycoreutils-python-utils \
	|| warn "Some base packages failed to install."

# chrony, not systemd-timesyncd.
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
# [FEDORA] MINIMAL PACKAGE LISTS, NOT SPINS.
#
# No @workstation-product-environment, no @kde-desktop. Those groups are the
# full spin package set -- several hundred packages including games, a mail
# client, a photo manager and a browser you did not ask for. What follows is
# the smallest set that gives a working graphical session: compositor, login
# manager, settings, file manager, terminal. DESKTOP_SIZE=full adds the usual
# applications on top, still by name.
#
# Fedora also renames desktop packages every couple of releases -- gnome-
# terminal to ptyxis, eog to loupe, evince to papers -- so the helpers below
# take alternatives in preference order and install the first one that exists
# rather than hard-coding a name that was right in 2024.

# Install the FIRST package from the list that exists. For renamed packages.
dnf_install_first() {
	local label="$1"; shift
	local p
	for p in "$@"; do
		if dnf -q list --installed "$p" >/dev/null 2>&1; then
			echo "    ${label}: ${p} (already installed)"
			return 0
		fi
		if dnf -q list --available "$p" >/dev/null 2>&1; then
			echo "    ${label}: ${p}"
			dnf install -y "$p" && return 0
			warn "${p} failed to install; trying the next alternative."
		fi
	done
	warn "No ${label} package available from: $*"
	return 0
}

case "$DESKTOP" in
	gnome)
		log "Installing GNOME (${DESKTOP_SIZE})"
		# The session itself. gnome-shell pulls mutter and gsettings schemas;
		# the rest is what makes it usable rather than merely running.
		dnf_install_available "GNOME session" \
			gnome-shell gnome-session gnome-settings-daemon \
			gnome-control-center gdm gnome-keyring \
			xdg-desktop-portal-gnome xdg-user-dirs-gtk
		dnf_install_available "GNOME core applications" \
			nautilus gnome-text-editor gnome-disk-utility gnome-calculator \
			gnome-system-monitor
		# Renamed between releases: Ptyxis is the F41+ default terminal,
		# gnome-console the F39-F40 one, gnome-terminal the classic.
		dnf_install_first "terminal" ptyxis gnome-console gnome-terminal

		if [[ "$DESKTOP_SIZE" == "full" ]]; then
			dnf_install_available "GNOME extras" \
				gnome-software gnome-tweaks gnome-characters gnome-logs \
				gnome-calendar gnome-clocks gnome-weather gnome-maps \
				gnome-color-manager gnome-remote-desktop \
				dconf-editor seahorse simple-scan totem \
				gnome-shell-extension-common
			dnf_install_first "image viewer" loupe eog
			dnf_install_first "document viewer" papers evince
		fi

		if ! rpm -q gdm >/dev/null 2>&1; then
			warn "gdm is not installed; GNOME will not start a login screen."
			systemctl set-default multi-user.target
		else
			systemctl enable gdm || warn "gdm could not be enabled."
			systemctl set-default graphical.target
		fi
		;;
	kde)
		log "Installing KDE Plasma (${DESKTOP_SIZE})"
		# [FEDORA] Unlike EL, KDE here is a first-class Fedora citizen -- it is
		# a release-blocking edition, in the main repositories, no EPEL and no
		# third-party anything. F45 carries Plasma 6.7.
		dnf_install_available "Plasma session" \
			plasma-desktop plasma-workspace plasma-workspace-wayland \
			kwin kwin-wayland sddm sddm-breeze sddm-kcm \
			plasma-nm plasma-pa kscreen breeze-icon-theme \
			xdg-desktop-portal-kde kf6-kio-extras
		dnf_install_available "KDE core applications" \
			dolphin konsole plasma-systemmonitor kwrite

		if [[ "$DESKTOP_SIZE" == "full" ]]; then
			dnf_install_available "KDE extras" \
				kate ark okular gwenview spectacle kcalc \
				plasma-discover kdeplasma-addons kinfocenter \
				kfind kcharselect filelight kdialog print-manager \
				kdeconnectd khelpcenter
		fi

		if ! rpm -q sddm >/dev/null 2>&1 || ! rpm -q plasma-workspace >/dev/null 2>&1; then
			warn "The KDE stack is incomplete (sddm and/or plasma-workspace missing)."
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

	# [FEDORA] Fedora ships no patent-encumbered codecs. What is here covers
	# free formats plus the OpenH264 Cisco build Fedora is allowed to carry.
	# For the rest you want RPM Fusion (ENABLE_RPMFUSION=yes), which this
	# script leaves off by default.
	dnf_install_available "codecs" \
		gstreamer1-plugins-good gstreamer1-plugins-bad-free \
		gstreamer1-plugin-openh264 mozilla-openh264

	dnf_install_available "archives and filesystems" \
		p7zip p7zip-plugins unzip zip xz ntfs-3g exfatprogs dosfstools

	dnf_install_available "hardware services" fwupd power-profiles-daemon

	dnf_install_available "browser" firefox

	dnf_install_available "fonts" \
		google-noto-sans-fonts google-noto-serif-fonts \
		google-noto-color-emoji-fonts liberation-fonts dejavu-sans-fonts

	if [[ "$INSTALL_MEDIA_ACCEL" == "yes" ]]; then
		dnf_install_available "video acceleration" \
			libva libva-utils libvdpau mesa-va-drivers mesa-vdpau-drivers \
			mesa-vulkan-drivers vulkan-loader intel-media-driver
	fi

	if [[ "$INSTALL_FLATPAK" == "yes" ]]; then
		dnf_install_available "flatpak" flatpak
		case "$DESKTOP" in
			gnome) dnf_install_available "software centre" gnome-software ;;
			kde)   dnf_install_available "software centre" plasma-discover ;;
		esac
	fi

	if [[ "$INSTALL_OFFICE" == "yes" ]]; then
		dnf_install_available "office" \
			libreoffice-writer libreoffice-calc libreoffice-impress
	fi
fi

if [[ "$INSTALL_AUTO_UPDATES" == "yes" ]]; then
	# Think about this one on a DKMS system: an unattended kernel update whose
	# module build fails is exactly the failure this script spends a section
	# trying to prevent. KERNEL_POLICY=pin pairs much better with this.
	dnf_install_available "automatic updates" dnf-automatic
	systemctl enable dnf-automatic.timer 2>/dev/null || true
	if [[ "$KERNEL_POLICY" != "pin" ]]; then
		warn "dnf-automatic is enabled but KERNEL_POLICY is not 'pin'. An unattended"
		warn "kernel update with a failing DKMS build will leave an unbootable default"
		warn "kernel. Consider KERNEL_POLICY=pin."
	fi
fi

#==============================================================================
# SELinux
#==============================================================================
# Nothing here has a Debian counterpart, and skipping it is the most likely way
# to reach an emergency shell on first boot.
#
# dnf --installroot writes files with whatever labels the HOST policy produced,
# or with none at all where the host had no matching rule. systemd, sshd, gdm
# and the rest are then denied access to their own files. Relabelling rewrites
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
dnf -y autoremove || true
dnf clean all || true

log "ESP contents"
find /boot/efi/EFI -maxdepth 2 \( -name '*.EFI' -o -name '*.efi' \) | sort
df -h /boot/efi

log "Installed versions"
rpm -q kernel zfs zfs-dracut 2>/dev/null || true
rpm -q rEFInd 2>/dev/null || true
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
$( [[ "$SB_STATE" == enabled ]] && printf '%s\n' \
"SECURE BOOT IS STILL ENABLED" \
"  You chose to continue. Expect the firmware to refuse rEFInd (its binaries" \
"  come from rEFInd-unsigned-x64) and the kernel to refuse zfs.ko. Either turn" \
"  Secure Boot off in firmware setup before rebooting, or enrol a MOK and sign" \
"  both. Nothing in this install is signed for you." \
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
"  POST) lists one entry per ZFSBootMenu image. There are no sub-entries, so set" \
"  ZFSBootMenu's own behaviour through pool properties instead, e.g." \
"      zfs set org.zfsbootmenu:timeout=-1 ${POOL_NAME}" \
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

THE ONE THING THAT WILL BREAK THIS MACHINE: A KERNEL UPDATE
  Fedora ships kernels faster than OpenZFS adds support for them, and ZFS here
  is DKMS -- there is no kmod option, because a kernel whose ABI changes every
  few weeks cannot be tracked that way. A kernel update whose DKMS build fails
  gives you a new default kernel with no zfs.ko, which cannot mount root.

  Current policy: KERNEL_POLICY=${KERNEL_POLICY}
$( [[ "$KERNEL_POLICY" == pin ]] && printf '%s\n' \
"    Kernel updates are EXCLUDED in /etc/dnf/dnf.conf. Nothing moves until you" \
"    say so -- including kernel security fixes. Take them deliberately:" \
"      sudo zfs snapshot ${POOL_NAME}/ROOT/${BE_NAME}@pre-\$(date +%F)" \
"      sudo dnf --disableexcludes=all update 'kernel*'" \
"      dkms status                       # confirm zfs built for the new kernel" \
"      sudo dracut --force --regenerate-all" )
$( [[ "$KERNEL_POLICY" == protect ]] && printf '%s\n' \
"    The zfs packages are protected (dnf refuses to remove them) and five" \
"    kernels are kept instead of three. Kernels still update normally, so make" \
"    this the habit before every 'dnf update' that touches one:" \
"      sudo zfs snapshot ${POOL_NAME}/ROOT/${BE_NAME}@pre-\$(date +%F)" \
"      sudo dnf update" \
"      dkms status                       # zfs should be 'installed' for the new kernel" \
"    If dkms status does not list the new kernel, DO NOT REBOOT into it. Either" \
"    fix the build or boot the previous kernel from ZFSBootMenu." )
$( [[ "$KERNEL_POLICY" == none ]] && printf '%s\n' \
"    No protection at all. You asked for this. At minimum, snapshot before" \
"    every update:  sudo zfs snapshot ${POOL_NAME}/ROOT/${BE_NAME}@pre-\$(date +%F)" )

  The recovery path is the same in every case: ZFSBootMenu can boot a snapshot
  directly, so a bad update is one menu entry away from undone. That is the
  whole reason this layout is worth the trouble on a fast-moving distribution.

UPGRADING FEDORA RELEASES
  'dnf system-upgrade' on a ZFS root is a real event, not a background task.
  The order that works:
    1. Check that OpenZFS supports the new release's kernel AT ALL. The repo
       for Fedora N must exist at ${ZFS_RELEASE_BASE} before you start.
    2. sudo zfs snapshot -r ${POOL_NAME}/ROOT/${BE_NAME}@pre-FN
    3. Do the upgrade.
    4. Before rebooting: dkms status, and confirm zfs.ko exists under
       /lib/modules/<new kernel>.
    5. Keep a ZBM recovery image handy. If the new kernel has no module, boot
       the snapshot from the ZFSBootMenu menu and wait for OpenZFS to catch up.

ZFS PACKAGING
  Repo: ${ZFS_BRANCH} (from ${ZFS_RELEASE_BASE})
  Fedora's default 'zfs' repo already tracks the NEWEST released OpenZFS
  branch -- there is no zfs-latest/zfs-legacy split the way there is on EL, and
  no kmod packages at all. Check what you have:
    zfs version
    dnf repolist enabled | grep zfs
  zfs-testing exists for the case where the released branch will not build
  against a kernel Fedora has already shipped:
    sudo dnf config-manager setopt zfs-testing.enabled=1

  zfs-fuse is excluded in /etc/dnf/dnf.conf. Leave it that way -- it is an
  unrelated, unmaintained project that happens to own the name and conflicts
  with real ZFS.

NOT INSTALLED, ON PURPOSE
  * RPM Fusion ($( [[ "$ENABLE_RPMFUSION" == yes ]] && echo "you enabled it" || echo "ENABLE_RPMFUSION=no" )). Fedora ships no patent-encumbered codecs,
    so h264/h265/mp3 playback in the stock gstreamer stack is partial. Enable
    it yourself if you want the rest.
  * cups/avahi printing. Add with:
      sudo dnf install cups cups-filters avahi$( [[ "$DESKTOP" == gnome ]] && echo " system-config-printer" )$( [[ "$DESKTOP" == kde ]] && echo " print-manager" )
      sudo systemctl enable --now cups
  * The ${DESKTOP} SPIN. You got a minimal ${DESKTOP} session, not the Fedora
    ${DESKTOP} edition's package set. Add what you miss by name, or install the
    full group if you change your mind:
      sudo dnf group install $( [[ "$DESKTOP" == gnome ]] && echo '"Fedora Workstation"' || echo '"KDE Plasma Workspaces"' )

RECOVERY IMAGES
  EFI/ZBM-RECOVERY-* include networking, curl, sgdisk and cryptsetup. Keep at
  least one even after you have picked a favourite: it is the difference
  between fixing a broken pool from the boot menu and going to find a USB
  stick. On Fedora this matters more than on EL, for the kernel reason above.

BOOT VERBOSITY
  'quiet' and 'rhgb' are set nowhere, unlike Fedora's default.
    ZFSBootMenu's own kernel : ${ZBM_CMDLINE}
    Fedora's kernel          : ${KERNEL_CMDLINE}

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

POOL FEATURES
  Pool compatibility: ${POOL_COMPATIBILITY:-none -- every feature the installed zfs supports}
  ZFSBootMenu ${ZBM_VERSION} images embed OpenZFS 2.4.0 and Fedora's zfs is on the
  newest branch too, so both sides agree and the pool can use everything.
  What breaks that: replacing these ZBM images with an OLDER release after a
  zpool upgrade. Do any image downgrade BEFORE the upgrade, never after.

SELINUX
  Mode: ${SELINUX_MODE}. If something that worked on Debian is mysteriously
  denied here, that is the first place to look:
    sudo ausearch -m avc -ts recent
  Temporarily, to confirm SELinux is the culprit and not something else:
    sudo setenforce 0        # permissive until reboot

EOF
