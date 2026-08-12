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
    # Canonical action registry, execution, discovery, and surface bridges.
    "ActionKey": "1.2.0",
    "ActionParameterSet": "1.2.0",
    "ActionParameterDefinition": "1.2.0",
    "ActionDefinition": "1.2.0",
    "ActionReference": "1.2.0",
    "ActionCatalogEntry": "1.2.0",
    "ActionAvailability": "1.2.0",
    "ActionInvocation": "1.2.0",
    "ActionExecutionHandle": "1.2.0",
    "PluginActionProviding": "1.2.0",
    "PluginActionExecutionRevisionProviding": "1.2.0",
    "PluginActionExposureProviding": "1.2.0",
    "PluginActionPermissionProviding": "1.2.0",
    "LegacyActionShortcutAssignment": "1.2.0",
    "PluginLegacyActionShortcutProviding": "1.2.0",
    "ActionSurfaceCatalogItem": "1.2.0",
    "ActionGridPresentationEntry": "1.2.0",
    "ActionGridHostContext": "1.2.0",
    "ActionGridHostContextConsuming": "1.2.0",
    "TrackpadActionHostContext": "1.2.0",
    "TrackpadActionHostContextConsuming": "1.2.0",
    "ActionSurfaceAssignmentSummary": "1.2.0",
    "ActionSurfaceAssignmentSummarizing": "1.2.0",
    # Portable preferences and input ownership added with the shared surfaces.
    "PluginPortablePreferencesRestorationReporting": "1.2.0",
    "PluginPortablePreferencesActionReferencesProviding": "1.2.0",
    "PluginActionReferenceBackupDisposition": "1.2.0",
    "PluginActionReferenceBackupProviding": "1.2.0",
    "PluginInputGestureClaim": "1.2.0",
    "PluginInputGestureConflict": "1.2.0",
    "PluginInputGestureClaimProviding": "1.2.0",
    "PluginInputGestureConflictConsuming": "1.2.0",
    # Shared lifecycle and presentation helpers introduced in host 1.2.
    "PluginCallbackContext": "1.2.0",
    "PluginPresentationSafety": "1.2.0",
    "PluginProcessGroupLease": "1.2.0",
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

    def test_new_api_inventory_covers_every_1_2_plugin_kit_type_used_by_plugins(self) -> None:
        required_symbols = {
            "PluginActionProviding",
            "ActionGridHostContextConsuming",
            "TrackpadActionHostContextConsuming",
            "PluginPortablePreferencesRestorationReporting",
            "PluginInputGestureClaimProviding",
            "PluginPresentationSafety",
            "PluginCallbackContext",
            "PluginProcessGroupLease",
            "PluginSystemImage",
        }
        self.assertTrue(required_symbols <= NEW_API_MINIMUM_HOSTS.keys())


if __name__ == "__main__":
    unittest.main()
