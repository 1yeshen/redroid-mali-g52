#!/bin/bash
# ============================================================
# extract-mali-from-firmware.sh
#
# Extract Mali-G52 userspace GPU drivers (Android/bionic) from
# RK3568 Android firmware (update.img or partition images).
#
# Usage: extract-mali-from-firmware.sh <firmware_url|firmware_path> <output_dir>
#
# The script handles:
#   - update.img (Rockchip unified firmware)
#   - Individual partition images (system.img, vendor.img, super.img)
#   - Raw ext4 images
# ============================================================

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <firmware_url|firmware_path> <output_dir>"
    exit 1
fi

SRC="$1"
OUTDIR="$2"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$OUTDIR"
echo "[*] Working directory: $WORKDIR"

# -----------------------------------------------------------
# Step 1: Acquire firmware
# -----------------------------------------------------------
FIRMWARE_PATH=""
if [[ "$SRC" =~ ^https?:// ]]; then
    echo "[*] Downloading firmware from: $SRC"
    wget -q --show-progress --timeout=60 -O "$WORKDIR/firmware.bin" "$SRC" || {
        echo "[!] Direct download failed, trying with curl..."
        curl -sL --connect-timeout 30 -o "$WORKDIR/firmware.bin" "$SRC" || {
            echo "[!] Download failed. Trying fallback..."
            # Try DomainFold accelerated download if available
            if command -v ksget.sh &>/dev/null; then
                ksget.sh -o "$WORKDIR/firmware.bin" "$SRC"
            else
                echo "[ERROR] Cannot download firmware"
                exit 1
            fi
        }
    }
    FIRMWARE_PATH="$WORKDIR/firmware.bin"
else
    FIRMWARE_PATH="$SRC"
fi

echo "[*] Firmware size: $(ls -lh "$FIRMWARE_PATH" | awk '{print $5}')"
file "$FIRMWARE_PATH"

# -----------------------------------------------------------
# Step 2: Identify firmware type and extract
# -----------------------------------------------------------
FW_TYPE=$(file "$FIRMWARE_PATH")

# Function to extract Mali files from a mounted vendor image
extract_mali_from_mount() {
    local mount_point="$1"
    local out="$2"
    local found=0

    # Common Mali Bifrost GPU files for Rockchip
    declare -A MALI_FILES=(
        ["vendor/lib64/egl/libGLES_mali.so"]="Mali GPU userspace driver"
        ["vendor/lib64/hw/android.hardware.graphics.allocator@4.0-impl-bifrost.so"]="Gralloc HAL (Bifrost)"
        ["vendor/lib64/hw/android.hardware.graphics.mapper@4.0-impl-bifrost.so"]="Mapper HAL (Bifrost)"
        ["vendor/lib64/hw/hwcomposer.rockchip.so"]="Hardware Composer"
        ["vendor/etc/gralloc/capabilities.xml"]="Gralloc capabilities"
    )

    for path in "${!MALI_FILES[@]}"; do
        src="$mount_point/$path"
        if [ -f "$src" ]; then
            dst="$out/$path"
            mkdir -p "$(dirname "$dst")"
            cp -v "$src" "$dst"
            found=$((found + 1))
        fi
    done

    # Also look for alternative paths
    for path in $(find "$mount_point/vendor" -name "*mali*" -o -name "*bifrost*" -o -name "*rockchip*gralloc*" 2>/dev/null | head -20); do
        rel_path="${path#$mount_point/}"
        dst="$out/$rel_path"
        mkdir -p "$(dirname "$dst")"
        cp -v "$path" "$dst"
        found=$((found + 1))
    done

    return $found
}

# Try to mount and extract from various image types
extract_from_image() {
    local img_path="$1"
    local img_type
    img_type=$(file "$img_path")

    echo "[*] Analyzing image: $img_type"

    # Try simg2img for Android sparse images
    if echo "$img_type" | grep -qi "sparse\|Android"; then
        echo "[*] Converting sparse image..."
        simg2img "$img_path" "$WORKDIR/raw.img" 2>/dev/null || {
            echo "[!] Not sparse or conversion failed"
            cp "$img_path" "$WORKDIR/raw.img"
        }
    else
        cp "$img_path" "$WORKDIR/raw.img"
    fi

    # Try to mount as ext4
    mkdir -p "$WORKDIR/mnt"
    if mount -o loop,ro "$WORKDIR/raw.img" "$WORKDIR/mnt" 2>/dev/null; then
        echo "[*] Mounted successfully as ext4"
        extract_mali_from_mount "$WORKDIR/mnt" "$OUTDIR"
        local count=$?
        umount "$WORKDIR/mnt" 2>/dev/null || true
        return $count
    fi

    # Try as erofs
    if mount -o loop,ro -t erofs "$WORKDIR/raw.img" "$WORKDIR/mnt" 2>/dev/null; then
        echo "[*] Mounted successfully as erofs"
        extract_mali_from_mount "$WORKDIR/mnt" "$OUTDIR"
        local count=$?
        umount "$WORKDIR/mnt" 2>/dev/null || true
        return $count
    fi

    # Try as squashfs
    if mount -o loop,ro -t squashfs "$WORKDIR/raw.img" "$WORKDIR/mnt" 2>/dev/null; then
        echo "[*] Mounted successfully as squashfs"
        extract_mali_from_mount "$WORKDIR/mnt" "$OUTDIR"
        local count=$?
        umount "$WORKDIR/mnt" 2>/dev/null || true
        return $count
    fi

    return 0
}

# Try directly as partition image
echo "[*] Trying to process as partition image..."
extract_from_image "$FIRMWARE_PATH"
EXTRACT_COUNT=$?

if [ "$EXTRACT_COUNT" -gt 0 ]; then
    echo "[✓] Extracted $EXTRACT_COUNT Mali files directly"
    ls -la "$OUTDIR/vendor/lib64/egl/" 2>/dev/null || true
    exit 0
fi

# -----------------------------------------------------------
# Step 3: Handle unified firmware (update.img)
# Rockchip update.img contains concatenated partitions
# -----------------------------------------------------------
echo "[*] Trying to process as Rockchip update.img..."

# Search for partition images inside the firmware
# Common partition names: system, vendor, super, product
for part in vendor system super product; do
    if [ -f "$WORKDIR/${part}.img" ]; then
        echo "[*] Found ${part}.img in workspace"
        extract_from_image "$WORKDIR/${part}.img"
        if [ $? -gt 0 ]; then
            echo "[✓] Extracted from ${part}.img"
        fi
    fi
done

# Try to find images using unzip (some firmware is zip-archived)
if unzip -l "$FIRMWARE_PATH" &>/dev/null; then
    echo "[*] Firmware is a zip archive, extracting..."
    unzip -o "$FIRMWARE_PATH" -d "$WORKDIR/extracted/" 2>/dev/null || true
    for img in "$WORKDIR/extracted"/*.img; do
        [ -f "$img" ] || continue
        extract_from_image "$img"
    done
fi

# Search for any .img files recursively
echo "[*] Searching for partition images..."
find "$WORKDIR" -name "*.img" -type f 2>/dev/null | while read -r img; do
    [ "$img" = "$WORKDIR/raw.img" ] && continue
    extract_from_image "$img"
done

# -----------------------------------------------------------
# Step 4: Verify results
# -----------------------------------------------------------
echo ""
echo "============================================"
echo "Extraction Results"
echo "============================================"

if [ -f "$OUTDIR/vendor/lib64/egl/libGLES_mali.so" ]; then
    echo "[✓] Mali GPU driver found!"
    ls -lh "$OUTDIR/vendor/lib64/egl/libGLES_mali.so"
    file "$OUTDIR/vendor/lib64/egl/libGLES_mali.so"
else
    echo "[!] Mali GPU driver NOT found!"
    echo "    Expected: vendor/lib64/egl/libGLES_mali.so"
    echo ""
    echo "Files found in $OUTDIR:"
    find "$OUTDIR" -type f 2>/dev/null | sort
fi

if [ -d "$OUTDIR/vendor" ]; then
    echo ""
    echo "Total Mali-related files extracted:"
    find "$OUTDIR" -type f 2>/dev/null | wc -l
    du -sh "$OUTDIR"
fi

echo "============================================"
