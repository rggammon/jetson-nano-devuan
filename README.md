# Jetson Nano — Devuan (no systemd) + NVIDIA L4T R32.7.6

Reproducible SD-card images for the **NVIDIA Jetson Nano Developer Kit (P3448/P3449, 4 GB and 2 GB)** that combine:

- **Devuan 6 "Excalibur"** (Debian 13 "Trixie" without systemd) with **OpenRC**, built from scratch with `mmdebstrap`
- **NVIDIA's L4T R32.7.6 BSP**, the final JetPack 4.6.x release: kernel `4.9.337-tegra`, GPU/multimedia drivers, `nvpmodel`, zram, and **CUDA 10.2**

Images are built by GitHub Actions on native arm64 runners (no qemu) and attached to [Releases](../../releases) for `v*` tags.

> **Status: experimental.** CI builds and checks the image offline. Booting on real hardware has not been verified yet, so expect to need the serial console the first time.

## Why Devuan

NVIDIA froze the Nano on kernel 4.9 and Ubuntu 18.04. A newer Debian userland runs on that kernel, but **systemd 257 (Trixie) deprecates cgroup v1** and the 4.9 kernel doesn't support cgroup v2 well. systemd 258+ (Debian 14) drops cgroup v1 entirely. Devuan avoids this: sysvinit runs as PID 1, OpenRC manages services, and eudev handles devices, none of which care about cgroups.

NVIDIA's L4T packages don't depend on systemd. Their services just wrap shell scripts, which are ported here as OpenRC scripts:

| NVIDIA systemd unit | OpenRC service |
|---|---|
| `nvfb-early.service`, `nvfb.service` | `nv-l4t-early` |
| `nv.service`, `nvpmodel.service`, `nvphs.service` | `nv-l4t` |
| `nvzramconfig.service` | `nv-zram` |
| (new) | `jetson-firstboot`: grows the root filesystem, generates SSH host keys and machine-id |

## Requirements

1. **QSPI bootloader on L4T R32.7.x.** On the production-module Nano (B01 / 2 GB), the bootloader lives in the module's QSPI flash, not on the SD card. If a stock JetPack 4.6.x SD image boots on your board, you're set. Otherwise, update QSPI once from an x86_64 Linux host with the [R32.7.6 BSP](https://developer.nvidia.com/embedded/linux-tegra-r3276), with the board in force-recovery mode:
   ```bash
   sudo ./flash.sh jetson-nano-qspi-sd mmcblk0p1
   ```
2. A microSD card of **8 GB or more**. The root filesystem grows to fill the card on first boot.
3. Strongly recommended: a **3.3 V USB-UART adapter** on the J50 debug UART header (115200 8N1). The kernel console and a login prompt (`ttyS0`) come up there. Without it, a failed boot only shows the NVIDIA logo.

## Flash and boot

1. Download `jetson-nano-devuan-*.img.xz` from Releases (or from a workflow run's artifacts) and check it against its `.sha256` file.
2. Write it with [balenaEtcher](https://etcher.balena.io), or:
   ```bash
   xz -dc jetson-nano-devuan-*.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
   ```
3. Boot with Ethernet connected. The first boot grows the filesystem and generates SSH host keys.
4. Log in on the serial console, HDMI console, or `ssh jetson@jetson-nano.local` (or the IP shown by your router). The login is **`jetson` / `jetson`** and you'll be **forced to change the password** at first login. `root` is locked, so use `sudo`.

## Verify

```bash
uname -r                      # 4.9.337-tegra
cat /etc/devuan_version       # excalibur
rc-status                     # OpenRC services
sudo nvpmodel -q              # power mode (MAXN / 5W)
cuda-check                    # JIT-compiles and runs a PTX kernel on the GPU via libcuda
```

## What's in the image

| Layer | Contents |
|---|---|
| Boot | Single GPT partition `APP` (ext4). NVIDIA U-Boot in QSPI reads `/boot/extlinux/extlinux.conf` and boots `/boot/Image` + NVIDIA's `/boot/initrd`. The kernel DTB comes from QSPI, as with stock images. |
| Kernel/BSP | `nvidia-l4t-{core,init,configs,tools,kernel,kernel-dtbs,initrd,firmware,xusb-firmware,3d-core,wayland,cuda,libvulkan,multimedia,multimedia-utils,jetson-io}` 32.7.6 |
| CUDA | `cuda-libraries-10-2` (runtime) by default. The workflow input can switch to `cuda-toolkit-10-2` or none. cuDNN 8.2 and TensorRT 8.2 can be installed with `apt` from NVIDIA's repo, which is preconfigured. |
| Userland | Devuan Excalibur minbase + OpenRC, eudev, OpenSSH, ifupdown + dhcpcd (`eth0` DHCP), chrony, fake-hwclock, cron, rsyslog, sudo, Python 3.13 |
| Compat | `libffi6` (Debian 10) and `libpcre3` (Debian 12), pinned by SHA256, plus a dummy `libegl1-mesa`. These cover sonames NVIDIA's 18.04-era binaries need that Trixie no longer ships. |

## Build

### GitHub Actions

`.github/workflows/build.yml` runs on `ubuntu-24.04-arm`, which is free for public repositories. It builds inside a privileged `debian:trixie` container:

- Push or PR: builds, verifies, and uploads the image as a workflow artifact.
- **Run workflow** (manual): pick the CUDA flavor and add extra packages.
- Tag `v*`: also publishes a GitHub Release.

### Locally

Run on any arm64 Debian/Devuan machine as root. On x86_64 it also works with `qemu-user-static` binfmt and `ALLOW_FOREIGN=1`, but slower.

```bash
sudo apt install mmdebstrap e2fsprogs gdisk xz-utils curl ca-certificates dpkg-dev
sudo CUDA=runtime ./build.sh            # output in ./out
```

Variables: `SUITE`, `MIRROR`, `CUDA` (`none|runtime|toolkit`), `EXTRA_PACKAGES`, `IMG_HOSTNAME`, `IMG_USER`, `IMG_PASSWORD`, `IMAGE_VERSION`, `COMPRESS=0`.

`scripts/verify-image.sh <img>` checks a built image offline: the GPT layout, ext4 features readable by kernel 4.9 and U-Boot, boot-critical files, and that no SSH host keys are baked in.

## Known limits

- **Kernel 4.9 is end-of-life.** It's NVIDIA's last kernel for this SoC, and nothing newer has working CUDA.
- **No GPU-accelerated X desktop.** NVIDIA's Xorg driver targets the Ubuntu 18.04 X server ABI. CUDA, EGL, and the multimedia engines work without X. A desktop would run on the framebuffer.
- **`nvcc` needs gcc 8 or older.** Trixie ships gcc 14, so build CUDA code in an Ubuntu 18.04 container or cross-compile. PTX JIT through the driver works (see `cuda-check`).
- **Docker** needs cgroups and kernel features that 4.9 only partly provides. It's not included or tested.
- **Debian 14 / Devuan 7** may require newer kernel interfaces. Excalibur is the target.

## License

The build scripts in this repository are MIT licensed (see [LICENSE](LICENSE)). Built images contain NVIDIA proprietary software distributed under NVIDIA's license terms, plus Debian/Devuan packages under their own licenses.
