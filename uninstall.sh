#!/bin/bash
#
# Linux 开关机计数和硬件检测系统 - 卸载脚本
# 使用方法: sudo bash uninstall.sh
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
    echo "使用方法: sudo bash uninstall.sh"
    exit 1
fi

# 配置
INSTALL_DIR="/opt/boot_monitor"
SERVICE_NAME="boot-monitor.service"

echo "============================================"
echo "开关机计数和硬件检测系统 - 卸载程序"
echo "============================================"
echo ""

# 检查是否已安装
if [ ! -d "$INSTALL_DIR" ]; then
    echo "系统未安装或已被卸载"
    exit 0
fi

echo -e "\033[0;31m警告: 此操作将完全删除开机计数系统！\033[0m"
echo ""
echo "将删除以下内容:"
echo "  - systemd 服务"
echo "  - 所有脚本文件"
echo "  - 所有日志文件"
echo "  - 开机计数数据"
echo "  - 硬件基准数据"
echo ""
echo "安装目录: $INSTALL_DIR"
echo ""
echo -n "确认卸载? 输入 'YES' 继续: "
read CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo ""
    echo "卸载已取消"
    exit 0
fi

echo ""
echo "正在卸载..."
echo ""

# 1. 停止并禁用服务
echo "[1/7] 停止服务..."
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
echo "  ✓ 服务已停止"

# 2. 删除服务文件
echo "[2/7] 删除服务文件..."
rm -f "/etc/systemd/system/$SERVICE_NAME"
systemctl daemon-reload
echo "  ✓ 服务文件已删除"

# 3. 删除全局命令
echo "[3/7] 删除全局命令..."
rm -f /usr/local/bin/boot-manager
echo "  ✓ 全局命令已删除"

# 4. 删除桌面自启动文件
echo "[4/7] 删除桌面自启动文件..."
rm -f /etc/xdg/autostart/boot-monitor-display.desktop
echo "  ✓ 桌面自启动文件已删除"

# 5. 清理 Getty 自动登录配置
echo "[5/7] 清理 Getty 自动登录配置..."
GETTY_OVERRIDE="/etc/systemd/system/getty@tty1.service.d/override.conf"
if [ -f "$GETTY_OVERRIDE" ]; then
    rm -f "$GETTY_OVERRIDE"
    rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
    systemctl daemon-reload
    echo "  ✓ Getty 自动登录配置已清理"
else
    echo "  - Getty 自动登录未配置，跳过"
fi

# 6. 清理用户 .bashrc 中的配置
echo "[6/7] 清理用户配置..."
for USER_HOME in /home/* /root; do
    BASHRC="$USER_HOME/.bashrc"
    if [ -f "$BASHRC" ] && grep -q "boot_status_show.sh" "$BASHRC"; then
        sed -i '/# 开机状态显示/d' "$BASHRC" 2>/dev/null || true
        sed -i '/boot_status_show.sh/d' "$BASHRC" 2>/dev/null || true
        echo "  ✓ 已清理 $BASHRC"
    fi
done

# 7. 删除安装目录
echo "[7/7] 删除安装目录..."
rm -rf "$INSTALL_DIR"
echo "  ✓ 安装目录已删除"

# 完成
echo ""
echo "清理完成"

echo ""
echo "============================================"
echo "卸载完成！"
echo "============================================"
echo ""
echo "系统已完全删除，感谢使用！"
echo ""

exit 0
