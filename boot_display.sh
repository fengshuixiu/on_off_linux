#!/bin/bash
#
# 桌面环境启动后显示开机状态
# 此脚本由桌面环境的 autostart 调用
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

SCRIPT_DIR="/opt/boot_monitor"
LOG_DIR="${SCRIPT_DIR}/logs"
COUNTER_FILE="${SCRIPT_DIR}/boot_count.txt"
NORMAL_LOG="${LOG_DIR}/boot/normal_summary.log"
ERROR_LOG="${LOG_DIR}/error/error.log"
DISPLAY_FLAG="${SCRIPT_DIR}/.display_pending"

# 检查是否需要显示（由 boot_counter.sh 设置标志）
if [ ! -f "${DISPLAY_FLAG}" ]; then
    exit 0
fi

# 等待桌面环境完全加载
sleep 3

# 读取开机次数
if [ -f "$COUNTER_FILE" ]; then
    BOOT_COUNT=$(cat "$COUNTER_FILE")
else
    BOOT_COUNT="未知"
fi

# 读取最近的启动状态
LAST_STATUS=""
if [ -f "${NORMAL_LOG}" ]; then
    LAST_STATUS=$(tail -1 "${NORMAL_LOG}" 2>/dev/null)
fi

# 检查是否有错误并统计错误次数
ERROR_COUNT=0
HAS_ERROR=0
if [ -f "${ERROR_LOG}" ] && [ -s "${ERROR_LOG}" ]; then
    ERROR_COUNT=$(wc -l < "${ERROR_LOG}" 2>/dev/null || echo "0")
    ERROR_COUNT=${ERROR_COUNT// /}
    RECENT_ERROR=$(tail -3 "${ERROR_LOG}" 2>/dev/null)
    if [ -n "$RECENT_ERROR" ]; then
        HAS_ERROR=1
    fi
fi

# 构建显示内容
OUTPUT_FILE="/tmp/boot_status_$$.txt"
{
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║     Linux 开机计数与硬件检测系统 - 启动状态              ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  启动总次数: ${BOOT_COUNT}"
    echo "  错误次数: ${ERROR_COUNT}"
    echo "  启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    if [ -n "$LAST_STATUS" ]; then
        echo "  最近状态: $LAST_STATUS"
        echo ""
    fi
    
    if [ $HAS_ERROR -eq 1 ]; then
        echo "  ⚠ 错误记录 (最近3条)："
        echo "  ─────────────────────────────────────────────────"
        # 显示3条错误
        tail -3 "${ERROR_LOG}" | while read -r line; do
            echo "  $line"
        done
        echo "  ─────────────────────────────────────────────────"
        echo ""
    else
        echo "  ✓ 系统状态正常"
        echo ""
    fi
    
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "按回车键关闭此窗口..."
} > "${OUTPUT_FILE}"

# 尝试在终端中显示
open_terminal() {
    if command -v gnome-terminal &>/dev/null; then
        gnome-terminal --title="开机状态" -- bash -c "cat '${OUTPUT_FILE}'; read; rm -f '${OUTPUT_FILE}'"
    elif command -v xfce4-terminal &>/dev/null; then
        xfce4-terminal --title="开机状态" -e "bash -c 'cat \"${OUTPUT_FILE}\"; read; rm -f \"${OUTPUT_FILE}\"'"
    elif command -v konsole &>/dev/null; then
        konsole --title "开机状态" -e bash -c "cat '${OUTPUT_FILE}'; read; rm -f '${OUTPUT_FILE}'"
    elif command -v lxterminal &>/dev/null; then
        lxterminal --title="开机状态" -e "bash -c 'cat \"${OUTPUT_FILE}\"; read; rm -f \"${OUTPUT_FILE}\"'"
    elif command -v mate-terminal &>/dev/null; then
        mate-terminal --title="开机状态" -e "bash -c 'cat \"${OUTPUT_FILE}\"; read; rm -f \"${OUTPUT_FILE}\"'"
    elif command -v xterm &>/dev/null; then
        xterm -title "开机状态" -hold -e "cat '${OUTPUT_FILE}'"
    else
        # 使用 zenity 或 notify-send 作为备选
        if command -v zenity &>/dev/null; then
            zenity --text-info --title="开机状态" --filename="${OUTPUT_FILE}" --width=600 --height=400
            rm -f "${OUTPUT_FILE}"
        elif command -v notify-send &>/dev/null; then
            notify-send "开机状态" "开机次数: ${BOOT_COUNT}\n状态: 正常" --icon=dialog-information
            rm -f "${OUTPUT_FILE}"
        fi
    fi
}

# 执行显示
open_terminal &

# 清除显示标志（尝试普通删除，失败则用 sudo）
rm -f "${DISPLAY_FLAG}" 2>/dev/null || sudo rm -f "${DISPLAY_FLAG}" 2>/dev/null || true
sync

exit 0
