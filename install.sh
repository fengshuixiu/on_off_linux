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

# 在修改系统之前检查必要的基础工具。
# systemd、flock、timeout 不是所有目标平台都有（Buildroot 例外），
# 缺失时按能力降级，不再直接拒绝安装。
for REQUIRED_COMMAND in mktemp mkdir cp chmod grep; do
    if ! command -v "$REQUIRED_COMMAND" >/dev/null 2>&1; then
        echo "错误: 缺少必要工具 $REQUIRED_COMMAND" >&2
        exit 1
    fi
done

INIT_SYSTEM="${BOOT_MONITOR_INIT:-}"
if [ -z "$INIT_SYSTEM" ]; then
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif [ -x /etc/init.d/rcS ] || [ -f /etc/init.d/rcS ]; then
        INIT_SYSTEM="busybox"
    elif [ -d /etc/rc2.d ] || [ -d /etc/rc.d ]; then
        INIT_SYSTEM="sysv"
    else
        INIT_SYSTEM="unknown"
    fi
fi
echo "检测到 init 系统: $INIT_SYSTEM"
if ! command -v flock >/dev/null 2>&1; then
    echo "  ⚠ 未找到 flock：计数仍可用，循环重启测试不可用"
fi
if ! command -v timeout >/dev/null 2>&1; then
    echo "  ⚠ 未找到 timeout：将使用内置看门狗限制硬件检测时长"
fi

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
if [ -f "$SCRIPT_DIR/platform.sh" ]; then
    . "$SCRIPT_DIR/platform.sh"
fi

if [ -f "$SCRIPT_DIR/boot_counter.sh" ]; then
    cp "$SCRIPT_DIR/boot_counter.sh" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/boot_counter.sh"
    echo "  ✓ boot_counter.sh 已安装"
else
    echo "  ✗ 错误: 找不到 boot_counter.sh"
    exit 1
fi

# 早段计数脚本：systemd 下由 boot-monitor.service 单独调用，
# 缺它就没有计数入口，因此和 boot_counter.sh 一样是必装项。
if [ -f "$SCRIPT_DIR/boot_count.sh" ]; then
    cp "$SCRIPT_DIR/boot_count.sh" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/boot_count.sh"
    echo "  ✓ boot_count.sh 已安装"
else
    echo "  ✗ 错误: 找不到 boot_count.sh"
    exit 1
fi

if [ -f "$SCRIPT_DIR/platform.sh" ]; then
    cp "$SCRIPT_DIR/platform.sh" "$INSTALL_DIR/"
    chmod 644 "$INSTALL_DIR/platform.sh"
else
    echo "  ⚠ 警告: 找不到 platform.sh，平台适配功能不可用"
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
    mkdir -p /usr/local/bin 2>/dev/null || true
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

# 安装开机启动项
if [ "$INIT_SYSTEM" = "systemd" ]; then
    echo "[3/8] 安装 systemd 服务..."
    for UNIT in boot-monitor.service boot-monitor-report.service boot-monitor-report.timer; do
        if [ -f "$SCRIPT_DIR/$UNIT" ]; then
            cp "$SCRIPT_DIR/$UNIT" /etc/systemd/system/
            echo "  ✓ $UNIT 已安装"
        else
            echo "  ✗ 错误: 找不到 $UNIT"
            exit 1
        fi
    done
else
    echo "[3/8] 安装 init.d 启动脚本..."
    if [ -f "$SCRIPT_DIR/boot-monitor.initd" ]; then
        if [ "$INIT_SYSTEM" = "busybox" ]; then
            cp "$SCRIPT_DIR/boot-monitor.initd" /etc/init.d/S99boot-monitor
            chmod +x /etc/init.d/S99boot-monitor
            echo "  ✓ /etc/init.d/S99boot-monitor 已安装"
        else
            cp "$SCRIPT_DIR/boot-monitor.initd" /etc/init.d/boot-monitor
            chmod +x /etc/init.d/boot-monitor
            echo "  ✓ /etc/init.d/boot-monitor 已安装"
        fi
    else
        echo "  ✗ 错误: 找不到 boot-monitor.initd"
        exit 1
    fi
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

# 启用开机启动
echo "[5/8] 启用开机启动..."
case "$INIT_SYSTEM" in
    systemd)
        systemctl daemon-reload
        systemctl enable boot-monitor.service
        # 晚段报告只由 timer 触发。enable 不 --now，本次开机的报告仍由下一次开机负责，
        # 免得安装完立刻跑一次，把"非开机时刻"的耗时写进基准。
        systemctl enable boot-monitor-report.timer
        echo "  ✓ 计数服务与报告定时器已启用，将在下次开机时自动运行"
        ;;
    busybox)
        chmod +x /etc/init.d/S99boot-monitor
        echo "  ✓ S99boot-monitor 已启用，将在下次开机时自动运行"
        ;;
    sysv)
        if command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d boot-monitor defaults
        else
            for RC in 2 3 4 5; do
                mkdir -p "/etc/rc${RC}.d"
                ln -sf /etc/init.d/boot-monitor "/etc/rc${RC}.d/S99boot-monitor"
            done
            for RC in 0 1 6; do
                mkdir -p "/etc/rc${RC}.d"
                ln -sf /etc/init.d/boot-monitor "/etc/rc${RC}.d/K01boot-monitor"
            done
        fi
        echo "  ✓ 服务已启用，将在下次开机时自动运行"
        ;;
    *)
        echo "  ⚠ 警告: 未识别 init 系统，启动项未启用"
        echo "  请手动将 $INSTALL_DIR/boot_counter.sh 加入开机脚本"
        ;;
esac

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
# 直接调用硬件检测生成基准，不经由 boot_counter.sh——后者会同时累加开机计数、
# 写入启动耗时基准和上次开机时间戳，而安装并不是一次真实开机。
if [ -f "$INSTALL_DIR/hardware_check.sh" ]; then
    if [ -s "$INSTALL_DIR/hardware_baseline.txt" ]; then
        echo "  ℹ 已保留现有硬件基准，如需更新请使用管理工具"
    else
        echo "  正在检测硬件设备..."
        HW_TEMP=$(mktemp "$INSTALL_DIR/.hardware_baseline.XXXXXX")
        HW_RC=0
        if command -v plat_timeout >/dev/null 2>&1; then
            plat_timeout 300 bash "$INSTALL_DIR/hardware_check.sh" > "$HW_TEMP" 2>&1 || HW_RC=$?
        elif command -v timeout >/dev/null 2>&1; then
            timeout 300 bash "$INSTALL_DIR/hardware_check.sh" > "$HW_TEMP" 2>&1 || HW_RC=$?
        else
            bash "$INSTALL_DIR/hardware_check.sh" > "$HW_TEMP" 2>&1 || HW_RC=$?
        fi
        DEVICE_COUNT=$(grep -c "^  - " "$HW_TEMP" || true)
        if [ "$HW_RC" -eq 0 ] && [ "${DEVICE_COUNT:-0}" -gt 0 ] &&
           grep -qxF '设备标识格式: v5' "$HW_TEMP"; then
            chmod 644 "$HW_TEMP"
            mv -- "$HW_TEMP" "$INSTALL_DIR/hardware_baseline.txt"
            echo "  ✓ 硬件基准已创建"
            echo "  ℹ 检测到 $DEVICE_COUNT 个硬件设备"
            sync
        else
            echo "  ⚠ 硬件检测失败、超时或结果无效（退出码: $HW_RC），基准未创建"
            rm -f -- "$HW_TEMP"
        fi
    fi
    
    # 清理可能的历史残留显示标志
    rm -f "$INSTALL_DIR/.display_pending" 2>/dev/null
else
    echo "  ✗ 错误: hardware_check.sh 不存在"
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
echo "服务状态: $(case "$INIT_SYSTEM" in
    systemd) printf '%s / timer %s' \
        "$(systemctl is-enabled boot-monitor.service 2>/dev/null)" \
        "$(systemctl is-enabled boot-monitor-report.timer 2>/dev/null)" ;;
    busybox) [ -x /etc/init.d/S99boot-monitor ] && echo enabled || echo disabled ;;
    sysv) [ -x /etc/init.d/boot-monitor ] && echo enabled || echo disabled ;;
    *) echo unknown ;;
esac)"
echo ""
echo "可用命令:"
echo "  - 管理工具:       sudo boot-manager  (推荐)"
if [ "$INIT_SYSTEM" = "systemd" ]; then
    echo "  - 查看服务状态:   sudo systemctl status boot-monitor.service boot-monitor-report.timer"
    echo "  - 查看系统日志:   sudo journalctl -u boot-monitor.service -u boot-monitor-report.service"
else
    echo "  - 查看服务状态:   sudo $( [ "$INIT_SYSTEM" = "busybox" ] && echo /etc/init.d/S99boot-monitor || echo /etc/init.d/boot-monitor ) status"
    echo "  - 查看系统日志:   sudo cat $INSTALL_DIR/logs/boot/normal_summary.log"
fi
echo "  - 手动重跑报告:   sudo $INSTALL_DIR/boot_counter.sh report   (不增加开机计数)"
echo "  - 查看开机次数:   cat $INSTALL_DIR/boot_count.txt"
echo "  - 查看硬件基准:   cat $INSTALL_DIR/hardware_baseline.txt"
echo "  - 查看最新日志:   ls -lt $INSTALL_DIR/logs/ | head"
echo "  - 重置计数器:     echo 0 | sudo tee $INSTALL_DIR/boot_count.txt"
echo "  - 卸载系统:       sudo boot-manager  (选择 u 选项)"
echo ""
echo -e "\033[1;32m立即使用管理工具: sudo boot-manager\033[0m"
echo ""
echo "下次系统重启时，将自动执行开机计数和硬件检测！"
echo ""
echo "提示: 运行 'sudo boot-manager' 打开管理界面"
echo "============================================"

exit 0
