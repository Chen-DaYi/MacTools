#!/usr/bin/env python3
from __future__ import annotations

import json
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGINS_ROOT = REPO_ROOT / "Plugins"
LEGACY_V4_CATALOG = REPO_ROOT / "docs/plugins/v4/catalog.json"
PLUGIN_RELEASE_WORKFLOW = REPO_ROOT / ".github/workflows/plugin-release.yml"
NEW_API_MINIMUM_HOSTS = {
    "PluginCallbackContext": "1.2.0",
    "PluginPresentationSafety": "1.2.0",
    "PluginSystemImage": "1.2.0",
}


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(component) for component in value.split("."))


class PluginMinimumHostCompatibilityTests(unittest.TestCase):
    def test_legacy_v4_catalog_remains_compatible_with_shipped_1_1_6_verifier(self) -> None:
        catalog = json.loads(LEGACY_V4_CATALOG.read_text(encoding="utf-8"))
        self.assertEqual(catalog["minimumHostVersion"], "1.1.6")
        incompatible = [
            entry["id"]
            for entry in catalog["plugins"]
            if version_tuple(entry["minimumHostVersion"]) > version_tuple("1.1.6")
        ]
        self.assertEqual(incompatible, [])

    def test_plugin_kit4_release_targets_host_compatible_catalog(self) -> None:
        workflow = PLUGIN_RELEASE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            'PLUGIN_CATALOG_RELATIVE_PATH="docs/plugins/v4/host-1.2/catalog.json"',
            workflow,
        )
        self.assertIn('PLUGIN_CATALOG_MINIMUM_HOST_VERSION="1.2.0"', workflow)

    def test_new_plugin_kit_api_consumers_require_compatible_host(self) -> None:
        violations: list[str] = []
        for manifest_path in sorted(PLUGINS_ROOT.glob("*/plugin.json")):
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            source = "\n".join(
                path.read_text(encoding="utf-8")
                for path in sorted((manifest_path.parent / "Sources").rglob("*.swift"))
            )
            declared = manifest.get("minHostVersion", "0")
            for symbol, required in NEW_API_MINIMUM_HOSTS.items():
                if symbol in source and version_tuple(declared) < version_tuple(required):
                    violations.append(
                        f"{manifest['id']} uses {symbol} but declares "
                        f"minHostVersion {declared} (< {required})"
                    )

        self.assertEqual(violations, [], "\n".join(violations))


if __name__ == "__main__":
    unittest.main()
