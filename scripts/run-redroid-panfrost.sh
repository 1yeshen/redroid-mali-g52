#!/bin/sh
# ============================================================
# run-redroid-panfrost.sh
#
# Run standard redroid:14.0.0_64only-latest with Panfrost GPU
# acceleration on RK3568 (EasePi R1).
#
# Key points:
#   1. Uses --device (NOT -v /dev:/dev) to avoid SIGBUS crash
#      from Android property system collisions
#   2. vendor_redroid's gpu_config.sh auto-detects Panfrost
#      via /sys/kernel/debug/dri/*/name, so gpu_mode=host
#      is sufficient
#   3. Binder nodes are mounted via --device from binderfs
#   4. No custom Docker image needed - works with the standard
#      redroid/redroid:14.0.0_64only-latest image
# ============================================================
set -e

# ---- Configuration ----
REDROID_IMAGE="${REDROID_IMAGE:-redroid/redroid:14.0.0_64only-latest}"
CONTAINER_NAME="${CONTAINER_NAME:-redroid-panfrost}"
DATA_DIR="${DATA_DIR:-/data/redroid-panfrost}"
ADB_PORT="${ADB_PORT:-5555}"

# ---- GPU & Hardware Devices ----
# Panfrost render node (Mali-G52 on RK3568)
DRM_DEVICES="--device /dev/dri/renderD128:/dev/dri/renderD128"
DRM_DEVICES="${DRM_DEVICES} --device /dev/dri/card0:/dev/dri/card0"

# Binder nodes (binderfs on iStoreOS, mounted at /dev/binderfs/)
BINDER_DEVICES="--device /dev/binderfs/binder:/dev/binder"
BINDER_DEVICES="${BINDER_DEVICES} --device /dev/binderfs/hwbinder:/dev/hwbinder"
BINDER_DEVICES="${BINDER_DEVICES} --device /dev/binderfs/vndbinder:/dev/vndbinder"

# Media/display hardware
MEDIA_DEVICES="--device /dev/rga:/dev/rga"
MEDIA_DEVICES="${MEDIA_DEVICES} --device /dev/mpp_service:/dev/mpp_service"
MEDIA_DEVICES="${MEDIA_DEVICES} --device /dev/dri/card1:/dev/dri/card1"

# ---- Pre-flight Checks ----
echo "============================================"
echo "  redroid Panfrost Launcher (RK3568)"
echo "============================================"
echo ""

# Check Panfrost render node
if [ ! -e /dev/dri/renderD128 ]; then
    echo "[!] WARNING: /dev/dri/renderD128 not found!"
    echo "    Panfrost kernel module may not be loaded."
    echo "    Run: lsmod | grep panfrost"
    echo "    Or check: ls -la /dev/dri/"
    echo ""
    echo "    To load Panfrost:"
    echo "      insmod /path/to/panfrost.ko"
    echo "      insmod /path/to/drm.ko"
    echo "      insmod /path/to/drm_shmem_helper.ko"
    echo "      insmod /path/to/gpu-sched.ko"
    echo ""
    echo "[!] Continuing anyway (may fall back to software rendering)..."
fi

# Check binder nodes
for node in /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder; do
    if [ ! -e "$node" ]; then
        echo "[!] WARNING: $node not found!"
        echo "    binderfs may not be mounted."
        echo "    Run: mount | grep binder"
    fi
done

# Check Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "[!] ERROR: docker command not found!"
    exit 1
fi

# Pull image if not present
echo "[*] Checking image: ${REDROID_IMAGE}..."
if ! docker image inspect "${REDROID_IMAGE}" >/dev/null 2>&1; then
    echo "[*] Pulling ${REDROID_IMAGE}..."
    docker pull "${REDROID_IMAGE}"
fi

# Remove existing container if present
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "[*] Removing existing container '${CONTAINER_NAME}'..."
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1
fi

# Create data directory
mkdir -p "${DATA_DIR}"

# ---- Launch Container ----
echo "[*] Launching redroid container..."
echo "    Image:      ${REDROID_IMAGE}"
echo "    Container:  ${CONTAINER_NAME}"
echo "    Data dir:   ${DATA_DIR}"
echo "    ADB port:   ${ADB_PORT}"
echo ""

# CRITICAL: Use --device (NOT -v /dev:/dev) to avoid SIGBUS
# See: https://github.com/remote-android/redroid-doc/issues/228
#
# gpu_config.sh (from vendor_redroid) auto-detects Panfrost
# when gpu_mode=host:
#   1. Scans /sys/kernel/debug/dri/*/name
#   2. Finds "panfrost" driver
#   3. Sets gralloc.gbm.device = /dev/dri/renderD128
#   4. Sets ro.hardware.vulkan = panfrost
#   5. Sets ro.hardware.egl = mesa
#   6. Sets ro.hardware.gralloc = gbm
echo "[*] Running: docker run -d --privileged --name ${CONTAINER_NAME} ..."
# Note: inline # comments inside multi-line docker run will be passed as args.
# All explanations are above.
set -x
docker run -d \
    --privileged \
    --name "${CONTAINER_NAME}" \
    --pull never \
    \
    ${DRM_DEVICES} \
    \
    ${BINDER_DEVICES} \
    \
    ${MEDIA_DEVICES} \
    \
    --device /dev/dma_heap:/dev/dma_heap \
    \
    --device /dev/ashmem:/dev/ashmem \
    \
    --device /dev/ion:/dev/ion \
    \
    -v "${DATA_DIR}:/data" \
    \
    -p "${ADB_PORT}:5555" \
    \
    androidboot.redroid_gpu_mode=host \
    \
    androidboot.use_memfd=true \
    \
    androidboot.redroid_dpi=320 \
    \
    androidboot.redroid_width=720 \
    androidboot.redroid_height=1280 \
    \
    "${REDROID_IMAGE}"

set +x

# ---- Post-launch Checks ----
echo ""
echo "============================================"
echo "  Container launched!"
echo "============================================"
echo ""
echo "Check status:"
echo "  docker ps -a --filter name=${CONTAINER_NAME}"
echo ""
echo "Follow boot log:"
echo "  docker logs -f ${CONTAINER_NAME}"
echo ""
echo "Connect via ADB:"
echo "  adb connect localhost:${ADB_PORT}"
echo ""
echo "Verify GPU inside container:"
echo "  adb shell dumpsys SurfaceFlinger | grep GLES"
echo "  adb shell getprop | grep -E '(egl|gralloc|vulkan|gpu)'"
echo "  adb shell ls -la /dev/dri/"
echo ""
echo "Stop container:"
echo "  docker stop ${CONTAINER_NAME}"
echo ""

# Quick status
docker ps --filter name="${CONTAINER_NAME}" --format "Container {{.Names}} is {{.Status}}"
