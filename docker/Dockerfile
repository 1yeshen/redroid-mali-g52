# ============================================================
# Dockerfile: Mali-G52 GPU overlay for redroid on RK3568
# ============================================================
# Strategy: Extract Mali userspace drivers (bionic) from
# RK3568 Android firmware and overlay them onto stock redroid.
# ============================================================

ARG REDROID_BASE=redroid/redroid:14.0.0_64only-latest
FROM $REDROID_BASE AS base

# -----------------------------------------------------------
# Stage: mali-extract (runs only when FIRMWARE_URL is set)
# -----------------------------------------------------------
FROM ubuntu:22.04 AS mali-extract

ARG FIRMWARE_URL=""
ARG MALI_BINARIES_DIR=""

# If MALI_BINARIES_DIR is provided, skip extraction
RUN if [ -n "$MALI_BINARIES_DIR" ] && [ -d "$MALI_BINARIES_DIR" ]; then \
        echo "Using pre-extracted Mali binaries from $MALI_BINARIES_DIR"; \
    elif [ -z "$FIRMWARE_URL" ]; then \
        echo "ERROR: Neither FIRMWARE_URL nor MALI_BINARIES_DIR provided"; \
        exit 1; \
    fi

# Install extraction tools (only if FIRMWARE_URL is set)
RUN if [ -n "$FIRMWARE_URL" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            wget unzip simg2img e2tools file \
            xz-utils \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# Copy extraction script
COPY scripts/extract-mali-from-firmware.sh /tmp/
RUN chmod +x /tmp/extract-mali-from-firmware.sh

# Run extraction (only if FIRMWARE_URL is set)
RUN if [ -n "$FIRMWARE_URL" ]; then \
        mkdir -p /output/mali && \
        /tmp/extract-mali-from-firmware.sh "$FIRMWARE_URL" /output/mali; \
    fi

# Copy pre-extracted binaries if provided
RUN if [ -n "$MALI_BINARIES_DIR" ] && [ -d "$MALI_BINARIES_DIR" ]; then \
        mkdir -p /output/mali && \
        cp -rv "$MALI_BINARIES_DIR"/* /output/mali/; \
    fi

# -----------------------------------------------------------
# Stage: final - Mali overlay on redroid
# -----------------------------------------------------------
FROM base AS final

# Copy Mali GPU userspace drivers from extraction stage
COPY --from=mali-extract /output/mali/vendor/lib64/egl/libGLES_mali.so \
    /vendor/lib64/egl/libGLES_mali.so
COPY --from=mali-extract /output/mali/vendor/lib64/hw/android.hardware.graphics.allocator@4.0-impl-bifrost.so \
    /vendor/lib64/hw/android.hardware.graphics.allocator@4.0-impl-bifrost.so 2>/dev/null || true
COPY --from=mali-extract /output/mali/vendor/lib64/hw/android.hardware.graphics.mapper@4.0-impl-bifrost.so \
    /vendor/lib64/hw/android.hardware.graphics.mapper@4.0-impl-bifrost.so 2>/dev/null || true
COPY --from=mali-extract /output/mali/vendor/lib64/hw/hwcomposer.rockchip.so \
    /vendor/lib64/hw/hwcomposer.rockchip.so 2>/dev/null || true
COPY --from=mali-extract /output/mali/vendor/etc/gralloc/capabilities.xml \
    /vendor/etc/gralloc/capabilities.xml 2>/dev/null || true

# Copy Mali config files
COPY docker/mali-config/ /tmp/mali-config/
RUN if [ -d /tmp/mali-config ]; then \
        cp -rv /tmp/mali-config/* /vendor/ 2>/dev/null || true; \
    fi && rm -rf /tmp/mali-config

# Set proper permissions
RUN chmod 644 /vendor/lib64/egl/libGLES_mali.so && \
    chmod 644 /vendor/lib64/hw/*.so 2>/dev/null || true

# Set Mali GPU mode - redroid will detect libGLES_mali.so
ENV TARGET_BOARD_PLATFORM_GPU=mali-G52
ENV TARGET_RK_GRALLOC_VERSION=4

# Add Mali GPU device nodes mapping hint
# These should be mapped at runtime: /dev/mali0, /dev/rga, /dev/mpp_service, /dev/dri/card0

LABEL description="redroid with Mali-G52 GPU hardware acceleration for RK3568"
LABEL gpu=mali-G52
LABEL soc=rockchip-rk3568
LABEL build_date="${BUILD_DATE}"

# The init process is inherited from base image (redroid)
# No custom ENTRYPOINT needed - the Mali .so files are picked up
# by Android's HAL service manager at boot time.
