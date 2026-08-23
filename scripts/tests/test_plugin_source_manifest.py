from __future__ import annotations

import base64
import copy
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PLUGINS_ROOT = REPO_ROOT / "Plugins"
SCRIPTS_ROOT = REPO_ROOT / "scripts" / "plugins"
sys.path.insert(0, str(SCRIPTS_ROOT))

from plugin_source_manifest import (  # noqa: E402
    ManifestValidationError,
    SUPPORTED_LOCALES,
    load_known_plugin_ids,
    validate_and_project_manifest,
)


class PluginSourceManifestTests(unittest.TestCase):
    def test_every_repository_manifest_passes_semantic_validation(self) -> None:
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)
        for path in sorted(PLUGINS_ROOT.glob("*/plugin.json")):
            with self.subTest(plugin=path.parent.name):
                validate_and_project_manifest(
                    json.loads(path.read_text(encoding="utf-8")),
                    path,
                    known_ids,
                )

    def test_all_repository_manifests_publish_complete_product_metadata(self) -> None:
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)
        required_sections = {
            "presentation", "discovery", "requirements", "privacy", "setup", "relationships"
        }
        for path in sorted(PLUGINS_ROOT.glob("*/plugin.json")):
            manifest = json.loads(path.read_text(encoding="utf-8"))
            with self.subTest(plugin=manifest["id"]):
                self.assertTrue(required_sections.issubset(manifest))
                self.assertEqual(set(manifest["localizedMetadata"]), SUPPORTED_LOCALES)
                projected, _ = validate_and_project_manifest(manifest, path, known_ids)
                self.assertEqual(
                    set(projected["presentation"]["longDescription"]),
                    SUPPORTED_LOCALES,
                )

    def test_source_localization_references_expand_before_projection(self) -> None:
        path = PLUGINS_ROOT / "ActivityBar" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))

        self.assertEqual(manifest["presentation"]["longDescription"], "@summary")
        projected, _ = validate_and_project_manifest(
            manifest,
            path,
            load_known_plugin_ids(PLUGINS_ROOT),
        )

        self.assertEqual(
            projected["presentation"]["longDescription"]["en"],
            manifest["localizedMetadata"]["en"]["summary"],
        )

    def test_sparse_legacy_manifest_remains_valid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = pathlib.Path(temporary_directory) / "plugin.json"
            manifest = {
                "id": "legacy-demo",
                "displayName": "Legacy",
                "version": "1.0.0",
                "minHostVersion": "1.0.0",
                "pluginKitVersion": 4,
                "bundleRelativePath": "Legacy.bundle",
            }
            path.write_text(json.dumps(manifest), encoding="utf-8")

            projected, assets = validate_and_project_manifest(manifest, path, {"legacy-demo"})

            self.assertNotIn("presentation", projected)
            self.assertEqual(assets, [])

    def test_duplicate_plugin_ids_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            for name in ("First", "Second"):
                directory = root / name
                directory.mkdir()
                directory.joinpath("plugin.json").write_text(
                    json.dumps({"id": "duplicate"}),
                    encoding="utf-8",
                )

            with self.assertRaisesRegex(ManifestValidationError, "duplicates another plugin"):
                load_known_plugin_ids(root)

    def test_rejects_missing_localization_invalid_domain_and_duplicate_action(self) -> None:
        path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)

        missing_locale = copy.deepcopy(manifest)
        missing_locale["presentation"]["longDescription"].pop("fr")
        with self.assertRaisesRegex(ManifestValidationError, "missing locale fallback"):
            validate_and_project_manifest(missing_locale, path, known_ids)

        invalid_domain = copy.deepcopy(manifest)
        invalid_domain["privacy"]["networkUse"] = "required"
        invalid_domain["privacy"]["networkDomains"] = ["https://example.com/path"]
        with self.assertRaisesRegex(ManifestValidationError, "invalid domain"):
            validate_and_project_manifest(invalid_domain, path, known_ids)

        duplicate_action = copy.deepcopy(manifest)
        duplicate_action["actions"]["providers"][0]["staticActions"].append(
            copy.deepcopy(duplicate_action["actions"]["providers"][0]["staticActions"][0])
        )
        with self.assertRaisesRegex(ManifestValidationError, "duplicates a static action key"):
            validate_and_project_manifest(duplicate_action, path, known_ids)

    def test_static_dynamic_and_mixed_provider_shapes_validate(self) -> None:
        appearance_path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        app_volume_path = PLUGINS_ROOT / "AppVolume" / "plugin.json"
        appearance = json.loads(appearance_path.read_text(encoding="utf-8"))
        app_volume = json.loads(app_volume_path.read_text(encoding="utf-8"))
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)

        validate_and_project_manifest(appearance, appearance_path, known_ids)
        validate_and_project_manifest(app_volume, app_volume_path, known_ids)

        mixed = copy.deepcopy(appearance)
        provider = mixed["actions"]["providers"][0]
        provider["kind"] = "mixed"
        template = copy.deepcopy(
            app_volume["actions"]["providers"][0]["dynamicTemplates"][0]
        )
        template["id"] = "set-device-value"
        provider["dynamicTemplates"] = [template]

        validate_and_project_manifest(mixed, appearance_path, known_ids)

    def test_rejects_invalid_action_permission_relationship_asset_and_test_action(self) -> None:
        path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)

        cases = []
        invalid_key = copy.deepcopy(manifest)
        invalid_key["actions"]["providers"][0]["staticActions"][0]["id"] = "bad/action"
        cases.append((invalid_key, "stable identifier"))

        invalid_permission = copy.deepcopy(manifest)
        invalid_permission["actions"]["providers"][0]["staticActions"][0]["permissionIDs"] = ["root-access"]
        cases.append((invalid_permission, "unknown: root-access"))

        invalid_relationship = copy.deepcopy(manifest)
        invalid_relationship["relationships"]["relatedPluginIDs"] = ["missing-plugin"]
        cases.append((invalid_relationship, "references unknown plugins"))

        invalid_asset = copy.deepcopy(manifest)
        invalid_asset["presentation"]["screenshots"] = [{
            "id": "missing",
            "path": "MarketplaceAssets/missing.png",
            "alt": invalid_asset["presentation"]["longDescription"],
        }]
        cases.append((invalid_asset, "asset does not exist"))

        invalid_test_action = copy.deepcopy(manifest)
        invalid_test_action["setup"]["suggestedTestAction"]["actionID"] = "missing"
        cases.append((invalid_test_action, "must reference a declared static action"))

        for value, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ManifestValidationError, message):
                    validate_and_project_manifest(value, path, known_ids)

    def test_unknown_optional_field_is_preserved_and_dynamic_templates_must_be_complete(self) -> None:
        path = PLUGINS_ROOT / "AppVolume" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)
        manifest["futureProductField"] = {"enabled": True}

        projected, _ = validate_and_project_manifest(manifest, path, known_ids)

        self.assertEqual(projected["futureProductField"], {"enabled": True})

        incomplete = copy.deepcopy(manifest)
        del incomplete["actions"]["providers"][0]["dynamicTemplates"][0]["parameterSummary"]
        with self.assertRaisesRegex(ManifestValidationError, "missing parameterSummary"):
            validate_and_project_manifest(incomplete, path, known_ids)

    def test_asset_projection_hashes_and_validates_png(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            asset = root / "MarketplaceAssets" / "preview.png"
            asset.parent.mkdir()
            asset.write_bytes(base64.b64decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZlS8AAAAASUVORK5CYII="
            ))
            localized = {locale: "Preview" for locale in SUPPORTED_LOCALES}
            manifest = {
                "id": "asset-demo",
                "category": "other",
                "presentation": {
                    "longDescription": localized,
                    "examples": [],
                    "screenshots": [{
                        "id": "main", "path": "MarketplaceAssets/preview.png", "alt": localized,
                    }],
                    "publisher": "Example",
                    "license": "Apache-2.0",
                },
            }
            path = root / "plugin.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")

            projected, assets = validate_and_project_manifest(manifest, path, {"asset-demo"})

            screenshot = projected["presentation"]["screenshots"][0]
            self.assertEqual(screenshot["mediaType"], "image/png")
            self.assertEqual(screenshot["width"], 1)
            self.assertEqual(screenshot["height"], 1)
            self.assertEqual(len(screenshot["sha256"]), 64)
            self.assertEqual(len(assets), 1)

    def test_catalog_and_website_generation_are_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            package = root / "appearance.mactoolsplugin"
            package.mkdir()
            source = PLUGINS_ROOT / "Appearance" / "plugin.json"
            package.joinpath("plugin.json").write_bytes(source.read_bytes())
            package.joinpath("Appearance.bundle").mkdir()
            package.joinpath("Appearance.bundle", "payload").write_text("fixture", encoding="utf-8")
            first_catalog = root / "first.json"
            second_catalog = root / "second.json"
            first_website = root / "first-website" / "plugins.json"
            second_website = root / "second-website" / "plugins.json"
            base_command = [
                sys.executable,
                str(SCRIPTS_ROOT / "generate-plugin-catalog.py"),
                "--mode", "debug",
                "--package", str(package),
                "--plugins-root", str(PLUGINS_ROOT),
                "--generated-at", "2026-08-23T00:00:00Z",
            ]
            subprocess.run(
                base_command + ["--output", str(first_catalog), "--website-output", str(first_website)],
                check=True,
            )
            subprocess.run(
                base_command + ["--output", str(second_catalog), "--website-output", str(second_website)],
                check=True,
            )

            self.assertEqual(first_catalog.read_bytes(), second_catalog.read_bytes())
            self.assertEqual(first_website.read_bytes(), second_website.read_bytes())
            self.assertNotIn("@summary", first_catalog.read_text(encoding="utf-8"))
            self.assertNotIn("@displayName", first_catalog.read_text(encoding="utf-8"))
            catalog = json.loads(first_catalog.read_text(encoding="utf-8"))
            self.assertEqual(catalog["schemaVersion"], 3)
            entry = catalog["plugins"][0]
            self.assertIn("actions", entry)
            self.assertNotIn("build", entry)
            website = json.loads(first_website.read_text(encoding="utf-8"))
            self.assertNotIn("package", website["plugins"][0])

    def test_dynamic_catalog_template_never_contains_machine_local_entries(self) -> None:
        manifest = json.loads(
            (PLUGINS_ROOT / "AppVolume" / "plugin.json").read_text(encoding="utf-8")
        )
        provider = manifest["actions"]["providers"][0]

        self.assertEqual(provider["kind"], "dynamic")
        self.assertEqual(provider["staticActions"], [])
        self.assertEqual(provider["dynamicTemplates"][0]["entrySource"], "active-audio-applications")
        self.assertNotIn("entries", provider)


if __name__ == "__main__":
    unittest.main()
