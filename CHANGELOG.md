# Changelog

## Unreleased

- Drop Mesa and LLVM (~155 MB installed) from the image. Nothing on Tegra uses them, but two dependency chains pulled them in:
  - Debian's GL dispatcher (libglvnd) hard-depends on Mesa's EGL/GLX vendor libraries, but on Tegra it always dispatches to NVIDIA's `libEGL_nvidia`/`libGLX_nvidia`. Empty `libegl-mesa0`/`libglx-mesa0` placeholders satisfy that dependency.
  - `nvidia-l4t-multimedia` declares `libgstreamer-plugins-bad1.0-0`, which chains through `libgstreamer-gl` and `libgbm1` to Mesa. NVIDIA's binaries only link `libgstreamer-1.0` and `libgstvideo-1.0` (from plugins-base), so it's a placeholder too.
  - The build fails if Mesa, LLVM or GBM reappear in the base image.
  - To restore a real package later (e.g. for an X server or GStreamer GL plugins), run `sudo apt install --allow-downgrades <pkg>=<version>`, using the version shown by `apt policy <pkg>`.

## v1.0.0 — 2026-10-17

- First release: Devuan 6 Excalibur (OpenRC, no systemd) with NVIDIA L4T R32.7.6 (kernel 4.9.337-tegra) and the CUDA 10.2 runtime for Jetson Nano.
- Verified on a Jetson Nano 4 GB devkit: boots, DHCP + SSH + mDNS, root filesystem growth on first boot, all NVIDIA services (`nv-l4t-early`, `nv-l4t`, `nv-phs`, `nv-zram`), and `cuda-check` (PTX JIT on the GPU).
