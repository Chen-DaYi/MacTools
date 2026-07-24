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


if __name__ == "__main__":
    unittest.main()
