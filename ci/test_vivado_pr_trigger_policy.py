from __future__ import annotations

import re
import unittest
from pathlib import Path


WORKFLOW = (
    Path(__file__).resolve().parents[1]
    / ".github"
    / "workflows"
    / "vivado-frs-route.yml"
).read_text(encoding="utf-8")


class VivadoPullRequestPolicyTests(unittest.TestCase):
    def test_uses_base_workflow_for_pull_request_target_only(self) -> None:
        self.assertIn("pull_request_target:", WORKFLOW)
        self.assertNotRegex(WORKFLOW, r"(?m)^\s+pull_request:")
        self.assertIn("branches: [main]", WORKFLOW)

    def test_fork_and_non_owner_prs_are_filtered_before_runner_assignment(self) -> None:
        job = WORKFLOW.split("  route-both-profiles:", 1)[1].split("\n    runs-on:", 1)[0]
        self.assertIn("head.repo.full_name == github.repository", job)
        self.assertIn("pull_request.user.login == 'graniteset'", job)

    def test_environment_approval_and_minimal_permissions_are_retained(self) -> None:
        self.assertRegex(WORKFLOW, r"(?m)^permissions:\n  contents: read$")
        self.assertRegex(WORKFLOW, r"(?m)^    environment: vivado-ooc$")

    def test_checks_out_full_pr_head_sha_without_persisting_credentials(self) -> None:
        self.assertIn("PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}", WORKFLOW)
        self.assertIn("ref: ${{ steps.verify.outputs.target_sha }}", WORKFLOW)
        self.assertIn("persist-credentials: false", WORKFLOW)
        self.assertIn('git rev-parse HEAD', WORKFLOW)
        self.assertRegex(WORKFLOW, r"\[\[ \"\$\{actual,,\}\" == \"\$\{TARGET_SHA,,\}\" \]\]")

    def test_preserves_both_profiles_and_existing_report_gate(self) -> None:
        self.assertIn("for mode in 1 0; do", WORKFLOW)
        self.assertIn("ci/check_vivado_route_reports.py", WORKFLOW)
        self.assertIn('exit "$any_failed"', WORKFLOW)
        self.assertIn("Upload routed build evidence", WORKFLOW)

    def test_dispatch_still_requires_typed_exact_sha(self) -> None:
        self.assertIn("CONFIRM_SHA", WORKFLOW)
        self.assertIn('"${CONFIRM_SHA,,}" == "${DISPATCH_SHA,,}"', WORKFLOW)


if __name__ == "__main__":
    unittest.main()
