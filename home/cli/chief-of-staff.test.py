#!/usr/bin/env python3
"""Structural skill regressions; not a test of autonomous agent scheduling."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent
CANONICAL = ROOT / "chief-of-staff"
LEGACY = ROOT / "herdr-coordinate"
STATES = {
    "queued", "active", "reviewing", "integrating", "blocked", "paused",
    "done", "cancelled",
}


class ChiefOfStaffSkillTests(unittest.TestCase):
    def test_portable_skill_frontmatter(self):
        for directory in (CANONICAL, LEGACY):
            with self.subTest(skill=directory.name):
                content = (directory / "SKILL.md").read_text()
                self.assertTrue(content.startswith("---\n"))
                frontmatter = content.split("---\n", 2)[1]
                fields = dict(line.split(": ", 1) for line in frontmatter.splitlines())
                self.assertEqual(fields["name"], directory.name)
                self.assertRegex(fields["name"], r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
                self.assertLessEqual(len(fields["name"]), 64)
                self.assertTrue(fields["description"].strip())
                self.assertLessEqual(len(fields["description"]), 1024)

    def test_bundled_references_resolve(self):
        links = []
        for path in CANONICAL.rglob("*.md"):
            for link in re.findall(r"\[[^\]]+\]\(([^)]+)\)", path.read_text()):
                target = (path.parent / link).resolve()
                self.assertTrue(target.is_relative_to(CANONICAL.resolve()))
                self.assertTrue(target.is_file(), f"Missing reference: {path}: {link}")
                links.append(target)
        self.assertEqual(set(links), {
            CANONICAL / "references/herdr-workflow.md",
            CANONICAL / "templates/portfolio.md",
            CANONICAL / "templates/task.md",
        })

    def test_alias_has_no_second_execution_contract(self):
        alias = (LEGACY / "SKILL.md").read_text()
        self.assertIn("~/.agents/skills/chief-of-staff/SKILL.md", alias)
        self.assertIn("Reuse the current conversation's portfolio", alias)
        self.assertNotIn("hc run", alias)
        self.assertNotIn("../chief-of-staff", alias)  # Separate Nix store roots.
        metadata = (LEGACY / "agents/openai.yaml").read_text()
        self.assertIn("$chief-of-staff", metadata)
        self.assertIn("allow_implicit_invocation: false", metadata)

    def test_states_and_record_templates(self):
        skill = (CANONICAL / "SKILL.md").read_text()
        declared = set(re.findall(r"^\| `([a-z]+)` \|", skill, re.MULTILINE))
        self.assertEqual(declared, STATES)
        portfolio = (CANONICAL / "templates/portfolio.md").read_text()
        task = (CANONICAL / "templates/task.md").read_text()
        for field in ("Coordinator terminal", "Owning core", "Dependencies",
                      "Live worker inventory", "Handoff / recovery"):
            self.assertIn(field, portfolio)
        for field in ("State: queued", "Previous stage", "Original user request",
                      "Acceptance checks", "Baseline and isolation",
                      "Assignments and launch intents", "Integration and verification"):
            self.assertIn(field, task)

    def test_exact_worker_models_and_safety_contract_survive(self):
        contract = (CANONICAL / "references/herdr-workflow.md").read_text()
        for model in ("grok-4.7-high", "grok-4.7-xhigh", "composer-2.5", "gpt-6-astra"):
            self.assertIn(model, contract)
        for safeguard in ("never silently", "Workers must not delegate",
                          "first_message.sent", "Never force-send into a permission",
                          "without committing, stashing or", "Never stop/restart core"):
            self.assertIn(safeguard, contract)
        self.assertNotIn("The mode ends\nwith the task", contract)

    def test_client_neutral_roles_and_canonical_codex_metadata(self):
        for filename in ("implementer.md", "reviewer.md"):
            role = (LEGACY / filename).read_text()
            self.assertIn("chief-of-staff-coordinated", role)
            self.assertNotIn("Codex-coordinated", role)
        metadata = (CANONICAL / "agents/openai.yaml").read_text()
        self.assertIn('display_name: "Chief of staff"', metadata)
        self.assertIn("$chief-of-staff", metadata)
        self.assertIn("allow_implicit_invocation: false", metadata)


if __name__ == "__main__":
    unittest.main()
