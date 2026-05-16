#!/bin/sh
# ============================================================
# analyze_mali_so.sh - Analyze Mali GPU userspace driver .so
#
# Usage:
#   ./scripts/analyze_mali_so.sh [path/to/libGLES_mali.so]
#
# If no path is given, analyzes all .so files in mali-binaries*/
# ============================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

analyze_one() {
    local so="$1"
    echo ""
    echo "============================================"
    echo " Analyzing: $so"
    echo "============================================"

    # Basic file info
    echo ""
    echo "--- File Info ---"
    file "$so"
    ls -lh "$so" | awk '{print "Size:", $5}'

    # DDK version string
    echo ""
    echo "--- DDK Version ---"
    ddk_ver=$(strings "$so" 2>/dev/null | grep -E "^g[0-9]+p[0-9]" | head -1)
    rk_so=$(strings "$so" 2>/dev/null | grep "rk_so_ver" | head -1)
    release=$(strings "$so" 2>/dev/null | grep "arm_release_ver" | head -1)
    bifrost=$(strings "$so" 2>/dev/null | grep "Bifrost" | head -1)
    echo "DDK:         ${ddk_ver:-NOT FOUND}"
    echo "rk_so_ver:   ${rk_so:-NOT FOUND}"
    echo "Release:     ${release:-NOT FOUND}"
    echo "Arch:        ${bifrost:-NOT FOUND}"

    # ELF information
    echo ""
    echo "--- ELF Info ---"
    if command -v readelf >/dev/null 2>&1; then
        readelf -h "$so" 2>/dev/null | grep -E "(Class|Machine|Entry)"
    else
        echo "(readelf not available)"
    fi

    # Dynamic dependencies
    echo ""
    echo "--- NEEDED Libraries ---"
    if command -v readelf >/dev/null 2>&1; then
        readelf -d "$so" 2>/dev/null | grep "NEEDED" | sed 's/.*\[\(.*\)\]/  \1/'
    else
        echo "(readelf not available)"
    fi

    # Section info
    echo ""
    echo "--- Sections ---"
    if command -v readelf >/dev/null 2>&1; then
        readelf -S "$so" 2>/dev/null | grep -E "\.(dynsym|dynstr|gnu\.version|rodata|text)" | head -10
    fi

    # Symbol counts
    echo ""
    echo "--- Symbol Counts ---"
    if command -v nm >/dev/null 2>&1; then
        total=$(nm -D "$so" 2>/dev/null | wc -l)
        defined=$(nm -D "$so" 2>/dev/null | grep -c " T \| W \| A ")
        undefined=$(nm -D "$so" 2>/dev/null | grep -c " U ")
        echo "Total symbols:     $total"
        echo "Defined (exported): $defined"
        echo "Undefined (imports): $undefined"
    else
        echo "(nm not available)"
    fi

    # EGL/GLES specific strings
    echo ""
    echo "--- EGL/GLES Strings ---"
    strings "$so" 2>/dev/null | grep -E "(EGL_|GL_|GLES|OpenGL|Vulkan|egl|OpenCL)" | sort -u | head -20

    # Build ID
    echo ""
    echo "--- Build ID ---"
    if command -v readelf >/dev/null 2>&1; then
        readelf -n "$so" 2>/dev/null | grep "Build ID" || echo "  (none)"
    fi

    # GPU family strings
    echo ""
    echo "--- GPU Family Strings ---"
    strings "$so" 2>/dev/null | grep -iE "(bifrost|valhall|midgard|utgard|g[0-9]+[pn][0-9])" | sort -u | head -10

    echo ""
    echo "--- Compatibility Assessment ---"
    # Compare with kernel DDK
    kernel_ddk=$(cat /proc/version 2>/dev/null | head -1 || echo "unknown")
    echo "Host kernel: $kernel_ddk"
    echo ""
    echo "NOTE: The kernel DDK (g18p0-01eac0) should be close to the"
    echo "userspace DDK. A difference of more than 3 versions may cause"
    echo "instability. See README.md for the DDK compatibility matrix."
}

# Main
if [ $# -gt 0 ]; then
    for f in "$@"; do
        if [ -f "$f" ]; then
            analyze_one "$f"
        else
            echo "ERROR: File not found: $f"
        fi
    done
else
    # Find all libGLES_mali.so in the project
    SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
    found=0
    for f in "$SCRIPT_DIR"/mali-binaries*/**/libGLES_mali.so; do
        if [ -f "$f" ]; then
            analyze_one "$f"
            found=$((found + 1))
        fi
    done
    # Also check current mali-binaries
    for f in "$SCRIPT_DIR"/mali-binaries/vendor/lib*/egl/libGLES_mali.so; do
        if [ -f "$f" ]; then
            analyze_one "$f"
            found=$((found + 1))
        fi
    done
    if [ $found -eq 0 ]; then
        echo "No libGLES_mali.so found in project."
        echo "Usage: $0 [path/to/libGLES_mali.so]"
    fi
fi
