#!/usr/bin/env python3
"""隔离回归测试：仅修改临时目录，所有重启及系统管理命令均为替身。

运行方式：python3 tests/test_regression.py（Linux / WSL，Python 标准库）。
"""
import fcntl
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
REPORT = "设备标识格式: v5\n  - USB设备: 1234:5678\n完成时间: test\n"


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="boot-test-", dir=ROOT / "tests")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.install = self.root / "install"
        self.bin = self.root / "bin"
        self.install.mkdir()
        self.bin.mkdir()
        self.boot_id = self.root / "boot_id"
        self.boot_id.write_text("11111111-1111-1111-1111-111111111111\n")
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin", LC_ALL="C.UTF-8")
        for name in ("sync", "sleep", "systemctl", "busctl", "clear", "ip"):
            self.command(name, "exit 0\n")
        self.command("reboot", f"printf 'reboot\\n' >> {shlex.quote(str(self.root / 'reboots'))}\nexit 0\n")
        self.command("dmesg", "printf 'mock kernel log\\n'\n")
        self.command("systemd-analyze", "printf 'Startup finished in 1s (kernel) + 9s (userspace) = 10s\\n'\n")
        self.hardware()
        for name in ("boot_counter.sh", "boot_count.sh", "boot_manager.sh", "platform.sh"):
            self.prepare(name)

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body)
        path.chmod(0o755)

    def prepare(self, name):
        text = (ROOT / name).read_text()
        text = text.replace("/opt/boot_monitor", str(self.install))
        text = text.replace("/proc/sys/kernel/random/boot_id", str(self.boot_id))
        if name == "boot_manager.sh":
            # 保留全部函数，只让测试以普通用户调用指定入口。
            text = text.rsplit("\nmain", 1)[0] + '\n"$@"\n'
            text = text.replace('if [ "$EUID" -ne 0 ]; then', 'if false; then')
        target = self.install / name
        target.write_text(text)
        return target

    def force_init(self, kind):
        """把 init 探测点搬进沙箱，判定仍由真实的 plat_detect_init 完成。"""
        probes = {
            "/run/systemd/system": "systemd",
            "/etc/init.d/rcS": "busybox",
            "/etc/rc2.d": "sysv",
            "/etc/rc.d": "sysv",
        }
        path = self.install / "platform.sh"
        text = path.read_text()
        for probe, owner in probes.items():
            target = self.root / "probe" / probe.lstrip("/")
            if owner == kind:
                target.mkdir(parents=True, exist_ok=True)
            text = text.replace(probe, str(target))
        path.write_text(text)

    def hardware(self, text=REPORT, status=0):
        (self.install / "hardware_check.sh").write_text(
            "#!/bin/bash\nprintf '%s' " + shlex.quote(text) + f"\nexit {status}\n"
        )

    def run_script(self, name="boot_counter.sh", *args, input="", timeout=8, env=None):
        child_env = dict(self.env, **(env or {}))
        return subprocess.run(["bash", str(self.install / name), *args], input=input,
                              text=True, capture_output=True, env=child_env, timeout=timeout)

    def read(self, name):
        path = self.install / name
        return path.read_text() if path.exists() else ""

    def baseline(self, text=REPORT):
        (self.install / "hardware_baseline.txt").write_text(text)

    def next_boot(self):
        self.boot_id.write_text("22222222-2222-2222-2222-222222222222\n")

    def hold_lock(self, name):
        handle = (self.install / name).open("w")
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.addCleanup(handle.close)
        return handle

    def reboot_count(self):
        path = self.root / "reboots"
        return len(path.read_text().splitlines()) if path.exists() else 0


class CounterTests(Sandbox):
    def test_first_boot_counts_once(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read("boot_count.txt").strip(), "1")
        self.assertEqual(self.read("hardware_baseline.txt"), REPORT)

    def test_leading_zero_count_is_decimal(self):
        (self.install / "boot_count.txt").write_text("08\n")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read("boot_count.txt").strip(), "9")

    def test_oversized_count_fails_without_corruption(self):
        original = "999999999999999999999999999999\n"
        (self.install / "boot_count.txt").write_text(original)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read("boot_count.txt"), original)

    def test_same_boot_is_not_counted_twice(self):
        self.run_script()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read("boot_count.txt").strip(), "1")

    def test_new_boot_increments_count(self):
        self.run_script()
        self.next_boot()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read("boot_count.txt").strip(), "2")

    def test_failed_scan_does_not_create_baseline(self):
        self.hardware(REPORT, 1)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.install / "hardware_baseline.txt").exists())
        self.assertIn("HW_CHECK", self.read("logs/error/error.log"))

    def test_failed_scan_does_not_replace_legacy_baseline(self):
        self.baseline("old baseline\n")
        self.hardware(REPORT, 124)
        self.run_script()
        self.assertEqual(self.read("hardware_baseline.txt"), "old baseline\n")

    def test_failed_scan_does_not_report_missing_devices(self):
        self.baseline()
        self.hardware("interrupted\n", 1)
        self.run_script()
        self.assertNotIn("HW_LOST", self.read("logs/error/error.log"))

    def test_empty_successful_scan_is_not_a_baseline(self):
        self.hardware("")
        self.run_script()
        self.assertFalse((self.install / "hardware_baseline.txt").exists())
        self.assertIn("HW_CHECK", self.read("logs/error/error.log"))

    def test_duplicate_devices_are_compared_as_multiset(self):
        self.baseline(REPORT.replace("完成时间:", "  - USB设备: 1234:5678\n完成时间:"))
        self.run_script()
        self.assertIn("HW_LOST", self.read("logs/error/error.log"))

    def test_added_device_is_written_to_error_log(self):
        self.baseline()
        self.hardware(REPORT + "  - USB设备: aaaa:bbbb\n")
        self.run_script()
        self.assertIn("HW_NEW", self.read("logs/error/error.log"))

    def test_temperature_failure_still_compares_complete_report(self):
        self.baseline(REPORT + "  - missing device\n")
        self.hardware(REPORT, 2)
        self.run_script()
        self.assertIn("HW_CHECK", self.read("logs/error/error.log"))
        self.assertIn("HW_LOST", self.read("logs/error/error.log"))
        self.assertEqual(self.read("hardware_baseline.txt"), REPORT + "  - missing device\n")

    def test_incomplete_temperature_report_is_not_compared(self):
        self.baseline()
        self.hardware("设备标识格式: v5\n  - partial\n", 2)
        self.run_script()
        self.assertNotIn("HW_LOST", self.read("logs/error/error.log"))

    def test_unchanged_boot_uses_summary(self):
        self.baseline()
        self.run_script()
        self.assertIn("status=OK", self.read("logs/boot/normal_summary.log"))
        self.assertFalse(list((self.install / "logs/boot").glob("boot_*.log")))

    def test_cancel_during_reboot_delay_is_honored(self):
        (self.install / "reboot_remaining.txt").write_text("2\n")
        self.command("sleep", f"if [ \"$1\" = 15 ]; then : > {shlex.quote(str(self.install / 'reboot_remaining.txt'))}; fi\n")
        self.run_script()
        self.assertEqual(self.reboot_count(), 0)

    def test_reboot_failure_is_reported(self):
        (self.install / "reboot_remaining.txt").write_text("1\n")
        self.command("reboot", "exit 1\n")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("REBOOT", self.read("logs/error/error.log"))
        self.assertEqual(self.read("reboot_remaining.txt").strip(), "1")

    def test_valid_remaining_reboots_once(self):
        (self.install / "reboot_remaining.txt").write_text("02\n")
        self.run_script()
        self.assertEqual(self.reboot_count(), 1)
        self.assertEqual(self.read("reboot_remaining.txt").strip(), "1")

    def test_reboot_commit_works_with_busybox_mv(self):
        # BusyBox mv 没有 -T。提交事务若依赖它，Buildroot 上"指定次数重启"
        # 一次都不会执行：剩余次数写不下去，脚本直接停止重启。
        self.command("mv", 'for a in "$@"; do\n'
                           '  [ "$a" = "-T" ] && { echo "mv: unrecognized option: T" >&2; exit 1; }\n'
                           'done\n'
                           'exec /usr/bin/mv "$@"\n')
        (self.install / "reboot_remaining.txt").write_text("2\n")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.reboot_count(), 1)
        self.assertEqual(self.read("reboot_remaining.txt").strip(), "1")

    def test_reboot_delay_counts_from_startup_finished(self):
        # 定时器比启动完成晚触发时，倒计时要把已经过去的时间扣掉，
        # 否则“系统起来后 15 秒重启”会变成“定时器触发后 15 秒”。
        uptime = int(float(Path("/proc/uptime").read_text().split()[0]))
        finish_us = max(uptime - 10, 1) * 1_000_000
        self.command("systemctl",
                     f"if [ \"$1\" = show ]; then echo 'FinishTimestampMonotonic={finish_us}'; fi\n"
                     "exit 0\n")
        log = self.root / "sleep-args"
        self.command("sleep", f"printf '%s\\n' \"$1\" >> {shlex.quote(str(log))}\n")
        (self.install / "reboot_remaining.txt").write_text("1\n")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.reboot_count(), 1)
        values = [int(v) for v in log.read_text().split()]
        self.assertTrue(any(3 <= v <= 7 for v in values), values)

    def test_reboot_delay_reads_manager_property_without_unit(self):
        # 真机踩过：systemctl show 带单元名时 Manager 属性输出为空，倒计时永远按 15 秒算
        text = (ROOT / "boot_counter.sh").read_text()
        self.assertNotRegex(text, r'systemctl show systemd\b')
        self.assertIn("systemctl show -p FinishTimestampMonotonic", text)

    def test_reboot_delay_never_goes_negative(self):
        # 事务结束已超过 15 秒（定时器晚了）时立即重启，不能算出负数或倒扣
        uptime = int(float(Path("/proc/uptime").read_text().split()[0]))
        finish_us = max(uptime - 1000, 1) * 1_000_000
        self.command("systemctl",
                     f"if [ \"$1\" = show ]; then echo 'FinishTimestampMonotonic={finish_us}'; fi\n"
                     "exit 0\n")
        log = self.root / "sleep-args"
        self.command("sleep", f"printf '%s\\n' \"$1\" >> {shlex.quote(str(log))}\n")
        (self.install / "reboot_remaining.txt").write_text("1\n")
        self.run_script()
        self.assertEqual(self.reboot_count(), 1)
        values = [int(v) for v in log.read_text().split()] if log.exists() else []
        self.assertEqual([v for v in values if v > 0], [])

    def test_invalid_remaining_never_reboots(self):
        (self.install / "reboot_remaining.txt").write_text("invalid\n")
        self.run_script()
        self.assertEqual(self.reboot_count(), 0)
        self.assertIn("REBOOT", self.read("logs/error/error.log"))


    def test_boot_time_waits_for_transaction_with_a_cap(self):
        # timer 可能早于启动事务结束触发（本机启动比 OnBootSec 慢时）。晚段要能等到
        # 事务结束再取全链耗时，但等待必须有上限，否则事务永不结束就一直占着报告任务。
        self.command("systemd-analyze",
                     'echo "Bootup is not yet finished (FinishTimestampMonotonic=0)."\nexit 1\n')
        self.baseline()
        result = self.run_script(env={"BOOT_WAIT_MAX_SEC": "2"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("等待启动事务结束", result.stdout)
        # 无全链数据时退回 uptime 口径，并在摘要里标注来源。
        # 不断言基准文件内容：宿主机 uptime 可能已超出启动窗口，那时不写基准才是正确行为。
        self.assertIn("src=uptime", self.read("logs/boot/normal_summary.log"))

    def test_early_stage_only_counts(self):
        # 早段的全部职责就是计数：不能碰硬件基准、不能写摘要，更不能等启动事务。
        result = self.run_script("boot_count.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read("boot_count.txt").strip(), "1")
        self.assertFalse((self.install / "hardware_baseline.txt").exists())
        self.assertFalse((self.install / "logs/boot/normal_summary.log").exists())
        self.assertFalse((self.install / "boot_time_baseline.txt").exists())
        self.assertFalse((self.install / ".last_reported_boot_id").exists())

    def test_early_stage_records_log_pointer_for_late_stage(self):
        # 晚段沿用早段建立的日志名，异常详情才会集中在同一份 boot_*.log 里
        self.baseline(REPORT + "  - USB设备: aaaa:1111\n")   # 缺设备 -> 异常，详细日志保留
        self.run_script()
        pointer = self.read(".boot_log").strip()
        self.assertTrue(pointer, "早段没有写下本次开机日志指针")
        self.assertTrue(Path(pointer).exists(), pointer)
        self.assertEqual(len(list((self.install / "logs/boot").glob("boot_*.log"))), 1)

    def test_report_runs_once_per_boot(self):
        self.baseline()
        self.run_script()
        lines = len(self.read("logs/boot/normal_summary.log").splitlines())
        result = self.run_script("boot_counter.sh", "report")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("本次开机的报告已完成", result.stdout)
        self.assertEqual(len(self.read("logs/boot/normal_summary.log").splitlines()), lines)

    def test_forced_report_repeats_without_counting(self):
        # 管理工具的"立即运行一次"重跑报告，但绝不能把开机计数加回去
        self.baseline()
        self.run_script()
        lines = len(self.read("logs/boot/normal_summary.log").splitlines())
        result = self.run_script("boot_counter.sh", "report",
                                 env={"BOOT_MONITOR_FORCE": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read("boot_count.txt").strip(), "1")
        self.assertEqual(len(self.read("logs/boot/normal_summary.log").splitlines()), lines + 1)

    def test_report_needs_a_count_from_the_early_stage(self):
        # 晚段单独运行却拿不到计数时不能瞎写摘要，直接报错退出
        result = self.run_script("boot_counter.sh", "report")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.install / "logs/boot/normal_summary.log").exists())

    def test_report_lock_blocks_a_second_report(self):
        self.baseline()
        self.run_script("boot_count.sh")
        self.hold_lock(".boot_report.lock")
        result = self.run_script("boot_counter.sh", "report")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("已在运行", result.stdout)
        self.assertFalse((self.install / "logs/boot/normal_summary.log").exists())

    def test_boot_time_slower_than_baseline_alarms(self):
        (self.install / "boot_time_baseline.txt").write_text("10 systemd-analyze\n")
        self.baseline()
        self.command("systemd-analyze", "echo 'Startup finished in 30s (userspace) = 30s'\n")
        self.run_script()
        self.assertIn("BOOT_SLOW", self.read("logs/error/error.log"))
        self.assertIn("status=ERROR", self.read("logs/boot/normal_summary.log"))

    def test_boot_time_faster_than_baseline_alarms(self):
        (self.install / "boot_time_baseline.txt").write_text("30 systemd-analyze\n")
        self.baseline()
        self.run_script()
        self.assertIn("BOOT_FAST", self.read("logs/error/error.log"))
        self.assertIn("status=ERROR", self.read("logs/boot/normal_summary.log"))

    def test_boot_time_within_tolerance_is_normal(self):
        (self.install / "boot_time_baseline.txt").write_text("13 systemd-analyze\n")
        self.baseline()
        self.run_script()
        self.assertIn("status=OK", self.read("logs/boot/normal_summary.log"))
        self.assertNotIn("BOOT_FAST", self.read("logs/error/error.log"))

    def test_summary_records_boot_time_source(self):
        self.run_script()
        self.assertIn("time=10s src=systemd-analyze", self.read("logs/boot/normal_summary.log"))

    def test_counter_lock_prevents_concurrent_write(self):
        self.hold_lock(".boot_counter.lock")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.install / "boot_count.txt").exists())

    def test_counter_reboot_respects_another_reboot_request(self):
        self.hold_lock(".reboot_request.lock")
        (self.install / "reboot_remaining.txt").write_text("2\n")
        self.run_script()
        self.assertEqual(self.reboot_count(), 0)
        self.assertEqual(self.read("reboot_remaining.txt").strip(), "2")

    def test_failed_counter_commit_preserves_old_count(self):
        (self.install / "boot_count.txt").write_text("5\n")
        self.command("mv", "exit 1\n")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read("boot_count.txt").strip(), "5")
        self.assertFalse((self.install / ".last_counted_boot_id").exists())


class ManagerTests(Sandbox):
    def test_request_one_reboot_does_not_schedule_second(self):
        result = self.run_script("boot_manager.sh", "reboot_with_count", input="1\ny\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.reboot_count(), 1)
        self.assertEqual(self.read("reboot_remaining.txt").strip(), "0")
        self.run_script()
        self.assertEqual(self.reboot_count(), 1)

    def test_eof_exits_menu(self):
        try:
            result = self.run_script("boot_manager.sh", "main", timeout=1)
        except subprocess.TimeoutExpired:
            self.fail("管理菜单遇到 EOF 后仍在循环")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_oversized_manager_count_is_rejected(self):
        result = self.run_script("boot_manager.sh", "set_boot_count", input="99999999999999999999999999\n\n")
        self.assertFalse((self.install / "boot_count.txt").exists(), result.stdout)

    def test_manual_scan_detects_loss_of_identical_usb(self):
        self.baseline(REPORT.replace("完成时间:", "  - USB设备: 1234:5678\n完成时间:"))
        result = self.run_script("boot_manager.sh", "run_hardware_check", input="n\n\n")
        self.assertIn("丢失设备", result.stdout)

    def test_service_status_covers_all_three_units(self):
        # 早段单元计数后立刻 active(exited)，只展示它等于什么都没说：
        # 操作员还要能看到报告服务与报告定时器的状态
        self.force_init("systemd")
        self.command("systemctl", 'if [ "$1" = status ]; then echo "STATUS:$2"; fi\nexit 0\n')
        result = self.run_script("boot_manager.sh", "service_management", input="0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        for unit in ("boot-monitor.service", "boot-monitor-report.service",
                     "boot-monitor-report.timer"):
            self.assertIn(f"STATUS:{unit}", result.stdout)

    def test_service_status_on_busybox_shows_init_block_once(self):
        # 非 systemd 平台只有一个 init 脚本。把三个单元的状态块都打出来，
        # 操作员会以为装了三份服务，而且每块都在重复同一份 init 信息。
        self.force_init("busybox")
        result = self.run_script("boot_manager.sh", "service_management", input="0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("init 系统: busybox"), 1)


    def test_three_requested_reboots_are_exactly_three(self):
        self.run_script("boot_manager.sh", "reboot_with_count", input="3\ny\n")
        for number in range(3):
            self.boot_id.write_text(f"00000000-0000-0000-0000-{number:012d}\n")
            result = self.run_script()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.reboot_count(), 3)
        self.assertEqual(self.read("boot_count.txt").strip(), "3")
        self.assertFalse((self.install / "reboot_remaining.txt").exists())

    def test_manager_cancel_during_delay(self):
        self.command("sleep", f"if [ \"$1\" = 5 ]; then : > {shlex.quote(str(self.install / 'reboot_remaining.txt'))}; fi\n")
        self.run_script("boot_manager.sh", "reboot_with_count", input="2\ny\n")
        self.assertEqual(self.reboot_count(), 0)

    def test_manager_reboot_failure_restores_count(self):
        self.command("reboot", "exit 1\n")
        result = self.run_script("boot_manager.sh", "reboot_with_count", input="2\ny\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read("reboot_remaining.txt").strip(), "2")

    def test_manual_scan_does_not_conflict_with_boot_scan(self):
        self.hold_lock(".boot_counter.lock")
        self.baseline()
        self.hardware(REPORT + "  - new device\n")
        self.run_script("boot_manager.sh", "run_hardware_check", input="y\n\n")
        self.assertEqual(self.read("hardware_baseline.txt"), REPORT)

    def test_counter_edit_does_not_conflict_with_boot_scan(self):
        self.hold_lock(".boot_counter.lock")
        (self.install / "boot_count.txt").write_text("5\n")
        self.run_script("boot_manager.sh", "set_boot_count", input="9\n\n")
        self.assertEqual(self.read("boot_count.txt").strip(), "5")

    def test_failed_counter_edit_is_not_reported_as_success(self):
        self.command("mv", "exit 1\n")
        (self.install / "boot_count.txt").write_text("5\n")
        result = self.run_script("boot_manager.sh", "set_boot_count", input="9\n\n")
        self.assertNotIn("已设置为", result.stdout)
        self.assertEqual(self.read("boot_count.txt").strip(), "5")

    def test_reboot_setup_does_not_run_while_counter_locked(self):
        self.hold_lock(".boot_counter.lock")
        self.baseline()
        self.run_script("boot_manager.sh", "reboot_with_count", input="2\ny\n")
        self.assertEqual(self.reboot_count(), 0)
        self.assertEqual(self.read("hardware_baseline.txt"), REPORT)

    def test_reboot_setup_write_failure_stops_reboot(self):
        (self.install / "boot_count.txt").mkdir()
        result = self.run_script("boot_manager.sh", "reboot_with_count", input="2\ny\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.reboot_count(), 0)
        self.assertFalse((self.install / "reboot_remaining.txt").exists())

    def test_reset_count_uses_exclusive_write(self):
        self.hold_lock(".boot_counter.lock")
        (self.install / "boot_count.txt").write_text("5\n")
        self.run_script("boot_manager.sh", "reset_boot_count", input="y\n\n")
        self.assertEqual(self.read("boot_count.txt").strip(), "5")

    def test_cancel_during_commit_does_not_claim_success(self):
        (self.install / "reboot_remaining.txt").write_text("2\n")
        self.hold_lock(".reboot_state.lock")
        result = self.run_script("boot_manager.sh", "reboot_with_count", input="2\n")
        self.assertNotIn("已取消", result.stdout)
        self.assertEqual(self.read("reboot_remaining.txt").strip(), "2")

    def test_cancel_after_reboot_accepted_does_not_claim_success(self):
        self.run_script("boot_manager.sh", "reboot_with_count", input="2\ny\n")
        result = self.run_script("boot_manager.sh", "reboot_with_count", input="2\n")
        self.assertNotIn("已取消", result.stdout)
        self.assertEqual(self.read("reboot_remaining.txt").strip(), "1")

    def test_cancel_during_counter_commit_is_serialized(self):
        (self.install / "reboot_remaining.txt").write_text("2\n")
        plan = shlex.quote(str(self.install / "reboot_remaining.txt"))
        manager = shlex.quote(str(self.install / "boot_manager.sh"))
        output = self.root / "cancel-output"
        self.command("mv", f'if [ "${{@: -1}}" = {plan} ]; then\n'
                     f"printf '2\\n' | bash {manager} reboot_with_count > {shlex.quote(str(output))}\n"
                     'fi\nexec /bin/mv "$@"\n')
        self.run_script()
        self.assertEqual(self.reboot_count(), 1)
        self.assertNotIn("已取消", output.read_text())

    def test_manual_temperature_failure_compares_without_baseline_update(self):
        original = REPORT + "  - missing device\n"
        self.baseline(original)
        self.hardware(REPORT, 2)
        result = self.run_script("boot_manager.sh", "run_hardware_check", input="y\n\n")
        self.assertIn("丢失设备", result.stdout)
        self.assertEqual(self.read("hardware_baseline.txt"), original)

    def test_invalid_manual_scan_does_not_replace_baseline(self):
        self.baseline()
        self.hardware("", 0)
        self.run_script("boot_manager.sh", "run_hardware_check", input="y\n\n")
        self.assertEqual(self.read("hardware_baseline.txt"), REPORT)


class InstallTests(Sandbox):
    def run_baseline_stage(self, status=0, report=REPORT):
        # 只执行安装器的基准生成阶段，绝不执行系统目录复制和服务操作。
        text = (ROOT / "install.sh").read_text()
        start = text.index('if [ -f "$INSTALL_DIR/hardware_check.sh" ]; then', text.index('# 执行首次硬件检测'))
        end = text.index('# 设置目录权限', start)
        self.hardware(report, status)
        return subprocess.run(["bash", "-c", 'set -e\nINSTALL_DIR="$1"\n' + text[start:end],
                               "test", str(self.install)], text=True, capture_output=True,
                              env=self.env, timeout=5)

    def test_install_timeout_is_handled(self):
        result = self.run_baseline_stage(124)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.install / "hardware_baseline.txt").exists())

    def test_install_scan_failure_is_handled(self):
        result = self.run_baseline_stage(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.install / "hardware_baseline.txt").exists())

    def test_reinstall_preserves_baseline(self):
        self.baseline("existing baseline\n")
        result = self.run_baseline_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read("hardware_baseline.txt"), "existing baseline\n")

    def test_install_success_creates_baseline(self):
        result = self.run_baseline_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read("hardware_baseline.txt"), REPORT)

    def test_platform_library_is_installed(self):
        text = (ROOT / "install.sh").read_text()
        self.assertTrue(re.search(r'cp[^\n]+platform\.sh', text), "安装器遗漏 platform.sh")

    def test_installer_copies_early_stage_script(self):
        text = (ROOT / "install.sh").read_text()
        self.assertTrue(re.search(r'cp[^\n]+boot_count\.sh', text), "安装器遗漏 boot_count.sh")

    def test_installer_installs_and_enables_report_units(self):
        text = (ROOT / "install.sh").read_text()
        for unit in ("boot-monitor-report.service", "boot-monitor-report.timer"):
            self.assertIn(unit, text, f"安装器未处理 {unit}")
        # report.service 没有 [Install]，只能靠 enable timer 生效
        self.assertIn("systemctl enable boot-monitor-report.timer", text)

    def test_uninstaller_removes_report_units(self):
        text = (ROOT / "uninstall.sh").read_text()
        for unit in ("boot-monitor-report.service", "boot-monitor-report.timer"):
            self.assertIn(unit, text, f"卸载脚本遗漏 {unit}")

    def test_empty_install_scan_is_handled(self):
        result = self.run_baseline_stage(report="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("integer expression", result.stderr)
        self.assertFalse((self.install / "hardware_baseline.txt").exists())


class HardwareTests(Sandbox):
    def run_hardware(self):
        # 重定向内核文件路径到测试夹具，保留原检测算法。
        # 只替换完整路径前缀：/sys/.../device 里的 /dev 不能被当作 /dev 根目录。
        text = (ROOT / "hardware_check.sh").read_text().replace("/dev/null", "__NULL_DEVICE__")
        for prefix in ("sys", "proc", "dev"):
            text = re.sub(rf"(?<![\w.])/{prefix}(?=[/\s\"']|$)", str(self.root / prefix), text)
        text = text.replace("__NULL_DEVICE__", "/dev/null")
        target = self.root / "hardware_fixture.sh"
        target.write_text(text)
        return subprocess.run(["bash", str(target)], text=True, capture_output=True,
                              env=self.env, timeout=5)

    def node(self, path, value):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value)

    def dir(self, path):
        target = self.root / path
        target.mkdir(parents=True, exist_ok=True)
        return target

    def identities(self, result):
        return [line for line in result.stdout.splitlines() if line.startswith("  - ")]

    def test_phantom_serial_ports_are_not_counted(self):
        self.node("dev/ttyS0", "")
        self.dir("sys/class/tty/ttyS0")
        self.node("sys/class/tty/ttyS0/type", "0")
        result = self.run_hardware()
        self.assertFalse(any("ttyS0" in line for line in self.identities(result)))
        self.assertIn("未检测到串口设备", result.stdout)

    def test_real_serial_port_is_counted(self):
        self.node("dev/ttyS1", "")
        self.dir("sys/class/tty/ttyS1/device")
        self.node("sys/class/tty/ttyS1/type", "4")
        result = self.run_hardware()
        self.assertTrue(any("ttyS1" in line for line in self.identities(result)), result.stdout)

    def test_virtio_disk_is_counted_with_mb_size(self):
        self.node("dev/vda", "")
        self.node("sys/block/vda/size", str(1024 * 1024))  # 512MB
        result = self.run_hardware()
        self.assertTrue(any("vda (虚拟磁盘)" in line for line in self.identities(result)), result.stdout)
        self.assertIn("容量:512MB", result.stdout)
        self.assertNotIn("未检测到存储设备", result.stdout)

    def test_virtual_interface_is_not_in_identity_lines(self):
        self.node("sys/class/net/docker0/address", "02:42:ac:11:00:02")
        self.dir("sys/class/net/eth0/device")
        self.node("sys/class/net/eth0/address", "00:11:22:33:44:55")
        result = self.run_hardware()
        lines = self.identities(result)
        self.assertTrue(any("eth0" in line for line in lines))
        self.assertFalse(any("docker0" in line for line in lines))
        self.assertIn("虚拟接口: docker0", result.stdout)

    def test_connected_display_connector_is_identity(self):
        self.dir("sys/class/drm/card0/device")
        self.node("sys/class/drm/card0/device/vendor", "0x8086")
        self.node("sys/class/drm/card0/device/device", "0x1234")
        self.node("sys/class/drm/card0-DP-1/status", "connected")
        self.node("sys/class/drm/card0-HDMI-A-1/status", "disconnected")
        result = self.run_hardware()
        lines = self.identities(result)
        self.assertTrue(any("card0" in line and "0x8086" in line for line in lines))
        self.assertTrue(any("card0-DP-1 [connected]" in line for line in lines))
        self.assertFalse(any("HDMI-A-1" in line for line in lines))
        self.assertIn("接口 card0-HDMI-A-1: disconnected", result.stdout)

    def test_common_4g_module_vendor_is_detected(self):
        self.node("sys/bus/usb/devices/1-1/idVendor", "2c7c")
        self.node("sys/bus/usb/devices/1-1/idProduct", "0125")
        self.node("sys/bus/usb/devices/1-1/product", "EC25-E")
        self.node("sys/bus/usb/devices/1-1/manufacturer", "Quectel")
        result = self.run_hardware()
        self.assertIn("4G模块: 2c7c:0125", result.stdout)

    def test_non_can_interface_named_can_is_not_counted(self):
        self.node("sys/class/net/can0/type", "1")
        result = self.run_hardware()
        self.assertNotIn("can0 (CAN接口)", result.stdout)
        self.assertIn("未检测到CAN设备", result.stdout)

    def test_realtek_wireless_is_not_mistaken_for_4g(self):
        base = "sys/bus/usb/devices/1-2"
        self.node(base + "/idVendor", "0bda")
        self.node(base + "/idProduct", "d723")
        self.node(base + "/product", "802.11n WLAN Adapter")
        self.node(base + "/manufacturer", "Realtek")
        result = self.run_hardware()
        self.assertNotIn("4G模块: 0bda:d723", result.stdout)
        self.assertIn("未检测到4G模块", result.stdout)

    def test_can_interface_is_not_counted_as_nic(self):
        self.dir("sys/class/net/can0/device")
        self.node("sys/class/net/can0/type", "280")
        result = self.run_hardware()
        self.assertIn("CAN接口: can0", result.stdout)
        self.assertIn("检测到 1 个CAN设备", result.stdout)
        self.assertNotIn("个物理网络接口", result.stdout)

    def test_wireless_interface_is_excluded_from_baseline(self):
        # WiFi 的 MAC 会随机化，接口名 wlx<MAC> 跟着变，整行都不能进基准；
        # 无线模块本身的存在仍由 USB/PCI 段体现。
        self.dir("sys/class/net/wlx4c24cec984ce/device")
        self.dir("sys/class/net/wlx4c24cec984ce/wireless")
        self.node("sys/class/net/wlx4c24cec984ce/address", "4c:24:ce:c9:84:ce")
        self.node("sys/class/net/wlx4c24cec984ce/operstate", "up")
        self.dir("sys/class/net/enp4s0/device")
        self.node("sys/class/net/enp4s0/address", "2c:16:bd:d4:fd:e6")
        result = self.run_hardware()
        lines = self.identities(result)
        self.assertFalse(any("wlx" in line for line in lines), result.stdout)
        self.assertTrue(any("enp4s0 [MAC:2c:16:bd:d4:fd:e6]" in line for line in lines), result.stdout)
        self.assertIn("无线网卡: wlx4c24cec984ce [MAC:4c:24:ce:c9:84:ce]（不参与硬件比对）", result.stdout)
        self.assertIn("检测到 2 个物理网络接口", result.stdout)
        self.assertIn("检测到 1 个WiFi设备", result.stdout)

    def test_random_mac_interface_keeps_name_without_mac(self):
        # qmi_wwan 等蜂窝网卡每次开机随机 MAC：addr_assign_type 非 0 时
        # 标识行只保留稳定的接口名，MAC 降级为展示信息。
        self.dir("sys/class/net/wwan0/device")
        self.node("sys/class/net/wwan0/address", "02:38:ff:e2:83:ab")
        self.node("sys/class/net/wwan0/addr_assign_type", "1")
        self.node("sys/class/net/wwan0/operstate", "down")
        result = self.run_hardware()
        self.assertTrue(any(line.strip() == "- wwan0" for line in self.identities(result)), result.stdout)
        self.assertNotIn("[MAC:02:38:ff:e2:83:ab]", result.stdout)
        self.assertIn("非烧录地址，不参与硬件比对", result.stdout)

    def test_burned_in_mac_stays_in_identity(self):
        self.dir("sys/class/net/enp4s0/device")
        self.node("sys/class/net/enp4s0/address", "2c:16:bd:d4:fd:e6")
        self.node("sys/class/net/enp4s0/addr_assign_type", "0")
        result = self.run_hardware()
        self.assertTrue(any("enp4s0 [MAC:2c:16:bd:d4:fd:e6]" in line
                            for line in self.identities(result)), result.stdout)

    def test_audio_pcm_name_stays_on_one_line(self):
        self.node("proc/asound/card0/id", "PCH")
        self.node("proc/asound/card0/pcm3p/info",
                  "pcm3p:\n  name : HDMI 0\n  subname : HDMI 0\n  subdevices : #0\n")
        result = self.run_hardware()
        self.assertIn("pcm3p: HDMI 0\n", result.stdout)
        self.assertNotIn("subdevice", result.stdout)

    def test_disk_model_whitespace_is_trimmed(self):
        self.node("dev/sda", "")
        self.node("sys/block/sda/size", "234441216")
        self.node("sys/block/sda/device/model", "FORESEE 128GB SS   ")
        result = self.run_hardware()
        self.assertTrue(any("型号:FORESEE 128GB SS 容量:" in line for line in self.identities(result)),
                        result.stdout)

    def test_absent_optional_hardware_is_skipped_not_failed(self):
        result = self.run_hardware()
        self.assertIn("跳过（本机未配置）", result.stdout)
        self.assertIn("未检测到串口设备", result.stdout)
        self.assertEqual(result.returncode, 0)

    def test_wwan_interface_is_not_counted_twice(self):
        self.node("sys/class/net/wwan0/operstate", "up")
        result = self.run_hardware()
        self.assertIn("检测到 1 个4G/LTE模块相关设备", result.stdout)

    def test_out_of_range_temperature_returns_failure(self):
        self.node("sys/class/thermal/thermal_zone0/temp", "102001")
        self.node("sys/class/thermal/thermal_zone0/type", "CPU")
        result = self.run_hardware()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("温度异常", result.stdout)

    def test_unreadable_sensor_alongside_valid_sensor_is_failure(self):
        self.node("sys/class/thermal/thermal_zone0/temp", "45000")
        self.node("sys/class/thermal/thermal_zone1/temp", "")
        result = self.run_hardware()
        self.assertNotEqual(result.returncode, 0)

    def test_temperature_boundaries_and_invalid_values(self):
        for value, expected in (("-45000", 0), ("102000", 0), ("-45001", 2),
                                ("008000", 0), ("invalid", 2), ("", 2)):
            with self.subTest(value=value):
                self.node("sys/class/thermal/thermal_zone0/temp", value)
                result = self.run_hardware()
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_hwmon_temperature_boundary(self):
        self.node("sys/class/hwmon/hwmon0/temp1_input", "102001")
        result = self.run_hardware()
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_missing_optional_hardware_is_not_runtime_failure(self):
        result = self.run_hardware()
        self.assertEqual(result.returncode, 0, result.stderr)


class ServiceTests(unittest.TestCase):
    def test_no_multi_user_ordering_cycle(self):
        text = (ROOT / "boot-monitor.service").read_text()
        self.assertNotRegex(text, r'(?m)^After=.*multi-user\.target')

    def test_early_unit_only_counts(self):
        text = (ROOT / "boot-monitor.service").read_text()
        self.assertIn("ExecStart=/opt/boot_monitor/boot_count.sh", text)
        # 早段一旦调用完整脚本，就会把硬件检测和等待事务拖进启动关键路径
        self.assertNotIn("boot_counter.sh", text)

    def test_report_unit_is_timer_triggered_only(self):
        service = (ROOT / "boot-monitor-report.service").read_text()
        self.assertIn("ExecStart=/opt/boot_monitor/boot_counter.sh report", service)
        # 被任何 target 拉起都会让它重新成为启动事务的成员，systemd-analyze 就永远读不到全链耗时
        self.assertNotRegex(service, r'(?m)^\[Install\]')
        self.assertNotRegex(service, r'(?m)^WantedBy=')
        timer = (ROOT / "boot-monitor-report.timer").read_text()
        self.assertIn("Unit=boot-monitor-report.service", timer)
        self.assertRegex(timer, r'(?m)^OnBootSec=\d+$')
        self.assertIn("WantedBy=timers.target", timer)

    def test_timer_fires_after_userspace_boot(self):
        # OnBootSec 从内核启动计时，必须晚于本机 userspace 启动耗时，
        # 否则报告任务会插进还没结束的启动事务，全链耗时永远取不到。
        timer = (ROOT / "boot-monitor-report.timer").read_text()
        sec = int(re.search(r'(?m)^OnBootSec=(\d+)$', timer).group(1))
        self.assertGreaterEqual(sec, 20)
        self.assertIn("userspace", timer)

    def test_report_unit_timeout_covers_wait_and_scan(self):
        service = (ROOT / "boot-monitor-report.service").read_text()
        wait = int(re.search(r'BOOT_WAIT_MAX_SEC=(\d+)', service).group(1))
        timeout = int(re.search(r'TimeoutStartSec=(\d+)', service).group(1))
        # 等待事务结束 + 300s 硬件检测 + 重启倒计时 + 落盘余量
        self.assertGreater(timeout, wait + 300 + 15)

    def test_count_unit_finishes_within_seconds(self):
        # 计数必须尽早落盘，单元超时只作兜底，不能给成"慢慢跑"的量级
        text = (ROOT / "boot-monitor.service").read_text()
        timeout = int(re.search(r'TimeoutStartSec=(\d+)', text).group(1))
        self.assertLessEqual(timeout, 60)

    def test_systemd_unit_verifies(self):
        with tempfile.TemporaryDirectory(prefix="unit-test-", dir=ROOT / "tests") as tmp:
            for name in ("boot-monitor.service", "boot-monitor-report.service",
                         "boot-monitor-report.timer", "boot_count.sh", "boot_counter.sh"):
                shutil.copy(ROOT / name, Path(tmp) / name)
            for name in ("boot-monitor.service", "boot-monitor-report.service",
                         "boot-monitor-report.timer"):
                with self.subTest(unit=name):
                    unit = Path(tmp) / name
                    text = unit.read_text()
                    # 脚本替身：verify 只解析单元，不执行 ExecStart，但路径必须存在性一致
                    for script in ("boot_count.sh", "boot_counter.sh"):
                        text = text.replace(f"/opt/boot_monitor/{script}", "/bin/true")
                    text = text.replace("WorkingDirectory=/opt/boot_monitor", f"WorkingDirectory={tmp}")
                    unit.write_text(text)
                    result = subprocess.run(["systemd-analyze", "verify", "--man=no", str(unit)],
                                            text=True, capture_output=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_service_timeout_exceeds_total_work_time(self):
        text = (ROOT / "boot-monitor.service").read_text()
        timeout = int(re.search(r'TimeoutStartSec=(\d+)', text).group(1))
        # 早段只做计数，超时是兜底而不是预算
        self.assertGreater(timeout, 10)


class PlatformCompatTests(unittest.TestCase):
    """验证 BusyBox 能力子集下的命令降级路径。"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="plat-test-", dir=ROOT / "tests")
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()

    def run_snippet(self, snippet, path=None):
        env = dict(os.environ, LC_ALL="C.UTF-8")
        if path:
            env["PATH"] = str(path)
        return subprocess.run([BASH, "-c", f'source "{ROOT / "platform.sh"}"\n{snippet}'],
                              text=True, capture_output=True, env=env, timeout=20)

    def link(self, name):
        source = shutil.which(name, path="/usr/bin:/bin")
        self.assertIsNotNone(source, f"host 缺少 {name}")
        (self.bin / name).symlink_to(source)

    def test_atomic_replace_works_and_refuses_directory(self):
        src = self.dir / "new.txt"
        dest = self.dir / "target.txt"
        src.write_text("new")
        dest.write_text("old")
        result = self.run_snippet(f'plat_atomic_replace "{src}" "{dest}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(dest.read_text(), "new")

        src.write_text("keep")
        folder = self.dir / "folder"
        folder.mkdir()
        result = self.run_snippet(f'plat_atomic_replace "{src}" "{folder}"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(src.read_text(), "keep")
        self.assertTrue(folder.is_dir())

    def test_timeout_falls_back_when_kill_flag_unsupported(self):
        stub = self.bin / "timeout"
        stub.write_text('#!/bin/bash\nif [ "$1" = "-k" ]; then exit 1; fi\n'
                        'shift\nexec "$@"\n')
        stub.chmod(0o755)
        result = self.run_snippet('plat_timeout 5 bash -c "exit 7"; echo "rc=$?"',
                                  path=f"{self.bin}:/usr/bin:/bin")
        self.assertIn("rc=7", result.stdout, result.stderr)

    def test_timeout_falls_back_when_command_missing(self):
        self.link("sleep")
        result = self.run_snippet('plat_timeout 1 sleep 5; echo "rc=$?"', path=self.bin)
        self.assertIn("rc=124", result.stdout, result.stderr)

    def test_initd_scripts_parse(self):
        for name in ("boot-monitor.initd",):
            for shell in ("sh", "bash"):
                result = subprocess.run([shell, "-n", str(ROOT / name)],
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, f"{shell} -n {name}: {result.stderr}")


class DistroCompatTests(Sandbox):
    def minimal_env(self, commands, exclude=()):
        path = self.root / "minbin"
        path.mkdir(exist_ok=True)
        for name in commands:
            if name in exclude:
                continue
            source = shutil.which(name, path="/usr/bin:/bin")
            if source and not (path / name).exists():
                (path / name).symlink_to(source)
        env = dict(self.env)
        env["PATH"] = str(path)
        return env

    def test_counter_counts_without_flock(self):
        env = self.minimal_env((
            "bash", "locale", "grep", "mkdir", "cat", "mktemp", "chmod", "sync",
            "mv", "date", "sleep", "rm", "cp", "touch", "awk", "sed", "sort",
            "head", "tail", "tr", "wc", "basename", "find", "du", "stat", "uname",
            "uptime", "tee", "timeout", "dmesg", "true", "ls",
        ), exclude=("flock",))
        result = subprocess.run([BASH, str(self.install / "boot_counter.sh")],
                                text=True, capture_output=True, env=env, timeout=20)
        self.assertIn("未找到 flock", result.stdout + result.stderr)
        self.assertEqual(self.read("boot_count.txt").strip(), "1")

    def test_install_selects_busybox_initd(self):
        text = (ROOT / "install.sh").read_text()
        text = text.replace('SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
                            f'SCRIPT_DIR="{ROOT}"')
        text = text.replace("/opt/boot_monitor", str(self.install))
        text = text.replace("/etc/systemd/system/", str(self.root / "etc/systemd/system") + "/")
        text = text.replace("/etc/init.d/", str(self.root / "etc/init.d") + "/")
        text = text.replace("/usr/local/bin/", str(self.root / "usr/local/bin") + "/")
        text = text.replace("/etc/xdg/autostart", str(self.root / "etc/xdg/autostart"))
        text = text.replace('if [ "$EUID" -ne 0 ]; then', "if false; then")
        script = self.root / "install_busybox.sh"
        script.write_text(text)
        (self.root / "etc/init.d").mkdir(parents=True, exist_ok=True)
        (self.root / "usr/local/bin").mkdir(parents=True, exist_ok=True)

        env = dict(self.env, BOOT_MONITOR_INIT="busybox")
        result = subprocess.run([BASH, str(script)], text=True, capture_output=True,
                                env=env, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        initd = self.root / "etc/init.d/S99boot-monitor"
        self.assertTrue(initd.exists(), result.stdout)
        self.assertTrue(os.access(initd, os.X_OK))
        self.assertFalse((self.root / "etc/systemd/system/boot-monitor.service").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
