#!/usr/bin/env bash
# Offline sanity checks for a built (uncompressed) image: partition layout,
# ext4 features usable by kernel 4.9 / U-Boot 2020.04, and boot-critical files.
set -euo pipefail

IMG=${1:?usage: verify-image.sh <image.img>}
OFFSET=$((2048 * 512))
FS="$IMG?offset=$OFFSET"
fail=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }

echo "Verifying $IMG"

sgdisk -v "$IMG" | grep -q 'No problems found' && ok "GPT is consistent" || bad "sgdisk -v reported problems"
info=$(sgdisk -i 1 "$IMG")
grep -q "First sector: 2048 " <<<"$info" && ok "partition 1 starts at sector 2048" || bad "partition 1 does not start at 2048"
grep -q "Partition name: 'APP'" <<<"$info" && ok "partition 1 is named APP" || bad "partition 1 is not named APP"
grep -qi "Attribute flags: 0000000000000004" <<<"$info" && ok "partition 1 has legacy-BIOS-bootable flag" || bad "bootable flag missing"

if e2fsck -fn "$FS" >/dev/null 2>&1; then ok "e2fsck clean"; else bad "e2fsck reported errors"; e2fsck -fn "$FS" || true; fi

features=$(debugfs -R stats "$FS" 2>/dev/null | sed -n 's/^Filesystem features: *//p')
[ -n "$features" ] || bad "could not read ext4 features"
echo "  features: $features"
newfeat=0
for f in orphan_file metadata_csum_seed inline_data encrypt casefold large_dir verity; do
    if grep -qw "$f" <<<"$features"; then bad "ext4 feature '$f' is unsupported by kernel 4.9 / U-Boot"; newfeat=1; fi
done
[ $newfeat -eq 0 ] && ok "no ext4 features newer than kernel 4.9"

exists() { debugfs -R "stat $1" "$FS" 2>/dev/null | grep -q '^Inode:'; }
for p in /boot/Image /boot/initrd /boot/extlinux/extlinux.conf \
         /usr/sbin/init /usr/sbin/openrc /usr/sbin/openrc-run /etc/inittab \
         /usr/lib/modules/4.9.337-tegra/modules.dep \
         /usr/lib/aarch64-linux-gnu/tegra/libcuda.so.1.1 \
         /usr/lib/aarch64-linux-gnu/libffi.so.6 \
         /etc/init.d/nv-l4t /etc/init.d/nv-l4t-early /etc/init.d/jetson-firstboot \
         /etc/systemd/nv.sh /usr/sbin/sshd /usr/local/bin/cuda-check; do
    exists "$p" && ok "$p" || bad "missing $p"
done

for l in /bin /sbin /lib; do
    debugfs -R "stat $l" "$FS" 2>/dev/null | grep -q 'Type: symlink' && ok "$l is a merged-/usr symlink" || bad "$l is not a symlink"
done

if exists /etc/ssh/ssh_host_ed25519_key; then bad "SSH host keys baked into image"; else ok "no SSH host keys in image"; fi

echo "  extlinux.conf:"
debugfs -R "cat /boot/extlinux/extlinux.conf" "$FS" 2>/dev/null | grep -vE '^\s*(#|$)' | sed 's/^/    /'

if [ $fail -ne 0 ]; then echo "Image verification FAILED"; exit 1; fi
echo "Image verification passed"
