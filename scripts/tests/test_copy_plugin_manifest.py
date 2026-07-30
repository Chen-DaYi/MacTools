import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/plugins/copy-plugin-manifest.py"
SYNC_SCRIPT = REPO_ROOT / "scripts/plugins/sync-debug-plugins.sh"
APP_VERSION_CONFIG = REPO_ROOT / "Configs/AppVersion.xcconfig"


class CopyPluginManifestTests(unittest.TestCase):
    def test_debug_copy_uses_local_host_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "plugin.json"
            destination = root / "copied.json"
            config = root / "AppVersion.xcconfig"
            source.write_text(
                json.dumps({"id": "example", "minHostVersion": "99.0"}),
                encoding="utf-8",
            )
            config.write_text("MARKETING_VERSION = 1.2.3\n", encoding="utf-8")

            subprocess.run(
                [
                    sys.executable, str(SCRIPT), "copy",
                    "--source", str(source),
                    "--destination", str(destination),
                    "--configuration", "Debug",
                    "--app-version-config", str(config),
                ],
                check=True,
            )

            self.assertEqual(
                json.loads(destination.read_text(encoding="utf-8"))["minHostVersion"],
                "1.2.3",
            )

    def test_release_copy_preserves_manifest_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "plugin.json"
            destination = root / "copied.json"
            config = root / "AppVersion.xcconfig"
            original = b'{ "id": "example", "minHostVersion": "2.0" }\n'
            source.write_bytes(original)
            config.write_text("MARKETING_VERSION = 1.2.3\n", encoding="utf-8")

            subprocess.run(
                [
                    sys.executable, str(SCRIPT), "copy",
                    "--source", str(source),
                    "--destination", str(destination),
                    "--configuration", "Release",
                    "--app-version-config", str(config),
                ],
                check=True,
            )

            self.assertEqual(destination.read_bytes(), original)

    def test_debug_sync_normalizes_and_caches_packaged_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Source"
            products = root / "Products"
            output = root / "Output"
            bundle = products / "Example.bundle"
            source.mkdir()
            bundle.mkdir(parents=True)
            (bundle / "payload").write_text("debug bundle", encoding="utf-8")
            (source / "plugin.json").write_text(
                json.dumps(
                    {
                        "id": "example-debug-plugin",
                        "displayName": "Example",
                        "version": "1.0.0",
                        "minHostVersion": "99.0.0",
                        "pluginKitVersion": 3,
                        "bundleRelativePath": "Example.bundle",
                    }
                ),
                encoding="utf-8",
            )

            command = [
                str(SYNC_SCRIPT),
                "--source-dir", str(source),
                "--products-dir", str(products),
                "--output-dir", str(output),
                "--skip-install",
            ]
            first_run = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
            )
            second_run = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
            )

            host_version = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "host-version",
                    "--app-version-config",
                    str(APP_VERSION_CONFIG),
                ],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            packaged_manifest = json.loads(
                (
                    output
                    / "Packages/example-debug-plugin.mactoolsplugin/plugin.json"
                ).read_text(encoding="utf-8")
            )
            catalog = json.loads(
                (output / "catalog.dev.json").read_text(encoding="utf-8")
            )

            self.assertIn("Synced 1 changed", first_run.stdout)
            self.assertIn("skipped 1 unchanged", second_run.stdout)
            self.assertEqual(packaged_manifest["minHostVersion"], host_version)
            self.assertEqual(
                catalog["plugins"][0]["minimumHostVersion"],
                host_version,
            )


if __name__ == "__main__":
    unittest.main()
