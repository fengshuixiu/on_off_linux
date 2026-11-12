#!/bin/bash
#
# Linux 开关机计数管理工具
# 提供交互式菜单进行各项管理操作
#
# 功能：查看计数、设置计数、查看日志、清理日志、硬件检测等
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

# 配置路径
SCRIPT_DIR="/opt/boot_monitor"
COUNTER_FILE="${SCRIPT_DIR}/boot_count.txt"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_BOOT_DIR="${LOG_DIR}/boot"
LOG_ERROR_DIR="${LOG_DIR}/error"
LOG_DMESG_DIR="${LOG_DIR}/dmesg"
BASELINE_FILE="${SCRIPT_DIR}/hardware_baseline.txt"
ERROR_LOG="${LOG_ERROR_DIR}/error.log"
DMESG_LOG="${LOG_DMESG_DIR}/dmesg.log"
REBOOT_COUNT_FILE="${SCRIPT_DIR}/reboot_remaining.txt"
SERVICE_NAME="boot-monitor.service"
# systemd 把开机流程拆成两段：早段只计数，晚段报告由 timer 触发。
# 服务管理必须成对处理，否则会出现"计数已禁用、报告仍在跑"的半卸载状态。
REPORT_SERVICE_NAME="boot-monitor-report.service"
REPORT_TIMER_NAME="boot-monitor-report.timer"
if [ -f "${SCRIPT_DIR}/platform.sh" ]; then
    . "${SCRIPT_DIR}/platform.sh"
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 检查是否安装
check_installation() {
    if [ ! -d "$SCRIPT_DIR" ]; then
        echo -e "${RED}错误: 系统未安装！${NC}"
        echo "请先运行安装脚本: sudo bash install.sh"
        exit 1
    fi
}

# 用户认证函数（已移除，因为使用 sudo 运行已经是认证）
# 如果需要系统自动登录，请使用菜单中的"配置自动登录"选项

# 显示标题
show_header() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      ${BOLD}Linux 开关机计数与硬件检测管理系统${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# 显示当前状态
show_status() {
    if [ -f "$COUNTER_FILE" ]; then
        BOOT_COUNT=$(cat "$COUNTER_FILE")
    else
        BOOT_COUNT="未初始化"
    fi
    
    # 检查服务状态
    if command -v plat_service_enabled >/dev/null 2>&1; then
        if plat_service_enabled "$SERVICE_NAME"; then
            SERVICE_STATUS="${GREEN}已启用${NC}"
        else
            SERVICE_STATUS="${RED}未启用${NC}"
        fi
    elif systemctl is-enabled "$SERVICE_NAME" &>/dev/null; then
        SERVICE_STATUS="${GREEN}已启用${NC}"
    else
        SERVICE_STATUS="${RED}未启用${NC}"
    fi
    
    # 统计日志数量
    if [ -d "$LOG_BOOT_DIR" ]; then
        LOG_COUNT=$(ls -1 "$LOG_BOOT_DIR"/boot_*.log 2>/dev/null | wc -l)
    else
        LOG_COUNT=0
    fi
    if [ -d "$LOG_DMESG_DIR" ]; then
        DMESG_COUNT=$(ls -1 "$LOG_DMESG_DIR"/dmesg_boot*.log 2>/dev/null | wc -l)
    else
        DMESG_COUNT=0
    fi
    
    echo -e "${BLUE}【当前状态】${NC}"
    echo -e "  开机次数: ${YELLOW}${BOOT_COUNT}${NC}"
    echo -e "  服务状态: ${SERVICE_STATUS}"
    echo -e "  开机日志: ${YELLOW}${LOG_COUNT}${NC} 个"
    if [ $DMESG_COUNT -gt 0 ]; then
        echo -e "  错误快照: ${RED}${DMESG_COUNT}${NC} 个 (dmesg)"
    fi
    echo -e "  安装路径: ${SCRIPT_DIR}"
    echo ""
}

# 显示主菜单
show_menu() {
    echo -e "${BLUE}【主菜单】${NC}"
    echo "  1) 查看开机次数"
    echo "  2) 设置开机次数"
    echo "  3) 重置开机次数"
    echo "  4) 立即执行硬件检测"
    echo "  5) 查看最新日志"
    echo "  6) 查看历史日志列表"
    echo "  7) 清理日志文件"
    echo "  8) 服务管理"
    echo "  9) 系统信息"
    echo "  d) 查看系统日志(dmesg)"
    echo "  e) 查看错误日志"
    echo "  a) 配置自动登录"
    echo "  r) 指定次数重启系统"
    echo "  u) 卸载系统"
    echo "  0) 退出"
    echo ""
    echo -ne "${CYAN}请选择操作 [0-9/d/e/a/r/u]: ${NC}"
}

# 1. 查看开机次数
view_boot_count() {
    show_header
    echo -e "${BLUE}【查看开机次数】${NC}"
    echo ""
    
    if [ -f "$COUNTER_FILE" ]; then
        BOOT_COUNT=$(cat "$COUNTER_FILE")
        echo -e "  当前开机次数: ${GREEN}${BOOT_COUNT}${NC}"
        echo ""
        
        # 显示最近一次开机时间
        LATEST_LOG=$(ls -t "$LOG_BOOT_DIR"/boot_*.log 2>/dev/null | head -1)
        if [ -n "$LATEST_LOG" ]; then
            echo "  最近一次开机记录:"
            grep "开机时间:" "$LATEST_LOG" 2>/dev/null | sed 's/^/    /'
            grep "运行时长:" "$LATEST_LOG" 2>/dev/null | sed 's/^/    /'
        fi
    else
        echo -e "  ${RED}计数器文件不存在${NC}"
    fi
    
    echo ""
    read -p "按回车键返回..." dummy
}

# 管理操作与开机任务共用锁；替换成功后才报告写入成功。
save_boot_count() (
    local tmp
    [ ! -d "$COUNTER_FILE" ] || return 1
    if command -v flock >/dev/null 2>&1; then
        exec 9>"${SCRIPT_DIR}/.boot_counter.lock" || return 1
        flock -n 9 || { echo "启动检测正在运行，请稍后修改计数" >&2; return 1; }
    fi
    tmp=$(mktemp "${COUNTER_FILE}.XXXXXX") || return 1
    trap 'rm -f -- "$tmp"' EXIT
    printf '%s\n' "$1" > "$tmp" && chmod 644 "$tmp" || return 1
    if command -v plat_atomic_replace >/dev/null 2>&1; then
        plat_atomic_replace "$tmp" "$COUNTER_FILE" && sync
    else
        mv -f "$tmp" "$COUNTER_FILE" && sync
    fi
)

# 2. 设置开机次数
set_boot_count() {
    show_header
    echo -e "${BLUE}【设置开机次数】${NC}"
    echo ""
    
    if [ -f "$COUNTER_FILE" ]; then
        CURRENT_COUNT=$(cat "$COUNTER_FILE")
        echo -e "  当前开机次数: ${YELLOW}${CURRENT_COUNT}${NC}"
    else
        CURRENT_COUNT=0
        echo -e "  ${YELLOW}计数器未初始化${NC}"
    fi
    
    echo ""
    echo -ne "  请输入新的开机次数 (输入 0 取消): "
    read NEW_COUNT
    
    # 验证输入
    if ! [[ "$NEW_COUNT" =~ ^[0-9]{1,18}$ ]]; then
        echo -e "  ${RED}错误: 请输入不超过18位的非负整数${NC}"
        sleep 2
        return
    fi
    
    NEW_COUNT=$((10#$NEW_COUNT))
    if [ "$NEW_COUNT" -eq 0 ]; then
        echo "  操作已取消"
        sleep 1
        return
    fi
    
    # 保存新值
    if ! save_boot_count "$NEW_COUNT"; then
        echo "错误: 无法保存开机次数" >&2
        return 1
    fi
    echo -e "  ${GREEN}✓ 开机次数已设置为: ${NEW_COUNT}${NC}"
    
    echo ""
    read -p "按回车键返回..." dummy
}

# 3. 重置开机次数
reset_boot_count() {
    show_header
    echo -e "${BLUE}【重置开机次数】${NC}"
    echo ""
    
    if [ -f "$COUNTER_FILE" ]; then
        CURRENT_COUNT=$(cat "$COUNTER_FILE")
        echo -e "  当前开机次数: ${YELLOW}${CURRENT_COUNT}${NC}"
    fi
    
    echo ""
    echo -e "  ${YELLOW}警告: 此操作将把开机次数重置为 0${NC}"
    echo -ne "  确认重置? (y/N): "
    read CONFIRM
    
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        if ! save_boot_count 0; then
            echo "错误: 无法重置开机次数" >&2
            return 1
        fi
        echo -e "  ${GREEN}✓ 开机次数已重置为 0${NC}"
    else
        echo "  操作已取消"
    fi
    
    echo ""
    read -p "按回车键返回..." dummy
}

# 4. 立即执行硬件检测
run_hardware_check() (
    if command -v flock >/dev/null 2>&1; then
        exec 9>"${SCRIPT_DIR}/.boot_counter.lock" || return 1
        flock -n 9 || { echo "启动检测正在运行，请稍后重试" >&2; return 1; }
    fi
    show_header
    echo -e "${BLUE}【硬件检测】${NC}"
    echo ""
    
    local BASELINE_FILE="${SCRIPT_DIR}/hardware_baseline.txt"
    local CURRENT_HW_FILE="${SCRIPT_DIR}/hardware_current.txt"
    
    if [ ! -f "${SCRIPT_DIR}/hardware_check.sh" ]; then
        echo -e "${RED}错误: 硬件检测脚本不存在${NC}"
        read -p "按回车键返回..." dummy
        return
    fi
    
    echo "正在执行硬件检测，请稍候..."
    echo ""
    
    # 执行硬件检测并保存结果
    local hw_rc=0
    if command -v plat_timeout >/dev/null 2>&1; then
        plat_timeout 300 bash "${SCRIPT_DIR}/hardware_check.sh" > "${CURRENT_HW_FILE}" 2>&1 || hw_rc=$?
    else
        timeout 300 bash "${SCRIPT_DIR}/hardware_check.sh" > "${CURRENT_HW_FILE}" 2>&1 || hw_rc=$?
    fi
    if { [ "$hw_rc" -eq 0 ] || [ "$hw_rc" -eq 2 ]; } &&
       grep -qxF '设备标识格式: v5' "${CURRENT_HW_FILE}" &&
       grep -q '^完成时间: ' "${CURRENT_HW_FILE}" && grep -q '^  - ' "${CURRENT_HW_FILE}"; then
        cat "${CURRENT_HW_FILE}"
        echo ""
        if [ "$hw_rc" -eq 0 ]; then
            echo -e "${GREEN}✓ 硬件检测完成${NC}"
        else
            echo "传感器检测异常，继续比对设备，但不允许更新基准"
        fi
    else
        echo -e "${RED}✗ 硬件检测执行失败${NC}"
        [ -f "${CURRENT_HW_FILE}" ] && cat "${CURRENT_HW_FILE}"
        read -p "按回车键返回..." dummy
        return
    fi
    
    echo ""
    
    # 检查基准文件
    if [ ! -f "${BASELINE_FILE}" ]; then
        [ "$hw_rc" -eq 0 ] || return "$hw_rc"
        echo -e "${YELLOW}注意: 硬件基准文件不存在${NC}"
        echo ""
        echo -ne "是否以当前检测结果创建基准? (y/N): "
        read CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            cp "${CURRENT_HW_FILE}" "${BASELINE_FILE}"
            sync
            echo -e "${GREEN}✓ 硬件基准已创建${NC}"
        fi
    else
        # 基准存在，执行对比
        echo "━━━━━━━━━━ 硬件基准对比 ━━━━━━━━━━"
        echo ""
        
        # 提取设备列表
        BASELINE_DEVICES=$(grep -E "^  - " "${BASELINE_FILE}" 2>/dev/null | sort)
        CURRENT_DEVICES=$(grep -E "^  - " "${CURRENT_HW_FILE}" 2>/dev/null | sort)
        
        HAS_CHANGE=0
        
        if [ -z "$BASELINE_DEVICES" ] && [ -z "$CURRENT_DEVICES" ]; then
            echo -e "${YELLOW}⚠ 无法提取设备列表进行对比${NC}"
        else
            # 检测新增设备
            if [ -n "$CURRENT_DEVICES" ]; then
                NEW_DEVICES=$(comm -13 <(echo "$BASELINE_DEVICES") <(echo "$CURRENT_DEVICES") 2>/dev/null || true)
            else
                NEW_DEVICES=""
            fi
            if [ -n "$NEW_DEVICES" ]; then
                echo -e "${GREEN}✓ 新增设备:${NC}"
                echo "$NEW_DEVICES" | sed 's/^/  /'
                echo ""
                HAS_CHANGE=1
            fi
            
            # 检测丢失设备
            if [ -n "$BASELINE_DEVICES" ]; then
                MISSING_DEVICES=$(comm -23 <(echo "$BASELINE_DEVICES") <(echo "$CURRENT_DEVICES") 2>/dev/null || true)
            else
                MISSING_DEVICES=""
            fi
            if [ -n "$MISSING_DEVICES" ]; then
                echo -e "${RED}✗ 丢失设备:${NC}"
                echo "$MISSING_DEVICES" | sed 's/^/  /'
                echo ""
                HAS_CHANGE=1
            fi
            
            if [ "$HAS_CHANGE" = "0" ]; then
                echo -e "${GREEN}✓ 硬件配置无变化${NC}"
            fi
        fi
        
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        [ "$hw_rc" -eq 0 ] || return "$hw_rc"
        echo -ne "是否更新硬件基准文件? (y/N): "
        read CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            cp "${CURRENT_HW_FILE}" "${BASELINE_FILE}"
            sync
            echo -e "${GREEN}✓ 硬件基准已更新${NC}"
        fi
    fi
    
    echo ""
    read -p "按回车键返回..." dummy
)

# 5. 查看最新日志
view_latest_log() {
    show_header
    echo -e "${BLUE}【查看最新日志】${NC}"
    echo ""
    
    LATEST_LOG=$(ls -t "$LOG_BOOT_DIR"/boot_*.log 2>/dev/null | head -1)
    NORMAL_LOG="${LOG_BOOT_DIR}/normal_summary.log"
    
    if [ -n "$LATEST_LOG" ]; then
        echo -e "详细日志: ${GREEN}$(basename $LATEST_LOG)${NC}"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        cat "$LATEST_LOG"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    elif [ -f "$NORMAL_LOG" ] && [ -s "$NORMAL_LOG" ]; then
        echo -e "${YELLOW}无详细日志（正常启动不保留详细日志）${NC}"
        echo -e "显示启动摘要日志: ${GREEN}normal_summary.log${NC}"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "最近 10 条启动记录:"
        tail -10 "$NORMAL_LOG"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        echo -e "${RED}未找到任何日志文件${NC}"
    fi
    
    echo ""
    read -p "按回车键返回..." dummy
}

# 6. 查看历史日志列表
view_log_history() {
    show_header
    echo -e "${BLUE}【历史日志列表】${NC}"
    echo ""
    
    if [ ! -d "$LOG_DIR" ]; then
        echo -e "${RED}日志目录不存在${NC}"
        read -p "按回车键返回..." dummy
        return
    fi
    
    LOGS=$(ls -t "$LOG_BOOT_DIR"/boot_*.log 2>/dev/null)
    NORMAL_LOG="${LOG_BOOT_DIR}/normal_summary.log"
    BOOT_LOG_COUNT=$(echo "$LOGS" | grep -c "." 2>/dev/null || echo 0)
    [ -z "$LOGS" ] && BOOT_LOG_COUNT=0
    
    echo "日志类型:"
    echo ""
    echo "  s) 查看启动摘要日志 (normal_summary.log)"
    if [ $BOOT_LOG_COUNT -gt 0 ]; then
        echo "  b) 查看详细启动日志 ($BOOT_LOG_COUNT 个文件)"
    else
        echo -e "  b) 详细启动日志 ${YELLOW}(无文件 - 正常启动不保留)${NC}"
    fi
    echo "  0) 返回"
    echo ""
    echo -ne "请选择 [s/b/0]: "
    read LOG_TYPE
    
    case $LOG_TYPE in
        s|S)
            clear
            echo -e "${BLUE}【启动摘要日志】${NC}"
            echo ""
            if [ -f "$NORMAL_LOG" ] && [ -s "$NORMAL_LOG" ]; then
                SUMMARY_LINES=$(wc -l < "$NORMAL_LOG")
                echo -e "文件: ${GREEN}normal_summary.log${NC} (${SUMMARY_LINES} 条记录)"
                echo ""
                echo "查看选项:"
                echo "  1) 查看全部"
                echo "  2) 查看最近 20 条"
                echo "  3) 查看最近 50 条"
                echo "  4) 仅显示正常启动 (status=OK)"
                echo "  5) 仅显示异常启动 (status=ERROR)"
                echo ""
                echo -ne "请选择 [1-5]: "
                read SUB_OPT
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                case $SUB_OPT in
                    1) less "$NORMAL_LOG" ;;
                    2) tail -20 "$NORMAL_LOG" ;;
                    3) tail -50 "$NORMAL_LOG" ;;
                    4) grep "status=OK" "$NORMAL_LOG" || echo "无正常启动记录" ;;
                    5) grep "status=ERROR" "$NORMAL_LOG" || echo "无异常启动记录" ;;
                    *) tail -20 "$NORMAL_LOG" ;;
                esac
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            else
                echo -e "${YELLOW}启动摘要日志为空或不存在${NC}"
            fi
            ;;
        b|B)
            if [ $BOOT_LOG_COUNT -eq 0 ]; then
                echo -e "${YELLOW}无详细启动日志（正常启动不保留详细日志）${NC}"
            else
                clear
                echo -e "${BLUE}【详细启动日志列表】${NC}"
                echo ""
                echo "找到以下日志文件:"
                echo ""
                
                INDEX=1
                echo "$LOGS" | while read log; do
                    LOG_NAME=$(basename "$log")
                    LOG_SIZE=$(du -h "$log" | awk '{print $1}')
                    LOG_TIME=$(stat -c %y "$log" 2>/dev/null | cut -d. -f1)
                    echo "  $INDEX) $LOG_NAME ($LOG_SIZE) - $LOG_TIME"
                    INDEX=$((INDEX + 1))
                done
                
                echo ""
                echo -e "日志总数: ${YELLOW}${BOOT_LOG_COUNT}${NC}"
                echo ""
                echo -ne "输入日志编号查看详情 (0 返回): "
                read LOG_NUM
                
                if [[ "$LOG_NUM" =~ ^[1-9][0-9]*$ ]]; then
                    SELECTED_LOG=$(echo "$LOGS" | sed -n "${LOG_NUM}p")
                    if [ -n "$SELECTED_LOG" ]; then
                        clear
                        echo -e "${BLUE}【日志详情】${NC}"
                        echo ""
                        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        cat "$SELECTED_LOG"
                        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    fi
                fi
            fi
            ;;
        0|*)
            return
            ;;
    esac
    
    echo ""
    read -p "按回车键返回..." dummy
}

# 7. 清理日志文件 - 优化版
clean_logs() {
    show_header
    echo -e "${BLUE}【清理日志文件】${NC}"
    echo ""
    
    if [ ! -d "$LOG_DIR" ]; then
        echo -e "${RED}日志目录不存在${NC}"
        read -p "按回车键返回..." dummy
        return
    fi
    
    BOOT_LOG_COUNT=$(ls -1 "$LOG_BOOT_DIR"/boot_*.log 2>/dev/null | wc -l)
    DMESG_SNAPSHOT_COUNT=$(ls -1 "$LOG_DMESG_DIR"/dmesg_boot*.log 2>/dev/null | wc -l)
    ERROR_LOG_SIZE=0
    DMESG_LOG_SIZE=0
    [ -f "${ERROR_LOG}" ] && ERROR_LOG_SIZE=$(du -h "${ERROR_LOG}" 2>/dev/null | awk '{print $1}')
    [ -f "${DMESG_LOG}" ] && DMESG_LOG_SIZE=$(du -h "${DMESG_LOG}" 2>/dev/null | awk '{print $1}')
    
    if [ $BOOT_LOG_COUNT -eq 0 ] && [ $DMESG_SNAPSHOT_COUNT -eq 0 ] && [ ! -f "${ERROR_LOG}" ] && [ ! -f "${DMESG_LOG}" ]; then
        echo -e "${YELLOW}没有日志文件需要清理${NC}"
        read -p "按回车键返回..." dummy
        return
    fi
    
    echo "日志统计信息："
    echo ""
    echo "  • 开机日志: $BOOT_LOG_COUNT 个文件"
    echo "  • dmesg 错误快照: $DMESG_SNAPSHOT_COUNT 个文件"
    if [ -f "${DMESG_LOG}" ]; then
        echo "  • dmesg 主日志: $DMESG_LOG_SIZE"
    fi
    if [ -f "${ERROR_LOG}" ]; then
        echo "  • 错误日志: $ERROR_LOG_SIZE"
    fi
    echo ""
    
    echo "清理选项："
    echo ""
    echo "  1) 清理所有开机日志 ($BOOT_LOG_COUNT 个文件)"
    echo "  2) 清理 7 天前的开机日志"
    echo "  3) 清理 30 天前的开机日志"
    echo "  4) 清理 90 天前的开机日志"
    echo "  5) 自定义天数清理开机日志"
    echo "  6) 清理错误日志文件"
    echo "  7) 清理 dmesg 错误快照文件"
    echo "  8) 清理 dmesg 主日志文件"
    echo "  9) 清理所有日志（包括所有类型）"
    echo "  a) 完全重置（清除所有txt和log文件，从头开始）"
    echo "  0) 返回"
    echo ""
    echo -ne "请选择 [0-9/a]: "
    read CLEAN_OPTION
    
    case $CLEAN_OPTION in
        1)
            echo ""
            echo -e "${YELLOW}警告: 将删除所有 $BOOT_LOG_COUNT 个开机日志文件${NC}"
            echo -ne "确认删除? (y/N): "
            read CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                DELETED=$(ls -1 "$LOG_BOOT_DIR"/boot_*.log 2>/dev/null | wc -l)
                rm -f "$LOG_BOOT_DIR"/boot_*.log 2>/dev/null
                echo -e "${GREEN}✓ 已清理 $DELETED 个开机日志文件${NC}"
            else
                echo "操作已取消"
            fi
            ;;
        2|3|4)
            if [ "$CLEAN_OPTION" = "2" ]; then DAYS=7
            elif [ "$CLEAN_OPTION" = "3" ]; then DAYS=30
            else DAYS=90; fi
            
            OLD_COUNT=$(find "$LOG_BOOT_DIR" -name "boot_*.log" -mtime +$DAYS 2>/dev/null | wc -l)
            
            if [ $OLD_COUNT -gt 0 ]; then
                echo ""
                echo -e "${YELLOW}将删除 $DAYS 天前的 $OLD_COUNT 个开机日志文件${NC}"
                echo -ne "确认删除? (y/N): "
                read CONFIRM
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    find "$LOG_BOOT_DIR" -name "boot_*.log" -mtime +$DAYS -delete 2>/dev/null
                    echo -e "${GREEN}✓ 已清理 $DAYS 天前的 $OLD_COUNT 个日志${NC}"
                else
                    echo "操作已取消"
                fi
            else
                echo -e "${YELLOW}没有 $DAYS 天前的日志文件${NC}"
            fi
            ;;
        5)
            echo ""
            echo -ne "请输入天数: "
            read CUSTOM_DAYS
            
            if [[ "$CUSTOM_DAYS" =~ ^[0-9]+$ ]] && [ $CUSTOM_DAYS -gt 0 ]; then
                OLD_COUNT=$(find "$LOG_BOOT_DIR" -name "boot_*.log" -mtime +$CUSTOM_DAYS 2>/dev/null | wc -l)
                
                if [ $OLD_COUNT -gt 0 ]; then
                    echo ""
                    echo -e "${YELLOW}将删除 $CUSTOM_DAYS 天前的 $OLD_COUNT 个开机日志文件${NC}"
                    echo -ne "确认删除? (y/N): "
                    read CONFIRM
                    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                        find "$LOG_BOOT_DIR" -name "boot_*.log" -mtime +$CUSTOM_DAYS -delete 2>/dev/null
                        echo -e "${GREEN}✓ 已清理 $CUSTOM_DAYS 天前的 $OLD_COUNT 个日志${NC}"
                    else
                        echo "操作已取消"
                    fi
                else
                    echo -e "${YELLOW}没有 $CUSTOM_DAYS 天前的日志文件${NC}"
                fi
            else
                echo -e "${RED}无效的天数${NC}"
            fi
            ;;
        6)
            if [ -f "${ERROR_LOG}" ]; then
                echo ""
                echo -e "${YELLOW}警告: 将清空错误日志文件 ($ERROR_LOG_SIZE)${NC}"
                echo -ne "确认清空? (y/N): "
                read CONFIRM
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    > "${ERROR_LOG}"
                    echo -e "${GREEN}✓ 错误日志已清空${NC}"
                else
                    echo "操作已取消"
                fi
            else
                echo -e "${YELLOW}错误日志文件不存在${NC}"
            fi
            ;;
        7)
            if [ $DMESG_SNAPSHOT_COUNT -gt 0 ]; then
                echo ""
                echo -e "${YELLOW}警告: 将删除所有 $DMESG_SNAPSHOT_COUNT 个 dmesg 错误快照文件${NC}"
                echo -ne "确认删除? (y/N): "
                read CONFIRM
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    DELETED=$(ls -1 "$LOG_DMESG_DIR"/dmesg_boot*.log 2>/dev/null | wc -l)
                    rm -f "$LOG_DMESG_DIR"/dmesg_boot*.log 2>/dev/null
                    echo -e "${GREEN}✓ 已清理 $DELETED 个 dmesg 错误快照文件${NC}"
                else
                    echo "操作已取消"
                fi
            else
                echo -e "${YELLOW}没有 dmesg 错误快照文件${NC}"
            fi
            ;;
        8)
            if [ -f "${DMESG_LOG}" ]; then
                echo ""
                echo -e "${YELLOW}警告: 将清空 dmesg 主日志文件 ($DMESG_LOG_SIZE)${NC}"
                echo -ne "确认清空? (y/N): "
                read CONFIRM
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    > "${DMESG_LOG}"
                    echo -e "${GREEN}✓ dmesg 主日志已清空${NC}"
                else
                    echo "操作已取消"
                fi
            else
                echo -e "${YELLOW}dmesg 主日志文件不存在${NC}"
            fi
            ;;
        9)
            echo ""
            echo -e "${YELLOW}警告: 将删除所有日志文件（开机日志 + dmesg + 错误日志）${NC}"
            echo -ne "确认删除? (y/N): "
            read CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                BOOT_DELETED=$(ls -1 "$LOG_BOOT_DIR"/boot_*.log 2>/dev/null | wc -l)
                DMESG_DELETED=$(ls -1 "$LOG_DMESG_DIR"/dmesg_boot*.log 2>/dev/null | wc -l)
                rm -f "$LOG_BOOT_DIR"/*.log 2>/dev/null
                rm -f "$LOG_ERROR_DIR"/*.log 2>/dev/null
                rm -f "$LOG_DMESG_DIR"/*.log 2>/dev/null
                echo -e "${GREEN}✓ 已清理所有日志${NC}"
                echo "  - 删除 $BOOT_DELETED 个开机日志"
                echo "  - 删除 $DMESG_DELETED 个 dmesg 错误快照"
                echo "  - 清空错误日志"
                echo "  - 清空 dmesg 主日志"
            else
                echo "操作已取消"
            fi
            ;;
        a|A)
            echo ""
            echo -e "${RED}警告: 完全重置将清除所有数据，从头开始！${NC}"
            echo ""
            echo "将清除以下内容:"
            echo "  - 开机计数器 (重置为0)"
            echo "  - 启动时间基准 (boot_time_baseline.txt)"
            echo "  - 硬件基准 (hardware_baseline.txt)"
            echo "  - 硬件当前状态 (hardware_current.txt)"
            echo "  - 所有日志文件 (logs/boot/*.log, logs/error/*.log, logs/dmesg/*.log)"
            echo ""
            echo -ne "确认完全重置? (y/N): "
            read CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                # 重置开机计数器
                echo "0" > "$COUNTER_FILE"
                # 清除txt文件
                rm -f "${SCRIPT_DIR}/boot_time_baseline.txt"
                rm -f "${SCRIPT_DIR}/last_boot_time.txt"
                rm -f "${SCRIPT_DIR}/hardware_baseline.txt"
                rm -f "${SCRIPT_DIR}/hardware_current.txt"
                rm -f "${SCRIPT_DIR}/reboot_remaining.txt"
                rm -f "${SCRIPT_DIR}/.display_pending"
                # 清除所有日志
                rm -f "$LOG_BOOT_DIR"/*.log 2>/dev/null
                rm -f "$LOG_ERROR_DIR"/*.log 2>/dev/null
                rm -f "$LOG_DMESG_DIR"/*.log 2>/dev/null
                sync
                echo ""
                echo -e "${GREEN}✓ 完全重置完成${NC}"
                echo "  - 开机计数器已重置为0"
                echo "  - 所有基准文件已清除"
                echo "  - 所有日志文件已清除"
                echo ""
                echo "下次开机将从第1次开始计数，并重新创建基准"
            else
                echo "操作已取消"
            fi
            ;;
        0|*)
            return
            ;;
    esac
    
    echo ""
    read -p "按回车键返回..." dummy
}

# 8. 服务管理
service_management() {
    show_header
    echo -e "${BLUE}【服务管理】${NC}"
    echo ""
    
    # 显示服务状态
    echo "当前服务状态："
    echo ""
    if command -v plat_service_status >/dev/null 2>&1; then
        if [ "${PLATFORM_INIT:-}" = "systemd" ]; then
            # 早段只计数，跑完立刻 active(exited)，单看它判断不了报告有没有跑。
            # 计数服务、报告服务、报告定时器要一起展示。
            for UNIT in "$SERVICE_NAME" "$REPORT_SERVICE_NAME" "$REPORT_TIMER_NAME"; do
                plat_service_status "$UNIT"
                echo ""
            done
        else
            plat_service_status "$SERVICE_NAME"
        fi
    else
        systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null | head -10
    fi
    
    echo ""
    echo "服务管理选项："
    echo ""
    echo "  1) 启用服务 (开机自动运行)"
    echo "  2) 禁用服务"
    echo "  3) 立即运行一次"
    echo "  4) 查看服务日志"
    echo "  0) 返回"
    echo ""
    echo -ne "请选择 [0-4]: "
    read SERVICE_OPTION
    
    case $SERVICE_OPTION in
        1)
            echo ""
            if command -v plat_service_enable >/dev/null 2>&1; then
                plat_service_enable "$SERVICE_NAME" || { echo -e "${RED}启用失败${NC}"; return 1; }
                if [ "${PLATFORM_INIT:-}" = "systemd" ]; then
                    systemctl enable "$REPORT_TIMER_NAME" || { echo -e "${RED}报告定时器启用失败${NC}"; return 1; }
                fi
            else
                systemctl enable "$SERVICE_NAME" "$REPORT_TIMER_NAME"
            fi
            echo -e "${GREEN}✓ 服务已启用${NC}"
            ;;
        2)
            echo ""
            if command -v plat_service_disable >/dev/null 2>&1; then
                plat_service_disable "$SERVICE_NAME" || { echo -e "${RED}禁用失败${NC}"; return 1; }
                if [ "${PLATFORM_INIT:-}" = "systemd" ]; then
                    systemctl stop "$REPORT_TIMER_NAME" 2>/dev/null || true
                    systemctl disable "$REPORT_TIMER_NAME" || { echo -e "${RED}报告定时器禁用失败${NC}"; return 1; }
                fi
            else
                systemctl disable "$SERVICE_NAME" "$REPORT_TIMER_NAME"
            fi
            echo -e "${YELLOW}✓ 服务已禁用${NC}"
            ;;
        3)
            echo ""
            echo "正在运行（报告阶段，不改变开机计数）..."
            # 计数只在开机早段做，手动运行重跑硬件检测与比对，因此不能走 all
            BOOT_MONITOR_FORCE=1 bash "${SCRIPT_DIR}/boot_counter.sh" report
            ;;
        4)
            clear
            echo -e "${BLUE}【服务日志】${NC}"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            if [ "${PLATFORM_INIT:-}" = "systemd" ]; then
                # 两段各一个单元，只看计数单元会漏掉硬件检测与耗时判定的输出
                journalctl -u "$SERVICE_NAME" -u "$REPORT_SERVICE_NAME" -n 50 --no-pager
            elif command -v plat_service_logs >/dev/null 2>&1; then
                plat_service_logs "$SERVICE_NAME" 50
            else
                journalctl -u "$SERVICE_NAME" -n 50 --no-pager
            fi
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            ;;
        0|*)
            return
            ;;
    esac
    
    echo ""
    read -p "按回车键返回..." dummy
}

# 9. 系统信息
system_info() {
    show_header
    echo -e "${BLUE}【系统信息】${NC}"
    echo ""
    
    echo "操作系统信息:"
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        echo "  发行版: $NAME"
        echo "  版本: $VERSION"
    else
        echo "  $(uname -s) $(uname -r)"
    fi
    
    echo ""
    echo "内核信息:"
    echo "  $(uname -r)"
    
    echo ""
    echo "运行时长:"
    echo "  $(uptime -p 2>/dev/null || uptime)"
    
    echo ""
    echo "CPU 信息:"
    grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^/  /'
    echo "  CPU 核心数: $(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 未知)"
    
    echo ""
    echo "内存信息:"
    free -h 2>/dev/null | grep "Mem:" | awk '{print "  总内存: "$2"  已用: "$3"  可用: "$7}' ||
        free 2>/dev/null | grep "Mem:" | awk '{print "  总内存: "$2"  已用: "$3"  可用: "$4}'
    
    echo ""
    echo "磁盘使用:"
    df -h / 2>/dev/null | tail -1 | awk '{print "  根分区: "$2"  已用: "$3" ("$5")  可用: "$4}'
    
    echo ""
    read -p "按回车键返回..." dummy
}

# d. 查看dmesg系统日志
view_dmesg_logs() {
    show_header
    echo -e "${BLUE}【查看系统日志 (dmesg)】${NC}"
    echo ""
    
    if [ ! -d "$LOG_DIR" ]; then
        echo -e "${RED}日志目录不存在${NC}"
        read -p "按回车键返回..." dummy
        return
    fi
    
    # 统计 dmesg 日志（仅错误时才有）
    DMESG_SNAPSHOTS=$(ls -t "$LOG_DMESG_DIR"/dmesg_boot*.log 2>/dev/null)
    SNAPSHOT_COUNT=$(echo "$DMESG_SNAPSHOTS" | grep -c "^" 2>/dev/null || echo 0)
    
    if [ -f "${DMESG_LOG}" ]; then
        DMESG_SIZE=$(du -h "${DMESG_LOG}" 2>/dev/null | awk '{print $1}')
        echo -e "主日志文件: ${GREEN}${DMESG_LOG}${NC} (${DMESG_SIZE})"
    else
        echo -e "${YELLOW}主日志文件不存在（无错误记录）${NC}"
    fi
    
    echo -e "dmesg 错误快照数量: ${YELLOW}${SNAPSHOT_COUNT}${NC} 个"
    echo ""
    
    if [ $SNAPSHOT_COUNT -eq 0 ] && [ ! -f "${DMESG_LOG}" ]; then
        echo -e "${YELLOW}没有 dmesg 日志文件${NC}"
        read -p "按回车键返回..." dummy
        return
    fi
    
    echo "查看选项："
    echo ""
    echo "  1) 查看主 dmesg 日志文件"
    echo "  2) 查看 dmesg 错误快照列表"
    echo "  3) 查看当前系统 dmesg （实时）"
    echo "  4) 手动抓取 dmesg 快照（用于故障分析）"
    echo "  0) 返回"
    echo ""
    echo -ne "请选择 [0-4]: "
    read DMESG_OPTION
    
    case $DMESG_OPTION in
        1)
            if [ -f "${DMESG_LOG}" ]; then
                clear
                echo -e "${BLUE}【dmesg 主日志文件】${NC}"
                echo ""
                echo "─────────────────────────────────────────────────────────────"
                less "${DMESG_LOG}"
                echo "─────────────────────────────────────────────────────────────"
            else
                echo -e "${RED}dmesg 主日志文件不存在${NC}"
            fi
            ;;
        2)
            if [ $SNAPSHOT_COUNT -gt 0 ]; then
                clear
                echo -e "${BLUE}【dmesg 快照列表】${NC}"
                echo ""
                echo "找到以下 dmesg 快照文件："
                echo ""
                
                INDEX=1
                echo "$DMESG_SNAPSHOTS" | while read snapshot; do
                    SNAP_NAME=$(basename "$snapshot")
                    SNAP_SIZE=$(du -h "$snapshot" 2>/dev/null | awk '{print $1}')
                    SNAP_TIME=$(stat -c %y "$snapshot" 2>/dev/null | cut -d. -f1)
                    
                    # 从文件名提取开机次数 dmesg_bootXXX_YYYYMMDD_HHMMSS.log
                    BOOT_NUM=$(echo "$SNAP_NAME" | sed 's/.*boot\([0-9]*\).*/\1/' | grep -E '^[0-9]+$' || echo "?")
                    
                    echo "  $INDEX) [开机次数:$BOOT_NUM] $SNAP_NAME ($SNAP_SIZE) - $SNAP_TIME"
                    INDEX=$((INDEX + 1))
                done
                
                echo ""
                echo -ne "输入快照编号查看详情 (0 返回): "
                read SNAP_NUM
                
                if [[ "$SNAP_NUM" =~ ^[1-9][0-9]*$ ]]; then
                    SELECTED_SNAP=$(echo "$DMESG_SNAPSHOTS" | sed -n "${SNAP_NUM}p")
                    if [ -n "$SELECTED_SNAP" ]; then
                        clear
                        echo -e "${BLUE}【dmesg 快照详情】${NC}"
                        echo ""
                        echo "─────────────────────────────────────────────────────────────"
                        less "$SELECTED_SNAP"
                        echo "─────────────────────────────────────────────────────────────"
                    fi
                fi
            else
                echo -e "${YELLOW}没有 dmesg 快照文件${NC}"
            fi
            ;;
        3)
            clear
            echo -e "${BLUE}【当前系统 dmesg（实时）】${NC}"
            echo ""
            echo "─────────────────────────────────────────────────────────────"
            dmesg | less
            echo "─────────────────────────────────────────────────────────────"
            ;;
        4)
            echo ""
            echo "正在抓取当前 dmesg 快照（用于故障分析）..."
            
            # 获取当前开机次数
            if [ -f "$COUNTER_FILE" ]; then
                CURRENT_BOOT=$(cat "$COUNTER_FILE")
            else
                CURRENT_BOOT="unknown"
            fi
            
            TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
            SNAPSHOT_FILE="${LOG_DMESG_DIR}/dmesg_boot${CURRENT_BOOT}_manual_${TIMESTAMP}.log"
            
            # 抓取 dmesg 并添加上下文信息
            {
                echo "============================================"
                echo "抓取时间: $(date '+%Y-%m-%d %H:%M:%S')"
                echo "开机次数: ${CURRENT_BOOT}"
                echo "抓取类型: 手动抓取（故障分析）"
                echo "============================================"
                echo ""
                dmesg
            } > "${SNAPSHOT_FILE}" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ 快照已保存到: ${SNAPSHOT_FILE}${NC}"
            else
                echo -e "${RED}✗ 抓取失败${NC}"
            fi
            sleep 2
            ;;
        0|*)
            return
            ;;
    esac
    
    echo ""
    read -p "按回车键返回..." dummy
}

# e. 查看错误日志
view_error_logs() {
    show_header
    echo -e "${BLUE}【查看错误日志】${NC}"
    echo ""
    
    if [ ! -f "${ERROR_LOG}" ]; then
        echo -e "${YELLOW}错误日志文件不存在${NC}"
        read -p "按回车键返回..." dummy
        return
    fi
    
    ERROR_SIZE=$(du -h "${ERROR_LOG}" 2>/dev/null | awk '{print $1}')
    ERROR_LINES=$(wc -l < "${ERROR_LOG}" 2>/dev/null || echo 0)
    
    echo -e "错误日志文件: ${GREEN}${ERROR_LOG}${NC}"
    echo -e "文件大小: ${YELLOW}${ERROR_SIZE}${NC}"
    echo -e "总行数: ${YELLOW}${ERROR_LINES}${NC} 行"
    echo ""
    
    if [ $ERROR_LINES -eq 0 ]; then
        echo -e "${GREEN}✓ 没有错误记录${NC}"
        read -p "按回车键返回..." dummy
        return
    fi
    
    echo "查看选项："
    echo ""
    echo "  1) 查看所有错误日志"
    echo "  2) 查看最近 20 行"
    echo "  3) 查看最近 50 行"
    echo "  4) 查看最近 100 行"
    echo "  5) 搜索错误关键词"
    echo "  0) 返回"
    echo ""
    echo -ne "请选择 [0-5]: "
    read ERROR_OPTION
    
    case $ERROR_OPTION in
        1)
            clear
            echo -e "${BLUE}【所有错误日志】${NC}"
            echo ""
            echo "─────────────────────────────────────────────────────────────"
            less "${ERROR_LOG}"
            echo "─────────────────────────────────────────────────────────────"
            ;;
        2|3|4)
            if [ "$ERROR_OPTION" = "2" ]; then LINES=20
            elif [ "$ERROR_OPTION" = "3" ]; then LINES=50
            else LINES=100; fi
            
            clear
            echo -e "${BLUE}【最近 $LINES 行错误日志】${NC}"
            echo ""
            echo "─────────────────────────────────────────────────────────────"
            tail -$LINES "${ERROR_LOG}"
            echo "─────────────────────────────────────────────────────────────"
            ;;
        5)
            echo ""
            echo -ne "请输入搜索关键词: "
            read KEYWORD
            
            if [ -n "$KEYWORD" ]; then
                clear
                echo -e "${BLUE}【搜索结果: $KEYWORD】${NC}"
                echo ""
                echo "─────────────────────────────────────────────────────────────"
                grep -i "$KEYWORD" "${ERROR_LOG}" || echo -e "${YELLOW}未找到匹配结果${NC}"
                echo "─────────────────────────────────────────────────────────────"
            fi
            ;;
        0|*)
            return
            ;;
    esac
    
    echo ""
    read -p "按回车键返回..." dummy
}

# a. 配置自动登录
configure_autologin() {
    show_header
    echo -e "${BLUE}【配置自动登录】${NC}"
    echo ""
    
    echo "此功能将配置系统开机后自动登录到指定用户"
    echo ""
    echo "支持的显示管理器:"
    echo "  - GDM (GNOME Display Manager) - Ubuntu 默认"
    echo "  - LightDM - 轻量级显示管理器"
    echo ""
    
    # 检测当前显示管理器
    DM_TYPE=""
    if systemctl is-active gdm &>/dev/null || systemctl is-active gdm3 &>/dev/null; then
        DM_TYPE="gdm"
        echo -e "检测到: ${GREEN}GDM${NC}"
    elif systemctl is-active lightdm &>/dev/null; then
        DM_TYPE="lightdm"
        echo -e "检测到: ${GREEN}LightDM${NC}"
    else
        echo -e "${YELLOW}警告: 未检测到支持的显示管理器${NC}"
        echo "如果您使用的是服务器（无图形界面），可配置 Getty 自动登录"
        echo ""
        echo -ne "是否配置 Getty 自动登录? (y/N): "
        read CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            DM_TYPE="getty"
        else
            echo "操作已取消"
            read -p "按回车键返回..." dummy
            return
        fi
    fi
    
    echo ""
    echo -ne "请输入要自动登录的用户名: "
    read AUTO_USER
    
    # 验证用户是否存在
    if ! id "$AUTO_USER" &>/dev/null; then
        echo -e "${RED}错误: 用户 '$AUTO_USER' 不存在${NC}"
        sleep 2
        return
    fi
    
    echo ""
    echo -e "${YELLOW}警告: 此操作将修改系统配置文件${NC}"
    echo -e "将配置用户 ${GREEN}$AUTO_USER${NC} 开机自动登录"
    echo ""
    echo -ne "确认配置? (y/N): "
    read CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "操作已取消"
        sleep 1
        return
    fi
    
    echo ""
    echo "正在配置..."
    
    case $DM_TYPE in
        gdm)
            # 配置 GDM 自动登录
            GDM_CONF="/etc/gdm3/custom.conf"
            if [ ! -f "$GDM_CONF" ]; then
                GDM_CONF="/etc/gdm/custom.conf"
            fi
            
            if [ -f "$GDM_CONF" ]; then
                # 备份原文件
                cp "$GDM_CONF" "${GDM_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
                
                # 修改配置
                if grep -q "\[daemon\]" "$GDM_CONF"; then
                    sed -i "/\[daemon\]/a AutomaticLoginEnable = true\nAutomaticLogin = $AUTO_USER" "$GDM_CONF"
                else
                    echo "[daemon]" >> "$GDM_CONF"
                    echo "AutomaticLoginEnable = true" >> "$GDM_CONF"
                    echo "AutomaticLogin = $AUTO_USER" >> "$GDM_CONF"
                fi
                
                echo -e "${GREEN}✓ GDM 自动登录已配置${NC}"
            else
                echo -e "${RED}✗ 找不到 GDM 配置文件${NC}"
            fi
            ;;
            
        lightdm)
            # 配置 LightDM 自动登录
            LIGHTDM_CONF="/etc/lightdm/lightdm.conf"
            
            if [ -f "$LIGHTDM_CONF" ]; then
                # 备份原文件
                cp "$LIGHTDM_CONF" "${LIGHTDM_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
                
                # 修改配置
                if grep -q "\[Seat:\*\]" "$LIGHTDM_CONF"; then
                    sed -i "/\[Seat:\*\]/a autologin-user=$AUTO_USER" "$LIGHTDM_CONF"
                else
                    echo "[Seat:*]" >> "$LIGHTDM_CONF"
                    echo "autologin-user=$AUTO_USER" >> "$LIGHTDM_CONF"
                fi
                
                echo -e "${GREEN}✓ LightDM 自动登录已配置${NC}"
            else
                echo -e "${RED}✗ 找不到 LightDM 配置文件${NC}"
            fi
            ;;
            
        getty)
            # 配置 Getty 自动登录（控制台）
            GETTY_OVERRIDE="/etc/systemd/system/getty@tty1.service.d/override.conf"
            
            mkdir -p "/etc/systemd/system/getty@tty1.service.d"
            
            cat > "$GETTY_OVERRIDE" << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $AUTO_USER --noclear %I \$TERM
EOF
            
            systemctl daemon-reload
            echo -e "${GREEN}✓ Getty 自动登录已配置${NC}"
            
            # 配置登录后自动显示启动状态
            USER_HOME=$(eval echo ~$AUTO_USER)
            BASHRC="$USER_HOME/.bashrc"
            SHOW_SCRIPT="/opt/boot_monitor/boot_status_show.sh"
            
            # 检查是否已添加
            if [ -f "$BASHRC" ] && ! grep -q "boot_status_show.sh" "$BASHRC"; then
                echo "" >> "$BASHRC"
                echo "# 开机状态显示（自动添加）" >> "$BASHRC"
                echo "[ -x \"$SHOW_SCRIPT\" ] && $SHOW_SCRIPT" >> "$BASHRC"
                echo -e "${GREEN}✓ 登录后自动显示状态已配置${NC}"
            elif [ ! -f "$BASHRC" ]; then
                echo "# 开机状态显示（自动添加）" > "$BASHRC"
                echo "[ -x \"$SHOW_SCRIPT\" ] && $SHOW_SCRIPT" >> "$BASHRC"
                chown $AUTO_USER:$AUTO_USER "$BASHRC"
                echo -e "${GREEN}✓ 登录后自动显示状态已配置${NC}"
            else
                echo -e "${YELLOW}ℹ 登录后显示状态已配置过${NC}"
            fi
            ;;
    esac
    
    echo ""
    echo -e "${GREEN}配置完成！${NC}"
    echo ""
    echo "重启系统后将自动登录到用户: $AUTO_USER"
    echo ""
    echo "备份文件已保存，如需恢复可手动还原"
    echo ""
    read -p "按回车键返回..." dummy
}

# r. 指定次数重启（reboot重启指定次数，每次启动后等待10s再重启）
# 首次重启和继续测试使用相同的扣减、取消检查及失败处理。
request_reboot() (
    local delay="$1" expected="$2"
    command -v plat_commit_reboot >/dev/null 2>&1 || { echo "错误: 平台适配层缺失，无法安全重启" >&2; return 1; }
    command -v flock >/dev/null 2>&1 || { echo "错误: 本机未提供 flock，无法安全执行循环重启" >&2; return 1; }
    exec 8>"${SCRIPT_DIR}/.reboot_request.lock" || return 1
    flock -n 8 || { echo "已有重启任务在等待，请勿重复启动"; return 1; }
    sleep "$delay"
    plat_commit_reboot "$SCRIPT_DIR" "$expected"
)

reboot_with_count() {
    show_header
    echo -e "${BLUE}【指定次数重启测试】${NC}"
    echo ""
    
    if [ -f "$COUNTER_FILE" ]; then
        CURRENT_COUNT=$(cat "$COUNTER_FILE")
        echo -e "  当前开机次数: ${YELLOW}${CURRENT_COUNT}${NC}"
    else
        CURRENT_COUNT=0
    fi
    
    # 检查是否有正在进行的重启测试
    if [ -f "$REBOOT_COUNT_FILE" ]; then
        REMAINING=$(cat "$REBOOT_COUNT_FILE" 2>/dev/null || echo "0")
        if [[ "$REMAINING" =~ ^[0-9]{1,18}$ ]] && [ "$((10#$REMAINING))" -gt 0 ]; then
            echo -e "  ${YELLOW}当前正在进行重启测试，剩余 ${REMAINING} 次${NC}"
            echo ""
            echo "  选项:"
            echo "    1) 继续当前测试"
            echo "    2) 取消当前测试"
            echo "    3) 重新设置重启次数"
            echo "    0) 返回"
            echo ""
            echo -ne "  请选择 [0-3]: "
            read SUB_CHOICE
            
            case $SUB_CHOICE in
                1)
                    echo ""
                    echo -e "  ${YELLOW}继续重启测试，15秒后重启...${NC}"
                    request_reboot 15 "$REMAINING"
                    return $?
                    ;;
                2)
                    command -v plat_cancel_reboot >/dev/null 2>&1 && plat_cancel_reboot "$SCRIPT_DIR" || return 1
                    echo -e "  ${GREEN}✓ 重启测试已取消${NC}"
                    sleep 2
                    return
                    ;;
                3)
                    command -v plat_cancel_reboot >/dev/null 2>&1 && plat_cancel_reboot "$SCRIPT_DIR" || return 1
                    ;;
                *)
                    return
                    ;;
            esac
        fi
    fi
    
    echo ""
    echo -e "${YELLOW}功能说明:${NC}"
    echo "  指定重启次数后，系统将循环重启指定次数"
    echo "  每次启动后等待 15 秒再自动重启"
    echo "  用于测试系统稳定性和开关机功能"
    echo ""
    echo -ne "  请输入要重启的次数 (输入 0 取消): "
    read REBOOT_TIMES
    
    # 验证输入
    if ! [[ "$REBOOT_TIMES" =~ ^[0-9]{1,18}$ ]]; then
        echo -e "  ${RED}错误: 请输入不超过18位的非负整数${NC}"
        sleep 2
        return
    fi
    
    REBOOT_TIMES=$((10#$REBOOT_TIMES))
    if [ "$REBOOT_TIMES" -eq 0 ]; then
        echo "  操作已取消"
        sleep 1
        return
    fi
    
    # 显示确认信息
    echo ""
    echo -e "  ${YELLOW}重启计划:${NC}"
    echo "    - 重启次数: ${REBOOT_TIMES} 次"
    echo "    - 每次启动后等待: 15 秒"
    echo "    - 开机计数器将重置为0，从1开始计数"
    echo "    - 首次启动将作为基准启动时间"
    echo ""
    echo -e "${RED}警告: 系统将在确认后立即开始重启测试！${NC}"
    echo ""
    echo -ne "  确认开始重启测试? (y/N): "
    read CONFIRM
    
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        (
        if command -v flock >/dev/null 2>&1; then
            exec 9>"${SCRIPT_DIR}/.boot_counter.lock" || return 1
            flock -n 9 || { echo "启动检测正在运行，请稍后配置重启测试" >&2; return 1; }
        fi
        command -v plat_lock_reboot_state >/dev/null 2>&1 && plat_lock_reboot_state "$SCRIPT_DIR" || return 1
        # 将重启次数写入文件
        # 先完成计数初始化，再发布重启计划，写入失败时不得重启。
        local count_tmp plan_tmp
        [ ! -d "$COUNTER_FILE" ] && [ ! -d "$REBOOT_COUNT_FILE" ] || return 1
        count_tmp=$(mktemp "${COUNTER_FILE}.XXXXXX") || return 1
        plan_tmp=$(mktemp "${REBOOT_COUNT_FILE}.XXXXXX") || { rm -f -- "$count_tmp"; return 1; }
        trap 'rm -f -- "$count_tmp" "$plan_tmp"' EXIT
        printf '%s\n' "$REBOOT_TIMES" > "$plan_tmp" || return 1
        
        # 重置开机计数器为0（重启后第一次将为1）
        printf '0\n' > "$count_tmp" && chmod 644 "$count_tmp" || return 1
        if command -v plat_atomic_replace >/dev/null 2>&1; then
            plat_atomic_replace "$count_tmp" "$COUNTER_FILE" || return 1
        else
            mv -f "$count_tmp" "$COUNTER_FILE" || return 1
        fi
        
        # 清除启动时间基准（重新记录）
        rm -f "${SCRIPT_DIR}/boot_time_baseline.txt"
        rm -f "${SCRIPT_DIR}/last_boot_time.txt"
        
        # 清除硬件基准（重新创建）
        rm -f "${SCRIPT_DIR}/hardware_baseline.txt"
        rm -f "${SCRIPT_DIR}/hardware_current.txt"
        rm -f "${SCRIPT_DIR}/.display_pending"
        
        # 清除所有日志文件
        echo "  正在清除日志文件..."
        rm -f "${LOG_BOOT_DIR}"/*.log 2>/dev/null
        rm -f "${LOG_ERROR_DIR}"/*.log 2>/dev/null
        rm -f "${LOG_DMESG_DIR}"/*.log 2>/dev/null
        
        if command -v plat_atomic_replace >/dev/null 2>&1; then
            plat_atomic_replace "$plan_tmp" "$REBOOT_COUNT_FILE" || return 1
        else
            mv -f "$plan_tmp" "$REBOOT_COUNT_FILE" || return 1
        fi
        sync
        exec 7>&-
        
        echo ""
        echo -e "  ${GREEN}✓ 重启测试已配置${NC}"
        echo -e "  ${YELLOW}开机计数器已重置为0，重启后从1开始计数${NC}"
        echo -e "  ${YELLOW}所有日志和基准文件已清除，从头开始${NC}"
        echo -e "  ${YELLOW}系统将在 5 秒后重启...${NC}"
        echo ""
        echo "  提示: 可以通过 boot-manager 进入此菜单取消测试"
        request_reboot 5 "$REBOOT_TIMES"
        )
        return $?
    else
        echo "  重启测试已取消"
        sleep 2
    fi
}

# u. 卸载系统
uninstall_system() {
    show_header
    echo -e "${BLUE}【卸载系统】${NC}"
    echo ""
    
    echo -e "${RED}警告: 此操作将完全删除开机计数系统！${NC}"
    echo ""
    echo "将删除以下内容:"
    echo "  - systemd 服务"
    echo "  - 所有脚本文件"
    echo "  - 所有日志文件"
    echo "  - 开机计数数据"
    echo "  - 硬件基准数据"
    echo ""
    echo -e "${YELLOW}安装目录: $SCRIPT_DIR${NC}"
    echo ""
    echo -ne "  确认卸载? 输入 'YES' 继续: "
    read CONFIRM
    
    if [ "$CONFIRM" = "YES" ]; then
        echo ""
        echo "正在卸载..."
        
        # 1. 停止并禁用服务
        echo "  [1/8] 停止服务..."
        if [ "$PLATFORM_INIT" = "systemd" ]; then
            for UNIT in "$SERVICE_NAME" "$REPORT_SERVICE_NAME" "$REPORT_TIMER_NAME"; do
                systemctl stop "$UNIT" 2>/dev/null
                systemctl disable "$UNIT" 2>/dev/null
            done
        elif command -v plat_service_disable >/dev/null 2>&1; then
            plat_service_disable "$SERVICE_NAME" 2>/dev/null || true
        fi
        echo "    ✓ 服务已停止"
        
        # 2. 删除服务文件
        echo "  [2/8] 删除服务文件..."
        for UNIT in "$SERVICE_NAME" "$REPORT_SERVICE_NAME" "$REPORT_TIMER_NAME"; do
            rm -f "/etc/systemd/system/$UNIT"
        done
        if [ "$PLATFORM_INIT" = "busybox" ]; then
            rm -f /etc/init.d/S99boot-monitor
        elif [ "$PLATFORM_INIT" != "systemd" ]; then
            rm -f /etc/init.d/boot-monitor
        fi
        [ "$PLATFORM_INIT" = "systemd" ] && systemctl daemon-reload
        echo "    ✓ 服务文件已删除"
        
        # 3. 删除全局命令
        echo "  [3/8] 删除全局命令..."
        rm -f /usr/local/bin/boot-manager
        echo "    ✓ 全局命令已删除"
        
        # 4. 删除桌面自启动文件
        echo "  [4/8] 删除桌面自启动文件..."
        rm -f /etc/xdg/autostart/boot-monitor-display.desktop
        echo "    ✓ 桌面自启动文件已删除"
        
        # 5. 清理 Getty 自动登录配置
        echo "  [5/8] 清理 Getty 自动登录配置..."
        GETTY_OVERRIDE="/etc/systemd/system/getty@tty1.service.d/override.conf"
        if [ -f "$GETTY_OVERRIDE" ]; then
            rm -f "$GETTY_OVERRIDE"
            rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
            systemctl daemon-reload
            echo "    ✓ Getty 自动登录配置已清理"
        else
            echo "    - Getty 自动登录未配置，跳过"
        fi
        
        # 6. 清理用户 .bashrc 中的配置
        echo "  [6/8] 清理用户配置..."
        for USER_HOME in /home/* /root; do
            BASHRC="$USER_HOME/.bashrc"
            if [ -f "$BASHRC" ] && grep -q "boot_status_show.sh" "$BASHRC"; then
                sed -i '/# 开机状态显示/d' "$BASHRC" 2>/dev/null || true
                sed -i '/boot_status_show.sh/d' "$BASHRC" 2>/dev/null || true
                echo "    ✓ 已清理 $BASHRC"
            fi
        done
        
        # 7. 删除安装目录
        echo "  [7/8] 删除安装目录..."
        rm -rf "$SCRIPT_DIR"
        echo "    ✓ 安装目录已删除"
        
        # 8. 完成
        echo "  [8/8] 清理完成"
        
        echo ""
        echo -e "${GREEN}✓ 卸载完成！${NC}"
        echo ""
        echo "系统已完全删除，感谢使用！"
        echo ""
        exit 0
    else
        echo ""
        echo "  卸载已取消"
        sleep 2
    fi
}

# 主程序
main() {
    # 检查是否为 root
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}错误: 请使用 root 权限运行${NC}"
        echo "使用方法: sudo bash $0"
        exit 1
    fi
    
    # 检查安装
    check_installation
    
    # 主循环
    while true; do
        show_header
        show_status
        show_menu
        if ! IFS= read -r CHOICE; then
            echo ""
            return 0
        fi
        
        case $CHOICE in
            1) view_boot_count ;;
            2) set_boot_count ;;
            3) reset_boot_count ;;
            4) run_hardware_check ;;
            5) view_latest_log ;;
            6) view_log_history ;;
            7) clean_logs ;;
            8) service_management ;;
            9) system_info ;;
            d|D) view_dmesg_logs ;;
            e|E) view_error_logs ;;
            a|A) configure_autologin ;;
            r|R) reboot_with_count ;;
            u|U) uninstall_system ;;
            0)
                show_header
                echo -e "${GREEN}感谢使用，再见！${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重试${NC}"
                sleep 1
                ;;
        esac
    done
}

# 运行主程序
main
