import json
import os
import pathlib
import subprocess
import tempfile
import unittest
import uuid


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE_TOOL = REPO_ROOT / "scripts" / "e2e" / "MacToolsE2EFixture.swift"
E2E_SCRIPT = REPO_ROOT / "scripts" / "e2e" / "mactools-e2e.sh"
KEY_SENDER_TOOL = REPO_ROOT / "scripts" / "e2e" / "MacToolsE2EKeySender.swift"
CAPTURE_RECT_TOOL = REPO_ROOT / "scripts" / "e2e" / "MacToolsE2ECaptureRect.swift"
SCENARIO_MANIFEST = REPO_ROOT / "scripts" / "e2e" / "scenarios.json"


class MacToolsE2ETests(unittest.TestCase):
    def setUp(self):
        self.bundle_id = f"com.jennymedia.mactools.e2e-test.{uuid.uuid4()}"

    def tearDown(self):
        self.run_fixture("clear-test-domain", check=False)

    def run_fixture(self, command, *, check=True, extra_arguments=()):
        environment = os.environ.copy()
        result = subprocess.run(
            [
                "xcrun",
                "swift",
                str(FIXTURE_TOOL),
                command,
                "--bundle-id",
                self.bundle_id,
                *extra_arguments,
            ],
            cwd=REPO_ROOT,
            env=environment,
            check=check,
            capture_output=True,
            text=True,
        )
        return result

    def test_fixture_seed_is_valid_and_idempotent(self):
        first = json.loads(self.run_fixture("seed").stdout)
        second = json.loads(self.run_fixture("seed").stdout)
        audited = json.loads(self.run_fixture("audit").stdout)

        for report in (first, second, audited):
            self.assertTrue(report["valid"])
            self.assertTrue(report["hasOpenSettingsShortcut"])
            self.assertTrue(report["hasActionGridShortcut"])
            self.assertTrue(report["hasDashboardShortcut"])
            self.assertTrue(report["hasWorkflowShortcut"])
            self.assertEqual(report["workflowName"], "E2E Safe Workflow")
            self.assertEqual(report["workflowStepCount"], 3)
            self.assertEqual(report["workflowCount"], 5)
            self.assertEqual(
                report["workflowNames"],
                [
                    "E2E Safe Workflow",
                    "E2E Background Workflow",
                    "E2E Continue After Missing Action",
                    "E2E Stop On Missing Action",
                    "E2E Cancellable Delay",
                ],
            )
            self.assertFalse(report["hasDisplaySleepWorkflowStep"])
            self.assertEqual(
                report["workflowStepCounts"]["E2E Continue After Missing Action"],
                3,
            )
            self.assertEqual(
                report["workflowStepCounts"]["E2E Stop On Missing Action"],
                2,
            )
            self.assertEqual(
                report["automationWorkflowName"],
                "E2E Background Workflow",
            )
            self.assertEqual(report["automationWorkflowStepCount"], 1)
            self.assertTrue(report["automationWorkflowIsIdempotent"])
            self.assertIsInstance(report["systemMuteValue"], bool)
            self.assertTrue(report["systemMuteStatePreserved"])
            self.assertTrue(report["calculatorRuleEnabled"])
            self.assertTrue(report["calculatorSkipRuleEnabled"])
            self.assertTrue(report["textEditRuleEnabled"])
            self.assertEqual(report["ruleCount"], 3)
            self.assertTrue(report["hasUnavailableGridEntry"])
            self.assertEqual(report["language"], "en")
            self.assertEqual(report["appearance"], "light")
            self.assertEqual(
                report["actionGridActionIDs"],
                [
                    "app.open-settings",
                    "toggleLaunchpad",
                    "app.toggle-dashboard",
                    "app.toggle-feature-panel",
                    "workflow.00000000-0000-4000-8000-000000000247",
                    "workflow.00000000-0000-4000-8000-000000000248",
                    "workflow.00000000-0000-4000-8000-000000000260",
                    "workflow.00000000-0000-4000-8000-000000000261",
                    "not-installed",
                ],
            )
            self.assertEqual(report["actionGridEntryCount"], 9)
            self.assertEqual(report["workflowHistoryCount"], 0)

        self.assertEqual(first["shortcutCount"], 4)
        self.assertEqual(second["shortcutCount"], 4)

    def test_real_domain_requires_explicit_opt_in(self):
        self.bundle_id = "com.example.mactools"
        result = self.run_fixture("seed", check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--allow-real-domain", result.stderr)

    def test_shell_harness_has_valid_zsh_syntax(self):
        subprocess.run(
            ["zsh", "-n", str(E2E_SCRIPT)],
            cwd=REPO_ROOT,
            check=True,
        )

    def test_checkpoint_records_status_and_detail(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            checkpoint_path = pathlib.Path(temporary_directory) / "ui-checkpoints.json"
            checkpoint_path.write_text(
                json.dumps({"workflow-visible": {"status": "pending", "detail": ""}}),
                encoding="utf-8",
            )

            subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "checkpoint",
                    temporary_directory,
                    "workflow-visible",
                    "pass",
                    "fixture workflow is visible",
                ],
                cwd=REPO_ROOT,
                check=True,
            )

            payload = json.loads(checkpoint_path.read_text(encoding="utf-8"))
            self.assertEqual(payload["workflow-visible"]["status"], "pass")
            self.assertEqual(
                payload["workflow-visible"]["detail"],
                "fixture workflow is visible",
            )
            self.assertIn("timestamp", payload["workflow-visible"])

    def test_checkpoint_rejects_unknown_name(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            checkpoint_path = pathlib.Path(temporary_directory) / "ui-checkpoints.json"
            checkpoint_path.write_text(
                json.dumps({"workflow-visible": {"status": "pending", "detail": ""}}),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "checkpoint",
                    temporary_directory,
                    "typo-checkpoint",
                    "pass",
                ],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unknown checkpoint", result.stderr)

    def test_key_sender_dry_run_mapping(self):
        expected = {
            "open-settings": 20,
            "action-grid": 21,
            "dashboard": 23,
            "safe-workflow": 22,
        }
        for name, key_code in expected.items():
            with self.subTest(name=name):
                result = subprocess.run(
                    ["xcrun", "swift", str(KEY_SENDER_TOOL), "describe", name],
                    cwd=REPO_ROOT,
                    check=True,
                    capture_output=True,
                    text=True,
                )
                payload = json.loads(result.stdout)
                self.assertEqual(payload["name"], name)
                self.assertEqual(payload["keyCode"], key_code)
                self.assertEqual(payload["modifiers"], ["control", "command"])

    def test_scenario_manifest_has_unique_complete_required_checkpoints(self):
        manifest = json.loads(SCENARIO_MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual(manifest["formatVersion"], 1)
        self.assertEqual(set(manifest["issueScope"]), {247, 249, 250, 251})
        required = [pack for pack in manifest["packs"] if pack["required"]]
        self.assertTrue(required)
        self.assertEqual(
            set().union(*(set(pack["issues"]) for pack in required)),
            {247, 249, 250, 251},
        )
        checkpoints = [
            checkpoint
            for pack in required
            for checkpoint in pack["checkpoints"]
        ]
        self.assertEqual(len(checkpoints), len(set(checkpoints)))
        self.assertIn("rebuild-permission-persistence", checkpoints)
        self.assertIn("screencast-captured", checkpoints)

    def test_scenario_and_record_pack_dry_runs(self):
        scenario = subprocess.run(
            [str(E2E_SCRIPT), "scenarios", "workflow-resilience"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(json.loads(scenario.stdout)["id"], "workflow-resilience")

        with tempfile.TemporaryDirectory() as temporary_directory:
            pathlib.Path(temporary_directory, "session.plist").touch()
            recording = subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "record-pack",
                    temporary_directory,
                    "workflow-resilience",
                    "12",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("screencast.workflow-resilience.mov", recording.stdout)
            self.assertIn("-R<visible-MacTools-window>", recording.stdout)
            self.assertNotIn("-D1", recording.stdout)

    def test_recording_uses_a_fail_closed_window_capture_helper(self):
        source = CAPTURE_RECT_TOOL.read_text(encoding="utf-8")
        self.assertIn("kAXStandardWindowSubrole", source)
        self.assertIn("no visible standard MacTools window", source)
        self.assertNotIn("CGWindowListCopyWindowInfo", source)

        harness = E2E_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('temporary_mov="$session_dir/.$base_name.$$.mov"', harness)
        self.assertIn('mv -f -- "$temporary_mov" "$mov"', harness)

    def test_code_verification_has_a_non_mutating_dry_run(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            pathlib.Path(temporary_directory, "session.plist").touch()
            result = subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "verify-code",
                    temporary_directory,
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
        self.assertIn("PluginCatalogManagerTests", result.stdout)
        self.assertIn("six injected Trackpad Gestures test classes", result.stdout)
        self.assertNotIn("Test Suite", result.stdout)


if __name__ == "__main__":
    unittest.main()
