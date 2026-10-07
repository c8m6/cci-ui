"""Synthetic lookup fixtures; no registry requests or production data."""

import json
import unittest

from dependency_report import collect, render


class DependencyReportTest(unittest.TestCase):
    def log(self, deps):
        return json.dumps({"msg": "packageFiles with updates", "config": {
            "bundler": [{"packageFile": "Gemfile", "deps": deps}]
        }})

    def test_major_and_minor_are_separated_and_locked_version_is_used(self):
        data = collect(self.log([{"depName": "example", "currentValue": "~> 1.0",
            "lockedVersion": "1.1.0", "updates": [
                {"newVersion": "2.0.0", "updateType": "major"},
                {"newVersion": "1.2.0", "updateType": "minor"}]}]))
        text, incomplete = render(data, "ruby", "abc")
        major, other = text.split("## Other update candidates")
        self.assertIn("2.0.0", major)
        self.assertNotIn("1.2.0", major)
        self.assertIn("1.2.0", other)
        self.assertEqual(data["dependencies"][0]["current"], "1.1.0")
        self.assertFalse(incomplete)

    def test_empty_or_changed_log_cannot_report_success(self):
        for log in ["", "not json", '{"msg":"new format"}', self.log([])]:
            with self.assertRaises(ValueError):
                collect(log)

    def test_lookup_warnings_and_skip_reasons_are_incomplete(self):
        for problem in [{"warnings": [{"message": "unreachable"}]},
                        {"skipReason": "invalid-value"}]:
            data = collect(self.log([{"depName": "example", **problem}]))
            text, incomplete = render(data, "ruby", "abc")
            self.assertTrue(incomplete)
            self.assertIn("**incomplete**", text)

    def test_global_warning_and_failed_process_are_incomplete(self):
        data = collect(self.log([{"depName": "example"}]) + "\n" +
                       json.dumps({"level": 40, "msg": "Registry unreachable"}))
        self.assertTrue(render(data, "all", "abc")[1])
        data["warning_count"] = 0
        self.assertTrue(render(data, "all", "abc", failed=True)[1])

    def test_sensitive_raw_config_is_not_copied_and_markdown_is_escaped(self):
        log = json.loads(self.log([{"depName": "<example>|name", "token": "secret",
                                   "registryUrl": "https://user:secret@example.invalid"}]))
        log["token"] = "top-secret"
        data = collect(json.dumps(log))
        text, _ = render(data, "all", "abc")
        self.assertNotIn("secret", json.dumps(data) + text)
        self.assertIn("&lt;example&gt;&#124;name", text)

    def test_same_tag_digest_candidate_preserves_target(self):
        data = collect(self.log([{"depName": "example", "currentValue": "v1",
            "currentDigest": "sha256:old", "updates": [{"newValue": "v1",
                "newDigest": "sha256:new", "updateType": "digest"}]}]))
        self.assertIn("sha256:new", render(data, "actions", "abc")[0])


if __name__ == "__main__":
    unittest.main()
