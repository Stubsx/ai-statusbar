import importlib.util
import os
import pathlib
import tempfile
import unittest
from unittest import mock
import stat


ROOT = pathlib.Path(__file__).resolve().parents[1]
COLLECTOR = ROOT / "swiftbar-plugins" / "ai_status.py"


def load_collector():
    spec = importlib.util.spec_from_file_location("ai_status", COLLECTOR)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class CollectorTests(unittest.TestCase):
    def test_swiftbar_escapes_untrusted_titles(self):
        module = load_collector()
        data = {
            "tools": [{
                "letter": "T",
                "state": "busy",
                "busy_count": 1,
                "name": "测试",
                "detail": "1 个任务",
                "busy_items": [{"id": "1", "title": "正常| bash=危险\n下一行"}],
                "latest_title": None,
                "latest_age": None,
            }]
        }
        output = module.render_swiftbar(data)
        self.assertIn("正常¦ bash=危险 下一行 | size=11", output)
        self.assertNotIn("正常| bash=", output)

    def test_online_quota_defaults_off(self):
        source = COLLECTOR.read_text(encoding="utf-8")
        self.assertIn('bool(s.get("online_quota", False))', source)

    def test_supported_python_version_is_enforced(self):
        source = COLLECTOR.read_text(encoding="utf-8")
        self.assertIn("sys.version_info < (3, 8)", source)

    def test_privacy_sensitive_ui_defaults_are_off(self):
        source = (ROOT / "AIStatusBar" / "Sources" / "main.swift").read_text(encoding="utf-8")
        self.assertIn("@Published var notifyEnabled = false", source)
        self.assertIn('@AppStorage("panelAppearanceMode") private var appearanceMode = "system"', source)

    def test_fresh_install_does_not_make_quota_requests(self):
        with tempfile.TemporaryDirectory() as temp_home:
            settings_dir = pathlib.Path(temp_home) / ".ai-statusbar"
            settings_dir.mkdir()
            old_home = os.environ.get("HOME")
            os.environ["HOME"] = temp_home
            try:
                module = load_collector()
                with mock.patch.object(
                    module.urllib.request,
                    "urlopen",
                    side_effect=AssertionError("fresh install attempted a network request"),
                ), mock.patch.object(
                    module,
                    "_kimi_monthly_token_mtime",
                    side_effect=AssertionError("fresh install inspected the Kimi login token"),
                ):
                    quota = module.collect_quota()
            finally:
                if old_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = old_home
        self.assertIsNone(quota["kimi"])
        self.assertIsNone(quota["zcode"])

    def test_repository_has_no_personal_home_path(self):
        tracked_text = [
            ROOT / "AIStatusBar" / "Sources" / "main.swift",
            ROOT / "uebersicht-widgets" / "ai-status.widget" / "index.jsx",
            COLLECTOR,
        ]
        for path in tracked_text:
            text = path.read_text(encoding="utf-8")
            old_home = str(pathlib.Path("/").joinpath("Users", "jabber1")) + "/"
            old_project = str(pathlib.Path("/").joinpath("Desktop", "未命名文件夹")) + "/"
            self.assertNotIn(old_home, text, path)
            self.assertNotIn(old_project, text, path)

    def test_import_does_not_create_project_files(self):
        before = set(ROOT.rglob("quota-cache.json"))
        with tempfile.TemporaryDirectory() as temp_home:
            old_home = os.environ.get("HOME")
            os.environ["HOME"] = temp_home
            try:
                load_collector()
            finally:
                if old_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = old_home
        self.assertEqual(before, set(ROOT.rglob("quota-cache.json")))

    def test_private_cache_permissions(self):
        with tempfile.TemporaryDirectory() as temp_home:
            old_home = os.environ.get("HOME")
            os.environ["HOME"] = temp_home
            try:
                module = load_collector()
                module._write_private_json(module.QUOTA_CACHE, {"value": 1})
                directory_mode = stat.S_IMODE(os.stat(module.USAGE_DIR).st_mode)
                file_mode = stat.S_IMODE(os.stat(module.QUOTA_CACHE).st_mode)
            finally:
                if old_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = old_home
        self.assertEqual(directory_mode, 0o700)
        self.assertEqual(file_mode, 0o600)

    def test_expired_kimi_credentials_are_not_modified(self):
        with tempfile.TemporaryDirectory() as temp_home:
            settings_dir = pathlib.Path(temp_home) / ".ai-statusbar"
            settings_dir.mkdir()
            (settings_dir / "settings.json").write_text(
                '{"online_quota": true}', encoding="utf-8"
            )
            credential = pathlib.Path(temp_home) / ".kimi-code" / "credentials" / "kimi-code.json"
            credential.parent.mkdir(parents=True)
            original = '{"access_token":"example","refresh_token":"do-not-touch","expires_at":1}'
            credential.write_text(original, encoding="utf-8")
            old_home = os.environ.get("HOME")
            os.environ["HOME"] = temp_home
            try:
                module = load_collector()
                with mock.patch.object(
                    module.urllib.request,
                    "urlopen",
                    side_effect=AssertionError("expired credentials attempted a network request"),
                ):
                    self.assertIsNone(module._kimi_coding_quota())
            finally:
                if old_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = old_home
            self.assertEqual(credential.read_text(encoding="utf-8"), original)


if __name__ == "__main__":
    unittest.main()
