#!/bin/bash
#
# 平台适配层：屏蔽两类目标平台的差异，供其余脚本 source 使用
#
#   平台 A：systemd + Xorg/显示管理器        （如 Ubuntu 22.04）
#   平台 B：BusyBox init + weston/Wayland    （如 Buildroot on RK3588）
#
# 两台目标机上的实测结论，决定了本层只需要抽象哪些东西：
#   - /bin/sh 均指向 bash 5.x，因此本层可以使用 bash 语法，无需降级为 POSIX sh
#   - /var/log 在两台上都是 tmpfs，systemd 的 journal 也是 volatile 配置，
#     系统日志重启即失，不能作为跨重启的证据来源
#   - dmesg / pgrep / pidof / start-stop-daemon 两台都有
# 真正的差异只有 init 系统与显示栈两项。
#

# 允许被重复 source 而不重复初始化。被 source 时用 return 退出，
# 直接执行时 return 不可用，退回 exit。
if [ -n "${PLATFORM_LIB_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
PLATFORM_LIB_LOADED=1

# ==================== init 系统 ====================

# 输出: systemd | busybox | sysv | unknown
plat_detect_init() {
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        echo "systemd"
        return 0
    fi

    # BusyBox 的 rcS 会顺序执行 /etc/init.d/S??* ；Debian 系 sysvinit 走
    # /etc/rc?.d/ 符号链接，没有 rcS 这个入口。这是两者最稳定的区分点。
    if [ -x /etc/init.d/rcS ] || [ -f /etc/init.d/rcS ]; then
        echo "busybox"
        return 0
    fi

    if [ -d /etc/rc2.d ] || [ -d /etc/rc.d ]; then
        echo "sysv"
        return 0
    fi

    echo "unknown"
    return 1
}

# 探测失败时也要给出确定值，避免调用方在 set -e 下被非零返回码带崩
PLATFORM_INIT="$(plat_detect_init || true)"
[ -n "$PLATFORM_INIT" ] || PLATFORM_INIT="unknown"

# 服务是否在运行。
# systemd 之外的平台没有"服务状态"这个概念，只能退化为进程名匹配——
# 进程在不在跑是这些平台上唯一可判定的事实。
# 用法: plat_service_is_active <服务名> [进程名...]
plat_service_is_active() {
    local unit="$1"
    shift

    if [ "$PLATFORM_INIT" = "systemd" ]; then
        systemctl is-active --quiet "$unit" 2>/dev/null && return 0
        return 1
    fi

    # 未给出进程名时按服务名本身匹配
    [ $# -eq 0 ] && set -- "$unit"
    local p
    for p in "$@"; do
        if command -v pgrep >/dev/null 2>&1; then
            pgrep -x "$p" >/dev/null 2>&1 && return 0
        elif command -v pidof >/dev/null 2>&1; then
            pidof "$p" >/dev/null 2>&1 && return 0
        fi
    done
    return 1
}

# ==================== 日志后端 ====================

# 判断路径实际落在哪种文件系统上，用于在写日志前确认它能否活过重启。
# 取 /proc/mounts 中的最长前缀匹配，因为挂载点会互相嵌套。
# 返回 0 表示易失（tmpfs/ramfs）。
plat_path_is_volatile() {
    local target="$1"
    [ -n "$target" ] || return 1
    [ -r /proc/mounts ] || return 1

    awk -v p="$target" '
    {
        mp = $2; fs = $3
        if (mp == "/" || p == mp || index(p, mp "/") == 1) {
            if (length(mp) >= best_len) { best_len = length(mp); best_fs = fs }
        }
    }
    END { exit (best_fs == "tmpfs" || best_fs == "ramfs") ? 0 : 1 }
    ' /proc/mounts
}

# 输出: journal | syslog-file | none
plat_detect_log_backend() {
    if [ "$PLATFORM_INIT" = "systemd" ] && command -v journalctl >/dev/null 2>&1; then
        echo "journal"
    elif [ -f /var/log/messages ] || [ -f /var/log/syslog ]; then
        echo "syslog-file"
    else
        echo "none"
    fi
}

PLATFORM_LOG_BACKEND="$(plat_detect_log_backend || true)"
[ -n "$PLATFORM_LOG_BACKEND" ] || PLATFORM_LOG_BACKEND="none"

# 内核环形缓冲。两台都有 dmesg，且开机即有内容，是唯一可靠的跨平台日志源。
plat_kernel_log() {
    dmesg 2>/dev/null
}

# 本服务在系统日志中的记录。仅用于当次开机的诊断：两台机器的系统日志
# 都放在易失文件系统上，这里拿不到上一次开机的内容。
# 用法: plat_service_log <服务名> [行数]
plat_service_log() {
    local unit="$1"
    local lines="${2:-200}"

    case "$PLATFORM_LOG_BACKEND" in
        journal)
            journalctl -u "$unit" -b --no-pager -n "$lines" 2>/dev/null
            ;;
        syslog-file)
            local f
            for f in /var/log/messages /var/log/syslog; do
                [ -f "$f" ] || continue
                grep -F "$unit" "$f" 2>/dev/null | tail -n "$lines"
            done
            ;;
        *)
            return 1
            ;;
    esac
}

# ==================== 显示栈 ====================

# 输出: wayland | x11 | none
# 注意不能只看 DISPLAY / WAYLAND_DISPLAY 环境变量：由 init 启动的脚本
# 继承不到用户会话的环境，这两个变量必然是空的。因此以 socket 与进程为准。
plat_detect_display() {
    # Wayland：weston 在运行且 compositor socket 已建立。
    # socket 的位置不固定，Buildroot 上 weston 以 root 运行时落在 /run 下，
    # 常规发行版则在 /run/user/<uid>/ 里。
    local sock
    for sock in /run/wayland-[0-9] /run/user/*/wayland-[0-9]; do
        if [ -S "$sock" ]; then
            echo "wayland"
            return 0
        fi
    done

    # X11：Xorg 在运行，或存在 X 的 unix socket
    if plat_service_is_active "display-manager" Xorg X; then
        echo "x11"
        return 0
    fi
    if [ -S /tmp/.X11-unix/X0 ]; then
        echo "x11"
        return 0
    fi

    echo "none"
    return 1
}

# 供显示脚本使用：把 Wayland 环境变量补齐到当前 shell。
# 只在检测到 wayland 时有意义，找不到 socket 时保持环境不变并返回非 0。
plat_export_wayland_env() {
    local sock
    for sock in /run/wayland-[0-9] /run/user/*/wayland-[0-9]; do
        [ -S "$sock" ] || continue
        XDG_RUNTIME_DIR="$(dirname "$sock")"
        WAYLAND_DISPLAY="$(basename "$sock")"
        export XDG_RUNTIME_DIR WAYLAND_DISPLAY
        return 0
    done
    return 1
}

# ==================== 重启状态事务 ====================
# 倒计时不持有此锁；发布、取消与最终提交才持锁，防止取消后复活计划。
plat_lock_reboot_state() {
    local directory="$1" boot_id
    if ! plat_has_flock; then
        echo "错误: 循环重启需要 flock 才能安全取消/提交，本机未提供该命令" >&2
        return 1
    fi
    exec 7>"${directory}/.reboot_state.lock" || return 1
    if ! flock -n 7; then
        echo "重启状态正在提交，请稍后重试" >&2
        exec 7>&-
        return 1
    fi
    boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || { exec 7>&-; return 1; }
    if [ -z "$boot_id" ] || [ "$boot_id" = "$(cat "${directory}/.reboot_committed" 2>/dev/null)" ]; then
        echo "重启已提交或启动标识不可用，不能再更改本次计划" >&2
        exec 7>&-
        return 1
    fi
}

plat_cancel_reboot() (
    local directory="$1"
    plat_lock_reboot_state "$directory" || return 1
    rm -f -- "${directory}/reboot_remaining.txt" "${directory}/.reboot_committed"
)

plat_commit_reboot() (
    local directory="$1" expected="$2" remaining tmp boot_id
    local state="${directory}/reboot_remaining.txt"
    plat_lock_reboot_state "$directory" || return 1
    if [ "$(cat "$state" 2>/dev/null)" != "$expected" ]; then
        echo "重启计划已取消或变更，本次不再重启"
        return 0
    fi
    [[ "$expected" =~ ^[0-9]{1,18}$ ]] || return 1
    remaining=$((10#$expected))
    [ "$remaining" -gt 0 ] || return 0
    tmp=$(mktemp "${state}.XXXXXX") || return 1
    trap 'rm -f -- "$tmp"' EXIT
    if ! printf '%s\n' "$((remaining - 1))" > "$tmp" || ! plat_atomic_replace "$tmp" "$state"; then
        echo "错误: 无法保存剩余次数，已停止重启" >&2
        return 1
    fi
    boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    if ! printf '%s\n' "$boot_id" > "${directory}/.reboot_committed"; then
        printf '%s\n' "$remaining" > "$state"
        echo "错误: 无法保存重启提交状态" >&2
        return 1
    fi
    sync
    if ! reboot; then
        printf '%s\n' "$remaining" > "$state"
        rm -f -- "${directory}/.reboot_committed"
        sync
        echo "错误: 重启命令失败，剩余次数已保留" >&2
        return 1
    fi
)

# ==================== 基础命令兼容层 ====================
# Ubuntu/Debian/CentOS/麒麟/UOS 使用完整 coreutils；Buildroot 多为 BusyBox，
# mv/flock/timeout 的能力子集不同。此处只封装会导致功能不可用的差异。

plat_has_flock() {
    command -v flock >/dev/null 2>&1
}

# 原子替换。BusyBox mv 没有 -T，目标恒为文件路径，因此只拒绝目录目标。
plat_atomic_replace() {
    local src="$1" dest="$2"
    [ -f "$src" ] || return 1
    [ ! -d "$dest" ] || return 1
    mv -f "$src" "$dest"
}

# 超时执行：优先 timeout -k，退化到不带 -k，再退化到自带看门狗。
plat_timeout() {
    local secs="$1"; shift
    if [ -z "${PLATFORM_TIMEOUT_MODE:-}" ]; then
        if ! command -v timeout >/dev/null 2>&1; then
            PLATFORM_TIMEOUT_MODE="manual"
        elif timeout -k 1 5 true >/dev/null 2>&1; then
            PLATFORM_TIMEOUT_MODE="kill"
        else
            PLATFORM_TIMEOUT_MODE="plain"
        fi
    fi
    case "$PLATFORM_TIMEOUT_MODE" in
        kill)
            timeout -k 5 "$secs" "$@"
            ;;
        plain)
            timeout "$secs" "$@"
            ;;
        manual)
            local pid wd rc=0
            "$@" &
            pid=$!
            ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
            wd=$!
            wait "$pid" || rc=$?
            kill -TERM "$wd" 2>/dev/null || true
            wait "$wd" 2>/dev/null || true
            [ "$rc" -eq 143 ] && rc=124
            return "$rc"
            ;;
    esac
}

# ==================== 服务管理 ====================

plat_service_file() {
    case "$PLATFORM_INIT" in
        systemd) echo "/etc/systemd/system/boot-monitor.service" ;;
        busybox) echo "/etc/init.d/S99boot-monitor" ;;
        *) echo "/etc/init.d/boot-monitor" ;;
    esac
}

plat_service_enabled() {
    case "$PLATFORM_INIT" in
        systemd)
            systemctl is-enabled "$1" >/dev/null 2>&1
            ;;
        busybox)
            [ -x "$(plat_service_file)" ]
            ;;
        *)
            local name="${1%.service}"
            ls /etc/rc[2-5].d/S*"$name" >/dev/null 2>&1 ||
                ls /etc/rc.d/rc[2-5].d/S*"$name" >/dev/null 2>&1
            ;;
    esac
}

plat_service_enable() {
    case "$PLATFORM_INIT" in
        systemd) systemctl enable "$1" ;;
        busybox) chmod +x "$(plat_service_file)" ;;
        *)
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d "${1%.service}" defaults
            else
                chmod +x "$(plat_service_file)"
            fi
            ;;
    esac
}

plat_service_disable() {
    case "$PLATFORM_INIT" in
        systemd) systemctl disable "$1" ;;
        busybox) chmod -x "$(plat_service_file)" ;;
        *)
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d -f "${1%.service}" remove
            else
                chmod -x "$(plat_service_file)"
            fi
            ;;
    esac
}

# 展示服务状态；非 systemd 平台没有 systemctl status，退化为脚本/计数信息。
plat_service_status() {
    local unit="$1"
    if [ "$PLATFORM_INIT" = "systemd" ]; then
        systemctl status "$unit" --no-pager 2>/dev/null | head -10
    else
        echo "  init 系统: $PLATFORM_INIT"
        echo "  启动脚本: $(plat_service_file)"
        if plat_service_enabled "$unit"; then
            echo "  开机运行: 已启用"
        else
            echo "  开机运行: 未启用"
        fi
        echo "  开机次数: $(cat /opt/boot_monitor/boot_count.txt 2>/dev/null || echo 未初始化)"
    fi
}

# 查看最近的服务日志；无 journal 时给出文件日志位置。
plat_service_logs() {
    local unit="$1" lines="${2:-50}"
    case "$PLATFORM_LOG_BACKEND" in
        journal)
            journalctl -u "$unit" -n "$lines" --no-pager 2>/dev/null
            ;;
        *)
            local latest
            latest=$(ls -t /opt/boot_monitor/logs/boot/boot_*.log 2>/dev/null | head -1)
            if [ -n "$latest" ]; then
                echo "日志文件: $latest"
                tail -n "$lines" "$latest"
            else
                echo "暂无详细启动日志；摘要:"
                tail -n "$lines" /opt/boot_monitor/logs/boot/normal_summary.log 2>/dev/null ||
                    echo "  无日志记录"
            fi
            ;;
    esac
}

# ==================== 自检 ====================
# 直接执行本文件时打印探测结果，便于在新机器上快速确认适配情况。
if [ "$(basename "${0##-}")" = "platform.sh" ]; then
    echo "PLATFORM_INIT        = ${PLATFORM_INIT}"
    echo "PLATFORM_LOG_BACKEND = ${PLATFORM_LOG_BACKEND}"
    echo "display backend      = $(plat_detect_display)"
    echo "/var/log volatile    = $(plat_path_is_volatile /var/log && echo yes || echo no)"
    echo "/opt volatile        = $(plat_path_is_volatile /opt && echo yes || echo no)"
    if plat_export_wayland_env; then
        echo "wayland env          = XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
    else
        echo "wayland env          = (no socket)"
    fi
    echo "kernel log lines     = $(plat_kernel_log | wc -l)"
fi
