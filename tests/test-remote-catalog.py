"""Exercise both POSIX preflights and TOML merging with offline transports."""
import copy
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cumob-catalog-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "config.toml"
        self.auth = self.root / "auth.json"
        self.catalog = self.root / "catalog.json"
        self.requests = self.root / "requests.log"
        self.config.write_text('[features]\napi_key_model_discovery = false\nother_flag = true\n')
        self.auth.write_text('{"OPENAI_API_KEY":"fixture-key","OTHER":"keep"}')
        self.data = {"models": [{"slug": "remote-only-model", "display_name": "Remote model", "priority": 1,
                                 "supported_in_api": True, "visibility": "list", "default_reasoning_level": "high",
                                 "supported_reasoning_levels": [{"effort": "high"}]}]}
        self.env = dict(os.environ, CUMOB_TEST_CATALOG=str(self.catalog), CUMOB_TEST_EXPECTED_KEY="fixture-key",
                        CUMOB_TEST_REQUESTS=str(self.requests), CUMOB_CODEX_CLIENT_VERSION="0.162.1",
                        PYTHONDONTWRITEBYTECODE="1", PYTHONPATH=str(ROOT / "tests/python-fixture"),
                        NODE_OPTIONS="--import=" + str(ROOT / "tests/mock-catalog.mjs"))
        self.env.pop("CUMOB_INSTALL_API_KEY", None)
        self.env.pop("CUMOB_TEST_MODE", None)

    def run_helpers(self, ok=True, expected="remote-only-model\thigh", url="https://api.cumob.com/v1/codex/models", error=None):
        self.catalog.write_text(json.dumps(self.data))
        before = {file: file.read_bytes() for file in (self.auth, self.config)}
        for command in (["node", str(ROOT / "scripts/prepare-codex.mjs")],
                        ["python3", str(ROOT / "scripts/prepare_codex.py")]):
            with self.subTest(helper=command[-1]):
                result = subprocess.run(command + [str(self.config), str(self.auth), url], env=self.env,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
                self.assertNotIn("fixture-key", result.stdout + result.stderr)
                if ok:
                    self.assertEqual(result.stdout.strip(), expected)
                elif error:
                    self.assertIn(error, result.stderr)
                for file, contents in before.items():
                    self.assertEqual(file.read_bytes(), contents)

    def test_single_model_and_existing_auth(self):
        self.run_helpers()

    def test_supplied_key_and_cn(self):
        self.env["CUMOB_INSTALL_API_KEY"] = "different-key"
        self.env["CUMOB_TEST_EXPECTED_KEY"] = "different-key"
        self.run_helpers(url="https://api.cumob.cn/v1/codex/models")

    def test_visible_default_uses_lowest_priority(self):
        hidden = copy.deepcopy(self.data["models"][0])
        hidden.update(slug="hidden-model", visibility="hide", priority=-10)
        second = copy.deepcopy(self.data["models"][0])
        second.update(slug="new-default", priority=0)
        self.data["models"] += [hidden, second]
        self.run_helpers(expected="new-default\thigh")

    def test_equal_priorities_are_valid(self):
        second = copy.deepcopy(self.data["models"][0])
        second["slug"] = "second-model"
        self.data["models"].append(second)
        self.run_helpers()

    def test_transport_errors(self):
        for mode in ("401", "redirect", "timeout", "invalid-json", "oversize"):
            with self.subTest(mode=mode):
                self.env["CUMOB_TEST_MODE"] = mode
                self.run_helpers(ok=False, error="Remote catalog")

    def test_invalid_catalogs(self):
        valid = copy.deepcopy(self.data)
        cases = [{}, {"models": []}, {"models": [None]}, {"data": valid["models"]}]
        for field, value in (("slug", 'bad"slug'), ("slug", ""), ("priority", True),
                             ("priority", 1.5), ("display_name", ""), ("default_reasoning_level", "low"),
                             ("supported_reasoning_levels", []), ("supported_in_api", False)):
            case = copy.deepcopy(valid)
            case["models"][0][field] = value
            cases.append(case)
        duplicate = copy.deepcopy(valid)
        duplicate["models"] *= 2
        cases.append(duplicate)
        for data in cases:
            with self.subTest(data=data):
                self.data = data
                self.run_helpers(ok=False, error="Remote catalog")

    def test_missing_and_malformed_auth(self):
        for auth in ("{}", "[]", "null", "not JSON", '{"OPENAI_API_KEY":42}'):
            with self.subTest(auth=auth):
                self.auth.write_text(auth)
                self.run_helpers(ok=False)

    def test_relevant_profiles_block_before_request(self):
        for content in ('[profiles.work]\nmodel_catalog_json = "/old.json"\n',
                        '[profiles.work.features]\napi_key_model_discovery = false\n',
                        '[profiles.work]\n"model_catalog_json" = "/old.json"\n',
                        '[profiles.work]\nmodel_provider = "cumob"\nfeatures.api_key_model_discovery = false\n'):
            with self.subTest(content=content):
                self.config.write_text(content)
                self.run_helpers(ok=False, error="Profile work")
                self.assertFalse(self.requests.exists())

    def test_other_provider_profile_preserved(self):
        self.config.write_text('[profiles.other]\nmodel_provider = "other"\nmodel_catalog_json = "/other.json"\n')
        self.run_helpers()

    def test_unsafe_destinations_never_receive_credentials(self):
        for url in ("https://untrusted.invalid/v1/codex/models", "http://api.cumob.com/v1/codex/models",
                    "https://api.cumob.com:444/v1/codex/models", "https://api.cumob.com/v1/codex/models?extra=1"):
            with self.subTest(url=url):
                self.run_helpers(ok=False, url=url, error="Catalog URL")
                self.assertFalse(self.requests.exists())

    def test_unsupported_feature_syntax_is_actionable(self):
        for text in ('features = { other = true }\n', 'features.other = true\n'):
            self.config.write_text(text)
            self.run_helpers(ok=False, error="[features] table")

    def test_toml_merge_preserves_other_settings(self):
        import tomllib
        for original in ("", '"model_catalog_json" = "/old.json"\n', '[features]\napi_key_model_discovery = false\nother = true\n',
                         'features.api_key_model_discovery = false\n[desktop]\nlocale = "zh-CN"\n',
                         '["features"]\n"api_key_model_discovery" = false\nother = true\n'):
            with self.subTest(original=original):
                self.config.write_text(original)
                filtered = subprocess.check_output(["awk", "-f", str(ROOT / "scripts/merge-config.awk"), str(self.config)], text=True)
                template = (ROOT / "payload/cumob-config.template.toml").read_text().replace("{{DEFAULT_MODEL}}", "remote-only-model").replace("{{DEFAULT_REASONING_LEVEL}}", "high").replace("{{CUMOB_BASE_URL}}", "https://api.cumob.com/v1")
                result = tomllib.loads(template + "\n" + filtered)
                self.assertTrue(result["features"]["api_key_model_discovery"])
                self.assertNotIn("model_catalog_json", result)
                self.assertEqual(result["model_providers"]["cumob"]["model_catalog_url"], "https://api.cumob.com/v1/codex/models")
                old = tomllib.loads(original)
                if "other" in old.get("features", {}): self.assertTrue(result["features"]["other"])
                if "desktop" in old: self.assertEqual(result["desktop"], old["desktop"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
