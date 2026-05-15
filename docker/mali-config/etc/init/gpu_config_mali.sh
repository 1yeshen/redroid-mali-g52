#!/system/bin/sh
# ============================================================
# Mali GPU configuration for RK3568
# Installed to /vendor/etc/init/gpu_config_mali.sh
# Called from init.mali_gpu.rc to override gpu_config.sh
# ============================================================

# Only run when Mali GPU mode is requested
mode=$(getprop ro.boot.redroid_gpu_mode)
if [ "$mode" != "mali" ]; then
    # Not Mali mode - exit silently, let default gpu_config.sh handle it
    exit 0
fi

echo "Mali GPU mode detected - configuring Mali-G52 GPU"

# Set Mali EGL as the default EGL implementation
setprop ro.hardware.egl mali

# Use bifrost gralloc HAL  
setprop ro.hardware.gralloc bifrost

# Hardcode display properties for headless operation
setprop ro.boot.redroid_fps 30
setprop ro.boot.redroid_width 720
setprop ro.boot.redroid_height 1280
setprop ro.boot.redroid_dpi 320

# Mali GPU device permissions
chmod 0666 /dev/mali0
chmod 0666 /dev/rga
chmod 0666 /dev/dri/card0

# Log success
log -t MaliGPU -p i "Mali-G52 GPU mode configured successfully (mali)"

exit 0
