#!/usr/bin/env bash
# Build a Devuan (no systemd) SD-card image for the NVIDIA Jetson Nano (P3448)
# that keeps NVIDIA's L4T R32.7.6 kernel, drivers and CUDA 10.2 userspace.
#
# Run as root on an arm64 Debian/Devuan host (e.g. GitHub's ubuntu-24.04-arm
# runner inside a privileged debian:trixie container). See README.md.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

: "${SUITE:=excalibur}"
: "${MIRROR:=http://deb.devuan.org/merged}"
: "${L4T_RELEASE:=r32.7}"
: "${L4T_VERSION:=32.7.6-20241104234540}"
: "${L4T_KERNEL:=4.9.337-tegra}"
: "${CUDA:=runtime}"                 # none | runtime | toolkit
: "${EXTRA_PACKAGES:=}"              # space-separated, installed last
: "${IMG_HOSTNAME:=jetson-nano}"
: "${IMG_USER:=jetson}"
: "${IMG_PASSWORD:=jetson}"          # expired on first login; user must change it
: "${IMAGE_VERSION:=dev}"
: "${WORK:=$HERE/work}"
: "${OUT:=$HERE/out}"
: "${COMPRESS:=1}"

IMAGE_NAME="jetson-nano-devuan-${SUITE}-l4t-${L4T_VERSION%%-*}-${IMAGE_VERSION}"
ROOTFS="$WORK/rootfs"
COMPONENTS="main contrib non-free non-free-firmware"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ "$(uname -m)" = aarch64 ] || [ -n "${ALLOW_FOREIGN:-}" ] \
    || die "host is $(uname -m); run on arm64 (or set ALLOW_FOREIGN=1 with qemu-user-static binfmt registered)"
for t in mmdebstrap mke2fs e2fsck sgdisk dpkg-deb curl sha256sum xz; do
    command -v "$t" >/dev/null || die "missing host tool: $t"
done

MOUNTS=()
cleanup() {
    local i
    for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do umount -l "${MOUNTS[$i]}" 2>/dev/null || true; done
}
trap cleanup EXIT

chroot_mount() {
    local m
    for m in proc sys dev dev/pts; do
        mkdir -p "$ROOTFS/$m"
        case $m in
            proc) mount -t proc proc "$ROOTFS/proc" ;;
            sys) mount -t sysfs sysfs "$ROOTFS/sys" ;;
            dev) mount --bind /dev "$ROOTFS/dev" ;;
            dev/pts) mount -t devpts devpts "$ROOTFS/dev/pts" -o gid=5,mode=620,ptmxmode=666 ;;
        esac
        MOUNTS+=("$ROOTFS/$m")
    done
}

chroot_umount() { cleanup; MOUNTS=(); }

in_chroot() { LC_ALL=C DEBIAN_FRONTEND=noninteractive chroot "$ROOTFS" /bin/bash -euo pipefail -c "$*"; }

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"

# --------------------------------------------------------------------------
log "Fetching compatibility packages for NVIDIA's Ubuntu 18.04-era dependencies"
# NVIDIA's packages link against sonames that Debian 13 no longer ships.
# Real libraries from older Debian releases are installed side by side
# (different sonames, no file conflicts). Hashes are pinned.
COMPAT="$WORK/compat"
mkdir -p "$COMPAT"
fetch_pinned() {
    local url=$1 sha=$2 dst
    dst="$COMPAT/$(basename "$url")"
    curl -fsSL --retry 3 -o "$dst" "$url"
    echo "$sha  $dst" | sha256sum -c --quiet || die "checksum mismatch for $url"
}
fetch_pinned http://archive.debian.org/debian/pool/main/libf/libffi/libffi6_3.2.1-9_arm64.deb \
    c5f7f4158dc6821bf37dd44ce0fe4399b5798d4ae7e821ad85b63059a2b31c0f
fetch_pinned http://deb.debian.org/debian/pool/main/p/pcre3/libpcre3_8.39-15_arm64.deb \
    ffff38112e92b032688c0efdc19673686feb2aff8b85f65f54d9f2f6b55992d9

# Pure name-only dependencies get empty transitional packages.
make_dummy() {
    local name=$1 depends=$2 d="$WORK/dummy/$1"
    mkdir -p "$d/DEBIAN"
    cat > "$d/DEBIAN/control" <<EOF
Package: $name
Version: 99:0+jetson1
Architecture: all
Maintainer: jetson-nano-devuan <noreply@example.invalid>
Depends: $depends
Section: oldlibs
Priority: optional
Description: transitional dummy package for NVIDIA L4T compatibility
EOF
    dpkg-deb --root-owner-group -b "$d" "$COMPAT/${name}_dummy_all.deb" >/dev/null
}
make_dummy libegl1-mesa libegl1

# --------------------------------------------------------------------------
log "Bootstrapping Devuan $SUITE into $ROOTFS"
BASE_PACKAGES=(
    devuan-keyring sysvinit-core eudev kmod procps
    bash-completion ca-certificates curl less nano sudo locales tzdata
    openssh-server ifupdown dhcpcd-base iproute2 iputils-ping netbase avahi-daemon dbus
    chrony fake-hwclock cron rsyslog logrotate
    cloud-guest-utils fdisk gdisk e2fsprogs parted
    python3 python3-minimal usbutils pciutils i2c-tools bc psmisc
)
INCLUDE=$(IFS=,; echo "${BASE_PACKAGES[*]}")

mmdebstrap \
    --mode=root \
    --arch=arm64 \
    --variant=minbase \
    --keyring="$HERE/keys/devuan-archive-keyring.gpg" \
    --hook-dir=/usr/share/mmdebstrap/hooks/merged-usr \
    --aptopt='APT::Install-Recommends "false"' \
    --dpkgopt='path-exclude=/usr/share/man/*' \
    --dpkgopt='path-exclude=/usr/share/doc/*' \
    --dpkgopt='path-include=/usr/share/doc/*/copyright' \
    --dpkgopt='path-exclude=/usr/share/locale/*' \
    --dpkgopt='path-include=/usr/share/locale/locale.alias' \
    --include="$INCLUDE" \
    "$SUITE" "$ROOTFS" \
    "deb $MIRROR $SUITE $COMPONENTS" \
    "deb $MIRROR $SUITE-updates $COMPONENTS" \
    "deb $MIRROR $SUITE-security $COMPONENTS"

# Keep the doc/man excludes for packages installed later in the chroot.
cat > "$ROOTFS/etc/dpkg/dpkg.cfg.d/01-jetson-nodoc" <<'EOF'
path-exclude=/usr/share/man/*
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/locale.alias
EOF
echo 'APT::Install-Recommends "false";' > "$ROOTFS/etc/apt/apt.conf.d/90-no-recommends"

# --------------------------------------------------------------------------
log "Installing NVIDIA L4T $L4T_VERSION packages"
chroot_mount
printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
chmod 755 "$ROOTFS/usr/sbin/policy-rc.d"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

install -D -m 644 "$HERE/keys/nvidia-jetson-ota.asc" "$ROOTFS/usr/share/keyrings/nvidia-jetson-ota.asc"
cat > "$ROOTFS/etc/apt/sources.list.d/nvidia-l4t.sources" <<EOF
# NVIDIA L4T / JetPack 4.6.x packages for Jetson Nano (t210). Frozen upstream.
Types: deb
URIs: https://repo.download.nvidia.com/jetson/common https://repo.download.nvidia.com/jetson/t210
Suites: $L4T_RELEASE
Components: main
Signed-By: /usr/share/keyrings/nvidia-jetson-ota.asc
EOF

# Mirrors what NVIDIA's apply_binaries.sh does for an offline rootfs: skip the
# hardware probe and boot-firmware flashing in the package maintainer scripts.
mkdir -p "$ROOTFS/opt/nvidia/l4t-packages"
touch "$ROOTFS/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall"

# Read by nvidia-l4t-* maintainer scripts on later on-device upgrades.
# No TNSPEC on purpose: the bootloader (QSPI) package is not installed.
cat > "$ROOTFS/etc/nv_boot_control.conf" <<'EOF'
TEGRA_CHIPID 0x21
TEGRA_OTA_BOOT_DEVICE /dev/mtdblock0
TEGRA_OTA_GPT_DEVICE /dev/mtdblock0
EOF

# nvidia-l4t-kernel's postinst runs nv-update-extlinux, which expects this file.
install -D -m 644 "$HERE/overlay/boot/extlinux/extlinux.conf" "$ROOTFS/boot/extlinux/extlinux.conf"

mkdir -p "$ROOTFS/tmp/compat"
cp "$COMPAT"/*.deb "$ROOTFS/tmp/compat/"

L4T_PACKAGES=(
    nvidia-l4t-core nvidia-l4t-init nvidia-l4t-configs nvidia-l4t-tools
    nvidia-l4t-kernel nvidia-l4t-kernel-dtbs nvidia-l4t-initrd
    nvidia-l4t-firmware nvidia-l4t-xusb-firmware
    nvidia-l4t-3d-core nvidia-l4t-wayland nvidia-l4t-cuda nvidia-l4t-libvulkan
    nvidia-l4t-multimedia nvidia-l4t-multimedia-utils nvidia-l4t-jetson-io
)
L4T_PINNED=()
for p in "${L4T_PACKAGES[@]}"; do
    case $p in
        nvidia-l4t-kernel*) L4T_PINNED+=("$p=$L4T_KERNEL-$L4T_VERSION") ;;
        *) L4T_PINNED+=("$p=$L4T_VERSION") ;;
    esac
done

case "$CUDA" in
    none) CUDA_PACKAGES=() ;;
    runtime) CUDA_PACKAGES=(cuda-libraries-10-2) ;;
    toolkit) CUDA_PACKAGES=(cuda-toolkit-10-2) ;;
    *) die "CUDA must be none, runtime or toolkit (got '$CUDA')" ;;
esac

in_chroot "apt-get update"
# sysv-rc is Priority: required in Devuan, so OpenRC replaces (and purges) it after bootstrap.
in_chroot "apt-get install -y --purge openrc sysv-rc-"
# nvidia-l4t-core must be configured before the rest (same as nv-apply-debs.sh).
in_chroot "apt-get install -y /tmp/compat/*.deb nvidia-l4t-core=$L4T_VERSION"
in_chroot "apt-get install -y ${L4T_PINNED[*]} ${CUDA_PACKAGES[*]:-}"
if [ -n "$EXTRA_PACKAGES" ]; then
    in_chroot "apt-get install -y $EXTRA_PACKAGES"
fi
rm -rf "$ROOTFS/tmp/compat"

problems=$(in_chroot "dpkg --audit")
[ -z "$problems" ] || die "dpkg reports unconfigured/broken packages:
$problems"

# nvidia-l4t-init's postinst rewrites these during pre-installation.
rm -f "$ROOTFS/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall"

# --------------------------------------------------------------------------
log "Configuring system"
tar -C "$HERE/overlay" --owner=0 --group=0 -cf - . | tar -C "$ROOTFS" --no-overwrite-dir -xf -
chmod 755 "$ROOTFS"/etc/init.d/nv-* "$ROOTFS"/etc/init.d/jetson-* "$ROOTFS"/usr/local/bin/*

# Same as the first-boot block of nvfb-early.sh, done now so CUDA/EGL work immediately.
# Clearing /etc/nv/nvfirstboot also skips nvfb.sh's unbounded
# "dpkg-reconfigure openssh-server" retry loop; host keys come from jetson-firstboot.
in_chroot "
    echo /usr/lib/aarch64-linux-gnu/tegra > /etc/ld.so.conf.d/nvidia-tegra.conf
    echo /usr/lib/aarch64-linux-gnu/tegra-egl > /usr/lib/aarch64-linux-gnu/tegra-egl/ld.so.conf
    echo /usr/lib/aarch64-linux-gnu/tegra > /usr/lib/aarch64-linux-gnu/tegra/ld.so.conf
    update-alternatives --install /etc/ld.so.conf.d/aarch64-linux-gnu_EGL.conf aarch64-linux-gnu_egl_conf /usr/lib/aarch64-linux-gnu/tegra-egl/ld.so.conf 1000
    update-alternatives --install /etc/ld.so.conf.d/aarch64-linux-gnu_GL.conf aarch64-linux-gnu_gl_conf /usr/lib/aarch64-linux-gnu/tegra/ld.so.conf 1000
    ldconfig
    groupadd -rf debug
    rm -f /etc/nv/nvfirstboot
"

echo "$IMG_HOSTNAME" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$IMG_HOSTNAME
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

cat > "$ROOTFS/etc/fstab" <<'EOF'
# <file system>  <mount point>  <type>  <options>          <dump>  <pass>
# Root is mounted read-write by NVIDIA's initrd, so boot-time fsck is skipped.
/dev/mmcblk0p1   /              ext4    defaults,noatime   0       0
EOF

# Serial console on the J50 debug UART, matching the kernel's console=ttyS0.
sed -i '/^#\?T0:/d' "$ROOTFS/etc/inittab"
echo 'T0:2345:respawn:/sbin/getty -L 115200 ttyS0 vt102' >> "$ROOTFS/etc/inittab"

sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' "$ROOTFS/etc/locale.gen"
in_chroot "locale-gen && update-locale LANG=en_US.UTF-8"
ln -sf /usr/share/zoneinfo/Etc/UTC "$ROOTFS/etc/localtime"
echo Etc/UTC > "$ROOTFS/etc/timezone"

in_chroot "
    for g in gpio i2c video render audio dialout plugdev sudo; do getent group \$g >/dev/null || groupadd -r \$g; done
    useradd -m -s /bin/bash -G sudo,video,render,audio,dialout,plugdev,gpio,i2c '$IMG_USER'
    echo '$IMG_USER:$IMG_PASSWORD' | chpasswd
    passwd -e '$IMG_USER' >/dev/null
    passwd -l root >/dev/null
"

# Services. Package postinsts already register most LSB scripts with OpenRC
# (via update-rc.d); only add the ones that are not in any runlevel yet.
in_chroot "
    for s in nv-l4t-early nv-l4t nv-zram jetson-firstboot; do rc-update add \$s default >/dev/null; done
    for s in ssh chrony cron rsyslog networking fake-hwclock dbus avahi-daemon; do
        if [ ! -e /etc/init.d/\$s ]; then echo \"warning: no /etc/init.d/\$s\"; continue; fi
        rc-update show -v | grep -qE \"^ *\$s \\| *[a-z]\" || rc-update add \$s default >/dev/null
    done
    rc-update show -v | grep -E 'boot|default|sysinit' || true
"

# --------------------------------------------------------------------------
log "Cleaning up rootfs"
rm -f "$ROOTFS/usr/sbin/policy-rc.d"
rm -f "$ROOTFS"/etc/ssh/ssh_host_*
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/dbus/machine-id"
in_chroot "apt-get clean"
rm -rf "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/var/cache/apt/*.bin "$ROOTFS"/tmp/* "$ROOTFS"/var/tmp/*
find "$ROOTFS/var/log" -type f -exec truncate -s 0 {} +
date -u '+%Y-%m-%d %H:%M:%S' > "$ROOTFS/etc/fake-hwclock.data"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$ROOTFS/etc/resolv.conf"

in_chroot "dpkg-query -W -f='\${Package}\t\${Version}\n'" > "$OUT/$IMAGE_NAME.packages.tsv"
chroot_umount

# --------------------------------------------------------------------------
log "Creating disk image"
# Single GPT partition (APP) like NVIDIA's SD images for QSPI-boot Nano modules:
# U-Boot in QSPI reads /boot/extlinux/extlinux.conf from mmcblk0p1.
USED_MB=$(du -sxm "$ROOTFS" | cut -f1)
PART_MB=$(( (USED_MB * 115 / 100 + 512 + 63) / 64 * 64 ))
IMG="$OUT/$IMAGE_NAME.img"
rm -f "$IMG"
truncate -s $(( (PART_MB + 2) * 1024 * 1024 )) "$IMG"
sgdisk --zap-all "$IMG" >/dev/null
sgdisk -n 1:2048:+${PART_MB}M -c 1:APP -t 1:8300 -A 1:set:2 "$IMG" >/dev/null
sgdisk -p "$IMG"

# Feature set must be readable by kernel 4.9 and NVIDIA's U-Boot 2020.04:
# no orphan_file (5.15+) and no metadata_csum_seed.
mke2fs -q -F -t ext4 -L APP \
    -O ^orphan_file,^metadata_csum_seed \
    -E offset=$((2048 * 512)),root_owner=0:0 \
    -d "$ROOTFS" "$IMG" "${PART_MB}M"

bash "$HERE/scripts/verify-image.sh" "$IMG"

if [ "$COMPRESS" = 1 ]; then
    log "Compressing"
    xz -T0 -6 -f "$IMG"
    IMG="$IMG.xz"
fi
( cd "$OUT" && sha256sum "$(basename "$IMG")" > "$(basename "$IMG").sha256" )
log "Done: $IMG ($(du -h "$IMG" | cut -f1)), rootfs ${USED_MB} MiB, partition ${PART_MB} MiB"
