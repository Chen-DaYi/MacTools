import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import threading
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/install-debug-app.sh"


class InstallDebugAppTests(unittest.TestCase):
    def make_app(
        self,
        path: pathlib.Path,
        marker: str,
        *,
        bundle_identifier: str = "com.example.mactools-test",
        executable_name: str = "MacTools Test",
        long_running: bool = False,
    ) -> None:
        executable = path / "Contents/MacOS" / executable_name
        executable.parent.mkdir(parents=True)
        shutil.copyfile("/bin/sleep", executable)
        executable.chmod(0o755)
        with (path / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": bundle_identifier,
                    "CFBundleExecutable": executable_name,
                },
                handle,
            )
        marker_path = path / "Contents/Resources/marker.txt"
        marker_path.parent.mkdir(parents=True)
        marker_path.write_text(marker, encoding="utf-8")
        subprocess.run(
            [
                "/usr/bin/codesign",
                "--force",
                "--sign",
                "-",
                "--identifier",
                bundle_identifier,
                "--requirements",
                f'=designated => identifier "{bundle_identifier}"',
                str(path),
            ],
            check=True,
            capture_output=True,
        )

    def test_term_after_backup_restores_previous_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Built/MacTools Test.app"
            installed = root / "Home/Applications/MacTools Test.app"
            self.make_app(source, "new")
            self.make_app(installed, "previous")
            environment = os.environ.copy()
            environment["HOME"] = str(root / "Home")
            environment["MACTOOLS_INSTALL_DEBUG_TEST_INTERRUPT_AFTER_BACKUP"] = "TERM"

            result = subprocess.run(
                [str(SCRIPT), str(source), str(installed)],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 143)
            self.assertEqual(
                (installed / "Contents/Resources/marker.txt").read_text(encoding="utf-8"),
                "previous",
            )
            self.assertFalse(
                list(installed.parent.glob(".mactools-debug-install.*")),
                "transaction staging directory should be cleaned after restoration",
            )

    def test_replacement_transaction_is_armed_before_backup_move(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        transaction = script.index('replacement_started=true\n    /bin/mv "$installed_app" "$backup_app"')
        interrupt_hook = script.index("MACTOOLS_INSTALL_DEBUG_TEST_INTERRUPT_AFTER_BACKUP")

        self.assertLess(transaction, interrupt_hook)

    def test_identity_mismatch_is_rejected_before_stopping_retained_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Built/MacTools Test.app"
            installed = root / "Home/Applications/MacTools Test.app"
            self.make_app(
                source,
                "new",
                bundle_identifier="com.example.unrelated",
            )
            self.make_app(installed, "previous", long_running=True)
            environment = os.environ.copy()
            environment["HOME"] = str(root / "Home")
            retained_process = subprocess.Popen(
                [str(installed / "Contents/MacOS/MacTools Test"), "30"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                result = subprocess.run(
                    [str(SCRIPT), str(source), str(installed)],
                    env=environment,
                    capture_output=True,
                    text=True,
                    check=False,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("identity does not match", result.stderr)
                self.assertIsNone(
                    retained_process.poll(),
                    "identity validation must happen before process termination",
                )
                self.assertEqual(
                    (installed / "Contents/Resources/marker.txt").read_text(encoding="utf-8"),
                    "previous",
                )
                self.assertFalse(list(installed.parent.glob(".mactools-debug-install.*")))
            finally:
                retained_process.terminate()
                retained_process.wait(timeout=5)

    def test_stop_debug_app_targets_exact_installed_executable_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            installed_executable = (
                root / "Applications/MacTools Test.app/Contents/MacOS/MacTools Test"
            )
            decoy_executable = root / "decoy/MacTools Test"
            installed_executable.parent.mkdir(parents=True)
            decoy_executable.parent.mkdir(parents=True)
            installed_executable.symlink_to("/bin/sleep")
            decoy_executable.symlink_to("/bin/sleep")
            installed_process = subprocess.Popen([str(installed_executable), "30"])
            decoy_process = subprocess.Popen([str(decoy_executable), "30"])
            installed_waiter = threading.Thread(target=installed_process.wait, daemon=True)
            installed_waiter.start()
            try:
                result = subprocess.run(
                    [
                        "/usr/bin/make",
                        "-f",
                        str(REPO_ROOT / "Makefile"),
                        "stop-debug-app",
                        "APP_PRODUCT_NAME=MacTools Test",
                        f"LOCAL_APP_INSTALL_DIR={root / 'Applications'}",
                    ],
                    cwd=REPO_ROOT,
                    capture_output=True,
                    text=True,
                    check=False,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                installed_waiter.join(timeout=5)
                self.assertIsNotNone(installed_process.poll())
                self.assertIsNone(
                    decoy_process.poll(),
                    "a same-basename process outside the retained app must survive",
                )
            finally:
                for process in (installed_process, decoy_process):
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
