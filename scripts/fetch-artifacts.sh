#!/bin/sh
# ============================================================
# fetch-artifacts.sh
#
# Download the latest Panfrost kernel module artifacts from
# GitHub Actions and install them on the EasePi R1.
#
# Usage:
#   sh scripts/fetch-artifacts.sh         # download + install
#   sh scripts/fetch-artifacts.sh --check  # check versions only
# ============================================================
set -e

GITHUB_REPO="1yeshen/redroid-mali-g52"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# ---- Colors ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo "${CYAN}[*]${NC} $1"; }
ok()   { echo "${GREEN}[✓]${NC} $1"; }
warn() { echo "${YELLOW}[!]${NC} $1"; }
err()  { echo "${RED}[✗]${NC} $1"; }

# ---- Pre-flight ----
if [ "$1" = "--check" ]; then
    echo ""
    echo "============================================"
    echo "  EasePi R1 - Panfrost Readiness Check"
    echo "============================================"
    echo ""
    echo "--- System ---"
    cat /etc/openwrt_release 2>/dev/null || cat /etc/os-release 2>/dev/null || uname -a
    echo ""
    echo "--- Kernel ---"
    uname -r
    echo ""
    echo "--- Docker ---"
    docker --version 2>/dev/null || echo "Docker not installed"
    echo ""
    echo "--- GPU Status ---"
    ls -la /dev/dri/ 2>/dev/null || echo "No /dev/dri/ (module not loaded)"
    echo ""
    lsmod 2>/dev/null | grep -E "panfrost|drm" || echo "No panfrost/drm modules loaded"
    echo ""
    echo "--- Binder ---"
    ls -la /dev/binderfs/ 2>/dev/null || echo "No binderfs"
    echo ""
    echo "--- Disk ---"
    df -h / /data /overlay 2>/dev/null
    exit 0
fi

# Detect workspace: prefer the repo root, fallback to script location
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "============================================"
echo "  Fetch Panfrost Kernel Modules"
echo "============================================"
echo ""

# ---- Step 1: Get the latest successful build run ----
info "Finding latest successful Panfrost Kernel Module build..."
if [ -n "$GITHUB_TOKEN" ]; then
    AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
else
    AUTH_HEADER=""
    warn "No GITHUB_TOKEN set. Using unauthenticated request (rate limited)."
    warn "Set GITHUB_TOKEN for reliable access."
fi

if [ -n "$AUTH_HEADER" ]; then
    API_RESPONSE=$(curl -s -H "$AUTH_HEADER" \
      "https://api.github.com/repos/$GITHUB_REPO/actions/workflows/build-panfrost-module.yml/runs?per_page=1&status=completed&branch=main")
else
    API_RESPONSE=$(curl -s \
      "https://api.github.com/repos/$GITHUB_REPO/actions/workflows/build-panfrost-module.yml/runs?per_page=1&status=completed&branch=main")
fi

RUN_ID=$(echo "$API_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
runs = data.get('workflow_runs', [])
for r in runs:
    if r.get('conclusion') == 'success':
        print(r['id'])
        break
" 2>/dev/null)

if [ -z "$RUN_ID" ]; then
    err "Could not find a successful build run!"
    err "Check: https://github.com/$GITHUB_REPO/actions/workflows/build-panfrost-module.yml"
    exit 1
fi
ok "Found build run #$RUN_ID"

# ---- Step 2: Get artifact download URL ----
info "Fetching artifact info..."
if [ -n "$AUTH_HEADER" ]; then
    ARTIFACTS=$(curl -s -H "$AUTH_HEADER" \
      "https://api.github.com/repos/$GITHUB_REPO/actions/runs/$RUN_ID/artifacts")
else
    ARTIFACTS=$(curl -s \
      "https://api.github.com/repos/$GITHUB_REPO/actions/runs/$RUN_ID/artifacts")
fi

ARTIFACT_NAME=$(echo "$ARTIFACTS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
arts = data.get('artifacts', [])
if arts:
    print(arts[0]['name'])
" 2>/dev/null)

ARTIFACT_URL=$(echo "$ARTIFACTS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
arts = data.get('artifacts', [])
if arts:
    print(arts[0]['archive_download_url'])
" 2>/dev/null)

if [ -z "$ARTIFACT_URL" ]; then
    err "No artifacts found in build #$RUN_ID!"
    exit 1
fi
ok "Artifact: $ARTIFACT_NAME"

# ---- Step 3: Download ----
DOWNLOAD_DIR="${REPO_ROOT}/downloads"
mkdir -p "$DOWNLOAD_DIR"
ARTIFACT_FILE="${DOWNLOAD_DIR}/${ARTIFACT_NAME}.zip"

info "Downloading artifact..."
if [ -n "$AUTH_HEADER" ]; then
    curl -sL -o "$ARTIFACT_FILE" -H "$AUTH_HEADER" "$ARTIFACT_URL"
else
    curl -sL -o "$ARTIFACT_FILE" "$ARTIFACT_URL"
fi

if [ ! -f "$ARTIFACT_FILE" ]; then
    err "Download failed!"
    exit 1
fi

SIZE=$(ls -lh "$ARTIFACT_FILE" | awk '{print $5}')
ok "Downloaded: $ARTIFACT_FILE ($SIZE)"

# ---- Step 4: Extract ----
EXTRACT_DIR="${DOWNLOAD_DIR}/modules"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

info "Extracting modules..."
unzip -o "$ARTIFACT_FILE" -d "$EXTRACT_DIR" >/dev/null 2>&1
ok "Extracted to: $EXTRACT_DIR"

echo ""
echo "--- Modules ---"
ls -lh "$EXTRACT_DIR"/
echo ""

# ---- Step 5: Install (load modules) ----
info "Installing kernel modules..."
cd "$EXTRACT_DIR"

# Order matters: drm base → shmem → gpu-sched → panfrost → opp-fix
for mod in drm.ko drm_shmem_helper.ko gpu-sched.ko panfrost.ko opp-fix.ko; do
    if [ -f "$mod" ]; then
        # Check if already loaded
        if lsmod 2>/dev/null | grep -q "^${mod%.ko}"; then
            ok "${mod%.ko} already loaded"
        else
            info "Loading $mod..."
            insmod "$mod" && ok "${mod%.ko} loaded" || warn "Failed to load $mod"
        fi
    fi
done

echo ""

# ---- Step 6: Verify ----
info "Verifying Panfrost status..."
echo ""
echo "--- Loaded modules ---"
lsmod | grep -E "panfrost|drm|gpu" || echo "(none)"
echo ""
echo "--- DRM devices ---"
ls -la /dev/dri/ 2>/dev/null || echo "(none)"
echo ""
echo "--- Render node ---"
if [ -e /dev/dri/renderD128 ]; then
    ok "/dev/dri/renderD128 exists!"
    echo "    Try: cat /sys/kernel/debug/dri/*/name"
else
    warn "/dev/dri/renderD128 NOT found"
    echo "    Check dmesg: dmesg | grep panfrost"
fi

echo ""
echo "============================================"
echo "  Done!"
echo "============================================"
echo ""
echo "Next step: run redroid with Panfrost"
echo "  sh ${REPO_ROOT}/scripts/run-redroid-panfrost.sh"
echo ""
