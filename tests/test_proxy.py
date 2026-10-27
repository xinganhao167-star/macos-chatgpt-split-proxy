import fnmatch
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ProxyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = pathlib.Path(self.tmp.name) / "home"
        self.home.mkdir()
        self.bin = pathlib.Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        for name in ("uname", "networksetup", "launchctl", "nc", "pgrep", "ps", "curl", "scutil", "osascript"):
            (self.bin / name).symlink_to(ROOT / "tests/mock.py")
        self.state = pathlib.Path(self.tmp.name) / "state.json"
        self.state.write_text(json.dumps({
            "services": ["Wi-Fi", "USB 10/100/1000 LAN"],
            "pac": {
                "Wi-Fi": {"url": "http://old.example/proxy.pac", "enabled": "Yes"},
                "USB 10/100/1000 LAN": {"url": "", "enabled": "No"},
            },
            "launch": [],
        }))
        self.env = dict(os.environ, HOME=str(self.home), MOCK_STATE=str(self.state),
                        PATH=str(self.bin) + ":" + os.environ["PATH"],
                        SPLIT_PROXY_CONFIG_DIR=str(self.home / "Library/Application Support/chatgpt-split-proxy"))

    def run_script(self, script, *args, **env):
        return subprocess.run([str(ROOT / script), *args], env=dict(self.env, **env),
                              text=True, capture_output=True, timeout=40)

    def install(self, *args):
        result = self.run_script("install.sh", *args)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def test_dry_run_has_no_side_effects(self):
        result = self.run_script("install.sh", "--dry-run", "--proxy", "127.0.0.1:7897")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.home / "proxy-pac").exists())
        self.assertFalse((self.home / "Desktop").exists())
        self.assertFalse((self.home / "Library/Application Support/chatgpt-split-proxy").exists())
        self.assertEqual(json.loads(self.state.read_text())["launch"], [])

    def test_install_repeat_custom_port_and_uninstall_restore(self):
        self.install("--proxy", "127.0.0.1:7897", "--with-watchdog")
        self.install("--with-watchdog")
        self.install("--proxy", "127.0.0.1:7897", "--pac-port", "8900", "--with-watchdog")
        config = (self.home / "Library/Application Support/chatgpt-split-proxy/config").read_text()
        pac = (self.home / "proxy-pac/split.pac").read_text()
        launcher = (self.home / "Desktop/ChatGPT代理启动.command").read_text()
        for name in ("local.pac-server.plist", "local.codex-proxy-guard.plist"):
            with (self.home / "Library/LaunchAgents" / name).open("rb") as handle:
                self.assertIsInstance(plistlib.load(handle), dict)
        self.assertIn("PROXY_PORT=7897", config)
        self.assertIn("PAC_PORT=8900", config)
        self.assertIn("PROXY 127.0.0.1:7897", pac)
        self.assertIn('load_config', launcher)
        self.assertNotIn("pkill", launcher)
        self.assertIn("USB 10/100/1000 LAN", json.loads(self.state.read_text())["pac"])
        self.assertEqual(json.loads(self.state.read_text())["pac"]["Wi-Fi"]["url"],
                         "http://127.0.0.1:8900/split.pac")
        result = self.run_script("uninstall.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        pac_state = json.loads(self.state.read_text())["pac"]
        self.assertEqual(pac_state["Wi-Fi"], {"url": "http://old.example/proxy.pac", "enabled": "Yes"})
        self.assertEqual(pac_state["USB 10/100/1000 LAN"], {"url": "", "enabled": "No"})
        self.assertEqual(self.run_script("uninstall.sh").returncode, 0)

    def test_uninstall_preserves_external_pac_change(self):
        self.install("--proxy", "127.0.0.1:7897")
        state = json.loads(self.state.read_text())
        state["pac"]["Wi-Fi"] = {"url": "http://new.example/pac", "enabled": "Yes"}
        self.state.write_text(json.dumps(state))
        result = self.run_script("uninstall.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.state.read_text())["pac"]["Wi-Fi"]["url"],
                         "http://new.example/pac")

    def test_install_failure_rolls_back(self):
        result = self.run_script("install.sh", "--proxy", "127.0.0.1:7897", MOCK_FAIL_LAUNCH="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / "Library/Application Support/chatgpt-split-proxy/config").exists())
        self.assertEqual(json.loads(self.state.read_text())["pac"]["Wi-Fi"]["url"], "http://old.example/proxy.pac")

    def test_network_write_failure_rolls_back_all_services(self):
        result = self.run_script("install.sh", "--proxy", "127.0.0.1:7897", MOCK_FAIL_NETWORK="1")
        self.assertNotEqual(result.returncode, 0)
        pac = json.loads(self.state.read_text())["pac"]
        self.assertEqual(pac["Wi-Fi"], {"url": "http://old.example/proxy.pac", "enabled": "Yes"})
        self.assertEqual(pac["USB 10/100/1000 LAN"], {"url": "", "enabled": "No"})
        self.assertFalse((self.home / "Library/Application Support/chatgpt-split-proxy/config").exists())

    def test_guard_states_and_safety(self):
        self.install("--proxy", "127.0.0.1:7897", "--with-watchdog")
        self.assertIn("ABSENT", self.run_script("guard.sh", "--check").stdout)
        self.assertIn("CONFIG_OK", self.run_script("guard.sh", "--check", MOCK_MAIN="1", MOCK_CHILD="1").stdout)
        self.assertIn("BAD", self.run_script("guard.sh", "--check", MOCK_MAIN="1", MOCK_CHILD="1", MOCK_ENV="wrong").stdout)
        self.assertIn("BAD", self.run_script("guard.sh", "--check", MOCK_MAIN="1", MOCK_CHILD="1", MOCK_ENV="empty").stdout)
        self.assertIn("UNKNOWN", self.run_script("guard.sh", "--check", MOCK_MAIN="1", MOCK_CHILD="1", MOCK_ENV="unknown").stdout)
        self.assertIn("UNKNOWN", self.run_script("guard.sh", "--check", MOCK_MAIN="1").stdout)
        self.assertIn("BAD", self.run_script("guard.sh", "--check", MOCK_MAIN="1", MOCK_CHILD="1", MOCK_PROXY="0").stdout)
        source = (ROOT / "guard.sh").read_text()
        self.assertNotRegex(source, r"\b(?:p?kill|killall)\b")
        # Even explicit recovery cannot touch a running app.
        result = self.run_script("guard.sh", "--auto-recover", MOCK_MAIN="1", MOCK_CHILD="1", MOCK_ENV="wrong")
        self.assertIn("BAD", result.stdout)

    def test_auto_recover_requires_launcher_proxy_and_cooldown(self):
        self.install("--proxy", "127.0.0.1:7897")
        self.assertIn("UNKNOWN", self.run_script("guard.sh", "--auto-recover",
                                                 GUARD_LAUNCHER=str(self.home / "missing")).stdout)
        marker = pathlib.Path(self.tmp.name) / "launches"
        launcher = pathlib.Path(self.tmp.name) / "launcher"
        launcher.write_text("#!/bin/sh\necho x >> \"$MOCK_LAUNCHES\"\n")
        launcher.chmod(0o755)
        env = {"GUARD_LAUNCHER": str(launcher), "MOCK_LAUNCHES": str(marker)}
        self.assertIn("UNKNOWN", self.run_script("guard.sh", "--auto-recover", MOCK_PROXY="0", **env).stdout)
        self.assertFalse(marker.exists())
        self.assertIn("STARTED", self.run_script("guard.sh", "--auto-recover", **env).stdout)
        self.assertIn("UNKNOWN", self.run_script("guard.sh", "--auto-recover", **env).stdout)
        self.assertEqual(marker.read_text().splitlines(), ["x"])

    def test_launcher_never_interrupts_running_app(self):
        self.install("--proxy", "127.0.0.1:7897")
        app = pathlib.Path(self.tmp.name) / "ChatGPT.app"
        binary = app / "Contents/MacOS/ChatGPT"
        binary.parent.mkdir(parents=True)
        marker = pathlib.Path(self.tmp.name) / "app_started"
        binary.write_text("#!/bin/sh\necho x >> \"$MOCK_LAUNCHES\"\n")
        binary.chmod(0o755)
        launcher = self.home / "Desktop/ChatGPT代理启动.command"
        result = subprocess.run([str(launcher)], env=dict(self.env, SPLIT_PROXY_APP_PATH=str(app),
                                MOCK_MAIN="1", MOCK_LAUNCHES=str(marker)),
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(marker.exists())

    def test_diagnose_doctor_failure_and_timeout(self):
        self.install("--proxy", "127.0.0.1:7897")
        app = pathlib.Path(self.tmp.name) / "ChatGPT.app"
        cli = app / "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        cli.parent.mkdir(parents=True)
        cli.write_text("#!/bin/sh\necho 'websocket failed'\nexit 7\n")
        cli.chmod(0o755)
        env = {"SPLIT_PROXY_APP_PATH": str(app)}
        result = self.run_script("diagnose.sh", **env, MOCK_API="fail")
        self.assertIn("API_UNKNOWN", result.stdout)
        self.assertIn("WEBSOCKET_UNKNOWN", result.stdout)
        self.assertIn("DOCTOR_UNKNOWN 退出码 7", result.stdout)
        cli.write_text("#!/bin/sh\nsleep 3\n")
        result = self.run_script("diagnose.sh", **env, SPLIT_PROXY_DOCTOR_TIMEOUT="1")
        self.assertIn("DOCTOR_UNKNOWN 诊断超时", result.stdout)

    def test_bridge_install_wires_desktop_entry_only(self):
        self.install("--proxy", "127.0.0.1:8080", "--with-bridge", "--socks", "127.0.0.1:1080")
        config = (self.home / "Library/Application Support/chatgpt-split-proxy/config").read_text()
        self.assertIn("BRIDGE_PORT=8081", config)
        self.assertIn("SOCKS_PORT=1080", config)
        bridge = self.home / "Library/Application Support/chatgpt-split-proxy/bridge/http2socks.py"
        self.assertTrue(bridge.exists())
        plist = self.home / "Library/LaunchAgents/local.split-proxy-bridge.plist"
        with plist.open("rb") as handle:
            args = plistlib.load(handle)["ProgramArguments"]
        self.assertIn("--listen", args)
        self.assertIn("8081", args)
        self.assertIn("127.0.0.1:1080", args)
        # 桌面端走桥；浏览器 PAC 仍指向 HTTP 上游
        self.assertIn('"$CLIENT_URL"', (self.home / "Desktop/ChatGPT代理启动.command").read_text())
        self.assertIn("PROXY 127.0.0.1:8080", (self.home / "proxy-pac/split.pac").read_text())
        self.run_script("uninstall.sh")
        self.assertFalse(plist.exists())
        self.assertFalse(bridge.exists())

    def test_bridge_absent_by_default(self):
        self.install("--proxy", "127.0.0.1:7897")
        config = (self.home / "Library/Application Support/chatgpt-split-proxy/config").read_text()
        self.assertNotIn("BRIDGE_PORT", config)
        self.assertFalse((self.home / "Library/LaunchAgents/local.split-proxy-bridge.plist").exists())

    def test_bridge_argument_parsing(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("http2socks", ROOT / "bridge/http2socks.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        args = module.parse_args(["--listen", "9001", "--socks", "127.0.0.1:1081"])
        self.assertEqual((args.listen, args.socks), (9001, "127.0.0.1:1081"))
        args = module.parse_args(["9002", "127.0.0.1:1082"])
        self.assertEqual((args.listen, args.socks), (9002, "127.0.0.1:1082"))

    def test_pac_domain_rules(self):
        source = (ROOT / "split.pac").read_text()
        domains = re.findall(r'^\s+"([^"]+)",?$', source, re.M)
        self.assertTrue(domains)
        def route(host):
            return "PROXY" if any(fnmatch.fnmatchcase(host.lower(), pat) for pat in domains) else "DIRECT"
        for host in ("chatgpt.com", "openai.com", "api.openai.com", "cdn.oaistatic.com",
                     "x.com", "api.x.com", "twitter.com", "api.twitter.com", "t.co",
                     "pbs.twimg.com", "video.twimg.com"):
            self.assertEqual(route(host), "PROXY", host)
        for host in ("example.com", "baidu.com", "notchatgpt.com", "notx.com",
                     "x.com.example.org", "nottwitter.com", "t.co.example.org"):
            self.assertEqual(route(host), "DIRECT", host)

    def test_shell_syntax(self):
        for script in list(ROOT.glob("*.sh")) + list(ROOT.glob("relay/*.sh")):
            result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, script.name + result.stderr)


if __name__ == "__main__":
    unittest.main()
