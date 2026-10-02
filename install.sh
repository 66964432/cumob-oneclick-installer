#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$SCRIPT_DIR/payload"
DEFAULT_INSTALLER_ARCHIVE_URL="https://github.com/66964432/cumob-oneclick-installer/archive/refs/heads/main.zip"
DEFAULT_SKILL_ARCHIVE_URL="https://github.com/66964432/cumob-media-generation/archive/refs/heads/main.zip"
DEFAULT_MODELS_URL="https://raw.githubusercontent.com/66964432/cumob-oneclick-installer/main/payload/cumob-models.json"
DEFAULT_TEMPLATE_URL="https://raw.githubusercontent.com/66964432/cumob-oneclick-installer/main/payload/cumob-config.template.toml"
DEFAULT_MERGE_AWK_URL="https://raw.githubusercontent.com/66964432/cumob-oneclick-installer/main/scripts/merge-config.awk"
DEFAULT_MERGE_AUTH_MJS_URL="https://raw.githubusercontent.com/66964432/cumob-oneclick-installer/main/scripts/merge-auth.mjs"
DEFAULT_MERGE_AUTH_PY_URL="https://raw.githubusercontent.com/66964432/cumob-oneclick-installer/main/scripts/merge_auth.py"

DRY_RUN=0
NO_PROMPT=0
DOWNLOAD_ROOT=""
FILTERED_CONFIG=""
NEW_CONFIG=""
RUNTIME_ROOT=""

# ── Colours & helpers ────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${CYAN}i ${NC}%s\n" "$*"; }
ok()    { printf "${GREEN}* ${NC}%s\n" "$*"; }
warn_msg()  { printf "${YELLOW}! ${NC}%s\n" "$*"; }
err_msg()   { printf "${RED}x ${NC}%s\n" "$*" >&2; }

cleanup() {
  if [ -n "$DOWNLOAD_ROOT" ] && [ -d "$DOWNLOAD_ROOT" ]; then
    rm -rf "$DOWNLOAD_ROOT"
  fi
  if [ -n "$FILTERED_CONFIG" ]; then
    rm -f "$FILTERED_CONFIG"
  fi
  if [ -n "$NEW_CONFIG" ]; then
    rm -f "$NEW_CONFIG"
  fi
}
trap cleanup EXIT

# ── Platform detection ───────────────────────────────────────
HAS_CODEX=false
HAS_CLAUDE=false
TARGETS=()

detect_platforms() {
  HAS_CODEX=false
  HAS_CLAUDE=false

  # Codex: check for CLI or config directory
  if command -v codex >/dev/null 2>&1 || [ -d "${CODEX_HOME:-$HOME/.codex}" ]; then
    HAS_CODEX=true
  fi

  # Claude Code: check for CLI or config directory
  if command -v claude >/dev/null 2>&1 || [ -d "${CLAUDE_HOME:-$HOME/.claude}" ]; then
    HAS_CLAUDE=true
  fi
}

# ── Interactive platform selection ───────────────────────────
select_platform() {
  detect_platforms

  # In --no-prompt mode, auto-detect and install for all detected platforms.
  # If nothing detected, default to codex for backwards compatibility.
  if [ "$NO_PROMPT" -eq 1 ] || [ ! -t 0 ]; then
    if $HAS_CODEX && $HAS_CLAUDE; then
      TARGETS=(codex claude-code)
    elif $HAS_CODEX; then
      TARGETS=(codex)
    elif $HAS_CLAUDE; then
      TARGETS=(claude-code)
    else
      TARGETS=(codex)
    fi
    local joined
    joined=$(printf '%s, ' "${TARGETS[@]}")
    printf '%s\n' "Auto-detected platforms: ${joined%, }" >&2
    return 0
  fi

  echo ""
  printf "${BOLD}CUMOB One-Click Installer${NC}\n"
  echo ""

  # Show detected platforms
  if $HAS_CODEX; then
    ok "Detected OpenAI Codex"
  else
    warn_msg "OpenAI Codex not detected"
  fi

  if $HAS_CLAUDE; then
    ok "Detected Claude Code"
  else
    warn_msg "Claude Code not detected"
  fi

  echo ""

  if ! $HAS_CODEX && ! $HAS_CLAUDE; then
    warn_msg "No installed platform detected, but you can still choose a target."
    echo ""
  fi

  printf "${BOLD}Select installation target:${NC}\n"
  echo ""
  echo "  1) OpenAI Codex"
  echo "  2) Claude Code"
  echo "  3) Both (Codex + Claude Code)"
  echo "  q) Quit"
  echo ""

  while true; do
    printf "${CYAN}Enter choice [1/2/3/q]: ${NC}"
    read -r choice
    case "$choice" in
      1) TARGETS=(codex);              break ;;
      2) TARGETS=(claude-code);        break ;;
      3) TARGETS=(codex claude-code);  break ;;
      q|Q) info "Cancelled."; exit 0 ;;
      *)  err_msg "Invalid choice, try again." ;;
    esac
  done
}


normalize_cumob_base_url() {
  local value="${1:-}"
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s|/*$||')"
  if [ -z "$value" ]; then
    return 1
  fi
  case "$value" in
    http://api.cumob.com|https://api.cumob.com|http://api.cumob.cn|https://api.cumob.cn|\
    http://api.cumob.com/v1|https://api.cumob.com/v1|http://api.cumob.cn/v1|https://api.cumob.cn/v1)
      ;;
    *)
      return 1
      ;;
  esac
  case "$value" in
    */v1) printf '%s\n' "$value" ;;
    *) printf '%s/v1\n' "$value" ;;
  esac
}

get_existing_cumob_base_url() {
  local config_path="${1:-}"
  local existing

  if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
    return 1
  fi

  existing="$(
    sed -nE 's/^[[:space:]]*base_url[[:space:]]*=[[:space:]]*"(https?:\/\/api\.cumob\.(com|cn)(\/v1)?)"[[:space:]]*(#.*)?$/\1/p' \
      "$config_path" | head -n 1
  )"
  normalize_cumob_base_url "$existing"
}

read_cumob_base_url_choice() {
  local timeout_seconds="${1:-15}"
  local default_url="${2:-https://api.cumob.com/v1}"
  local cn_url="https://api.cumob.cn/v1"
  local choice=""

  default_url="$(normalize_cumob_base_url "$default_url" || printf '%s\n' "https://api.cumob.com/v1")"

  printf '%s\n' \
    "" \
    "Select CUMOB API endpoint:" \
    "  1) $default_url  (default)" \
    "  2) $cn_url" \
    "Press 1 or 2 within ${timeout_seconds}s. Empty input or timeout keeps the default." >&2

  if [ -t 0 ]; then
    if IFS= read -r -t "$timeout_seconds" choice; then
      :
    else
      choice=""
    fi
  fi

  case "$(printf '%s' "$choice" | tr -d '[:space:]')" in
    2)
      printf '%s\n' "Selected: $cn_url" >&2
      printf '%s\n' "$cn_url"
      ;;
    1|"")
      if [ -z "$(printf '%s' "$choice" | tr -d '[:space:]')" ]; then
        printf '%s\n' "No selection within ${timeout_seconds}s. Using default: $default_url" >&2
      else
        printf '%s\n' "Selected: $default_url" >&2
      fi
      printf '%s\n' "$default_url"
      ;;
    *)
      printf '%s\n' "Unrecognized input. Using default: $default_url" >&2
      printf '%s\n' "$default_url"
      ;;
  esac
}

resolve_cumob_base_url() {
  local config_path="${1:-}"
  local no_prompt="${2:-0}"
  local default_url="https://api.cumob.com/v1"
  local from_env existing

  if from_env="$(normalize_cumob_base_url "${CUMOB_BASE_URL:-}")"; then
    printf '%s\n' "Using CUMOB_BASE_URL: $from_env" >&2
    printf '%s\n' "$from_env"
    return 0
  fi

  if existing="$(get_existing_cumob_base_url "$config_path")"; then
    printf '%s\n' "Existing CUMOB endpoint in config.toml: $existing" >&2
  fi

  if [ "$no_prompt" -eq 1 ] || [ ! -t 0 ]; then
    printf '%s\n' "Using default CUMOB endpoint: $default_url" >&2
    printf '%s\n' "$default_url"
    return 0
  fi

  read_cumob_base_url_choice 15 "$default_url"
}

usage() {
  printf '%s\n' \
    "Usage: ./install.sh [--dry-run] [--no-prompt]" \
    "" \
    "Installs the CUMOB API gateway configuration and cumob-media-generation" \
    "skill for OpenAI Codex and/or Claude Code." \
    "" \
    "Options:" \
    "  --dry-run     Show what would be done without changing any files." \
    "  --no-prompt   Auto-detect platforms and install without interactive prompts." \
    "  -h, --help    Show this help message." \
    "" \
    "Environment variables:" \
    "  CODEX_HOME                  Override the Codex home directory (default: ~/.codex)." \
    "  CLAUDE_HOME                 Override the Claude Code home directory (default: ~/.claude)." \
    "  CUMOB_INSTALL_API_KEY       Set the API key without a command-line argument." \
    "  CUMOB_SKILL_URL             Override the GitHub Skill archive URL." \
    "  CUMOB_SKILL_ARCHIVE         Local Skill zip path, or Skill archive URL." \
    "  CUMOB_SKILL_SOURCE_DIR      Use a local unpacked Skill directory." \
    "  CUMOB_INSTALLER_URL         Override installer archive URL used by bootstrap." \
    "  CUMOB_MODELS_URL            Override remote model catalog URL." \
    "  CUMOB_CONFIG_TEMPLATE_URL   Override remote config template URL." \
    "  CUMOB_BASE_URL              Skip the prompt and force https://api.cumob.com/v1 or https://api.cumob.cn/v1." \
    "" \
    "Supported platforms:" \
    "  - OpenAI Codex   (config.toml + auth.json in CODEX_HOME)" \
    "  - Claude Code    (settings.json in CLAUDE_HOME, skill symlink, /cumob-media command)"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --no-prompt)
      NO_PROMPT=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

download_file() {
  local url="$1"
  local dest="$2"
  printf 'Downloading %s\n' "$url"
  curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"
}

resolve_catalog_defaults() {
  local catalog_path="$1"
  local result=""

  if command -v node >/dev/null 2>&1; then
    result="$(node - "$catalog_path" <<'NODE'
const fs = require("fs");
const catalog = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const models = Array.isArray(catalog.models) ? catalog.models : [];
const eligible = models.filter((model) =>
  model && model.supported_in_api === true && model.visibility === "list" &&
  typeof model.slug === "string" && Number.isInteger(model.priority) &&
  typeof model.default_reasoning_level === "string"
);
if (!eligible.length) throw new Error("no visible API-supported model with a valid priority");
eligible.sort((a, b) => a.priority - b.priority);
process.stdout.write(`${eligible[0].slug}\t${eligible[0].default_reasoning_level}`);
NODE
    )"
  elif command -v python3 >/dev/null 2>&1; then
    result="$(python3 - "$catalog_path" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    catalog = json.load(stream)
models = catalog.get("models", []) if isinstance(catalog, dict) else []
eligible = [
    model for model in models
    if isinstance(model, dict)
    and model.get("supported_in_api") is True
    and model.get("visibility") == "list"
    and isinstance(model.get("slug"), str)
    and isinstance(model.get("priority"), int)
    and not isinstance(model.get("priority"), bool)
    and isinstance(model.get("default_reasoning_level"), str)
]
if not eligible:
    raise SystemExit("no visible API-supported model with a valid priority")
model = min(eligible, key=lambda item: item["priority"])
print(f'{model["slug"]}\t{model["default_reasoning_level"]}', end="")
PY
    )"
  else
    printf '%s\n' "A Node.js or Python 3 runtime is required to read the model catalog." >&2
    exit 1
  fi

  IFS=$'\t' read -r DEFAULT_MODEL DEFAULT_REASONING_LEVEL <<< "$result"
  if [ -z "$DEFAULT_MODEL" ] || [ -z "$DEFAULT_REASONING_LEVEL" ]; then
    printf '%s\n' "Invalid model catalog: could not determine the default model." >&2
    exit 1
  fi
}

ensure_runtime_assets() {
  local catalog_source="$PAYLOAD_DIR/cumob-models.json"
  local template_source="$PAYLOAD_DIR/cumob-config.template.toml"
  local merge_awk="$SCRIPT_DIR/scripts/merge-config.awk"
  local merge_auth_mjs="$SCRIPT_DIR/scripts/merge-auth.mjs"
  local merge_auth_py="$SCRIPT_DIR/scripts/merge_auth.py"

  if [ -f "$catalog_source" ] &&
    [ -f "$template_source" ] &&
    [ -f "$merge_awk" ] &&
    { [ -f "$merge_auth_mjs" ] || [ -f "$merge_auth_py" ]; }; then
    CATALOG_SOURCE="$catalog_source"
    TEMPLATE_SOURCE="$template_source"
    MERGE_AWK="$merge_awk"
    MERGE_AUTH_MJS="$merge_auth_mjs"
    MERGE_AUTH_PY="$merge_auth_py"
    return 0
  fi

  require_cmd curl
  RUNTIME_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cumob-installer-runtime.XXXXXX")"
  DOWNLOAD_ROOT="$RUNTIME_ROOT"
  mkdir -p "$RUNTIME_ROOT/payload" "$RUNTIME_ROOT/scripts"

  CATALOG_SOURCE="$RUNTIME_ROOT/payload/cumob-models.json"
  TEMPLATE_SOURCE="$RUNTIME_ROOT/payload/cumob-config.template.toml"
  MERGE_AWK="$RUNTIME_ROOT/scripts/merge-config.awk"
  MERGE_AUTH_MJS="$RUNTIME_ROOT/scripts/merge-auth.mjs"
  MERGE_AUTH_PY="$RUNTIME_ROOT/scripts/merge_auth.py"

  if [ -f "$catalog_source" ]; then
    cp "$catalog_source" "$CATALOG_SOURCE"
  else
    download_file "${CUMOB_MODELS_URL:-$DEFAULT_MODELS_URL}" "$CATALOG_SOURCE"
  fi

  if [ -f "$template_source" ]; then
    cp "$template_source" "$TEMPLATE_SOURCE"
  else
    download_file "${CUMOB_CONFIG_TEMPLATE_URL:-$DEFAULT_TEMPLATE_URL}" "$TEMPLATE_SOURCE"
  fi

  if [ -f "$merge_awk" ]; then
    cp "$merge_awk" "$MERGE_AWK"
  else
    download_file "${CUMOB_MERGE_AWK_URL:-$DEFAULT_MERGE_AWK_URL}" "$MERGE_AWK"
  fi

  if [ -f "$merge_auth_mjs" ]; then
    cp "$merge_auth_mjs" "$MERGE_AUTH_MJS"
  else
    download_file "${CUMOB_MERGE_AUTH_MJS_URL:-$DEFAULT_MERGE_AUTH_MJS_URL}" "$MERGE_AUTH_MJS" || true
  fi

  if [ -f "$merge_auth_py" ]; then
    cp "$merge_auth_py" "$MERGE_AUTH_PY"
  else
    download_file "${CUMOB_MERGE_AUTH_PY_URL:-$DEFAULT_MERGE_AUTH_PY_URL}" "$MERGE_AUTH_PY" || true
  fi

  if [ ! -f "$CATALOG_SOURCE" ] || [ ! -f "$TEMPLATE_SOURCE" ] || [ ! -f "$MERGE_AWK" ]; then
    printf '%s\n' "Failed to obtain installer assets from GitHub. Existing files were not changed." >&2
    exit 1
  fi

  if [ ! -f "$MERGE_AUTH_MJS" ] && [ ! -f "$MERGE_AUTH_PY" ]; then
    printf '%s\n' "Failed to obtain auth merge helpers from GitHub. Existing files were not changed." >&2
    exit 1
  fi
}

# ── Configure Claude Code ────────────────────────────────────
configure_claude_code() {
  local claude_home="${CLAUDE_HOME:-$HOME/.claude}"
  local settings_file="$claude_home/settings.json"

  info "Configuring Claude Code ..."

  mkdir -p "$claude_home"

  if [ -f "$settings_file" ]; then
    # Merge env keys into existing settings.json using python3 or node
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$settings_file" "$api_key" "$cumob_base_url" <<'PYEOF'
import json, sys
settings_path, key, base_url = sys.argv[1], sys.argv[2], sys.argv[3]
with open(settings_path) as f:
    data = json.load(f)
env = data.setdefault("env", {})
if key:
    env["CUMOB_API_KEY"] = key
    env["OPENAI_API_KEY"] = key
env["CUMOB_BASE_URL"] = base_url
env["OPENAI_BASE_URL"] = base_url
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
    elif command -v node >/dev/null 2>&1; then
      node - "$settings_file" "$api_key" "$cumob_base_url" <<'NODEEOF'
const fs = require("fs");
const [,, settingsPath, key, baseUrl] = process.argv;
let data = {};
try { data = JSON.parse(fs.readFileSync(settingsPath, "utf8")); } catch {}
if (!data.env) data.env = {};
if (key) { data.env.CUMOB_API_KEY = key; data.env.OPENAI_API_KEY = key; }
data.env.CUMOB_BASE_URL = baseUrl;
data.env.OPENAI_BASE_URL = baseUrl;
fs.writeFileSync(settingsPath, JSON.stringify(data, null, 2) + "\n");
NODEEOF
    else
      printf '%s\n' "Cannot update settings.json: neither python3 nor node found." >&2
      return 1
    fi
  else
    # Create new settings.json
    if [ -n "$api_key" ]; then
      cat > "$settings_file" <<JSONEOF
{
  "env": {
    "CUMOB_API_KEY": "$api_key",
    "CUMOB_BASE_URL": "$cumob_base_url",
    "OPENAI_API_KEY": "$api_key",
    "OPENAI_BASE_URL": "$cumob_base_url"
  }
}
JSONEOF
    else
      cat > "$settings_file" <<JSONEOF
{
  "env": {
    "CUMOB_BASE_URL": "$cumob_base_url",
    "OPENAI_BASE_URL": "$cumob_base_url"
  }
}
JSONEOF
    fi
  fi

  chmod 600 "$settings_file"
  ok "Claude Code settings.json configured: $settings_file"
}

# ── Install skill into Claude Code ───────────────────────────
install_skill_claude_code() {
  local claude_home="${CLAUDE_HOME:-$HOME/.claude}"
  local skill_target="$claude_home/skills/cumob-media-generation"
  local cmd_dir="$claude_home/commands"

  info "Installing cumob-media-generation skill into Claude Code ..."

  # Method 1: Try `claude plugin install` if CLI is available
  if command -v claude >/dev/null 2>&1; then
    info "Detected claude CLI, trying claude plugin install ..."
    if claude plugin install "$SKILL_SOURCE" 2>/dev/null; then
      ok "Skill installed via claude plugin install"
      # Still create the command for discoverability
      mkdir -p "$cmd_dir"
      _write_claude_command "$cmd_dir"
      return
    else
      warn_msg "claude plugin install failed, falling back to manual install ..."
    fi
  fi

  # Method 2: Manual symlink / copy into ~/.claude/skills/
  mkdir -p "$claude_home/skills"

  if [ -L "$skill_target" ]; then
    rm "$skill_target"
  elif [ -d "$skill_target" ]; then
    local ts
    ts="$(date '+%Y%m%d-%H%M%S')"
    warn_msg "Existing $skill_target directory backed up to ${skill_target}.bak.$ts"
    mv "$skill_target" "${skill_target}.bak.$ts"
  fi

  cp -R "$SKILL_SOURCE" "$skill_target"
  ok "Skill installed to $skill_target"

  # Method 3: Also install as a global custom command for discoverability
  mkdir -p "$cmd_dir"
  _write_claude_command "$cmd_dir"
}

_write_claude_command() {
  local cmd_dir="$1"
  cat > "$cmd_dir/cumob-media.md" <<'CMDEOF'
Use the cumob-media-generation skill for image and video generation.

For images:
```bash
node ~/.claude/skills/cumob-media-generation/scripts/generate-image.mjs --prompt "$ARGUMENTS" --out outputs/generated.png
```

For videos:
```bash
node ~/.claude/skills/cumob-media-generation/scripts/generate-video.mjs --prompt "$ARGUMENTS" --duration 10 --aspect-ratio 16:9 --out outputs/generated.mp4
```

Read the SKILL.md at ~/.claude/skills/cumob-media-generation/SKILL.md for full usage instructions before generating.
CMDEOF
  ok "Created Claude Code command /cumob-media"
}

# ── Codex paths (set up after argument parsing) ──────────────
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SKILLS_DIR="$CODEX_HOME/skills"
SKILL_TARGET="$SKILLS_DIR/cumob-media-generation"
LEGACY_SKILL_TARGET="$SKILLS_DIR/cumob-media-generation4codex"
PREVIOUS_LEGACY_SKILL_TARGET="$SKILLS_DIR/cumob-image-generation4codex"
CATALOG_DIR="$CODEX_HOME/model-catalogs"
CATALOG_TARGET="$CATALOG_DIR/cumob-models.json"
CONFIG_PATH="$CODEX_HOME/config.toml"
AUTH_PATH="$CODEX_HOME/auth.json"

# ── Platform selection (right after argument parsing) ────────
select_platform

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' \
    "Dry run only; no files will be changed." \
    "Selected platforms: ${TARGETS[*]}" \
    "Codex home: $CODEX_HOME" \
    "Claude home: $CLAUDE_HOME" \
    "Skill target (Codex): $SKILL_TARGET" \
    "Catalog target: $CATALOG_TARGET" \
    "Config target: $CONFIG_PATH" \
    "Auth target: $AUTH_PATH" \
    "Installer source: ${CUMOB_INSTALLER_URL:-$DEFAULT_INSTALLER_ARCHIVE_URL}" \
    "Skill source: ${CUMOB_SKILL_URL:-$DEFAULT_SKILL_ARCHIVE_URL}" \
    "Models source: ${CUMOB_MODELS_URL:-$DEFAULT_MODELS_URL}"
  exit 0
fi

# ── Check if Codex is a target (need runtime assets only for Codex) ──
CODEX_SELECTED=false
CLAUDE_SELECTED=false
for t in "${TARGETS[@]}"; do
  if [ "$t" = "codex" ]; then CODEX_SELECTED=true; fi
  if [ "$t" = "claude-code" ]; then CLAUDE_SELECTED=true; fi
done

if $CODEX_SELECTED; then
  ensure_runtime_assets
  resolve_catalog_defaults "$CATALOG_SOURCE"
fi

# ── Download skill archive (shared by both platforms) ────────
SKILL_SOURCE="${CUMOB_SKILL_SOURCE_DIR:-}"
if [ -z "$SKILL_SOURCE" ]; then
  require_cmd unzip
  if [ -z "$DOWNLOAD_ROOT" ]; then
    DOWNLOAD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cumob-skill-download.XXXXXX")"
  fi
  skill_archive="$DOWNLOAD_ROOT/cumob-media-generation.zip"
  skill_extract_dir="$DOWNLOAD_ROOT/skill-extracted"
  mkdir -p "$skill_extract_dir"

  if [ -n "${CUMOB_SKILL_ARCHIVE:-}" ] && [ -f "$CUMOB_SKILL_ARCHIVE" ]; then
    cp "$CUMOB_SKILL_ARCHIVE" "$skill_archive"
  else
    require_cmd curl
    skill_url="${CUMOB_SKILL_ARCHIVE:-${CUMOB_SKILL_URL:-$DEFAULT_SKILL_ARCHIVE_URL}}"
    download_file "$skill_url" "$skill_archive"
  fi

  unzip -q "$skill_archive" -d "$skill_extract_dir"
  for candidate in "$skill_extract_dir"/*; do
    if [ -d "$candidate" ] && [ -f "$candidate/SKILL.md" ]; then
      SKILL_SOURCE="$candidate"
      break
    fi
  done
fi

if [ -z "$SKILL_SOURCE" ] ||
  [ ! -f "$SKILL_SOURCE/SKILL.md" ] ||
  { [ ! -f "$SKILL_SOURCE/scripts/generate-image.mjs" ] &&
    [ ! -f "$SKILL_SOURCE/scripts/generate-image.py" ]; }; then
  printf '%s\n' "Downloaded Skill archive is invalid or incomplete. Existing files were not changed." >&2
  exit 1
fi

skill_version="latest"
if [ -f "$SKILL_SOURCE/VERSION" ]; then
  skill_version="$(sed -n '1p' "$SKILL_SOURCE/VERSION" | tr -d '\r')"
fi

api_key="${CUMOB_INSTALL_API_KEY:-}"
if [ -z "$api_key" ] && [ "$NO_PROMPT" -eq 0 ] && [ -t 0 ]; then
  printf '%s' "CUMOB API Key (leave blank to keep existing config): "
  IFS= read -r -s api_key
  printf '\n'
fi

cumob_base_url="$(resolve_cumob_base_url "$CONFIG_PATH" "$NO_PROMPT")"

timestamp="$(date '+%Y%m%d-%H%M%S')"
backup_dir="$CODEX_HOME/backups/cumob-installer-$timestamp"
if [ -e "$backup_dir" ]; then
  backup_dir="$backup_dir-$$"
fi

# ── Codex installation ───────────────────────────────────────
if $CODEX_SELECTED; then
  mkdir -p "$backup_dir" "$SKILLS_DIR" "$CATALOG_DIR"

  if [ -f "$CONFIG_PATH" ]; then
    cp "$CONFIG_PATH" "$backup_dir/config.toml"
  fi
  if [ -f "$AUTH_PATH" ]; then
    cp "$AUTH_PATH" "$backup_dir/auth.json"
  fi
  if [ -f "$CATALOG_TARGET" ]; then
    cp "$CATALOG_TARGET" "$backup_dir/cumob-models.json"
  fi
  if [ -d "$SKILL_TARGET" ]; then
    cp -R "$SKILL_TARGET" "$backup_dir/cumob-media-generation"
  fi
  if [ -d "$LEGACY_SKILL_TARGET" ]; then
    cp -R "$LEGACY_SKILL_TARGET" "$backup_dir/cumob-media-generation4codex"
  fi
  if [ -d "$PREVIOUS_LEGACY_SKILL_TARGET" ]; then
    cp -R "$PREVIOUS_LEGACY_SKILL_TARGET" "$backup_dir/cumob-image-generation4codex"
  fi

  temp_skill="$SKILLS_DIR/.cumob-media-generation.tmp.$$"
  rm -rf "$temp_skill"
  cp -R "$SKILL_SOURCE" "$temp_skill"
  rm -rf "$SKILL_TARGET"
  mv "$temp_skill" "$SKILL_TARGET"
  rm -rf "$LEGACY_SKILL_TARGET"
  rm -rf "$PREVIOUS_LEGACY_SKILL_TARGET"
  cp "$CATALOG_SOURCE" "$CATALOG_TARGET"

  FILTERED_CONFIG="$(mktemp "${TMPDIR:-/tmp}/cumob-config-filtered.XXXXXX")"
  NEW_CONFIG="$(mktemp "${TMPDIR:-/tmp}/cumob-config-new.XXXXXX")"

  if [ -f "$CONFIG_PATH" ]; then
    awk -f "$MERGE_AWK" "$CONFIG_PATH" > "$FILTERED_CONFIG"
  else
    : > "$FILTERED_CONFIG"
  fi

  catalog_toml_path="${CATALOG_TARGET//\\/\\\\}"
  catalog_toml_path="${catalog_toml_path//\"/\\\"}"

  if [ -f "$TEMPLATE_SOURCE" ]; then
    managed_block="$(
      sed \
        -e "s|{{MODEL_CATALOG_PATH}}|$catalog_toml_path|g" \
        -e "s|{{DEFAULT_MODEL}}|$DEFAULT_MODEL|g" \
        -e "s|{{DEFAULT_REASONING_LEVEL}}|$DEFAULT_REASONING_LEVEL|g" \
        -e "s|{{CUMOB_BASE_URL}}|$cumob_base_url|g" \
        "$TEMPLATE_SOURCE"
    )"
  else
    managed_block="$(
      printf '%s\n' \
        'model_provider = "cumob"' \
        "model = \"$DEFAULT_MODEL\"" \
        'disable_response_storage = true' \
        "model_catalog_json = \"$catalog_toml_path\"" \
        "model_reasoning_effort = \"$DEFAULT_REASONING_LEVEL\"" \
        '' \
        '[model_providers.cumob]' \
        'name = "cumob"' \
        'wire_api = "responses"' \
        'image_api = "images"' \
        'image_model = "gpt-image-2.5"' \
        'video_api = "videos"' \
        'video_model = "minimax-h3-2k"' \
        'requires_openai_auth = true' \
        "base_url = \"$cumob_base_url\""
    )"
  fi

  {
    printf '%s\n' "# BEGIN CUMOB ONE-CLICK INSTALLER"
    printf '%s\n' "$managed_block"
    printf '%s\n' "# END CUMOB ONE-CLICK INSTALLER"

    if [ -s "$FILTERED_CONFIG" ]; then
      printf '\n'
      sed '/./,$!d' "$FILTERED_CONFIG"
    fi
  } > "$NEW_CONFIG"

  mv "$NEW_CONFIG" "$CONFIG_PATH"
  NEW_CONFIG=""
  chmod 600 "$CONFIG_PATH"

  if [ -n "$api_key" ]; then
    export CUMOB_INSTALL_API_KEY="$api_key"
    if command -v node >/dev/null 2>&1 && [ -f "$MERGE_AUTH_MJS" ]; then
      node "$MERGE_AUTH_MJS" "$AUTH_PATH"
    elif command -v python3 >/dev/null 2>&1 && [ -f "$MERGE_AUTH_PY" ]; then
      python3 "$MERGE_AUTH_PY" "$AUTH_PATH"
    elif [ -x "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node" ] && [ -f "$MERGE_AUTH_MJS" ]; then
      "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node" \
        "$MERGE_AUTH_MJS" "$AUTH_PATH"
    else
      printf '%s\n' \
        "The skill and Codex configuration were installed, but auth.json could not be updated." \
        "Install Node.js 18+ or Python 3, then run this installer again." >&2
      exit 1
    fi
    unset CUMOB_INSTALL_API_KEY
  elif [ ! -f "$AUTH_PATH" ]; then
    printf '%s\n' "Warning: no API Key was provided. Run the installer again to complete Codex authentication." >&2
  fi

  ok "Codex installation complete."
fi

# ── Claude Code installation ─────────────────────────────────
if $CLAUDE_SELECTED; then
  configure_claude_code
  install_skill_claude_code
  ok "Claude Code installation complete."
fi

# ── Runtime check ────────────────────────────────────────────
runtime_message="No Node.js 18+ or Python 3 runtime was detected on PATH."
if command -v node >/dev/null 2>&1; then
  node_major="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || printf '0')"
  if [ "$node_major" -ge 18 ]; then
    runtime_message="Node.js runtime detected."
  fi
fi
if [ "$runtime_message" != "Node.js runtime detected." ] && command -v python3 >/dev/null 2>&1; then
  runtime_message="Python 3 runtime detected."
fi

# ── Final summary ────────────────────────────────────────────
printf '%s\n' \
  "" \
  "CUMOB One-Click Installer complete." \
  "Installed for: ${TARGETS[*]}"

if $CODEX_SELECTED; then
  printf '%s\n' \
    "Codex backup: $backup_dir" \
    "Codex skill: $SKILL_TARGET (version: $skill_version)" \
    "Model catalog: $CATALOG_TARGET" \
    "Codex config: $CONFIG_PATH" \
    "CUMOB endpoint: $cumob_base_url"
fi

if $CLAUDE_SELECTED; then
  local_claude_home="${CLAUDE_HOME:-$HOME/.claude}"
  printf '%s\n' \
    "Claude Code settings: $local_claude_home/settings.json" \
    "Claude Code skill: $local_claude_home/skills/cumob-media-generation" \
    "Claude Code command: /cumob-media"
fi

printf '%s\n' \
  "$runtime_message" \
  "Restart your coding assistant or create a new task to reload."
