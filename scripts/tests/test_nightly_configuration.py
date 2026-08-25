import pathlib
import plistlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class NightlyConfigurationTests(unittest.TestCase):
    def test_project_declares_isolated_release_optimized_nightly_configuration(self) -> None:
        project = (REPO_ROOT / "project.yml").read_text(encoding="utf-8")

        self.assertIn("Nightly: release", project)
        self.assertIn('PRODUCT_NAME: "MacTools Nightly"', project)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: "$(BUNDLE_IDENTIFIER_PREFIX).mactools.nightly"', project)
        self.assertIn("MACTOOLS_URL_SCHEME: mactools-nightly", project)
        self.assertIn('APPLICATION_SUPPORT_DIRECTORY_NAME: "MacTools Nightly"', project)
        self.assertIn("https://mactools.ggbond.app/nightly/appcast.xml", project)
        self.assertNotIn("https://mactools.ggbond.app/nightly/plugins/v5/catalog.json", project)
        self.assertNotIn(
            "MACTOOLS_RELEASE_CHANNEL: stable\n        PLUGIN_CATALOG_URL:",
            project,
        )
        self.assertIn("RIGHT_CLICK_EXTENSION_DISPLAY_NAME: MacTools Nightly 右键工具", project)
        self.assertIn("RIGHT_CLICK_TOOLBAR_ITEM_NAME: MacTools Nightly", project)

    def test_finder_sync_nightly_entitlement_isolated_from_stable_and_debug(self) -> None:
        entitlement_path = (
            REPO_ROOT
            / "Sources/Extensions/RightClickFinderSync/RightClickFinderSync-Nightly.entitlements"
        )
        with entitlement_path.open("rb") as file:
            entitlements = plistlib.load(file)

        paths = entitlements[
            "com.apple.security.temporary-exception.files.home-relative-path.read-only"
        ]
        self.assertEqual(
            paths,
            ["/Library/Application Support/MacTools Nightly/right-click-menu.json"],
        )

    def test_generated_plugin_targets_map_nightly_to_release_settings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = pathlib.Path(temporary_directory) / "GeneratedPlugins.yml"
            subprocess.run(
                [
                    str(REPO_ROOT / "scripts/plugins/generate-plugin-project-config.rb"),
                    "--source-dir", str(REPO_ROOT / "Plugins"),
                    "--output", str(output),
                ],
                check=True,
            )
            generated = output.read_text(encoding="utf-8")

        self.assertIn("Nightly: Release.xcconfig", generated)
        self.assertIn(
            "$(BUILT_PRODUCTS_DIR)/MacTools Nightly.app/Contents/MacOS/MacTools Nightly",
            generated,
        )

    def test_pull_request_ci_builds_and_verifies_nightly(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")

        self.assertIn("Build and verify unsigned Nightly configuration", workflow)
        self.assertIn("-configuration Nightly", workflow)
        self.assertIn("scripts/nightly-release.py verify-app", workflow)
        self.assertIn("scripts/nightly-release.py plugin-kit-version", workflow)
        self.assertIn('--plugin-kit-version "$PLUGIN_KIT_VERSION"', workflow)
        self.assertIn(
            'PLUGIN_CATALOG_URL="https://mactools.ggbond.app/nightly/plugins/v${PLUGIN_KIT_VERSION}/catalog.json"',
            workflow,
        )

    def test_nightly_workflow_is_gated_manual_and_fail_closed(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")

        self.assertIn("github.event_name == 'workflow_dispatch'", workflow)
        self.assertIn("vars.ENABLE_NIGHTLY_RELEASES == 'true'", workflow)
        self.assertIn('git merge-base --is-ancestor "$SOURCE_SHA" origin/main', workflow)
        self.assertIn("refusing to expose release credentials", workflow)
        self.assertIn("--draft", workflow)
        self.assertIn("--latest=false", workflow)
        self.assertNotIn("--clobber", workflow)
        self.assertLess(
            workflow.index("gh release edit"),
            workflow.index("Publish dedicated Nightly catalog and appcast last"),
        )
        self.assertIn("docs/appcast.xml", workflow)
        self.assertIn("git diff --exit-code", workflow)
        self.assertIn("NIGHTLY_PLUGIN_CATALOG_RELATIVE_PATH", workflow)
        self.assertIn("NIGHTLY_APPCAST_RELATIVE_PATH", workflow)
        self.assertIn("unexpected publication state", workflow)
        self.assertIn("unexpectedly replaced the stable Latest release", workflow)
        self.assertIn("preflight-app-plugin-catalog.swift", workflow)
        self.assertIn('--deployed-catalog "$SIGNED_PLUGIN_CATALOG_PATH"', workflow)
        self.assertIn(
            '(cd "$DMG_DIRECTORY" && shasum -a 256 "$DMG_NAME")',
            workflow,
        )
        self.assertIn("gh api --paginate --slurp", workflow)
        self.assertNotIn("--slurp \\\n            --jq", workflow)
        self.assertIn("jq 'flatten | map(", workflow)
        self.assertIn('--preserve-tag "$COMMITTED_TAG"', workflow)
        self.assertIn('--preserve-tag "$DEPLOYED_TAG"', workflow)
        self.assertIn('&& DEPLOYED_TAG="$(scripts/nightly-release.py appcast-tag', workflow)

    def test_nightly_reuses_existing_release_credentials(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")

        for secret in [
            "DEVELOPER_ID_CERT_P12",
            "ASC_API_KEY_P8_BASE64",
            "SPARKLE_PRIVATE_KEY",
            "PLUGIN_CATALOG_PRIVATE_KEY_BASE64",
        ]:
            self.assertIn(f"secrets.{secret}", workflow)
        self.assertNotIn("NIGHTLY_SPARKLE_PRIVATE_KEY", workflow)

    def test_pages_deploy_waits_for_successful_nightly_workflow(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/pages.yml").read_text(encoding="utf-8")

        self.assertIn('- "docs/nightly/**"', workflow)
        self.assertIn("- Nightly", workflow)
        self.assertIn("github.event.workflow_run.conclusion == 'success'", workflow)


if __name__ == "__main__":
    unittest.main()
