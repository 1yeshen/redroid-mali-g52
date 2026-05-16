# redroid-mali-g52

Custom **redroid** (Android in Docker) image with **Mali-G52 GPU hardware acceleration** for Rockchip RK3568 devices (EasePi R1, Radxa ROCK3A/3B, Orange Pi 3B, etc.).

[![Analyze Mali Binaries](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/analyze-mali-binaries.yml/badge.svg)](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/analyze-mali-binaries.yml)
[![Build & Test Matrix](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-test-matrix.yml/badge.svg)](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-test-matrix.yml)
[![Build Mali-G52 Overlay](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-mali-overlay.yml/badge.svg)](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-mali-overlay.yml)
[![Build Panfrost Module](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-panfrost-module.yml/badge.svg)](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-panfrost-module.yml)

## Status

| Component | Status | Notes |
|-----------|--------|-------|
| Container boot (old base) | ✅ | Pinned to SHA `c898abca51e6` |
| Mali /dev/mali0 detection | ✅ | `--mount bind` preserves inode (fixes Issue #228) |
| Mali userspace driver load | ⚠️ | g25p0 passes init (rk_so_ver patched 10→8), GPU not functional |
| SurfaceFlinger GPU init | ❌ | DDK mismatch: kernel g18p0 vs available userspace drivers |
| **Panfrost kernel module** | **✅ Built** | Cross-compiled for 6.6.127, vermagic matches |
| **Panfrost module load (built-in)** | **⚠️ Probe fails (-ENOENT)** | Built-in Panfrost handles -EBUSY but not -ENOENT from corrupted OPP state |
| **`opp-fix.ko` (OPP recovery module)** | **✅ Built** | Clears `supported_hw` filter, re-adds DT OPP entries post-Mali |
| **`load-panfrost-fixed.sh` workflow** | **✅ Script ready** | Mali→unbind→opp-fix→bind Panfrost, verified on device |
| **Panfrost probe via opp-fix** | **🔄 Pending CI fix** | Patch context mismatch in CI; v1 patch worked, v2 needs correction |
| **Hardware acceleration (Mali)** | ❌ | Pending matching (g13p0–g18p0) bionic userspace driver |
| **Hardware acceleration (Panfrost)** | **🔄 In progress** | CI patch fix → deploy modules → opp-fix → bind → Mesa for Android |

**Root cause (Mali DDK):** The kernel's Mali Bifrost module (`bifrost_kbase.ko`) is compiled at DDK **g18p0-01eac0** (≈r46p0), but all available Android (bionic) userspace Mali drivers are at incompatible DDK versions.

**Root cause (Panfrost OPP):** On RK3568, Mali's `rockchip_init_opp_info()` pre-populates the GPU OPP table via `dev_pm_opp_set_config()`. When Mali is removed, `rockchip_uninit_opp_info()` only partially cleans up — leaving `supported_hw` filters that kill all DT OPP entries. When Panfrost later probes, `devm_pm_opp_of_add_table()` returns `-ENOENT` ("no supported OPPs").

**Current approach:** Instead of rebuilding the kernel (Panfrost is built-in `[permanent]`), we use **`opp-fix.ko`** — a tiny kernel module that clears `supported_hw` and re-adds OPP entries from DT. Workflow: load Mali → unbind Mali → load `opp-fix.ko` → bind built-in Panfrost. This avoids a reboot and works with the existing kernel.

## Panfrost (Open-Source GPU Driver) — New Approach

After exhausting the closed-source Mali userspace driver approach (see [DDK Compatibility Matrix](#ddk-compatibility-matrix)), we have **pivoted to the open-source Panfrost GPU driver** for Mali-G52 on RK3568.

### Why Panfrost?

- **Panfrost supports Mali-G52** (Bifrost architecture) in mainline Linux since kernel 5.2
- **Redroid already supports Panfrost** — auto-detects via `/sys/kernel/debug/dri/*/name` and sets `ro.hardware.vulkan=panfrost`, uses `gbm` gralloc
- **No DDK dependency** — Panfrost is part of the upstream kernel, no proprietary IOCTL interface to match
- **Open-source** — Mesa Gallium driver + kernel module, fully transparent

### Progress So Far

| Step | Status | Details |
|------|--------|---------|
| 1. Research Panfrost feasibility | ✅ | Confirmed: redroid supports Panfrost, RK3568 GPU DT compatible |
| 2. Analyze iStoreOS kernel config | ✅ | DRM disabled, IOMMU/SMMU/DMA_SHARED_BUFFER enabled |
| 3. Cross-compile panfrost.ko | ✅ | Built for kernel **6.6.127** (exact match), vermagic = `6.6.127 SMP mod_unload aarch64` |
| 4. Load DRM modules | ✅ | **5 modules built**: `drm.ko`, `drm_shmem_helper.ko`, `gpu-sched.ko`, `panfrost.ko`, `drm_panel_orientation_quirks.ko` |
| 5. First probe attempt | ⚠️ | Probe fails with `-EBUSY` — OPP/regulator state leftover from Mali `bifrost_kbase.ko` |
| 6. Root cause diagnosis | ✅ | Identified OPP corruption chain: Mali `rockchip_init_opp_info()` → partial cleanup → `-ENOENT` for Panfrost |
| 7. `opp-fix.ko` kernel module | ✅ | Tiny module that clears `supported_hw` (→0xffffffff) and re-adds DT OPP entries |
| 8. `load-panfrost-fixed.sh` script | ✅ | Complete workflow: load Mali → unbind → opp-fix → bind Panfrost → verify renderD128 |
| 9. CI patch (v1) | ✅ | Two-hunk patch worked: handles `-EBUSY`, `-EEXIST`, `-ENOENT` from pre-configured OPP |
| 10. CI patch (v2) | ❌ | Single-hunk patch doesn't apply to vanilla 6.6.127 — context mismatch. Needs revert to v1 format |
| 11. Build Mesa for Android (bionic) | 🔜 | Cross-compile Mesa with `-Dgallium-drivers=panfrost` for Android container |

### How the Panfrost Kernel Module Was Built

The workflow `.github/workflows/build-panfrost-module.yml` cross-compiles `panfrost.ko` for iStoreOS 24.10.6 (kernel 6.6.127):

1. **Download** vanilla Linux 6.6.127 from kernel.org
2. **Fetch** OpenWrt kernel config from the iStoreOS repo (generic + rockchip/armv8)
3. **Merge configs** and enable `CONFIG_DRM=m`, `CONFIG_DRM_PANFROST=m`
4. **Build vmlinux** (generates `Module.symvers` for core kernel symbols)
5. **Build modules** via `make modules` (handles composite modules like `drm.ko`)
6. **Package & upload** all DRM `.ko` files as artifact

### Root Cause: Panfrost Probe Failure on RK3568

On RK3568 (EasePi R1) running iStoreOS kernel 6.6.127:

1. **Mali Bifrost driver loads at boot** (via `kmod-rkgpu-bifrost` / `85-rkgpu-bifrost`).
2. **`rockchip_init_opp_info()`** is called during Mali probe → pre-configures GPU OPP with:
   - Regulators (`dev_pm_opp_set_regulators`)
   - `supported_hw` mask (bin/speed matching)
   - 6 frequency entries (200 MHz–1000 MHz) from DT
3. **Mali is auto-removed ~28s after boot** (iStoreOS init script) → `rockchip_uninit_opp_info()` partially cleans up OPP state.
4. **Panfrost probes ~117s after boot** → calls:
   - `devm_pm_opp_set_regulators()` → **-EBUSY** (regulators still configured)
   - `devm_pm_opp_of_add_table()` → **-ENOENT** (residual `supported_hw` filter kills all 6 DT OPP entries)

**After Mali unbind, only 1/6 OPP entries survive** (200 MHz — debugfs confirmed).

The built-in Panfrost has a partial iStoreOS patch that handles `-EBUSY` (skips to `opp_add_table`), but **does NOT handle `-ENOENT`** from `devm_pm_opp_of_add_table()`.

### The `opp-fix.ko` Solution

Since Panfrost is built into the kernel (`[permanent]`) and can't be replaced by loading a different `panfrost.ko`, we use a **helper kernel module** to fix OPP state:

**`patches/opp-fix/opp-fix.c`** does:
1. Find the GPU device (`platform-fde60000.gpu`) OPP table
2. Clear `supported_hw` to `0xffffffff` (remove the filter)
3. Re-add all OPP entries from DT device node

**Complete workflow** (`scripts/load-panfrost-fixed.sh`):

```bash
# Step 1: Load Mali (configures OPP correctly)
insmod /lib/modules/$(uname -r)/bifrost_kbase.ko

# Step 2: Unbind Mali (partial cleanup leaves corrupted OPP)
echo "fde60000.gpu" > /sys/bus/platform/drivers/mali/unbind

# Step 3: Load opp-fix.ko (fixes supported_hw + re-adds OPP entries)
insmod /path/to/opp-fix.ko

# Step 4: Bind built-in Panfrost (handles -EBUSY, now sees clean OPP table)
echo "fde60000.gpu" > /sys/bus/platform/drivers/panfrost/bind

# Step 5: Verify
ls -la /dev/dri/renderD128
```

### CI Patch Status

The CI workflow `.github/workflows/build-panfrost-module.yml` builds both `panfrost.ko` (with OPP patch) and `opp-fix.ko`.

- **v1 patch** (two hunks: `@@ -134,7 +134,12 @@` + `@@ -142,12 +147,16 @@`): ✅ **Built successfully** in CI run `25960759519`
- **v2 patch** (single hunk `@@ -134,17 +134,27 @@`): ❌ **Fails** — context doesn't match vanilla Linux 6.6.127's `panfrost_devfreq.c`

**Fix needed:** Revert to two-hunk format or hand-craft patch against vanilla 6.6.127 source.

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
│  │ stage RE pipe)   │    │ (Mali DDK investigation)     │ │
│  └─────────────────┘    └──────────────────────────────┘ │
│  ┌─────────────────┐    ┌──────────────────────────────┐ │
│  │ Extract Mali .so │ -> │ Build Docker overlay image   │ │
│  │ from RK3568      │    │ redroid + Mali-G52 drivers   │ │
│  │ Android firmware  │    │        ↓                     │ │
│  └─────────────────┘    │  ghcr.io/1yeshen/redroid-     │ │
│                          │  mali-g52:latest              │ │
│                          └──────────────────────────────┘ │
│  ┌──────────────────────────────────────────────────┐    │
│  │ Build Panfrost Module (NEW)                       │    │
│  │ Cross-compile panfrost.ko for kernel 6.6.127      │    │
│  │ Download linux-6.6.127 + OpenWrt config           │    │
│  │ Enable CONFIG_DRM + CONFIG_DRM_PANFROST           │    │
│  │ Build vmlinux → Module.symvers → make modules     │    │
│  │ ↓ outputs: panfrost.ko, drm.ko, drm_shmem_helper  │    │
│  └──────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
         ↓ pull on device
┌─────────────────────────────────────────────────────────┐
│              EasePi R1 (RK3568)                           │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Docker Container: redroid-mali-g52               │   │
│  │  ┌────────────────────────────────────────────┐   │   │
│  │  │  Android 14 (AOSP)                        │   │   │
│  │  │  ├─ Mesa (Panfrost) ──────────────────────┼──┼───┼───► /dev/dri/renderD128
│  │  │  ├─ gralloc.gbm ──────────────────────────┼──┼───┼───► /dev/dri/card0
│  │  │  └─ mpp_service ──────────────────────────┼──┼───┼───► /dev/mpp_service
│  │  └────────────────────────────────────────────┘   │   │
│  │                                                    │   │
│  │  Kernel Modules (new):                             │   │
│  │  ┌────────────────────────────────────────────┐   │   │
│  │  │  panfrost.ko (→ /dev/dri/renderD128)       │   │   │
│  │  │  drm.ko                                     │   │   │
│  │  │  drm_shmem_helper.ko                        │   │   │
│  │  │  gpu-sched.ko                               │   │   │
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
| `build-panfrost-module.yml` | **Cross-compile panfrost.ko + opp-fix.ko** for iStoreOS kernel 6.6.127 (DRM + Panfrost from source) | Free |

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
| `scripts/load-panfrost-fixed.sh` | Complete workflow: load Mali → unbind → opp-fix.ko → bind Panfrost → verify |

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

### Prerequisites

#### Option A: Mali (closed-source, DDK mismatched)

```bash
# Load the Bifrost kernel module (required after every reboot on iStoreOS)
insmod /lib/modules/$(uname -r)/bifrost_kbase.ko

# Verify Mali device
ls -la /dev/mali0
```

#### Option B: Panfrost (open-source, recommended for new development)

**Method 1: Reboot with Mali blacklisted (cleanest)**

```bash
# 1. Blacklist Mali module (prevent auto-load)
echo "blacklist bifrost_kbase" > /etc/modprobe.d/blacklist-mali.conf
mv /etc/modules.d/85-rkgpu-bifrost /etc/modules.d/85-rkgpu-bifrost.disabled

# 2. Reboot (clears Mali OPP/regulator state)
reboot

# 3. After reboot, verify Mali is NOT loaded
lsmod | grep bifrost  # should be empty

# 4. Load DRM modules (order matters!)
insmod /mnt/nvme0n1-1/drm-modules/drm.ko
insmod /mnt/nvme0n1-1/drm-modules/gpu-sched.ko
insmod /mnt/nvme0n1-1/drm-modules/drm_shmem_helper.ko
insmod /mnt/nvme0n1-1/drm-modules/panfrost.ko

# 5. Verify Panfrost device
ls -la /dev/dri/renderD128
```

**Method 2: opp-fix.ko (no reboot needed, works with Mali loaded)**

```bash
# Use the automated workflow script
sh scripts/load-panfrost-fixed.sh /path/to/modules/

# Or manually:
# 1. Load Mali (configures OPP)
insmod /lib/modules/$(uname -r)/bifrost_kbase.ko
# 2. Unbind Mali from GPU
echo "fde60000.gpu" > /sys/bus/platform/drivers/mali/unbind
# 3. Load opp-fix to repair OPP table
insmod /path/to/opp-fix.ko
# 4. Bind built-in Panfrost (has -EBUSY handling)
echo "fde60000.gpu" > /sys/bus/platform/drivers/panfrost/bind
# 5. Verify
ls -la /dev/dri/renderD128
```

### Build locally

```bash
# Use the pinned working base image
docker build --build-arg REDROID_BASE=redroid/redroid:14.0.0-arch-fix \
  -t redroid-mali-g52 -f docker/Dockerfile .
```

### Run

#### With Mali GPU acceleration (--mount bind fix)

```bash
# IMPORTANT: Use --mount bind (NOT --device) for /dev/mali0
docker run -d --privileged \
  --name redroid-mali \
  --mount type=bind,source=/dev/mali0,destination=/dev/mali0 \
  -p 5555:5555 \
  redroid-mali-g52:latest \
  androidboot.redroid_gpu_mode=mali
```

**Note:** All current Mali userspace drivers (g2p0/g7p1/g25p0) have DDK mismatch with the kernel module (g18p0). See [Status](#status) for details.

#### With Panfrost GPU acceleration (planned)

```bash
# When Mesa Panfrost is ready, use host GPU mode (auto-detects Panfrost)
docker run -d --privileged \
  --name redroid-panfrost \
  -p 5556:5555 \
  your-panfrost-image:latest \
  androidboot.redroid_gpu_mode=host
```

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
│   ├── extract-mali-from-firmware.yml  # Firmware partition extraction
│   └── build-panfrost-module.yml       # Cross-compile panfrost.ko for kernel 6.6.127
├── patches/
│   ├── 0001-panfrost-devfreq-handle-preconfigured-OPP.patch  # OPP -EBUSY/-EEXIST/-ENOENT handling
│   └── opp-fix/
│       └── opp-fix.c               # Kernel module: clears supported_hw, re-adds DT OPP entries
├── scripts/
│   ├── analyze_mali_so.sh          # Local Mali .so analysis
│   ├── extract-mali-from-firmware.sh   # Firmware extraction script
│   └── load-panfrost-fixed.sh      # Mali→unbind→opp-fix→Panfrost workflow
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

1. **DDK mismatch (Mali approach)**: Kernel module (g18p0) vs userspace drivers (g2p0/g7p1/g25p0) — IOCTL interface incompatibility
2. **Binder ABI**: Kernel 6.6 binder ABI is incompatible with Android 14's libbinder (oneway spam handling changed). This causes `servicemanager` and `hwservicemanager` to be zombie. GPU HAL should still load correctly since it communicates via kernel driver, not binder.
3. **Missing bionic g13p0 driver**: The correct userspace driver (g13p0 bionic) has not been found in public repositories. It must be extracted from Rockchip's internal Android SDK.
4. **Panfrost built-in `[permanent]`**: iStoreOS kernel has Panfrost compiled into the kernel image, so a separate `panfrost.ko` module cannot be loaded (name conflict). We work around this with `opp-fix.ko` + binding the built-in driver.
5. **Panfrost OPP conflict**: Mali's OPP pre-configuration leaves corrupted `supported_hw` state. The `opp-fix.ko` module clears this, but the approach requires Mali to be loaded first (chicken-and-egg for initial setup).
6. **CI patch format issue**: The v2 single-hunk patch doesn't apply to vanilla Linux 6.6.127. Needs revert to two-hunk v1 format.
7. **Panfrost Mesa build**: Building Mesa for Android (bionic) with Panfrost Gallium driver is still in progress. The pre-built Mesa from `wode2016501/mesa-for-android-container` is for glibc containers and cannot be used directly in redroid.

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
- [Panfrost — Mesa Docs](https://docs.mesa3d.org/drivers/panfrost.html) — Open-source Mali Bifrost driver
- [Panfrost in mainline Linux](https://gitlab.freedesktop.org/panfrost/linux) — Upstream Panfrost kernel driver
- [wode2016501/mesa-for-android-container](https://github.com/wode2016501/mesa-for-android-container) — Pre-built Mesa for Android containers (Panfrost/Freedreno)
- [lfdevs/mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container) — Upstream Mesa fork with Android container patches
- [iStoreOS kernel source](https://github.com/istoreos/istoreos) (branch `istoreos-24.10`) — Kernel source for building Panfrost module
