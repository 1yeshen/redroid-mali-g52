# redroid-mali-g52

Custom **redroid** (Android in Docker) image with **Mali-G52 GPU hardware acceleration** for Rockchip RK3568 devices (EasePi R1, Radxa ROCK3A/3B, etc.).

## Status

| Component | Status | Notes |
|-----------|--------|-------|
| Container boot (old base) | ✅ | Pinned to SHA `c898abca51e6` |
| Mali /dev/mali0 detection | ✅ | Device mapped into container |
| Mali userspace driver load | ✅ | g25p0 DDK loaded correctly |
| SurfaceFlinger GPU init | ❌ | DDK mismatch: kernel g18p0 vs userspace g25p0/g7p1 |
| Hardware acceleration | ❌ | Pending matching DDK userspace driver |

**Root cause:** The kernel's Mali Bifrost module (`bifrost_kbase.ko`) is compiled at DDK **g18p0-01eac0** (r46p0), but all available Android (bionic) userspace Mali drivers are at different DDK versions. Userspace must use a compatible DDK version matching the kernel module.

### DDK Compatibility Matrix

| Userspace DDK | Source | rk_so_ver | Kernel g18p0 Result |
|---------------|--------|-----------|---------------------|
| g2p0-01eac0 | Old RK3566 firmware | 8 | ❌ SIGSEGV in `eglCreateImageKHR` |
| g7p1-01bet0 | Stock RK3568 firmware | 8 | ❌ SIGSEGV in `eglCreateImageKHR` |
| g13p0-01eac0 | libmali-rockchip (glibc) | 11 | ❌ glibc incompatible with Android bionic |
| **g25p0-00eac0** | FriendlyElec Android14 SDK rkr8 | 10 | ❌ Exit 129 (SIGHUP) during init |
| **g18p0 (needed)** | Not found yet | ? | ✅ Should match kernel module |

## Background

On iStoreOS (OpenWrt 24.10, kernel 6.6.127) running on EasePi R1 (RK3568):

- **Stock redroid:14.0.0_64only-latest** runs stably with software rendering (`gpu_mode=guest`)
- But `servicemanager` is zombie due to kernel 6.6 binder ABI incompatibility (container still works for basic tasks)
- **/dev/mali0** exists on the host but is not utilized inside the container
- This repo builds a custom image with the Mali-G52 userspace driver

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    GitHub Actions CI                      │
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

## Local Usage (on EasePi R1)

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

### Run

```bash
# Run with Mali GPU acceleration
docker run -d --privileged \
  --name redroid-mali \
  --device /dev/mali0:/dev/mali0 \
  --device /dev/rga:/dev/rga \
  --device /dev/dri:/dev/dri \
  -v /dev:/dev \
  -p 5555:5555 \
  redroid-mali-g52:latest \
  androidboot.redroid_gpu_mode=mali
```

**Important:** Current Mali userspace drivers (g2p0/g7p1) will boot but SurfaceFlinger crashes due to DDK mismatch with kernel module (g18p0). See [Status](#status) for details.

### GPU Verification

```bash
# Inside container, check GPU devices
adb shell ls -la /dev/mali0 /dev/rga /dev/dri/card0

# Check logcat for Mali/GPU errors
adb shell logcat -d -s SurfaceFlinger

# Check tombstones for GPU crashes
adb shell ls /data/tombstones/
```

## Project Structure

```
redroid-mali-g52/
├── .github/workflows/
│   ├── build-mali-overlay.yml   # Firmware extraction + overlay build (free runner)
│   └── build-aosp-full.yml      # Full AOSP build (paid runner)
├── scripts/
│   └── extract-mali-from-firmware.sh  # Mali driver extraction script
├── docker/
│   ├── Dockerfile               # Multi-stage Docker build
│   └── mali-config/
│       ├── bin/gpu_config.sh    # Mali GPU configuration script
│       ├── etc/init/init.mali_gpu.rc  # Mali GPU init script
│       ├── etc/init/init.rockchip.gpu.rc  # Rockchip GPU init
│       └── etc/gralloc/capabilities.xml # Gralloc Bifrost configuration
├── mali-binaries/
│   └── vendor/
│       ├── lib/egl/libGLES_mali.so          # 32-bit Mali driver
│       ├── lib64/egl/libGLES_mali.so        # 64-bit Mali driver
│       └── lib64/hw/
│           ├── android.hardware.graphics.allocator@4.0-impl-bifrost.so
│           └── android.hardware.graphics.mapper@4.0-impl-bifrost.so
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
| `libGLES_mali.so` | Mali GPU userspace driver (EGL/GLES/Vulkan) |
| `android.hardware.graphics.allocator@4.0-impl-bifrost.so` | Gralloc buffer allocation (Bifrost) |
| `android.hardware.graphics.mapper@4.0-impl-bifrost.so` | Gralloc buffer mapping (Bifrost) |
| `hwcomposer.rockchip.so` | Rockchip hardware composer |
| `capabilities.xml` | Gralloc capabilities config |

### DDK Version Investigation

The Mali Bifrost DDK follows the naming pattern `gXXpY`:
- `g` = generation, `p` = patch
- Higher number = newer DDK
- Bifrost architecture spans `g2p0` through `g25p0`+

Key findings:
1. **Kernel module** (bifrost_kbase.ko): `g18p0-01eac0` (~r46p0, Rockchip kernel 6.6)
2. **g7p1 bionic driver**: From stock RK3568 firmware, DDK too old for kernel
3. **g13p0 glibc driver**: From libmali-rockchip, correct DDK era but incompatible (glibc vs bionic)
4. **g25p0 bionic driver**: From FriendlyElec Android 14 SDK rkr8, newer than kernel DDK, causes init crash
5. **Need**: bionic Mali userspace driver at DDK g13p0-g18p0 range

### Kernel Device Requirements

| Device | Purpose |
|--------|---------|
| `/dev/mali0` | Mali GPU (major 10, minor 258) |
| `/dev/rga` | Raster Graphics Acceleration |
| `/dev/mpp_service` | Video codec (Media Process Platform) |
| `/dev/dri/card0` | DRM display |

### Known Limitation

Kernel 6.6 binder ABI is incompatible with Android 14's libbinder (oneway spam handling changed). This causes `servicemanager` and `hwservicemanager` to be zombie. The Mali GPU HAL should still load correctly since it communicates via the Mali kernel driver (`/dev/mali0`), not binder. Container stability is not affected.

## References

- [redroid-rockchip/platform_manifests](https://github.com/redroid-rockchip/platform_manifests)
- [remote-android/redroid-doc](https://github.com/remote-android/redroid-doc)
- [tsukumijima/libmali-rockchip](https://github.com/tsukumijima/libmali-rockchip)
- [FriendlyElec rk35xx-android14](http://112.124.9.243:3000/friendlyelec/rk35xx-android14)
- [Radxa ROCK3A Android docs](https://docs.radxa.com/en/rock3/rock3a/other-os/android)
- [Rockchip Linux Graphics](https://opensource.rock-chips.com/wiki_Graphics)
