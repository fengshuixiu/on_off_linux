#!/bin/bash
#
# Linux 开关机计数和硬件检测系统 - 安装脚本
# 使用方法: sudo bash install.sh
#
# 支持系统: Ubuntu, Debian, CentOS, RHEL, Fedora 等主流 Linux 发行版
# 特性: 无外部依赖，完全使用系统内部文件检测
#

# 设置字符编码环境（支持中英文字符）
if locale -a 2>/dev/null | grep -q 'C.UTF-8\|C.utf8'; then
    export LANG="C.UTF-8"
elif locale -a 2>/dev/null | grep -q 'en_US.UTF-8\|en_US.utf8'; then
    export LANG="en_US.UTF-8"
else
    export LANG="C"
fi
export LC_ALL="$LANG" 2>/dev/null || true

set -e

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then 
    echo "错误: 请使用 root 权限运行此脚本"
    echo "使用方法: sudo bash install.sh"
    exit 1
fi

echo "============================================"
echo "开关机计数和硬件检测系统 - 安装程序"
echo "============================================"
echo ""

# 创建安装目录
INSTALL_DIR="/opt/boot_monitor"
echo "[1/8] 创建安装目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/logs/boot"
mkdir -p "$INSTALL_DIR/logs/error"
mkdir -p "$INSTALL_DIR/logs/dmesg"

# 复制脚本文件
echo "[2/8] 复制脚本文件..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/boot_counter.sh" ]; then
    cp "$SCRIPT_DIR/boot_counter.sh" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/boot_counter.sh"
    echo "  ✓ boot_counter.sh 已安装"
else
    echo "  ✗ 错误: 找不到 boot_counter.sh"
    exit 1
fi

if [ -f "$SCRIPT_DIR/hardware_check.sh" ]; then
    cp "$SCRIPT_DIR/hardware_check.sh" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/hardware_check.sh"
    echo "  ✓ hardware_check.sh 已安装"
else
    echo "  ✗ 错误: 找不到 hardware_check.sh"
    exit 1
fi

if [ -f "$SCRIPT_DIR/boot_manager.sh" ]; then
    cp "$SCRIPT_DIR/boot_manager.sh" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/boot_manager.sh"
    # 创建全局命令链接
    ln -sf "$INSTALL_DIR/boot_manager.sh" /usr/local/bin/boot-manager
    echo "  ✓ boot_manager.sh 已安装"
else
    echo "  ✗ 错误: 找不到 boot_manager.sh"
    exit 1
fi

if [ -f "$SCRIPT_DIR/boot_display.sh" ]; then
    cp "$SCRIPT_DIR/boot_display.sh" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/boot_display.sh"
    echo "  ✓ boot_display.sh 已安装"
else
    echo "  ⚠ 警告: 找不到 boot_display.sh（桌面显示功能将不可用）"
fi

if [ -f "$SCRIPT_DIR/boot_status_show.sh" ]; then
    cp "$SCRIPT_DIR/boot_status_show.sh" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/boot_status_show.sh"
    echo "  ✓ boot_status_show.sh 已安装（无桌面系统用）"
else
    echo "  ⚠ 警告: 找不到 boot_status_show.sh"
fi

# 安装 systemd 服务
echo "[3/8] 安装 systemd 服务..."
if [ -f "$SCRIPT_DIR/boot-monitor.service" ]; then
    cp "$SCRIPT_DIR/boot-monitor.service" /etc/systemd/system/
    echo "  ✓ boot-monitor.service 已安装"
else
    echo "  ✗ 错误: 找不到 boot-monitor.service"
    exit 1
fi

# 安装桌面自启动文件（仅桌面环境）
echo "[4/8] 配置桌面自启动..."
if [ -f "$SCRIPT_DIR/boot-monitor-display.desktop" ]; then
    # 安装到系统级 autostart 目录
    AUTOSTART_DIR="/etc/xdg/autostart"
    if [ -d "$AUTOSTART_DIR" ] || mkdir -p "$AUTOSTART_DIR"; then
        cp "$SCRIPT_DIR/boot-monitor-display.desktop" "$AUTOSTART_DIR/"
        echo "  ✓ 桌面自启动已配置"
    else
        echo "  ⚠ 警告: 无法创建 autostart 目录"
    fi
else
    echo "  ⚠ 警告: 找不到 boot-monitor-display.desktop（桌面显示功能将不可用）"
fi

# 重新加载 systemd 并启用服务
echo "[5/8] 配置 systemd 服务..."
systemctl daemon-reload
systemctl enable boot-monitor.service
echo "  ✓ 服务已启用，将在下次开机时自动运行"

# 初始化计数器
echo "[6/8] 初始化开机计数器..."
if [ ! -f "$INSTALL_DIR/boot_count.txt" ]; then
    echo "0" > "$INSTALL_DIR/boot_count.txt"
    echo "  ✓ 计数器已初始化为 0"
else
    CURRENT_COUNT=$(cat "$INSTALL_DIR/boot_count.txt")
    echo "  ℹ 计数器已存在，当前值: $CURRENT_COUNT"
fi

# 检测系统类型
echo "[7/8] 检测系统环境..."
if [ -f /etc/os-release ]; then
    source /etc/os-release
    echo "  ✓ 系统: $NAME $VERSION"
else
    echo "  ✓ 系统: $(uname -s) $(uname -r)"
fi
echo "  ✓ 内核: $(uname -r)"
echo "  ℹ 本系统无需外部依赖，完全使用系统内部文件检测"

# 执行首次硬件检测并创建基准
echo "[8/8] 执行首次硬件检测并创建基准..."
if [ -f "$INSTALL_DIR/boot_counter.sh" ]; then
    echo "  正在检测硬件设备..."
    bash "$INSTALL_DIR/boot_counter.sh" > /dev/null 2>&1
    if [ -f "$INSTALL_DIR/hardware_baseline.txt" ]; then
        echo "  ✓ 硬件基准已创建"
        # 统计检测到的设备数量
        DEVICE_COUNT=$(grep -c "^  - " "$INSTALL_DIR/hardware_baseline.txt" 2>/dev/null || echo "0")
        echo "  ℹ 检测到 $DEVICE_COUNT 个硬件设备"
    else
        echo "  ⚠ 硬件基准创建失败"
    fi
    
    # 清理安装时生成的显示标志
    rm -f "$INSTALL_DIR/.display_pending" 2>/dev/null
else
    echo "  ✗ 错误: boot_counter.sh 不存在"
fi

# 设置目录权限，确保普通用户可读取
echo ""
echo "设置文件权限..."
chmod 755 "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR/logs" 2>/dev/null || true
chmod 755 "$INSTALL_DIR/logs/boot" 2>/dev/null || true
chmod 755 "$INSTALL_DIR/logs/error" 2>/dev/null || true
chmod 755 "$INSTALL_DIR/logs/dmesg" 2>/dev/null || true
chmod 644 "$INSTALL_DIR"/*.txt 2>/dev/null || true
chmod 644 "$INSTALL_DIR/logs/boot"/*.log 2>/dev/null || true
chmod 644 "$INSTALL_DIR/logs/error"/*.log 2>/dev/null || true
chmod 644 "$INSTALL_DIR/logs/dmesg"/*.log 2>/dev/null || true
echo "  ✓ 权限设置完成"

echo ""
echo "============================================"
echo "安装完成！"
echo "============================================"
echo ""
echo "安装位置: $INSTALL_DIR"
echo "日志目录: $INSTALL_DIR/logs/{boot,error,dmesg}"
echo "服务状态: $(systemctl is-enabled boot-monitor.service)"
echo ""
echo "可用命令:"
echo "  - 管理工具:       sudo boot-manager  (推荐)"
echo "  - 查看服务状态:   sudo systemctl status boot-monitor.service"
echo "  - 手动运行测试:   sudo $INSTALL_DIR/boot_counter.sh"
echo "  - 查看开机次数:   cat $INSTALL_DIR/boot_count.txt"
echo "  - 查看硬件基准:   cat $INSTALL_DIR/hardware_baseline.txt"
echo "  - 查看最新日志:   ls -lt $INSTALL_DIR/logs/ | head"
echo "  - 重置计数器:     echo 0 | sudo tee $INSTALL_DIR/boot_count.txt"
echo "  - 查看系统日志:   sudo journalctl -u boot-monitor.service"
echo "  - 卸载系统:       sudo boot-manager  (选择 u 选项)"
echo ""
echo -e "\033[1;32m立即使用管理工具: sudo boot-manager\033[0m"
echo ""
echo "下次系统重启时，将自动执行开机计数和硬件检测！"
echo ""
echo "提示: 运行 'sudo boot-manager' 打开管理界面"
echo "============================================"

exit 0
