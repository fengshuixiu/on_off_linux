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

# ==================== 立即执行计数（最关键，确保断电也能记录） ====================
# 创建必要的目录
mkdir -p "${SCRIPT_DIR}" "${LOG_DIR}" "${LOG_BOOT_DIR}" "${LOG_ERROR_DIR}" "${LOG_DMESG_DIR}"

# 初始化计数器文件
if [ ! -f "${COUNTER_FILE}" ]; then
    echo "0" > "${COUNTER_FILE}"
    sync
fi

# 读取当前计数
BOOT_COUNT=$(cat "${COUNTER_FILE}" 2>/dev/null || echo "0")
if ! [[ "$BOOT_COUNT" =~ ^[0-9]+$ ]]; then
    BOOT_COUNT=0
fi

# 增加计数
BOOT_COUNT=$((BOOT_COUNT + 1))

# 立即保存新计数（原子操作：先写临时文件再 mv）
echo "${BOOT_COUNT}" > "${COUNTER_FILE}.tmp"
sync  # 确保临时文件落盘
mv "${COUNTER_FILE}.tmp" "${COUNTER_FILE}"
sync  # 确保 mv 操作落盘
# ==================== 计数完成，以上操作必须在毫秒级完成 ====================

# 计数完成后放宽错误处理，确保硬件检测失败不会导致整个脚本退出
set +e

# 其他配置文件路径
CURRENT_LOG="${LOG_BOOT_DIR}/boot_$(date +%Y%m%d_%H%M%S).log"   # 启动日志 -> logs/boot/
HARDWARE_LOG="${LOG_BOOT_DIR}/hardware_check.log"              # 硬件日志 -> logs/boot/
BASELINE_FILE="${SCRIPT_DIR}/hardware_baseline.txt"
CURRENT_HW_FILE="${SCRIPT_DIR}/hardware_current.txt"
ERROR_LOG="${LOG_ERROR_DIR}/error.log"                         # 错误日志 -> logs/error/
BOOT_TIME_FILE="${SCRIPT_DIR}/boot_time_baseline.txt"
DMESG_LOG="${LOG_DMESG_DIR}/dmesg.log"                         # 系统日志 -> logs/dmesg/
NORMAL_LOG="${LOG_BOOT_DIR}/normal_summary.log"                # 正常摘要 -> logs/boot/
REBOOT_COUNT_FILE="${SCRIPT_DIR}/reboot_remaining.txt"
DISPLAY_FLAG="${SCRIPT_DIR}/.display_pending"

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
        local log_size=$(stat -c%s "${log_file}" 2>/dev/null || stat -f%z "${log_file}" 2>/dev/null || echo 0)
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

# 获取实际启动耗时（从开机到系统就绪）
get_boot_time() {
    local boot_time=""
    
    # 方法1: 使用 systemd-analyze （最准确）
    if command -v systemd-analyze &>/dev/null; then
        # 获取总启动时间（秒）- 兼容多种格式
        local analyze_output=$(systemd-analyze 2>/dev/null | head -1)
        # 尝试提取数字（如 "25.123s")
        boot_time=$(echo "$analyze_output" | sed -n 's/.*= \([0-9.]*\)s.*/\1/p')
        if [ -z "$boot_time" ]; then
            # 备用格式: 提取最后一个时间数字
            boot_time=$(echo "$analyze_output" | grep -o '[0-9]*\.[0-9]*s' | tail -1 | tr -d 's')
        fi
        if [ -z "$boot_time" ]; then
            # 再备用：只提取数字
            boot_time=$(echo "$analyze_output" | grep -o '[0-9]*\.[0-9]*' | tail -1)
        fi
    fi
    
    # 方法2: 使用 /proc/stat 中的 btime 和当前时间计算
    if [ -z "$boot_time" ] && [ -f /proc/stat ]; then
        local btime=$(grep '^btime' /proc/stat | awk '{print $2}')
        if [ -n "$btime" ]; then
            local now=$(date +%s)
            boot_time=$((now - btime))
        fi
    fi
    
    # 方法3: 使用 uptime
    if [ -z "$boot_time" ] && [ -f /proc/uptime ]; then
        boot_time=$(awk '{print int($1)}' /proc/uptime)
    fi
    
    echo "${boot_time:-0}"
}

# 获取启动耗时
CURRENT_BOOT_TIME=$(get_boot_time)

# 检查启动耗时（与基准启动时间对比，超过基准7秒报警）
TIME_WARNING=""; NORMAL_START=1
if [ ! -f "${BOOT_TIME_FILE}" ]; then
    # 首次启动，记录基准启动时间
    if echo "${CURRENT_BOOT_TIME}" > "${BOOT_TIME_FILE}"; then
        TIME_WARNING="[首次启动] 启动耗时: ${CURRENT_BOOT_TIME}秒 (已记录为基准)"
        sync
    else
        log_error "ERROR" "BOOT_TIME" "cannot create baseline"
    fi
else
    # 读取基准时间（容错处理）
    if BASELINE_BOOT_TIME=$(cat "${BOOT_TIME_FILE}" 2>/dev/null); then
        # 验证是否为数字
        if [[ "$BASELINE_BOOT_TIME" =~ ^[0-9.]+$ ]]; then
            BASELINE_INT=${BASELINE_BOOT_TIME%.*}
            CURRENT_INT=${CURRENT_BOOT_TIME%.*}
            TIME_DIFF=$((CURRENT_INT - BASELINE_INT))
            
            # 检查启动耗时是否比基准大7秒以上
            if [ "$TIME_DIFF" -gt 7 ]; then
                TIME_WARNING="[警告] 启动时间异常！本次:${CURRENT_BOOT_TIME}秒 基准:${BASELINE_INT}秒 差异:+${TIME_DIFF}秒(超过基准7s)"
                log_error "WARN" "BOOT_SLOW" "current:${CURRENT_BOOT_TIME}s baseline:${BASELINE_INT}s diff:+${TIME_DIFF}s"
                capture_dmesg "启动时间异常(+${TIME_DIFF}s)"
            else
                TIME_WARNING="启动耗时: ${CURRENT_BOOT_TIME}秒 (基准: ${BASELINE_INT}秒, 正常)"
            fi
        else
            log_error "WARN" "BOOT_TIME" "baseline corrupted, recreated"
            echo "${CURRENT_BOOT_TIME}" > "${BOOT_TIME_FILE}"
            sync
        fi
    else
        if [ -f "${ERROR_LOG}" ]; then
            log_error "ERROR" "BOOT_TIME" "cannot read baseline"
        fi
    fi
fi

# 根据时间异常标记正常状态（只有警告时才标记为异常）
if echo "$TIME_WARNING" | grep -q "警告"; then
    NORMAL_START=0
fi

# ==================== 系统时间递增校验 ====================
# 检查当前时间是否 >= 上次启动时间 + 基准启动时间
if [ -f "${LAST_BOOT_FILE}" ] && [ -f "${BOOT_TIME_FILE}" ]; then
    LAST_EPOCH=$(cat "${LAST_BOOT_FILE}" 2>/dev/null || echo "0")
    BASELINE_TIME=$(cat "${BOOT_TIME_FILE}" 2>/dev/null || echo "30")
    BASELINE_INT=${BASELINE_TIME%.*}
    
    # 验证数字有效性
    if [[ "$LAST_EPOCH" =~ ^[0-9]+$ ]] && [[ "$BASELINE_INT" =~ ^[0-9]+$ ]]; then
        # 期望的最小时间: 上次启动 + 基准启动时间
        EXPECTED_MIN=$((LAST_EPOCH + BASELINE_INT))
        
        if [ "$CURRENT_EPOCH" -lt "$EXPECTED_MIN" ] 2>/dev/null; then
            TIME_DIFF_BACK=$((EXPECTED_MIN - CURRENT_EPOCH))
            echo "" | tee -a "${CURRENT_LOG}"
            echo "✗ [错误] 系统时间异常！时间可能已清零或回退" | tee -a "${CURRENT_LOG}"
            echo "  上次启动: $(date -d @$LAST_EPOCH '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo $LAST_EPOCH)" | tee -a "${CURRENT_LOG}"
            echo "  当前时间: ${BOOT_TIMESTAMP}" | tee -a "${CURRENT_LOG}"
            echo "  基准启动: ${BASELINE_INT}秒" | tee -a "${CURRENT_LOG}"
            echo "  时间差异: -${TIME_DIFF_BACK}秒 (应该 >= 上次+基准)" | tee -a "${CURRENT_LOG}"
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
    echo "运行时长: $(uptime -p)"
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
    if timeout 300 bash "${SCRIPT_DIR}/hardware_check.sh" > "${CURRENT_HW_FILE}" 2>&1; then
        HW_CHECK_STATUS="成功"
    else
        EXIT_CODE=$?
        if [ $EXIT_CODE -eq 124 ]; then
            HW_CHECK_STATUS="超时"
            ERROR_MSG="硬件检测脚本执行超时（5分钟）"
        else
            HW_CHECK_STATUS="失败"
            ERROR_MSG="硬件检测脚本执行失败（退出码: $EXIT_CODE）"
        fi
        log_error "ERROR" "HW_CHECK" "$ERROR_MSG"
        capture_dmesg "硬件检测失败(退出码:$EXIT_CODE)"
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
    if [ ! -f "${BASELINE_FILE}" ]; then
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
        # 对比基准
        echo "" | tee -a "${CURRENT_LOG}"
        echo "========== 硬件变化检测 ==========" | tee -a "${CURRENT_LOG}"
        echo ""
        echo "  正在对比硬件配置..."
        echo ""
        
        # 提取设备列表进行对比
        extract_devices() {
            grep -E "^  - " "$1" 2>/dev/null | sort | uniq
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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] boot=${BOOT_COUNT} status=OK time=${CURRENT_BOOT_TIME}s" >> "${NORMAL_LOG}"
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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] boot=${BOOT_COUNT} status=ERROR time=${CURRENT_BOOT_TIME}s" >> "${NORMAL_LOG}"
    # 保存硬件检测结果到历史记录
    [ -f "${CURRENT_HW_FILE}" ] && cat "${CURRENT_HW_FILE}" >> "${HARDWARE_LOG}"
    sync
    echo ""
    echo -e "\033[1;31m⚠ 检测到异常，详细日志已保存到: ${CURRENT_LOG}\033[0m"
    echo -e "\033[1;31m⚠ 错误日志: ${ERROR_LOG}\033[0m"
fi

sync

# 检查是否有剩余的自动重启次数
if [ -f "${REBOOT_COUNT_FILE}" ]; then
    REMAINING=$(cat "${REBOOT_COUNT_FILE}" 2>/dev/null || echo "0")
    if [ "$REMAINING" -gt 0 ] 2>/dev/null; then
        NEW_REMAINING=$((REMAINING - 1))
        echo "$NEW_REMAINING" > "${REBOOT_COUNT_FILE}"
        sync
        
        echo ""
        echo "════════════════════════════════════════════════════════════"
        echo "自动重启测试: 剩余 ${NEW_REMAINING} 次"
        echo "15秒后将自动重启..."
        echo "════════════════════════════════════════════════════════════"
        
        # 等待15秒后重启（给用户足够时间查看信息）
        sleep 15
        reboot
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
