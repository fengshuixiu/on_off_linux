#!/bin/bash
#
# 开机计数（启动早期阶段）
#
# 唯一职责：把这一次开机记进计数器，并在断电前落盘。
# 与 boot_counter.sh 的分工：本脚本必须在开机最早期完成（systemd 早段单元），
# 硬件检测、耗时判定和循环重启倒计时放在启动事务结束后的晚段，因为
# 早段单元自身属于启动事务，等待"事务结束"会自锁。
#

if locale -a 2>/dev/null | grep -q 'C.UTF-8\|C.utf8'; then
    export LANG="C.UTF-8"
elif locale -a 2>/dev/null | grep -q 'en_US.UTF-8\|en_US.utf8'; then
    export LANG="en_US.UTF-8"
else
    export LANG="C"
fi
export LC_ALL="$LANG" 2>/dev/null || true

set -euo pipefail

SCRIPT_DIR="/opt/boot_monitor"
COUNTER_FILE="${SCRIPT_DIR}/boot_count.txt"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_BOOT_DIR="${LOG_DIR}/boot"
LOG_ERROR_DIR="${LOG_DIR}/error"
LOG_DMESG_DIR="${LOG_DIR}/dmesg"
COUNTED_FILE="${SCRIPT_DIR}/.last_counted_boot_id"
LOG_POINTER="${SCRIPT_DIR}/.boot_log"
DISPLAY_FLAG="${SCRIPT_DIR}/.display_pending"

mkdir -p "${SCRIPT_DIR}" "${LOG_DIR}" "${LOG_BOOT_DIR}" "${LOG_ERROR_DIR}" "${LOG_DMESG_DIR}"

# 同一时间只允许一个开机任务改计数与重启状态；缺 flock 时退化为不加锁，
# 计数仍靠 boot_id 去重，不能因为可选工具缺失而停止计数。
# BOOT_COUNTER_LOCK_HELD 由 boot_counter.sh 在 all 模式下导出：它已经占住这把锁，
# 本子进程若再 exec 9> 同一个文件会换到一个全新的锁并把自己挡在门外。
if [ "${BOOT_COUNTER_LOCK_HELD:-0}" != "1" ]; then
    if command -v flock >/dev/null 2>&1; then
        exec 9>"${SCRIPT_DIR}/.boot_counter.lock"
        flock -n 9 || { echo "启动任务已在运行，跳过重复计数"; exit 0; }
    else
        echo "提示: 未找到 flock，本次跳过并发保护"
    fi
fi

BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
if [ -n "$BOOT_ID" ] && [ "$BOOT_ID" = "$(cat "$COUNTED_FILE" 2>/dev/null || true)" ]; then
    echo "本次开机已经计数，跳过重复任务"
    exit 0
fi

[ -f "${COUNTER_FILE}" ] || { echo "0" > "${COUNTER_FILE}"; sync; }

BOOT_COUNT=$(cat "${COUNTER_FILE}")
if ! [[ "$BOOT_COUNT" =~ ^[0-9]{1,18}$ ]]; then
    echo "错误: 开机计数无效或超出范围，请通过管理工具修复" >&2
    exit 1
fi
BOOT_COUNT=$((10#$BOOT_COUNT))
if [ "$BOOT_COUNT" -ge 999999999999999999 ]; then
    echo "错误: 开机计数已达到上限" >&2
    exit 1
fi
BOOT_COUNT=$((BOOT_COUNT + 1))

# 先写计数，再写本次开机身份：中途断电时下次开机仍会补记这一次
COUNT_TMP=$(mktemp "${COUNTER_FILE}.XXXXXX")
ID_TMP=""
LOG_TMP=""
trap 'rm -f -- "${COUNT_TMP:-}" "${ID_TMP:-}" "${LOG_TMP:-}"' EXIT
printf '%s\n' "$BOOT_COUNT" > "$COUNT_TMP"
chmod 644 "$COUNT_TMP"
sync
if command -v plat_atomic_replace >/dev/null 2>&1; then
    plat_atomic_replace "$COUNT_TMP" "$COUNTER_FILE"
else
    mv -f "$COUNT_TMP" "$COUNTER_FILE"
fi

CURRENT_LOG="${LOG_BOOT_DIR}/boot_$(date +%Y%m%d_%H%M%S).log"
LOG_TMP=$(mktemp "${LOG_POINTER}.XXXXXX")
printf '%s\n' "$CURRENT_LOG" > "$LOG_TMP"
chmod 644 "$LOG_TMP"
mv -f "$LOG_TMP" "$LOG_POINTER"

if [ -n "$BOOT_ID" ]; then
    ID_TMP=$(mktemp "${COUNTED_FILE}.XXXXXX")
    printf '%s\n' "$BOOT_ID" > "$ID_TMP"
    chmod 644 "$ID_TMP"
    if command -v plat_atomic_replace >/dev/null 2>&1; then
        plat_atomic_replace "$ID_TMP" "$COUNTED_FILE"
    else
        mv -f "$ID_TMP" "$COUNTED_FILE"
    fi
fi
sync

# 登录后显示状态用的标志；晚段还没跑完时至少能看到开机次数
touch "${DISPLAY_FLAG}" 2>/dev/null || true
chmod 644 "${DISPLAY_FLAG}" 2>/dev/null || true

printf '开机计数: %s\n本次日志: %s\n' "$BOOT_COUNT" "$CURRENT_LOG"
exit 0
