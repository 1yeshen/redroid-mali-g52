# redroid-mali-g52

为 Rockchip RK3568 设备（EasePi R1、Radxa ROCK3A/3B、Orange Pi 3B 等）定制的 **redroid**（Docker 中的 Android）镜像，带有 **Mali-G52 GPU 硬件加速**。

[![Analyze Mali Binaries](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/analyze-mali-binaries.yml/badge.svg)](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/analyze-mali-binaries.yml)
[![Build & Test Matrix](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-test-matrix.yml/badge.svg)](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-test-matrix.yml)
[![Build Mali-G52 Overlay](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-mali-overlay.yml/badge.svg)](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-mali-overlay.yml)
[![Build Panfrost Module](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-panfrost-module.yml/badge.svg)](https://github.com/1yeshen/redroid-mali-g52/actions/workflows/build-panfrost-module.yml)

## 当前状态

| 组件 | 状态 | 说明 |
|------|------|------|
| 容器启动（旧版基础镜像） | ✅ | 固定到 SHA `c898abca51e6` |
| Mali /dev/mali0 检测 | ✅ | `--mount bind` 保留 inode（修复 Issue #228） |
| Mali 用户态驱动加载 | ⚠️ | g25p0 通过 init 阶段（rk_so_ver 修补 10→8），GPU 不可用 |
| SurfaceFlinger GPU 初始化 | ❌ | DDK 不匹配：内核 g18p0 vs 可用用户态驱动 |
| **Panfrost 内核模块** | **✅ 已构建** | 为 6.6.127 交叉编译，vermagic 匹配 |
| **Panfrost 模块加载** | **⚠️ probe 失败** | 与 Mali 驱动的 OPP regulator 状态冲突 |
| **硬件加速（Mali 方案）** | ❌ | 等待匹配的（g13p0–g18p0）bionic 用户态驱动 |
| **硬件加速（Panfrost 方案）** | **🔄 进行中** | 需重启清除 Mali OPP 状态，然后构建 Mesa |

**根本原因：** 内核的 Mali Bifrost 模块（`bifrost_kbase.ko`）编译为 DDK **g18p0-01eac0**（≈r46p0），但所有可用的 Android（bionic）用户态 Mali 驱动都在不兼容的 DDK 版本上。用户态驱动必须使用与内核模块 IOCTL 接口兼容的 DDK 版本。

**当前方案：** 由于 Mali DDK 不匹配问题在公开的 bionic 驱动中无法解决，我们已**转向 Panfrost**（开源 GPU 驱动）。Panfrost 内核模块（`panfrost.ko`）已成功为内核 6.6.127 交叉编译。当前加载失败是由于 Mali 驱动遗留的 OPP/regulator 状态 — 禁用 Mali 后重启即可清除。

## Panfrost（开源 GPU 驱动）— 新方案

在耗尽了闭源 Mali 用户态驱动方案后（见 [DDK 兼容性矩阵](#ddk-兼容性矩阵)），我们已**转向开源 Panfrost GPU 驱动**用于 RK3568 上的 Mali-G52。

### 为什么选择 Panfrost？

- **Panfrost 支持 Mali-G52**（Bifrost 架构），自内核 5.2 起已合入主线 Linux
- **Redroid 已支持 Panfrost** — 通过 `/sys/kernel/debug/dri/*/name` 自动检测，设置 `ro.hardware.vulkan=panfrost`，使用 `gbm` gralloc
- **无 DDK 依赖** — Panfrost 是上游内核的一部分，无需匹配专有 IOCTL 接口
- **开源透明** — Mesa Gallium 驱动 + 内核模块

### 进展情况

| 步骤 | 状态 | 详情 |
|------|------|------|
| 1. Panfrost 可行性调研 | ✅ | 确认：redroid 支持 Panfrost，RK3568 GPU DT 兼容 |
| 2. 分析 iStoreOS 内核配置 | ✅ | DRM 未启用，IOMMU/SMMU/DMA_SHARED_BUFFER 已启用 |
| 3. 交叉编译 panfrost.ko | ✅ | 为内核 **6.6.127** 构建（精确匹配），vermagic = `6.6.127 SMP mod_unload aarch64` |
| 4. 加载 DRM 模块 | ✅ | **5 个模块**：`drm.ko`、`drm_shmem_helper.ko`、`gpu-sched.ko`、`panfrost.ko`、`drm_panel_orientation_quirks.ko` |
| 5. 首次 probe 尝试 | ⚠️ | Probe 失败 `-EBUSY` — Mali `bifrost_kbase.ko` 遗留的 OPP/regulator 状态 |
| 6. 禁用 Mali 后重启 | 🔜 | 下一步：黑名单 `bifrost_kbase`，重启，重新加载 Panfrost |
| 7. 构建 Mesa for Android (bionic) | 🔜 | 用 `-Dgallium-drivers=panfrost` 交叉编译 Mesa 用于 Android 容器 |

### Panfrost 内核模块构建方式

工作流 `.github/workflows/build-panfrost-module.yml` 为 iStoreOS 24.10.6（内核 6.6.127）交叉编译 `panfrost.ko`：

1. **下载** kernel.org 上的 vanilla Linux 6.6.127
2. **获取** iStoreOS 仓库中的 OpenWrt 内核配置（generic + rockchip/armv8）
3. **合并配置**并启用 `CONFIG_DRM=m`、`CONFIG_DRM_PANFROST=m`
4. **编译 vmlinux**（生成 `Module.symvers` 供核心内核符号使用）
5. **编译模块**通过 `make modules`（正确处理复合模块如 `drm.ko`）
6. **打包并上传**所有 DRM `.ko` 文件为构建产物

### 关键发现：`--mount` vs `--device` 用于 `/dev/mali0`

Mali 内核驱动会检查 `/dev/mali0` 的 inode 号是否匹配预期值。使用 `--device /dev/mali0` 会在容器中创建**新的 inode**，导致驱动拒绝访问。请使用 `--mount type=bind` 代替：

```bash
# ❌ 不起作用（inode 不同）：
--device /dev/mali0

# ✅ 起作用（与宿主机 inode 相同）：
--mount type=bind,source=/dev/mali0,destination=/dev/mali0
```

详见 [redroid-doc Issue #228](https://github.com/remote-android/redroid-doc/issues/228)

### DDK 兼容性矩阵

| 用户态 DDK | 来源 | rk_so_ver | 内核 g18p0 结果 |
|------------|------|-----------|----------------|
| g2p0-01eac0 | 旧 RK3566 固件 | 8 | ❌ `eglCreateImageKHR` 中 SIGSEGV |
| g7p1-01bet0 | 标准 RK3568 固件 | 8 | ❌ `eglCreateImageKHR` 中 SIGSEGV |
| g13p0-01eac0 | libmali-rockchip（glibc） | 11 | ❌ glibc ≠ bionic（libc 不匹配） |
| **g25p0-00eac0**（已修补） | FriendlyElec Android14 SDK rkr8 | **8**（原为 10） | ✅ 正常退出（code 0），GPU 无功能 |
| **g18p0（需要）** | 尚未找到 bionic 版本 | ? | ✅ 应与内核模块匹配 |
| **g13p0-bionic（需要）** | Rockchip Android 12/13 SDK | ? | ✅ Radxa 文档确认兼容 |

Radxa 文档确认：对于 RK356X，g18p0 内核对应的正确用户态 DDK 是 **g13p0**（Debian 上为 `libmali-bifrost-g52-g13p0-x11-wayland-gbm`）。

## 背景

在运行 iStoreOS（OpenWrt 24.10，内核 6.6.127）的 EasePi R1（RK3568）上：

- **标准 redroid:14.0.0_64only-latest** 可以使用软件渲染稳定运行（`gpu_mode=guest`）
- 但由于内核 6.6 binder ABI 不兼容，`servicemanager` 处于僵尸状态（容器仍可执行基本任务）
- **/dev/mali0** 在宿主机上存在，bifrost_kbase 内核模块版本为 DDK g18p0
- 此仓库构建带有 Mali-G52 用户态驱动的自定义镜像

## 架构

```
┌─────────────────────────────────────────────────────────┐
│                    GitHub Actions CI                      │
│  ┌─────────────────┐    ┌──────────────────────────────┐ │
│  │ Mali 二进制分析   │    │ 构建与测试矩阵              │ │
│  │ （30 阶段逆向工程）│    │ 3 种 Mali × 4 种基础镜像    │ │
│  └─────────────────┘    └──────────────────────────────┘ │
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

## 仓库内容

### 工作流（GitHub Actions）

| 工作流 | 描述 | 运行器 |
|--------|------|--------|
| `analyze-mali-binaries.yml` | 30 阶段逆向工程流水线：ELF 头、capstone 反汇编、YARA、熵分析、DDK 兼容矩阵、跨版本差异比较 | 免费 |
| `build-test-matrix.yml` | 构建+快速启动测试全部 12 种组合（3 种 Mali × 4 种基础镜像） | 免费 |
| `build-mali-overlay.yml` | 从固件 URL 提取 Mali .so + 构建 Docker 覆盖镜像 | 免费 |
| `extract-mali-from-firmware.yml` | 从 RK3568 Android 固件镜像中提取 vendor 分区 | 免费 |
| `build-aosp-full.yml` | 完整 AOSP + redroid-rockchip 源码构建（16 核运行器） | 付费 |
| `build-panfrost-module.yml` | **交叉编译 panfrost.ko** 用于 iStoreOS 内核 6.6.127（从源码构建 DRM + Panfrost） | 免费 |
 
### Mali 驱动变体

| 变体 | DDK | 大小 | rk_so_ver | 说明 |
|------|-----|------|-----------|------|
| `mali-binaries/`（默认） | g25p0-00eac0 | 50.5 MB | 10（已修补→8） | 来自 FriendlyElec Android 14 |
| `mali-binaries-g2p0/` | g2p0-01eac0 | 39.2 MB | 8 | 旧 RK3566 固件 |
| `mali-binaries-g7p1/` | g7p1-01bet0 | 39.5 MB | 8 | 标准 RK3568 固件 |
| `mali-binaries/.../g25p0_patched.so` | g25p0-00eac0 | 50.5 MB | **8**（已修补） | rk_so_ver 10→8，正常退出 |

### 脚本

| 脚本 | 用途 |
|------|------|
| `scripts/analyze_mali_so.sh` | 本地 Mali .so 逆向分析（DDK、符号、熵） |
| `scripts/extract-mali-from-firmware.sh` | 从 Android 固件镜像中提取 Mali 驱动 |

### Docker 配置

| 文件 | 用途 |
|------|------|
| `docker/Dockerfile` | 多阶段 Alpine→redroid 构建 |
| `docker/mali-config/bin/gpu_config.sh` | Mali GPU 配置脚本 |
| `docker/mali-config/etc/init/init.mali_gpu.rc` | Mali GPU 初始化脚本 |
| `docker/mali-config/etc/init/init.rockchip.gpu.rc` | Rockchip GPU 初始化 |
| `docker/mali-config/etc/gralloc/capabilities.xml` | Gralloc Bifrost 配置 |

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

## 本地使用（在 EasePi R1 / RK3568 上）

### 先决条件

#### 方案 A：Mali（闭源，DDK 不匹配）

```bash
# 加载 Bifrost 内核模块（iStoreOS 每次重启后都需要）
insmod /lib/modules/$(uname -r)/bifrost_kbase.ko

# 验证 Mali 设备
ls -la /dev/mali0
```

#### 方案 B：Panfrost（开源，推荐用于新开发）

```bash
# 1. 禁用 Mali 模块自动加载
echo "blacklist bifrost_kbase" > /etc/modprobe.d/blacklist-mali.conf
mv /etc/modules.d/85-rkgpu-bifrost /etc/modules.d/85-rkgpu-bifrost.disabled

# 2. 重启（清除 Mali OPP/regulator 状态）
reboot

# 3. 重启后验证 Mali 未加载
lsmod | grep bifrost  # 应为空

# 4. 按顺序加载 DRM 模块
insmod /mnt/nvme0n1-1/drm-modules/drm.ko
insmod /mnt/nvme0n1-1/drm-modules/gpu-sched.ko
insmod /mnt/nvme0n1-1/drm-modules/drm_shmem_helper.ko
insmod /mnt/nvme0n1-1/drm-modules/panfrost.ko

# 5. 验证 Panfrost 设备
ls -la /dev/dri/renderD128
```

### 本地构建

```bash
# 使用固定的工作基础镜像
docker build --build-arg REDROID_BASE=redroid/redroid:14.0.0-arch-fix \
  -t redroid-mali-g52 -f docker/Dockerfile .
```

### 运行（使用 --mount bind 修复）

```bash
# 使用 Mali GPU 加速运行
# 重要：对 /dev/mali0 使用 --mount bind（不是 --device）
docker run -d --privileged \
  --name redroid-mali \
  --mount type=bind,source=/dev/mali0,destination=/dev/mali0 \
  -p 5555:5555 \
  redroid-mali-g52:latest \
  androidboot.redroid_gpu_mode=mali
```

**注意：** 所有当前的 Mali 用户态驱动（g2p0/g7p1/g25p0）都与内核模块（g18p0）存在 DDK 不匹配。详见[当前状态](#当前状态)。

### GPU 验证

```bash
# 在容器内，检查 GPU 设备
adb shell ls -la /dev/mali0 /dev/rga /dev/dri/card0

# 检查 Mali/GPU 错误的 logcat
adb shell logcat -d -s SurfaceFlinger libEGL mali

# 检查 GPU 崩溃的 tombstone
adb shell ls /data/tombstones/

# 检查加载的 EGL 驱动
adb shell dumpsys SurfaceFlinger | grep GLES
```

## 项目结构

```
redroid-mali-g52/
├── .github/workflows/
│   ├── analyze-mali-binaries.yml   # 30 阶段逆向工程流水线
│   ├── build-mali-overlay.yml      # 固件提取 + 覆盖镜像构建
│   ├── build-test-matrix.yml       # 12 组合构建与测试矩阵
│   ├── build-aosp-full.yml         # 完整 AOSP 构建（付费运行器）
│   ├── extract-mali-from-firmware.yml  # 固件分区提取
│   └── build-panfrost-module.yml       # 交叉编译 panfrost.ko（内核 6.6.127）
├── scripts/
│   ├── analyze_mali_so.sh          # 本地 Mali .so 分析
│   └── extract-mali-from-firmware.sh   # 固件提取脚本
├── docker/
│   ├── Dockerfile                  # 多阶段 Docker 构建
│   └── mali-config/
│       ├── bin/gpu_config.sh
│       ├── etc/init/init.mali_gpu.rc
│       ├── etc/init/init.rockchip.gpu.rc
│       └── etc/gralloc/capabilities.xml
├── mali-binaries/                  # 默认（g25p0）Mali 驱动
│   └── vendor/
│       ├── lib/egl/libGLES_mali.so
│       ├── lib64/egl/libGLES_mali.so
│       ├── lib64/egl/libGLES_mali_g25p0.so       # 原始 g25p0 备份
│       ├── lib64/egl/libGLES_mali_g25p0_patched.so # rk_so_ver 10→8 修补版
│       └── lib64/hw/
│           ├── android.hardware.graphics.allocator@4.0-impl-bifrost.so
│           └── android.hardware.graphics.mapper@4.0-impl-bifrost.so
├── mali-binaries-g2p0/             # g2p0 Mali 驱动变体
│   └── vendor/lib64/egl/libGLES_mali.so
├── mali-binaries-g7p1/             # g7p1 Mali 驱动变体
│   └── vendor/lib64/egl/libGLES_mali.so
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
| `libGLES_mali.so` | Mali GPU 用户态驱动（EGL/GLES/Vulkan）— 主要的驱动二进制文件 |
| `android.hardware.graphics.allocator@4.0-impl-bifrost.so` | Gralloc 缓冲分配（Bifrost） |
| `android.hardware.graphics.mapper@4.0-impl-bifrost.so` | Gralloc 缓冲映射（Bifrost） |
| `hwcomposer.rockchip.so` | Rockchip 硬件合成器 |
| `capabilities.xml` | Gralloc 能力配置 |

### DDK 版本调查

Mali Bifrost DDK 使用命名规则 `gXXpY`：
- `g` = 代次，`p` = 补丁
- 数字越大 = DDK 越新
- Bifrost 架构涵盖 `g2p0` 至 `g25p0`+

**ARM DDK 版本对应关系（近似）：**
| DDK | ARM 版本 | 说明 |
|-----|----------|------|
| g2p0 | r32p0 | 非常旧 |
| g7p1 | r38p0 | 旧 |
| **g13p0** | **r41p0** | **确认与 g18p0 内核兼容** |
| g15p0 | r43p0 | 可能可用 |
| g17p0 | r45p0 | 可能可用 |
| **g18p0** | **r46p0** | **我们的内核模块** |
| g25p0 | r48p0 | 太新 |

**关键发现：**
1. **内核模块**（bifrost_kbase.ko）：`g18p0-01eac0`（~r46p0，Rockchip 内核 6.6）
2. **g7p1 bionic 驱动**：来自标准 RK3568 固件，DDK 对内核来说太旧
3. **g13p0 glibc 驱动**：来自 libmali-rockchip，DDK 时代正确但与 bionic 不兼容。Debian 包 `libmali-bifrost-g52-g13p0-x11-wayland-gbm` 包含 `libmali.so.1.9.0`（43MB，rk_so_ver 11）
4. **g25p0 bionic 驱动**：来自 FriendlyElec Android 14 SDK rkr8，比内核 DDK 更新。rk_so_ver 从 10 修补为 8 以通过 init，但 IOCTL 不匹配仍然存在
5. **g13p0 bionic（Android）驱动**：**尚未找到** — 这是缺失的关键部分。它存在于 Rockchip 的 Android 12/13 SDK vendor 分区中
6. **g13p0 可用性**：glibc 版本确认 g13p0 为 Mali-G52 存在。必须从 Rockchip Android SDK 固件中提取 bionic（Android）版本

### g13p0 Mali 驱动来源

已知 Mali-G52 g13p0 用户态驱动在以下地方分发：

1. **Radxa Debian Bookworm**：`libmali-bifrost-g52-g13p0-x11-wayland-gbm`（glibc）— 来自 `tsukumijima/libmali-rockchip`
2. **christianhaitian/rk3566_core_builds**：`mali/aarch64/libmali-bifrost-g52-g13p0-gbm.so`（glibc）— 用于 ArkOS/EmuELEC
3. **Rockchip Android 12/13 SDK**：包含 bionic 版本 `libGLES_mali.so`（g13p0）— **这是我们需要的**
4. **bmdhacks/dArkOS_rg52mini**：引用 RK3562 的 g13p0，从 `rk3566_core_builds` 下载

### rk_so_ver 修补

`libGLES_mali.so` 中的 `rk_so_ver` 字段被 Android 的 linker/init 用于验证驱动兼容性。基础镜像 `redroid/redroid:14.0.0-arch-fix` 期望 rk_so_ver 为 `8@0`。

**g25p0 修补（偏移 0x11e834）：**
```
修补前：rk_so_ver is '10'.
修补后：rk_so_ver is '8@0'.
```

这修复了 init 阶段的 SIGHUP（exit 129），使容器能够启动。但由于 g25p0 用户态与 g18p0 内核之间的 IOCTL 接口不匹配，Mali GPU 仍然无法工作。

### 内核设备要求

| 设备 | 用途 |
|------|------|
| `/dev/mali0` | Mali GPU（主设备号 10，次设备号 258） |
| `/dev/rga` | 光栅图形加速 |
| `/dev/mpp_service` | 视频编解码（媒体处理平台） |
| `/dev/dri/card0` | DRM 显示 |

### 已知限制

1. **DDK 不匹配（Mali 方案）**：内核模块（g18p0）与用户态驱动（g2p0/g7p1/g25p0）— IOCTL 接口不兼容
2. **Binder ABI**：内核 6.6 的 binder ABI 与 Android 14 的 libbinder 不兼容（单向垃圾邮件处理方式已更改）。这导致 `servicemanager` 和 `hwservicemanager` 处于僵尸状态。GPU HAL 应仍能正确加载，因为它通过内核驱动通信，而不是 binder
3. **缺少 bionic g13p0 驱动**：正确的用户态驱动（g13p0 bionic）在公开仓库中尚未找到。必须从 Rockchip 的内部 Android SDK 中提取
4. **Panfrost OPP 冲突**：当 Mali 驱动之前加载过时，Panfrost probe 失败并返回 `-EBUSY`。需要禁用 Mali 后重启以清除 OPP/regulator 状态
5. **Panfrost Mesa 构建**：为 Android (bionic) 构建带 Panfrost Gallium 驱动的 Mesa 仍在进行中。`wode2016501/mesa-for-android-container` 的预构建 Mesa 用于 glibc 容器，不能直接在 redroid 中使用

## 参考

- [redroid-rockchip/platform_manifests](https://github.com/redroid-rockchip/platform_manifests)
- [remote-android/redroid-doc](https://github.com/remote-android/redroid-doc)
  - [Issue #228: RK3588 Mali GPU（--mount bind 修复）](https://github.com/remote-android/redroid-doc/issues/228)
  - [Issue #519: RK3399 Mali GPU（EGL_BAD_ACCESS）](https://github.com/remote-android/redroid-doc/issues/519)
  - [Issue #614: RK3588 Mali GPU（mali_csffw.bin）](https://github.com/remote-android/redroid-doc/issues/614)
- [tsukumijima/libmali-rockchip](https://github.com/tsukumijima/libmali-rockchip) — Debian Mali 驱动包
- [christianhaitian/rk3566_core_builds](https://github.com/christianhaitian/rk3566_core_builds) — 预编译 Mali g13p0（glibc）用于 ArkOS
- [bmdhacks/dArkOS_rg52mini](https://github.com/bmdhacks/dArkOS_rg52mini) — 使用 Mali g13p0 的参考构建
- [FriendlyElec rk35xx-android14](http://112.124.9.243:3000/friendlyelec/rk35xx-android14)
- [Radxa ROCK3A Android docs](https://docs.radxa.com/en/rock3/rock3a/other-os/android)
- [Radxa GPU 驱动切换](https://docs.radxa.com/en/rock5/rock5c/radxa-os/mali-gpu) — 确认 RK356X 使用 g13p0
- [Rockchip Linux Graphics](https://opensource.rock-chips.com/wiki_Graphics)
- [Rockchip Mali Wiki](https://opensource.rock-chips.com/wiki_Mali)
- [CNflysky/redroid-rk3588](https://github.com/CNflysky/redroid-rk3588) — RK3588 redroid 参考实现（Mali-G610）
- [Panfrost — Mesa 文档](https://docs.mesa3d.org/drivers/panfrost.html) — 开源 Mali Bifrost 驱动
- [Panfrost 主线 Linux](https://gitlab.freedesktop.org/panfrost/linux) — 上游 Panfrost 内核驱动
- [wode2016501/mesa-for-android-container](https://github.com/wode2016501/mesa-for-android-container) — 预构建的 Android 容器 Mesa（Panfrost/Freedreno）
- [lfdevs/mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container) — 上游 Mesa fork（含 Android 容器补丁）
- [iStoreOS 内核源码](https://github.com/istoreos/istoreos)（分支 `istoreos-24.10`）— 用于构建 Panfrost 模块的内核源码
