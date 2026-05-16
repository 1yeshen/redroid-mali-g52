# redroid-mali-g52

Custom **redroid** (Android in Docker) image with **Mali-G52 GPU hardware acceleration** for Rockchip RK3568 devices (EasePi R1, Radxa ROCK3A/3B, Orange Pi 3B, etc.).

[![Analyze Mali Binaries](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/analyze-mali-binaries.yml/badge.svg)](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/analyze-mali-binaries.yml)
[![Build & Test Matrix](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-test-matrix.yml/badge.svg)](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-test-matrix.yml)
[![Build Mali-G52 Overlay](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-mali-overlay.yml/badge.svg)](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-mali-overlay.yml)

## Status

| Component | Status | Notes |
|-----------|--------|-------|
| Container boot (old base) | ✅ | Pinned to SHA `c898abca51e6` |
| Mali /dev/mali0 detection | ✅ | `--mount bind` preserves inode (fixes Issue #228) |
| Mali userspace driver load | ⚠️ | g25p0 passes init (rk_so_ver patched 10→8), GPU not functional |
| SurfaceFlinger GPU init | ❌ | DDK mismatch: kernel g18p0 vs available userspace drivers |
| Hardware acceleration | ❌ | Pending matching (g13p0–g18p0) bionic userspace driver |

**Root cause:** The kernel's Mali Bifrost module (`bifrost_kbase.ko`) is compiled at DDK **g18p0-01eac0** (≈r46p0), but all available Android (bionic) userspace Mali drivers are at incompatible DDK versions. Userspace must use a compatible DDK version matching the kernel module's IOCTL interface.

### Critical Discovery: `--mount` vs `--device` for `/dev/mali0`

The Mali kernel driver checks that the inode number of `/dev/mali0` matches what it expects. Using `--device /dev/mali0` creates a **new inode** in the container, causing the driver to reject it. Use `--mount type=bind` instead:

```bash
# ❌ Does NOT work (different inode):
--device /dev/mali0

# ✅ Works (same inode as host):
--mount type=bind,source=/dev/mali0,destination=/dev/mali0
```

See [redroid-doc Issue #228](https://github.com/remote-android/redroid-doc/issues/228) for details.

### DDK Compatibility Matrix

| Userspace DDK | Source | rk_so_ver | rk3588-1.5.x Ref | Kernel g18p0 Result |
|---------------|--------|-----------|-------------------|---------------------|
| g2p0-01eac0 | Old RK3566 firmware | 8 | g2p0 | ❌ SIGSEGV in `eglCreateImageKHR` |
| g7p1-01bet0 | Stock RK3568 firmware | 8 | g7p1 | ❌ SIGSEGV in `eglCreateImageKHR` |
| g13p0-01eac0 | libmali-rockchip (glibc) | 11 | g13p0 | ❌ glibc ≠ bionic (wrong libc) |
| **g25p0-00eac0** (patched) | FriendlyElec Android14 SDK rkr8 | **8** (was 10) | g25p0 | ✅ Exits cleanly (code 0), no GPU function |
| **g18p0 (needed)** | Not found yet in bionic build | ? | g2p0 | ✅ Should match kernel module |
| g13p0-bionic (needed) | Rockchip Android 12/13 SDK | ? | g13p0 | ✅ Confirmed working per Radxa docs |

Confirmed by Radxa docs: For RK356X, the correct userspace DDK for g18p0 kernel is **g13p0** (`libmali-bifrost-g52-g13p0-x11-wayland-gbm` on Debian).

## Background

On iStoreOS (OpenWrt 24.10, kernel 6.6.127) running on EasePi R1 (RK3568):

- **Stock redroid:14.0.0_64only-latest** runs stably with software rendering (`gpu_mode=guest`)
- But `servicemanager` is zombie due to kernel 6.6 binder ABI incompatibility (container still works for basic tasks)
- **/dev/mali0** exists on the host with `bifrost_kbase` kernel module at DDK g18p0
- This repo builds a custom image with the Mali-G52 userspace driver

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    GitHub Actions CI                      │
│  ┌─────────────────┐    ┌──────────────────────────────┐ │
│  │ Analyze Mali     │    │ Build & Test Matrix          │ │
│  │ Binaries (30     │    │ 3 Mali × 4 Base = 12 combos │ │
│  │ stage RE pipe)   │    │                              │ │
│  └─────────────────┘    └──────────────────────────────┘ │
│  ┌─────────────────┐    ┌──────────────────────────────┐ │
│  │ Extract Mali .so │ -> │ Build Docker overlay image   │ │
│  │ from RK3568      │    │ redroid + Mali-G52 drivers   │ │
│  │ Android firmware  │    │        ↓                     │ │
│  └─────────────────┘    │  ghcr.io/1yeshen/redroid-     │ │
│                          │  mali-g52:latest              │ │
│                          └──────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
         ↓ pull on device
┌─────────────────────────────────────────────────────────┐
│              EasePi R1 (RK3568)                           │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Docker Container: redroid-mali-g52               │   │
│  │  ┌────────────────────────────────────────────┐   │   │
│  │  │  Android 14 (AOSP)                        │   │   │
│  │  │  ├─ libGLES_mali.so (Mali-G52) ───────────┼──┼───┼───► /dev/mali0
│  │  │  ├─ gralloc-bifrost.so ───────────────────┼──┼───┼───► /dev/rga
│  │  │  ├─ hwcomposer.rockchip.so ──────────────┼──┼───┼───► /dev/dri/card0
│  │  │  └─ mpp_service ──────────────────────────┼──┼───┼───► /dev/mpp_service
│  │  └────────────────────────────────────────────┘   │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## Repository Contents

### Workflows (GitHub Actions)

| Workflow | Description | Runner |
|----------|-------------|--------|
| `analyze-mali-binaries.yml` | 30-stage reverse engineering pipeline: ELF headers, capstone disasm, YARA, entropy, DDK compat matrix, cross-version diffing | Free |
| `build-test-matrix.yml` | Build + quick-boot-test all 12 combinations (3 Mali × 4 base images) | Free |
| `build-mali-overlay.yml` | Extract Mali .so from firmware URL + build Docker overlay image | Free |
| `extract-mali-from-firmware.yml` | Extract vendor partition from RK3568 Android firmware image | Free |
| `build-aosp-full.yml` | Full AOSP + redroid-rockchip source build (16-core runner) | Paid |

### Mali Driver Variants

| Variant | DDK | Size | rk_so_ver | Notes |
|---------|-----|------|-----------|-------|
| `mali-binaries/` (default) | g25p0-00eac0 | 50.5 MB | 10 (patched→8) | From FriendlyElec Android 14 |
| `mali-binaries-g2p0/` | g2p0-01eac0 | 39.2 MB | 8 | Old RK3566 firmware |
| `mali-binaries-g7p1/` | g7p1-01bet0 | 39.5 MB | 8 | Stock RK3568 firmware |
| `mali-binaries/.../g25p0_patched.so` | g25p0-00eac0 | 50.5 MB | **8** (patched) | rk_so_ver 10→8, exits cleanly |

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/analyze_mali_so.sh` | Local reverse engineering of Mali .so files (DDK, symbols, entropy) |
| `scripts/extract-mali-from-firmware.sh` | Extract Mali drivers from Android firmware images |

### Docker Configuration

| File | Purpose |
|------|---------|
| `docker/Dockerfile` | Multi-stage Alpine→redroid build |
| `docker/mali-config/bin/gpu_config.sh` | Mali GPU configuration script |
| `docker/mali-config/etc/init/init.mali_gpu.rc` | Mali GPU init script |
| `docker/mali-config/etc/init/init.rockchip.gpu.rc` | Rockchip GPU init |
| `docker/mali-config/etc/gralloc/capabilities.xml` | Gralloc Bifrost configuration |

## Build Methods

### Method 1: Firmware Extraction (Recommended, Free Runner ✅)

Extract prebuilt Mali-G52 Android (bionic) drivers from RK3568 Android firmware.

**Trigger:** Use `workflow_dispatch` on GitHub Actions:
1. Go to **Actions** → **Build Mali-G52 Overlay** → **Run workflow**
2. Provide a URL to an RK3568 Android firmware (e.g., Firefly or Radxa release)
3. The workflow extracts Mali .so files and builds a Docker overlay image
4. Image is pushed to `ghcr.io/1yeshen/redroid-mali-g52:latest`

**Firmware sources:**
- [FriendlyElec NanoPi R5C Android 14](https://download.friendlyelec.com/NanoPiR5C)
- [Firefly ROC-RK3566-PC Android 11](https://en.t-firefly.com/doc/download/93.html)
- [Radxa ROCK3A Android 11](https://docs.radxa.com/en/rock3/rock3a/other-os/android)
- Any RK3568/RK3566 Android firmware containing Mali-G52 Bifrost drivers

### Method 2: Full AOSP Build (Paid Runner 💰)

Full source compilation of AOSP + redroid-rockchip with Mali-G52 HAL.

**Requires:** GitHub larger runner (16-core/64GB/300GB disk recommended)
**Build time:** ~5 hours
**Cost:** ~$2.40 (at $0.008/min on 4-core larger runner)

**Trigger:** Use `workflow_dispatch` on **Build AOSP (Full) - Mali-G52**

## Local Usage (on EasePi R1 / RK3568)

### Prerequisites: Load Mali kernel module

```bash
# Load the Bifrost kernel module (required after every reboot on iStoreOS)
insmod /lib/modules/$(uname -r)/bifrost_kbase.ko

# Verify Mali device
ls -la /dev/mali0
```

### Build locally

```bash
# Use the pinned working base image
docker build --build-arg REDROID_BASE=redroid/redroid:14.0.0-arch-fix \
  -t redroid-mali-g52 -f docker/Dockerfile .
```

### Run (with --mount bind fix)

```bash
# Run with Mali GPU acceleration
# IMPORTANT: Use --mount bind (NOT --device) for /dev/mali0
docker run -d --privileged \
  --name redroid-mali \
  --mount type=bind,source=/dev/mali0,destination=/dev/mali0 \
  -p 5555:5555 \
  redroid-mali-g52:latest \
  androidboot.redroid_gpu_mode=mali
```

**Note:** All current Mali userspace drivers (g2p0/g7p1/g25p0) have DDK mismatch with the kernel module (g18p0). See [Status](#status) for details.

### GPU Verification

```bash
# Inside container, check GPU devices
adb shell ls -la /dev/mali0 /dev/rga /dev/dri/card0

# Check logcat for Mali/GPU errors
adb shell logcat -d -s SurfaceFlinger libEGL mali

# Check tombstones for GPU crashes
adb shell ls /data/tombstones/

# Check which EGL driver is loaded
adb shell dumpsys SurfaceFlinger | grep GLES
```

## Project Structure

```
redroid-mali-g52/
├── .github/workflows/
│   ├── analyze-mali-binaries.yml   # 30-stage RE pipeline
│   ├── build-mali-overlay.yml      # Firmware extraction + overlay build
│   ├── build-test-matrix.yml       # 12-combo build & test matrix
│   ├── build-aosp-full.yml         # Full AOSP build (paid runner)
│   └── extract-mali-from-firmware.yml  # Firmware partition extraction
├── scripts/
│   ├── analyze_mali_so.sh          # Local Mali .so analysis
│   └── extract-mali-from-firmware.sh   # Firmware extraction script
├── docker/
│   ├── Dockerfile                  # Multi-stage Docker build
│   └── mali-config/
│       ├── bin/gpu_config.sh
│       ├── etc/init/init.mali_gpu.rc
│       ├── etc/init/init.rockchip.gpu.rc
│       └── etc/gralloc/capabilities.xml
├── mali-binaries/                  # Default (g25p0) Mali driver
│   └── vendor/
│       ├── lib/egl/libGLES_mali.so
│       ├── lib64/egl/libGLES_mali.so
│       ├── lib64/egl/libGLES_mali_g25p0.so       # Original g25p0 backup
│       ├── lib64/egl/libGLES_mali_g25p0_patched.so # rk_so_ver 10→8 patched
│       └── lib64/hw/
│           ├── android.hardware.graphics.allocator@4.0-impl-bifrost.so
│           └── android.hardware.graphics.mapper@4.0-impl-bifrost.so
├── mali-binaries-g2p0/             # g2p0 Mali driver variant
│   └── vendor/lib64/egl/libGLES_mali.so
├── mali-binaries-g7p1/             # g7p1 Mali driver variant
│   └── vendor/lib64/egl/libGLES_mali.so
├── README.md
├── README.zh-CN.md
├── LICENSE              # GPL-3.0
├── PATENTS              # Patent grant + litigation termination
├── NOTICE               # Third-party attribution
└── .gitignore
```

## Technical Details

### Mali-G52 Bifrost Userspace Components

| File | Purpose |
|------|---------|
| `libGLES_mali.so` | Mali GPU userspace driver (EGL/GLES/Vulkan) - the main driver binary |
| `android.hardware.graphics.allocator@4.0-impl-bifrost.so` | Gralloc buffer allocation (Bifrost) |
| `android.hardware.graphics.mapper@4.0-impl-bifrost.so` | Gralloc buffer mapping (Bifrost) |
| `hwcomposer.rockchip.so` | Rockchip hardware composer |
| `capabilities.xml` | Gralloc capabilities config |

### DDK Version Investigation

The Mali Bifrost DDK follows the naming pattern `gXXpY`:
- `g` = generation, `p` = patch
- Higher number = newer DDK
- Bifrost architecture spans `g2p0` through `g25p0`+

**ARM DDK version equivalence (approximate):**
| DDK | ARM Version | Notes |
|-----|-------------|-------|
| g2p0 | r32p0 | Very old |
| g7p1 | r38p0 | Old |
| **g13p0** | **r41p0** | **Confirmed working with g18p0 kernel** |
| g15p0 | r43p0 | Might work |
| g17p0 | r45p0 | Might work |
| **g18p0** | **r46p0** | **Our kernel module** |
| g25p0 | r48p0 | Too new |

**Key findings:**
1. **Kernel module** (bifrost_kbase.ko): `g18p0-01eac0` (~r46p0, Rockchip kernel 6.6)
2. **g7p1 bionic driver**: From stock RK3568 firmware, DDK too old for kernel
3. **g13p0 glibc driver**: From libmali-rockchip, correct DDK era but incompatible (glibc vs bionic). The Debian package `libmali-bifrost-g52-g13p0-x11-wayland-gbm` contains `libmali.so.1.9.0` (43MB, rk_so_ver 11)
4. **g25p0 bionic driver**: From FriendlyElec Android 14 SDK rkr8, newer than kernel DDK. rk_so_ver patched from 10→8 to pass init, but IOCTL mismatch persists
5. **g13p0 bionic (Android) driver**: **NOT FOUND YET** — This is the missing piece. It exists in Rockchip's Android 12/13 SDK vendor partition.
6. **g13p0 availability**: The glibc version confirms g13p0 exists for Mali-G52. A bionic (Android) build must be extracted from Rockchip Android SDK firmware.

### Source of g13p0 Mali Driver

The Mali-G52 g13p0 userspace driver is known to be distributed in:

1. **Radxa Debian Bookworm**: `libmali-bifrost-g52-g13p0-x11-wayland-gbm` (glibc) — from `tsukumijima/libmali-rockchip`
2. **christianhaitian/rk3566_core_builds**: `mali/aarch64/libmali-bifrost-g52-g13p0-gbm.so` (glibc) — for ArkOS/EmuELEC
3. **Rockchip Android 12/13 SDK**: Contains bionic `libGLES_mali.so` at g13p0 — **this is what we need**
4. **bmdhacks/dArkOS_rg52mini**: References g13p0 for RK3562, downloads from `rk3566_core_builds`

### rk_so_ver Patching

The `rk_so_ver` field in `libGLES_mali.so` is checked by Android's linker/init to verify driver compatibility. The base image `redroid/redroid:14.0.0-arch-fix` expects rk_so_ver `8@0`.

**g25p0 patching (offset 0x11e834):**
```
Before: rk_so_ver is '10'.
After:  rk_so_ver is '8@0'.
```

This fixes the SIGHUP (exit 129) during init, allowing the container to boot. However, the Mali GPU still doesn't work due to the IOCTL interface mismatch between g25p0 userspace and g18p0 kernel.

### Kernel Device Requirements

| Device | Purpose |
|--------|---------|
| `/dev/mali0` | Mali GPU (major 10, minor 258) |
| `/dev/rga` | Raster Graphics Acceleration |
| `/dev/mpp_service` | Video codec (Media Process Platform) |
| `/dev/dri/card0` | DRM display |

### Known Limitations

1. **DDK mismatch**: Kernel module (g18p0) vs userspace drivers (g2p0/g7p1/g25p0) — IOCTL interface incompatibility
2. **Binder ABI**: Kernel 6.6 binder ABI is incompatible with Android 14's libbinder (oneway spam handling changed). This causes `servicemanager` and `hwservicemanager` to be zombie. Mali GPU HAL should still load correctly since it communicates via the Mali kernel driver (`/dev/mali0`), not binder.
3. **Missing bionic g13p0 driver**: The correct userspace driver (g13p0 bionic) has not been found in public repositories. It must be extracted from Rockchip's internal Android SDK.

## References

- [redroid-rockchip/platform_manifests](https://github.com/redroid-rockchip/platform_manifests)
- [remote-android/redroid-doc](https://github.com/remote-android/redroid-doc)
  - [Issue #228: RK3588 Mali GPU (--mount bind fix)](https://github.com/remote-android/redroid-doc/issues/228)
  - [Issue #519: RK3399 Mali GPU (EGL_BAD_ACCESS)](https://github.com/remote-android/redroid-doc/issues/519)
  - [Issue #614: RK3588 Mali GPU (mali_csffw.bin)](https://github.com/remote-android/redroid-doc/issues/614)
- [tsukumijima/libmali-rockchip](https://github.com/tsukumijima/libmali-rockchip) — Debian Mali driver packages
- [christianhaitian/rk3566_core_builds](https://github.com/christianhaitian/rk3566_core_builds) — Prebuilt Mali g13p0 (glibc) for ArkOS
- [bmdhacks/dArkOS_rg52mini](https://github.com/bmdhacks/dArkOS_rg52mini) — Reference build with Mali g13p0
- [FriendlyElec rk35xx-android14](http://112.124.9.243:3000/friendlyelec/rk35xx-android14)
- [Radxa ROCK3A Android docs](https://docs.radxa.com/en/rock3/rock3a/other-os/android)
- [Radxa GPU Driver Switch](https://docs.radxa.com/en/rock5/rock5c/radxa-os/mali-gpu) — Confirms g13p0 for RK356X
- [Rockchip Linux Graphics](https://opensource.rock-chips.com/wiki_Graphics)
- [Rockchip Mali Wiki](https://opensource.rock-chips.com/wiki_Mali)
- [CNflysky/redroid-rk3588](https://github.com/CNflysky/redroid-rk3588) — Reference RK3588 redroid with Mali-G610
