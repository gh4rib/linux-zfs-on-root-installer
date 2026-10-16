# linux-zfs-on-root-installer

Installers for **root on encrypted ZFS**, for Debian, AlmaLinux/Rocky, and Fedora.

| Script | Distro | Bootloader | `/boot` | Based on |
|---|---|---|---|---|
| `debian13-zbm-install-testing.sh` | Debian 13 | rEFInd → **ZFSBootMenu** | ZFS root dataset | [ZFSBootMenu — Debian (UEFI)](https://docs.zfsbootmenu.org/en/v3.1.x/guides/debian/uefi.html) |
| `debian13-root-on-zfs-grub.sh` | Debian 13 | **GRUB** | separate **ext4** partition | [OpenZFS — Debian Trixie Root on ZFS](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html) |
| `el10-zbm-install-testing.sh` | **AlmaLinux 10 / Rocky 10** | rEFInd → **ZFSBootMenu** | ZFS root dataset | [ZFSBootMenu — AlmaLinux (UEFI)](https://docs.zfsbootmenu.org/en/v3.1.x/guides/almalinux/uefi.html) |
| `fedora-zbm-install-testing.sh` | **Fedora 43 / 44 / 45** | rEFInd → **ZFSBootMenu** | ZFS root dataset | the AlmaLinux guide above + [OpenZFS — Fedora](https://openzfs.github.io/openzfs-docs/Getting%20Started/Fedora/index.html) |

One script covers both AlmaLinux and Rocky. They are the same system for everything these scripts touch — see [AlmaLinux vs Rocky](#almalinux-vs-rocky).

Every script:

- uses **ZFS native encryption** (`aes-256-gcm`, passphrase) — always on, not optional
- wants the disk as a stable `/dev/disk/by-id/…` path
- builds the **same dataset layout**: separate datasets for `/home`, `/root`, `/opt`, `/srv`, `/var/log`, `/var/spool`, `/var/tmp` and the container/VM stores
- creates a `default` (or distro-named) and a `baseline` boot environment
- adds a **1 GiB encrypted swap partition** with a fresh random key every boot
- installs KDE, GNOME, or nothing, picked with an environment variable
- installs CPU microcode and firmware
- leaves boot messages **visible** — `quiet` is never set

Every step in the source is tagged `[GUIDE]` (straight from the upstream doc) or `[DEVIATION]` (with the reason next to it). The EL and Fedora scripts add `[EL]` and `[FEDORA]` for things that exist only because of that distro.

---

## Table of contents

- [Which script should I use?](#which-script-should-i-use)
- [Introduction](#introduction)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Disk layouts](#disk-layouts)
- [Dataset hierarchy](#dataset-hierarchy)
- [Environment variables](#environment-variables)
- [What happens at boot](#what-happens-at-boot)
- [After installation](#after-installation)
- [Upgrading OpenZFS and the pool](#upgrading-openzfs-and-the-pool)
- [Recovery](#recovery)
- [Deviations from the upstream guides](#deviations-from-the-upstream-guides)
- [Safety notes](#safety-notes)
- [Credits](#credits)
- [License](#license)

---

## Which script should I use?

Pick your distro first, then the bootloader if you have a choice.

| You want | Use | Watch out for |
|---|---|---|
| Debian, interactive boot environments | `debian13-zbm-install-testing.sh` | `zpool upgrade` can break booting |
| Debian, the boring safe option | `debian13-root-on-zfs-grub.sh` | boot environments are not interactive |
| AlmaLinux or Rocky 10 | `el10-zbm-install-testing.sh` | rEFInd isn't packaged, comes from GitHub |
| Fedora 43/44/45 | `fedora-zbm-install-testing.sh` | kernel updates can leave you unbootable |

Rough difficulty order, easiest first: **Debian GRUB → Debian ZBM → Fedora → AlmaLinux/Rocky.**

Fedora is easier than EL in one way (rEFInd is in the repos) and harder in another (kernels move fast and can outrun ZFS). Pick Fedora if you want current software and will keep an eye on kernel updates. Pick AlmaLinux or Rocky if you want a machine you can ignore for a year.

### AlmaLinux vs Rocky

There is no separate script. For everything these installers do, the two are the same system: same repos, same repo IDs (`crb`), same dnf5, same dracut, same SELinux, same package names, same `wheel` group, and neither one ships rEFInd.

Three things actually differ:

- `$ID` in `/etc/os-release` — `almalinux` vs `rocky`
- the release package — `almalinux-release` vs `rocky-release`
- the live ISO you boot

The script reads `$ID` from the live environment and uses it for the boot environment name. Boot Alma media and you get `zroot/ROOT/almalinux`; boot Rocky media and you get `zroot/ROOT/rocky`. That is the only difference in the result. Override with `DISTRO_ID=` if you're installing one from the other's live image.

One hardware note: AlmaLinux also publishes an `x86_64_v2` build for CPUs older than RHEL 10's `x86_64-v3` baseline. Rocky 10 has no equivalent. On an older machine, take the Alma v2 media.

---

# Introduction

### `debian13-zbm-install-testing.sh` — ZFSBootMenu

ZFSBootMenu is a small Linux + initramfs packed into a single EFI executable. It imports your pool, asks for the passphrase, lists every boot environment and snapshot it finds, and `kexec`s into the one you pick.

**Choose it if** you want boot environments as a real, interactive feature. Rolling back a bad upgrade is a menu choice at boot, not a rescue USB. You also get a snapshot browser, a diff viewer, a recovery shell, and pool health info before the OS starts.

**The cost:** ZFSBootMenu carries its own copy of the ZFS userland and module. If you `zpool upgrade` to feature flags your ZBM image doesn't know about, it can't import the pool and the machine won't boot. That's manageable — see [Upgrading OpenZFS and the pool](#upgrading-openzfs-and-the-pool) — but it's a constraint you have to remember forever.

### `debian13-root-on-zfs-grub.sh` — GRUB

GRUB reads the kernel and initramfs from a plain ext4 `/boot`. It never touches ZFS; the kernel's initramfs imports the pool and asks for the passphrase.

**Choose it if** you want the boring, maximally robust option. Because GRUB never reads the root pool, `zpool upgrade rpool` is **always safe**, forever. Any Debian live ISO can rescue it with no special tooling. It's the closest thing to a normal Debian install that still has root on ZFS.

**The cost:** boot environments aren't interactive. The script makes a GRUB entry for `baseline`, but switching to any other snapshot means editing the kernel command line at the GRUB prompt or booting a live ISO.

### `el10-zbm-install-testing.sh` — AlmaLinux 10 / Rocky 10

Same ZFSBootMenu idea as the Debian script, rebuilt for Enterprise Linux. The ZFS and ZFSBootMenu half follows the AlmaLinux UEFI guide; the distro half is all dnf, dracut and SELinux.

**Choose it if** you want a root-on-ZFS machine that stays still. EL kernels barely move inside a major release, so the DKMS module rebuilds rarely and ZFS support is never in question.

**What's different from Debian:**

- `dracut` instead of initramfs-tools. This matters more than it sounds. Debian's initramfs-tools copies all of `/etc/zfs` in for free, so the pool key ends up in the initramfs without asking. Dracut copies nothing you didn't name, so the key has to be listed explicitly. Miss it and the boot dies *after* ZFSBootMenu already worked, which is a confusing place to fail. The script handles it and then checks the result with `lsinitrd`.
- **SELinux.** A filesystem built by `dnf --installroot` has labels from the host, or none at all. Boot that and systemd drops you into an emergency shell. The script relabels inside the chroot and also leaves `/.autorelabel` as a second chance.
- **rEFInd is not packaged anywhere on EL.** Not in BaseOS, AppStream or CRB, and not in EPEL either — the Fedora `rEFInd` package has Fedora branches only, with no EPEL branch to rebuild from. So it comes from a GitHub release instead. See [rEFInd on AlmaLinux and Rocky](#refind-on-almalinux-and-rocky).
- **You have to ask for current ZFS.** `zfs-release` leaves the conservative `zfs` repo enabled, which on EL is the old 2.2.x maintenance branch. The script switches to `zfs-latest` by default.

**The cost:** the rEFInd situation, and EL's older desktop packages. KDE in particular comes from EPEL and can be incomplete for weeks after a point release.

### `fedora-zbm-install-testing.sh` — Fedora 43 / 44 / 45

The same setup again, on a distro that moves fast.

**Choose it if** you want current everything: GNOME 51 or Plasma 6.7, recent kernels, newest OpenZFS without opting in.

**The good news:** Fedora actually packages rEFInd. `dnf install rEFInd` and you're done — no downloads, no unsigned RPM, no `--nogpgcheck`. It's version 0.14.2, built for F43, F44 and F45. This is the single easiest part of any of these installs, and it's the thing AlmaLinux and Rocky can't do.

**The bad news, which is one problem wearing three hats: Fedora kernels move faster than OpenZFS does.**

Fedora ships a new kernel most weeks and jumps a whole major version each release (F45 is on Linux 7.2). OpenZFS supports a kernel when it supports it. That gives you:

1. **DKMS only.** There are no kABI-tracking kmod packages for Fedora, because the concept doesn't work on a kernel whose ABI changes constantly. Every kernel update rebuilds the module, and a rebuild can fail.
2. **A failed rebuild means an unbootable default kernel.** You get a shiny new kernel with no `zfs.ko`. ZFSBootMenu will happily offer it and it will not mount root.
3. **Release upgrades are a real event.** Not a background task. Snapshot first, keep a recovery image handy.

The script pushes back on all three: it checks `zfs.ko` actually exists for the installed kernel before finishing, protects the ZFS packages from removal, keeps five old kernels instead of three, and can pin kernel updates entirely with `KERNEL_POLICY=pin`.

**Two more Fedora-only things:**

- **`zfs-fuse`.** Fedora's own repos carry this ancient, unrelated FUSE project that happens to own the name. It conflicts with real ZFS. OpenZFS's docs open by telling you to remove it. The script removes it and adds a permanent exclude.
- **Secure Boot.** Two things here are unsigned: the DKMS module, and rEFInd (Fedora ships its binaries in a package literally called `rEFInd-unsigned-x64`). With Secure Boot on, neither loads. The script detects it, explains it, and makes you type `YES` to continue. It does not sign anything for you.

---

## Requirements

All scripts:

- A **64-bit UEFI** system (the Debian GRUB script can also do legacy BIOS with `BOOT_MODE=bios`)
- A **whole disk to erase** — these are not dual-boot installers
- Working internet in the live environment
- ≥ 4 GiB RAM recommended (ZFS is slow below 2 GiB)
- Patience. ZFS compiles with DKMS in the live environment, which takes several minutes before anything visible happens.

Per distro:

| Script | Live image | Notes |
|---|---|---|
| Debian ZBM | Debian 13 Live | |
| Debian GRUB | Debian 13 Live | The guide suggests a GUI image, e.g. GNOME |
| AlmaLinux / Rocky | [AlmaLinux 10 Live](https://repo.almalinux.org/almalinux/10/live/x86_64/) or [Rocky 10 Live](https://download.rockylinux.org/pub/rocky/10/live/x86_64/) | Either works for either target; `$ID` decides the BE name |
| Fedora | Fedora 43/44/45 Live (Workstation or KDE spin) | **Turn Secure Boot off first**, or the ZFS module won't even load in the live session |

Fedora extra: the live session uses a small zram-backed overlay and the DKMS build needs room. If the build dies with "no space left", reboot the live image and add `rd.live.overlay.size=8192` to its kernel command line.

---

## Quick start

```bash
# In the live environment
sudo -i

# Debian
apt update && apt install -y git

# AlmaLinux / Rocky / Fedora
dnf install -y git

git clone https://github.com/gh4rib/trixie-zfs-installer.git
cd trixie-zfs-installer
chmod +x *.sh
```

**Find your disk.** Run any script with no `DISK` set and it lists the candidates and exits:

```bash
./debian13-zbm-install-testing.sh
# Whole disks under /dev/disk/by-id/:
#   /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1A2B3C4    931.5G Samsung SSD 990 PRO
#   /dev/disk/by-id/ata-CT1000MX500SSD1_2015E2A0B1C2          931.5G CT1000MX500SSD1
```

**Debian — ZFSBootMenu:**

```bash
DISK=/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1A2B3C4 \
TARGET_HOSTNAME=workstation \
ADMIN_USER=alireza \
TIMEZONE=Europe/Berlin \
DESKTOP=kde \
./debian13-zbm-install-testing.sh
```

**Debian — GRUB:**

```bash
DISK=/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1A2B3C4 \
TARGET_HOSTNAME=workstation \
ADMIN_USER=alireza \
TIMEZONE=Europe/Berlin \
DESKTOP=kde \
./debian13-root-on-zfs-grub.sh
```

**AlmaLinux / Rocky 10:**

```bash
DISK=/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1A2B3C4 \
TARGET_HOSTNAME=workstation \
ADMIN_USER=alireza \
TIMEZONE=Europe/Berlin \
DESKTOP=gnome \
ZBM_KERNELS=all \
./el10-zbm-install-testing.sh
```

**Fedora:**

```bash
DISK=/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1A2B3C4 \
TARGET_HOSTNAME=workstation \
ADMIN_USER=alireza \
TIMEZONE=Europe/Berlin \
DESKTOP=gnome \
ZBM_KERNELS=all \
./fedora-zbm-install-testing.sh
```

Every script prints a full configuration summary, then makes you type `ERASE` before touching the disk. Passwords are asked for interactively (root, admin user, ZFS passphrase) unless you pass them as variables.

### First time? Try one image, no desktop

The EL and Fedora scripts install several ZFSBootMenu images by default so you can test them. For a first run in a VM, keep it small:

```bash
DISK=… DESKTOP=none ZBM_KERNELS=6.12 ./fedora-zbm-install-testing.sh
```

### Not sure about the keyboard layout?

All scripts inherit the layout you picked at the ISO boot menu. To see the variants for your layout:

```bash
LIST_KEYBOARD=yes ./el10-zbm-install-testing.sh
```

An empty `KEYBOARD_VARIANT` is normal and right for most people — it means the standard layout for that country code.

On EL and Fedora there are **two** keyboard settings, because the text console and the graphical session use different naming. `KEYMAP` is the X11/Wayland layout, `VCONSOLE_KEYMAP` is the console one. For `us`, `de`, `fr`, `es` and `it` the names are the same and you can ignore this. For anything unusual, set both.

---

## Disk layouts

### Debian ZBM

| Part | Size | Type | Purpose |
|---|---|---|---|
| 1 | 1024 MiB | `ef00` | ESP → `/boot/efi`, holds rEFInd + ZFSBootMenu |
| 2 | 1024 MiB | `8309` | encrypted swap |
| 3 | rest − 10 MiB | `bf00` | `zroot` |

### AlmaLinux / Rocky and Fedora

| Part | Size | Type | Purpose |
|---|---|---|---|
| 1 | **2048 MiB** | `ef00` | ESP → `/boot/efi`, holds rEFInd + **several** ZBM images |
| 2 | 1024 MiB | `8200` or `8309` | encrypted swap |
| 3 | rest − 10 MiB | `bf00` | `zroot` |

The ESP is twice as big as Debian's because these scripts install up to nine ZBM images. Nine images is roughly 650 MB. The script works out how much it needs and refuses to start if `ESP_SIZE_MIB` is too small.

The swap partition type follows the mode: `8200` (Linux swap) for `SWAP_MODE=random`, `8309` (Linux LUKS) for `SWAP_MODE=luks`. Getting this wrong makes `systemd-gpt-auto-generator` create a competing unit that can't succeed, which then drags down the real swap unit.

In all ZBM layouts the kernel and initramfs live on the ZFS root dataset, so they're snapshotted and rolled back with everything else. That's the whole point of the design.

### Debian GRUB

| Part | Size | Type | Purpose |
|---|---|---|---|
| 1 | 1 MiB | `EF02` | BIOS boot (tiny; keeps the legacy path open) |
| 2 | 600 MiB | `EF00` | ESP → `/boot/efi` |
| 3 | 2048 MiB | `8300` | `/boot` — **ext4** |
| 4 | 1024 MiB | `8200` | encrypted swap |
| 5 | rest | `BF00` | `rpool` |

---

## Dataset hierarchy

Nearly identical everywhere. Pool is `zroot` on the ZBM scripts and `rpool` on the GRUB one, matching each guide.

```
POOL/ROOT                       mountpoint=none   canmount=off
├── default                     mountpoint=/      canmount=noauto   ← active
└── baseline                    mountpoint=/      canmount=noauto   ← factory image
POOL/data                       mountpoint=none   canmount=off
├── home                        /home
│   ├── root                    /root
│   └── <username>              /home/<username>
├── opt                         /opt
├── srv                         /srv
├── usr                         (container, canmount=off)            (EL/Fedora only)
│   └── local                   /usr/local                           (EL/Fedora only)
└── var                         (container, canmount=off)
    ├── lib                     (container, canmount=off)
    │   ├── containers          /var/lib/containers      Podman
    │   ├── docker              /var/lib/docker          Docker      (Debian only)
    │   ├── containerd          /var/lib/containerd                  (EL only)
    │   ├── libvirt             /var/lib/libvirt         VMs
    │   └── lxc                 /var/lib/lxc             LXC         (Debian only)
    ├── log                     /var/log
    ├── spool                   /var/spool
    └── tmp                     /var/tmp
```

The boot environment is named `default` on Debian. On EL it's named after the distro (`almalinux` or `rocky`), following the AlmaLinux guide, which uses `$ID`. On Fedora it's `fedora`. Change it with `BE_NAME`.

There's no `/var/lib/docker` or `/var/lib/lxc` dataset on EL and Fedora, since neither is a default there — those systems use Podman, whose storage is `/var/lib/containers` and already has a dataset. Add your own if you install `docker-ce` later.

The `ROOT`/`data` split is what makes boot environments useful: rolling back `ROOT/default` reverts the OS without touching home directories, logs, or VM images.

The container and VM datasets exist but **no daemons are installed**. Install `podman`, `libvirt`, `docker` or `lxc` when you need them and they land on their own datasets automatically.

### Optional tuning

With `DATASET_TUNING=yes` (the default), the scripts apply a light, conservative set of properties: `atime=off` across `data/var`, `setuid=off devices=off` on `/var/tmp`, `compression=zstd recordsize=64K` on `/var/log`, `recordsize=64K` on libvirt, `32K` on the container stores, and `com.sun:auto-snapshot=false` on the container/VM datasets. Set `DATASET_TUNING=no` to inherit pool defaults and tune it yourself.

On EL and Fedora, `xattr=sa` isn't just a performance choice the way it is on Debian. SELinux stores security contexts in extended attributes, and `sa`-backed xattrs are the difference between a relabel that finishes and one that crawls.

---

## Environment variables

### Common to all scripts

| Variable | Default | Notes |
|---|---|---|
| `DISK` | — | **Required.** Must be a `/dev/disk/by-id/…` whole-disk path |
| `TARGET_HOSTNAME` | varies | `debian-zbm`, `debian`, `el10-zbm`, `fedora-zbm` |
| `ADMIN_USER` | `admin` | Gets its own dataset and admin rights |
| `ADMIN_FULLNAME` | `System Administrator` | GECOS field |
| `ADMIN_GROUPS` | see script | `sudo` on Debian, `wheel` on EL/Fedora, always added |
| `TIMEZONE` | `Etc/UTC` | Any zoneinfo name; validated |
| `LOCALE` | `en_US.UTF-8` | Must be UTF-8 |
| `KEYMAP` | inherited from live ISO | Validated against the XKB rules list |
| `KEYBOARD_VARIANT` | inherited from live ISO | Empty = standard layout |
| `DESKTOP` | `kde` (Debian) / `gnome` (EL, Fedora) | `kde`, `gnome`, `none` |
| `DESKTOP_SIZE` | `minimal` | `minimal` or `full` |
| `SWAP_SIZE_MIB` | `1024` | `0` disables swap entirely |
| `SWAP_MODE` | `random` | `random`, `luks`, `none` |
| `SWAP_RANDOM_SOURCE` | `/dev/urandom` | See [note on swap](#a-note-on-random-key-swap) |
| `POOL_NAME` | `zroot` / `rpool` | |
| `BE_NAME` | `default` / distro name | Active boot environment |
| `BASELINE_NAME` | `baseline` | |
| `BASELINE_MODE` | `clone` | `clone`, `send`, `none` |
| `ASHIFT` | `12` | |
| `COMPRESSION` | `lz4` | |
| `ENCRYPTION_ALGO` | `aes-256-gcm` | |
| `DATASET_TUNING` | `yes` | |
| `INSTALL_FIRMWARE` | `yes` | Microcode + firmware |
| `EXTRA_PACKAGES` | — | Space-separated |
| `ROOT_PASSWORD` / `ADMIN_PASSWORD` / `ZFS_PASSPHRASE` | prompted | Passing these on the command line leaks them to `ps` |
| `FORCE` | `no` | `yes` skips **only** the confirmation prompts |
| `LIST_KEYBOARD` | — | List variants and exit |

### Debian-specific

| Variable | Default | Notes |
|---|---|---|
| `SUITE` / `MIRROR` | `trixie` / deb.debian.org | |
| `COMPONENTS` | `main contrib non-free-firmware` | |
| `ENABLE_BACKPORTS` | `yes` | Adds the repo unpinned; installs nothing from it |

### Debian ZBM only

| Variable | Default | Notes |
|---|---|---|
| `ESP_SIZE_MIB` | `1024` | |
| `ZBM_INSTALL` | `prebuilt` | `prebuilt` (download the EFI) or `source` (build with `generate-zbm`) |
| `ZBM_CMDLINE` | `loglevel=6` | ZFSBootMenu's **own** kernel command line |
| `KERNEL_CMDLINE` | `loglevel=6 systemd.show_status=yes` | What ZBM passes to Debian |
| `ZBM_TIMEOUT` | `10` | Countdown before booting `bootfs` |
| `ZBM_FALLBACK` | `yes` | Also install to `EFI/BOOT/BOOTX64.EFI` |
| `POOL_COMPAT` | *(empty)* | Set to `openzfs-2.3-linux` to pin feature flags |

> **`ZBM_CMDLINE` and `KERNEL_CMDLINE` are not the same thing.** The first configures ZFSBootMenu's own kernel — what you see while it imports the pool and asks for the passphrase. The second is stored in `org.zfsbootmenu:commandline` and configures the OS. Mixing them up is the most common mistake with this setup. This applies to all three ZBM scripts.

### Debian GRUB only

| Variable | Default | Notes |
|---|---|---|
| `BOOT_MODE` | `uefi` | `uefi` or `bios` |
| `ESP_SIZE_MIB` | `600` | |
| `BOOT_SIZE_MIB` | `2048` | ext4 `/boot` |
| `GRUB_VERBOSE` | `yes` | Removes `quiet`, sets `GRUB_TERMINAL=console` |
| `GRUB_CMDLINE_DEFAULT` | `loglevel=6` | |
| `GRUB_TIMEOUT_SECS` | `5` | |
| `REMOVE_OS_PROBER` | `yes` | Avoids `update-grub` noise on single-boot systems |
| `DISABLE_LOG_COMPRESSION` | `yes` | `/var/log` is already a compressed dataset |
| `DNODESIZE` | `auto` | |
| `NORMALIZATION` | `formD` | **Cannot be changed after pool creation.** Implies `utf8only=on` |
| `INSTALL_SSH` | `no` | |
| `BLKDISCARD` | `no` | Full-disk TRIM before partitioning |

### Shared by the EL and Fedora scripts

These two scripts install several ZBM images and share a lot of machinery.

| Variable | Default | Notes |
|---|---|---|
| `ESP_SIZE_MIB` | `2048` | Checked against your image selection; refuses if too small |
| `RELEASEVER` | detected | `10` for EL, `43`/`44`/`45` for Fedora |
| `ZBM_VERSION` | `v3.1.0` | Pinned, not "latest" — a testing rig should be reproducible |
| `ZBM_KERNELS` | `all` | `all` = `6.6 6.12 6.18`, or any subset like `"6.12 6.18"` |
| `ZBM_RECOVERY` | `yes` | Also install the recovery build of each image |
| `ZBM_BACKUP` | `yes` | Keep a second copy of each release image |
| `ZBM_FALLBACK_KERNEL` | `6.12` | Which image goes to `EFI/BOOT/BOOTX64.EFI`; empty disables |
| `ZBM_CMDLINE` | `loglevel=6` | ZFSBootMenu's own kernel command line |
| `KERNEL_CMDLINE` | `loglevel=6 systemd.show_status=yes rd.luks=0` | What ZBM passes to the OS |
| `ZBM_TIMEOUT` | `30` | Countdown before booting `bootfs` |
| `BOOTLOADER` | `refind` | `refind` or `efibootmgr` (no rEFInd, one NVRAM entry per image) |
| `REFIND_TIMEOUT` | `30` | `0` waits forever |
| `REFIND_DEFAULT` | *(empty)* | No image is marked "correct" — you decide after testing |
| `EFI_ENTRIES_ALWAYS` | `no` | Also register NVRAM entries even when rEFInd worked |
| `SELINUX_MODE` | `enforcing` | `enforcing`, `permissive`, `disabled` |
| `SELINUX_RELABEL` | `both` | `fixfiles`, `autorelabel`, `both`, `none` |
| `POOL_COMPATIBILITY` | *(empty)* | Note the name — Debian calls it `POOL_COMPAT` |
| `DESKTOP_EXTRAS` | `yes` | Portals, audio, bluetooth, fonts, codecs |
| `INSTALL_MEDIA_ACCEL` | `yes` | VA-API / VDPAU / Vulkan |
| `INSTALL_FLATPAK` | `no` | |
| `INSTALL_OFFICE` | `no` | |
| `INSTALL_AUTO_UPDATES` | `no` | `dnf-automatic` |

> **`rd.luks=0` is deliberate.** Dracut's crypt module reads `/etc/crypttab` and will try to unlock the swap volume from the initramfs — where the keyfile lives on the not-yet-mounted ZFS root, so it doesn't exist. You get a prompt for a passphrase that was never set, and the boot stalls there. Root is ZFS and needs no LUKS that early, so turning the whole mechanism off is the clean fix. systemd unlocks swap later, from the real root, where the key actually is. Only remove this if you add a LUKS volume that genuinely must open in the initramfs.

### AlmaLinux / Rocky only

| Variable | Default | Notes |
|---|---|---|
| `DISTRO_ID` | detected from live ISO | `almalinux` or `rocky`; also the default `BE_NAME` |
| `BASE_GROUP` | `Minimal Install` | The dnf group installed into the empty root |
| `ZFS_BRANCH` | `latest` | `latest`, `legacy`, `default`, or a branch like `2.4` |
| `ZFS_PKG_STYLE` | `dkms` | `dkms` or `kmod` |
| `ZFS_RELEASE_PKG` | `zfs-release-3-0` | Only this one has the branch-specific repos |
| `ZFS_NOGPGCHECK` | `no` | EL10 ZFS packages have been unsigned at times |
| `ENABLE_CRB` / `ENABLE_EPEL` | `yes` | CRB has the `-devel` packages EPEL links against |
| `REFIND_SOURCE` | `zip` | `zip`, `rpm`, `auto` — see below |
| `REFIND_VERSION` | `0.14.2` | |
| `REFIND_ASSET_BASE` | the GitHub release | Where the zip and RPM come from |
| `REFIND_ZIP_SHA256` / `REFIND_RPM_SHA256` | *(empty)* | Optional integrity check |

**`ZFS_BRANCH` matters more than it looks.** `zfs-release` leaves the plain `zfs` repo enabled, and on EL that repo is the **2.2.x maintenance branch** — upstream only touches it for build breakage or data-corruption bugs. `latest` switches to `zfs-latest`, the newest released branch (2.4.x). The script follows upstream's documented procedure: disable every `zfs*` repo, then enable exactly one. Keep it that way. With two enabled, a future `dnf update` will quietly move you between branches, and a pool created on the newer branch may then refuse to import on the older one.

**`ZFS_PKG_STYLE`:** `dkms` rebuilds the module for every kernel, which survives kernel updates at the cost of a build each time. `kmod` is a prebuilt kABI-tracking module — much faster, but it breaks the day a kernel update moves outside the tracked ABI. DKMS is the default and pairs better with `ZFS_BRANCH=latest`.

#### rEFInd on AlmaLinux and Rocky

rEFInd is in **no** EL repository. Not BaseOS, not AppStream, not CRB, not EPEL. The Fedora package has Fedora branches only (Rawhide, 45, 44, 43) and no EPEL branch to rebuild from, so `dnf install rEFInd` just fails.

It comes from a GitHub release instead, in two forms. **The zip is the default and the better choice:**

| | zip (default) | RPM |
|---|---|---|
| When the install runs | when the script calls it, with `/boot/efi` mounted and the exit status checked | inside a dnf `%post` scriptlet |
| If it fails | you see it | dnf still reports success; you find out at reboot |
| Signature | none needed | unsigned, so `--nogpgcheck` |
| rpmdb | nothing to go stale | a package entry nothing will ever update |

The RPM's one advantage is that `rpm -q refind` answers yes, which isn't worth much when nothing updates it. Use `REFIND_SOURCE=rpm` if you want it anyway, or `auto` to try the zip then the RPM.

Both downloads are checked for being the right file format before use, because a 404 or a proxy login page still arrives as "200 OK" with HTML in it. Set `REFIND_ZIP_SHA256` if you want a real integrity check.

**Nothing will update rEFInd for you.** dnf doesn't know it exists. The zip path keeps the unpacked tree at `/usr/local/share/refind-0.14.2/`, so upgrading later is:

```bash
cd /usr/local/share/refind-0.14.2 && sudo ./refind-install --yes
```

If both downloads fail, the script falls back to `BOOTLOADER=efibootmgr` and registers one firmware boot entry per image. That always works, needs no third-party anything, and just gives you your firmware's menu instead of rEFInd's.

### Fedora only

| Variable | Default | Notes |
|---|---|---|
| `BASE_GROUP` | `@core` | Fedora's `@core` is genuinely minimal |
| `ZFS_BRANCH` | `default` | `default` or `testing` |
| `ZFS_RELEASE_BASE` | `https://zfsonlinux.org/fedora` | Note `/fedora`, not `/epel` |
| `ZFS_GPG_KEY_URL` | OpenZFS signing key 2 | Imported before `zfs-release` |
| `KERNEL_POLICY` | `protect` | `protect`, `pin`, `none` — see below |
| `EXCLUDE_ZFS_FUSE` | `yes` | Remove and permanently exclude the conflicting FUSE package |
| `REFIND_PACKAGES` | `rEFInd rEFInd-tools rEFInd-unsigned-x64` | All three; the split has moved between builds |
| `ENABLE_RPMFUSION` | `no` | Third-party; off unless you ask |

**No `ZFS_PKG_STYLE` here.** Fedora has DKMS only — there are no kmod packages, because a kernel that changes ABI every few weeks can't be tracked that way.

**No `zfs-latest` either.** Fedora's default `zfs` repo *is* the newest released branch. That's the thing the EL script has to opt into. `ZFS_BRANCH=testing` gets you pre-release OpenZFS, which is only the right call when the released branch won't build against a kernel Fedora already shipped.

**`KERNEL_POLICY` is the one to think about:**

- `protect` (default) — protects the ZFS packages from removal and keeps five old kernels instead of three. Kernels still update normally. This does **not** silently freeze your kernel, which also means it doesn't silently freeze your kernel security fixes.
- `pin` — the above, plus `exclude=kernel*` in `/etc/dnf/dnf.conf`. Kernels only move when you say so. Safest for a machine you don't watch, at the cost of having to remember. It freezes security fixes too.
- `none` — neither. You're on your own.

If you turn on `INSTALL_AUTO_UPDATES`, the script warns you unless `KERNEL_POLICY=pin`. An unattended kernel update with a failing DKMS build is exactly the failure this whole section exists to prevent.

---

## What happens at boot

### Debian ZBM

```
firmware → rEFInd → ZFSBootMenu → zroot/ROOT/default
```

One ZBM image, and rEFInd offers four ways into it:

| Entry | Behaviour |
|---|---|
| Boot default | 10s countdown, then boots `bootfs` |
| Boot to menu | always show the boot-environment selector |
| Boot immediately | no menu, no countdown |
| Verbose debug | `loglevel=7`, ZBM's full internal tracing |

### AlmaLinux / Rocky and Fedora — several images at once

```
firmware → rEFInd → (a ZFSBootMenu image you pick) → zroot/ROOT/<distro>
```

This is the big structural difference. These scripts install **up to nine** ZBM images side by side, so you can find out which one your hardware likes:

```
/boot/efi/EFI/ZBM-6.6/vmlinuz.EFI            + refind_linux.conf
/boot/efi/EFI/ZBM-6.12/vmlinuz.EFI           + refind_linux.conf
/boot/efi/EFI/ZBM-6.18/vmlinuz.EFI           + refind_linux.conf
/boot/efi/EFI/ZBM-RECOVERY-6.6/vmlinuz.EFI   + refind_linux.conf
/boot/efi/EFI/ZBM-RECOVERY-6.12/vmlinuz.EFI  + refind_linux.conf
/boot/efi/EFI/ZBM-RECOVERY-6.18/vmlinuz.EFI  + refind_linux.conf
/boot/efi/EFI/ZBM-BACKUP/vmlinuz-6.6.EFI
                         vmlinuz-6.12.EFI    + refind_linux.conf
                         vmlinuz-6.18.EFI
```

rEFInd shows **one entry per image**, each with the same four sub-entries as above (press `F2` or `Insert` to open them). The backups deliberately share a directory so they collapse into one menu tag instead of cluttering it.

**All of these contain the same OpenZFS (2.4.0).** The only difference is the Linux kernel inside, which means hardware support: NVMe controllers, RAID HBAs, GPUs, USB controllers. Picking a different one does not change ZFS capability or feature-flag compatibility.

Nothing is marked as the default and the timeout is 30 seconds, so the menu waits for you. Boot each one once and note:

- does it reach the ZFSBootMenu prompt at all?
- is your keyboard usable at the passphrase prompt?
- does it find and import the pool?
- how long does it take?

Then pin your winner:

```bash
sudo nano /boot/efi/EFI/refind/refind.conf
#   default_selection "ZBM-6.12"
#   timeout 5
```

Deleting the ones you rejected is just removing their directory under `/boot/efi/EFI/`. rEFInd rescans the ESP every boot — there's nothing to regenerate.

**Keep at least one recovery image.** They include networking, curl, sgdisk, cryptsetup and an SSH client. That's the difference between fixing a broken pool from the boot menu and going to find a USB stick. On Fedora this matters more, because of the kernel situation.

#### Why the directory-per-image layout

rEFInd auto-detects files called `vmlinuz*` as Linux kernels, and `fold_linux_kernels` (on by default) collapses every kernel **in the same directory** into one menu tag — picking whichever filename sorts highest as the primary. That's why a normal install with `VMLINUZ.EFI` and `VMLINUZ-BACKUP.EFI` in one folder shows only the backup: `-BACKUP` sorts above the empty string.

Folding is per-directory, so one directory per image sidesteps it while keeping the `vmlinuz` name that triggers autodetection in the first place.

The written `refind.conf` sets `scan_all_linux_kernels true`, and that line is load-bearing. Turn it off and rEFInd stops reading the `refind_linux.conf` next to each image, so all four sub-entries vanish and every image boots with no arguments at all.

### Changing boot verbosity later

Works the same on all three ZBM scripts:

```bash
sudo zfs set org.zfsbootmenu:commandline="loglevel=7 systemd.show_status=yes" zroot/ROOT
sudo zfs set org.zfsbootmenu:commandline="quiet loglevel=3" zroot/ROOT   # back to silent
```

On EL and Fedora, keep `rd.luks=0` in there unless you know you want it gone.

The property is inherited by every environment under `ROOT`. `%{parent}` expands to the parent's value, so you can make just one environment verbose:

```bash
sudo zfs set org.zfsbootmenu:commandline="loglevel=7 %{parent}" zroot/ROOT/default
```

ZFSBootMenu's own verbosity and countdown live in the `refind_linux.conf` next to each image — plain text, no regeneration needed.

### Debian GRUB

```
firmware → GRUB (reads ext4 /boot) → kernel + initramfs → unlock rpool
```

The initramfs asks for the passphrase. The GRUB menu has an entry for `rpool/ROOT/default` and one for `rpool/ROOT/baseline`, generated by `/etc/grub.d/11_baseline_be` (which re-runs on every `update-grub`, so it tracks kernel updates).

The OpenZFS guide suggests reverting the verbose settings once you've rebooted twice and are confident:

```bash
sudo nano /etc/default/grub     # add 'quiet', comment out GRUB_TERMINAL
sudo update-grub
```

### First boot on EL and Fedora relabels itself

`/.autorelabel` is left in place, so the very first boot walks the whole filesystem rewriting SELinux labels and **then reboots on its own**. That's expected. It takes a few minutes and only happens once. Don't interrupt it.

If you land in an emergency shell instead, boot a ZBM recovery image, import the pool, chroot in and run `fixfiles -F -f relabel`.

---

## After installation

### Creating a new boot environment

`canmount` is **not inheritable**, and two filesystems trying to mount at `/` will stop the system booting. Set it explicitly every time:

```bash
sudo zfs snapshot POOL/ROOT/default@pre-upgrade
sudo zfs clone -o canmount=noauto -o mountpoint=/ \
    POOL/ROOT/default@pre-upgrade POOL/ROOT/new
```

On the ZBM scripts you can do this from the boot menu instead. On GRUB, copy `/etc/grub.d/11_baseline_be` as a template, or edit the kernel line at the GRUB prompt and change `root=ZFS=…`.

### Adding a user

A per-user dataset makes the home directory exist — and **`useradd` will not copy `/etc/skel` into a directory that already exists.** It prints `Not copying any file from skel directory into it` and carries on, leaving the account with no `.bashrc` or `.profile`. Do it by hand:

```bash
sudo zfs create -o mountpoint=/home/NAME POOL/data/home/NAME
sudo useradd -M -d /home/NAME -s /bin/bash NAME
sudo cp -a /etc/skel/. /home/NAME/
sudo chown -R NAME:NAME /home/NAME && sudo chmod 0750 /home/NAME
sudo passwd NAME

# Debian
sudo usermod -a -G sudo NAME

# EL / Fedora
sudo usermod -a -G wheel NAME
sudo restorecon -R /home/NAME      # the new dataset has no SELinux labels
```

That last line matters. A brand-new dataset has no SELinux labels at all, and without `restorecon` the user can hit confusing permission errors in their own home directory.

### Updating ZFSBootMenu

Debian (single image):

```bash
sudo curl -fSL -o /boot/efi/EFI/ZBM/VMLINUZ.EFI https://get.zfsbootmenu.org/efi
```

Leave `VMLINUZ-BACKUP.EFI` alone as your known-good image.

EL and Fedora (several images) — update one at a time and test before touching the rest:

```bash
sudo curl -fSL -o /boot/efi/EFI/ZBM-6.12/vmlinuz.EFI \
    https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.2.0/zfsbootmenu-release-x86_64-v3.2.0-linux6.12.EFI
```

Leave `EFI/ZBM-BACKUP/` alone. That's the point of it.

### Kernel updates on Fedora

This is the thing most likely to break a Fedora machine. Make this the habit:

```bash
sudo zfs snapshot zroot/ROOT/fedora@pre-$(date +%F)
sudo dnf update
dkms status                      # zfs should be 'installed' for the new kernel
```

**If `dkms status` doesn't list the new kernel, don't reboot into it.** Either fix the build or boot the previous kernel from ZFSBootMenu.

With `KERNEL_POLICY=pin`, take kernel updates deliberately:

```bash
sudo zfs snapshot zroot/ROOT/fedora@pre-$(date +%F)
sudo dnf --disableexcludes=all update 'kernel*'
dkms status
sudo dracut --force --regenerate-all
```

The recovery path is the same either way: ZFSBootMenu can boot a snapshot directly, so a bad update is one menu entry away from undone. That's the whole reason this layout is worth the trouble on a fast-moving distro.

### Upgrading Fedora releases

`dnf system-upgrade` on a ZFS root is a real event, not a background task. The order that works:

1. Check OpenZFS supports the new release's kernel **at all**. The repo for Fedora *N* must exist at `https://zfsonlinux.org/fedora` before you start.
2. `sudo zfs snapshot -r zroot/ROOT/fedora@pre-F<N>`
3. Do the upgrade.
4. **Before rebooting:** `dkms status`, and confirm `zfs.ko` exists under `/lib/modules/<new kernel>`.
5. Keep a ZBM recovery image handy. If the new kernel has no module, boot the snapshot from the menu and wait for OpenZFS to catch up.

### Changing the dracut config (EL and Fedora)

After anything that touches `/etc/dracut.conf.d` or the pool key:

```bash
sudo dracut --force --regenerate-all
sudo lsinitrd /boot/initramfs-$(uname -r).img | grep zroot.key   # verify the key is in there
```

### Cleanup

Every script leaves an `@install` or `@baseline` snapshot. Once you're happy:

```bash
sudo zfs list -t snapshot
sudo zfs destroy POOL/ROOT/default@install
sudo usermod -p '*' root          # disable the root password (optional)
```

If `BASELINE_MODE=clone`, the `@baseline` snapshot **cannot** be destroyed while the clone exists. That's deliberate — it's the guarantee a factory image should have.

---

## Upgrading OpenZFS and the pool

### Debian GRUB

Nothing to think about. GRUB never reads the root pool:

```bash
sudo apt install -t trixie-backports zfs-dkms zfsutils-linux zfs-initramfs
sudo update-initramfs -c -k all
# reboot, verify `zfs version`, then:
sudo zpool upgrade rpool
```

### Any ZBM script — order matters

ZFSBootMenu ships its own ZFS. **`zpool upgrade` is irreversible, and a ZBM image that predates a newly enabled feature flag cannot import the pool.** Follow this order:

1. **Install the newer ZFS in the OS.**

   Debian:
   ```bash
   sudo apt install -t trixie-backports zfs-dkms zfsutils-linux zfs-initramfs
   sudo update-initramfs -c -k all
   ```

   EL / Fedora:
   ```bash
   sudo dnf update 'zfs*'
   sudo dracut --force --regenerate-all
   ```

   Reboot; confirm both userland and kmod report the new version with `zfs version`.

2. **Refresh ZFSBootMenu first.** Check which ZFS version a release embeds at [zbm-dev/zfsbootmenu/releases](https://github.com/zbm-dev/zfsbootmenu/releases), then download it. On EL and Fedora, update every image you actually use.

3. **Reboot through the new image** and confirm it still imports the pool and boots. *Only then:*
   ```bash
   sudo zpool upgrade zroot
   ```

Once the pool is upgraded, old backup images stop being usable fallbacks unless they've been refreshed too.

### Pool feature flags

| Script | `compatibility=` | Why |
|---|---|---|
| Debian ZBM | none by default | `POOL_COMPAT=openzfs-2.3-linux` for the guide's cautious setting |
| Debian GRUB | none | GRUB never reads the pool, so it's always safe |
| AlmaLinux / Rocky | none by default | `ZFS_BRANCH=latest` puts userland on 2.4.x, same as the ZBM images |
| Fedora | none by default | Fedora's default repo is already 2.4.x |

All of them create the pool with **no pin**, so it gets every feature flag the installing ZFS supports. On EL and Fedora that's deliberate: userland and the ZBM images are both on OpenZFS 2.4, so pinning to 2.3 would throw away what you asked for.

What breaks that pairing, most likely first:

1. Replacing the ZBM images with an **older** release after a `zpool upgrade`. Do image downgrades *before* the upgrade, never after.
2. Moving `ZFS_BRANCH` downwards on EL after the pool has enabled newer features. Check what's enabled first: `zpool get all zroot | grep feature | grep -v disabled`
3. A future OpenZFS branch outrunning your images. Check the ZBM release notes for the embedded version before upgrading either side, and upgrade the images first.

Set `POOL_COMPATIBILITY=openzfs-2.3-linux` (EL/Fedora) or `POOL_COMPAT=…` (Debian) at install time if you'd rather be conservative.

---

## Recovery

### Debian

From any Debian live ISO:

```bash
sudo -i
apt update && apt install -y zfsutils-linux
```

### AlmaLinux / Rocky / Fedora

Easiest route is a **ZBM recovery image** from your own boot menu — it already has ZFS, networking and disk tools. Otherwise, from a live ISO:

```bash
sudo -i
# EL
dnf install -y https://zfsonlinux.org/epel/zfs-release-3-0$(rpm --eval "%{dist}").noarch.rpm
# Fedora
dnf install -y https://zfsonlinux.org/fedora/zfs-release-3-0$(rpm --eval "%{dist}").noarch.rpm

dnf install -y epel-release          # EL only
dnf install -y kernel-devel zfs
modprobe zfs
```

### Then, on every distro

```bash
zpool import -f -N -R /mnt POOL
zfs load-key -a                        # or: zfs load-key POOL
zfs mount POOL/ROOT/<be-name>
zfs mount -a
mount /dev/disk/by-id/…-partN /mnt/boot   # Debian GRUB only (ext4 /boot)

mount --make-private --rbind /dev  /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys  /mnt/sys
mount -t tmpfs tmpfs /mnt/run && mkdir /mnt/run/lock
chroot /mnt /bin/bash --login
mount /boot/efi
```

When done:

```bash
exit
mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
zpool export -a
```

Remember the boot environment name isn't `default` on EL and Fedora — it's `almalinux`, `rocky` or `fedora` unless you changed it. `zfs list` will show you.

If a script recorded problems during installation, they're kept at `/root/INSTALL-WARNINGS.txt` on the installed system.

### SELinux problems after recovery

If you chrooted in and changed files, labels may be wrong. From inside the chroot:

```bash
restorecon -R /etc /usr /var      # targeted
fixfiles -F -f relabel            # everything, slower
```

Or just `touch /.autorelabel` and let the next boot sort it out.

---

## Deviations from the upstream guides

Every script is annotated inline. The ones worth knowing up front:

### Debian ZBM script

- **1024 MiB ESP** instead of 512, leaving room for several images and rEFInd.
- **The pool key file is created.** The guide's encrypted `zpool create` references `/etc/zfs/zroot.key` as a file "created in a previous step" — but the Debian page never shows that step. The script creates it before `zpool create`.
- **Encrypted export/import is spelled out.** The guide's encrypted tab leaves it out; the script does `zpool export` → `zpool import -N -R /mnt` → `zfs load-key` → mount, which is what the other guides in the same series actually do.
- **The vdev is referenced by PARTUUID**, so the pool doesn't care about device enumeration order.
- **`EFI/BOOT/BOOTX64.EFI` fallback**, for firmware that silently drops NVRAM boot entries. The guide mentions the problem and links to its Portable ZFSBootMenu page but doesn't automate it.
- **Verbose command lines**, microcode, expanded firmware, and `zfs-zed` — none of which the guide covers.

### Debian GRUB script

- **ext4 `/boot` instead of `bpool`.** The big one. The guide creates a second ZFS pool for `/boot` pinned to `-o compatibility=grub2`, because GRUB understands only a subset of pool features. Using ext4 removes that whole mechanism: no `bpool`, no feature-flag pin, no `zfs-import-bpool.service` (guide step 4.13), no `bpool` entry in `zfs-list.cache`. The payoff is that `zpool upgrade rpool` is permanently safe.
- **Non-interactive native encryption.** The guide's `-O keylocation=prompt` makes `zpool create` prompt interactively. The script creates the pool against a temporary key in `/dev/shm`, then runs `zfs set keylocation=prompt` and shreds the file — ending in exactly the state the guide describes.
- **Ubuntu-isms corrected.** Guide steps 1.6 and 4.7 name `linux-headers-generic` and `linux-image-generic`, Ubuntu metapackages that don't exist in Debian. The script probes the archive and falls back to the `-amd64` variants.
- **Swap on a partition, not a zvol.** The guide's step 7 uses a zvol and warns that under extreme memory pressure this can lock the system up. `RESUME=none` is set either way, per the guide.
- **`tasksel --new-install` replaced** by the `DESKTOP` variable, since tasksel is interactive.

### AlmaLinux / Rocky script

- **Several ZBM images, not one.** Up to nine, each in its own directory. The guide installs one plus a backup in a single folder, which trips over rEFInd's kernel folding.
- **2048 MiB ESP** instead of the guide's 512. 512 fits exactly one image and one backup.
- **`ZFS_BRANCH=latest`.** The guide just installs `zfs`, which gets you the 2.2.x maintenance branch. The script disables every `zfs*` repo and enables exactly one, following OpenZFS's documented procedure.
- **No fallback to an older `zfs-release`.** Only `zfs-release-3-0` has the branch-specific repos, so quietly falling back would hand you the old branch while claiming otherwise.
- **rEFInd from GitHub**, because EL packages it nowhere. With a fallback to `efibootmgr` entries if that fails.
- **Imports by pool GUID, not name**, with the device scan restricted to the partition just created. Importing by name picks whichever pool the scan finds first, which is a coin toss if a second pool shares the name — and the failure mode is installing over the wrong pool.
- **Pool-name collision check** after the wipe, so anything found is genuinely on another disk.
- **`rd.luks=0`** in the OS command line, for the swap-unlock stall described earlier.
- **Explicit desktop package lists**, not dnf groups. See below.
- **No `quiet rhgb`.** The guide sets both. This is a testing rig; `quiet` hides exactly the messages you installed three images to read.

### Fedora script

Everything from the EL list above, plus:

- **rEFInd from Fedora's own repos** — the one place this is easy.
- **`zfs-fuse` removed and excluded.** Fedora's repos carry it and it conflicts with real ZFS.
- **The OpenZFS GPG key is imported before `zfs-release`.** Fedora 45 enforces RPM signature checking by default, and `zfs-release` is signed with the key that `zfs-release` installs. Importing it first breaks that circle without reaching for `--nogpgcheck`.
- **`zfs.ko` is verified to exist** for the installed kernel before the script finishes. A DKMS package installs happily and leaves nothing behind when the build fails.
- **`KERNEL_POLICY`**, which has no equivalent anywhere else because no other distro here moves this fast.
- **Secure Boot is detected and will stop you** with a typed confirmation.
- **Renamed packages are handled.** Fedora renames desktop packages every couple of releases — `gnome-terminal` → `gnome-console` → `ptyxis`, `eog` → `loupe`, `evince` → `papers`. The script takes alternatives in preference order and installs the first that exists, rather than hard-coding a name that was right in 2024.

### Why explicit desktop packages instead of dnf groups

Both the EL and Fedora scripts install desktops as plain package lists. No `@workstation-product-environment`, no `"KDE Plasma Workspaces"`.

Two reasons. Group names move around between Alma, Rocky, Fedora and minor releases, so a group that resolves on one machine fails on another. And a group pulls in several hundred packages you didn't choose — games, a mail client, a photo manager.

`DESKTOP_SIZE=minimal` gives you a session that works: compositor, login manager, settings, file manager, terminal. `full` adds the usual applications, still by name. Every package goes through a check first, so a missing name is skipped and reported instead of failing the whole transaction.

If you decide you want the full spin later:

```bash
# Fedora
sudo dnf group install "Fedora Workstation"      # or "KDE Plasma Workspaces"
```

---

## Safety notes

- **These scripts erase an entire disk.** Not for dual-booting. Back up first.
- `FORCE=yes` skips **only** the confirmation prompts. It doesn't skip password prompts, and all preflight validation still runs.
- Test in a VM before running on hardware you care about. For QEMU/KVM, set a unique serial on each virtual disk so `/dev/disk/by-id` aliases appear.
- **Your passphrase is probably the weakest link.** On the ZBM scripts you type it inside ZFSBootMenu, which uses a basic keymap — prefer unshifted ASCII you can type blind.
- **Secure Boot on Fedora and EL:** the DKMS module and rEFInd are both unsigned. Either turn Secure Boot off, or enrol a Machine Owner Key and sign both after every rebuild. These scripts sign nothing for you.

### A note on random-key swap

The swap partition uses **plain dm-crypt with a fresh key from `/dev/urandom` every boot**, via crypttab's `swap` option. Nothing on it survives a reboot.

This is *not* LUKS, and can't be: LUKS needs a persistent header with keyslots, which is incompatible with a per-boot random key. So **hibernation is impossible**, which is why `RESUME=none` (Debian) and the omitted dracut `resume` module (EL/Fedora) are configured.

If you need hibernation, all the ZBM scripts offer `SWAP_MODE=luks` — a persistent LUKS2 volume unlocked from a keyfile on the encrypted root. The scripts don't configure a resume device; that's left to you.

`/dev/urandom` is the default rather than `/dev/random` because they're cryptographically identical on modern kernels and `/dev/urandom` never blocks. Set `SWAP_RANDOM_SOURCE=/dev/random` if you prefer.

### A note on codecs

Neither EL nor Fedora ships patent-encumbered codecs, so h264/h265/mp3 playback in the stock gstreamer stack is partial. EPEL doesn't carry them either.

On Fedora, `ENABLE_RPMFUSION=yes` adds RPM Fusion. On EL you'd add it yourself. Neither script enables a third-party repository without being told to.

---

## Credits

These scripts are automation wrappers. All the hard thinking belongs to the upstream projects.

### Upstream projects

- **[ZFSBootMenu](https://zfsbootmenu.org/)** — the boot environment manager three of these scripts install.
  Documentation: <https://docs.zfsbootmenu.org/> · Source: <https://github.com/zbm-dev/zfsbootmenu>
  Thanks to Zach Dykstra and the ZFSBootMenu team. The Debian and AlmaLinux UEFI guides are the backbone of this repo.

- **[OpenZFS](https://openzfs.org/)** — ZFS on Linux itself, the *Root on ZFS* series the GRUB script follows, and the RHEL-based and Fedora package documentation the EL and Fedora scripts follow.
  Documentation: <https://openzfs.github.io/openzfs-docs/> · Source: <https://github.com/openzfs/zfs>
  The Debian HOWTO is maintained by rlaager and contributors.

- **[rEFInd](http://www.rodsbooks.com/refind/)** by Rod Smith — the boot manager in front of ZFSBootMenu. Fedora's package is maintained by ngompa, dcavalca and sentry.

### Prior art and inspiration

Other projects solving the same problem, each worth reading before you write your own:

- **[Sithuk/ubuntu-server-zfsbootmenu](https://github.com/Sithuk/ubuntu-server-zfsbootmenu)** — a mature, far more featureful Ubuntu installer: native ZFS or LUKS encryption, single/mirror/raidz topologies, integrated sanoid snapshot management with automatic pruning, an optional encrypted data pool on a second drive, and remote unlocking over SSH at boot so you can roll back a headless machine without physical access. If you're on Ubuntu rather than Debian, use this instead.

- **[okhsunrog/archinstall_zfs](https://github.com/okhsunrog/archinstall_zfs)** — a ZFS-first Arch Linux installer with both a graphical (Slint/KMS) and terminal (ratatui) UI. It validates kernel/ZFS compatibility against OpenZFS release data before installing, and falls back from prebuilt modules to DKMS automatically. That's the same class of problem the Fedora script deals with through `KERNEL_POLICY` — worth reading if you want a better answer than "snapshot and hope".

- **[fnichol/cachyos-zfs-installer](https://github.com/fnichol/cachyos-zfs-installer)** — configures CachyOS with an optionally encrypted ZFS root, ZFSBootMenu, and automatic boot environments by reconfiguring Calamares to use ZFS + ZFSBootMenu instead of ext4 + systemd-boot. Its pacman hooks are the interesting part: a pre-hook snapshots the current boot environment whenever kernel or ZFS packages are about to update, and a post-hook prunes old environments by retention policy and regenerates the ZBM images. That's a genuinely better answer to "snapshot before upgrade" than doing it by hand, and it's the obvious next thing to steal for the Fedora script.

---

## License

MIT. The upstream guides, ZFSBootMenu, rEFInd and OpenZFS carry their own licenses — ZFS is CDDL, rEFInd is GPL-3.0-or-later.

## Contributing

Issues and pull requests welcome. Please test changes in a VM and say which guide section your change relates to, so the `[GUIDE]` / `[DEVIATION]` / `[EL]` / `[FEDORA]` annotations in the scripts stay accurate.
