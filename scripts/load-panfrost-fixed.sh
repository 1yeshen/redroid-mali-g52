#!/bin/sh
# ============================================================
# load-panfrost-fixed.sh
#
# Complete workflow to get patched Panfrost working on
# iStoreOS/RK3568 (EasePi R1).
#
# Background:
#   - iStoreOS 24.10.6 does NOT have Panfrost built into the kernel
#   - Panfrost can be loaded as a standalone module (panfrost.ko)
#   - Mali bifrost driver pre-configures GPU OPP via rockchip_opp_select
#     which can corrupt OPP state when Mali is unbound
#   - The patched panfrost.ko handles all OPP failure paths (-EBUSY,
#     -EEXIST, -ENOENT, devfreq_recommended_opp failures)
#
# This script (opp-fix fallback method):
#   1. Loads Mali bifrost driver (configures OPP correctly)
#   2. Unbinds Mali from GPU (leaves partial OPP corruption)
#   3. Loads opp-fix.ko (fixes supported_hw + re-adds OPP entries)
#   4. Loads patched panfrost.ko (handles all OPP failure paths)
#   5. Verifies render node
#
# For the clean method (recommended):
#   Just load DRM modules directly after reboot with Mali disabled:
#     insmod drm.ko && insmod gpu-sched.ko && insmod drm_shmem_helper.ko && insmod panfrost.ko
#
# Prerequisites:
#   - bifrost_kbase.ko in /lib/modules/$(uname -r)/
#   - opp-fix.ko in MODDIR (default: /tmp/)
#   - panfrost.ko with OPP patch in MODDIR (default: /tmp/)
#   - drm.ko, gpu-sched.ko, drm_shmem_helper.ko in MODDIR
# ============================================================

MODDIR="${1:-/tmp}"
OPP_FIX="${MODDIR}/opp-fix.ko"
PANFROST_KO="${MODDIR}/panfrost.ko"
DRM_KO="${MODDIR}/drm.ko"
GPU_SCHED_KO="${MODDIR}/gpu-sched.ko"
DRM_SHMEM_KO="${MODDIR}/drm_shmem_helper.ko"

error_exit() {
    echo "[ERROR] $1"
    exit 1
}

info() {
    echo "[INFO] $1"
}

# Step 0: Verify prerequisites
info "Step 0: Verifying prerequisites..."

# Check if panfrost.ko is available (with OPP patch)
if [ ! -f "${PANFROST_KO}" ]; then
    error_exit "panfrost.ko not found at ${PANFROST_KO}"
fi

if [ ! -f "${OPP_FIX}" ]; then
    info "opp-fix.ko not found at ${OPP_FIX} — will skip opp-fix step"
    OPP_FIX=""
fi

# Check DRM dependency modules
for mod in "${DRM_KO}" "${GPU_SCHED_KO}" "${DRM_SHMEM_KO}"; do
    if [ ! -f "$mod" ]; then
        info "Warning: $mod not found — will check if already loaded"
    fi
done

# Check if bifrost_kbase module is available
MALI_KO="/lib/modules/$(uname -r)/bifrost_kbase.ko"
if [ ! -f "${MALI_KO}" ]; then
    info "bifrost_kbase.ko not found, checking for mali.ko..."
    MALI_KO="/lib/modules/$(uname -r)/mali.ko"
    if [ ! -f "${MALI_KO}" ]; then
        info "No Mali module found — proceeding with direct Panfrost load"
        MALI_KO=""
    fi
fi

# Step 1: Remove any existing Mali module
info "Step 1: Removing any existing Mali module..."
rmmod bifrost_kbase 2>/dev/null || true
rmmod mali 2>/dev/null || true

# Step 2: Load DRM dependency modules (if not already loaded)
info "Step 2: Loading DRM dependency modules..."
for modname in drm gpu_sched drm_shmem_helper; do
    if ! lsmod | grep -q "^${modname} "; then
        modpath="${MODDIR}/${modname}.ko"
        if [ -f "$modpath" ]; then
            insmod "$modpath" || info "Warning: could not load $modpath"
        fi
    fi
done

# Step 3: Load opp-fix.ko to clean OPP table (if available and if Mali was loaded)
if [ -n "${MALI_KO}" ] && [ -f "${MALI_KO}" ]; then
    info "Step 3a: Loading Mali to configure OPP..."
    insmod "${MALI_KO}" 2>/dev/null || info "Mali load skipped (may already be configured)"

    # Unbind Mali from GPU
    info "Step 3b: Unbinding Mali from GPU..."
    echo "fde60000.gpu" > /sys/bus/platform/drivers/mali/unbind 2>/dev/null || \
        info "Mali unbind skipped or already unbound"
fi

if [ -n "${OPP_FIX}" ]; then
    info "Step 3c: Loading opp-fix.ko (fixing OPP supported_hw)..."
    insmod "${OPP_FIX}" 2>/dev/null || info "opp-fix load skipped (already loaded)"
    sleep 1

    OPP_COUNT=$(find /sys/kernel/debug/opp/platform-fde60000.gpu -name "opp:*" -type d 2>/dev/null | wc -l)
    info "GPU OPP entries after fix: ${OPP_COUNT}"
fi

# Step 4: Load patched Panfrost module
info "Step 4: Loading patched Panfrost module..."
insmod "${PANFROST_KO}" 2>/dev/null || error_exit "Failed to load panfrost.ko"
sleep 1

# Step 5: Verify
info "Step 5: Verifying GPU..."
if [ -c "/dev/dri/renderD128" ]; then
    info "SUCCESS: /dev/dri/renderD128 exists!"
    ls -la /dev/dri/
else
    info "/dev/dri/renderD128 not found"
    ls -la /dev/dri/ 2>/dev/null || true
    info "Checking dmesg for errors..."
    dmesg | grep -i panfrost | tail -10
fi

# Check dmesg for panfrost messages
echo ""
info "=== Last 10 panfrost messages ==="
dmesg | grep -i panfrost | tail -10

echo ""
info "=== Done ==="
info "If renderD128 exists, GPU is ready for Mesa/Panfrost."
info "If not, check dmesg for errors."
