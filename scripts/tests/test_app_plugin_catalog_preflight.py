from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT_DIR / "scripts/plugins/preflight-app-plugin-catalog.swift"
SIGNED_CATALOG = ROOT_DIR / "docs/plugins/v4/catalog.json"


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "requires macOS and Xcode")
class AppPluginCatalogPreflightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary_directory = tempfile.TemporaryDirectory()
        cls.executable = Path(cls.temporary_directory.name) / "catalog-preflight"
        subprocess.run(
            ["xcrun", "swiftc", str(SCRIPT_PATH), "-o", str(cls.executable)],
            cwd=ROOT_DIR,
            check=True,
            text=True,
            capture_output=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary_directory.cleanup()

    def run_preflight(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.executable), *arguments],
            cwd=ROOT_DIR,
            check=False,
            text=True,
            capture_output=True,
        )

    def test_versions_before_1_2_do_not_require_the_new_catalog(self) -> None:
        result = self.run_preflight("--app-version", "1.1.6")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("not required", result.stdout)

    def test_matching_committed_and_deployed_signed_catalog_passes(self) -> None:
        result = self.run_preflight(
            "--app-version",
            "1.2.0",
            "--expected-catalog",
            str(SIGNED_CATALOG),
            "--deployed-catalog",
            str(SIGNED_CATALOG),
            "--catalog-url",
            "https://example.invalid/catalog.json",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verified signed PluginKit 4 catalog", result.stdout)

    def test_missing_catalog_fails_with_release_order_guidance(self) -> None:
        missing = Path(self.temporary_directory.name) / "missing.json"
        result = self.run_preflight(
            "--app-version",
            "1.2.0",
            "--expected-catalog",
            str(missing),
            "--deployed-catalog",
            str(missing),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Publish the plugin batch first", result.stderr)
        self.assertIn("Release order:", result.stderr)

    def test_invalid_signature_fails_closed(self) -> None:
        catalog = json.loads(SIGNED_CATALOG.read_text(encoding="utf-8"))
        catalog["generatedAt"] = "2099-01-01T00:00:00Z"
        tampered = Path(self.temporary_directory.name) / "tampered.json"
        tampered.write_text(json.dumps(catalog), encoding="utf-8")
        result = self.run_preflight(
            "--app-version",
            "1.2.0",
            "--expected-catalog",
            str(tampered),
            "--deployed-catalog",
            str(tampered),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signature does not match", result.stderr)


if __name__ == "__main__":
    unittest.main()
