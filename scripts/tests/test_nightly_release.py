import importlib.util
import json
import pathlib
import plistlib
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts/nightly-release.py"
SPEC = importlib.util.spec_from_file_location("nightly_release", SCRIPT_PATH)
assert SPEC and SPEC.loader
nightly_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(nightly_release)


class NightlyReleaseTests(unittest.TestCase):
    def test_metadata_uses_run_attempt_for_monotonic_retries(self) -> None:
        metadata = nightly_release.make_metadata(
            config_path=REPO_ROOT / "Configs/AppVersion.xcconfig",
            plugins_dir=REPO_ROOT / "Plugins",
            repository="ggbond268/MacTools",
            source_sha="a" * 40,
            run_number="512",
            run_attempt="3",
        )

        self.assertEqual(metadata["BUILD_NUMBER"], "512.3")
        self.assertEqual(metadata["TAG"], "nightly-512-3")
        self.assertNotIn("PROJECT_NAME", metadata)
        self.assertEqual(metadata["PLUGIN_KIT_VERSION"], "5")
        self.assertEqual(
            metadata["NIGHTLY_PLUGIN_CATALOG_RELATIVE_PATH"],
            "docs/nightly/plugins/v5/catalog.json",
        )

    def test_release_warning_is_first(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = pathlib.Path(temporary_directory) / "notes.md"
            nightly_release.write_release_notes(
                output,
                "example/MacTools",
                "1.2.1",
                "512.1",
                "a" * 40,
            )
            notes = output.read_text(encoding="utf-8")

            self.assertTrue(notes.startswith("> [!WARNING]\n"))
            self.assertIn("MacTools Nightly is unstable", notes)
            self.assertIn("Signed assets for an existing Nightly tag are never replaced", notes)
            self.assertIn("github.com/example/MacTools/commit/", notes)

    def test_appcast_uses_dedicated_asset_and_numeric_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = pathlib.Path(temporary_directory) / "appcast.xml"
            nightly_release.write_appcast(
                output_path=output,
                repository="example/MacTools",
                tag="nightly-512-1",
                version="1.2.1",
                build_number="512.1",
                signature="signature",
                file_size=1234,
                publication_date="Tue, 25 Aug 2026 12:00:00 +0000",
                release_notes="> [!WARNING]\n> Unstable",
            )
            content = output.read_text(encoding="utf-8")

            self.assertIn("<sparkle:version>512.1</sparkle:version>", content)
            self.assertIn("nightly-512-1/MacTools-Nightly.dmg", content)
            self.assertNotIn("docs/appcast.xml", content)

            self.assertEqual(
                nightly_release.read_nightly_appcast_tag(output),
                "nightly-512-1",
            )

    def test_verify_app_accepts_fully_isolated_nightly_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = pathlib.Path(temporary_directory) / "MacTools Nightly.app"
            app_info_path = app / "Contents/Info.plist"
            extension_info_path = (
                app
                / "Contents/PlugIns/RightClickFinderSync.appex/Contents/Info.plist"
            )
            extension_info_path.parent.mkdir(parents=True)
            app_info = {
                "CFBundleDisplayName": "MacTools Nightly",
                "CFBundleIdentifier": "com.example.mactools.nightly",
                "CFBundleShortVersionString": "1.2.1",
                "CFBundleVersion": "512.1",
                "CFBundleURLTypes": [{"CFBundleURLSchemes": ["mactools-nightly"]}],
                "MTApplicationSupportDirectoryName": "MacTools Nightly",
                "MTReleaseChannel": "nightly",
                "MTPluginCatalogURL": "https://mactools.ggbond.app/nightly/plugins/v6/catalog.json",
                "MTRightClickConfigurationHomeRelativePath": "Library/Application Support/MacTools Nightly/right-click-menu.json",
                "SUFeedURL": "https://mactools.ggbond.app/nightly/appcast.xml",
            }
            extension_info = {
                "CFBundleDisplayName": "MacTools Nightly 右键工具",
                "CFBundleIdentifier": "com.example.mactools.nightly.right-click.finder-sync",
                "CFBundleShortVersionString": "1.2.1",
                "CFBundleVersion": "512.1",
                "MTRightClickHostURLScheme": "mactools-nightly",
                "MTRightClickToolbarItemName": "MacTools Nightly",
                "MTRightClickConfigurationHomeRelativePath": "Library/Application Support/MacTools Nightly/right-click-menu.json",
            }
            with app_info_path.open("wb") as file:
                plistlib.dump(app_info, file)
            with extension_info_path.open("wb") as file:
                plistlib.dump(extension_info, file)

            nightly_release.verify_nightly_app(
                app,
                "com.example",
                "1.2.1",
                "512.1",
                6,
            )

    def test_appcast_tag_rejects_malformed_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            appcast = pathlib.Path(temporary_directory) / "appcast.xml"
            appcast.write_text("<html>not an appcast", encoding="utf-8")

            with self.assertRaises(SystemExit):
                nightly_release.read_nightly_appcast_tag(appcast)

    def test_catalog_requires_all_plugins_and_build_specific_versions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            plugins = root / "Plugins"
            plugin = plugins / "Example"
            plugin.mkdir(parents=True)
            (plugin / "plugin.json").write_text(
                json.dumps(
                    {
                        "id": "example",
                        "version": "1.4.2",
                        "pluginKitVersion": 5,
                        "minHostVersion": "1.2.0",
                    }
                ),
                encoding="utf-8",
            )
            catalog_path = root / "catalog.json"
            catalog_path.write_text(
                json.dumps(
                    {
                        "signature": {"algorithm": "ed25519", "value": "signed"},
                        "plugins": [
                            {
                                "id": "example",
                                "version": "1.512.1",
                                "pluginKitVersion": 5,
                                "package": {
                                    "url": "https://github.com/example/MacTools/releases/download/nightly-512-1/example.mactoolsplugin.zip"
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            nightly_release.verify_nightly_catalog(
                catalog_path,
                plugins,
                "example/MacTools",
                "nightly-512-1",
                "512.1",
            )

    def test_retention_only_selects_old_matching_prereleases(self) -> None:
        releases = [
            {
                "tagName": f"nightly-{index}-1",
                "isPrerelease": True,
                "publishedAt": f"2026-08-{index:02d}T00:00:00Z",
            }
            for index in range(1, 5)
        ]
        releases.extend(
            [
                {
                    "tagName": "v1.2.0",
                    "isPrerelease": False,
                    "publishedAt": "2026-08-20T00:00:00Z",
                },
                {
                    "tagName": "beta-manual",
                    "isPrerelease": True,
                    "publishedAt": "2026-08-21T00:00:00Z",
                },
                {
                    "tagName": "nightly-99-1",
                    "isDraft": True,
                    "isPrerelease": True,
                    "publishedAt": None,
                },
            ]
        )

        self.assertEqual(
            nightly_release.stale_nightly_tags(releases, keep=2),
            ["nightly-2-1", "nightly-1-1"],
        )
        self.assertEqual(
            nightly_release.stale_nightly_tags(
                releases,
                keep=2,
                preserve_tags=["nightly-1-1"],
            ),
            ["nightly-2-1"],
        )

    def test_retention_never_deletes_the_advertised_tag(self) -> None:
        advertised_tag = "nightly-100-1"
        releases = [
            {
                "tagName": advertised_tag,
                "isPrerelease": True,
                "publishedAt": "2026-08-01T00:00:00Z",
            }
        ]
        releases.extend(
            {
                "tagName": f"nightly-{100 + index}-1",
                "isPrerelease": True,
                "publishedAt": f"2026-08-{index + 1:02d}T00:00:00Z",
            }
            for index in range(1, 15)
        )

        self.assertEqual(
            nightly_release.stale_nightly_tags(
                releases,
                keep=14,
                preserve_tags=[advertised_tag],
            ),
            [],
        )


if __name__ == "__main__":
    unittest.main()
