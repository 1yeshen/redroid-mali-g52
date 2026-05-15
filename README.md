# redroid-mali-g52

Custom **redroid** (Android in Docker) image with **Mali-G52 GPU hardware acceleration** for Rockchip RK3568 devices (EasePi R1, Radxa ROCK3A/3B, etc.).

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

Once the image is built and pushed:

```bash
# Pull the image
docker pull ghcr.io/1yeshen/redroid-mali-g52:latest

# Run with Mali GPU acceleration
docker run -d --privileged \
  --name redroid-mali \
  -v /dev/mali0:/dev/mali0 \
  -v /dev/rga:/dev/rga \
  -v /dev/dri/card0:/dev/dri/card0 \
  -v /dev/mpp_service:/dev/mpp_service \
  -v /dev/binderfs:/dev/binderfs \
  -v /data/redroid-data:/data \
  -p 5555:5555 \
  ghcr.io/1yeshen/redroid-mali-g52:latest \
  androidboot.redroid_gpu_mode=mali
```

### GPU Verification

```bash
# Inside container, check GPU devices
adb shell ls -la /dev/mali0 /dev/rga /dev/dri/card0

# Check EGL/GLES
adb shell dumpsys | grep -i mali

# Run GLES benchmark
adb shell /system/bin/glmark2-es2 --offscreen
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
│       ├── init.rockchip.gpu.rc # Android init script for Mali GPU
│       └── gralloc/
│           └── capabilities.xml # Gralloc Bifrost configuration
├── README.md
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

### Kernel Device Requirements

| Device | Purpose |
|--------|---------|
| `/dev/mali0` | Mali GPU (major 10, minor 100) |
| `/dev/rga` | Raster Graphics Acceleration |
| `/dev/mpp_service` | Video codec (Media Process Platform) |
| `/dev/dri/card0` | DRM display |

### Known Limitation

Kernel 6.6 binder ABI is incompatible with Android 14's libbinder (oneway spam handling changed). This causes `servicemanager` and `hwservicemanager` to be zombie. The Mali GPU HAL should still load correctly since it communicates via the Mali kernel driver (`/dev/mali0`), not binder. Container stability is not affected.

## References

- [redroid-rockchip/platform_manifests](https://github.com/redroid-rockchip/platform_manifests)
- [remote-android/redroid-doc](https://github.com/remote-android/redroid-doc)
- [tsukumijima/libmali-rockchip](https://github.com/tsukumijima/libmali-rockchip)
- [Radxa ROCK3A Android docs](https://docs.radxa.com/en/rock3/rock3a/other-os/android)
