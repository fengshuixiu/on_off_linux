#!/bin/bash
#
# 无桌面系统登录后显示开机状态
# 将此脚本添加到用户的 .bashrc 或 .profile 中
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
BOOT_TIME_FILE="${SCRIPT_DIR}/boot_time_baseline.txt"
DISPLAY_FLAG="${SCRIPT_DIR}/.display_pending"

# 检查是否需要显示（仅显示一次）
if [ ! -f "${DISPLAY_FLAG}" ]; then
    exit 0
fi

# 读取开机次数
if [ -f "$COUNTER_FILE" ]; then
    BOOT_COUNT=$(cat "$COUNTER_FILE")
else
    BOOT_COUNT="未知"
fi

# 统计错误次数
ERROR_COUNT=0
if [ -f "${ERROR_LOG}" ] && [ -s "${ERROR_LOG}" ]; then
    ERROR_COUNT=$(wc -l < "${ERROR_LOG}" 2>/dev/null || echo "0")
    ERROR_COUNT=${ERROR_COUNT// /}
fi

# 读取启动时间信息（基准文件格式: "<整秒> <来源>"）
BOOT_TIME_INFO=""
if [ -f "${BOOT_TIME_FILE}" ]; then
    BASELINE=$(awk 'NR==1 {print $1}' "${BOOT_TIME_FILE}" 2>/dev/null)
    BASELINE_SRC=$(awk 'NR==1 {print $2}' "${BOOT_TIME_FILE}" 2>/dev/null)
    if [ -n "$BASELINE" ]; then
        BOOT_TIME_INFO="基准启动时间: ${BASELINE}秒"
        [ -n "$BASELINE_SRC" ] && BOOT_TIME_INFO="${BOOT_TIME_INFO} (来源: ${BASELINE_SRC})"
    fi
fi

# 显示状态
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║     Linux 开机计数与硬件检测系统 - 启动状态              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  启动总次数: ${BOOT_COUNT}"
echo "  错误次数: ${ERROR_COUNT}"
echo "  当前时间: $(date '+%Y-%m-%d %H:%M:%S')"
if [ -n "$BOOT_TIME_INFO" ]; then
    echo "  $BOOT_TIME_INFO"
fi
echo ""

# 显示最近状态
if [ -f "${NORMAL_LOG}" ]; then
    LAST_STATUS=$(tail -1 "${NORMAL_LOG}" 2>/dev/null)
    if [ -n "$LAST_STATUS" ]; then
        echo "  最近状态: $LAST_STATUS"
        echo ""
    fi
fi

# 如果有错误，显示最近3条
if [ -f "${ERROR_LOG}" ] && [ -s "${ERROR_LOG}" ] && [ "$ERROR_COUNT" -gt 0 ]; then
    echo "  ⚠ 错误记录 (最近3条)："
    echo "  ─────────────────────────────────────────────────────────"
    # 显示3条错误
    tail -3 "${ERROR_LOG}" | while read line; do
        echo "  $line"
    done
    echo "  ─────────────────────────────────────────────────────────"
    echo ""
else
    echo "  ✓ 系统状态正常"
    echo ""
fi

echo "════════════════════════════════════════════════════════════"
echo ""

# 清除显示标志（只显示一次）
rm -f "${DISPLAY_FLAG}"
sync

exit 0
