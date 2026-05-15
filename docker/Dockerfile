# ============================================================
# Dockerfile: Mali-G52 GPU overlay for redroid on RK3568
# ============================================================
# Multi-stage build strategy:
#   Stage 1 (mali-preparer): Use Alpine Linux to arrange Mali
#     binary files into /vendor/ directory structure.
#   Stage 2 (final): Copy /vendor/ from Stage 1 into the
#     redroid base image using COPY --from (no shell needed).
#
# This avoids running any commands inside the redroid image,
# which may not have a working /bin/sh (Android minimal base).
#
# Usage:
#   docker buildx build --platform linux/arm64 \
#     --build-arg REDROID_BASE=redroid/redroid:14.0.0-latest \
#     -t redroid-mali-g52 -f docker/Dockerfile .
#
# The mali-binaries/ directory must exist in the build context
# (containing vendor/lib64/egl/libGLES_mali.so etc.)
# ============================================================

# ARG must be declared at the top level (before any FROM) to be
# available to all stages via --build-arg or default value.
ARG REDROID_BASE=redroid/redroid:14.0.0-latest

# -----------------------------------------------------------
# Stage 1: Arrange Mali files using a standard Linux image
# -----------------------------------------------------------
FROM alpine:latest AS mali-preparer

# Copy Mali source binaries and config files
COPY mali-binaries/ /mali-src/
COPY docker/mali-config/ /mali-config/

# Create the /vendor directory structure with all Mali files
RUN set -e; \
    echo "[*] Preparing Mali GPU driver files..."; \
    \
    # Copy vendor files preserving directory structure \
    if [ -d /mali-src/vendor ]; then \
        cp -rv /mali-src/vendor/* /vendor/ 2>/dev/null || true; \
    fi; \
    \
    # Copy config overlay files \
    if [ -d /mali-config ]; then \
        cp -rv /mali-config/* /vendor/ 2>/dev/null || true; \
    fi; \
    \
    # Show what was prepared \
    echo "[*] Files in /vendor/:"; \
    find /vendor -type f -exec ls -lh {} \; 2>/dev/null | head -20; \
    echo "[✓] Mali files prepared successfully"

# -----------------------------------------------------------
# Stage 2: Final redroid image with Mali drivers
# -----------------------------------------------------------
FROM $REDROID_BASE

# Copy pre-arranged Mali files from Stage 1 (no shell needed in this image)
COPY --from=mali-preparer /vendor/ /vendor/

# Set Mali GPU mode
ENV TARGET_BOARD_PLATFORM_GPU=mali-G52
ENV TARGET_RK_GRALLOC_VERSION=4

LABEL description="redroid with Mali-G52 GPU hardware acceleration for RK3568"
LABEL gpu=mali-G52
LABEL soc=rockchip-rk3568

# The init process is inherited from base image (redroid)
# Mali .so files are auto-detected by Android's HAL service manager
