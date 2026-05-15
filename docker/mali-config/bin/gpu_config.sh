#!/system/bin/sh
# ============================================================
# GPU configuration for redroid (enhanced for Mali-G52)
#
# This replaces the default gpu_config.sh from the redroid
# base image, adding support for "mali" GPU mode.
#
# Supported modes:
#   host  - Mesa/GBM (Intel, AMD, NVIDIA desktop GPUs)
#   guest - SwiftShader/Angle (software render)
#   auto  - auto-detect DRI node, fallback to guest
#   mali  - Mali Bifrost GPU (RK3568/RK3588 etc.)
# ============================================================

# args: driver
setup_vulkan() {
    echo "setup vulkan for driver: $1"
    case "$1" in
        i915)
            setprop ro.hardware.vulkan intel
            ;;
        amdgpu)
            setprop ro.hardware.vulkan radeon
            ;;
        virtio_gpu)
            setprop ro.hardware.vulkan virtio
            ;;
        v3d|vc4)
            setprop ro.hardware.vulkan broadcom
            ;;
        msm_drm)
            setprop ro.hardware.vulkan freedreno
            ;;
        panfrost)
            setprop ro.hardware.vulkan panfrost
            ;;
        mali)
            setprop ro.hardware.vulkan mali
            ;;
        *)
            echo "not supported driver: $1"
            ;;
    esac
}

setup_render_node() {
    node=$(getprop ro.boot.redroid_gpu_node)
    if [ -n "$node" ]; then
        echo "force render node: $node"

        setprop gralloc.gbm.device "$node"
        chmod 666 "$node"

        # setup vulkan
        driver=$(cut -d' ' -f1 "/sys/kernel/debug/dri/${node#/dev/dri/renderD}/name")
        setup_vulkan "$driver"
        return 0
    fi

    cd /sys/kernel/debug/dri || exit
    for d in * ; do
        if [ "$d" -ge "128" ]; then
            driver="$(cut -d' ' -f1 "$d/name")"
            echo "DRI node exists, driver: $driver"
            setup_vulkan "$driver"
            case $driver in
                i915|amdgpu|nouveau|virtio_gpu|v3d|vc4|msm_drm|panfrost)
                    node="/dev/dri/renderD$d"
                    echo "use render node: $node"
                    setprop gralloc.gbm.device "$node"
                    chmod 666 "$node"
                    return 0
                    ;;
            esac
        fi
    done

    echo "NO qualified render node found"
    return 1
}

gpu_setup_host() {
    echo "use GPU host mode"

    setprop ro.hardware.egl mesa
    setprop ro.hardware.gralloc gbm
    setprop ro.boot.redroid_fps 30
}

gpu_setup_guest() {
    echo "use GPU guest mode"

    EGL_DIR=/vendor/lib64/egl
    egl=

    if [ -f $EGL_DIR/libEGL_angle.so ]; then
        egl=angle
    elif [ -f $EGL_DIR/libEGL_swiftshader.so ];then
        egl=swiftshader
    else
        echo "ERROR no SW egl found!!!"
    fi

    setprop ro.hardware.egl $egl
    setprop ro.hardware.gralloc redroid
    setprop ro.hardware.vulkan pastel
}

gpu_setup_mali() {
    echo "use GPU Mali mode (Mali-G52 Bifrost on RK3568)"

    # Set Mali EGL implementation
    setprop ro.hardware.egl mali

    # Set bifrost gralloc HAL
    setprop ro.hardware.gralloc bifrost

    # Set Mali Vulkan support
    setprop ro.hardware.vulkan mali

    # Display properties for headless Android
    setprop ro.boot.redroid_fps 30
    setprop ro.boot.redroid_width 720
    setprop ro.boot.redroid_height 1280
    setprop ro.boot.redroid_dpi 320

    # Mali GPU device permissions
    chmod 0666 /dev/mali0
    chmod 0666 /dev/rga
    chmod 0666 /dev/dri/card0
    chmod 0666 /dev/mpp_service

    echo "Mali-G52 GPU mode configured successfully"
}

gpu_setup() {
    mode=$(getprop ro.boot.redroid_gpu_mode)
    if [ -z "$mode" ]; then
        mode="guest"
    fi

    echo "GPU mode: $mode"

    case "$mode" in
        host)
            setup_render_node
            gpu_setup_host
            ;;
        guest)
            gpu_setup_guest
            ;;
        auto)
            echo "use GPU auto mode"
            if setup_render_node; then
                gpu_setup_host
            else
                gpu_setup_guest
            fi
            ;;
        mali)
            gpu_setup_mali
            ;;
        *)
            echo "unknown mode: $mode, falling back to guest"
            gpu_setup_guest
            ;;
    esac
}

gpu_setup
