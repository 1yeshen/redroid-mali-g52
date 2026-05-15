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

# Copy the entire mali-binaries directory into temp location
COPY mali-binaries/ /tmp/mali-binaries/

# Install Mali GPU drivers - only copy files that exist
RUN set -e; \
    if [ -f /tmp/mali-binaries/vendor/lib64/egl/libGLES_mali.so ]; then \
        echo "[*] Installing Mali GPU userspace driver (64-bit)"; \
        install -D -m 644 /tmp/mali-binaries/vendor/lib64/egl/libGLES_mali.so \
            /vendor/lib64/egl/libGLES_mali.so; \
    fi; \
    if [ -f /tmp/mali-binaries/vendor/lib/egl/libGLES_mali.so ]; then \
        echo "[*] Installing Mali GPU userspace driver (32-bit)"; \
        install -D -m 644 /tmp/mali-binaries/vendor/lib/egl/libGLES_mali.so \
            /vendor/lib/egl/libGLES_mali.so; \
    fi; \
    for f in /tmp/mali-binaries/vendor/lib64/hw/*.so; do \
        if [ -f "$f" ]; then \
            echo "[*] Installing $(basename $f)"; \
            install -D -m 644 "$f" "/vendor/lib64/hw/$(basename $f)"; \
        fi; \
    done; \
    for f in /tmp/mali-binaries/vendor/lib/hw/*.so; do \
        if [ -f "$f" ]; then \
            echo "[*] Installing $(basename $f) (32-bit)"; \
            install -D -m 644 "$f" "/vendor/lib/hw/$(basename $f)"; \
        fi; \
    done; \
    if [ -d /tmp/mali-binaries/vendor/etc ]; then \
        cp -rv /tmp/mali-binaries/vendor/etc/* /vendor/etc/ 2>/dev/null || true; \
    fi; \
    rm -rf /tmp/mali-binaries

# Copy Mali init config files
COPY docker/mali-config/ /tmp/mali-config/
RUN if [ -d /tmp/mali-config ]; then \
        cp -rv /tmp/mali-config/* /vendor/ 2>/dev/null || true; \
        rm -rf /tmp/mali-config; \
    fi

# Set Mali GPU mode
ENV TARGET_BOARD_PLATFORM_GPU=mali-G52
ENV TARGET_RK_GRALLOC_VERSION=4

LABEL description="redroid with Mali-G52 GPU hardware acceleration for RK3568"
LABEL gpu=mali-G52
LABEL soc=rockchip-rk3568

# The init process is inherited from base image (redroid)
# Mali .so files are auto-detected by Android's HAL service manager
