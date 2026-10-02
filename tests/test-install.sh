#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cumob-installer-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
export CODEX_HOME="$TEST_ROOT/.codex"
export CLAUDE_HOME="$TEST_ROOT/.claude"
mkdir -p "$CODEX_HOME/skills/cumob-media-generation4codex" "$CODEX_HOME/skills/cumob-image-generation4codex" "$CODEX_HOME/model-catalogs"
if [ "${CUMOB_LIVE_TEST:-0}" != "1" ]; then
  fixture_skill="$TEST_ROOT/fixture-skill"
  mkdir -p "$fixture_skill/scripts"
  cat > "$fixture_skill/SKILL.md" <<'SKILL'
---
name: cumob-media-generation
description: Installer test fixture.
---
SKILL
  printf '%s\n' "test-fixture" > "$fixture_skill/VERSION"
  printf '%s\n' 'print("test fixture")' > "$fixture_skill/scripts/generate-image.py"
  export CUMOB_SKILL_SOURCE_DIR="$fixture_skill"
  export EXPECTED_SKILL_VERSION="test-fixture"
else
  unset CUMOB_SKILL_SOURCE_DIR || true
  export EXPECTED_SKILL_VERSION=""
fi
fixture_remote="$TEST_ROOT/remote-fixture"
mkdir -p "$fixture_remote/payload" "$fixture_remote/scripts"
cp "$ROOT_DIR/payload/cumob-models.json" "$fixture_remote/payload/cumob-models.json"
cp "$ROOT_DIR/payload/cumob-config.template.toml" "$fixture_remote/payload/cumob-config.template.toml"
cp "$ROOT_DIR/scripts/merge-config.awk" "$fixture_remote/scripts/merge-config.awk"
cp "$ROOT_DIR/scripts/merge-auth.mjs" "$fixture_remote/scripts/merge-auth.mjs"
cp "$ROOT_DIR/scripts/merge_auth.py" "$fixture_remote/scripts/merge_auth.py"
to_file_url() {
  python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().as_uri())' "$1"
}
export CUMOB_MODELS_URL="$(to_file_url "$fixture_remote/payload/cumob-models.json")"
export CUMOB_CONFIG_TEMPLATE_URL="$(to_file_url "$fixture_remote/payload/cumob-config.template.toml")"
export CUMOB_MERGE_AWK_URL="$(to_file_url "$fixture_remote/scripts/merge-config.awk")"
export CUMOB_MERGE_AUTH_MJS_URL="$(to_file_url "$fixture_remote/scripts/merge-auth.mjs")"
export CUMOB_MERGE_AUTH_PY_URL="$(to_file_url "$fixture_remote/scripts/merge_auth.py")"
printf '%s\n' "old skill" > "$CODEX_HOME/skills/cumob-image-generation4codex/OLD.txt"
printf '%s\n' "renamed old skill" > "$CODEX_HOME/skills/cumob-media-generation4codex/OLD.txt"
cat > "$CODEX_HOME/config.toml" <<'CFG'
model_provider = "old-provider"
model = "old-model"
model_catalog_json = "/old/path/models.json"
model_reasoning_effort = "low"

[model_providers]
[model_providers.cumob]
name = "old-cumob"
base_url = "https://old.invalid/v1"

[model_providers.other]
name = "keep-me"
base_url = "https://example.test/v1"

[desktop]
localeOverride = "zh-CN"
CFG
cat > "$CODEX_HOME/auth.json" <<'AUTH'
{
  "OPENAI_API_KEY": "old-key",
  "OTHER_AUTH_FIELD": "keep-me"
}
AUTH
export CUMOB_INSTALL_API_KEY="test-key-one"
bash "$ROOT_DIR/install.sh" --no-prompt >/dev/null
node - "$CODEX_HOME" "$ROOT_DIR/payload/cumob-models.json" <<'NODE'
const fs = require("fs");
const path = require("path");
const home = process.argv[2];
const sourceCatalog = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const config = fs.readFileSync(path.join(home, "config.toml"), "utf8");
const auth = JSON.parse(fs.readFileSync(path.join(home, "auth.json"), "utf8"));
const catalog = JSON.parse(fs.readFileSync(path.join(home, "model-catalogs", "cumob-models.json"), "utf8"));
const version = fs.readFileSync(path.join(home, "skills", "cumob-media-generation", "VERSION"), "utf8").trim();
const expectedVersion = process.env.EXPECTED_SKILL_VERSION;
function count(pattern) { return (config.match(pattern) || []).length; }
if (fs.existsSync(path.join(home, "skills", "cumob-image-generation4codex"))) throw new Error("legacy Skill directory was not removed");
const backupRoot = path.join(home, "backups");
const legacyWasBackedUp = fs.readdirSync(backupRoot).some((entry) =>
  fs.existsSync(path.join(backupRoot, entry, "cumob-image-generation4codex", "OLD.txt"))
);
if (!legacyWasBackedUp) throw new Error("legacy Skill directory was not backed up");
const renamedSkillWasBackedUp = fs.readdirSync(backupRoot).some((entry) =>
  fs.existsSync(path.join(backupRoot, entry, "cumob-media-generation4codex", "OLD.txt"))
);
if (!renamedSkillWasBackedUp) throw new Error("renamed legacy Skill directory was not backed up");
if (fs.existsSync(path.join(home, "skills", "cumob-media-generation4codex"))) throw new Error("renamed legacy Skill directory was not removed");
if (count(/^model_provider\s*=/gm) !== 1) throw new Error("model_provider is not unique");
if (count(/^\[model_providers\.cumob\]$/gm) !== 1) throw new Error("CUMOB table is not unique");
if (!config.includes('[model_providers.other]')) throw new Error("other provider was removed");
if (!config.includes('localeOverride = "zh-CN"')) throw new Error("desktop settings were removed");
if (!config.includes('video_api = "videos"')) throw new Error("video_api was not installed");
if (!config.includes('video_model = "minimax-h3-2k"')) throw new Error("video model was not installed");
const catalogMatch = config.match(/^model_catalog_json\s*=\s*"([^"]+)"$/m);
if (!catalogMatch) throw new Error("catalog path was not generated");
const expectedCatalog = fs.realpathSync(path.join(home, "model-catalogs", "cumob-models.json"));
const configuredCatalog = fs.realpathSync(catalogMatch[1]);
if (configuredCatalog !== expectedCatalog) throw new Error("catalog path points to the wrong file");
if (auth.OPENAI_API_KEY !== "test-key-one") throw new Error("API key was not updated");
if (auth.OTHER_AUTH_FIELD !== "keep-me") throw new Error("auth fields were not preserved");
if (!Array.isArray(catalog.models) || catalog.models.length !== sourceCatalog.models.length) throw new Error("model catalog was not installed");
const sourceSlugs = sourceCatalog.models.map((model) => model.slug).sort();
const installedSlugs = catalog.models.map((model) => model.slug).sort();
if (JSON.stringify(installedSlugs) !== JSON.stringify(sourceSlugs)) throw new Error("installed model catalog differs from source catalog");
const expectedDefault = sourceCatalog.models
  .filter((model) => model.supported_in_api === true && model.visibility === "list")
  .sort((a, b) => a.priority - b.priority)[0];
const configuredModel = config.match(/^model\s*=\s*"([^"]+)"$/m);
if (!configuredModel || configuredModel[1] !== expectedDefault.slug) throw new Error("default model was not derived from the catalog");
const configuredReasoning = config.match(/^model_reasoning_effort\s*=\s*"([^"]+)"$/m);
if (!configuredReasoning || configuredReasoning[1] !== expectedDefault.default_reasoning_level) throw new Error("default reasoning level was not derived from the catalog");
if (expectedVersion && version !== expectedVersion) throw new Error("skill version mismatch");
if (!version) throw new Error("installed skill version is empty");
NODE
REMOTE_ONLY_DIR="$TEST_ROOT/remote-only-installer"
mkdir -p "$REMOTE_ONLY_DIR"
cp "$ROOT_DIR/install.sh" "$REMOTE_ONLY_DIR/install.sh"
node - "$fixture_remote/payload/cumob-models.json" "$TEST_ROOT/removed-default.txt" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const catalog = JSON.parse(fs.readFileSync(file, "utf8"));
const eligible = catalog.models.filter((model) => model.supported_in_api === true && model.visibility === "list");
const oldDefault = eligible.sort((a, b) => a.priority - b.priority)[0];
fs.writeFileSync(process.argv[3], oldDefault.slug);
catalog.models = catalog.models.filter((model) => model.slug !== oldDefault.slug);
fs.writeFileSync(file, JSON.stringify(catalog, null, 2) + "\n");
NODE
export CUMOB_INSTALL_API_KEY="test-key-two"
bash "$REMOTE_ONLY_DIR/install.sh" --no-prompt >/dev/null
node - "$CODEX_HOME" "$fixture_remote/payload/cumob-models.json" "$TEST_ROOT/removed-default.txt" <<'NODE'
const fs = require("fs");
const path = require("path");
const home = process.argv[2];
const config = fs.readFileSync(path.join(home, "config.toml"), "utf8");
const auth = JSON.parse(fs.readFileSync(path.join(home, "auth.json"), "utf8"));
const backups = fs.readdirSync(path.join(home, "backups"));
if ((config.match(/^model_provider\s*=/gm) || []).length !== 1) throw new Error("reinstall duplicated model_provider");
if ((config.match(/^\[model_providers\.cumob\]$/gm) || []).length !== 1) throw new Error("reinstall duplicated CUMOB table");
if (auth.OPENAI_API_KEY !== "test-key-two") throw new Error("reinstall did not update API key");
const source = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const installed = JSON.parse(fs.readFileSync(path.join(home, "model-catalogs", "cumob-models.json"), "utf8"));
const removed = fs.readFileSync(process.argv[4], "utf8");
const selected = source.models.filter((model) => model.supported_in_api === true && model.visibility === "list")
  .sort((a, b) => a.priority - b.priority)[0];
if (!selected || !config.includes(`model = "${selected.slug}"`)) throw new Error("remote catalog deletion did not update the default model");
if (installed.models.some((model) => model.slug === removed)) throw new Error("removed model remains installed");
if (backups.length < 2) throw new Error("reinstall did not create a second backup");
NODE
if [ "${CUMOB_LIVE_TEST:-0}" = "1" ]; then
  node "$CODEX_HOME/skills/cumob-media-generation/scripts/generate-image.mjs" \
    --prompt "Installer configuration check" \
    --out "$TEST_ROOT/unused.png" \
    --dry-run > "$TEST_ROOT/dry-run.json"
  node - "$TEST_ROOT/dry-run.json" <<'NODE'
const fs = require("fs");
const output = fs.readFileSync(process.argv[2], "utf8");
if (!output.includes('"image_api": "images"')) throw new Error("image_api was not loaded");
if (!output.includes('"image_model": "gpt-image-2.5"')) throw new Error("image model was not loaded");
if (!output.includes('"has_api_key": true')) throw new Error("API key was not detected");
if (output.includes("test-key-two")) throw new Error("dry-run leaked the API key");
NODE
fi

# No-prompt installs use the default .com endpoint even if config previously used .cn.
python3 - "$CODEX_HOME" <<'NODE'
from pathlib import Path
import sys
config = Path(sys.argv[1]) / "config.toml"
text = config.read_text()
text = text.replace('base_url = "https://api.cumob.com/v1"', 'base_url = "https://api.cumob.cn/v1"')
config.write_text(text)
NODE
bash "$ROOT_DIR/install.sh" --no-prompt >/dev/null
python3 - "$CODEX_HOME" <<'NODE'
from pathlib import Path
import sys
config = (Path(sys.argv[1]) / "config.toml").read_text()
if 'base_url = "https://api.cumob.com/v1"' not in config:
    raise SystemExit('no-prompt reinstall did not fall back to the default api.cumob.com endpoint')
NODE

# CUMOB_BASE_URL override selects .cn and skips the prompt.
CUMOB_BASE_URL="https://api.cumob.cn/v1" bash "$ROOT_DIR/install.sh" --no-prompt >/dev/null
python3 - "$CODEX_HOME" <<'NODE'
from pathlib import Path
import sys
config = (Path(sys.argv[1]) / "config.toml").read_text()
if 'base_url = "https://api.cumob.cn/v1"' not in config:
    raise SystemExit('CUMOB_BASE_URL override did not select api.cumob.cn')
NODE

# CUMOB_BASE_URL override can also force .com again.
CUMOB_BASE_URL="https://api.cumob.com/v1" bash "$ROOT_DIR/install.sh" --no-prompt >/dev/null
python3 - "$CODEX_HOME" <<'NODE'
from pathlib import Path
import sys
config = (Path(sys.argv[1]) / "config.toml").read_text()
if 'base_url = "https://api.cumob.com/v1"' not in config:
    raise SystemExit('CUMOB_BASE_URL override was ignored')
NODE

printf '%s\n' "macOS/Linux installer integration test passed."
