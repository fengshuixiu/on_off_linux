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
record_result() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if [ "$1" == "PASS" ]; then
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        echo -e "${GREEN}✓ $2${NC}"
    else
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        echo -e "${RED}✗ $2${NC}"
    fi
}

# 开始检测
echo "============================================"
echo "硬件设备检测报告"
echo "检测时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

# 1. 串口设备检测（使用 /sys 和 /dev）
print_title "串口设备检测"
SERIAL_COUNT=0

# 检测标准串口 ttyS*（只检测真正活动的串口）
for port in /dev/ttyS[0-9]*; do
    if [ -e "$port" ]; then
        PORT_NUM=${port##*/ttyS}
        SYS_PATH="/sys/class/tty/ttyS${PORT_NUM}"
        if [ -d "$SYS_PATH" ]; then
            # 检查是否真正存在硬件（非虚拟串口）
            if [ -d "$SYS_PATH/device" ] || [ -f "$SYS_PATH/device/resources" ]; then
                echo "  - $port"
                [ -f "$SYS_PATH/device/resources" ] && echo "    状态: 活动" || echo "    状态: 存在"
                SERIAL_COUNT=$((SERIAL_COUNT + 1))
            fi
        fi
    fi
done

# 检测 USB 串口
for port in /dev/ttyUSB[0-9]* /dev/ttyACM[0-9]*; do
    if [ -e "$port" ]; then
        PORT_NAME=$(basename "$port")
        SYS_PATH="/sys/class/tty/${PORT_NAME}"
        echo "  - $port (USB串口)"
        # 尝试获取USB设备信息
        if [ -L "$SYS_PATH/device" ]; then
            DEVICE_PATH=$(readlink -f "$SYS_PATH/device" 2>/dev/null)
            PRODUCT=$(cat "${DEVICE_PATH}/../product" 2>/dev/null)
            [ -n "$PRODUCT" ] && echo "    设备: $PRODUCT"
        fi
        SERIAL_COUNT=$((SERIAL_COUNT + 1))
    fi
done

if [ $SERIAL_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $SERIAL_COUNT 个串口设备:"
else
    record_result "FAIL" "未检测到串口设备"
fi

# 2. 网络接口检测（使用 /sys/class/net）
print_title "网络接口检测"
NET_COUNT=0

for iface in /sys/class/net/*; do
    IFACE_NAME=$(basename "$iface")
    [ "$IFACE_NAME" = "lo" ] && continue
    
    echo "  - $IFACE_NAME"
    
    # 读取状态
    if [ -f "$iface/operstate" ]; then
        STATE=$(cat "$iface/operstate")
        echo "    状态: $STATE"
    fi
    
    # 读取 MAC 地址
    if [ -f "$iface/address" ]; then
        MAC=$(cat "$iface/address")
        echo "    MAC: $MAC"
    fi
    
    # 读取速度
    if [ -f "$iface/speed" ]; then
        SPEED=$(cat "$iface/speed" 2>/dev/null)
        # 检查速度是否有效（非-1且为数字）
        if [ -n "$SPEED" ] && [ "$SPEED" != "-1" ] && [[ "$SPEED" =~ ^[0-9]+$ ]]; then
            echo "    速度: ${SPEED}Mbps"
        fi
    fi
    
    # 读取 IP 地址（兼容方式）
    IP=$(ip addr show $IFACE_NAME 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
    [ -n "$IP" ] && echo "    IP: $IP"
    
    NET_COUNT=$((NET_COUNT + 1))
done

if [ $NET_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $NET_COUNT 个网络接口"
else
    record_result "FAIL" "未检测到网络接口"
fi

# 3. USB 设备检测（使用 /sys/bus/usb/devices）
print_title "USB 设备检测"
USB_COUNT=0

if [ -d /sys/bus/usb/devices ]; then
    for usb in /sys/bus/usb/devices/*; do
        if [ -f "$usb/idVendor" ] && [ -f "$usb/idProduct" ]; then
            VENDOR=$(cat "$usb/idVendor" 2>/dev/null)
            PRODUCT=$(cat "$usb/idProduct" 2>/dev/null)
            MANUFACTURER=$(cat "$usb/manufacturer" 2>/dev/null)
            PROD_NAME=$(cat "$usb/product" 2>/dev/null)
            
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
            echo "  - $WIFI_IFACE"
            
            # 检查设备状态
            if [ -d "/sys/class/net/$WIFI_IFACE" ]; then
                STATE=$(cat "/sys/class/net/$WIFI_IFACE/operstate" 2>/dev/null)
                echo "    状态: $STATE"
                        
                # 读取 MAC
                MAC=$(cat "/sys/class/net/$WIFI_IFACE/address" 2>/dev/null)
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
            IFACE_NAME=$(basename "$iface")
            echo "  - $IFACE_NAME (无线设备)"
            STATE=$(cat "$iface/operstate" 2>/dev/null)
            echo "    状态: $STATE"
            WIFI_COUNT=$((WIFI_COUNT + 1))
        fi
    done
fi

if [ $WIFI_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $WIFI_COUNT 个WiFi设备"
else
    record_result "FAIL" "未检测到WiFi设备"
fi

# 5. 4G/LTE 模块检测（仅检测设备存在，不检测信号强度）
print_title "4G/LTE 模块检测"
MODEM_COUNT=0

# 检查 WWAN 网络接口
for iface in /sys/class/net/wwan* /sys/class/net/*wwan*; do
    if [ -d "$iface" ]; then
        IFACE_NAME=$(basename "$iface")
        echo "  - $IFACE_NAME (WWAN接口)"
        STATE=$(cat "$iface/operstate" 2>/dev/null)
        echo "    状态: $STATE"
        MODEM_COUNT=$((MODEM_COUNT + 1))
    fi
done

# 检查 USB 调制解调器设备
for usb in /sys/bus/usb/devices/*; do
    if [ -f "$usb/product" ]; then
        PRODUCT=$(cat "$usb/product" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if echo "$PRODUCT" | grep -qE 'modem|lte|4g|wwan|qualcomm|huawei.*modem'; then
            VENDOR=$(cat "$usb/idVendor" 2>/dev/null)
            PROD_ID=$(cat "$usb/idProduct" 2>/dev/null)
            echo "  - 4G模块: ${VENDOR}:${PROD_ID}"
            echo "    产品: $(cat "$usb/product" 2>/dev/null)"
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
    record_result "FAIL" "未检测到4G模块"
fi

# 6. 显示设备检测（使用 /sys/class/drm）
print_title "显示设备检测"
DISPLAY_COUNT=0

# 检查 DRM 设备
if [ -d /sys/class/drm ]; then
    for card in /sys/class/drm/card[0-9]*; do
        if [ -d "$card" ] && [ ! -L "$card/device/driver" ] || [ -L "$card/device/driver" ]; then
            CARD_NAME=$(basename "$card")
            # 排除虚拟连接器
            if [ -d "$card/device" ]; then
                echo "  - $CARD_NAME"
                
                # 读取显卡信息
                if [ -f "$card/device/vendor" ] && [ -f "$card/device/device" ]; then
                    VENDOR=$(cat "$card/device/vendor" 2>/dev/null)
                    DEVICE=$(cat "$card/device/device" 2>/dev/null)
                    echo "    设备ID: ${VENDOR}:${DEVICE}"
                fi
                
                # 检查状态
                if [ -f "$card/status" ]; then
                    STATUS=$(cat "$card/status" 2>/dev/null)
                    echo "    状态: $STATUS"
                elif [ -f "$card/enabled" ]; then
                    ENABLED=$(cat "$card/enabled" 2>/dev/null)
                    echo "    启用: $ENABLED"
                fi
                
                DISPLAY_COUNT=$((DISPLAY_COUNT + 1))
            fi
        fi
    done
    
    # 检查 framebuffer 设备
    for fb in /dev/fb[0-9]*; do
        if [ -e "$fb" ]; then
            echo "  - $fb (Framebuffer)"
        fi
    done
fi

if [ $DISPLAY_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $DISPLAY_COUNT 个显示适配器"
else
    record_result "FAIL" "未检测到显示设备"
fi

# 7. 音频设备检测（使用 /proc/asound 和 /sys/class/sound）
print_title "音频设备检测"
AUDIO_COUNT=0

# 检查 /proc/asound
if [ -d /proc/asound ]; then
    for card in /proc/asound/card[0-9]*; do
        if [ -d "$card" ]; then
            CARD_NUM=$(basename "$card" | sed 's/card//')
            CARD_ID=$(cat "$card/id" 2>/dev/null)
            echo "  - 声卡$CARD_NUM: $CARD_ID"
            
            # 读取声卡信息
            if [ -f "$card/codec#0" ]; then
                CODEC=$(grep 'Codec:' "$card/codec#0" 2>/dev/null | head -1)
                [ -n "$CODEC" ] && echo "    $CODEC"
            fi
            
            # 检查 PCM 设备
            for pcm in "$card"/pcm*; do
                if [ -d "$pcm" ]; then
                    PCM_NAME=$(basename "$pcm")
                    PCM_INFO=$(cat "$pcm/info" 2>/dev/null | grep 'name:' | cut -d: -f2)
                    [ -n "$PCM_INFO" ] && echo "    $PCM_NAME:$PCM_INFO"
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
            CARD_NAME=$(basename "$snd")
            echo "  - $CARD_NAME"
            AUDIO_COUNT=$((AUDIO_COUNT + 1))
        fi
    done
fi

if [ $AUDIO_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $AUDIO_COUNT 个音频设备"
else
    record_result "FAIL" "未检测到音频设备"
fi

# 8. 硬盘设备检测（使用 /sys/block）
print_title "存储设备检测"
STORAGE_COUNT=0

# 遍历所有块设备
for block in /sys/block/*; do
    BLOCK_NAME=$(basename "$block")
    
    # 跳过循环设备、内存设备等
    case $BLOCK_NAME in
        loop*|ram*|dm-*) continue ;;
    esac
    
    DEV_PATH="/dev/$BLOCK_NAME"
    if [ ! -e "$DEV_PATH" ]; then
        continue
    fi
    
    # 读取设备大小
    if [ -f "$block/size" ]; then
        SECTORS=$(cat "$block/size" 2>/dev/null)
        SIZE_GB=$((SECTORS * 512 / 1024 / 1024 / 1024))
    else
        SIZE_GB=0
    fi
    
    # 判断设备类型
    if echo "$BLOCK_NAME" | grep -q '^mmcblk'; then
        # eMMC/SD 卡
        echo "  - $DEV_PATH (eMMC/SD)"
        MODEL=$(cat "$block/device/name" 2>/dev/null)
        [ -n "$MODEL" ] && echo "    型号: $MODEL"
        echo "    容量: ${SIZE_GB}GB"
        
        # 健康信息
        if [ -f "$block/device/life_time" ]; then
            LIFE=$(cat "$block/device/life_time" 2>/dev/null)
            echo "    寿命: $LIFE"
        fi
        STORAGE_COUNT=$((STORAGE_COUNT + 1))
        
    elif echo "$BLOCK_NAME" | grep -q '^nvme'; then
        # NVMe SSD
        echo "  - $DEV_PATH (NVMe SSD)"
        MODEL=$(cat "$block/device/model" 2>/dev/null | tr -s ' ')
        [ -n "$MODEL" ] && echo "    型号: $MODEL"
        echo "    容量: ${SIZE_GB}GB"
        
        # 读取序列号
        if [ -f "$block/device/serial" ]; then
            SERIAL=$(cat "$block/device/serial" 2>/dev/null)
            [ -n "$SERIAL" ] && echo "    序列号: $SERIAL"
        fi
        STORAGE_COUNT=$((STORAGE_COUNT + 1))
        
    elif echo "$BLOCK_NAME" | grep -q '^sd'; then
        # SATA/SCSI/USB 设备
        ROTA=$(cat "$block/queue/rotational" 2>/dev/null)
        if [ "$ROTA" = "0" ]; then
            TYPE="SSD"
        else
            TYPE="HDD"
        fi
        
        echo "  - $DEV_PATH (SATA/SCSI $TYPE)"
        MODEL=$(cat "$block/device/model" 2>/dev/null | tr -s ' ')
        [ -n "$MODEL" ] && echo "    型号: $MODEL"
        echo "    容量: ${SIZE_GB}GB"
        
        # 读取vendor
        if [ -f "$block/device/vendor" ]; then
            VENDOR=$(cat "$block/device/vendor" 2>/dev/null | tr -s ' ')
            [ -n "$VENDOR" ] && echo "    厂商: $VENDOR"
        fi
        STORAGE_COUNT=$((STORAGE_COUNT + 1))
        
    elif echo "$BLOCK_NAME" | grep -q '^hd'; then
        # IDE 设备
        echo "  - $DEV_PATH (IDE)"
        MODEL=$(cat "$block/device/model" 2>/dev/null | tr -s ' ')
        [ -n "$MODEL" ] && echo "    型号: $MODEL"
        echo "    容量: ${SIZE_GB}GB"
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
TEMP_MIN=-45
TEMP_MAX=102

if [ -d /sys/class/thermal ]; then
    for zone in /sys/class/thermal/thermal_zone*; do
        if [ -f "$zone/temp" ]; then
            TEMP=$(cat "$zone/temp" 2>/dev/null)
            if [ -n "$TEMP" ] && [[ "$TEMP" =~ ^-?[0-9]+$ ]]; then
                TEMP_C=$((TEMP / 1000))
                ZONE_TYPE=$(cat "$zone/type" 2>/dev/null)
                
                # 检查温度范围（-45 到 102 度）
                if [ "$TEMP_C" -ge "$TEMP_MIN" ] && [ "$TEMP_C" -le "$TEMP_MAX" ]; then
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
        HWMON_NAME=$(cat "$hwmon/name" 2>/dev/null)
        for temp_input in "$hwmon"/temp*_input; do
            if [ -f "$temp_input" ]; then
                TEMP=$(cat "$temp_input" 2>/dev/null)
                if [ -n "$TEMP" ] && [[ "$TEMP" =~ ^-?[0-9]+$ ]]; then
                    TEMP_C=$((TEMP / 1000))
                    LABEL_FILE="${temp_input/_input/_label}"
                    if [ -f "$LABEL_FILE" ]; then
                        LABEL=$(cat "$LABEL_FILE" 2>/dev/null)
                    else
                        LABEL=$(basename "$temp_input")
                    fi
                    
                    # 检查温度范围（-45 到 102 度）
                    if [ "$TEMP_C" -ge "$TEMP_MIN" ] && [ "$TEMP_C" -le "$TEMP_MAX" ]; then
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

if [ $TEMP_COUNT -gt 0 ]; then
    if [ $TEMP_ABNORMAL -gt 0 ]; then
        record_result "FAIL" "检测到 $TEMP_COUNT 个温度传感器，$TEMP_ABNORMAL 个温度异常！"
    else
        record_result "PASS" "检测到 $TEMP_COUNT 个温度传感器，全部正常（${TEMP_MIN}~${TEMP_MAX}°C范围内）"
    fi
else
    record_result "FAIL" "未找到温度传感器"
fi

# 10. PCI 设备检测（使用 /sys/bus/pci/devices）
print_title "PCI 设备检测"
PCI_COUNT=0

if [ -d /sys/bus/pci/devices ]; then
    for pci in /sys/bus/pci/devices/*; do
        PCI_ADDR=$(basename "$pci")
        
        # 读取设备信息
        if [ -f "$pci/vendor" ] && [ -f "$pci/device" ]; then
            VENDOR=$(cat "$pci/vendor" 2>/dev/null)
            DEVICE=$(cat "$pci/device" 2>/dev/null)
            
            # 读取设备类型
            if [ -f "$pci/class" ]; then
                CLASS=$(cat "$pci/class" 2>/dev/null)
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
CAN_DETECTED=""

# 检查 CAN 网络接口
for iface in /sys/class/net/*; do
    IFACE_NAME=$(basename "$iface")
    
    # 检查是否为 CAN 设备
    if [ -f "$iface/type" ]; then
        TYPE=$(cat "$iface/type" 2>/dev/null)
        # CAN 设备的类型通常是 280 (ARPHRD_CAN) 或命名为 can*
        if [ "$TYPE" = "280" ] || [[ "$IFACE_NAME" == can* ]]; then
            # 避免重复计数
            if [[ "$CAN_DETECTED" != *"$IFACE_NAME"* ]]; then
                echo "  - $IFACE_NAME (CAN接口)"
                
                # 读取状态
                if [ -f "$iface/operstate" ]; then
                    STATE=$(cat "$iface/operstate" 2>/dev/null)
                    echo "    状态: $STATE"
                fi
                
                # 读取 CAN 比特率（如果可用）
                if [ -f "$iface/can_bittiming" ]; then
                    BITRATE=$(cat "$iface/can_bittiming" 2>/dev/null | grep 'bitrate' | awk '{print $2}')
                    [ -n "$BITRATE" ] && echo "    比特率: $BITRATE bps"
                fi
                
                # 检查 CAN 统计信息
                if [ -d "$iface/statistics" ]; then
                    RX=$(cat "$iface/statistics/rx_packets" 2>/dev/null)
                    TX=$(cat "$iface/statistics/tx_packets" 2>/dev/null)
                    [ -n "$RX" ] && [ -n "$TX" ] && echo "    数据包: RX=$RX, TX=$TX"
                fi
                
                CAN_COUNT=$((CAN_COUNT + 1))
                CAN_DETECTED="$CAN_DETECTED $IFACE_NAME"
            fi
        fi
    fi
done

if [ $CAN_COUNT -gt 0 ]; then
    record_result "PASS" "检测到 $CAN_COUNT 个CAN设备"
else
    record_result "FAIL" "未检测到CAN设备"
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
echo "完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

exit 0
