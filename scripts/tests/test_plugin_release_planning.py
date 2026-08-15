#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
RELEASE_SCRIPT_PATH = SCRIPTS_DIR / "release.py"
PLAN_SCRIPT_PATH = SCRIPTS_DIR / "plugins" / "plan-plugin-release.py"

RELEASE_SPEC = importlib.util.spec_from_file_location("mactools_release", RELEASE_SCRIPT_PATH)
assert RELEASE_SPEC is not None and RELEASE_SPEC.loader is not None
release = importlib.util.module_from_spec(RELEASE_SPEC)
sys.modules[RELEASE_SPEC.name] = release
RELEASE_SPEC.loader.exec_module(release)


class InteractiveReleasePlanningTests(unittest.TestCase):
    def test_plugin_kit4_release_uses_host_compatible_catalog_path(self) -> None:
        self.assertEqual(
            release.plugin_catalog_path(4),
            release.ROOT_DIR / "docs/plugins/v4/host-1.2/catalog.json",
        )

    def test_first_host_compatible_v4_release_uses_legacy_v4_baseline(self) -> None:
        with (
            mock.patch.object(release, "read_plugins", return_value={}),
            mock.patch.object(release, "current_plugin_kit_version", return_value=4),
        ):
            self.assertEqual(
                release.previous_plugin_catalog_path(),
                release.ROOT_DIR / "docs/plugins/v4/catalog.json",
            )

    def test_predeclared_app_version_is_the_default_release_target(self) -> None:
        with mock.patch.object(release, "choose_level") as choose_level:
            target, level, uses_declared_version = release.resolve_app_release_target(
                current_version="1.2.0",
                latest_tag="1.1.6",
                requested_version=None,
                requested_level=None,
            )

        self.assertEqual(target, "1.2.0")
        self.assertEqual(level, "minor")
        self.assertTrue(uses_declared_version)
        choose_level.assert_not_called()

    def test_requested_version_may_match_predeclared_version(self) -> None:
        target, level, uses_declared_version = release.resolve_app_release_target(
            current_version="1.2.0",
            latest_tag="1.1.6",
            requested_version="1.2.0",
            requested_level=None,
        )

        self.assertEqual(target, "1.2.0")
        self.assertEqual(level, "minor")
        self.assertFalse(uses_declared_version)

    def test_app_release_target_cannot_precede_declared_version(self) -> None:
        with self.assertRaisesRegex(
            release.ReleaseError,
            "不能低于 AppVersion.xcconfig 已声明的版本",
        ):
            release.resolve_app_release_target(
                current_version="1.2.0",
                latest_tag="1.1.6",
                requested_version="1.1.7",
                requested_level=None,
            )

    def test_app_release_target_must_exceed_latest_tag(self) -> None:
        with self.assertRaisesRegex(release.ReleaseError, "必须高于最新 app tag"):
            release.resolve_app_release_target(
                current_version="1.1.6",
                latest_tag="1.1.6",
                requested_version="1.1.6",
                requested_level=None,
            )

    def test_explicit_major_release_can_advance_past_declared_version(self) -> None:
        target, level, uses_declared_version = release.resolve_app_release_target(
            current_version="1.2.0",
            latest_tag="1.1.6",
            requested_version=None,
            requested_level="major",
        )

        self.assertEqual(target, "2.0.0")
        self.assertEqual(level, "major")
        self.assertFalse(uses_declared_version)

    def test_release_preflight_skips_confirmation_without_plugin_kit_changes(self) -> None:
        with (
            mock.patch.object(release, "latest_tag_version", return_value="1.1.3"),
            mock.patch.object(release, "changed_paths_since", return_value=[]),
            mock.patch.object(release, "confirm") as confirm,
        ):
            release.confirm_plugin_kit_changes_before_release()

        confirm.assert_not_called()

    def test_release_preflight_confirms_plugin_kit_changes(self) -> None:
        changed_paths = [
            "Sources/MacToolsPluginKit/PluginModels.swift",
            "Sources/MacToolsPluginKit/PluginInterfaces.swift",
        ]

        with (
            mock.patch.object(release, "latest_tag_version", return_value="1.1.3"),
            mock.patch.object(release, "changed_paths_since", return_value=changed_paths),
            mock.patch.object(release, "confirm") as confirm,
            mock.patch("builtins.print"),
        ):
            release.confirm_plugin_kit_changes_before_release()

        confirm.assert_called_once_with(
            "确认已检查这些 PluginKit 改动是否需要提升 pluginKitVersion，并继续发布？",
            False,
            noninteractive_error=(
                "检测到 PluginKit 代码变化，非交互发布无法完成兼容性确认。"
                "请在交互终端运行 `make release`，检查 pluginKitVersion 后确认。"
            ),
        )

    def test_plugin_kit_changes_are_package_relevant_for_every_plugin(self) -> None:
        plugin = release.PluginInfo(
            id="demo",
            directory_name="Demo",
            display_name="Demo",
            path=release.PLUGIN_SOURCE_DIR / "Demo",
            manifest_path=release.PLUGIN_SOURCE_DIR / "Demo" / "plugin.json",
            version="1.0.0",
            plugin_kit_version=3,
        )

        def changed_paths(_ref: str, path: Path) -> list[str]:
            if path == release.PLUGIN_SHARED_PATHS[0]:
                return ["Sources/MacToolsPluginKit/PluginModels.swift"]
            return []

        with mock.patch.object(release, "changed_paths_since", side_effect=changed_paths):
            changes = release.plugin_package_relevant_changes_since("plugins-1.0.0", plugin)

        self.assertEqual(changes, ["Sources/MacToolsPluginKit/PluginModels.swift"])

    def test_app_release_preflight_invokes_catalog_verifier_for_target_version(self) -> None:
        with mock.patch.object(release, "run") as run:
            release.preflight_app_plugin_catalog("1.2.0")

        run.assert_called_once_with(
            [
                "xcrun",
                "swift",
                "scripts/plugins/preflight-app-plugin-catalog.swift",
                "--app-version",
                "1.2.0",
            ]
        )


class WorkflowReleasePlanningTests(unittest.TestCase):
    def test_default_plan_rejects_unbumped_plugin_after_plugin_kit_change(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            plugin_directory = root / "Plugins" / "Demo"
            plugin_kit_directory = root / "Sources" / "MacToolsPluginKit"
            plugin_directory.mkdir(parents=True)
            plugin_kit_directory.mkdir(parents=True)

            manifest = {
                "id": "demo",
                "displayName": "Demo",
                "version": "1.0.0",
                "pluginKitVersion": 3,
            }
            (plugin_directory / "plugin.json").write_text(
                json.dumps(manifest),
                encoding="utf-8",
            )
            shared_source = plugin_kit_directory / "PluginModels.swift"
            shared_source.write_text("public struct PluginConfiguration {}\n", encoding="utf-8")

            previous_catalog = root / "catalog.json"
            previous_catalog.write_text(
                json.dumps(
                    {
                        "pluginKitVersion": 3,
                        "plugins": [
                            {
                                "id": "demo",
                                "version": "1.0.0",
                                "pluginKitVersion": 3,
                                "package": {
                                    "url": (
                                        "https://example.invalid/releases/download/"
                                        "plugins-1.0.0/demo.zip"
                                    )
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
            subprocess.run(
                ["git", "config", "user.email", "test@example.invalid"],
                cwd=root,
                check=True,
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "baseline"], cwd=root, check=True)
            subprocess.run(["git", "tag", "plugins-1.0.0"], cwd=root, check=True)

            shared_source.write_text(
                "public struct PluginConfiguration { public let value: Int }\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "change plugin kit"], cwd=root, check=True)

            result = subprocess.run(
                [
                    sys.executable,
                    str(PLAN_SCRIPT_PATH),
                    "--mode",
                    "auto",
                    "--source-dir",
                    "Plugins",
                    "--previous-catalog",
                    str(previous_catalog),
                    "--shared-path",
                    "Sources/OtherShared",
                    "--output",
                    str(root / "plan.json"),
                ],
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Sources/MacToolsPluginKit/PluginModels.swift", result.stderr)
            self.assertIn("version is still 1.0.0", result.stderr)

    def test_selected_plan_cannot_bypass_shared_plugin_kit_rebuild(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            plugin_kit_directory = root / "Sources" / "MacToolsPluginKit"
            plugin_kit_directory.mkdir(parents=True)
            previous_plugins = []
            for directory, plugin_id, version in (
                ("Demo", "demo", "1.0.1"),
                ("Other", "other", "1.0.0"),
            ):
                plugin_directory = root / "Plugins" / directory
                plugin_directory.mkdir(parents=True)
                (plugin_directory / "plugin.json").write_text(
                    json.dumps(
                        {
                            "id": plugin_id,
                            "displayName": directory,
                            "version": version,
                            "pluginKitVersion": 3,
                        }
                    ),
                    encoding="utf-8",
                )
                previous_plugins.append(
                    {
                        "id": plugin_id,
                        "version": "1.0.0",
                        "pluginKitVersion": 3,
                        "package": {
                            "url": (
                                "https://example.invalid/releases/download/"
                                f"plugins-1.0.0/{plugin_id}.zip"
                            )
                        },
                    }
                )
            shared_source = plugin_kit_directory / "PluginModels.swift"
            shared_source.write_text("public struct Model {}\n", encoding="utf-8")
            previous_catalog = root / "catalog.json"
            previous_catalog.write_text(
                json.dumps({"pluginKitVersion": 3, "plugins": previous_plugins}),
                encoding="utf-8",
            )

            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
            subprocess.run(
                ["git", "config", "user.email", "test@example.invalid"],
                cwd=root,
                check=True,
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "baseline"], cwd=root, check=True)
            subprocess.run(["git", "tag", "plugins-1.0.0"], cwd=root, check=True)
            shared_source.write_text(
                "public struct Model { public let value: Int }\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "shared change"], cwd=root, check=True)

            result = subprocess.run(
                [
                    sys.executable,
                    str(PLAN_SCRIPT_PATH),
                    "--mode", "selected",
                    "--plugins", "demo",
                    "--source-dir", "Plugins",
                    "--previous-catalog", str(previous_catalog),
                    "--output", str(root / "plan.json"),
                ],
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Use --mode all", result.stderr)
            self.assertIn("Sources/MacToolsPluginKit/PluginModels.swift", result.stderr)


if __name__ == "__main__":
    unittest.main()
