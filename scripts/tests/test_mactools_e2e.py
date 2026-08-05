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
            self.assertEqual(report["workflowName"], "E2E Safe Workflow")
            self.assertEqual(report["workflowStepCount"], 3)
            self.assertEqual(report["workflowCount"], 2)
            self.assertEqual(
                report["automationWorkflowName"],
                "E2E Background Workflow",
            )
            self.assertEqual(report["automationWorkflowStepCount"], 1)
            self.assertTrue(report["automationWorkflowIsIdempotent"])
            self.assertTrue(report["systemMuteStatePreserved"])
            self.assertTrue(report["calculatorRuleEnabled"])
            self.assertEqual(
                report["actionGridActionIDs"],
                ["app.open-settings", "toggleLaunchpad"],
            )
            self.assertEqual(report["workflowHistoryCount"], 0)

        self.assertEqual(first["shortcutCount"], 2)
        self.assertEqual(second["shortcutCount"], 2)

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
            checkpoint_path.write_text("{}\n", encoding="utf-8")

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

    def test_key_sender_dry_run_mapping(self):
        result = subprocess.run(
            ["xcrun", "swift", str(KEY_SENDER_TOOL), "describe", "open-settings"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )

        payload = json.loads(result.stdout)
        self.assertEqual(payload["name"], "open-settings")
        self.assertEqual(payload["keyCode"], 20)
        self.assertEqual(payload["modifiers"], ["control", "command"])


if __name__ == "__main__":
    unittest.main()
