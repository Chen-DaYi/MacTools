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
PRIVACY_HELPER_TOOL = REPO_ROOT / "scripts" / "e2e" / "MacToolsE2EPrivacyHelper.swift"
PRIVACY_RECORDER_TOOL = REPO_ROOT / "scripts" / "e2e" / "MacToolsE2ERecorder.swift"
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
            self.assertEqual(report["workflowCount"], 6)
            self.assertEqual(
                report["workflowNames"],
                [
                    "E2E Safe Workflow",
                    "E2E Background Workflow",
                    "E2E Continue After Missing Action",
                    "E2E Stop On Missing Action",
                    "E2E Cancellable Delay",
                    "E2E Visual Proof Workflow",
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
            self.assertTrue(report["primaryHelperRuleEnabled"])
            self.assertTrue(report["primaryHelperSkipRuleEnabled"])
            self.assertTrue(report["secondaryHelperRuleEnabled"])
            self.assertEqual(report["ruleCount"], 3)
            self.assertEqual(report["visualWorkflowName"], "E2E Visual Proof Workflow")
            self.assertEqual(report["visualWorkflowStepCount"], 2)
            self.assertTrue(report["visualWorkflowUsesSavedScript"])
            self.assertTrue(report["visualWorkflowShowsActionGrid"])
            self.assertEqual(report["savedScriptCount"], 1)
            self.assertEqual(
                report["savedScriptName"],
                "E2E Privacy-Safe Visual Proof",
            )
            self.assertEqual(
                report["savedScriptActionID"],
                "run.00000000-0000-4000-8000-000000000290",
            )
            self.assertTrue(report["savedScriptRunsLocallyWithoutConfirmation"])
            self.assertTrue(report["savedScriptRequiresExternalConfirmation"])
            self.assertTrue(report["savedScriptIncludedInPortableBackup"])
            self.assertTrue(report["savedScriptIncludedInActionGrid"])
            self.assertTrue(report["savedScriptIncludedInVisualWorkflow"])
            self.assertIn(
                '/usr/bin/open -a "$HOME/Applications/MacTools Dev.app"',
                FIXTURE_TOOL.read_text(encoding="utf-8"),
            )
            self.assertTrue(report["hasUnavailableGridEntry"])
            self.assertTrue(report["hasTrackpadActionGridMapping"])
            self.assertTrue(report["hasTrackpadWorkflowMapping"])
            self.assertEqual(report["trackpadMappingCount"], 2)
            self.assertEqual(
                report["trackpadActionReferences"],
                [
                    "action-grid/show",
                    "automation/workflow.00000000-0000-4000-8000-000000000247",
                ],
            )
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
                    "not-installed",
                    "app.toggle-dashboard",
                    "app.toggle-feature-panel",
                    "workflow.00000000-0000-4000-8000-000000000247",
                    "workflow.00000000-0000-4000-8000-000000000248",
                    "workflow.00000000-0000-4000-8000-000000000263",
                    "run.00000000-0000-4000-8000-000000000290",
                    "workflow.00000000-0000-4000-8000-000000000260",
                    "workflow.00000000-0000-4000-8000-000000000261",
                    "workflow.00000000-0000-4000-8000-000000000262",
                    "app.open-settings",
                    "toggleLaunchpad",
                ],
            )
            self.assertEqual(report["actionGridEntryCount"], 9)
            self.assertEqual(report["actionGridTotalEntryCount"], 21)
            self.assertEqual(report["actionGridFolderCount"], 4)
            self.assertEqual(report["actionGridMaximumFolderDepth"], 2)
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

    def test_checkpoint_records_optional_manifest_checkpoint_for_existing_session(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            checkpoint_path = pathlib.Path(temporary_directory) / "ui-checkpoints.json"
            manifest = json.loads(SCENARIO_MANIFEST.read_text(encoding="utf-8"))
            required_names = [
                checkpoint
                for pack in manifest["packs"]
                if pack["required"]
                for checkpoint in pack["checkpoints"]
            ]
            checkpoint_path.write_text(
                json.dumps(
                    {
                        checkpoint: {"status": "pass", "detail": "verified"}
                        for checkpoint in required_names
                    }
                ),
                encoding="utf-8",
            )
            report_path = pathlib.Path(temporary_directory) / "report.json"
            report_path.write_text(
                json.dumps(
                    {
                        "generatedAt": "earlier",
                        "preflight": {"passed": True},
                        "fixture": {"valid": True},
                        "uiCheckpoints": {},
                        "scenarioCoverage": {},
                        "passed": True,
                    }
                ),
                encoding="utf-8",
            )

            subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "checkpoint",
                    temporary_directory,
                    "trackpad-physical-gesture-verification",
                    "pass",
                    "physical gesture recognized",
                ],
                cwd=REPO_ROOT,
                check=True,
            )

            payload = json.loads(checkpoint_path.read_text(encoding="utf-8"))
            self.assertEqual(
                payload["trackpad-physical-gesture-verification"]["status"],
                "pass",
            )
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertTrue(report["passed"])
            self.assertEqual(len(report["uiCheckpoints"]), len(required_names) + 1)
            self.assertTrue(report["scenarioCoverage"]["trackpad-hardware"]["passed"])

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

    def test_pointer_click_has_a_non_mutating_dry_run(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            pathlib.Path(temporary_directory, "session.plist").touch()
            result = subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "pointer-click",
                    temporary_directory,
                    "1000",
                    "768",
                    "930",
                    "147",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("Pointer click at (930,147)", result.stdout)
            key_sender = KEY_SENDER_TOOL.read_text(encoding="utf-8")
            self.assertIn("kAXFocusedWindowAttribute", key_sender)
            self.assertIn("mouseType: .mouseMoved", key_sender)
            self.assertIn("mouseType: .leftMouseDown", key_sender)
            self.assertIn("mouseType: .leftMouseUp", key_sender)
            self.assertIn("move.flags = []", key_sender)


    def test_text_input_has_non_mutating_dry_runs(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            pathlib.Path(temporary_directory, "session.plist").touch()
            select_all = subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "input-select-all",
                    temporary_directory,
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            type_text = subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "input-text",
                    temporary_directory,
                    "Pilot Build Check",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("Select all", select_all.stdout)
            self.assertIn("Type 17 characters", type_text.stdout)
            key_sender = KEY_SENDER_TOOL.read_text(encoding="utf-8")
            self.assertIn("keyboardSetUnicodeString", key_sender)
            self.assertIn('case "select-all"', key_sender)
            self.assertIn('case "type-text"', key_sender)

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
        self.assertIn("action-registry-health", checkpoints)
        self.assertIn("saved-script-grid-picker-visible", checkpoints)
        self.assertIn("privacy-helper-window-visible", checkpoints)
        self.assertIn("screencast-captured", checkpoints)
        optional = [pack for pack in manifest["packs"] if not pack["required"]]
        self.assertEqual([pack["id"] for pack in optional], ["trackpad-hardware"])
        self.assertEqual(
            optional[0]["checkpoints"],
            ["trackpad-physical-gesture-verification"],
        )

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
            self.assertIn(
                "Story start route: mactools-dev://app/settings/features/automation",
                recording.stdout,
            )
            self.assertIn("ScreenCaptureKit allowlist", recording.stdout)
            self.assertIn("<visible-MacTools-window>", recording.stdout)
            self.assertIn("<ready-file>", recording.stdout)
            self.assertIn("<first-action-file>", recording.stdout)
            self.assertIn("<assertion-stop-file>", recording.stdout)
            self.assertNotIn("-D1", recording.stdout)

            saved_scripts = subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "record-pack",
                    temporary_directory,
                    "saved-scripts",
                    "12",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn(
                "Story start route: mactools-dev://app/settings/plugins/saved-scripts",
                saved_scripts.stdout,
            )

            helper = subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "privacy-helper",
                    os.path.relpath(temporary_directory, REPO_ROOT),
                    "primary",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("MacTools E2E PRIMARY Helper.app", helper.stdout)
            self.assertIn(str(pathlib.Path(temporary_directory).resolve()), helper.stdout)

    def test_recording_ready_and_assertion_stop_markers_are_addressable(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            session = pathlib.Path(temporary_directory)
            (session / "session.plist").touch()
            ready = (
                session
                / "privacy-recorder"
                / "screencast.saved-scripts.ready"
            )
            ready.parent.mkdir(parents=True)
            ready.touch()

            wait = subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "wait-recording-ready",
                    temporary_directory,
                    "saved-scripts",
                    "1",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("recording-ready=", wait.stdout)

            start = subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "start-recording",
                    temporary_directory,
                    "saved-scripts",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("recording-start-requested=", start.stdout)
            self.assertTrue(
                (
                    session
                    / "privacy-recorder"
                    / "screencast.saved-scripts.start"
                ).is_file()
            )

            stop = subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "stop-recording",
                    temporary_directory,
                    "saved-scripts",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("recording-stop-requested=", stop.stdout)
            self.assertTrue(
                (
                    session
                    / "privacy-recorder"
                    / "screencast.saved-scripts.stop"
                ).is_file()
            )

    def test_recording_uses_a_fail_closed_application_filter(self):
        source = CAPTURE_RECT_TOOL.read_text(encoding="utf-8")
        self.assertIn("kAXStandardWindowSubrole", source)
        self.assertIn("no visible standard MacTools window", source)
        self.assertNotIn("CGWindowListCopyWindowInfo", source)

        recorder = PRIVACY_RECORDER_TOOL.read_text(encoding="utf-8")
        self.assertIn("SCContentFilter", recorder)
        self.assertIn("including: allowedApplications", recorder)
        self.assertIn("missingApplication", recorder)
        self.assertIn("rectangleSpansDisplays", recorder)
        self.assertIn("configuration.showMouseClicks = true", recorder)
        self.assertIn("request.stopURL", recorder)
        self.assertIn("request.readyURL", recorder)
        self.assertIn("request.startURL", recorder)
        self.assertIn("isCaptureEnabled", recorder)
        self.assertIn("guard didStartWriting else", recorder)
        self.assertIn("guard started else", recorder)

        harness = E2E_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('temporary_mov="$session_dir/.$base_name.$$.mov"', harness)
        self.assertIn('mv -f -- "$temporary_mov" "$mov"', harness)
        self.assertIn("privacy_recorder_tool", harness)
        self.assertIn("com.jennymedia.mactools.e2e-helper.backdrop", harness)
        self.assertIn("com.jennymedia.mactools.e2e-helper.secondary", harness)
        self.assertIn('/usr/bin/open -gj -a "$(privacy_helper_app_path "$session_dir" primary)"', harness)
        self.assertIn('/usr/bin/open -gj -a "$(privacy_helper_app_path "$session_dir" secondary)"', harness)
        self.assertIn('mactools-dev://app/$start_route', harness)
        self.assertIn("recording_start_route", harness)
        self.assertIn("wait_recording_ready", harness)
        self.assertIn("start_recording", harness)
        self.assertIn("stop_recording", harness)
        self.assertIn("ensure_input_driver", harness)
        self.assertIn("input_driver_tool", harness)
        self.assertIn('session_dir="${session_dir:A}"', harness)
        self.assertIn(
            'ensure_privacy_recorder "$session_dir"\n'
            '    ensure_input_driver "$session_dir"\n'
            '    stop_app',
            harness,
        )
        self.assertIn('for capture_attempt in {1..50}; do', harness)
        self.assertIn('key_sender_tool send open-settings', harness)
        self.assertNotIn("/usr/sbin/screencapture -v", harness)

    def test_privacy_recorder_and_helper_typecheck(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            recorder = pathlib.Path(temporary_directory) / "MacToolsE2ERecorder"
            helper = pathlib.Path(temporary_directory) / "MacToolsE2EPrivacyHelper"
            subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    "-parse-as-library",
                    "-suppress-warnings",
                    "-framework",
                    "AppKit",
                    "-framework",
                    "AVFoundation",
                    "-framework",
                    "ScreenCaptureKit",
                    str(PRIVACY_RECORDER_TOOL),
                    "-o",
                    str(recorder),
                ],
                cwd=REPO_ROOT,
                check=True,
            )
            subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    "-parse-as-library",
                    "-framework",
                    "AppKit",
                    str(PRIVACY_HELPER_TOOL),
                    "-o",
                    str(helper),
                ],
                cwd=REPO_ROOT,
                check=True,
            )

    def test_code_verification_has_a_non_mutating_dry_run(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            pathlib.Path(temporary_directory, "session.plist").touch()
            environment = os.environ.copy()
            environment["MACTOOLS_E2E_APP_PATH"] = str(
                pathlib.Path(temporary_directory, "Missing MacTools.app")
            )
            result = subprocess.run(
                [
                    str(E2E_SCRIPT),
                    "verify-code",
                    temporary_directory,
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )
        self.assertIn("PluginCatalogManagerTests", result.stdout)
        self.assertIn("all 15 native action-provider suites", result.stdout)
        self.assertIn("six injected Trackpad Gestures test classes", result.stdout)
        self.assertNotIn("Test Suite", result.stdout)

    def test_privacy_helper_is_deterministic_and_does_not_read_user_data(self):
        source = PRIVACY_HELPER_TOOL.read_text(encoding="utf-8")
        self.assertIn("No user files, account data, or clipboard content", source)
        self.assertIn("NSScreen.screens", source)
        self.assertIn('arguments.contains("--recording-privacy")', source)
        self.assertIn("application.hide()", source)
        self.assertIn("application.unhide()", source)
        self.assertIn("--visibility-state", source)
        self.assertIn("--restore-visibility", source)
        self.assertIn("SIGTERM", source)
        self.assertNotIn("NSPasteboard", source)
        self.assertNotIn("FileManager", source)

        harness = E2E_SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn('"permissionState": "pending-user-grant"', harness)
        self.assertIn("trackpadListenerLeaseOwnedByStableApp", harness)
        self.assertIn("--args --recording-privacy", harness)


if __name__ == "__main__":
    unittest.main()
