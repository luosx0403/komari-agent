import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("traffic_installer", str(ROOT / "install-traffic-patch.sh"))
spec = importlib.util.spec_from_loader(loader.name, loader)
installer = importlib.util.module_from_spec(spec)
loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name)
        self.binary = self.base / "agent"
        self.binary.write_bytes(b"previous-binary")
        self.artifact = self.base / "download"
        self.artifact.write_bytes(b"patched-binary")
        self.config = self.base / "service.conf"
        self.state = self.base / "traffic" / "network-total.json"
        self.plan = dict(kind="systemd", scope="user", service="komari-agent.service", binary=str(self.binary), config=str(self.config), uid=os.getuid(), gid=os.getgid(), state_file=str(self.state), active=False)
        self.data = dict(plan=self.plan, action="install", artifact=str(self.artifact), sha256=installer.sha256(self.artifact), original_sha256=installer.sha256(self.binary), version="1.5.10001", official=False, mode="lifetime", repo=installer.DEFAULT_REPO, save_interval=5, disable_auto_update=None, no_restart=False)
        self.manifest = self.base / "manifest.json"

    def apply(self):
        self.manifest.write_text(json.dumps(self.data))
        with contextlib.redirect_stdout(io.StringIO()):
            installer.apply(self.manifest)

    @patch.object(installer, "service_control")
    def test_systemd_install_and_rollback_preserve_state(self, control):
        self.apply()
        self.assertEqual(self.binary.read_bytes(), b"patched-binary")
        text = self.config.read_text()
        self.assertIn('AGENT_NETWORK_MODE=lifetime', text)
        self.assertNotIn('AGENT_DISABLE_AUTO_UPDATE', text)
        self.state.write_text('{"preserved":true}')
        self.data.update(action="rollback")
        self.apply()
        self.assertEqual(self.binary.read_bytes(), b"previous-binary")
        self.assertFalse(self.config.exists())
        self.assertEqual(self.state.read_text(), '{"preserved":true}')

    @patch.object(installer, "service_control")
    def test_mac_preserves_arguments_and_credentials(self, control):
        original = dict(Label="com.komari.komari-agent", ProgramArguments=[str(self.binary), "--token", "dummy-secret", "--config", "/path with spaces/config.json"], EnvironmentVariables={"EXISTING":"yes"})
        self.config.write_bytes(plistlib.dumps(original))
        self.plan.update(kind="launchd", domain="gui/501")
        self.apply()
        changed = plistlib.loads(self.config.read_bytes())
        self.assertEqual(changed["ProgramArguments"], original["ProgramArguments"])
        self.assertEqual(changed["EnvironmentVariables"]["EXISTING"], "yes")
        self.assertEqual(changed["EnvironmentVariables"]["AGENT_NETWORK_MODE"], "lifetime")
        self.data.update(action="rollback")
        self.apply()
        self.assertEqual(plistlib.loads(self.config.read_bytes()), original)

    @patch.object(installer, "service_control")
    def test_actual_official_binary_removes_only_patch_settings(self, control):
        self.apply()
        self.data.update(official=True, original_sha256=installer.sha256(self.binary))
        self.apply()
        self.assertFalse(self.config.exists())

    @patch.object(installer, "service_control")
    def test_bad_digest_never_stops_service(self, control):
        self.data["sha256"] = "0" * 64
        with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
            self.apply()
        control.assert_not_called()
        self.assertEqual(self.binary.read_bytes(), b"previous-binary")

    def test_failed_restart_restores_original_files(self):
        self.config.write_text("original config")
        self.plan["active"] = True
        starts = 0
        def control(plan, action, check=True):
            nonlocal starts
            if action == "start":
                starts += 1
                if starts == 1:
                    raise RuntimeError("simulated restart failure")
        with patch.object(installer, "service_control", side_effect=control):
            with self.assertRaisesRegex(RuntimeError, "simulated"):
                self.apply()
        self.assertEqual(self.binary.read_bytes(), b"previous-binary")
        self.assertEqual(self.config.read_text(), "original config")
        self.assertEqual(starts, 2)

    def test_rejects_invalid_repository(self):
        with self.assertRaises(ValueError):
            installer.valid_repo("x/y?token=oops")


class OpenWrtTests(unittest.TestCase):
    setUp = InstallerTests.setUp
    apply = InstallerTests.apply
    def procd_fixture(self):
        self.plan.update(kind="procd", service="komari-agent")
        self.original = "#!/bin/sh /etc/rc.common\nUSE_PROCD=1\nPROG='/opt/komari/agent'\nARGS='--token dummy-secret'\nstart_service() {\n    procd_open_instance\n    procd_set_param command \"$PROG\"\n    procd_append_param command $ARGS\n    procd_close_instance\n}\n"
        self.config.write_text(self.original)
        self.config.chmod(0o755)
        self.data.update(sync_on_report=False,save_interval=300)

    @patch.object(installer,"service_control")
    def test_procd_patch_and_rollback_keep_args_and_executable_init(self,control):
        self.procd_fixture()
        self.apply()
        text=self.config.read_text()
        self.assertIn("ARGS='--token dummy-secret'",text)
        self.assertIn("AGENT_NETWORK_SYNC_ON_REPORT=false",text)
        self.assertIn("AGENT_NETWORK_SAVE_INTERVAL=300",text)
        self.assertEqual(text.count(installer.PROCD_BEGIN),1)
        self.data.update(original_sha256=installer.sha256(self.binary))
        self.apply()
        self.assertEqual(self.config.read_text().count(installer.PROCD_BEGIN),1)
        self.data.update(action="rollback")
        self.apply()
        self.assertTrue(self.config.stat().st_mode & 0o111)

    @patch.object(installer,"service_control")
    def test_procd_official_removes_patch_keeps_original_init(self,control):
        self.procd_fixture()
        self.apply()
        self.data.update(official=True,original_sha256=installer.sha256(self.binary))
        self.apply()
        self.assertEqual(self.config.read_text(),self.original)
        self.assertTrue(self.config.stat().st_mode & 0o111)

    def test_rejects_nonstandard_multiple_instances(self):
        with self.assertRaisesRegex(RuntimeError,"one standard"):
            installer.procd_script("procd_close_instance\nprocd_close_instance\n",{"AGENT_NETWORK_MODE":"lifetime"})

    def test_procd_settings_quote_paths_without_shell_injection(self):
        text=installer.procd_script("procd_close_instance\n",{"KEY":"/mnt/a b/'test'"})
        command=next(line for line in text.splitlines() if "procd_append_param" in line)
        self.assertEqual(installer.shlex.split(command)[2:],["KEY=/mnt/a b/'test'"])


class AuthenticationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.stage = pathlib.Path(self.temp.name)
        self.command = ["/usr/bin/python3", str(self.stage/"installer.py"), "--apply", str(self.stage/"manifest.json")]
        self.route = dict(kind="cinnamon",scope="session-c6.scope",env={},agent=None)

    def spawn(self, route, wrapper):
        if wrapper.name == "session-probe.sh":
            (self.stage/"session-scope").write_text("0::/user.slice/session-c6.scope")
        else:
            (self.stage/"authorization-result").write_text("0")

    def test_ssh_cinnamon_uses_gui_session_and_fixed_wrappers(self):
        with patch.dict(os.environ, {"SSH_CONNECTION":"remote connection"}), patch.object(installer.platform,"system",return_value="Linux"), patch.object(installer,"linux_desktop",return_value=self.route), patch.object(installer,"cinnamon_spawn",side_effect=self.spawn) as spawn, contextlib.redirect_stdout(io.StringIO()) as output:
            installer.authorize(self.command,self.stage,"auto")
        self.assertEqual(spawn.call_count,2)
        self.assertIn("PHYSICAL DESKTOP",output.getvalue())
        self.assertIn("--auth-worker",(self.stage/"authorize.sh").read_text())

    def test_wrong_graphical_scope_never_starts_authentication(self):
        def wrong_scope(route,wrapper):
            (self.stage/"session-scope").write_text("0::/wrong-session.scope")
        with patch.object(installer.platform,"system",return_value="Linux"), patch.object(installer,"linux_desktop",return_value=self.route), patch.object(installer,"cinnamon_spawn",side_effect=wrong_scope) as spawn:
            with self.assertRaisesRegex(RuntimeError,"expected graphical session"):
                installer.authorize(self.command,self.stage,"auto")
        self.assertEqual(spawn.call_count,1)
        self.assertFalse((self.stage/"authorize.sh").exists())

    def test_cancelled_authentication_never_retries(self):
        def cancelled(route,wrapper):
            self.spawn(route,wrapper)
            if wrapper.name == "authorize.sh":
                (self.stage/"authorization-result").write_text("126")
        with patch.object(installer.platform,"system",return_value="Linux"), patch.object(installer,"linux_desktop",return_value=self.route), patch.object(installer,"cinnamon_spawn",side_effect=cancelled) as spawn, patch.object(installer.subprocess,"run") as run, contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError,"cancelled"):
                installer.authorize(self.command,self.stage,"auto")
        self.assertEqual(spawn.call_count,2)
        run.assert_not_called()

    def test_headless_ssh_does_not_attempt_terminal_authentication(self):
        with patch.object(installer.platform,"system",return_value="Linux"), patch.object(installer,"linux_desktop",side_effect=RuntimeError("No desktop")), patch.object(installer.subprocess,"run") as run:
            with self.assertRaisesRegex(installer.DesktopUnavailable,"local desktop"):
                installer.authorize(self.command,self.stage,"auto")
        run.assert_not_called()

    def test_explicit_sudo_n_cannot_prompt_or_retry(self):
        result = subprocess_result(1)
        with patch.object(installer.subprocess,"run",return_value=result) as run:
            with self.assertRaisesRegex(RuntimeError,"noninteractive"):
                installer.authorize(self.command,self.stage,"sudo-n")
        run.assert_called_once_with(["sudo","-n","--"]+self.command)

    def test_mac_ssh_bootstraps_one_shot_gui_launchagent(self):
        with patch.object(installer.platform,"system",return_value="Darwin"), patch.object(installer,"mac_desktop",return_value=dict(kind="launchd-auth",domain="gui/501")), patch.object(installer,"run") as run, patch.object(installer,"wait_desktop_result",return_value="0"), contextlib.redirect_stdout(io.StringIO()):
            installer.authorize(self.command,self.stage,"desktop")
        plist=plistlib.loads((self.stage/"authorize.plist").read_bytes())
        self.assertIn("--auth-worker",plist["ProgramArguments"])
        self.assertNotIn("KeepAlive",plist)
        self.assertEqual(run.call_args_list[0].args[0][:3],["launchctl","bootstrap","gui/501"])
        self.assertEqual(run.call_args_list[1].args[0][:2],["launchctl","bootout"])

    def test_worker_reports_cancelled_exit_and_disables_text_agent(self):
        with patch.object(installer.platform,"system",return_value="Linux"), patch.object(installer.subprocess,"run",return_value=subprocess_result(126)) as run:
            installer.auth_worker(self.stage/"manifest.json")
        self.assertEqual((self.stage/"authorization-result").read_text(),"126")
        self.assertEqual(run.call_args.args[0][:2],["pkexec","--disable-internal-agent"])
        self.assertNotIn("input",run.call_args.kwargs)


def subprocess_result(code):
    from types import SimpleNamespace
    return SimpleNamespace(returncode=code)


if __name__ == "__main__":
    unittest.main()
