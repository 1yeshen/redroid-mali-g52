# ============================================================
# Dockerfile: Mali-G52 GPU overlay for redroid on RK3568
# ============================================================
# Usage:
#   docker build -t redroid-mali-g52 \
#     --build-arg REDROID_BASE=redroid/redroid:14.0.0_64only-latest \
#     -f docker/Dockerfile .
#
# The mali-binaries/ directory must exist in the build context
# (containing vendor/lib64/egl/libGLES_mali.so etc.)
# ============================================================

ARG REDROID_BASE=redroid/redroid:14.0.0_64only-latest
FROM $REDROID_BASE

# Copy Mali GPU userspace drivers from build context
# These were pre-extracted from RK3568 Android firmware in CI
COPY mali-binaries/vendor/lib64/egl/libGLES_mali.so \
    /vendor/lib64/egl/libGLES_mali.so
COPY mali-binaries/vendor/lib64/hw/android.hardware.graphics.allocator@4.0-impl-bifrost.so \
    /vendor/lib64/hw/android.hardware.graphics.allocator@4.0-impl-bifrost.so
COPY mali-binaries/vendor/lib64/hw/android.hardware.graphics.mapper@4.0-impl-bifrost.so \
    /vendor/lib64/hw/android.hardware.graphics.mapper@4.0-impl-bifrost.so
COPY mali-binaries/vendor/lib64/hw/hwcomposer.rockchip.so \
    /vendor/lib64/hw/hwcomposer.rockchip.so
COPY mali-binaries/vendor/etc/gralloc/capabilities.xml \
    /vendor/etc/gralloc/capabilities.xml

# Copy Mali HAL init config
COPY docker/mali-config/ /vendor/

# Set proper permissions
RUN chmod 644 /vendor/lib64/egl/libGLES_mali.so && \
    chmod 644 /vendor/lib64/hw/*.so 2>/dev/null || true

# Set Mali GPU mode - redroid detects libGLES_mali.so at runtime
ENV TARGET_BOARD_PLATFORM_GPU=mali-G52
ENV TARGET_RK_GRALLOC_VERSION=4

LABEL description="redroid with Mali-G52 GPU hardware acceleration for RK3568"
LABEL gpu=mali-G52
LABEL soc=rockchip-rk3568

# The init process is inherited from base image (redroid)
# Mali .so files are auto-detected by Android's HAL service manager
