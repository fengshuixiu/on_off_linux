# Linux 开关机计数和硬件检测系统

一个完整的 Linux 系统开关机计数和硬件自动检测解决方案，每次开机时自动记录计数并检测系统硬件状态。

## ✨ 核心特性

- ✅ **无需专用硬件工具** - 主要使用系统内部文件（/sys、/proc）进行检测；基础命令依赖见系统要求
- ✅ **兼容性强** - 支持 Ubuntu、Debian、CentOS、麒麟、统信 UOS 等 systemd 发行版，以及 Buildroot + BusyBox init
- ✅ **交互式管理** - 提供图形化菜单界面，操作简单直观
- ✅ **自动化运行** - 自动识别 systemd / BusyBox / SysV init 并安装对应启动项
- ✅ **启动时间监控** - 自动检测启动耗时并对比基准
- ✅ **智能日志策略** - 正常时仅记录摘要，异常时保留详细日志
- ✅ **桌面/无桌面支持** - 自动适配系统类型显示状态

## 功能特性

### 🎯 管理功能

通过交互式菜单（`boot-manager`）提供：

1. **查看开机次数** - 显示当前计数和最近开机记录
2. **设置开机次数** - 自定义设置任意数值
3. **重置开机次数** - 一键清零计数器
4. **立即执行硬件检测** - 手动触发硬件检测
5. **查看日志** - 查看最新日志和历史记录
6. **清理日志** - 按时间范围清理旧日志（7/30/90天或自定义）
7. **服务管理** - 启用/禁用服务、查看状态
8. **系统信息** - 显示系统详细信息
9. **查看系统日志(dmesg)** - 查看 dmesg 错误日志
10. **查看错误日志** - 查看 error.log 错误记录
11. **配置自动登录** - 配置控制台自动登录（无桌面系统）
12. **指定次数重启** - 设置重启次数进行循环重启测试 ⭐ 新增
13. **卸载系统** - 完全删除所有文件和配置

### 📊 开机计数与启动时间监控
- **开机即计数** - `boot_count.sh` 在启动早期单独运行（`boot-monitor.service`），毫秒级落盘，开机瞬间断电也能记上；同一 `boot_id` 重复运行不重复计数，并用 `flock` 防止并发修改
- **晚段报告** - 硬件检测、耗时判定和循环重启倒计时由 `boot-monitor-report.timer` 在开机 30 秒后触发（从内核启动计时），不占用启动关键路径
- **启动时间检测** - 取 `systemd-analyze` 的 `firmware + loader + kernel + userspace` 全链耗时（UEFI 机器上通常几十秒）；事务未结束时最多再等 `BOOT_WAIT_MAX_SEC`（默认 90 秒，超则退回 uptime 估算），两种口径互不比较，来源变化会自动重建基准
- **基准对比** - 首次有效启动作为基准，之后偏差超过 **±5 秒**告警（变慢和变快都算）
- **摘要带来源标注** - `normal_summary.log` 每行形如 `boot=7 status=OK time=48s src=systemd-analyze`，`time` 的含义由 `src` 决定
- 保存开机时间和系统信息
- 生成详细的开机日志
- 自动清理30天以前的旧日志

### 🔧 硬件检测
全面检测以下硬件设备：

1. **串口设备** - ttyS*, ttyUSB*, ttyACM*；ttyS 需有后端设备且类型非 0，避免 x86 占位节点误报
2. **网络接口** - 物理网卡状态、MAC地址、IP地址、速率；docker/veth/br-/tun 等虚拟接口只展示，不写入基准；CAN 接口交给 CAN 段统计
3. **USB 设备** - 所有连接的USB设备列表
4. **WiFi 设备** - 无线网卡检测（仅检测设备存在）；**无线接口整行不参与硬件比对**，因为 MAC 会被随机化，接口名 `wlx<MAC>` 也随之变化，写进基准会每次开机误报新增+丢失。无线模块是否存在由 USB/PCI 段的设备标识判断
5. **4G/LTE 模块** - WWAN 接口、USB 模组（含 Quectel、Fibocom、移远、美格等厂商字符串）、cdc-wdm
6. **显示设备** - DRM 适配器与连接器状态；已连接的 cardN-* 接口写入基准，拔屏可被发现
7. **音频设备** - 声卡和音频接口
8. **存储设备**：
   - eMMC 存储
   - NVMe SSD
   - SATA HDD/SSD
   - virtio / Xen 虚拟磁盘（vda、xvda）
   - 容量按 GB/MB/KB 输出，小于 1GB 不再显示为 0GB
9. **系统温度** - CPU和其他传感器温度（仅范围检查 -45~102°C，不参与硬件对比）
10. **PCI 设备** - 所有PCI/PCIe设备
11. **CAN 设备** - type=280 的 CAN 接口（含 vcan）

### ✨ 硬件基准对比 ⭐ 新增

- **自动创建基准** - 首次成功检测后生成硬件基准；重复安装保留旧基准，失败或超时不覆盖基准
- **开机自动对比** - 每次开机自动对比硬件变化
- **检测新增设备** - 自动检测并显示新增的硬件
- **检测丢失设备** - 自动检测并警告丢失的硬件
- **可选硬件缺失不算失败** - 串口、WiFi、4G、音频、显示、CAN 未配置时标记为“跳过”；是否异常以首次开机基准为准，丢失时才告警
- **日志记录** - 所有变化都记录在日志中

设备标识行格式版本为 `v4`。格式变更后旧基准会自动重建一次，避免把所有设备同时报成新增和丢失。

### 📺 状态显示 ⭐ 新增

- **桌面系统** - 登录后自动打开终端显示启动状态
- **无桌面系统** - 登录后直接在控制台打印状态
- **显示内容** - 启动次数、错误次数、最近2条错误记录

### 📄 日志策略 ⭐ 新增

**正常启动：**
- 仅记录摘要到 `normal_summary.log`（时间、开机次数、启动耗时）
- 不保存详细日志，节省磁盘空间

**异常启动（以下情况之一）：**
- 启动耗时与首次基准偏差超过 ±5 秒（`BOOT_SLOW` 变慢 / `BOOT_FAST` 变快）
- 硬件新增或丢失
- 硬件检测失败

**异常时保存：**
- 详细开机日志 `boot_*.log`
- 错误日志 `error.log`
- dmesg 系统日志快照

## 📁 文件结构

```
on_off/
├── boot_count.sh             # 早段：开机计数（开机后立即执行，越早越断电安全）
├── boot_counter.sh           # 晚段：硬件检测、启动耗时判定、报告与循环重启倒计时
├── hardware_check.sh         # 硬件检测脚本（主要读取系统内部文件）
├── platform.sh               # 平台探测与重启状态事务
├── tests/test_regression.py  # Linux / WSL 隔离回归测试
├── boot_manager.sh           # 交互式管理工具
├── boot_display.sh           # 桌面环境状态显示脚本 ⭐ 新增
├── boot_status_show.sh       # 无桌面系统状态显示脚本 ⭐ 新增
├── boot-monitor.service      # systemd 早段单元（只跑 boot_count.sh）
├── boot-monitor-report.service   # systemd 晚段单元（boot_counter.sh report）
├── boot-monitor-report.timer     # 开机 30 秒后触发晚段单元
├── boot-monitor.initd        # BusyBox / SysV init 启动脚本（串行跑两段）
├── boot-monitor-display.desktop  # 桌面自启动配置 ⭐ 新增
├── install.sh                # 自动安装脚本
├── uninstall.sh              # 自动卸载脚本
└── README.md                 # 说明文档
```

### 为什么拆成早/晚两段

`systemd-analyze` 只有在启动事务结束之后才有值。如果计数和检测放在同一个被
`multi-user.target` 拉起的服务里，这个服务自身就是事务的一员——事务要等它退出才算
结束，它又在等事务结束，只能拿到 uptime 口径。因此：

| 阶段 | 单元 | 时机 | 职责 |
|------|------|------|------|
| 早段 | `boot-monitor.service` → `boot_count.sh` | 开机数秒内 | 计数、写日志指针、显示标志 |
| 晚段 | `boot-monitor-report.timer` → `boot-monitor-report.service` → `boot_counter.sh report` | 开机 30 秒后 | 硬件检测与比对、全链耗时、循环重启倒计时 |

`boot-monitor-report.service` 故意没有 `[Install]` 段：任何 target 拉起它都会让全链
耗时口径失效。userspace 启动超过 30 秒的机器请把 `boot-monitor-report.timer` 里的 `OnBootSec`
改大（脚本内部还会再等 `BOOT_WAIT_MAX_SEC` 秒）。非 systemd 平台仍由
`boot-monitor.initd` 串行执行 `boot_counter.sh`（参数 `all`）。

## 🚀 快速开始

### 安装步骤

### 方法一：自动安装（推荐）

```bash
# 1. 下载或复制所有文件到一个目录
cd /path/to/on_off

# 2. 给安装脚本添加执行权限
chmod +x install.sh

# 3. 运行安装脚本（需要 root 权限）
sudo bash install.sh
```

### 使用管理工具

安装完成后，使用管理工具进行所有操作：

```bash
# 打开管理界面（推荐）
sudo boot-manager
```

管理界面提供以下功能：
- 📊 查看和设置开机次数
- 🔧 立即执行硬件检测
- 📝 查看和管理日志
- 🗑️ 清理旧日志文件
- ⚙️ 服务管理
- ℹ️ 系统信息查看

### 方法二：手动安装

```bash
# 1. 创建安装目录
sudo mkdir -p /opt/boot_monitor/logs

# 2. 复制脚本文件
sudo cp boot_count.sh boot_counter.sh /opt/boot_monitor/
sudo cp hardware_check.sh platform.sh boot_manager.sh /opt/boot_monitor/
sudo chmod +x /opt/boot_monitor/*.sh

# 3. 安装 systemd 单元（早段计数 + 晚段报告 + 触发报告的定时器）
sudo cp boot-monitor.service boot-monitor-report.service boot-monitor-report.timer /etc/systemd/system/

# 4. 启用：报告单元没有 [Install] 段，只能启用定时器
sudo systemctl daemon-reload
sudo systemctl enable boot-monitor.service boot-monitor-report.timer

# 5. 初始化计数器
echo "0" | sudo tee /opt/boot_monitor/boot_count.txt
```

Buildroot / BusyBox 手动安装：

```bash
sudo cp boot-monitor.initd /etc/init.d/S99boot-monitor
sudo chmod +x /etc/init.d/S99boot-monitor
echo "0" | sudo tee /opt/boot_monitor/boot_count.txt
```

安装器会自动识别 init 系统；也可用 `BOOT_MONITOR_INIT=systemd|busybox|sysv sudo -E bash install.sh` 强制指定。

## 📖 详细使用说明

### 管理工具命令

```bash
# 打开交互式管理界面（推荐使用）
sudo boot-manager
```

管理界面截图：
```
╔════════════════════════════════════════════════════════════╗
║      Linux 开关机计数与硬件检测管理系统                  ║
╚════════════════════════════════════════════════════════════╝

【当前状态】
  开机次数: 42
  服务状态: 已启用
  日志数量: 15 个
  安装路径: /opt/boot_monitor

【主菜单】
  1) 查看开机次数
  2) 设置开机次数
  3) 重置开机次数
  4) 立即执行硬件检测
  5) 查看最新日志
  6) 查看历史日志列表
  7) 清理日志文件
  8) 服务管理
  9) 系统信息
  d) 查看系统日志(dmesg)
  e) 查看错误日志
  a) 配置自动登录
  r) 指定次数重启系统
  u) 卸载系统
  0) 退出

请选择操作 [0-9/d/e/a/r/u]:
```

### 命令行快捷操作

### 查看开机次数
```bash
cat /opt/boot_monitor/boot_count.txt
```

### 手动运行检测
```bash
sudo boot-manager  # 选择 4，仅执行硬件检测，不增加开机计数

# 或直接重跑晚段报告（硬件检测 + 耗时判定 + 比对），同样不增加计数
sudo /opt/boot_monitor/boot_counter.sh report
```

计数由 `boot_count.sh` 在开机早段完成，同一开机周期（同一 `boot_id`）重复运行不会二次计数；晚段报告同样按 `boot_id` 去重，`BOOT_MONITOR_FORCE=1` 可强制重跑一次报告。不要反复手动运行 `boot_counter.sh all`——那是非 systemd 平台的开机入口。计数文件损坏或超出18位整数范围时停止写入，使用管理工具修复。

### 查看服务状态
```bash
sudo systemctl status boot-monitor.service boot-monitor-report.timer
systemctl list-timers boot-monitor-report.timer   # 晚段报告的触发时间
```

### 查看日志文件
```bash
# 查看最新的开机日志
ls -lt /opt/boot_monitor/logs/boot/boot_*.log | head -1 | awk '{print $9}' | xargs -r cat

# 查看硬件检测日志
cat /opt/boot_monitor/logs/boot/hardware_check.log
```

### 查看系统日志
```bash
sudo journalctl -u boot-monitor.service -u boot-monitor-report.service
sudo journalctl -b -u boot-monitor.service -u boot-monitor-report.service  # 仅本次开机
```

### 日志管理

通过管理工具（`sudo boot-manager`）可以：
- 查看历史日志列表
- 按编号查看特定日志
- 按时间范围清理日志（7/30/90天）
- 自定义清理天数
- 一键清理所有日志

### 重置开机计数
```bash
echo "0" | sudo tee /opt/boot_monitor/boot_count.txt
```

### 指定次数重启 ⭐ 新增
```bash
# 使用管理工具（推荐）
sudo boot-manager  # 选择 r 选项

# 功能说明：
# - 设置重启次数后，系统将循环重启指定次数
# - 首次确认后等待5秒；每次开机在“系统启动完成”后等待15秒再重启
#   （倒计时以启动事务结束为零点，定时器触发晚了会自动扣掉已过时间）
# - 指定次数包含首次重启，输入1只重启一次
# - 倒计时内可以取消；已向系统提交重启后不再承诺取消成功
# - 开机计数器会重置为 0，从 1 开始计数
# - 启动时间基准会重新记录
# - 用于测试系统稳定性和开关机功能
```

### 查看硬件基准 ⭐ 新增
```bash
# 查看首次安装时的硬件配置
cat /opt/boot_monitor/hardware_baseline.txt
```

## 日志文件说明

### 日志位置
- **安装目录**: `/opt/boot_monitor/`
- **日志目录**: `/opt/boot_monitor/logs/`
- **计数文件**: `/opt/boot_monitor/boot_count.txt`

### 日志文件类型
- `boot_YYYYMMDD_HHMMSS.log` - 异常时保留的完整开机日志
- `normal_summary.log` - 正常启动摘要记录 ⭐ 新增
- `error.log` - 错误和警告日志 ⭐ 新增
- `dmesg.log` - dmesg 系统日志合集 ⭐ 新增
- `dmesg_boot*_*.log` - 异常时的 dmesg 快照 ⭐ 新增
- `hardware_check.log` - 硬件检测的累积日志
- `hardware_baseline.txt` - 硬件基准文件（首次安装时生成）
- `hardware_current.txt` - 当前硬件检测结果（临时文件）
- `boot_time_baseline.txt` - 启动时间基准（含口径来源，如 `49 systemd-analyze`）⭐ 新增

早/晚两段之间与防重复用的状态文件（在 `/opt/boot_monitor/` 下，勿手工删除）：

- `.boot_log` - 早段建立的本次开机日志名，晚段沿用同一份日志
- `.last_counted_boot_id` - 已计数的开机身份，防同一开机二次计数
- `.last_reported_boot_id` - 已出报告的开机身份，防重复摘要
- `.display_pending` - 登录后显示状态用的标志
- `.boot_counter.lock` / `.boot_report.lock` / `.reboot_request.lock` / `.reboot_state.lock` - `flock` 并发保护

### 日志轮转配置 ⭐ 新增

| 日志文件 | 单文件上限 | 保留份数 | 总容量限制 |
|----------|------------|----------|------------|
| error.log | 10MB | 5 份 | 50MB |
| dmesg.log | 30MB | 20 份 | 600MB |

### 日志内容示例
```
============================================
开机计数: 42
开机时间: 2025-12-02 08:30:15
系统信息: Linux hostname 5.15.0-generic #101-Ubuntu SMP x86_64 GNU/Linux
运行时长: up 2 minutes
============================================

开始硬件检测...

[串口设备检测]
------------------------------------------------------------
✓ 检测到串口设备:
  - /dev/ttyS0 (crw-rw---- root dialout)
  - /dev/ttyUSB0 (crw-rw---- root dialout)

[网络接口检测]
------------------------------------------------------------
✓ 检测到网络接口:
  - eth0: 状态=UP, MAC=00:11:22:33:44:55, IP=192.168.1.100
    速度: 1000Mbps
  - wlan0: 状态=UP, MAC=aa:bb:cc:dd:ee:ff, IP=192.168.1.101

...
```

## 卸载方法

### 方法1：使用管理工具（推荐）
```bash
sudo boot-manager
# 选择 u 选项
# 输入 YES 确认
```

### 方法2：使用卸载脚本
```bash
sudo bash uninstall.sh
```

### 方法3：手动卸载

```bash
# 1. 停止并禁用服务与定时器
sudo systemctl stop boot-monitor.service boot-monitor-report.service boot-monitor-report.timer
sudo systemctl disable boot-monitor.service boot-monitor-report.timer

# 2. 删除单元文件
sudo rm /etc/systemd/system/boot-monitor.service /etc/systemd/system/boot-monitor-report.service /etc/systemd/system/boot-monitor-report.timer
sudo systemctl daemon-reload

# 3. 删除安装目录（可选，会删除所有日志）
sudo rm -rf /opt/boot_monitor
```

## 🔧 系统要求

### 必需组件
- `bash` 4.x 及以上 - 所有脚本显式使用 bash
- init 系统：`systemd`，或 Buildroot 的 BusyBox `rcS` / 传统 SysV
- 基础命令：`mktemp`、`mkdir`、`cp`、`chmod`、`grep`、`awk`、`sed`、`sort`、`comm` 等
- Linux 的 `/sys`、`/proc`；`/proc/sys/kernel/random/boot_id` 缺失时仅失去同次开机去重
- 可选命令（缺失时自动降级）：
  - `flock` - 缺失时不加锁，计数依赖 boot_id 去重；循环重启测试不可用
  - `timeout` 及 `-k` - 缺失或不支持时使用内置看门狗
  - `mv -T` - 不使用；原子替换改为 `mv -f` 并显式拒绝目录目标
  - `systemd-analyze` - 提供全链启动耗时（firmware+loader+kernel+userspace）；缺失时退回 uptime 估算
  - `journalctl`、`ip` - 仅增强日志与展示
- Python 3 仅用于本地回归测试，不是运行依赖

### 支持的系统
| 目标 | 状态 | 说明 |
|---|---|---|
| Ubuntu 16.04+ / Debian 8+ | ✅ 设计支持 | systemd；本轮在 WSL Ubuntu 实测脚本逻辑 |
| CentOS 7+ / RHEL 7+ / Fedora | ✅ 设计支持 | Bash 4.2+；使用 systemd 路径 |
| 麒麟 V10 / 统信 UOS | ✅ 设计支持 | 桌面版为 systemd；ARM/x86 需分别核实硬件识别结果 |
| Buildroot + BusyBox init | ✅ 支持 | 需带 bash、`mktemp`；`flock/timeout` 可选；用 init.d 启动 |
| Buildroot + systemd | ✅ 支持 | 使用 systemd 单元 |
| Alpine / OpenRC、其他非上面列出的 init | ⚠ 未验证 | 需补充对应启动脚本 |
| Windows / macOS 原生 | ❌ 不支持 | 仅 Linux |

### 依赖边界
硬件检测不依赖 `lspci`、`lsusb`、`udevadm` 等专用探测工具，也不依赖 `/var/log`（Buildroot 上通常是 tmpfs）。

Buildroot 差异由 `platform.sh` 屏蔽：原子替换不再要求 `mv -T`，超时支持三级降级，服务状态/启停/日志按 init 系统分派。**仍需注意**：Buildroot 必须包含 `bash`（脚本使用 bash 数组、`[[ ]]`、进程替换和 `local`），只带 `ash` 的极简镜像无法运行。

检测报告退出码：`0` 表示扫描完成；`2` 表示扫描完成但传感器异常。可选硬件未安装不直接造成非零退出。退出码2的完整报告仍参与设备差异比对，但不能用于创建或更新基准。

所有硬件信息均从以下系统路径获取：
- `/sys/class/*` - 设备类信息
- `/sys/block/*` - 块设备信息
- `/sys/bus/*` - 总线设备信息
- `/proc/asound/*` - 音频设备信息
- `/proc/net/*` - 网络设备信息
- `/dev/*` - 设备文件

## 摘要里 time 是什么

```
[2026-11-05 19:07:06] boot=7 status=OK time=48s src=systemd-analyze
```

- `src=systemd-analyze`：全链启动耗时，= firmware + loader + kernel + userspace，
  也就是"UEFI 起点 → 系统启动完成"。按下电源到 UEFI 开始执行这一段任何用户态都取不到。
- `src=uptime`：无 systemd，或等待启动事务结束超时后的估算值，只表示"内核开始 → 本服务运行"，
  数值会明显偏小，不会与 systemd 口径互相比较。
- 等待上限可调：`BOOT_WAIT_MAX_SEC`（默认 60）；判定容差可调：`BOOT_TIME_TOLERANCE_SEC`（默认 5）。

## 本地测试验证

在 Linux 或 WSL 的项目目录执行，无需 root：

```bash
python3 tests/test_regression.py
for script in *.sh; do bash -n "$script" || exit 1; done
```

测试使用临时目录、模拟内核设备数据和系统命令替身，不触发真实重启、服务安装或卸载。覆盖计数防重复/并发、异常基准保护、相同型号设备数量变化、温度边界、重启次数/取消/提交竞争、菜单 EOF、systemd 单元校验，以及 BusyBox 能力降级（无 flock、`timeout` 无 `-k`、无 `mv -T`、无 systemd 时安装 init.d）。当前共 60 项。

这些测试不能替代目标机的开机自启、突然断电持久化、桌面显示及真实硬件插拔测试。

## 🐛 故障排查

### 服务未启动
```bash
# systemd
sudo systemctl status boot-monitor.service boot-monitor-report.timer
sudo journalctl -xeu boot-monitor.service -u boot-monitor-report.service

# Buildroot / BusyBox
sudo /etc/init.d/S99boot-monitor status
sudo cat /opt/boot_monitor/logs/boot/normal_summary.log
```

### 权限问题
确保脚本具有执行权限：
```bash
sudo chmod +x /opt/boot_monitor/boot_count.sh
sudo chmod +x /opt/boot_monitor/boot_counter.sh
sudo chmod +x /opt/boot_monitor/hardware_check.sh
```

### 计数器未增加
检查启动项是否正确启用：
```bash
# systemd
sudo systemctl is-enabled boot-monitor.service

# Buildroot / BusyBox：脚本需要可执行位
ls -l /etc/init.d/S99boot-monitor
```

### 报告没有跑（耗时无数据）
```bash
# systemd：晚段由定时器触发，确认定时器已启用并在跑
systemctl is-enabled boot-monitor-report.timer
systemctl list-timers boot-monitor-report.timer
sudo journalctl -b -u boot-monitor-report.service -n 30
```
机器 userspace 启动慢于 `OnBootSec`（默认 30 秒）时，把 `boot-monitor-report.timer` 的 `OnBootSec` 改大后
`sudo systemctl daemon-reload && systemctl restart boot-monitor-report.timer`。

## ⚙️ 自定义配置

### 修改安装路径
`boot_count.sh`（早段）和 `boot_counter.sh`（晚段）里的路径变量都要改，只改一份会导致两段读写不同目录：
```bash
SCRIPT_DIR="/opt/boot_monitor"        # 修改为你的路径
LOG_DIR="${SCRIPT_DIR}/logs"
```
单元文件里的 `ExecStart=`、`WorkingDirectory=` 也要同步到同一路径。

### 调整启动耗时阈值与等待
```bash
# boot-monitor-report.service 内可改
Environment=BOOT_WAIT_MAX_SEC=90       # 等启动事务结束的上限
Environment=BOOT_TIME_TOLERANCE_SEC=5  # 与基准的允许偏差
Environment=REBOOT_DELAY_SEC=15        # 循环重启：系统起来后等待的秒数（可选，默认 15）
```

### 修改日志保留时间
编辑 `boot_counter.sh` 中的清理命令，或使用管理工具的清理功能：
```bash
# 自动清理（在脚本中）
find "${LOG_DIR}" -name "boot_*.log" -mtime +30 -delete

# 使用管理工具（推荐）
sudo boot-manager  # 选择菜单项 7) 清理日志文件
```

### 添加自定义检测项
在 `hardware_check.sh` 中添加新的检测函数。

## 💡 使用技巧

### 1. 快速管理
使用 `boot-manager` 命令快速访问所有管理功能：
```bash
sudo boot-manager
```

### 2. 指定次数重启 ⭐ 新增
可用于测试或达到特定开机次数：
```bash
sudo boot-manager  # 选择 r 选项
# 输入目标次数，例如 100
# 系统将重启，重启后计数器显示 100
```

### 3. 定期清理日志
建议定期清理旧日志以节省磁盘空间：
- 通过管理工具菜单选择清理选项
- 或设置自动清理天数（默认30天）

### 3. 查看硬件变化 ⭐ 新增
对比不同时间的日志，可以发现硬件变化：
```bash
# 查看历史日志
sudo boot-manager  # 选择菜单项 6

# 查看硬件基准
cat /opt/boot_monitor/hardware_baseline.txt

# 每次开机日志中都会自动显示硬件变化
```

### 4. 导出报告
将硬件检测结果导出到文件：
```bash
sudo /opt/boot_monitor/hardware_check.sh > hardware_report.txt
```

### 5. 设置特定计数
可用于测试或设置初始值：
```bash
# 方法1：使用管理工具
sudo boot-manager  # 选择菜单项 2

# 方法2：直接编辑
echo "100" | sudo tee /opt/boot_monitor/boot_count.txt
```

## ⚠️ 注意事项

1. **权限要求** - 管理工具需要 root 权限运行（使用 `sudo`）
2. **首次启动** - 安装后需要重启系统才会开始自动计数
3. **日志清理** - 默认自动清理30天前的日志，可通过管理工具自定义
4. **虚拟机环境** - 某些虚拟化环境可能无法检测到所有硬件
5. **系统兼容** - 需要 Linux 和 bash；systemd、BusyBox init、SysV 均已适配，其余 init 需自行挂载启动脚本

## 🔍 技术支持

如有问题，请按以下步骤排查：

1. **使用管理工具诊断**
   ```bash
   sudo boot-manager  # 查看状态和日志
   ```

2. **检查服务状态**
   ```bash
   sudo systemctl status boot-monitor.service
   ```

3. **查看系统日志**
   ```bash
   sudo journalctl -u boot-monitor.service -n 50
   ```

4. **检查文件权限**
   ```bash
   ls -la /opt/boot_monitor/
   ```

## 许可证

本项目采用 MIT 许可证。

## 📝 更新日志

### v4.4.0 (2026-11-05)
- 🎯 开机流程拆成早/晚两段：`boot_count.sh` 开机即计数（`boot-monitor.service`），硬件检测与耗时判定改由 `boot-monitor-report.timer` 在开机 30 秒后触发（`boot-monitor-report.service`）
- 🐛 循环重启的 15 秒倒计时改为以“启动事务结束”为零点（定时器 60→30 秒）：此前从定时器触发时刻再等 15 秒，真机每轮 106 秒；现在重启落在系统起来后 15 秒，真机每轮 106 → 71～73 秒（3 轮实测剩余等待 9～10 秒）。`REBOOT_DELAY_SEC` 可调
- 🐛 修复 v4.3.0 的等待自锁：计数服务自身属于启动事务，等"事务结束"永远等不到，真机上每开机白等 60 秒后仍退化成 uptime 口径；改由 timer 触发后真机实测拿到 49 秒全链耗时（`systemd-analyze time` = 48.6s）
- 🔧 报告单元无 `[Install]` 段，只能由定时器拉起，避免再次被 target 拉进启动事务
- 🔧 晚段用 `.last_reported_boot_id` 去重，`BOOT_MONITOR_FORCE=1` 可强制重跑；管理菜单"立即运行一次"改跑晚段，不再增加开机计数
- 🔧 两段共用早段建立的 `.boot_log` 日志指针，异常详情集中在同一份 `boot_*.log`
- 🧪 回归测试增至 93 项（早段职责、晚段去重、timer 触发、单元校验、卸载覆盖新单元）

### v4.3.0 (2026-11-05)
- 🎯 启动耗时改为等待 systemd 启动事务结束后采样，取 firmware+loader+kernel+userspace 全链；此前服务跑得太早，`systemd-analyze` 未就绪，把 48 秒的真实启动记成了 3 秒
- 🎯 摘要与日志新增 `src=` 标注（`systemd-analyze` / `uptime`），口径一目了然
- 🔧 判定改为“以首次启动为基准，偏差超过 ±5 秒告警”，变慢记 `BOOT_SLOW`、变快记 `BOOT_FAST`（此前只报慢且阈值 7 秒）
- 🔧 等待上限 `BOOT_WAIT_MAX_SEC`（默认 60s）、容差 `BOOT_TIME_TOLERANCE_SEC`（默认 5s）可配置
- 🔧 单元 `TimeoutStartSec` 360 → 390，覆盖等待+检测+重启倒计时
- 🐛 `.last_counted_boot_id` 权限改为 644，普通用户可读取
- 🧪 回归测试增至 80 项

### v4.2.1 (2026-11-05)
- 🎯 WiFi 接口不再参与硬件比对：MAC 随机化会让 `wlx<MAC>` 名称和 MAC 每次都变，写进基准会每次开机误报新增+丢失；无线模块存在性由 USB/PCI 段判断
- 🔖 设备标识格式升级到 v4

### v4.2.0 (2026-11-04)
- 🎯 显示检测修复：按 `cardN-<conn>/status` 读取连接器状态，拔屏/黑屏可被基准比对发现
- 🎯 存储检测新增 virtio/Xen 虚拟磁盘（vda/xvda），容量按 GB/MB/KB 输出
- 🎯 串口检测过滤 8250 占位节点（无后端或 type=0），普通 PC 不再误报多个串口
- 🎯 网络检测区分物理/虚拟接口，容器和虚机启停不再污染硬件基准
- 🎯 4G 模块识别扩展到 Quectel、Fibocom、移远、美格、Simcom、Telit、Sierra 等厂商
- 🎯 移除无效的 CAN 二次统计分支，避免误计非 CAN 设备
- 🔧 可选硬件缺失改为“跳过”，不制造每日失败；异常由首次开机基准比对判定
- 🔖 设备标识格式升级到 v3，旧基准自动重建一次
- 🧪 回归测试增至 68 项

### v4.1.0 (2026-11-04)
- ✨ 支持 Buildroot / BusyBox init 与 SysV init（新增 `boot-monitor.initd`）
- ✨ 安装器自动识别 init 系统，支持 `BOOT_MONITOR_INIT` 强制指定
- 🔧 去除 `mv -T` 硬依赖，BusyBox 环境下仍可原子替换计数文件
- 🔧 `flock` 缺失时降级计数（保留 boot_id 去重）；循环重启测试明确提示不可用
- 🔧 `timeout -k` 缺失时三级降级到内置看门狗
- 🔧 服务状态/启停/日志按 init 系统分派，管理工具不再假定 systemd
- 🧪 回归测试扩展到 60 项，新增 BusyBox 能力降级与 init.d 安装路径验证

### v4.0.0 (2026-01-07)
- ✨ 新增启动时间检测功能（首次作为基准，后续对比±6秒）
- ✨ 新增桌面/无桌面系统状态自动显示
- ✨ 新增智能日志策略（正常仅记录摘要，异常保留详细日志）
- ✨ 新增 error.log 和 dmesg.log 日志轮转
- ✨ 新增错误次数统计和最近2条错误显示
- ✨ 新增控制台自动登录配置功能
- 🔧 优化 r) 重启测试：计数器重置为0，从1开始计数
- 🔧 优化温度检测：仅范围检查-45~102°C，不参与硬件对比
- 🔧 提高系统兼容性（移除 grep -oP 依赖）

### v3.0.0 (2025-12-02)
- ✨ 新增指定次数重启功能
- ✨ 新增硬件基准对比功能
- ✨ 自动检测硬件变化（新增/丢失）
- ✨ 安装后自动创建硬件基准
- ✨ 新增卸载脚本和管理界面卸载选项
- 🔧 优化WiFi和4G检测（仅检测设备存在）
- 📚 每次开机自动对比硬件配置

### v2.0.0 (2025-12-02)
- ✨ 新增交互式管理工具（boot-manager）
- ✨ 完全使用系统内部文件，零外部依赖
- ✨ 支持自定义设置开机次数
- ✨ 灵活的日志清理功能
- ✨ 增强的系统兼容性（Ubuntu/CentOS）
- 🔧 优化硬件检测逻辑
- 📚 完善的用户界面和提示信息

### v1.0.0 (2025-12-02)
- 初始版本发布
- 支持开机计数功能
- 支持全面的硬件检测
- 自动安装脚本
- systemd 服务集成

## 🤝 贡献

欢迎提交问题和改进建议！
