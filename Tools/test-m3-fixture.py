#!/usr/bin/env python3
"""Focused regressions for the packaged independent M3 reference fixture.

The bundle cases use real signed bundle-shaped directories and the real
validate-bundle.sh. The build cases run the real build.sh with only the
compiler, codesign and final validator stubbed; fixture validation and staging
are not stubbed. No model inference, GUI or network is involved.
"""
from __future__ import annotations

import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "Tests/Fixtures/upscale-m3"
CATALOG = ROOT / "Resources/model-catalog.json"
HELPER = ROOT / "Tools/validate-m3-fixture.py"
VALIDATOR = ROOT / "Tools/validate-bundle.sh"
EXPECTED_FILES = {
    "manifest.json",
    "source.rgb",
    "input.f32",
    "reference.mps.rgb",
    "reference.cpu.rgb",
    "bicubic.rgb",
}


def run(command: list[str], *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


def write_executable(path: Path, source: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class HelperContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="m3-helper-test-")
        self.base = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def verify(self, source: Path, catalog: Path = CATALOG) -> subprocess.CompletedProcess[str]:
        return run([sys.executable, str(HELPER), "verify-source", str(source), str(catalog)])

    def test_canonical_source_and_catalog_are_accepted(self) -> None:
        result = self.verify(FIXTURE)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_symlinked_source_directory_is_refused(self) -> None:
        link = self.base / "fixture-link"
        link.symlink_to(FIXTURE, target_is_directory=True)
        result = self.verify(link)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("symbolic link", result.stdout)

    def test_catalog_disagreement_is_refused(self) -> None:
        source = self.base / "fixture"
        shutil.copytree(FIXTURE, source)
        catalog = self.base / "catalog.json"
        payload = CATALOG.read_text(encoding="utf-8")
        payload = payload.replace(
            "e0da6778bbcffbb26d61fda450648998e22f66d5867924706fee6d929aa50cdf",
            "0" * 64,
            1,
        )
        catalog.write_text(payload, encoding="utf-8")
        result = self.verify(source, catalog)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("catalog", result.stdout.lower())


class BundleValidatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.compiler_work = tempfile.TemporaryDirectory(prefix="m3-bundle-compiler-")
        cls.executable = Path(cls.compiler_work.name) / "RetouchStudio"
        result = subprocess.run(
            [
                "/usr/bin/clang",
                "-arch",
                platform.machine(),
                "-x",
                "c",
                "-o",
                str(cls.executable),
                "-",
            ],
            input="int main(void) { return 0; }\n",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if result.returncode != 0:
            cls.compiler_work.cleanup()
            raise RuntimeError(f"tiny bundle executable compile failed: {result.stdout}")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.compiler_work.cleanup()

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="m3-bundle-test-")
        self.base = Path(self.temporary.name)
        self.app = self.base / "Retouch Studio.app"
        self.make_bundle()
        self.sign()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @property
    def resources(self) -> Path:
        return self.app / "Contents/Resources"

    @property
    def fixture(self) -> Path:
        return self.resources / "Tests/Fixtures/upscale-m3"

    def make_bundle(self) -> None:
        resources = self.resources
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (resources / "Fonts").mkdir(parents=True)
        shutil.copy2(self.executable, self.app / "Contents/MacOS/RetouchStudio")
        shutil.copy2(ROOT / "Resources/Info.plist", self.app / "Contents/Info.plist")
        shutil.copy2(ROOT / "LICENSE", resources / "LICENSE")
        shutil.copy2(
            ROOT / "Resources/THIRD_PARTY_NOTICES.txt",
            resources / "THIRD_PARTY_NOTICES.txt",
        )
        shutil.copy2(CATALOG, resources / "model-catalog.json")
        for name in ("OFL.txt", "Vazirmatn-Regular.ttf", "Vazirmatn-Medium.ttf",
                     "Vazirmatn-SemiBold.ttf", "Vazirmatn-Bold.ttf"):
            shutil.copy2(ROOT / "Resources/Fonts" / name, resources / "Fonts" / name)
        shutil.copytree(FIXTURE, self.fixture)

    def sign(self) -> None:
        result = subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(self.app)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout)

    def validate(self) -> subprocess.CompletedProcess[str]:
        return run([str(VALIDATOR), str(self.app), "", "--forbid-worker"])

    def expect_rejected(self, needle: str) -> None:
        self.sign()
        result = self.validate()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("M3 reference fixture", result.stdout, result.stdout)
        self.assertIn(needle, result.stdout, result.stdout)

    def test_canonical_bundle_fixture_is_accepted(self) -> None:
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_missing_fixture_directory_is_rejected(self) -> None:
        shutil.rmtree(self.fixture)
        self.expect_rejected("canonical bundle location")

    def test_missing_required_file_is_rejected(self) -> None:
        (self.fixture / "reference.cpu.rgb").unlink()
        self.expect_rejected("reference.cpu.rgb")

    def test_extra_file_is_rejected(self) -> None:
        (self.fixture / "unexpected.txt").write_text("extra\n", encoding="utf-8")
        self.expect_rejected("unexpected")

    def test_wrong_size_is_rejected(self) -> None:
        with (self.fixture / "source.rgb").open("ab") as handle:
            handle.write(b"x")
        self.expect_rejected("size mismatch")

    def test_wrong_hash_at_the_right_size_is_rejected(self) -> None:
        path = self.fixture / "input.f32"
        payload = bytearray(path.read_bytes())
        payload[0] ^= 0xFF
        path.write_bytes(payload)
        self.expect_rejected("SHA-256 mismatch")

    def test_malformed_manifest_is_rejected(self) -> None:
        (self.fixture / "manifest.json").write_bytes(b"{" * 2281)
        self.expect_rejected("manifest.json")

    def test_internally_inconsistent_manifest_is_rejected(self) -> None:
        path = self.fixture / "manifest.json"
        payload = path.read_bytes()
        self.assertIn(b'"COMPLETE"', payload)
        path.write_bytes(payload.replace(b'"COMPLETE"', b'"INVALID!"', 1))
        self.expect_rejected("manifest.json")

    def test_symlinked_fixture_file_is_rejected(self) -> None:
        external = self.base / "external-source.rgb"
        shutil.copy2(self.fixture / "source.rgb", external)
        (self.fixture / "source.rgb").unlink()
        (self.fixture / "source.rgb").symlink_to(external)
        self.expect_rejected("regular non-symlink")

    def test_symlinked_fixture_directory_is_rejected(self) -> None:
        external = self.base / "external-fixture"
        shutil.copytree(self.fixture, external)
        shutil.rmtree(self.fixture)
        self.fixture.symlink_to(external, target_is_directory=True)
        self.expect_rejected("symbolic link")

    def test_alternate_bundle_location_is_rejected(self) -> None:
        alternate = self.resources / "upscale-m3"
        shutil.move(str(self.fixture), str(alternate))
        self.expect_rejected("canonical bundle location")

    def test_ambiguous_duplicate_bundle_location_is_rejected(self) -> None:
        shutil.copytree(self.fixture, self.resources / "upscale-m3")
        self.expect_rejected("alternate")

    def test_symlinked_canonical_parent_is_rejected(self) -> None:
        external = self.base / "external-tests"
        shutil.move(str(self.resources / "Tests"), str(external))
        (self.resources / "Tests").symlink_to(external, target_is_directory=True)
        self.expect_rejected("symbolic link")


class ManualWorkflowContractTests(unittest.TestCase):
    def test_packaged_inference_is_a_named_manual_workflow(self) -> None:
        workflow = ROOT / ".github/workflows/m3-packaged-acceptance.yml"
        self.assertTrue(workflow.is_file(), "the packaged M3 acceptance workflow is missing")
        text = workflow.read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", text)
        self.assertNotIn("pull_request:", text)
        self.assertNotIn("push:", text)
        self.assertIn("name: M3 Packaged Real Inference", text)
        self.assertIn("model_run_id:", text)
        self.assertIn("model_artifact:", text)
        self.assertIn("gh run download", text)
        self.assertIn("RETOUCH_ARCH: arm64", text)
        self.assertIn("./build.sh release", text)
        self.assertIn("--upscale-selftest", text)
        self.assertIn("UPSCALE SELFTEST: PASS", text)
        self.assertIn("Tools/worker-integrity.py\" verify", text)
        self.assertIn("__pycache__", text)
        self.assertIn("if: always()", text)

    def test_manual_workflow_prepares_the_full_worker_before_build(self) -> None:
        text = (ROOT / ".github/workflows/m3-packaged-acceptance.yml").read_text(encoding="utf-8")
        build = text.index("./build.sh release")
        runtime = text.index("./Tools/build-python-runtime.sh")
        setup = text.index("./Tools/setup-worker-venv.sh --full")
        self.assertLess(runtime, setup)
        self.assertLess(setup, build)
        identity_step = text.split("- name: Retrieve only the supplied pinned model artifact", 1)[0]
        self.assertIn("GH_TOKEN: ${{ github.token }}", identity_step)
        self.assertNotIn("brew install", text)

    def test_release_arm64_prepares_the_full_worker_without_global_installs(self) -> None:
        text = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        arm64 = text.split("  macos-x86_64:", 1)[0]
        self.assertNotIn("RETOUCH_SKIP_WORKER", arm64)
        runtime = arm64.index("./Tools/build-python-runtime.sh")
        setup = arm64.index("./Tools/setup-worker-venv.sh --full")
        build = arm64.index("./build.sh release")
        self.assertLess(runtime, setup)
        self.assertLess(setup, build)
        self.assertNotIn("brew install", arm64)

    def test_ordinary_ci_runs_integrity_regressions_without_inference(self) -> None:
        workflow = ROOT / ".github/workflows/ci.yml"
        text = workflow.read_text(encoding="utf-8")
        self.assertIn("./Tools/test-m3-fixture.py 2>&1 | tee -a", text)
        self.assertIn("M3 fixture regressions: OK", text)
        self.assertNotIn("--upscale-selftest", text)

    def test_ordinary_ci_emits_the_m3_verdict_after_the_suite_succeeds(self) -> None:
        text = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        lines = text.splitlines()
        command = '          ./Tools/test-m3-fixture.py 2>&1 | tee -a "$RUNNER_TEMP/macos-integration.log"'
        index = lines.index(command)
        self.assertEqual(
            lines[index + 1].strip(),
            "printf '%s\\n' 'M3 fixture regressions: OK' | tee -a \"$RUNNER_TEMP/macos-integration.log\"",
        )


class BuildStagingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="m3-build-stage-test-")
        self.base = Path(self.temporary.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.fakebin = self.base / "fakebin"
        self.fakebin.mkdir()
        self.codesign_log = self.base / "codesign.log"
        self.validator_log = self.base / "validator.log"
        self.event_log = self.base / "events.log"
        self.staged = self.repo / "Retouch Studio.app/Contents/Resources/Tests/Fixtures/upscale-m3"
        self.prepare_repository()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def prepare_repository(self) -> None:
        shutil.copy2(ROOT / "build.sh", self.repo / "build.sh")
        (self.repo / "build.sh").chmod(0o755)
        (self.repo / "Sources/RetouchStudio").mkdir(parents=True)
        (self.repo / "Sources/RetouchStudio/dummy.swift").write_text(
            "// compiler stub input\n", encoding="utf-8"
        )
        (self.repo / "Resources").mkdir(parents=True)
        for name in ("Info.plist", "model-catalog.json", "THIRD_PARTY_NOTICES.txt"):
            shutil.copy2(ROOT / "Resources" / name, self.repo / "Resources" / name)
        shutil.copytree(ROOT / "Resources/Fonts", self.repo / "Resources/Fonts")
        shutil.copy2(ROOT / "LICENSE", self.repo / "LICENSE")
        shutil.copytree(FIXTURE, self.repo / "Tests/Fixtures/upscale-m3")
        (self.repo / "Tools").mkdir()
        if HELPER.exists():
            shutil.copy2(HELPER, self.repo / "Tools/validate-m3-fixture.py")
        shutil.copy2(ROOT / "Tools/worker-integrity.py", self.repo / "Tools/worker-integrity.py")
        write_executable(
            self.repo / "Tools/validate-bundle.sh",
            """#!/bin/bash
printf 'validate %s\\n' "$*" >> "$EVENT_LOG"
printf '%s\\n' "$*" >> "$VALIDATOR_LOG"
if [ "${REQUIRE_WORKER_INTEGRITY:-0}" = "1" ]; then
  /usr/bin/python3 "$PWD/Tools/worker-integrity.py" verify \\
    "$1/Contents/Resources/Worker"
fi
""",
        )
        write_executable(
            self.repo / "Tests/build-studiocore.sh",
            '#!/bin/bash\nset -e\nmkdir -p "$3"\n: > "$3/libStudioCore.a"\n',
        )
        write_executable(
            self.fakebin / "swiftc",
            """#!/bin/bash
set -e
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    shift
    output="$1"
  fi
  shift
done
if [ -n "$output" ]; then
  mkdir -p "$(dirname "$output")"
  printf '#!/bin/bash\\nexit 0\\n' > "$output"
  chmod +x "$output"
fi
""",
        )
        write_executable(
            self.fakebin / "codesign",
            """#!/bin/bash
printf 'codesign %s\\n' "$*" >> "$EVENT_LOG"
printf '%s\\n' "$*" >> "$CODESIGN_LOG"
if ! /usr/bin/python3 "$PWD/Tools/validate-m3-fixture.py" verify-source \\
    "$CODESIGN_FIXTURE" "$PWD/Resources/model-catalog.json" >/dev/null 2>&1; then
  echo 'fixture was absent or invalid when codesign ran' >&2
  exit 90
fi
if [ "${MUTATE_NESTED:-0}" = "1" ]; then
  for target in "$@"; do
    case "$target" in
      */Contents/Resources/Worker/*)
        printf '\\nfinal-nested-signature\\n' >> "$target"
        ;;
    esac
  done
fi
""",
        )

    def enable_worker(self) -> None:
        (self.repo / "worker/retouch_ai_worker").mkdir(parents=True)
        write_executable(
            self.repo / "worker/.venv/bin/python3",
            "#!/bin/bash\nexit 0\n",
        )
        write_executable(
            self.repo / "Tools/bundle-worker.sh",
            """#!/bin/bash
set -e
printf 'bundle-worker\\n' >> "$EVENT_LOG"
app="$1"
worker="$app/Contents/Resources/Worker"
mkdir -p "$worker/Python.framework/Versions/3.13/bin"
printf 'nested-before-final-signing\\n' \\
  > "$worker/Python.framework/Versions/3.13/bin/python3.13"
chmod +x "$worker/Python.framework/Versions/3.13/bin/python3.13"
printf '%064d' 0 > "$worker/.stamp"
/usr/bin/python3 "$PWD/Tools/worker-integrity.py" write "$worker"
""",
        )
        write_executable(
            self.fakebin / "file",
            """#!/bin/bash
if [ "${1:-}" = "-b" ]; then
  case "${2:-}" in
    */Contents/Resources/Worker/*) printf 'Mach-O 64-bit executable\\n'; exit 0 ;;
  esac
fi
exec /usr/bin/file "$@"
""",
        )

    def build(self, *, worker: bool = False, identity: str = "") -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": str(self.fakebin) + os.pathsep + environment.get("PATH", ""),
                "RETOUCH_ARCH": "arm64",
                "RETOUCH_SKIP_WORKER": "0" if worker else "1",
                "RETOUCH_TESTS_ROOT": str(self.base / "no-developer-root"),
                "CODESIGN_LOG": str(self.codesign_log),
                "CODESIGN_FIXTURE": str(self.staged),
                "VALIDATOR_LOG": str(self.validator_log),
                "EVENT_LOG": str(self.event_log),
                "MUTATE_NESTED": "1" if worker else "0",
                "REQUIRE_WORKER_INTEGRITY": "1" if worker else "0",
            }
        )
        if identity:
            environment["RETOUCH_SIGN_IDENTITY"] = identity
        return subprocess.run(
            [str(self.repo / "build.sh"), "release"],
            cwd=self.repo,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def assert_refused_before_signing(self) -> None:
        result = self.build()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.codesign_log.exists(), result.stdout)

    def test_arm64_build_stages_exact_fixture_before_codesign(self) -> None:
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(self.codesign_log.exists(), result.stdout)
        self.assertEqual({path.name for path in self.staged.iterdir()}, EXPECTED_FILES)
        for name in EXPECTED_FILES:
            self.assertEqual(
                (self.staged / name).read_bytes(),
                (FIXTURE / name).read_bytes(),
                name,
            )

    def test_final_nested_signing_precedes_worker_integrity_seal(self) -> None:
        self.enable_worker()
        identity = "Developer ID Application: M3 Ordering Test"
        result = self.build(worker=True, identity=identity)
        self.assertEqual(result.returncode, 0, result.stdout)
        worker = self.repo / "Retouch Studio.app/Contents/Resources/Worker"
        verified = run([sys.executable, str(self.repo / "Tools/worker-integrity.py"), "verify", str(worker)])
        self.assertEqual(verified.returncode, 0, verified.stdout)
        signing = self.codesign_log.read_text(encoding="utf-8")
        self.assertIn("--timestamp --options runtime", signing)
        self.assertIn(f"--sign {identity}", signing)
        events = self.event_log.read_text(encoding="utf-8").splitlines()
        nested = next(index for index, line in enumerate(events) if "Contents/Resources/Worker/" in line)
        outer = next(index for index, line in enumerate(events) if line.endswith("Retouch Studio.app"))
        validation = next(index for index, line in enumerate(events) if line.startswith("validate "))
        self.assertLess(nested, outer, events)
        self.assertLess(outer, validation, events)

    def test_build_refuses_missing_source_without_developer_fallback(self) -> None:
        shutil.rmtree(self.repo / "Tests/Fixtures/upscale-m3")
        self.assert_refused_before_signing()

    def test_build_refuses_symlinked_source_directory(self) -> None:
        source = self.repo / "Tests/Fixtures/upscale-m3"
        external = self.base / "external-fixture"
        shutil.move(str(source), str(external))
        source.symlink_to(external, target_is_directory=True)
        self.assert_refused_before_signing()

    def test_build_refuses_missing_required_source_file(self) -> None:
        (self.repo / "Tests/Fixtures/upscale-m3/reference.cpu.rgb").unlink()
        self.assert_refused_before_signing()

    def test_build_refuses_modified_source_bytes(self) -> None:
        with (self.repo / "Tests/Fixtures/upscale-m3/source.rgb").open("ab") as handle:
            handle.write(b"changed")
        self.assert_refused_before_signing()

    def test_build_refuses_unexpected_source_file(self) -> None:
        (self.repo / "Tests/Fixtures/upscale-m3/unexpected.txt").write_text(
            "extra\n", encoding="utf-8"
        )
        self.assert_refused_before_signing()


if __name__ == "__main__":
    unittest.main(verbosity=2)
