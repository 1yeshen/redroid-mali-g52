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

set -uo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <firmware_url|firmware_path> <output_dir>"
    exit 1
fi

SRC="$1"
OUTDIR="$2"
WORKDIR=$(mktemp -d)
# Cleanup function that handles read-only mounts gracefully
cleanup() {
    # Unmount any remaining mounts first
    mountpoint -q "$WORKDIR/mnt" 2>/dev/null && sudo umount "$WORKDIR/mnt" 2>/dev/null || true
    mountpoint -q "$WORKDIR/mnt2" 2>/dev/null && sudo umount "$WORKDIR/mnt2" 2>/dev/null || true
    # Then remove workdir (ignore errors for read-only files)
    rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

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
# Step 1.5: Extract from archive (7z/zip) if needed
# -----------------------------------------------------------
# The firmware URL may return a compressed archive (.7z, .zip)
# containing the actual update.img inside. Detect and extract.
extract_from_archive() {
    local fw_path="$1"
    local fw_type
    fw_type=$(file "$fw_path")

    # Check for 7-zip archive
    if echo "$fw_type" | grep -qi "7-zip\|7z"; then
        echo "[*] Detected 7-zip archive, extracting..."
        mkdir -p "$WORKDIR/archive_out"
        7z x "$fw_path" -o"$WORKDIR/archive_out/" -y 2>/dev/null || {
            echo "[!] 7z extraction failed, trying bsdtar..."
            bsdtar xf "$fw_path" -C "$WORKDIR/archive_out/" 2>/dev/null || return 1
        }
        
        # Find the largest .img file recursively
        local img_file
        img_file=$(find "$WORKDIR/archive_out" -name "*.img" -type f -printf "%s\t%p\n" 2>/dev/null | sort -n | tail -1 | cut -f2)
        if [ -n "$img_file" ]; then
            echo "[*] Extracted image: $img_file ($(ls -lh "$img_file" | awk '{print $5}'))"
            cp "$img_file" "$WORKDIR/firmware_extracted.img"
            FIRMWARE_PATH="$WORKDIR/firmware_extracted.img"
            echo "[*] Updated FIRMWARE_PATH to extracted image"
            file "$FIRMWARE_PATH"
            return 0
        else
            echo "[!] No .img file found in 7z archive"
            ls -la "$WORKDIR/archive_out/"
            return 1
        fi
    fi

    # Check for zip archive
    if unzip -l "$fw_path" &>/dev/null; then
        echo "[*] Detected zip archive, extracting..."
        mkdir -p "$WORKDIR/archive_out"
        unzip -o "$fw_path" -d "$WORKDIR/archive_out/" 2>/dev/null || true
        
        local img_file
        img_file=$(find "$WORKDIR/archive_out" -name "*.img" -type f -printf "%s\t%p\n" 2>/dev/null | sort -n | tail -1 | cut -f2)
        if [ -n "$img_file" ]; then
            echo "[*] Extracted image: $img_file ($(ls -lh "$img_file" | awk '{print $5}'))"
            cp "$img_file" "$WORKDIR/firmware_extracted.img"
            FIRMWARE_PATH="$WORKDIR/firmware_extracted.img"
            echo "[*] Updated FIRMWARE_PATH to extracted image"
            file "$FIRMWARE_PATH"
            return 0
        fi
    fi

    return 1
}

# Try to extract from archive. If successful, FIRMWARE_PATH is updated.
extract_from_archive "$FIRMWARE_PATH"

# -----------------------------------------------------------
# Step 1.6: Handle Rockchip RKFW/RKAF unified firmware format
# -----------------------------------------------------------
# RKFW format: starts with "RKFW" magic, contains a boot loader
# and an embedded RKAF (Rockchip Android Firmware) image.
# The RKAF image contains all partitions (system.img, vendor.img, etc.)
unpack_rkfw() {
    local fw_path="$1"
    
    # Check for RKFW magic (first 4 bytes)
    local magic
    magic=$(dd if="$fw_path" bs=4 count=1 2>/dev/null | tr -d '\0')
    
    if [ "$magic" != "RKFW" ]; then
        return 1  # Not RKFW format, skip
    fi

    echo "[*] Detected Rockchip RKFW firmware format!"
    echo "[*] This is a unified firmware wrapper containing an RKAF partition image."

    # Download afptool-rs if needed (check PATH first, then cache)
    local AFPTOOL_BIN=""
    local AFPTOOL_CACHE="/tmp/afptool-rs"
    
    if command -v afptool-rs &>/dev/null; then
        AFPTOOL_BIN=$(command -v afptool-rs)
        echo "[*] Using system afptool-rs: $AFPTOOL_BIN"
    elif [ -x "$AFPTOOL_CACHE" ]; then
        AFPTOOL_BIN="$AFPTOOL_CACHE"
        echo "[*] Using cached afptool-rs: $AFPTOOL_BIN"
    else
        echo "[*] Downloading afptool-rs (Rockchip firmware unpack tool)..."
        local AFPTOOL_URL="https://github.com/suyulin/apftool-rs/releases/download/v1.2.0/afptool-rs-linux-x86_64.zip"
        wget -q --show-progress --timeout=30 -O "$WORKDIR/afptool-rs.zip" "$AFPTOOL_URL" || {
            echo "[!] Failed to download afptool-rs from GitHub"
            echo "[!] Trying fallback URL..."
            curl -sL --connect-timeout 30 -o "$WORKDIR/afptool-rs.zip" "$AFPTOOL_URL" || {
                echo "[!] Cannot download afptool-rs, RKFW unpack will be skipped"
                return 1
            }
        }
        
        echo "[*] Extracting afptool-rs..."
        unzip -o "$WORKDIR/afptool-rs.zip" -d "$WORKDIR/afptool-rs-bin/" 2>/dev/null || {
            echo "[!] Failed to extract afptool-rs.zip"
            ls -la "$WORKDIR/afptool-rs.zip"
            return 1
        }
        
        # Find the binary (might be named afptool-rs or similar)
        AFPTOOL_BIN=$(find "$WORKDIR/afptool-rs-bin" -type f \( -name "afptool-rs" -o -name "afptool-rs*" \) ! -name "*.zip" ! -name "*.md" 2>/dev/null | head -1)
        
        if [ -z "$AFPTOOL_BIN" ]; then
            echo "[!] afptool-rs binary not found in extracted files"
            find "$WORKDIR/afptool-rs-bin" -type f 2>/dev/null | head -20
            return 1
        fi
        
        chmod +x "$AFPTOOL_BIN"
        echo "[*] afptool-rs ready: $AFPTOOL_BIN"
        "$AFPTOOL_BIN" --help 2>&1 | head -5 || true
        
        # Cache for potential reuse
        cp "$AFPTOOL_BIN" "$AFPTOOL_CACHE" 2>/dev/null || true
    fi

    # -----------------------------------------------------------
    # Stage 1: Unpack RKFW wrapper → extract embedded RKAF image
    # -----------------------------------------------------------
    echo ""
    echo "[*] === Stage 1: Unpack RKFW wrapper ==="
    mkdir -p "$WORKDIR/rkfw_out"
    
    "$AFPTOOL_BIN" unpack "$fw_path" "$WORKDIR/rkfw_out" 2>&1
    local rkfw_rc=$?
    
    if [ $rkfw_rc -ne 0 ]; then
        echo "[!] afptool-rs RKFW unpack failed (exit code: $rkfw_rc)"
        ls -la "$WORKDIR/rkfw_out/" 2>/dev/null || true
        return 1
    fi
    
    echo "[*] RKFW unpack output:"
    ls -la "$WORKDIR/rkfw_out/" 2>/dev/null
    
    # Find the embedded RKAF image (usually named embedded-update.img or similar)
    local embedded_img=""
    for f in "$WORKDIR/rkfw_out"/*.img "$WORKDIR/rkfw_out"/*; do
        [ -f "$f" ] || continue
        local f_magic
        f_magic=$(dd if="$f" bs=4 count=1 2>/dev/null | tr -d '\0')
        if [ "$f_magic" = "RKAF" ]; then
            embedded_img="$f"
            echo "[*] Found embedded RKAF image: $f"
            break
        fi
    done
    
    # If no RKAF magic found, try the largest .img file
    if [ -z "$embedded_img" ]; then
        echo "[*] No RKAF signature found, looking for largest .img file..."
        embedded_img=$(find "$WORKDIR/rkfw_out" -name "*.img" -type f -printf "%s\t%p\n" 2>/dev/null | sort -n | tail -1 | cut -f2)
        if [ -n "$embedded_img" ]; then
            echo "[*] Using: $embedded_img ($(ls -lh "$embedded_img" | awk '{print $5}'))"
        fi
    fi
    
    if [ -z "$embedded_img" ]; then
        echo "[!] No embedded RKAF image found in RKFW output"
        return 1
    fi

    # -----------------------------------------------------------
    # Stage 2: Unpack RKAF image → extract all partitions
    # -----------------------------------------------------------
    echo ""
    echo "[*] === Stage 2: Unpack RKAF partition image ==="
    mkdir -p "$WORKDIR/rkaf_out"
    
    "$AFPTOOL_BIN" unpack "$embedded_img" "$WORKDIR/rkaf_out" 2>&1
    local rkaf_rc=$?
    
    if [ $rkaf_rc -ne 0 ]; then
        echo "[!] afptool-rs RKAF unpack failed (exit code: $rkaf_rc)"
        ls -la "$WORKDIR/rkaf_out/" 2>/dev/null || true
        return 1
    fi
    
    echo "[*] RKAF unpack output:"
    ls -la "$WORKDIR/rkaf_out/" 2>/dev/null
    
    # -----------------------------------------------------------
    # Stage 3: Copy partition images to WORKDIR for processing
    # -----------------------------------------------------------
    echo ""
    echo "[*] === Stage 3: Collecting partition images ==="
    
    # Collect from main output directory
    for img in "$WORKDIR/rkaf_out"/*.img; do
        [ -f "$img" ] || continue
        local base=$(basename "$img")
        # Skip partition-metadata and other non-partition files
        echo "[*] Found partition: $base ($(ls -lh "$img" | awk '{print $5}'))"
        cp "$img" "$WORKDIR/$base"
    done
    
    # Also check for Image/ subdirectory (common in RKAF layout)
    if [ -d "$WORKDIR/rkaf_out/Image" ]; then
        echo "[*] Found Image/ subdirectory:"
        ls -la "$WORKDIR/rkaf_out/Image/"
        for img in "$WORKDIR/rkaf_out/Image"/*.img; do
            [ -f "$img" ] || continue
            local base=$(basename "$img")
            if [ ! -f "$WORKDIR/$base" ]; then
                echo "[*] Found partition: Image/$base ($(ls -lh "$img" | awk '{print $5}'))"
                cp "$img" "$WORKDIR/$base"
            fi
        done
    fi
    
    echo ""
    echo "[*] Partition images available for extraction:"
    ls -lh "$WORKDIR/"*.img 2>/dev/null || echo "(none)"
    
    return 0
}

# Call RKFW unpacker
unpack_rkfw "$FIRMWARE_PATH"
RKFW_RC=$?
if [ $RKFW_RC -eq 0 ]; then
    echo "[✓] RKFW firmware unpacked successfully"
fi

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
        # Try with vendor prefix (when mounted as full system)
        src="$mount_point/$path"
        if [ -f "$src" ]; then
            dst="$out/$path"
            mkdir -p "$(dirname "$dst")"
            cp -v "$src" "$dst"
            found=$((found + 1))
            continue
        fi
        
        # Try without vendor prefix (when mounted as vendor partition directly)
        local alt_path="${path#vendor/}"
        src="$mount_point/$alt_path"
        if [ -f "$src" ]; then
            dst="$out/$path"
            mkdir -p "$(dirname "$dst")"
            cp -v "$src" "$dst"
            found=$((found + 1))
        fi
    done

    # Also look for alternative paths (with and without vendor prefix)
    for search_path in "$mount_point/vendor" "$mount_point"; do
        if [ -d "$search_path" ]; then
            for path in $(find "$search_path" \( -name "*mali*" -o -name "*bifrost*" -o -name "*rockchip*gralloc*" -o -name "*hwcomposer*rockchip*" \) 2>/dev/null | head -30); do
                rel_path="${path#$mount_point/}"
                # Reconstruct with vendor/ prefix for consistent output
                if [[ "$rel_path" != vendor/* ]]; then
                    rel_path="vendor/$rel_path"
                fi
                dst="$out/$rel_path"
                mkdir -p "$(dirname "$dst")"
                cp -v "$path" "$dst"
                found=$((found + 1))
            done
        fi
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
    if sudo mount -o loop,ro "$WORKDIR/raw.img" "$WORKDIR/mnt" 2>/dev/null; then
        echo "[*] Mounted successfully as ext4"
        extract_mali_from_mount "$WORKDIR/mnt" "$OUTDIR"
        local count=$?
        sudo umount "$WORKDIR/mnt" 2>/dev/null || true
        return $count
    fi

    # Try as erofs
    if sudo mount -o loop,ro -t erofs "$WORKDIR/raw.img" "$WORKDIR/mnt" 2>/dev/null; then
        echo "[*] Mounted successfully as erofs"
        extract_mali_from_mount "$WORKDIR/mnt" "$OUTDIR"
        local count=$?
        sudo umount "$WORKDIR/mnt" 2>/dev/null || true
        return $count
    fi

    # Try as squashfs
    if sudo mount -o loop,ro -t squashfs "$WORKDIR/raw.img" "$WORKDIR/mnt" 2>/dev/null; then
        echo "[*] Mounted successfully as squashfs"
        extract_mali_from_mount "$WORKDIR/mnt" "$OUTDIR"
        local count=$?
        sudo umount "$WORKDIR/mnt" 2>/dev/null || true
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
# Step 3: Handle GPT disk images (Radxa/Firefly GPT format)
# -----------------------------------------------------------
extract_from_gpt_image() {
    local disk_img="$1"
    echo "[*] Detected GPT disk image: $disk_img"
    
    # Install sfdisk if needed
    command -v sfdisk &>/dev/null || apt-get install -y fdisk 2>/dev/null
    
    # List partitions
    echo "[*] GPT partition table:"
    sfdisk -l "$disk_img" 2>/dev/null | head -30
    
    # Try to extract each partition and look for Mali files
    local partition_num=0
    sfdisk -J "$disk_img" 2>/dev/null | python3 -c "
import sys, json, subprocess, os, tempfile

disk = '$disk_img'
workdir = '$WORKDIR'
outdir = '$OUTDIR'

try:
    data = json.load(sys.stdin)
    parts = data.get('partitiontable', {}).get('partitions', [])
except:
    # Try reading raw sfdisk output
    sys.exit(1)

for i, p in enumerate(parts):
    start = p.get('start', 0)
    size = p.get('size', 0)
    name = p.get('name', '').lower().strip()
    fstype = p.get('type', '')
    
    print(f'Partition {i+1}: name=\"{p.get(\"name\",\"\")}\" start={start} size={size} type={fstype}')
    
    # Check if this might be vendor, system, or super partition
    is_vendor = 'vendor' in name
    is_system = 'system' in name and not is_vendor
    is_super = 'super' in name
    
    if is_vendor or is_system or is_super:
        print(f'  -> Extracting {name} partition...')
        part_img = os.path.join(workdir, f'{name}.img')
        
        # Extract partition using dd
        subprocess.run([
            'dd', f'if={disk}', f'of={part_img}',
            f'skip={start}', f'count={size}',
            'bs=512', 'status=progress'
        ], check=False)
        
        # Try to mount and extract
        mnt = tempfile.mkdtemp(dir=workdir)
        
        mounted = False
        for fstype_attempt in ['ext4', 'erofs', 'squashfs']:
            if fstype_attempt == 'ext4':
                result = subprocess.run(
                    ['sudo', 'mount', '-o', 'loop,ro', part_img, mnt],
                    capture_output=True, text=True, timeout=30
                )
            else:
                result = subprocess.run(
                    ['sudo', 'mount', '-o', 'loop,ro', '-t', fstype_attempt, part_img, mnt],
                    capture_output=True, text=True, timeout=30
                )
            
            if result.returncode == 0:
                mounted = True
                print(f'  -> Mounted as {fstype_attempt}')
                break
        
        if not mounted:
            # Try simg2img first (for sparse images)
            raw_img = os.path.join(workdir, f'{name}_raw.img')
            subprocess.run(['simg2img', part_img, raw_img], capture_output=True, timeout=30)
            if os.path.exists(raw_img):
                for fstype_attempt in ['ext4', 'erofs', 'squashfs']:
                    if fstype_attempt == 'ext4':
                        result = subprocess.run(
                            ['sudo', 'mount', '-o', 'loop,ro', raw_img, mnt],
                            capture_output=True, text=True, timeout=30
                        )
                    else:
                        result = subprocess.run(
                            ['sudo', 'mount', '-o', 'loop,ro', '-t', fstype_attempt, raw_img, mnt],
                            capture_output=True, text=True, timeout=30
                        )
                    if result.returncode == 0:
                        mounted = True
                        print(f'  -> Mounted as {fstype_attempt} (after simg2img)')
                        break
        
        if mounted:
            # Look for Mali files
            mali_dirs = [
                os.path.join(mnt, 'vendor/lib64/egl'),
                os.path.join(mnt, 'vendor/lib64/hw'),
                os.path.join(mnt, 'vendor/etc/gralloc'),
            ]
            
            found_files = []
            for d in mali_dirs:
                if os.path.exists(d):
                    for root, dirs, files in os.walk(d):
                        for f in files:
                            full = os.path.join(root, f)
                            rel = os.path.relpath(full, mnt)
                            # Only copy Mali-related files
                            if any(k in f.lower() for k in ['mali', 'bifrost', 'gralloc', 'hwcomposer', 'rockchip']):
                                dst = os.path.join(outdir, rel)
                                os.makedirs(os.path.dirname(dst), exist_ok=True)
                                subprocess.run(['cp', '-v', full, dst])
                                found_files.append(rel)
            
            # Also search more broadly
            for root, dirs, files in os.walk(mnt):
                for f in files:
                    if any(k in f.lower() for k in ['mali', 'bifrost']):
                        full = os.path.join(root, f)
                        rel = os.path.relpath(full, mnt)
                        dst = os.path.join(outdir, rel)
                        os.makedirs(os.path.dirname(dst), exist_ok=True)
                        subprocess.run(['cp', '-v', full, dst])
                        found_files.append(rel)
            
            if found_files:
                print(f'  -> Found {len(found_files)} Mali-related files')
                for ff in found_files:
                    print(f'      {ff}')
            
            subprocess.run(['sudo', 'umount', mnt], capture_output=True)
        
        os.rmdir(mnt)
    
    # Also check for super.img (logical partitions)
    if 'super' in name:
        print('  -> super partition found, may need lpunpack for logical volumes')
        print(f'  -> Saving super image for later processing')
        part_img = os.path.join(workdir, f'{name}.img')
        subprocess.run([
            'dd', f'if={disk}', f'of={part_img}',
            f'skip={start}', f'count={size}',
            'bs=512', 'status=progress'
        ], check=False)
" 2>&1 || true
    
    # Check if super.img was extracted and needs lpunpack
    if [ -f "$WORKDIR/super.img" ]; then
        echo "[*] Attempting to process super partition with lpunpack (Python)..."
        LPUNPACK="/usr/local/bin/lpunpack.py"
        if [ -f "$LPUNPACK" ]; then
            mkdir -p "$WORKDIR/super_extracted"
            echo "[*] Running: python3 $LPUNPACK $WORKDIR/super.img $WORKDIR/super_extracted/"
            python3 "$LPUNPACK" "$WORKDIR/super.img" "$WORKDIR/super_extracted/" 2>&1 || true
            echo "[*] lpunpack.py result:"
            ls -la "$WORKDIR/super_extracted/" 2>/dev/null || echo "(empty)"
            
            for slot_img in "$WORKDIR/super_extracted"/*.img; do
                [ -f "$slot_img" ] || continue
                echo "[*] Processing $slot_img..."
                extract_from_image "$slot_img"
            done
        else
            echo "[!] lpunpack.py not found, cannot unpack super partition"
        fi
    fi
}

# -----------------------------------------------------------
# Step 4: Handle unified firmware (update.img)
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
        
        # Check if it's a GPT disk image
        if file "$img" | grep -qi "DOS/MBR boot sector\|GPT partition"; then
            extract_from_gpt_image "$img"
        else
            extract_from_image "$img"
        fi
    done
fi

# Search for any .img files recursively
echo "[*] Searching for partition images..."
find "$WORKDIR" -name "*.img" -type f 2>/dev/null | while read -r img; do
    [ "$img" = "$WORKDIR/raw.img" ] && continue
    
    # Check if it's a GPT disk image (hasn't been processed yet)
    if file "$img" | grep -qi "DOS/MBR boot sector\|GPT partition"; then
        # Check if it was already processed from the extracted folder
        if [[ "$img" != *"/extracted/"* ]]; then
            extract_from_gpt_image "$img"
        fi
    else
        extract_from_image "$img"
    fi
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
