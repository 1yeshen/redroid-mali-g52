#!/bin/sh
# ============================================================
# switch-kernel.sh
#
# 内核手动切换脚本 - iStoreOS/EasePi R1 (RK3568)
#
# 功能：
#   1. 备份当前内核 (kernel.img)
#   2. 切换到指定内核
#   3. 恢复到上一个内核
#   4. 查看当前/备份内核状态
#   5. 从网络下载并切换到指定内核
#
# 用法：
#   ./switch-kernel.sh status              # 查看当前内核状态
#   ./switch-kernel.sh backup              # 备份当前内核
#   ./switch-kernel.sh switch <kernel.img> # 切换到指定内核文件
#   ./switch-kernel.sh restore             # 恢复上一次备份
#   ./switch-kernel.sh fetch <URL>         # 从URL下载内核并切换
#   ./switch-kernel.sh list                # 列出可用备份
#
# 注意：
#   - 内核文件存放在 /boot/kernel.img
#   - 备份存放在 /mnt/nvme0n1-1/kernel-backups/
#   - 切换后需重启生效
# ============================================================

set -e

# 配置
BOOT_DIR="/boot"
KERNEL_FILE="${BOOT_DIR}/kernel.img"
BACKUP_DIR="/mnt/nvme0n1-1/kernel-backups"
DTB_FILE="${BOOT_DIR}/rockchip.dtb"
MODULES_DIR="/lib/modules"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
header(){ echo -e "${BLUE}━━━ $1 ━━━${NC}"; }

# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "请以 root 权限运行此脚本"
        exit 1
    fi
}

# 检查 boot 分区是否可写
check_boot() {
    if ! mount | grep -q "${BOOT_DIR}.*rw"; then
        warn "${BOOT_DIR} 当前为只读，尝试重新挂载..."
        mount -o remount,rw "${BOOT_DIR}" 2>/dev/null || {
            error "无法以读写方式挂载 ${BOOT_DIR}"
            exit 1
        }
    fi
}

# 获取当前内核版本
get_kernel_version() {
    uname -r 2>/dev/null || echo "unknown"
}

# 获取内核构建信息
get_kernel_build() {
    cat /proc/version 2>/dev/null | head -1
}

# 获取内核文件详细信息
get_kernel_file_info() {
    if [ -f "${KERNEL_FILE}" ]; then
        local size=$(stat -c%s "${KERNEL_FILE}" 2>/dev/null)
        local date=$(stat -c%y "${KERNEL_FILE}" 2>/dev/null | cut -d. -f1)
        local md5=$(md5sum "${KERNEL_FILE}" 2>/dev/null | cut -d' ' -f1)
        echo "文件大小: $((${size} / 1024 / 1024)) MB"
        echo "修改日期: ${date}"
        echo "MD5: ${md5}"
    else
        echo "文件不存在!"
    fi
}

# 检查模块版本兼容性
check_module_compat() {
    local kernel_ver="$1"
    if [ -d "${MODULES_DIR}/${kernel_ver}" ]; then
        local mod_count=$(find "${MODULES_DIR}/${kernel_ver}/kernel" -name "*.ko" 2>/dev/null | wc -l)
        echo "内核模块: ${mod_count} 个模块可用 (${MODULES_DIR}/${kernel_ver})"
        return 0
    else
        warn "未找到内核 ${kernel_ver} 对应的模块目录 ${MODULES_DIR}/${kernel_ver}"
        warn "切换后可能需要重新安装内核模块!"
        return 1
    fi
}

# ============================================================
# 子命令
# ============================================================

# 显示状态
cmd_status() {
    header "系统内核状态"
    
    echo -e "运行内核: $(get_kernel_version)"
    echo -e "构建信息: $(get_kernel_build)"
    echo ""
    
    header "内核文件状态"
    echo -e "内核文件: ${KERNEL_FILE}"
    get_kernel_file_info
    echo ""
    
    # DTB 信息
    if [ -L "${DTB_FILE}" ]; then
        echo "DTB文件: ${DTB_FILE} -> $(readlink ${DTB_FILE})"
    elif [ -f "${DTB_FILE}" ]; then
        echo "DTB文件: ${DTB_FILE}"
    fi
    echo ""
    
    # 模块兼容性
    header "内核模块兼容性"
    check_module_compat "$(get_kernel_version)" || true
    echo ""
    
    # 可用备份
    header "可用内核备份"
    cmd_list
}

# 备份当前内核
cmd_backup() {
    header "备份当前内核"
    
    mkdir -p "${BACKUP_DIR}"
    
    local date_tag=$(date +%Y%m%d-%H%M%S)
    local kernel_ver=$(get_kernel_version)
    local backup_name="kernel-${kernel_ver}-${date_tag}"
    local backup_file="${BACKUP_DIR}/${backup_name}.img"
    
    if [ ! -f "${KERNEL_FILE}" ]; then
        error "${KERNEL_FILE} 不存在，无法备份!"
        exit 1
    fi
    
    info "正在备份当前内核..."
    cp "${KERNEL_FILE}" "${backup_file}"
    
    # 保存元信息
    cat > "${BACKUP_DIR}/${backup_name}.meta" << METAEOF
KERNEL_VERSION=${kernel_ver}
BACKUP_DATE=$(date '+%Y-%m-%d %H:%M:%S')
KERNEL_SIZE=$(stat -c%s "${KERNEL_FILE}")
KERNEL_MD5=$(md5sum "${KERNEL_FILE}" | cut -d' ' -f1)
METAEOF
    
    info "备份完成: ${backup_file}"
    info "内核版本: ${kernel_ver}"
    info "备份大小: $(stat -c%s "${backup_file}" | awk '{printf "%.1f MB", $1/1024/1024}')"
}

# 切换内核
cmd_switch() {
    local new_kernel="$1"
    
    if [ -z "${new_kernel}" ]; then
        error "请指定内核文件路径"
        echo "用法: $0 switch <kernel.img>"
        exit 1
    fi
    
    if [ ! -f "${new_kernel}" ]; then
        error "内核文件不存在: ${new_kernel}"
        exit 1
    fi
    
    header "切换内核"
    
    # 检查文件类型
    local file_type=$(file "${new_kernel}" 2>/dev/null)
    if ! echo "${file_type}" | grep -q "Linux kernel.*Image"; then
        warn "文件类型可能不是内核镜像: ${file_type}"
        warn "继续切换前请确认文件正确!"
        echo -n "是否继续? [y/N]: "
        read confirm
        if [ "${confirm}" != "y" ] && [ "${confirm}" != "Y" ]; then
            info "已取消"
            exit 0
        fi
    fi
    
    # 自动备份
    info "切换前自动备份当前内核..."
    cmd_backup
    
    check_boot
    
    info "正在部署新内核: ${new_kernel}"
    cp "${new_kernel}" "${KERNEL_FILE}"
    sync
    
    info "内核部署完成!"
    warn "请重启以应用新内核: reboot"
    echo ""
    echo "如果要恢复上一个内核，请运行:"
    echo "  $0 restore"
}

# 恢复备份
cmd_restore() {
    header "恢复内核备份"
    
    # 查找最新的备份
    local latest_backup=$(ls -t ${BACKUP_DIR}/kernel-*.img 2>/dev/null | head -1)
    
    if [ -z "${latest_backup}" ]; then
        error "没有找到备份文件 (${BACKUP_DIR}/kernel-*.img)"
        exit 1
    fi
    
    local backup_name=$(basename "${latest_backup}" .img)
    local meta_file="${BACKUP_DIR}/${backup_name}.meta"
    
    echo "将恢复以下备份:"
    echo "  文件: ${latest_backup}"
    if [ -f "${meta_file}" ]; then
        cat "${meta_file}" | sed 's/^/  /'
    fi
    
    echo ""
    echo -n "确认恢复此内核? [y/N]: "
    read confirm
    if [ "${confirm}" != "y" ] && [ "${confirm}" != "Y" ]; then
        info "已取消"
        exit 0
    fi
    
    check_boot
    
    info "正在恢复内核..."
    cp "${latest_backup}" "${KERNEL_FILE}"
    sync
    
    info "恢复完成!"
    warn "请重启以应用恢复的内核: reboot"
}

# 从 URL 下载并切换
cmd_fetch() {
    local url="$1"
    
    if [ -z "${url}" ]; then
        error "请提供内核文件的下载 URL"
        echo "用法: $0 fetch <URL>"
        echo ""
        echo "原始内核下载地址（示例）:"
        echo "  https://fw0.koolcenter.com/iStoreOS/24.10.6/rockchip/armv8/"
        echo "  或从以下位置提取:"
        echo "  https://github.com/istoreos/istoreos/releases"
        exit 1
    fi
    
    header "下载内核"
    
    local temp_file="/tmp/kernel-download-$$.img"
    
    info "正在下载: ${url}"
    # 使用 ksget.sh 加速下载（如果可用）
    SKILLS_DIR="${XDG_CONFIG_HOME}/opencode/skills"
    [ -d "$SKILLS_DIR" ] || SKILLS_DIR="${XDG_CACHE_HOME}/opencode/skills"
    
    if [ -f "${SKILLS_DIR}/istoreos-kspeeder-domainfold-fetch/scripts/ksget.sh" ]; then
        sh "${SKILLS_DIR}/istoreos-kspeeder-domainfold-fetch/scripts/ksget.sh" \
            -o "${temp_file}" "${url}" || {
            error "下载失败"
            rm -f "${temp_file}"
            exit 1
        }
    else
        curl -fsSL "${url}" -o "${temp_file}" 2>/dev/null || {
            error "下载失败: curl returned $?"
            rm -f "${temp_file}"
            exit 1
        }
    fi
    
    if [ ! -f "${temp_file}" ] || [ $(stat -c%s "${temp_file}") -lt 1000000 ]; then
        error "下载文件太小或不存在，可能不是有效的内核镜像"
        rm -f "${temp_file}"
        exit 1
    fi
    
    info "下载完成 ($(stat -c%s "${temp_file}" | awk '{printf "%.1f MB", $1/1024/1024}'))"
    
    # 自动切换到下载的内核
    cmd_switch "${temp_file}"
    rm -f "${temp_file}"
}

# 列出备份
cmd_list() {
    local backups=$(ls ${BACKUP_DIR}/kernel-*.img 2>/dev/null | sort -r)
    
    if [ -z "${backups}" ]; then
        echo "  (无备份)"
        return
    fi
    
    echo "${backups}" | while read bk; do
        local name=$(basename "${bk}" .img)
        local size=$(stat -c%s "${bk}" 2>/dev/null | awk '{printf "%.1f MB", $1/1024/1024}')
        local date=$(stat -c%y "${bk}" 2>/dev/null | cut -d. -f1)
        
        # 读取元信息
        local ver="?"
        if [ -f "${BACKUP_DIR}/${name}.meta" ]; then
            ver=$(grep "^KERNEL_VERSION=" "${BACKUP_DIR}/${name}.meta" | cut -d= -f2)
        fi
        
        echo "  ${name}  (${size}, ${ver}, ${date})"
    done
}

# ============================================================
# 主入口
# ============================================================

check_root

case "${1:-status}" in
    status|stat)
        cmd_status
        ;;
    backup|bk)
        cmd_backup
        ;;
    switch|sw)
        cmd_switch "$2"
        ;;
    restore|rest|rv)
        cmd_restore
        ;;
    fetch|dl)
        cmd_fetch "$2"
        ;;
    list|ls)
        header "可用内核备份"
        cmd_list
        ;;
    help|--help|-h)
        echo "用法: $0 <command> [args]"
        echo ""
        echo "命令:"
        echo "  status             查看当前内核状态"
        echo "  backup             备份当前内核"
        echo "  switch <file>      切换到指定内核文件"
        echo "  restore            恢复上一次备份"
        echo "  fetch <URL>        从URL下载内核并切换"
        echo "  list               列出可用备份"
        echo "  help               显示此帮助"
        ;;
    *)
        error "未知命令: $1"
        echo "用法: $0 <command> [args]"
        echo "可用命令: status, backup, switch, restore, fetch, list, help"
        exit 1
        ;;
esac
