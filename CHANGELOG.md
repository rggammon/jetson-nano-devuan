# Changelog

## Unreleased

- Drop Mesa and LLVM (~155 MB installed) from the image. Debian's GL dispatcher (libglvnd) hard-depends on Mesa's EGL/GLX vendor libraries, but on Tegra it always dispatches to NVIDIA's `libEGL_nvidia`/`libGLX_nvidia`. Empty `libegl-mesa0`/`libglx-mesa0` placeholder packages satisfy the dependency, and the build fails if Mesa or LLVM reappear in the base image.
  - To install real Mesa later (e.g. for an X server with glamor), run `sudo apt install --allow-downgrades libegl-mesa0=<version> libglx-mesa0=<version>`, using the versions shown by `apt policy libegl-mesa0`.

## v1.0.0 — 2026-10-17

- First release: Devuan 6 Excalibur (OpenRC, no systemd) with NVIDIA L4T R32.7.6 (kernel 4.9.337-tegra) and the CUDA 10.2 runtime for Jetson Nano.
- Verified on a Jetson Nano 4 GB devkit: boots, DHCP + SSH + mDNS, root filesystem growth on first boot, all NVIDIA services (`nv-l4t-early`, `nv-l4t`, `nv-phs`, `nv-zram`), and `cuda-check` (PTX JIT on the GPU).
