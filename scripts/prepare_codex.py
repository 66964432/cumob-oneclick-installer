"""Read-only remote catalog preflight for machines without Node.js 18+."""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

MAX_BYTES = 1024 * 1024


def check_config(path):
    if not path.exists():
        return
    section = ""
    profiles = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        line = re.sub(r'^(\s*)["\'](model_provider|model_catalog_json|features|api_key_model_discovery)["\'](?=\s*[=.])', r"\1\2", line)
        header = re.match(r"^\s*\[([^\[\]]+)\]\s*(?:#.*)?$", line)
        if header:
            section = re.sub(r"[\s\"']", "", header[1])
            continue
        if not section and re.match(r"^\s*features\s*=", line):
            raise ValueError("Inline features configuration is not supported by this installer. Convert it to a [features] table first.")
        if not section and re.match(r"^\s*features\.", line) and not re.match(r"^\s*features\.api_key_model_discovery\s*=", line):
            raise ValueError("Dotted features configuration is not supported by this installer. Convert it to a [features] table first.")
        if section.startswith("profiles."):
            name = section.split(".")[1]
            profile = profiles.setdefault(name, {})
            if re.fullmatch(r"profiles\.[^.]+", section):
                provider = re.match(r"^\s*model_provider\s*=\s*[\"']([^\"']+)[\"']", line)
                if provider:
                    profile["provider"] = provider[1]
                if re.match(r"^\s*model_catalog_json\s*=", line):
                    profile["local"] = True
                if re.match(r"^\s*features\.api_key_model_discovery\s*=\s*false\b", line):
                    profile["disabled"] = True
            if re.fullmatch(r"profiles\.[^.]+\.features", section) and re.match(r"^\s*api_key_model_discovery\s*=\s*false\b", line):
                profile["disabled"] = True
    for name, profile in profiles.items():
        if profile.get("provider", "cumob") == "cumob" and (profile.get("local") or profile.get("disabled")):
            raise ValueError(f"Profile {name} overrides remote model discovery. Remove its model_catalog_json / disabled api_key_model_discovery setting, then retry. Other providers are left unchanged.")


def read_key(path):
    auth = {}
    if path.exists():
        try:
            auth = json.loads(path.read_text(encoding="utf-8-sig"))
        except ValueError:
            raise ValueError("Invalid auth.json. Repair it before installing; existing files were not changed.") from None
        if not isinstance(auth, dict):
            raise ValueError("auth.json must contain a JSON object.")
    key = os.environ.get("CUMOB_INSTALL_API_KEY") or auth.get("OPENAI_API_KEY")
    if not isinstance(key, str) or not key.strip() or re.search(r"[\r\n]", key):
        raise ValueError("A CUMOB API Key is required to validate the remote catalog. Supply a key or keep an existing OPENAI_API_KEY in auth.json.")
    return key


def client_version():
    version = os.environ.get("CUMOB_CODEX_CLIENT_VERSION")
    if not version:
        commands = ["codex"]
        if sys.platform == "darwin":
            commands.append("/Applications/Codex.app/Contents/Resources/codex")
        for command in commands:
            try:
                result = subprocess.run([command, "--version"], capture_output=True, text=True, timeout=3)
                match = re.search(r"\b\d+\.\d+\.\d+\b", result.stdout)
                if match:
                    version = match[0]
                    break
            except (OSError, subprocess.TimeoutExpired):
                continue
    if version and not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("CUMOB_CODEX_CLIENT_VERSION must use major.minor.patch.")
    return version


def select_default(catalog):
    models = catalog.get("models") if isinstance(catalog, dict) else None
    if not isinstance(models, list) or not models:
        raise ValueError("Remote catalog must contain a nonempty models array.")
    slugs = set()
    eligible = []
    for model in models:
        slug = model.get("slug") if isinstance(model, dict) else None
        if not isinstance(slug, str) or not re.fullmatch(r"[A-Za-z0-9._:/-]+", slug) or slug in slugs:
            raise ValueError("Remote catalog contains an invalid or duplicate model slug.")
        slugs.add(slug)
        if isinstance(model.get("priority"), bool) or not isinstance(model.get("priority"), int) or not isinstance(model.get("display_name"), str) or not model["display_name"].strip():
            raise ValueError("Remote catalog contains an invalid priority or display_name.")
        if model.get("supported_in_api") is not True or model.get("visibility") != "list":
            continue
        effort = model.get("default_reasoning_level")
        levels = model.get("supported_reasoning_levels")
        if not isinstance(effort, str) or not re.fullmatch(r"[a-z]+", effort) or not isinstance(levels, list) or effort not in [level.get("effort") for level in levels if isinstance(level, dict)]:
            raise ValueError("Remote catalog contains an unsupported default reasoning level.")
        eligible.append(model)
    if not eligible:
        raise ValueError("Remote catalog has no visible API-supported default model.")
    return min(eligible, key=lambda model: model["priority"])


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    config_path, auth_path, catalog_url = sys.argv[1:]
    check_config(Path(config_path))
    key = read_key(Path(auth_path))
    url = urllib.parse.urlsplit(catalog_url)
    if url.scheme != "https" or url.netloc not in ("api.cumob.com", "api.cumob.cn") or url.path != "/v1/codex/models" or url.query or url.fragment:
        raise ValueError("Catalog URL must be the selected CUMOB HTTPS /v1/codex/models endpoint.")
    version = client_version()
    if version:
        catalog_url += "?" + urllib.parse.urlencode({"client_version": version})
    else:
        print("Codex version was not detected; requesting the server's default catalog. Keep Codex updated to use remote model discovery.", file=sys.stderr)
    request = urllib.request.Request(catalog_url, headers={"Authorization": "Bearer " + key, "Accept": "application/json"})
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=20) as response:
            raw = response.read(MAX_BYTES + 1)
    except urllib.error.HTTPError as error:
        raise ValueError(f"Remote catalog request failed (HTTP {error.code}). Check your API Key and CUMOB endpoint; redirects are not followed.") from None
    except (OSError, urllib.error.URLError):
        raise ValueError("Remote catalog request failed (network error or timeout). Existing Codex files were not changed.") from None
    if len(raw) > MAX_BYTES:
        raise ValueError("Remote catalog exceeds the 1 MiB limit.")
    try:
        catalog = json.loads(raw)
    except (ValueError, UnicodeError):
        raise ValueError("Remote catalog did not return valid JSON.") from None
    model = select_default(catalog)
    print(f'{model["slug"]}\t{model["default_reasoning_level"]}')


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        print(f"Codex preflight failed: {error}", file=sys.stderr)
        sys.exit(1)
