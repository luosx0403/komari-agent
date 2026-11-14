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


if __name__ == "__main__":
    unittest.main()
