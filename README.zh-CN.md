# redroid-mali-g52

为 Rockchip RK3568 设备（EasePi R1、Radxa ROCK3A/3B 等）定制的 **redroid**（Docker 中的 Android）镜像，带有 **Mali-G52 GPU 硬件加速**。

## 当前状态

| 组件 | 状态 | 说明 |
|------|------|------|
| 容器启动（旧版基础镜像） | ✅ | 固定到 SHA `c898abca51e6` |
| Mali /dev/mali0 检测 | ✅ | 设备已映射到容器中 |
| Mali 用户态驱动加载 | ✅ | g25p0 DDK 正确加载 |
| SurfaceFlinger GPU 初始化 | ❌ | DDK 不匹配：内核 g18p0 vs 用户态 g25p0/g7p1 |
| 硬件加速 | ❌ | 等待匹配 DDK 的用户态驱动 |

**根本原因：** 内核的 Mali Bifrost 模块（`bifrost_kbase.ko`）编译为 DDK **g18p0-01eac0**（r46p0），但所有可用的 Android（bionic）用户态 Mali 驱动都在不同的 DDK 版本上。用户态驱动必须使用与内核模块兼容的 DDK 版本。

### DDK 兼容性矩阵

| 用户态 DDK | 来源 | rk_so_ver | 内核 g18p0 结果 |
|------------|------|-----------|----------------|
| g2p0-01eac0 | 旧 RK3566 固件 | 8 | ❌ `eglCreateImageKHR` 中 SIGSEGV |
| g7p1-01bet0 | 标准 RK3568 固件 | 8 | ❌ `eglCreateImageKHR` 中 SIGSEGV |
| g13p0-01eac0 | libmali-rockchip（glibc） | 11 | ❌ glibc 与 Android bionic 不兼容 |
| **g25p0-00eac0** | FriendlyElec Android14 SDK rkr8 | 10 | ❌ init 阶段 Exit 129（SIGHUP） |
| **g18p0（需要）** | 尚未找到 | ? | ✅ 应与内核模块匹配 |

## 背景

在运行 iStoreOS（OpenWrt 24.10，内核 6.6.127）的 EasePi R1（RK3568）上：

- **标准 redroid:14.0.0_64only-latest** 可以使用软件渲染稳定运行（`gpu_mode=guest`）
- 但由于内核 6.6 binder ABI 不兼容，`servicemanager` 处于僵尸状态（容器仍可执行基本任务）
- **/dev/mali0** 在宿主机上存在，但未在容器中使用
- 此仓库构建带有 Mali-G52 用户态驱动的自定义镜像

## 架构

```
┌─────────────────────────────────────────────────────────┐
│                    GitHub Actions CI                      │
│  ┌─────────────────┐    ┌──────────────────────────────┐ │
│  │ 从 RK3568        │ -> │ 构建 Docker 覆盖镜像         │ │
│  │ Android 固件      │    │ redroid + Mali-G52 驱动     │ │
│  │ 提取 Mali .so     │    │        ↓                     │ │
│  └─────────────────┘    │  ghcr.io/1yeshen/redroid-     │ │
│                          │  mali-g52:latest              │ │
│                          └──────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
         ↓ 在设备上拉取
┌─────────────────────────────────────────────────────────┐
│              EasePi R1 (RK3568)                           │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Docker 容器: redroid-mali-g52                    │   │
│  │  ┌────────────────────────────────────────────┐   │   │
│  │  │  Android 14 (AOSP)                        │   │   │
│  │  │  ├─ libGLES_mali.so (Mali-G52) ───────────┼──┼───┼───► /dev/mali0
│  │  │  ├─ gralloc-bifrost.so ───────────────────┼──┼───┼───► /dev/rga
│  │  │  ├─ hwcomposer.rockchip.so ──────────────┼──┼───┼───► /dev/dri/card0
│  │  │  └─ mpp_service ──────────────────────────┼──┼───┼───► /dev/mpp_service
│  │  └────────────────────────────────────────────┘   │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## 构建方法

### 方法 1：固件提取（推荐，免费运行器 ✅）

从 RK3568 Android 固件中提取预编译的 Mali-G52 Android（bionic）驱动。

**触发：** 在 GitHub Actions 上使用 `workflow_dispatch`：
1. 转到 **Actions** → **Build Mali-G52 Overlay** → **Run workflow**
2. 提供 RK3568 Android 固件的 URL（例如 Firefly 或 Radxa 发布版）
3. 工作流会提取 Mali .so 文件并构建 Docker 覆盖镜像
4. 镜像推送到 `ghcr.io/1yeshen/redroid-mali-g52:latest`

**固件来源：**
- [FriendlyElec NanoPi R5C Android 14](https://download.friendlyelec.com/NanoPiR5C)
- [Firefly ROC-RK3566-PC Android 11](https://en.t-firefly.com/doc/download/93.html)
- [Radxa ROCK3A Android 11](https://docs.radxa.com/en/rock3/rock3a/other-os/android)
- 任何包含 Mali-G52 Bifrost 驱动的 RK3568/RK3566 Android 固件

### 方法 2：完整 AOSP 构建（付费运行器 💰）

完整源码编译 AOSP + redroid-rockchip，包含 Mali-G52 HAL。

**需要：** GitHub 大型运行器（推荐 16 核/64GB/300GB 磁盘）
**构建时间：** ~5 小时
**费用：** ~$2.40（按 $0.008/分钟，4 核大型运行器计费）

**触发：** 在 **Build AOSP (Full) - Mali-G52** 上使用 `workflow_dispatch`

## 本地使用（在 EasePi R1 上）

### 先决条件：加载 Mali 内核模块

```bash
# 加载 Bifrost 内核模块（iStoreOS 每次重启后都需要）
insmod /lib/modules/$(uname -r)/bifrost_kbase.ko

# 验证 Mali 设备
ls -la /dev/mali0
```

### 本地构建

```bash
# 使用固定的工作基础镜像
docker build --build-arg REDROID_BASE=redroid/redroid:14.0.0-arch-fix \
  -t redroid-mali-g52 -f docker/Dockerfile .
```

### 运行

```bash
# 使用 Mali GPU 加速运行
docker run -d --privileged \
  --name redroid-mali \
  --device /dev/mali0:/dev/mali0 \
  --device /dev/rga:/dev/rga \
  --device /dev/dri:/dev/dri \
  -v /dev:/dev \
  -p 5555:5555 \
  redroid-mali-g52:latest \
  androidboot.redroid_gpu_mode=mali
```

**重要：** 当前的 Mali 用户态驱动（g2p0/g7p1）可以启动，但 SurfaceFlinger 会因 DDK 与内核模块（g18p0）不匹配而崩溃。详见[当前状态](#当前状态)。

### GPU 验证

```bash
# 在容器内，检查 GPU 设备
adb shell ls -la /dev/mali0 /dev/rga /dev/dri/card0

# 检查 Mali/GPU 错误的 logcat
adb shell logcat -d -s SurfaceFlinger

# 检查 GPU 崩溃的 tombstone
adb shell ls /data/tombstones/
```

## 项目结构

```
redroid-mali-g52/
├── .github/workflows/
│   ├── build-mali-overlay.yml   # 固件提取 + 覆盖镜像构建（免费运行器）
│   └── build-aosp-full.yml      # 完整 AOSP 构建（付费运行器）
├── scripts/
│   └── extract-mali-from-firmware.sh  # Mali 驱动提取脚本
├── docker/
│   ├── Dockerfile               # 多阶段 Docker 构建
│   └── mali-config/
│       ├── bin/gpu_config.sh    # Mali GPU 配置脚本
│       ├── etc/init/init.mali_gpu.rc  # Mali GPU 初始化脚本
│       ├── etc/init/init.rockchip.gpu.rc  # Rockchip GPU 初始化
│       └── etc/gralloc/capabilities.xml # Gralloc Bifrost 配置
├── mali-binaries/
│   └── vendor/
│       ├── lib/egl/libGLES_mali.so          # 32 位 Mali 驱动
│       ├── lib64/egl/libGLES_mali.so        # 64 位 Mali 驱动
│       └── lib64/hw/
│           ├── android.hardware.graphics.allocator@4.0-impl-bifrost.so
│           └── android.hardware.graphics.mapper@4.0-impl-bifrost.so
├── README.md
├── README.zh-CN.md
├── LICENSE              # GPL-3.0
├── PATENTS              # 专利授权 + 诉讼终止条款
├── NOTICE               # 第三方归属声明
└── .gitignore
```

## 技术细节

### Mali-G52 Bifrost 用户态组件

| 文件 | 用途 |
|------|------|
| `libGLES_mali.so` | Mali GPU 用户态驱动（EGL/GLES/Vulkan） |
| `android.hardware.graphics.allocator@4.0-impl-bifrost.so` | Gralloc 缓冲分配（Bifrost） |
| `android.hardware.graphics.mapper@4.0-impl-bifrost.so` | Gralloc 缓冲映射（Bifrost） |
| `hwcomposer.rockchip.so` | Rockchip 硬件合成器 |
| `capabilities.xml` | Gralloc 能力配置 |

### DDK 版本调查

Mali Bifrost DDK 使用命名规则 `gXXpY`：
- `g` = 代次，`p` = 补丁
- 数字越大 = DDK 越新
- Bifrost 架构涵盖 `g2p0` 至 `g25p0`+

关键发现：
1. **内核模块**（bifrost_kbase.ko）：`g18p0-01eac0`（~r46p0，Rockchip 内核 6.6）
2. **g7p1 bionic 驱动**：来自标准 RK3568 固件，DDK 对内核来说太旧
3. **g13p0 glibc 驱动**：来自 libmali-rockchip，DDK 时代正确但与 bionic 不兼容
4. **g25p0 bionic 驱动**：来自 FriendlyElec Android 14 SDK rkr8，比内核 DDK 更新，导致 init 崩溃
5. **需要**：DDK 在 g13p0-g18p0 范围内的 bionic Mali 用户态驱动

### 内核设备要求

| 设备 | 用途 |
|------|------|
| `/dev/mali0` | Mali GPU（主设备号 10，次设备号 258） |
| `/dev/rga` | 光栅图形加速 |
| `/dev/mpp_service` | 视频编解码（媒体处理平台） |
| `/dev/dri/card0` | DRM 显示 |

### 已知限制

内核 6.6 的 binder ABI 与 Android 14 的 libbinder 不兼容（单向垃圾邮件处理方式已更改）。这导致 `servicemanager` 和 `hwservicemanager` 处于僵尸状态。Mali GPU HAL 应仍能正确加载，因为它通过 Mali 内核驱动（`/dev/mali0`）通信，而不是 binder。容器稳定性不受影响。

## 参考

- [redroid-rockchip/platform_manifests](https://github.com/redroid-rockchip/platform_manifests)
- [remote-android/redroid-doc](https://github.com/remote-android/redroid-doc)
- [tsukumijima/libmali-rockchip](https://github.com/tsukumijima/libmali-rockchip)
- [FriendlyElec rk35xx-android14](http://112.124.9.243:3000/friendlyelec/rk35xx-android14)
- [Radxa ROCK3A Android docs](https://docs.radxa.com/en/rock3/rock3a/other-os/android)
- [Rockchip Linux Graphics](https://opensource.rock-chips.com/wiki_Graphics)
