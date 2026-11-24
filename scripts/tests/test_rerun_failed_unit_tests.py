#!/usr/bin/env python3
"""Contract tests for `scripts/ci/rerun_failed_unit_tests.py` (TODO T13).

The rerun mechanism is only useful if it selects **exactly** the tests that
failed. Two failure modes matter:

  * under-selection → the rerun passes although the regression is still there,
    and the job goes green on a bad change;
  * a noisy parser → every failure reruns the whole suite, which is what we were
    trying to avoid.

So the assertions below pin the identifier shapes for the three log dialects
that actually appear in the CI log (Swift Testing with a function name, Swift
Testing with a display name, XCTest), the xcresult JSON walk, and the
"never under-select" fallback (suite-level selection when a display name hides
the function).

Run: python3 scripts/tests/test_rerun_failed_unit_tests.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PARSER = ROOT / "scripts" / "ci" / "rerun_failed_unit_tests.py"


def load_parser():
    spec = importlib.util.spec_from_file_location("rerun_failed_unit_tests", PARSER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


parser_module = load_parser()

# Real log lines (the gh log prefix is kept on purpose: the parser must not
# anchor at the start of the line).
SWIFT_TESTING_FUNCTION_LOG = """\
Unit tests (cmuxTests)\t运行 cmuxTests\t2026-11-23T14:54:27.3397480Z ✘ Test remoteManualInputPreservesLiteralAndNamedKeyOrder() recorded an issue at RemoteTmuxMirrorPaneInputMappingTests.swift:415:9: Expectation failed: (commands → …)
Unit tests (cmuxTests)\t运行 cmuxTests\t2026-11-23T14:54:27.8792180Z ✘ Test remoteManualInputPreservesLiteralAndNamedKeyOrder() failed after 2.680 seconds with 1 issue.
"""

SWIFT_TESTING_DISPLAY_NAME_LOG = """\
Unit tests (cmuxTests)\t运行 cmuxTests\t2026-11-23T12:49:53.7907440Z ✘ Test closingTheWindowDuringTheDeminiaturizeWaitIsNotResurrected() recorded an issue at SettingsWindowPresentationContractTests.swift:56:33: Issue recorded
Unit tests (cmuxTests)\t运行 cmuxTests\t2026-11-23T12:49:53.8291360Z ✘ Test closingTheWindowDuringTheDeminiaturizeWaitIsNotResurrected() failed after 1.304 seconds with 1 issue.
"""

SWIFT_TESTING_QUOTED_NAME_LOG = """\
✘ Test "A canceled forward cannot publish a late local address" recorded an issue at CloudPortRoutePlanTests.swift:507:9: Expectation failed: await wait { model.phase == .stopping }
✘ Test "A canceled forward cannot publish a late local address" failed after 60.177 seconds with 1 issue.
"""

XCTEST_LOG = """\
Test Case '-[WorkspaceUnitTests testClosePanelKeepsFocus]' failed (0.421 seconds).
"""

XCRESULT_JSON = {
    "testNodes": [
        {
            "nodeType": "Test Plan",
            "name": "cmux-unit",
            "result": "Failed",
            "children": [
                {
                    "nodeType": "Test Target",
                    "name": "cmuxTests",
                    "result": "Failed",
                    "children": [
                        {
                            "nodeType": "Test Suite",
                            "name": "RemoteTmuxMirrorPaneInputMappingTests",
                            "result": "Failed",
                            "children": [
                                {
                                    "nodeType": "Test Case",
                                    "name": "remoteManualInputPreservesLiteralAndNamedKeyOrder()",
                                    "identifier": "cmuxTests/RemoteTmuxMirrorPaneInputMappingTests/remoteManualInputPreservesLiteralAndNamedKeyOrder()",
                                    "result": "Failed",
                                },
                                {
                                    "nodeType": "Test Case",
                                    "name": "passingNeighbour()",
                                    "identifier": "cmuxTests/RemoteTmuxMirrorPaneInputMappingTests/passingNeighbour()",
                                    "result": "Passed",
                                },
                            ],
                        },
                        {
                            "nodeType": "Test Case",
                            "name": "parameterized(case:)",
                            "identifier": "cmuxTests/SearchTests/parameterized(case:)",
                            "testStatus": "failure",
                        },
                    ],
                }
            ],
        }
    ]
}


class ParserTests(unittest.TestCase):
    def write_log(self, text: str) -> Path:
        handle = tempfile.NamedTemporaryFile(
            "w", suffix=".log", delete=False, encoding="utf-8"
        )
        with handle:
            handle.write(text)
        return Path(handle.name)

    def write_json(self, payload: dict) -> Path:
        handle = tempfile.NamedTemporaryFile(
            "w", suffix=".json", delete=False, encoding="utf-8"
        )
        with handle:
            json.dump(payload, handle)
        return Path(handle.name)

    def run_main(self, argv: list[str]) -> tuple[int, list[str]]:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            status = parser_module.main(argv)
        return status, [line for line in buffer.getvalue().splitlines() if line]

    def test_swift_testing_function_name_maps_to_test_identifier(self):
        log = self.write_log(SWIFT_TESTING_FUNCTION_LOG)
        status, identifiers = self.run_main(["--log", str(log)])
        self.assertEqual(status, 0)
        self.assertEqual(
            identifiers,
            [
                "cmuxTests/RemoteTmuxMirrorPaneInputMappingTests/remoteManualInputPreservesLiteralAndNamedKeyOrder"
            ],
        )

    def test_unquoted_swift_testing_name_is_selected_precisely(self):
        # `✘ Test someFunction() recorded an issue at Suite.swift:…` is a function
        # signature plus the file that names its suite: rerun that test only.
        log = self.write_log(SWIFT_TESTING_DISPLAY_NAME_LOG)
        status, identifiers = self.run_main(["--log", str(log)])
        self.assertEqual(status, 0)
        self.assertEqual(
            identifiers,
            [
                "cmuxTests/SettingsWindowPresentationContractTests/closingTheWindowDuringTheDeminiaturizeWaitIsNotResurrected"
            ],
        )

    def test_quoted_display_name_without_a_file_is_left_to_the_xcresult(self):
        # The `failed after` summary line carries no file: it cannot name a suite,
        # so it must produce nothing rather than a guess.
        log = self.write_log(SWIFT_TESTING_QUOTED_NAME_LOG.splitlines()[1] + "\n")
        status, _ = self.run_main(["--log", str(log)])
        self.assertEqual(status, 3)

    def test_quoted_display_name_with_a_file_reruns_the_suite(self):
        log = self.write_log(
            "\n".join(SWIFT_TESTING_QUOTED_NAME_LOG.splitlines()[0:1]) + "\n"
        )
        status, identifiers = self.run_main(["--log", str(log)])
        self.assertEqual(status, 0)
        self.assertEqual(identifiers, ["cmuxTests/CloudPortRoutePlanTests"])

    def test_xctest_failure_maps_to_class_and_method(self):
        log = self.write_log(XCTEST_LOG)
        status, identifiers = self.run_main(["--log", str(log)])
        self.assertEqual(status, 0)
        self.assertEqual(
            identifiers, ["cmuxTests/WorkspaceUnitTests/testClosePanelKeepsFocus"]
        )

    def test_xcresult_walk_takes_failed_leaves_and_ignores_passed_ones(self):
        # Plan / target / suite nodes carry an aggregate failure; only the
        # selectable leaves may be rerun, parameter lists stripped.
        path = self.write_json(XCRESULT_JSON)
        status, identifiers = self.run_main(["--xcresult-json", str(path)])
        self.assertEqual(status, 0)
        self.assertEqual(
            identifiers,
            [
                "cmuxTests/RemoteTmuxMirrorPaneInputMappingTests/remoteManualInputPreservesLiteralAndNamedKeyOrder",
                "cmuxTests/SearchTests/parameterized",
            ],
        )

    def test_union_of_both_sources_and_suite_collapses_methods(self):
        log = self.write_log(SWIFT_TESTING_FUNCTION_LOG + SWIFT_TESTING_DISPLAY_NAME_LOG)
        path = self.write_json(
            {
                "testNodes": [
                    {
                        "nodeType": "Test Case",
                        "identifier": "cmuxTests/RemoteTmuxMirrorPaneInputMappingTests",
                        "result": "Failed",
                    }
                ]
            }
        )
        status, identifiers = self.run_main(
            ["--log", str(log), "--xcresult-json", str(path)]
        )
        self.assertEqual(status, 0)
        self.assertEqual(
            identifiers,
            [
                "cmuxTests/RemoteTmuxMirrorPaneInputMappingTests",
                "cmuxTests/SettingsWindowPresentationContractTests/closingTheWindowDuringTheDeminiaturizeWaitIsNotResurrected",
            ],
        )

    def test_nothing_found_is_an_error_not_a_pass(self):
        log = self.write_log("all green here\n")
        status, identifiers = self.run_main(["--log", str(log)])
        self.assertEqual(status, 3)
        self.assertEqual(identifiers, [])

    def test_missing_sources_is_an_invocation_error(self):
        status, _ = self.run_main([])
        self.assertEqual(status, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
