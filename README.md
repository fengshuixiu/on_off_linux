# Linux 开关机计数和硬件检测系统

一个完整的 Linux 系统开关机计数和硬件自动检测解决方案，每次开机时自动记录计数并检测系统硬件状态。

## ✨ 核心特性

- ✅ **零外部依赖** - 完全使用系统内部文件（/sys、/proc）进行检测
- ✅ **兼容性强** - 支持 Ubuntu、CentOS、Debian、RHEL、Fedora 等主流发行版
- ✅ **交互式管理** - 提供图形化菜单界面，操作简单直观
- ✅ **自动化运行** - 通过 systemd 服务实现开机自动执行
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
- 自动记录每次开机次数
- **启动时间检测** - 记录从上电到进入系统的耗时 ⭐ 新增
- **基准对比** - 首次启动作为基准，后续启动偏差超过±6秒则告警
- 保存开机时间和系统信息
- 生成详细的开机日志
- 自动清理30天以前的旧日志

### 🔧 硬件检测
全面检测以下硬件设备：

1. **串口设备** - ttyS*, ttyUSB*, ttyACM*
2. **网络接口** - 以太网卡状态、MAC地址、IP地址、速率
3. **USB 设备** - 所有连接的USB设备列表
4. **WiFi 设备** - 无线网卡检测（仅检测设备存在）
5. **4G/LTE 模块** - 移动网络模块检测（仅检测设备存在）
6. **显示设备** - 显卡、显示器连接状态
7. **音频设备** - 声卡和音频接口
8. **存储设备**：
   - eMMC 存储
   - NVMe SSD
   - SATA HDD/SSD
9. **系统温度** - CPU和其他传感器温度（仅范围检查 -45~102°C，不参与硬件对比）
10. **PCI 设备** - 所有PCI/PCIe设备

### ✨ 硬件基准对比 ⭐ 新增

- **自动创建基准** - 首次安装时自动生成硬件基准
- **开机自动对比** - 每次开机自动对比硬件变化
- **检测新增设备** - 自动检测并显示新增的硬件
- **检测丢失设备** - 自动检测并警告丢失的硬件
- **日志记录** - 所有变化都记录在日志中

### 📺 状态显示 ⭐ 新增

- **桌面系统** - 登录后自动打开终端显示启动状态
- **无桌面系统** - 登录后直接在控制台打印状态
- **显示内容** - 启动次数、错误次数、最近2条错误记录

### 📄 日志策略 ⭐ 新增

**正常启动：**
- 仅记录摘要到 `normal_summary.log`（时间、开机次数、启动耗时）
- 不保存详细日志，节省磁盘空间

**异常启动（以下情况之一）：**
- 启动时间偏差超过±6秒
- 硬件新增或丢失
- 硬件检测失败

**异常时保存：**
- 详细开机日志 `boot_*.log`
- 错误日志 `error.log`
- dmesg 系统日志快照

## 📁 文件结构

```
on_off/
├── boot_counter.sh           # 主脚本：开机计数、启动时间检测、基准对比
├── hardware_check.sh         # 硬件检测脚本（纯系统内部文件）
├── boot_manager.sh           # 交互式管理工具
├── boot_display.sh           # 桌面环境状态显示脚本 ⭐ 新增
├── boot_status_show.sh       # 无桌面系统状态显示脚本 ⭐ 新增
├── boot-monitor.service      # systemd 服务配置
├── boot-monitor-display.desktop  # 桌面自启动配置 ⭐ 新增
├── install.sh                # 自动安装脚本
├── uninstall.sh              # 自动卸载脚本
└── README.md                 # 说明文档
```

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
sudo cp boot_counter.sh /opt/boot_monitor/
sudo cp hardware_check.sh /opt/boot_monitor/
sudo chmod +x /opt/boot_monitor/*.sh

# 3. 安装 systemd 服务
sudo cp boot-monitor.service /etc/systemd/system/

# 4. 启用服务
sudo systemctl daemon-reload
sudo systemctl enable boot-monitor.service

# 5. 初始化计数器
echo "0" | sudo tee /opt/boot_monitor/boot_count.txt
```

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
sudo /opt/boot_monitor/boot_counter.sh
```

### 查看服务状态
```bash
sudo systemctl status boot-monitor.service
```

### 查看日志文件
```bash
# 查看最新的开机日志
ls -lt /opt/boot_monitor/logs/boot_*.log | head -1 | awk '{print $9}' | xargs cat

# 查看硬件检测日志
cat /opt/boot_monitor/logs/hardware_check.log
```

### 查看系统日志
```bash
sudo journalctl -u boot-monitor.service
sudo journalctl -u boot-monitor.service -b  # 仅显示本次开机的日志
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
# - 每次启动后等待 10 秒再自动重启
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
- `boot_time_baseline.txt` - 启动时间基准 ⭐ 新增

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
# 1. 停止并禁用服务
sudo systemctl stop boot-monitor.service
sudo systemctl disable boot-monitor.service

# 2. 删除服务文件
sudo rm /etc/systemd/system/boot-monitor.service
sudo systemctl daemon-reload

# 3. 删除安装目录（可选，会删除所有日志）
sudo rm -rf /opt/boot_monitor
```

## 🔧 系统要求

### 必需组件
- `bash` - Shell 解释器
- `systemd` - 服务管理（开机自动运行）
- Linux 内核 2.6+ （支持 /sys 和 /proc 文件系统）

### 支持的系统
- ✅ Ubuntu 16.04+
- ✅ Debian 8+
- ✅ CentOS 7+
- ✅ RHEL 7+
- ✅ Fedora 20+
- ✅ 其他使用 systemd 的 Linux 发行版

### 零外部依赖
本系统完全使用系统内部文件进行硬件检测，无需安装任何额外工具包。

所有硬件信息均从以下系统路径获取：
- `/sys/class/*` - 设备类信息
- `/sys/block/*` - 块设备信息
- `/sys/bus/*` - 总线设备信息
- `/proc/asound/*` - 音频设备信息
- `/proc/net/*` - 网络设备信息
- `/dev/*` - 设备文件

## 🐛 故障排查

### 服务未启动
```bash
# 检查服务状态
sudo systemctl status boot-monitor.service

# 查看详细错误
sudo journalctl -xeu boot-monitor.service
```

### 权限问题
确保脚本具有执行权限：
```bash
sudo chmod +x /opt/boot_monitor/boot_counter.sh
sudo chmod +x /opt/boot_monitor/hardware_check.sh
```

### 计数器未增加
检查服务是否正确启用：
```bash
sudo systemctl is-enabled boot-monitor.service
# 应该显示: enabled
```

## ⚙️ 自定义配置

### 修改安装路径
编辑 `boot_counter.sh` 中的路径变量：
```bash
SCRIPT_DIR="/opt/boot_monitor"        # 修改为你的路径
LOG_DIR="${SCRIPT_DIR}/logs"
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
5. **系统兼容** - 需要 Linux 内核 2.6+ 和 systemd 支持

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
