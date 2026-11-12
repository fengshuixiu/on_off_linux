#!/bin/bash
#
# Linux 硬件检测脚本（纯系统内部文件检测，无外部依赖）
# 功能：通过 /sys 和 /proc 文件系统检测硬件设备状态
#
# 检测项目：串口、网络、USB、WiFi、4G模块、显示、音频、硬盘(eMMC/NVMe/SATA)
# 支持系统：Ubuntu, CentOS, Debian, RHEL 等主流 Linux 发行版
#

# 启用 nullglob：glob 无匹配时返回空而不是原字符串
shopt -s nullglob

# 设置字符编码环境（支持中英文字符）
if locale -a 2>/dev/null | grep -q 'C.UTF-8\|C.utf8'; then
    export LANG="C.UTF-8"
elif locale -a 2>/dev/null | grep -q 'en_US.UTF-8\|en_US.utf8'; then
    export LANG="en_US.UTF-8"
else
    export LANG="C"
fi
export LC_ALL="$LANG" 2>/dev/null || true

# 颜色定义（支持禁用）
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# 检测结果统计
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
SKIPPED_CHECKS=0

# 打印分隔线
print_separator() {
    echo "------------------------------------------------------------"
}

# 打印检测项标题
print_title() {
    echo -e "\n${YELLOW}[$1]${NC}"
    print_separator
}

# 记录检测结果
# PASS/FAIL 用于"该子系统存在且正常/异常"；SKIP 用于本机未配置的可选硬件。
# 可选硬件是否缺失由首次开机基准比对判定，这里不制造每日红色失败。
record_result() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    case "$1" in
        PASS)
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
            echo -e "${GREEN}✓ $2${NC}"
            ;;
        SKIP)
            SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
            echo -e "${BLUE}○ $2${NC}"
            ;;
        *)
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
            echo -e "${RED}✗ $2${NC}"
            ;;
    esac
}

# 开始检测
echo "============================================"
echo "硬件设备检测报告"
echo "检测时间: $(date '+%Y-%m-%d %H:%M:%S')"
# 设备标识行（"  - " 开头的行）的格式版本。它是硬件差异比对的键，
# 格式一变，旧基准就不再可比。boot_counter.sh 靠这一行识别旧基准并重建，
# 而不是把全部设备同时报成丢失和新增。修改设备标识行格式时必须同步递增。
echo "设备标识格式: v5"
echo "============================================"

# 1. 串口设备检测（使用 /sys 和 /dev）
print_title "串口设备检测"
SERIAL_COUNT=0

# 检测标准串口 ttyS*
# x86 上 ttyS0-3 常由 8250 驱动预注册，即使主板没有物理串口也会存在，
# 只有"有后端设备且类型不是 PORT_UNKNOWN(0)"的节点才是真实串口。
for port in /dev/ttyS[0-9]*; do
    if [ -e "$port" ]; then
        PORT_NUM=${port##*/ttyS}
        SYS_PATH="/sys/class/tty/ttyS${PORT_NUM}"
        if [ -d "$SYS_PATH" ] && [ -e "$SYS_PATH/device" ]; then
            PORT_TYPE=""
            [ -f "$SYS_PATH/type" ] && PORT_TYPE=$(cat "$SYS_PATH/type" 2>/dev/null)
            [ "$PORT_TYPE" = "0" ] && continue
            echo "  - $port"
            [ -f "$SYS_PATH/device/resources" ] && echo "    状态: 活动" || echo "    状态: 存在"
            SERIAL_COUNT=$((SERIAL_COUNT + 1))
        fi
    fi
done

# 检测 USB 串口
for port in /dev/ttyUSB[0-9]* /dev/ttyACM[0-9]*; do
    if [ -e "$port" ]; then
        echo "  - $port (USB串口)"
        SERIAL_COUNT=$((SERIAL_COUNT + 1))
    fi
done

if [ $SERIAL_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $SERIAL_COUNT 个串口设备"
else
    record_result "SKIP" "未检测到串口设备（按本机配置跳过；后续丢失由基准比对告警）"
fi

# 2. 网络接口检测（使用 /sys/class/net）
print_title "网络接口检测"
NET_COUNT=0
VIRT_NET_COUNT=0

for iface in /sys/class/net/*; do
    # /sys/class/net 下除了接口目录，还有 bonding_masters 这类普通文件，
    # 它们不是设备，必须先按目录过滤掉，否则会多报一个没有任何
    # 属性的假接口。
    [ -d "$iface" ] || continue
    IFACE_NAME=$(basename $iface)
    [ "$IFACE_NAME" = "lo" ] && continue

    # CAN 接口也挂在 /sys/class/net 下，但不是网卡，交由 CAN 段统计
    IFACE_TYPE=""
    [ -f "$iface/type" ] && IFACE_TYPE=$(cat "$iface/type" 2>/dev/null)
    if [ "$IFACE_TYPE" = "280" ]; then
        echo "    CAN接口: $IFACE_NAME（见 CAN 设备检测）"
        continue
    fi
    
    # 有 /sys/class/net/X/device 的才是物理网卡；docker0、veth*、br-*、
    # tun* 等虚拟接口会随容器/虚机启停出现和消失，写进基准会造成
    # 每次开机误报硬件新增或丢失，因此只展示、不参与比对。
    if [ ! -e "$iface/device" ]; then
        echo "    虚拟接口: $IFACE_NAME"
        VIRT_NET_COUNT=$((VIRT_NET_COUNT + 1))
        continue
    fi

    # MAC 是接口的稳定身份，放进设备标识行参与硬件差异比对，
    # 这样换网卡能被发现；而状态、速度、IP 会随插拔和网络环境变化，
    # 只作展示不参与比对。
    MAC=""
    ASSIGN_TYPE=""
    [ -f "$iface/address" ] && MAC=$(cat $iface/address 2>/dev/null)
    [ -f "$iface/addr_assign_type" ] && ASSIGN_TYPE=$(cat "$iface/addr_assign_type" 2>/dev/null)

    # WiFi 的 MAC 会被随机化，systemd 的可预测命名 wlx<MAC> 也随之变化，
    # 写进基准就会每次开机都报"新增+丢失"。无线模块是否存在由 USB/PCI 段
    # 判断，因此无线接口整行只做展示，不参与硬件比对。
    if [ -e "$iface/wireless" ] || [ -e "$iface/phy80211" ]; then
        echo "    无线网卡: $IFACE_NAME [MAC:${MAC:-未知}]（不参与硬件比对）"
        if [ -f "$iface/operstate" ]; then
            echo "    状态: $(cat "$iface/operstate" 2>/dev/null)"
        fi
        NET_COUNT=$((NET_COUNT + 1))
        continue
    fi

    # addr_assign_type 非 0 说明 MAC 不是烧录地址。qmi_wwan / cdc_mbim 这类
    # 蜂窝网卡每次开机换一个随机 MAC（111 真机 9 次重启采到 9 个地址），
    # 带进基准必然误报；接口名本身稳定，用名称做身份即可。
    if [ -n "$ASSIGN_TYPE" ] && [ "$ASSIGN_TYPE" != "0" ]; then
        echo "  - $IFACE_NAME"
        echo "    地址: ${MAC:-无}（非烧录地址，不参与硬件比对）"
    elif [ -n "$MAC" ]; then
        echo "  - $IFACE_NAME [MAC:$MAC]"
    else
        echo "  - $IFACE_NAME"
    fi
    
    # 读取状态
    if [ -f "$iface/operstate" ]; then
        STATE=$(cat $iface/operstate)
        echo "    状态: $STATE"
    fi
    
    # 读取速度
    if [ -f "$iface/speed" ]; then
        SPEED=$(cat $iface/speed 2>/dev/null)
        if [ "$SPEED" != "-1" ] && [ -n "$SPEED" ] 2>/dev/null; then
            echo "    速度: ${SPEED}Mbps"
        fi
    fi
    
    # 读取 IP 地址（ip 命令可选，缺失时跳过该展示项）
    if command -v ip >/dev/null 2>&1; then
        IP=$(ip addr show "$IFACE_NAME" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
        [ -n "$IP" ] && echo "    IP: $IP"
    fi
    
    NET_COUNT=$((NET_COUNT + 1))
done

if [ $NET_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $NET_COUNT 个物理网络接口"
elif [ $VIRT_NET_COUNT -gt 0 ]; then
    # 虚拟机/容器只有虚拟网卡，不属于硬件缺失
    record_result "SKIP" "仅检测到 $VIRT_NET_COUNT 个虚拟网络接口（不参与硬件比对）"
else
    record_result "FAIL" "未检测到网络接口"
fi

# 3. USB 设备检测（使用 /sys/bus/usb/devices）
print_title "USB 设备检测"
USB_COUNT=0

if [ -d /sys/bus/usb/devices ]; then
    for usb in /sys/bus/usb/devices/*; do
        if [ -f "$usb/idVendor" ] && [ -f "$usb/idProduct" ]; then
            VENDOR=$(cat $usb/idVendor 2>/dev/null)
            PRODUCT=$(cat $usb/idProduct 2>/dev/null)
            MANUFACTURER=$(cat $usb/manufacturer 2>/dev/null)
            PROD_NAME=$(cat $usb/product 2>/dev/null)
            
            if [ -n "$VENDOR" ] && [ -n "$PRODUCT" ]; then
                echo "  - USB设备: ${VENDOR}:${PRODUCT}"
                [ -n "$MANUFACTURER" ] && echo "    制造商: $MANUFACTURER"
                [ -n "$PROD_NAME" ] && echo "    产品: $PROD_NAME"
                USB_COUNT=$((USB_COUNT + 1))
            fi
        fi
    done
    
    if [ $USB_COUNT -gt 0 ]; then
        record_result "PASS" "检测到 $USB_COUNT 个USB设备"
    else
        record_result "FAIL" "未检测到USB设备"
    fi
else
    record_result "FAIL" "USB系统路径不存在"
fi

# 4. WiFi 设备检测（仅检测设备存在，不检测信号强度）
print_title "WiFi 设备检测"
WIFI_COUNT=0

# 从 /proc/net/wireless 读取无线设备（使用进程替换避免子shell问题）
if [ -f /proc/net/wireless ]; then
    while read line; do
        WIFI_IFACE=$(echo $line | awk -F: '{print $1}' | tr -d ' ')
        if [ -n "$WIFI_IFACE" ]; then
            # 无线接口整行不参与硬件比对（MAC 会随机化），此处只展示状态。
            echo "    无线接口: $WIFI_IFACE"
            
            # 检查设备状态
            if [ -d "/sys/class/net/$WIFI_IFACE" ]; then
                STATE=$(cat /sys/class/net/$WIFI_IFACE/operstate 2>/dev/null)
                echo "    状态: $STATE"
                
                # 读取 MAC
                MAC=$(cat /sys/class/net/$WIFI_IFACE/address 2>/dev/null)
                [ -n "$MAC" ] && echo "    MAC: $MAC"
            fi
            WIFI_COUNT=$((WIFI_COUNT + 1))
        fi
    done < <(tail -n +3 /proc/net/wireless 2>/dev/null)
fi

# 如果没有找到，检查网络设备中的无线设备
if [ $WIFI_COUNT -eq 0 ]; then
    for iface in /sys/class/net/w*; do
        if [ -d "$iface/wireless" ] || [ -d "$iface/phy80211" ]; then
            IFACE_NAME=$(basename $iface)
            echo "    无线接口: $IFACE_NAME"
            STATE=$(cat $iface/operstate 2>/dev/null)
            echo "    状态: $STATE"
            WIFI_COUNT=$((WIFI_COUNT + 1))
        fi
    done
fi

if [ $WIFI_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $WIFI_COUNT 个WiFi设备"
else
    record_result "SKIP" "未检测到WiFi设备（按本机配置跳过）"
fi

# 5. 4G/LTE 模块检测（仅检测设备存在，不检测信号强度）
print_title "4G/LTE 模块检测"
MODEM_COUNT=0

# 检查 WWAN 网络接口
for iface in /sys/class/net/*wwan*; do
    if [ -d "$iface" ]; then
        IFACE_NAME=$(basename $iface)
        echo "    WWAN接口: $IFACE_NAME"
        STATE=$(cat $iface/operstate 2>/dev/null)
        echo "    状态: $STATE"
        MODEM_COUNT=$((MODEM_COUNT + 1))
    fi
done

# 检查 USB 调制解调器设备
# 关键词必须整体匹配：realtek 里含有 lte 子串，用子串匹配会把
# Realtek WiFi 网卡误判为 4G 模块。
for usb in /sys/bus/usb/devices/*; do
    if [ -f "$usb/product" ]; then
        PRODUCT=$(cat $usb/product 2>/dev/null | tr '[:upper:]' '[:lower:]')
        MANUFACTURER=$(cat $usb/manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if echo "$PRODUCT $MANUFACTURER" | grep -qwE 'modem|lte|4g|5g|wwan|qualcomm|quectel|fibocom|simcom|meig|telit|sierra|thales|huawei'; then
            VENDOR=$(cat $usb/idVendor 2>/dev/null)
            PROD_ID=$(cat $usb/idProduct 2>/dev/null)
            echo "  - 4G模块: ${VENDOR}:${PROD_ID}"
            echo "    产品: $(cat $usb/product 2>/dev/null)"
            MODEM_COUNT=$((MODEM_COUNT + 1))
        fi
    fi
done

# 检查 cdc-wdm 设备
for dev in /dev/cdc-wdm*; do
    if [ -e "$dev" ]; then
        echo "  - $dev (调制解调器设备)"
        MODEM_COUNT=$((MODEM_COUNT + 1))
    fi
done

if [ $MODEM_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $MODEM_COUNT 个4G/LTE模块相关设备"
else
    record_result "SKIP" "未检测到4G模块（按本机配置跳过）"
fi

# 6. 显示设备检测（使用 /sys/class/drm）
print_title "显示设备检测"
DISPLAY_COUNT=0

# 检查 DRM 设备
# 适配器是 cardN；连接器状态在 cardN-<conn>/status。原实现读 cardN/status
# 永远读不到，"拔屏/黑屏"检测实际失效，这里按连接器逐个读取。
if [ -d /sys/class/drm ]; then
    for card in /sys/class/drm/card[0-9]*; do
        CARD_NAME=$(basename "$card")
        # card0-DP-1 这类连接器不是适配器，必须按名称精确排除
        [[ "$CARD_NAME" =~ ^card[0-9]+$ ]] || continue
        [ -d "$card/device" ] || continue

        VENDOR_ID=""
        DEVICE_ID=""
        [ -f "$card/device/vendor" ] && VENDOR_ID=$(cat "$card/device/vendor" 2>/dev/null)
        [ -f "$card/device/device" ] && DEVICE_ID=$(cat "$card/device/device" 2>/dev/null)
        echo "  - $CARD_NAME [${VENDOR_ID:-未知}:${DEVICE_ID:-未知}]"

        # 已连接的接口写入标识行：显示器被拔掉后该行消失，基准比对即可告警
        for conn in "$card"-*; do
            [ -d "$conn" ] || continue
            CONN_NAME=$(basename "$conn")
            CONN_STATUS=$(cat "$conn/status" 2>/dev/null)
            if [ "$CONN_STATUS" = "connected" ]; then
                echo "  - $CONN_NAME [connected]"
            elif [ -n "$CONN_STATUS" ]; then
                echo "    接口 $CONN_NAME: $CONN_STATUS"
            fi
        done

        DISPLAY_COUNT=$((DISPLAY_COUNT + 1))
    done

    # 检查 framebuffer 设备
    for fb in /dev/fb[0-9]*; do
        if [ -e "$fb" ]; then
            echo "  - $fb (Framebuffer)"
        fi
    done
fi

# 只有 framebuffer、没有 DRM 的嵌入式平台（部分 Buildroot 配置）
if [ $DISPLAY_COUNT -eq 0 ]; then
    for fb in /dev/fb[0-9]*; do
        if [ -e "$fb" ]; then
            echo "  - $fb (Framebuffer，无 DRM 适配器)"
            DISPLAY_COUNT=$((DISPLAY_COUNT + 1))
        fi
    done
fi

if [ $DISPLAY_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $DISPLAY_COUNT 个显示适配器"
else
    record_result "SKIP" "未检测到显示设备（按本机配置跳过）"
fi

# 7. 音频设备检测（使用 /proc/asound 和 /sys/class/sound）
print_title "音频设备检测"
AUDIO_COUNT=0

# 检查 /proc/asound
if [ -d /proc/asound ]; then
    for card in /proc/asound/card[0-9]*; do
        if [ -d "$card" ]; then
            CARD_NUM=$(basename $card | sed 's/card//')
            CARD_ID=$(cat $card/id 2>/dev/null)
            echo "  - 声卡$CARD_NUM: $CARD_ID"
            
            # 读取声卡信息
            if [ -f "$card/codec#0" ]; then
                CODEC=$(grep 'Codec:' $card/codec#0 2>/dev/null | head -1)
                [ -n "$CODEC" ] && echo "    $CODEC"
            fi
            
            # 检查 PCM 设备
            for pcm in $card/pcm*; do
                if [ -d "$pcm" ]; then
                    PCM_NAME=$(basename $pcm)
                    # info 里 name 与 subname 都含 "name:"，只取 name 行的值，
                    # 否则多条结果会把报告输出撑成错乱的多行。
                    PCM_INFO=$(sed -n 's/^[[:space:]]*name[[:space:]]*:[[:space:]]*\(.*\)$/\1/p' "$pcm/info" 2>/dev/null | head -1)
                    [ -n "$PCM_INFO" ] && echo "    $PCM_NAME: $PCM_INFO"
                fi
            done
            
            AUDIO_COUNT=$((AUDIO_COUNT + 1))
        fi
    done
fi

# 检查 /sys/class/sound
if [ $AUDIO_COUNT -eq 0 ] && [ -d /sys/class/sound ]; then
    for snd in /sys/class/sound/card[0-9]*; do
        if [ -d "$snd" ]; then
            CARD_NAME=$(basename $snd)
            echo "  - $CARD_NAME"
            AUDIO_COUNT=$((AUDIO_COUNT + 1))
        fi
    done
fi

if [ $AUDIO_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $AUDIO_COUNT 个音频设备"
else
    record_result "SKIP" "未检测到音频设备（按本机配置跳过）"
fi

# 8. 硬盘设备检测（使用 /sys/block）
print_title "存储设备检测"
STORAGE_COUNT=0

# 遍历所有块设备
# 容量按实际字节格式化：小于 1GB 的盘按整 GB 取整会显示 0GB，
# 换盘或容量变化就无法通过基准比对发现。
format_disk_size() {
    local sectors="$1" bytes
    [[ "$sectors" =~ ^[0-9]+$ ]] || { echo "未知"; return; }
    bytes=$((sectors * 512))
    if [ "$bytes" -ge $((1024 * 1024 * 1024)) ]; then
        echo "$((bytes / 1024 / 1024 / 1024))GB"
    elif [ "$bytes" -ge $((1024 * 1024)) ]; then
        echo "$((bytes / 1024 / 1024))MB"
    else
        echo "$((bytes / 1024))KB"
    fi
}

# sysfs 的型号/厂商字段按定长补齐，两端空格会写进设备标识行
read_attr() {
    local file="$1"
    [ -f "$file" ] || return 0
    tr -s ' ' < "$file" 2>/dev/null | sed 's/^ *//; s/ *$//'
}

for block in /sys/block/*; do
    BLOCK_NAME=$(basename $block)
    
    # 跳过循环设备、内存设备、软 RAID、网络块设备及光驱
    # mmcblkXbootN / mmcblkXrpmb 是 eMMC 的引导与回放保护分区，容量报 0，
    # 它们不是独立的存储设备，计入总数会把一块 eMMC 算成三个设备。
    case $BLOCK_NAME in
        loop*|ram*|dm-*|zram*|nbd*|sr*) continue ;;
        mmcblk*boot*|mmcblk*rpmb) continue ;;
    esac
    
    DEV_PATH="/dev/$BLOCK_NAME"
    if [ ! -e "$DEV_PATH" ]; then
        continue
    fi
    
    SECTORS=$(cat $block/size 2>/dev/null)
    SIZE_TEXT=$(format_disk_size "$SECTORS")
    
    # 设备标识行带上型号与容量，让换盘、换容量能被硬件差异比对发现。
    # 寿命、厂商这类会随使用变化或可能缺失的信息仍然只作展示。
    if [[ $BLOCK_NAME == mmcblk* ]]; then
        # eMMC/SD 卡
        MODEL=$(read_attr "$block/device/name")
        echo "  - $DEV_PATH (eMMC/SD) [型号:${MODEL:-未知} 容量:${SIZE_TEXT}]"
        echo "    容量: ${SIZE_TEXT}"
        
        # 健康信息
        if [ -f "$block/device/life_time" ]; then
            LIFE=$(cat $block/device/life_time 2>/dev/null)
            echo "    寿命: $LIFE"
        fi
        STORAGE_COUNT=$((STORAGE_COUNT + 1))
        
    elif [[ $BLOCK_NAME == nvme* ]]; then
        # NVMe SSD
        MODEL=$(read_attr "$block/device/model")
        echo "  - $DEV_PATH (NVMe SSD) [型号:${MODEL:-未知} 容量:${SIZE_TEXT}]"
        echo "    容量: ${SIZE_TEXT}"
        
        # 读取序列号
        if [ -f "$block/device/serial" ]; then
            SERIAL=$(read_attr "$block/device/serial")
            [ -n "$SERIAL" ] && echo "    序列号: $SERIAL"
        fi
        STORAGE_COUNT=$((STORAGE_COUNT + 1))
        
    elif [[ $BLOCK_NAME == sd* ]]; then
        # SATA/SCSI/USB 设备
        ROTA=$(cat $block/queue/rotational 2>/dev/null)
        if [ "$ROTA" = "0" ]; then
            TYPE="SSD"
        else
            TYPE="HDD"
        fi
        
        MODEL=$(read_attr "$block/device/model")
        echo "  - $DEV_PATH (SATA/SCSI $TYPE) [型号:${MODEL:-未知} 容量:${SIZE_TEXT}]"
        echo "    容量: ${SIZE_TEXT}"
        
        # 读取vendor
        if [ -f "$block/device/vendor" ]; then
            VENDOR=$(read_attr "$block/device/vendor")
            [ -n "$VENDOR" ] && echo "    厂商: $VENDOR"
        fi
        STORAGE_COUNT=$((STORAGE_COUNT + 1))
        
    elif [[ $BLOCK_NAME == hd* ]]; then
        # IDE 设备
        MODEL=$(read_attr "$block/device/model")
        echo "  - $DEV_PATH (IDE) [型号:${MODEL:-未知} 容量:${SIZE_TEXT}]"
        echo "    容量: ${SIZE_TEXT}"
        STORAGE_COUNT=$((STORAGE_COUNT + 1))

    elif [[ $BLOCK_NAME == vd* || $BLOCK_NAME == xvd* ]]; then
        # virtio / Xen 虚拟磁盘：虚拟机和部分 ARM 板卡的系统盘就是 vda，
        # 漏掉会误报“未检测到存储设备”。
        MODEL=$(read_attr "$block/device/model")
        echo "  - $DEV_PATH (虚拟磁盘) [型号:${MODEL:-未知} 容量:${SIZE_TEXT}]"
        echo "    容量: ${SIZE_TEXT}"
        STORAGE_COUNT=$((STORAGE_COUNT + 1))
    fi
done

if [ $STORAGE_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $STORAGE_COUNT 个存储设备"
else
    record_result "FAIL" "未检测到存储设备"
fi

# 显示挂载信息
echo ""
echo "挂载点信息:"
if [ -f /proc/mounts ]; then
    grep '^/dev' /proc/mounts | awk '{print "  "$1" -> "$2" ("$3")"}'
fi

# 9. 系统温度检测（使用 /sys/class/thermal）
# 注意：温度不作为硬件对比项，只检查范围（-45到102度为正常）
print_title "系统温度检测（仅范围检查，不参与硬件对比）"
TEMP_COUNT=0
TEMP_ABNORMAL=0
# 已发现的传感器节点数。用来区分两件不同的事：本平台根本不提供
# 温度接口（不是故障），还是接口存在但读不出值（是故障）。
TEMP_NODES=0
TEMP_MIN=-45
TEMP_MAX=102

if [ -d /sys/class/thermal ]; then
    for zone in /sys/class/thermal/thermal_zone*; do
        if [ -f "$zone/temp" ]; then
            TEMP_NODES=$((TEMP_NODES + 1))
            TEMP=$(cat $zone/temp 2>/dev/null)
            if [[ "$TEMP" =~ ^-?[0-9]{1,9}$ ]]; then
                TEMP_SIGN=1
                [[ "$TEMP" == -* ]] && TEMP_SIGN=-1
                TEMP=$((TEMP_SIGN * 10#${TEMP#-}))
                TEMP_C=$((TEMP / 1000))
                ZONE_TYPE=$(cat $zone/type 2>/dev/null)
                
                # 检查温度范围（-45 到 102 度）
                if [ "$TEMP" -ge "$((TEMP_MIN * 1000))" ] && [ "$TEMP" -le "$((TEMP_MAX * 1000))" ]; then
                    echo "    ${ZONE_TYPE}: ${TEMP_C}°C [正常]"
                else
                    echo "    ${ZONE_TYPE}: ${TEMP_C}°C [异常！超出范围 ${TEMP_MIN}~${TEMP_MAX}°C]"
                    TEMP_ABNORMAL=$((TEMP_ABNORMAL + 1))
                fi
                TEMP_COUNT=$((TEMP_COUNT + 1))
            fi
        fi
    done
fi

# 检查 hwmon 设备
if [ -d /sys/class/hwmon ]; then
    for hwmon in /sys/class/hwmon/hwmon*; do
        HWMON_NAME=$(cat $hwmon/name 2>/dev/null)
        for temp_input in $hwmon/temp*_input; do
            if [ -f "$temp_input" ]; then
                TEMP_NODES=$((TEMP_NODES + 1))
                TEMP=$(cat $temp_input 2>/dev/null)
                if [[ "$TEMP" =~ ^-?[0-9]{1,9}$ ]]; then
                    TEMP_SIGN=1
                    [[ "$TEMP" == -* ]] && TEMP_SIGN=-1
                    TEMP=$((TEMP_SIGN * 10#${TEMP#-}))
                    TEMP_C=$((TEMP / 1000))
                    LABEL_FILE="${temp_input/_input/_label}"
                    if [ -f "$LABEL_FILE" ]; then
                        LABEL=$(cat $LABEL_FILE 2>/dev/null)
                    else
                        LABEL=$(basename $temp_input)
                    fi
                    
                    # 检查温度范围（-45 到 102 度）
                    if [ "$TEMP" -ge "$((TEMP_MIN * 1000))" ] && [ "$TEMP" -le "$((TEMP_MAX * 1000))" ]; then
                        echo "    ${HWMON_NAME} ${LABEL}: ${TEMP_C}°C [正常]"
                    else
                        echo "    ${HWMON_NAME} ${LABEL}: ${TEMP_C}°C [异常！超出范围 ${TEMP_MIN}~${TEMP_MAX}°C]"
                        TEMP_ABNORMAL=$((TEMP_ABNORMAL + 1))
                    fi
                    TEMP_COUNT=$((TEMP_COUNT + 1))
                fi
            fi
        done
    done
fi

TEMP_READ_ERRORS=$((TEMP_NODES - TEMP_COUNT))
if [ $TEMP_COUNT -gt 0 ]; then
    if [ "$TEMP_READ_ERRORS" -gt 0 ]; then
        record_result "FAIL" "检测到 $TEMP_NODES 个温度节点，$TEMP_READ_ERRORS 个读取失败，$TEMP_ABNORMAL 个温度异常"
    elif [ $TEMP_ABNORMAL -gt 0 ]; then
        record_result "FAIL" "检测到 $TEMP_COUNT 个温度传感器，$TEMP_ABNORMAL 个温度异常！"
    else
        record_result "PASS" "检测到 $TEMP_COUNT 个温度传感器，全部正常（${TEMP_MIN}~${TEMP_MAX}°C范围内）"
    fi
elif [ $TEMP_NODES -gt 0 ]; then
    record_result "FAIL" "发现 $TEMP_NODES 个温度传感器节点，但全部读取失败"
else
    # 本平台没有温度传感器接口，这不是故障，不能计入失败项——
    # 否则每次开机都会多一条永不消失的失败记录，把真正的异常淹没。
    echo "    本平台未提供温度传感器接口（/sys/class/thermal 与 /sys/class/hwmon 均无可读节点），跳过"
fi

# 10. PCI 设备检测（使用 /sys/bus/pci/devices）
print_title "PCI 设备检测"
PCI_COUNT=0

if [ -d /sys/bus/pci/devices ]; then
    for pci in /sys/bus/pci/devices/*; do
        PCI_ADDR=$(basename $pci)
        
        # 读取设备信息
        if [ -f "$pci/vendor" ] && [ -f "$pci/device" ]; then
            VENDOR=$(cat $pci/vendor 2>/dev/null)
            DEVICE=$(cat $pci/device 2>/dev/null)
            
            # 读取设备类型
            if [ -f "$pci/class" ]; then
                CLASS=$(cat $pci/class 2>/dev/null)
                # 解析设备类型
                case ${CLASS:0:4} in
                    0x01) CLASS_NAME="存储控制器" ;;
                    0x02) CLASS_NAME="网络控制器" ;;
                    0x03) CLASS_NAME="显示控制器" ;;
                    0x04) CLASS_NAME="多媒体控制器" ;;
                    0x06) CLASS_NAME="桥接设备" ;;
                    0x0c) CLASS_NAME="串行总线控制器" ;;
                    *) CLASS_NAME="其他设备" ;;
                esac
            else
                CLASS_NAME="未知"
            fi
            
            echo "  - $PCI_ADDR: $CLASS_NAME (${VENDOR}:${DEVICE})"
            PCI_COUNT=$((PCI_COUNT + 1))
        fi
    done
    
    if [ $PCI_COUNT -gt 0 ]; then
        record_result "PASS" "检测到 $PCI_COUNT 个PCI设备"
    else
        record_result "FAIL" "未检测到PCI设备"
    fi
else
    record_result "FAIL" "PCI系统路径不存在"
fi

# 11. CAN 设备检测（使用 /sys/class/net）
print_title "CAN 设备检测"
CAN_COUNT=0

# 检查 CAN 网络接口
for iface in /sys/class/net/*; do
    IFACE_NAME=$(basename $iface)
    
    # 检查是否为 CAN 设备
    if [ -f "$iface/type" ]; then
        TYPE=$(cat $iface/type 2>/dev/null)
        # CAN 设备的类型通常是 280 (ARPHRD_CAN)
        if [ "$TYPE" = "280" ]; then
            echo "  - $IFACE_NAME (CAN接口)"
            
            # 读取状态
            if [ -f "$iface/operstate" ]; then
                STATE=$(cat $iface/operstate 2>/dev/null)
                echo "    状态: $STATE"
            fi
            
            # 读取 CAN 比特率（如果可用）
            if [ -f "$iface/can_bittiming" ]; then
                BITRATE=$(cat $iface/can_bittiming 2>/dev/null | grep 'bitrate' | awk '{print $2}')
                [ -n "$BITRATE" ] && echo "    比特率: $BITRATE bps"
            fi
            
            # 检查 CAN 统计信息
            if [ -d "$iface/statistics" ]; then
                RX=$(cat $iface/statistics/rx_packets 2>/dev/null)
                TX=$(cat $iface/statistics/tx_packets 2>/dev/null)
                [ -n "$RX" ] && [ -n "$TX" ] && echo "    数据包: RX=$RX, TX=$TX"
            fi
            
            CAN_COUNT=$((CAN_COUNT + 1))
        fi
    fi
done

# 同时检查 can* 命名的设备：原实现用"名称是否出现在 ls 输出"做去重，
# 该判断恒为真，且会把 type 不是 280 的设备也当成 CAN，属于无效分支。
# vcan/can 设备的 type 均为 280，第一段循环已覆盖，这里不再重复统计。

if [ $CAN_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $CAN_COUNT 个CAN设备"
else
    record_result "SKIP" "未检测到CAN设备（按本机配置跳过）"
fi

# 生成检测摘要
print_separator
echo ""
echo "============================================"
echo "检测摘要"
echo "============================================"
echo "总检测项: $TOTAL_CHECKS"
echo -e "${GREEN}通过: $PASSED_CHECKS${NC}"
echo -e "${RED}失败: $FAILED_CHECKS${NC}"
echo -e "${BLUE}跳过（本机未配置）: $SKIPPED_CHECKS${NC}"
echo "完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

# 未配置的可选硬件不影响退出码；已发现的传感器异常必须上报调用方。
if [ "$TEMP_ABNORMAL" -gt 0 ] || [ "$TEMP_READ_ERRORS" -gt 0 ]; then
    exit 2
fi
exit 0
