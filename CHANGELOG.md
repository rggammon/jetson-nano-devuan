# Changelog

## Unreleased

- Drop Mesa and LLVM (~155 MB installed) from the image. On Tegra, GL/EGL always go through NVIDIA's own libraries, so Mesa is never used. It came in through two dependency chains:
  - Debian's GL dispatcher (libglvnd: `libegl1`, `libglx0`) hard-depends on Mesa's EGL/GLX vendor libraries. Empty `libegl-mesa0`/`libglx-mesa0` placeholders satisfy that dependency. Nothing in Debian/Devuan depends on them at an exact version, so they don't block other installs.
  - `nvidia-l4t-multimedia` → `libgstreamer-plugins-bad1.0-0` → `libgstreamer-gl` → `libgbm1` → Mesa. **Hardware video (`nvidia-l4t-multimedia`, `-multimedia-utils`) is no longer installed by default**; install it and GStreamer when needed (see README). It then brings in Mesa as a normal dependency.
  - The build fails if Mesa, LLVM or GBM reappear in the base image.

## v1.0.0 — 2026-10-17

- First release: Devuan 6 Excalibur (OpenRC, no systemd) with NVIDIA L4T R32.7.6 (kernel 4.9.337-tegra) and the CUDA 10.2 runtime for Jetson Nano.
- Verified on a Jetson Nano 4 GB devkit: boots, DHCP + SSH + mDNS, root filesystem growth on first boot, all NVIDIA services (`nv-l4t-early`, `nv-l4t`, `nv-phs`, `nv-zram`), and `cuda-check` (PTX JIT on the GPU).
