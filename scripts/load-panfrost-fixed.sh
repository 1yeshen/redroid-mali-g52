#!/bin/sh
# ============================================================
# load-panfrost-fixed.sh
#
# Complete workflow to get patched Panfrost working on
# iStoreOS/RK3568 (EasePi R1).
#
# The built-in panfrost fails because:
#   1. Mali pre-configures GPU OPP via rockchip_opp_select
#   2. After Mali unbind, OPP state is partially corrupted
#   3. Built-in panfrost gets -ENOENT from devm_pm_opp_of_add_table()
#
# This script:
#   1. Loads Mali bifrost driver (configures OPP correctly)
#   2. Unbinds Mali from GPU (leaves partial OPP)
#   3. Loads opp-fix.ko (fixes supported_hw + re-adds OPP entries)
#   4. Binds built-in panfrost (which handles -EBUSY but not -ENOENT)
#   5. Verifies render node
#
# Prerequisites:
#   - bifrost_kbase.ko in /lib/modules/$(uname -r)/
#   - opp-fix.ko in current directory or /tmp/
#   - Kernel built-in panfrost driver with -EBUSY handling
# ============================================================

MODDIR="${1:-/tmp}"
OPP_FIX="${MODDIR}/opp-fix.ko"

error_exit() {
    echo "[ERROR] $1"
    exit 1
}

info() {
    echo "[INFO] $1"
}

# Step 0: Verify prerequisites
info "Step 0: Verifying prerequisites..."

if [ ! -f "${OPP_FIX}" ]; then
    error_exit "opp-fix.ko not found at ${OPP_FIX}"
fi

# Check if bifrost_kbase module is available
MALI_KO="/lib/modules/$(uname -r)/bifrost_kbase.ko"
if [ ! -f "${MALI_KO}" ]; then
    error_exit "bifrost_kbase.ko not found at ${MALI_KO}"
fi

# Check that built-in panfrost handles -EBUSY (partial kernel patch)
info "Checking built-in panfrost..."

# Step 1: Remove any existing Mali module (should not be loaded)
info "Step 1: Removing any existing Mali module..."
rmmod bifrost_kbase 2>/dev/null || true
rmmod mali 2>/dev/null || true

# Step 2: Load Mali bifrost driver to configure GPU OPP
info "Step 2: Loading Mali bifrost driver (configures GPU OPP)..."
insmod "${MALI_KO}" || error_exit "Failed to load bifrost_kbase.ko"
sleep 1

# Verify Mali probed successfully
if [ ! -L "/sys/devices/platform/fde60000.gpu/driver" ]; then
    error_exit "Mali did not bind to GPU device"
fi
info "Mali bound to GPU - OPP configured"

# Verify OPP entries were created
OPP_COUNT=$(find /sys/kernel/debug/opp/platform-fde60000.gpu -name "opp:*" -type d 2>/dev/null | wc -l)
info "GPU OPP entries before unbind: ${OPP_COUNT}"

# Step 3: Unbind Mali from GPU
info "Step 3: Unbinding Mali from GPU..."
echo "fde60000.gpu" > /sys/bus/platform/drivers/mali/unbind 2>/dev/null || \
    error_exit "Failed to unbind Mali from GPU"

# Verify Mali is unbound
if [ -L "/sys/devices/platform/fde60000.gpu/driver" ]; then
    error_exit "Mali still bound to GPU after unbind"
fi
info "Mali unbound from GPU"

OPP_COUNT=$(find /sys/kernel/debug/opp/platform-fde60000.gpu -name "opp:*" -type d 2>/dev/null | wc -l)
info "GPU OPP entries after unbind: ${OPP_COUNT}"

# Step 4: Load opp-fix.ko to fix OPP table
info "Step 4: Loading opp-fix.ko (fixing OPP supported_hw)..."
insmod "${OPP_FIX}" || error_exit "Failed to load opp-fix.ko"
sleep 1

OPP_COUNT=$(find /sys/kernel/debug/opp/platform-fde60000.gpu -name "opp:*" -type d 2>/dev/null | wc -l)
info "GPU OPP entries after fix: ${OPP_COUNT}"

# Step 5: Bind built-in Panfrost to GPU
info "Step 5: Binding Panfrost to GPU..."
echo "fde60000.gpu" > /sys/bus/platform/drivers/panfrost/bind 2>&1
RET=$?
if [ ${RET} -ne 0 ]; then
    info "Panfrost bind returned ${RET}, checking dmesg for details..."
    dmesg | tail -5 | grep -i panfrost
    error_exit "Panfrost bind failed (see dmesg above)"
fi

sleep 1

# Step 6: Verify
info "Step 6: Verifying GPU..."
if [ -L "/sys/devices/platform/fde60000.gpu/driver" ]; then
    DRV=$(readlink "/sys/devices/platform/fde60000.gpu/driver")
    info "GPU bound to: ${DRV}"
fi

if [ -c "/dev/dri/renderD128" ]; then
    info "SUCCESS: /dev/dri/renderD128 exists!"
    ls -la /dev/dri/
else
    info "/dev/dri/renderD128 not found"
    ls -la /dev/dri/ 2>/dev/null || true
fi

# Check dmesg for panfrost messages
echo ""
info "=== Last 10 panfrost messages ==="
dmesg | grep -i panfrost | tail -10

echo ""
info "=== Done ==="
info "If renderD128 exists, GPU is ready for Mesa/Panfrost."
info "If not, check dmesg for errors."
