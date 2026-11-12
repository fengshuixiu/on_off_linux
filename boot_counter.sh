#!/bin/bash
#
# Linux 开关机计数和硬件检测脚本
# 功能：记录开机次数，并在每次开机时执行硬件检测
#
# 作者: Auto Generated
# 日期: 2025-12-02
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

set -euo pipefail  # 严格错误处理：遇到错误立即退出

# 配置文件和日志目录
SCRIPT_DIR="/opt/boot_monitor"
COUNTER_FILE="${SCRIPT_DIR}/boot_count.txt"
LOG_DIR="${SCRIPT_DIR}/logs"

# 日志子目录（分类更清晰）
LOG_BOOT_DIR="${LOG_DIR}/boot"       # 启动日志
LOG_ERROR_DIR="${LOG_DIR}/error"     # 错误日志  
LOG_DMESG_DIR="${LOG_DIR}/dmesg"     # 系统日志

# 平台适配层（init 系统 / 日志后端 / 显示栈的差异屏蔽在这里）。
# 缺少时不中止计数：计数是本脚本最核心的职责，不能因为适配层丢了就整个失效；
# 后续调用点均以 command -v 方式容错。
if [ -f "${SCRIPT_DIR}/platform.sh" ]; then
    . "${SCRIPT_DIR}/platform.sh" || true
fi

# ==================== 阶段划分 ====================
# all    = 早段计数 + 晚段报告。非 systemd 平台的 init 脚本、手动运行用这个。
# report = 只做晚段。systemd 下由 boot-monitor-report.timer 在启动事务结束后触发。
#
# 为什么拆开：本脚本要读的 systemd-analyze 只有在启动事务结束后才有值，而早段单元
# 自身就是事务的一部分（被 multi-user.target 拉入），在早段里等事务结束等于自锁。
# 计数必须尽可能早（开机瞬间断电也要记上一次），报告可以晚到启动完成之后。
STAGE="${1:-all}"
case "$STAGE" in
    all|report) ;;
    *) echo "用法: $0 [all|report]" >&2; exit 2 ;;
esac

mkdir -p "${SCRIPT_DIR}" "${LOG_DIR}" "${LOG_BOOT_DIR}" "${LOG_ERROR_DIR}" "${LOG_DMESG_DIR}"

if [ "$STAGE" = "all" ]; then
    # 早段+晚段串行（非 systemd 平台与手动运行）。先占住计数锁，
    # 并用 BOOT_COUNTER_LOCK_HELD 告知子进程锁已持有——子进程再 exec 9> 同一文件
    # 会换到一个新锁，反而把自己挡在门外。
    if command -v flock >/dev/null 2>&1; then
        exec 9>"${SCRIPT_DIR}/.boot_counter.lock"
        flock -n 9 || { echo "开机任务已在运行，跳过重复任务"; exit 0; }
        export BOOT_COUNTER_LOCK_HELD=1
    else
        echo "提示: 未找到 flock，本次跳过并发保护"
    fi
    bash "${SCRIPT_DIR}/boot_count.sh" || { echo "错误: 开机计数阶段失败" >&2; exit 1; }
else
    # 单独跑晚段时不占计数锁：晚段只读计数值，占着锁会让循环重启期间改不了计数。
    # 报告自身的并发用独立锁挡住，避免两份报告同时写硬件基准和日志。
    if command -v flock >/dev/null 2>&1; then
        exec 7>"${SCRIPT_DIR}/.boot_report.lock"
        flock -n 7 || { echo "硬件检测与报告任务已在运行，跳过重复任务"; exit 0; }
    fi
fi

# 晚段自身的重复保护：同一 boot_id 只报告一次（timer 补触发或手动重跑都不重复写摘要）。
# 管理工具的"立即运行一次"用 BOOT_MONITOR_FORCE=1 跳过这道保护——早段计数不受影响，
# 手动运行永远不会多算一次开机。
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
REPORTED_FILE="${SCRIPT_DIR}/.last_reported_boot_id"
if [ "${BOOT_MONITOR_FORCE:-0}" != "1" ] &&
   [ -n "$BOOT_ID" ] && [ "$BOOT_ID" = "$(cat "$REPORTED_FILE" 2>/dev/null || true)" ]; then
    echo "本次开机的报告已完成，跳过重复任务"
    exit 0
fi

BOOT_COUNT=$(cat "${COUNTER_FILE}" 2>/dev/null || true)
if ! [[ "$BOOT_COUNT" =~ ^[0-9]{1,18}$ ]]; then
    echo "错误: 未找到有效开机计数，请先执行 boot_count.sh" >&2
    exit 1
fi
BOOT_COUNT=$((10#$BOOT_COUNT))

# 沿用早段建立的当日日志文件名，让两段输出进同一份日志
LOG_POINTER="${SCRIPT_DIR}/.boot_log"
POINTER_VALUE=""
[ -f "${LOG_POINTER}" ] && POINTER_VALUE=$(cat "${LOG_POINTER}" 2>/dev/null || true)

# 晚段放宽错误处理，确保硬件检测失败不会导致整个脚本退出
set +e

# 其他配置文件路径
CURRENT_LOG="${POINTER_VALUE:-${LOG_BOOT_DIR}/boot_$(date +%Y%m%d_%H%M%S).log}"   # 启动日志 -> logs/boot/
HARDWARE_LOG="${LOG_BOOT_DIR}/hardware_check.log"              # 硬件日志 -> logs/boot/
BASELINE_FILE="${SCRIPT_DIR}/hardware_baseline.txt"
CURRENT_HW_FILE="${SCRIPT_DIR}/hardware_current.txt"
ERROR_LOG="${LOG_ERROR_DIR}/error.log"                         # 错误日志 -> logs/error/
BOOT_TIME_FILE="${SCRIPT_DIR}/boot_time_baseline.txt"
DMESG_LOG="${LOG_DMESG_DIR}/dmesg.log"                         # 系统日志 -> logs/dmesg/
NORMAL_LOG="${LOG_BOOT_DIR}/normal_summary.log"                # 正常摘要 -> logs/boot/
REBOOT_COUNT_FILE="${SCRIPT_DIR}/reboot_remaining.txt"
DISPLAY_FLAG="${SCRIPT_DIR}/.display_pending"

# 检测是否为桌面版本
# 输出保留原有的显示管理器细分（对日志定位有用），并补上 wayland。
# 不能只看 DISPLAY / WAYLAND_DISPLAY：由 init 启动的本脚本继承不到用户
# 会话的环境，这两个变量必然为空，所以以 socket 与进程为准。
detect_desktop_environment() {
    # 显示管理器细分：仅 systemd 平台有这个概念
    if [ "${PLATFORM_INIT:-}" = "systemd" ]; then
        if systemctl is-active gdm &>/dev/null || systemctl is-active gdm3 &>/dev/null; then
            echo "gdm"
            return 0
        elif systemctl is-active lightdm &>/dev/null; then
            echo "lightdm"
            return 0
        elif systemctl is-active sddm &>/dev/null; then
            echo "sddm"
            return 0
        fi
    fi

    # 适配层探测（wayland / x11 / none）
    if command -v plat_detect_display >/dev/null 2>&1; then
        local backend
        backend=$(plat_detect_display || true)
        if [ -n "$backend" ] && [ "$backend" != "none" ]; then
            echo "$backend"
            return 0
        fi
    fi

    # 适配层不可用时的原有退路
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        echo "desktop"
        return 0
    fi
    echo "none"
    return 1
}

# 在桌面环境打开终端显示结果
open_terminal_with_output() {
    local output_file="$1"
    local dm_type=$(detect_desktop_environment || true)
    
    if [ "$dm_type" != "none" ]; then
        # 桌面环境，尝试打开终端
        if command -v gnome-terminal &>/dev/null; then
            gnome-terminal -- bash -c "cat '$output_file'; echo ''; echo '按回车键关闭...'; read" &
        elif command -v xterm &>/dev/null; then
            xterm -hold -e "cat '$output_file'" &
        elif command -v konsole &>/dev/null; then
            konsole -e "bash -c 'cat \"$output_file\"; echo \"\"; echo \"按回车键关闭...\"; read'" &
        elif command -v xfce4-terminal &>/dev/null; then
            xfce4-terminal -e "bash -c 'cat \"$output_file\"; echo \"\"; echo \"按回车键关闭...\"; read'" &
        elif [ "$dm_type" = "wayland" ] && command -v weston-terminal &>/dev/null; then
            # 纯 Wayland 平台（如 Buildroot + weston）上上面那些 X 终端都不存在，
            # weston-terminal 是唯一能上屏的通路。需要先把会话环境补齐。
            if command -v plat_export_wayland_env >/dev/null 2>&1 && plat_export_wayland_env; then
                # --shell 只接受可执行文件路径，不能带参数，
                # 因此把展示动作包装成一个临时脚本再交给它。
                local wrapper="${output_file}.wrapper.sh"
                {
                    echo '#!/bin/sh'
                    echo "cat '${output_file}'"
                    echo 'echo'
                    echo 'echo "按回车键关闭..."'
                    echo 'read x'
                } > "$wrapper"
                chmod +x "$wrapper"
                weston-terminal --fullscreen --shell="$wrapper" &
            fi
        fi
    fi
    # 无论是否桌面环境，都输出到控制台
    cat "$output_file"
}

# 日志轮转配置
MAX_ERROR_LOG_SIZE=10485760  # 10MB
MAX_ERROR_LOG_BACKUPS=5
MAX_DMESG_LOG_SIZE=31457280  # 30MB
MAX_DMESG_LOG_BACKUPS=20

# 错误日志函数（英文格式: [TIME] boot#N [LEVEL/TYPE] message）
log_error() {
    local level="$1"    # ERROR/WARN
    local type="$2"     # HW_LOST/HW_NEW/BOOT_SLOW/BOOT_TIME/HW_CHECK/HW_BASE/SCRIPT
    shift 2
    local message="$*"
    local log_file="${CURRENT_LOG:-boot_unknown.log}"
    local log_name=$(basename "$log_file" 2>/dev/null || echo "boot.log")
    # 格式: [YYYY-MM-DD HH:MM:SS] boot#N [LEVEL/TYPE] message | log:xxx
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] boot#${BOOT_COUNT:-0} [$level/$type] $message | log:$log_name" >> "${ERROR_LOG}"
    sync
}

# dmesg 日志抓取函数（仅在错误时调用，不重复记录错误）
capture_dmesg() {
    local reason="$1"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local dmesg_snapshot="${LOG_DMESG_DIR}/dmesg_boot${BOOT_COUNT}_${timestamp}.log"
    
    # 抓取 dmesg 日志
    if dmesg > "${dmesg_snapshot}" 2>/dev/null; then
        # 在快照文件开头添加上下文信息
        {
            echo "============================================"
            echo "错误时间: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "开机次数: ${BOOT_COUNT}"
            echo "错误原因: ${reason}"
            echo "============================================"
            echo ""
            cat "${dmesg_snapshot}"
        } > "${dmesg_snapshot}.tmp" && mv "${dmesg_snapshot}.tmp" "${dmesg_snapshot}"
        
        # 追加错误级别日志到快照
        {
            echo ""
            echo "========== dmesg 错误级别 (err) =========="
            if dmesg --level=err >/dev/null 2>&1; then
                dmesg --level=err
            else
                dmesg | grep -i -E 'error|err' || echo "[无 error 级别输出]"
            fi
            echo "========== 错误级别结束 =========="
            echo ""
        } >> "${dmesg_snapshot}"
        
        # 不再记录错误，避免重复计数
        
        # 同时追加到主 dmesg 日志
        {
            echo ""
            echo "========== dmesg 快照: ${timestamp} - 开机次数:${BOOT_COUNT} - ${reason} =========="
            cat "${dmesg_snapshot}"
            echo ""
            echo "---------- dmesg 错误级别 (err) ----------"
            if dmesg --level=err >/dev/null 2>&1; then
                dmesg --level=err
            else
                dmesg | grep -i -E 'error|err' || echo "[无 error 级别输出]"
            fi
            echo "---------- 错误级别结束 ----------"
            echo ""
            echo "========== dmesg 快照结束 =========="
            echo ""
        } >> "${DMESG_LOG}"
        
        # 轮转 dmesg 日志
        rotate_log "${DMESG_LOG}" "${MAX_DMESG_LOG_SIZE}" "${MAX_DMESG_LOG_BACKUPS}"
        sync
        
        return 0
    else
        return 1
    fi
}

# 通用日志轮转函数
# 参数: $1=日志文件路径 $2=最大大小(bytes) $3=最大备份数
rotate_log() {
    local log_file="$1"
    local max_size="$2"
    local max_backups="$3"
    
    if [ -f "${log_file}" ]; then
        local log_size=$(stat -f%z "${log_file}" 2>/dev/null || stat -c%s "${log_file}" 2>/dev/null || echo 0)
        if [ "$log_size" -gt "$max_size" ]; then
            # 删除最旧的备份
            [ -f "${log_file}.${max_backups}" ] && rm -f "${log_file}.${max_backups}"
            
            # 轮转备份文件
            for i in $(seq $((max_backups - 1)) -1 1); do
                [ -f "${log_file}.$i" ] && mv "${log_file}.$i" "${log_file}.$((i + 1))"
            done
            
            # 归档当前日志
            mv "${log_file}" "${log_file}.1"
            touch "${log_file}"
        fi
    fi
}

# 执行错误日志轮转
rotate_log "${ERROR_LOG}" "${MAX_ERROR_LOG_SIZE}" "${MAX_ERROR_LOG_BACKUPS}"

# 创建显示标志（无论桌面还是无桌面环境，登录后都会显示状态）
touch "${DISPLAY_FLAG}"
chmod 644 "${DISPLAY_FLAG}"  # 确保普通用户可读取
sync

# 记录开机时间（秒级时间戳）
BOOT_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
CURRENT_EPOCH=$(date +%s)  # 当前时间戳（秒）
LAST_BOOT_FILE="${SCRIPT_DIR}/last_boot_time.txt"  # 上次启动时间戳

# ==================== 启动耗时测量 ====================
# 口径：systemd-analyze 的完整启动时间 = 固件 + 引导器 + 内核 + 用户空间，
# 也就是"上电到启动完成"。它只在启动事务结束后有值，因此本脚本的晚段
# 必须由 timer 在事务结束后触发（本单元不参与事务），轮询等待才有意义。
# 拿不到该口径时（无 systemd、或等待超时）退回 uptime 估算并在基准里标来源，
# 两种来源之间不互相比较，来源变化时自动重建基准。
BOOT_WINDOW_SEC=600
BOOT_WAIT_MAX_SEC=${BOOT_WAIT_MAX_SEC:-60}
BOOT_POLL_SEC=2
# 判定口径：首次有效启动为基准，之后偏差超过 ±该秒数告警（变慢与变快都算）
BOOT_TIME_TOLERANCE_SEC=${BOOT_TIME_TOLERANCE_SEC:-5}

# 当前 uptime（整秒）。/proc/uptime 是单调的，不受系统时间调整影响，
# 因此优于 "date +%s 减 /proc/stat btime" 的算法。
get_uptime_sec() {
    [ -r /proc/uptime ] || return 0
    awk '{printf "%d", $1}' /proc/uptime 2>/dev/null
}

# 把 systemd-analyze 的时长串解析为整秒，无法解析则输出空。
# 兼容 "17.005s" / "1min 36.968s" / "2min 10s" / "1h 2min 3s" / "500ms"。
# 启动尚未结束时 systemd-analyze 输出的是提示文字，其中不含时长单位，
# 因此会正确地得到空值，而不会误取到句点或片段数字。
parse_systemd_duration() {
    echo "$1" | awk '
    {
        i = index($0, "= ")
        s = (i > 0) ? substr($0, i + 2) : $0
        total = 0; got = 0
        n = split(s, t, /[ \t]+/)
        for (k = 1; k <= n; k++) {
            tok = t[k]; v = tok
            if (tok ~ /^[0-9]+(\.[0-9]+)?h$/)        { sub(/h$/,   "", v); total += v * 3600; got = 1 }
            else if (tok ~ /^[0-9]+(\.[0-9]+)?min$/) { sub(/min$/, "", v); total += v * 60;   got = 1 }
            else if (tok ~ /^[0-9]+(\.[0-9]+)?ms$/)  { sub(/ms$/,  "", v); total += v / 1000; got = 1 }
            else if (tok ~ /^[0-9]+(\.[0-9]+)?s$/)   { sub(/s$/,   "", v); total += v;        got = 1 }
        }
        if (got) printf "%d", total + 0.5
    }'
}

# 测量结果同时带出来源与可信度：
#   CURRENT_BOOT_TIME  整秒，或空
#   BOOT_TIME_SOURCE   systemd-analyze | uptime | none
#   BOOT_TIME_TRUSTED  1 可用于基准建立与比对，0 仅供展示
CURRENT_BOOT_TIME=""
BOOT_TIME_SOURCE="none"
BOOT_TIME_TRUSTED=0
UPTIME_NOW=$(get_uptime_sec)

# 方法1: systemd-analyze 的完整启动时间。启动事务未结束时它只回提示语，
# 因此轮询到出现可用数值为止，最长 BOOT_WAIT_MAX_SEC；超时交给 uptime 回退。
if command -v systemd-analyze >/dev/null 2>&1; then
    BOOT_WAITED=0
    while : ; do
        ANALYZE_OUTPUT=$(systemd-analyze 2>/dev/null | head -1)
        ANALYZE_SEC=$(parse_systemd_duration "$ANALYZE_OUTPUT")
        if [ -n "$ANALYZE_SEC" ] && [ "$ANALYZE_SEC" -gt 0 ] 2>/dev/null; then
            CURRENT_BOOT_TIME="$ANALYZE_SEC"
            BOOT_TIME_SOURCE="systemd-analyze"
            BOOT_TIME_TRUSTED=1
            break
        fi
        [ "$BOOT_WAITED" -ge "$BOOT_WAIT_MAX_SEC" ] && break
        sleep "$BOOT_POLL_SEC"
        BOOT_WAITED=$((BOOT_WAITED + BOOT_POLL_SEC))
    done
    if [ -z "$CURRENT_BOOT_TIME" ]; then
        echo "等待启动事务结束超过 ${BOOT_WAIT_MAX_SEC}s，本次改用 uptime 口径"
    fi
fi

# 方法2: uptime —— 无 systemd 的平台，或 systemd 启动流程尚未结束时
if [ -z "$CURRENT_BOOT_TIME" ] && [ -n "$UPTIME_NOW" ]; then
    CURRENT_BOOT_TIME="$UPTIME_NOW"
    BOOT_TIME_SOURCE="uptime"
    if [ "$UPTIME_NOW" -le "$BOOT_WINDOW_SEC" ]; then
        BOOT_TIME_TRUSTED=1
    fi
fi

# 基准文件格式: "<整秒> <来源>"。只有同来源的数据之间才具备可比性，
# 因此来源变化时重建基准，而不是拿两种口径的数字相减。
read_baseline() {
    [ -f "${BOOT_TIME_FILE}" ] || return 0
    awk 'NR==1 {
        v = $1; src = ($2 == "") ? "unknown" : $2
        if (v ~ /^[0-9]+$/ && v + 0 > 0) print v " " src
    }' "${BOOT_TIME_FILE}" 2>/dev/null
}

write_baseline() {
    if echo "$1 $2" > "${BOOT_TIME_FILE}"; then
        sync
        return 0
    fi
    log_error "ERROR" "BOOT_TIME" "cannot write baseline"
    return 1
}

# 检查启动耗时（与基准启动时间对比，超过基准7秒报警）
TIME_WARNING=""; NORMAL_START=1
BASELINE_INT=""
if [ "$BOOT_TIME_TRUSTED" -ne 1 ]; then
    # 不在开机流程中，本次测量不写基准也不参与比对，避免污染基准
    TIME_WARNING="启动耗时: 本次运行不在开机流程中，未参与基准比对(uptime=${UPTIME_NOW:-未知}s)"
else
    BASELINE_RAW=$(read_baseline)
    BASELINE_VAL=$(echo "$BASELINE_RAW" | awk '{print $1}')
    BASELINE_SRC=$(echo "$BASELINE_RAW" | awk '{print $2}')

    if [ -z "$BASELINE_VAL" ]; then
        # 基准不存在或内容无效，两种情况统一按重建处理
        if [ -f "${BOOT_TIME_FILE}" ]; then
            log_error "WARN" "BOOT_TIME" "baseline invalid, rebuilt"
        fi
        if write_baseline "$CURRENT_BOOT_TIME" "$BOOT_TIME_SOURCE"; then
            BASELINE_INT="$CURRENT_BOOT_TIME"
            TIME_WARNING="[首次启动] 启动耗时: ${CURRENT_BOOT_TIME}秒 (来源:${BOOT_TIME_SOURCE}，已记录为基准)"
        fi
    elif [ "$BASELINE_SRC" != "$BOOT_TIME_SOURCE" ]; then
        log_error "WARN" "BOOT_TIME" "baseline source changed: ${BASELINE_SRC} -> ${BOOT_TIME_SOURCE}, rebuilt"
        if write_baseline "$CURRENT_BOOT_TIME" "$BOOT_TIME_SOURCE"; then
            BASELINE_INT="$CURRENT_BOOT_TIME"
            TIME_WARNING="启动耗时: ${CURRENT_BOOT_TIME}秒 (基准来源变更为${BOOT_TIME_SOURCE}，已重建基准)"
        fi
    else
        BASELINE_INT="$BASELINE_VAL"
        TIME_DIFF=$((CURRENT_BOOT_TIME - BASELINE_INT))
        TIME_ABS_DIFF=${TIME_DIFF#-}
        if [ "$TIME_ABS_DIFF" -gt "$BOOT_TIME_TOLERANCE_SEC" ]; then
            if [ "$TIME_DIFF" -gt 0 ]; then
                TIME_KIND="变慢"; TIME_LOG_TYPE="BOOT_SLOW"; SIGN="+"
            else
                TIME_KIND="变快"; TIME_LOG_TYPE="BOOT_FAST"; SIGN=""
            fi
            TIME_WARNING="[警告] 启动时间异常！本次:${CURRENT_BOOT_TIME}秒 基准:${BASELINE_INT}秒 差异:${SIGN}${TIME_DIFF}秒(超出基准±${BOOT_TIME_TOLERANCE_SEC}s)"
            log_error "WARN" "$TIME_LOG_TYPE" "current:${CURRENT_BOOT_TIME}s baseline:${BASELINE_INT}s diff:${TIME_DIFF}s source:${BOOT_TIME_SOURCE}"
            capture_dmesg "启动时间异常(${TIME_KIND}${TIME_ABS_DIFF}s)"
        else
            TIME_WARNING="启动耗时: ${CURRENT_BOOT_TIME}秒 (基准: ${BASELINE_INT}秒, ±${BOOT_TIME_TOLERANCE_SEC}s内正常)"
        fi
    fi
fi

# 根据时间异常标记正常状态（只有警告时才标记为异常）
if echo "$TIME_WARNING" | grep -q "警告"; then
    NORMAL_START=0
fi

# ==================== 系统时间递增校验 ====================
# 判据：本次开机时间戳不应早于上次开机时间戳。这里用一个与启动耗时无关的
# 固定小间隔做容差——启动耗时基准不能充当"两次开机的最小间隔"，否则基准值
# 越大越容易在快速重启时打出假告警。
MIN_BOOT_INTERVAL_SEC=5
TIME_VALID=1
if [ -f "${LAST_BOOT_FILE}" ]; then
    LAST_EPOCH=$(cat "${LAST_BOOT_FILE}" 2>/dev/null || echo "")
    
    # 验证数字有效性
    if [[ "$LAST_EPOCH" =~ ^[0-9]+$ ]]; then
        # 期望的最小时间: 上次启动 + 一次重启至少消耗的时间
        EXPECTED_MIN=$((LAST_EPOCH + MIN_BOOT_INTERVAL_SEC))
        
        if [ "$CURRENT_EPOCH" -lt "$EXPECTED_MIN" ] 2>/dev/null; then
            TIME_VALID=0
            TIME_DIFF_BACK=$((EXPECTED_MIN - CURRENT_EPOCH))
            echo "" | tee -a "${CURRENT_LOG}"
            echo "✗ [错误] 系统时间异常！时间可能已清零或回退" | tee -a "${CURRENT_LOG}"
            echo "  上次启动: $(date -d @$LAST_EPOCH '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo $LAST_EPOCH)" | tee -a "${CURRENT_LOG}"
            echo "  当前时间: ${BOOT_TIMESTAMP}" | tee -a "${CURRENT_LOG}"
            echo "  最小间隔: ${MIN_BOOT_INTERVAL_SEC}秒" | tee -a "${CURRENT_LOG}"
            echo "  时间差异: -${TIME_DIFF_BACK}秒 (应该 >= 上次+最小间隔)" | tee -a "${CURRENT_LOG}"
            log_error "ERROR" "TIME_BACK" "time_rollback detected: last=$LAST_EPOCH current=$CURRENT_EPOCH expected_min=$EXPECTED_MIN diff=-${TIME_DIFF_BACK}s"
            capture_dmesg "系统时间异常(回退${TIME_DIFF_BACK}秒)"
            NORMAL_START=0
        fi
    fi
fi

# 记录当前启动时间戳（用于下次校验）
echo "$CURRENT_EPOCH" > "${LAST_BOOT_FILE}"
sync

# 记录开机时间和计数
{
    echo "============================================"
    echo "开机计数: ${BOOT_COUNT}"
    echo "开机时间: ${BOOT_TIMESTAMP}"
    echo "系统信息: $(uname -a)"
    echo "运行时长: $(uptime -p 2>/dev/null || uptime 2>/dev/null)"
    if [ -n "$TIME_WARNING" ]; then
        echo "$TIME_WARNING"
    fi
    echo "============================================"
} | tee -a "${CURRENT_LOG}"
sync  # 立即保存日志

# 打印到控制台（显示在终端）
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║     Linux 开机计数与硬件检测系统 - 启动报告              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  开机次数: ${BOOT_COUNT}"
echo "  当前时间: ${BOOT_TIMESTAMP}"
echo "  $TIME_WARNING"
echo ""

# 调用硬件检测脚本 - 优化版
HW_CHECK_STATUS="未执行"

# 检查是否为第一次开机（基准文件不存在表示第一次）- 在硬件检测之前检查
IS_FIRST_BOOT=0
if [ ! -f "${BASELINE_FILE}" ]; then
    IS_FIRST_BOOT=1
fi

if [ -f "${SCRIPT_DIR}/hardware_check.sh" ]; then
    echo "开始硬件检测..." | tee -a "${CURRENT_LOG}"
    
    # 执行硬件检测并保存到临时文件，同时捕获错误（添加超时保护）
    EXIT_CODE=0
    if command -v plat_timeout >/dev/null 2>&1; then
        plat_timeout 300 bash "${SCRIPT_DIR}/hardware_check.sh" > "${CURRENT_HW_FILE}" 2>&1 || EXIT_CODE=$?
    else
        timeout 300 bash "${SCRIPT_DIR}/hardware_check.sh" > "${CURRENT_HW_FILE}" 2>&1 || EXIT_CODE=$?
    fi
    HW_REPORT_VALID=0
    if { [ "$EXIT_CODE" -eq 0 ] || [ "$EXIT_CODE" -eq 2 ]; } &&
       grep -qxF '设备标识格式: v5' "${CURRENT_HW_FILE}" &&
       grep -q '^完成时间: ' "${CURRENT_HW_FILE}" && grep -q '^  - ' "${CURRENT_HW_FILE}"; then
        HW_REPORT_VALID=1
    fi
    if [ "$EXIT_CODE" -eq 0 ] && [ "$HW_REPORT_VALID" -eq 1 ]; then
        HW_CHECK_STATUS="成功"
    else
        if [ "$EXIT_CODE" -eq 124 ] || [ "$EXIT_CODE" -eq 137 ]; then
            HW_CHECK_STATUS="超时"
            ERROR_MSG="硬件检测脚本执行超时（5分钟）"
        elif [ "$EXIT_CODE" -eq 2 ] && [ "$HW_REPORT_VALID" -eq 1 ]; then
            HW_CHECK_STATUS="异常"
            ERROR_MSG="硬件报告已完成，但传感器检测异常；继续比对设备，禁止更新基准"
        else
            HW_CHECK_STATUS="失败"
            ERROR_MSG="硬件检测失败或报告无效（退出码: $EXIT_CODE）"
        fi
        log_error "ERROR" "HW_CHECK" "$ERROR_MSG"
        capture_dmesg "硬件检测异常(退出码:$EXIT_CODE)"
        NORMAL_START=0
        echo "  ✗ 错误: $ERROR_MSG" | tee -a "${CURRENT_LOG}"
    fi
    
    # 显示检测结果（仅输出到当前日志，正常时会删除）
    cat "${CURRENT_HW_FILE}" | tee -a "${CURRENT_LOG}"
    sync
    
    # 打印硬件检测状态
    echo ""
    echo "  硬件检测状态: $HW_CHECK_STATUS"
    if [ "$HW_CHECK_STATUS" = "失败" ]; then
        echo "  ✗ 检测过程中出现错误，详情请查看: ${ERROR_LOG}"
    fi
    echo ""
    
    # 检查是否存在基准文件
    if [ "$HW_REPORT_VALID" -ne 1 ]; then
        echo "检测未成功完成，保留原基准并跳过硬件差异比对" | tee -a "${CURRENT_LOG}"
    elif [ "$HW_CHECK_STATUS" != "成功" ] && ! grep -qxF '设备标识格式: v5' "${BASELINE_FILE}" 2>/dev/null; then
        echo "检测存在异常，不创建或重建硬件基准" | tee -a "${CURRENT_LOG}"
    elif [ ! -f "${BASELINE_FILE}" ]; then
        # 首次运行，创建基准
        echo "" | tee -a "${CURRENT_LOG}"
        echo "========== 首次运行：创建硬件基准 ==========" | tee -a "${CURRENT_LOG}"
        if cp "${CURRENT_HW_FILE}" "${BASELINE_FILE}" 2>/dev/null; then
            echo "✓ 硬件基准已创建" | tee -a "${CURRENT_LOG}"
            echo "  ✓ 硬件基准文件已创建"
            sync
        else
            ERROR_MSG="无法创建硬件基准文件"
            echo "✗ 错误: $ERROR_MSG" | tee -a "${CURRENT_LOG}"
            log_error "ERROR" "HW_BASE" "$ERROR_MSG"
            capture_dmesg "创建硬件基准失败"
            NORMAL_START=0
            echo "  ✗ 错误: $ERROR_MSG"
        fi
        echo "========================================" | tee -a "${CURRENT_LOG}"
        sync  # 立即保存基准创建日志
    else
        # 基准格式校验：设备标识行的格式变更后，旧基准与新结果无法直接相减——
        # 直接比对会把所有设备同时报成丢失和新增。这种情况重建基准并记 WARN，
        # 不当作硬件故障。
        HW_FORMAT_TAG="设备标识格式: v5"
        if ! grep -qF "${HW_FORMAT_TAG}" "${BASELINE_FILE}" 2>/dev/null; then
            echo "" | tee -a "${CURRENT_LOG}"
            echo "========== 基准格式已变更：重建硬件基准 ==========" | tee -a "${CURRENT_LOG}"
            if cp "${CURRENT_HW_FILE}" "${BASELINE_FILE}" 2>/dev/null; then
                echo "✓ 旧版基准不再可比，已按本次检测结果重建" | tee -a "${CURRENT_LOG}"
                echo "  ✓ 硬件基准已重建（设备标识格式变更）"
                log_error "WARN" "HW_BASE" "baseline format outdated, rebuilt"
                sync
            else
                ERROR_MSG="无法重建硬件基准文件"
                echo "✗ 错误: $ERROR_MSG" | tee -a "${CURRENT_LOG}"
                log_error "ERROR" "HW_BASE" "$ERROR_MSG"
                NORMAL_START=0
                echo "  ✗ 错误: $ERROR_MSG"
            fi
            echo "========================================" | tee -a "${CURRENT_LOG}"
            sync
        else
        # 对比基准
        echo "" | tee -a "${CURRENT_LOG}"
        echo "========== 硬件变化检测 ==========" | tee -a "${CURRENT_LOG}"
        echo ""
        echo "  正在对比硬件配置..."
        echo ""
        
        # 提取设备列表进行对比
        extract_devices() {
            grep -E "^  - " "$1" 2>/dev/null | sort
        }
        
        BASELINE_DEVICES=$(extract_devices "${BASELINE_FILE}")
        CURRENT_DEVICES=$(extract_devices "${CURRENT_HW_FILE}")
        
        # 检查是否成功提取设备列表
        if [ -z "$BASELINE_DEVICES" ] && [ -z "$CURRENT_DEVICES" ]; then
            echo "⚠ 警告: 无法提取设备列表进行对比" | tee -a "${CURRENT_LOG}"
            echo "  基准文件和当前检测结果可能为空"
        else
            # 检测新增设备
            if [ -n "$CURRENT_DEVICES" ]; then
                NEW_DEVICES=$(comm -13 <(echo "$BASELINE_DEVICES") <(echo "$CURRENT_DEVICES") 2>/dev/null || true)
            else
                NEW_DEVICES=""
            fi
            if [ -n "$NEW_DEVICES" ]; then
                echo "✓ 新增设备:" | tee -a "${CURRENT_LOG}"
                echo "$NEW_DEVICES" | sed 's/^/  /' | tee -a "${CURRENT_LOG}"
                echo ""
                echo "  ✓ 检测到新增硬件设备"
                DEVICES_LIST=$(echo "$NEW_DEVICES" | sed 's/^  - //' | tr '\n' ',' | sed 's/,$//')
                log_error "WARN" "HW_NEW" "$DEVICES_LIST"
                capture_dmesg "新增硬件设备: $DEVICES_LIST"
                NORMAL_START=0
            fi
            
            # 检测丢失设备
            if [ -n "$BASELINE_DEVICES" ]; then
                MISSING_DEVICES=$(comm -23 <(echo "$BASELINE_DEVICES") <(echo "$CURRENT_DEVICES") 2>/dev/null || true)
            else
                MISSING_DEVICES=""
            fi
            if [ -n "$MISSING_DEVICES" ]; then
                echo "✗ 丢失设备:" | tee -a "${CURRENT_LOG}"
                echo "$MISSING_DEVICES" | sed 's/^/  /' | tee -a "${CURRENT_LOG}"
                echo ""
                echo "  ✗ 警告: 检测到硬件设备丢失！"
                DEVICES_LIST=$(echo "$MISSING_DEVICES" | sed 's/^  - //' | tr '\n' ',' | sed 's/,$//')
                log_error "ERROR" "HW_LOST" "$DEVICES_LIST"
                capture_dmesg "硬件设备丢失: $DEVICES_LIST"
                NORMAL_START=0
            fi
            
            # 如果没有变化
            if [ -z "$NEW_DEVICES" ] && [ -z "$MISSING_DEVICES" ]; then
                echo "✓ 硬件配置无变化" | tee -a "${CURRENT_LOG}"
                echo ""
                echo "  ✓ 硬件配置正常，无变化"
            fi
        fi
        
        echo "===================================" | tee -a "${CURRENT_LOG}"
        sync  # 立即保存硬件对比结果
        fi
    fi
else
    echo "警告: 硬件检测脚本不存在!" | tee -a "${CURRENT_LOG}"
    ERROR_MSG="硬件检测脚本文件不存在: ${SCRIPT_DIR}/hardware_check.sh"
    log_error "ERROR" "SCRIPT" "$ERROR_MSG"
    capture_dmesg "硬件检测脚本缺失"
    NORMAL_START=0
    echo "  ✗ 错误: 硬件检测脚本不存在"
fi

# 统计并显示错误记录
ERROR_COUNT=0
if [ -f "${ERROR_LOG}" ] && [ -s "${ERROR_LOG}" ]; then
    # 直接统计文件行数作为错误数
    ERROR_COUNT=$(wc -l < "${ERROR_LOG}" 2>/dev/null || echo "0")
    ERROR_COUNT=${ERROR_COUNT// /}  # 去除空格
fi

# 如果有错误，打印错误详情（显示最近3条）
if [ "$ERROR_COUNT" -gt 0 ] 2>/dev/null; then
    echo ""
    echo "⚠ 错误记录 (最近3条):"    
    echo "─────────────────────────────────────────────────────────────"
    # 显示最近3条错误
    tail -3 "${ERROR_LOG}"
    echo "─────────────────────────────────────────────────────────────"
fi

# 旧的摘要输出（同时记录到日志）
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    启动报告摘要                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  启动总次数: ${BOOT_COUNT}"
echo "  错误次数: ${ERROR_COUNT}"
echo "  本次开机: ${BOOT_TIMESTAMP}"
if [ -n "$HW_CHECK_STATUS" ]; then
    echo "  硬件检测: $HW_CHECK_STATUS"
fi

# 显示错误日志路径（如果有错误）
if [ "$ERROR_COUNT" -gt 0 ] 2>/dev/null; then
    echo "  ⚠ 发现 $ERROR_COUNT 条错误/警告记录"
    echo "  错误日志: ${ERROR_LOG}"
fi

# 统计 dmesg 日志（仅在有错误时才会存在）
if [ -f "${DMESG_LOG}" ] && [ -s "${DMESG_LOG}" ]; then
    DMESG_SIZE=$(du -h "${DMESG_LOG}" 2>/dev/null | awk '{print $1}')
    DMESG_SNAPSHOTS=$(find "${LOG_DMESG_DIR}" -name "dmesg_boot*.log" 2>/dev/null | wc -l)
    if [ "$DMESG_SNAPSHOTS" -gt 0 ]; then
        echo "  ⚠ 系统日志: ${DMESG_LOG} (${DMESG_SIZE}, ${DMESG_SNAPSHOTS}个错误快照)"
    fi
fi

echo "  日志文件: ${CURRENT_LOG}"
echo ""
echo "════════════════════════════════════════════════════════════"
echo ""
{
    echo ""
    echo "========== 开机报告摘要 =========="
    echo "总开机次数: ${BOOT_COUNT}"
    echo "本次开机: ${BOOT_TIMESTAMP}"
    echo "日志文件: ${CURRENT_LOG}"
    if [ -f "${ERROR_LOG}" ] && [ -s "${ERROR_LOG}" ]; then
        echo "错误日志: ${ERROR_LOG}"
    fi
    echo "=================================="
    echo ""
} | tee -a "${CURRENT_LOG}"
sync

# 清理超过30天的旧日志
find "${LOG_BOOT_DIR}" -name "boot_*.log" -mtime +30 -delete 2>/dev/null || true
# 清理超过30天的dmesg快照
find "${LOG_DMESG_DIR}" -name "dmesg_boot*.log" -mtime +30 -delete 2>/dev/null || true

# 写入完成，同步到磁盘
sync

# 显示最近5次开机记录
echo "最近5次开机记录:" | tee -a "${CURRENT_LOG}"
if ls "${LOG_BOOT_DIR}"/boot_*.log >/dev/null 2>&1; then
    ls -t "${LOG_BOOT_DIR}"/boot_*.log 2>/dev/null | head -5 | while read f; do
        stat -c '%y %n' "$f" 2>/dev/null | awk '{print $1, $2, $4}' || ls -l "$f" | awk '{print $6, $7, $9}'
    done | tee -a "${CURRENT_LOG}"
else
    echo "  (无记录)" | tee -a "${CURRENT_LOG}"
fi

echo ""

# 日志保存策略：
# - 第一次开机：保存硬件检测日志作为基准
# - 正常启动：不保存详细日志，仅记录摘要
# - 异常启动：保存详细日志 + 硬件检测结果 + dmesg
if [ "$NORMAL_START" = "1" ]; then
    # 正常启动：只记录摘要
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] boot=${BOOT_COUNT} status=OK time=${CURRENT_BOOT_TIME:-?}s src=${BOOT_TIME_SOURCE}" >> "${NORMAL_LOG}"
    sync
    
    # 非第一次开机，删除当次详细日志（节省空间）
    if [ "$IS_FIRST_BOOT" = "0" ]; then
        [ -f "${CURRENT_LOG}" ] && rm -f "${CURRENT_LOG}"
        echo "提示: 正常启动，摘要已记录"
    else
        # 第一次开机，保留基准日志
        echo "提示: 第一次开机，基准文件已保存"
    fi
else
    # 异常启动：保存详细日志
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] boot=${BOOT_COUNT} status=ERROR time=${CURRENT_BOOT_TIME:-?}s src=${BOOT_TIME_SOURCE}" >> "${NORMAL_LOG}"
    # 保存硬件检测结果到历史记录
    [ -f "${CURRENT_HW_FILE}" ] && cat "${CURRENT_HW_FILE}" >> "${HARDWARE_LOG}"
    sync
    echo ""
    echo -e "\033[1;31m⚠ 检测到异常，详细日志已保存到: ${CURRENT_LOG}\033[0m"
    echo -e "\033[1;31m⚠ 错误日志: ${ERROR_LOG}\033[0m"
fi

# 报告身份落盘放在重启倒计时之前：timer 补触发或手动重跑同一开机周期时直接跳过。
# 只在拿到 boot_id 时写；没有 boot_id 就宁可不写，也不能让下一台机器误判为已报告。
if [ -n "$BOOT_ID" ]; then
    REPORTED_TMP=$(mktemp "${REPORTED_FILE}.XXXXXX" 2>/dev/null || true)
    if [ -n "$REPORTED_TMP" ]; then
        printf '%s\n' "$BOOT_ID" > "$REPORTED_TMP"
        chmod 644 "$REPORTED_TMP"
        if command -v plat_atomic_replace >/dev/null 2>&1; then
            plat_atomic_replace "$REPORTED_TMP" "$REPORTED_FILE"
        else
            mv -f "$REPORTED_TMP" "$REPORTED_FILE"
        fi
    else
        echo "$BOOT_ID" > "$REPORTED_FILE" 2>/dev/null || true
    fi
fi

sync

# 循环重启的倒计时以“启动事务结束”为零点，而不是从定时器触发的时刻起算。
# 定时器按 OnBootSec 从内核启动计时，可能比启动完成晚十几秒触发；若从触发时刻再等
# REBOOT_DELAY_SEC 秒，每轮循环会被拉长（真机 111 实测 63s → 106s）。
# 拿不到事务结束时刻（非 systemd、尚未结束、属性不可用）时退回从当前时刻起算。
reboot_delay_remaining() {
    local want="$1" finish_us="" uptime_now finish_sec elapsed left
    [ "$want" -gt 0 ] || { echo 0; return 0; }
    if command -v systemctl >/dev/null 2>&1; then
        # 这是 Manager 的属性：systemctl show 不能带单元名，带 unit 会输出空。
        finish_us=$(systemctl show -p FinishTimestampMonotonic 2>/dev/null | tr -dc '0-9')
    fi
    if [ -z "$finish_us" ] && command -v busctl >/dev/null 2>&1; then
        finish_us=$(busctl get-property org.freedesktop.systemd1 /org/freedesktop/systemd1 \
            org.freedesktop.systemd1.Manager FinishTimestampMonotonic 2>/dev/null | tr -dc '0-9')
    fi
    # 未结束时 systemd 给 0 或 UINT64_MAX，两者都不能当成真实时刻
    if [ -z "$finish_us" ] || [ "${#finish_us}" -gt 12 ] || [ "$finish_us" -eq 0 ] 2>/dev/null; then
        echo "$want"
        return 0
    fi
    finish_sec=$((finish_us / 1000000))
    uptime_now=$(get_uptime_sec)
    if [ -z "$uptime_now" ]; then
        echo "$want"
        return 0
    fi
    elapsed=$((uptime_now - finish_sec))
    [ "$elapsed" -lt 0 ] && elapsed=0
    left=$((want - elapsed))
    [ "$left" -lt 0 ] && left=0
    echo "$left"
}

# 检查是否有剩余的自动重启次数
if [ -f "${REBOOT_COUNT_FILE}" ]; then
    if command -v flock >/dev/null 2>&1; then
        exec 8>"${SCRIPT_DIR}/.reboot_request.lock" || exit 1
        flock -n 8 || { echo "已有重启任务在等待，跳过重复请求"; exit 0; }
    fi
    REMAINING_RAW=$(cat "${REBOOT_COUNT_FILE}" 2>/dev/null || true)
    if ! [[ "$REMAINING_RAW" =~ ^[0-9]{1,18}$ ]]; then
        log_error "ERROR" "REBOOT" "invalid remaining count; automatic reboot stopped"
        exit 1
    fi
    REMAINING=$((10#$REMAINING_RAW))
    if [ "$REMAINING" -gt 0 ]; then
        NEW_REMAINING=$((REMAINING - 1))
        REBOOT_DELAY_SEC=${REBOOT_DELAY_SEC:-15}
        WAIT_LEFT=$(reboot_delay_remaining "$REBOOT_DELAY_SEC")
        
        echo ""
        echo "════════════════════════════════════════════════════════════"
        echo "自动重启测试: 剩余 ${NEW_REMAINING} 次"
        echo "系统启动完成后 ${REBOOT_DELAY_SEC} 秒重启，剩余等待 ${WAIT_LEFT} 秒..."
        echo "════════════════════════════════════════════════════════════"
        
        # 倒计时以启动事务结束为零点，给用户查看结果的时间；已过则立即重启
        [ "$WAIT_LEFT" -gt 0 ] && sleep "$WAIT_LEFT"
        if ! command -v plat_commit_reboot >/dev/null 2>&1 ||
           ! plat_commit_reboot "$SCRIPT_DIR" "$REMAINING_RAW"; then
            log_error "ERROR" "REBOOT" "reboot could not be committed; automatic reboot stopped"
            exit 1
        fi
        exit 0
    else
        # 重启完成，删除计数文件
        rm -f "${REBOOT_COUNT_FILE}"
        echo ""
        echo "════════════════════════════════════════════════════════════"
        echo "自动重启测试已完成！"
        echo "════════════════════════════════════════════════════════════"
    fi
fi

# 设置文件权限，确保普通用户可读取（用于桌面显示）
chmod 755 "${SCRIPT_DIR}" 2>/dev/null || true
chmod 755 "${LOG_DIR}" "${LOG_BOOT_DIR}" "${LOG_ERROR_DIR}" "${LOG_DMESG_DIR}" 2>/dev/null || true
chmod 644 "${SCRIPT_DIR}"/*.txt 2>/dev/null || true
chmod 644 "${LOG_BOOT_DIR}"/*.log 2>/dev/null || true
chmod 644 "${LOG_ERROR_DIR}"/*.log 2>/dev/null || true
chmod 644 "${LOG_DMESG_DIR}"/*.log 2>/dev/null || true

# 最终sync确保所有数据落盘
sync

exit 0
