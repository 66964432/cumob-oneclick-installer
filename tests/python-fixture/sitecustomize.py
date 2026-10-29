"""Offline transport fixture for the Python fallback integration test only."""
import io
import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

if os.environ.get("CUMOB_TEST_CATALOG"):
    class FixtureOpener:
        def open(self, request, timeout):
            url = urllib.parse.urlsplit(request.full_url)
            assert url.netloc in ("api.cumob.com", "api.cumob.cn")
            assert url.scheme == "https" and url.path == "/v1/codex/models"
            assert timeout == 20
            assert request.get_header("Authorization") == "Bearer " + os.environ["CUMOB_TEST_EXPECTED_KEY"]
            assert urllib.parse.parse_qs(url.query)["client_version"] == [os.environ["CUMOB_CODEX_CLIENT_VERSION"]]
            if os.environ.get("CUMOB_TEST_REQUESTS"):
                with open(os.environ["CUMOB_TEST_REQUESTS"], "a") as output:
                    output.write(request.full_url + "\n")
            mode = os.environ.get("CUMOB_TEST_MODE")
            if mode in ("401", "redirect"):
                raise urllib.error.HTTPError(request.full_url, 401 if mode == "401" else 302, "fixture", {}, None)
            if mode == "timeout":
                raise TimeoutError("fixture")
            if mode == "invalid-json":
                return io.BytesIO(b"not JSON")
            if mode == "oversize":
                return io.BytesIO(b" " * (1024 * 1024 + 1))
            return io.BytesIO(Path(os.environ["CUMOB_TEST_CATALOG"]).read_bytes())

    def build_fixture(*handlers):
        assert len(handlers) == 1
        assert handlers[0].redirect_request(None, None, 302, "", {}, "https://untrusted.invalid") is None
        return FixtureOpener()

    urllib.request.build_opener = build_fixture
