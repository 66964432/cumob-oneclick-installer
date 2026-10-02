# CUMOB One-Click Installer: Codex + Claude Code

[中文](README.md)

The macOS / Windows double-click entry installs Codex; the Bash installer supports Codex and Claude Code and installs the latest `cumob-media-generation` Skill.

> The installer detects available clients and lets you choose **Codex**, **Claude Code**, or **both**. With `--no-prompt`, it automatically installs for detected clients.

After installation, it automatically:

1. Installs the latest `cumob-media-generation` Skill
2. Writes the CUMOB provider configuration
3. Installs the custom model catalog `cumob-models.json`
4. Merges the CUMOB API Key into Codex `auth.json`
5. Supports choosing to install for Codex or Claude Code (or both)

## Goals

- **Codex:** Configure the CUMOB provider, model catalog, permission policy, and `auth.json`, then install the Skill.
- **Claude Code:** Configure CUMOB / OpenAI-compatible environment variables in `settings.json`, install the Skill, and create the `/cumob-media` command.
- Users only need a tiny install entry file and a double-click; the installer pulls the latest Skill, config template, and model catalog from GitHub at install time.
- Real API keys are never packaged.
- Re-running the installer upgrades safely, backing up Codex files first and renaming an existing Claude Code Skill directory before replacement.

## Repositories

- Installer: [`66964432/cumob-oneclick-installer`](https://github.com/66964432/cumob-oneclick-installer)
- Skill: [`66964432/cumob-media-generation`](https://github.com/66964432/cumob-media-generation)
- Latest release: https://github.com/66964432/cumob-oneclick-installer/releases/latest

## Client Support

| Client | Automatically configured | Default directory |
| --- | --- | --- |
| OpenAI Codex | CUMOB provider, model catalog, `config.toml`, `auth.json`, and Skill | `~/.codex` |
| Claude Code | `settings.json` environment variables, Skill, and `/cumob-media` custom command | `~/.claude` |

### Codex

The Codex install writes or updates:

- The CUMOB provider, default model, and model catalog in `config.toml`
- `OPENAI_API_KEY` in `auth.json`
- `skills/cumob-media-generation/` and its image / video scripts

### Claude Code

The Claude Code install:

- Merges or creates `settings.json`, preserving existing settings, and writes `CUMOB_API_KEY`, `CUMOB_BASE_URL`, `OPENAI_API_KEY`, and `OPENAI_BASE_URL`
- Installs `cumob-media-generation` into `skills/cumob-media-generation/`
- Creates `commands/cumob-media.md`, making `/cumob-media` available for quick image / video Skill usage
- Tries `claude plugin install` first when the `claude` CLI is available, then falls back to a local copy if needed

> The Claude Code API key is stored in the `settings.json` environment configuration. Protect this file like any other local secret.

## Prerequisites

1. Codex and/or Claude Code is installed: [Codex](https://chatgpt.com/codex) / [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
2. The machine can access GitHub
3. You have a CUMOB API Key ready (see “How to Get a CUMOB API Key” below)
4. Node.js 18+ or Python 3 is recommended for image / video generation; on Windows, the installer can install Node.js LTS when neither runtime is present

## How to Get a CUMOB API Key

This installer does not ship any API key. Create one yourself after signing in to the CUMOB platform at https://api.cumob.com.

### Platform and Domains

| Purpose | Domain |
| --- | --- |
| Platform entry (create keys, manage account) | [https://api.cumob.com](https://api.cumob.com) |
| API endpoint (International) | `https://api.cumob.com/v1` |
| API endpoint (Asia) | `https://api.cumob.cn/v1` |

Notes:

- For user access and key management, open: https://api.cumob.com
- The installer’s `base_url` should use the API endpoint: `https://api.cumob.com/v1` or `https://api.cumob.cn/v1`
- Platform access and Codex requests both use CUMOB domains; choose the `.com` / `.cn` route during install as needed

### Recommended steps

1. Open the [CUMOB platform](https://api.cumob.com)
2. Sign up, or log in with an existing account
3. Create / copy an API Key in the API Key page
4. Return to this installer and paste the key when prompted
5. If you need a different route, choose during install:
   - `1` → `https://api.cumob.com/v1` (default)
   - `2` → `https://api.cumob.cn/v1`

If the console labels differ slightly from the wording above, follow the UI on the platform. As long as you can create and copy an API Key, you are ready.

## One-Click Install (Recommended)

> **Client implementation note:** `install.sh` supports Codex / Claude Code / both. The Windows `install-windows.cmd` / `install.ps1` entry currently configures Codex and the Windows image runtime. To install Claude Code on Windows, run `bash install.sh` from Git Bash or WSL.

### macOS

1. Download: [`install-macos.command`](https://github.com/66964432/cumob-oneclick-installer/releases/latest/download/install-macos.command)
2. Double-click to run
3. If macOS blocks the file:
   - Right-click the file → Open
   - Or allow it in System Settings → Privacy & Security
4. Enter your CUMOB API Key when prompted
   - Input is hidden by design
   - Press Enter to keep an existing key
6. Close the window after you see `Installation finished`
7. Restart Codex / Claude Code, or create a new task

### Windows

1. Download: [`install-windows.cmd`](https://github.com/66964432/cumob-oneclick-installer/releases/latest/download/install-windows.cmd)
2. Double-click to run
3. If SmartScreen blocks it, choose Run anyway
4. Choose Codex / Claude Code / both when prompted
5. Enter your CUMOB API Key when prompted
   - Input is hidden by design
   - Press Enter to keep an existing key
6. Press any key to close the window after `Installation finished`
7. Restart Codex, or create a new task

Parallels shared folders under `\\Mac\...` are supported. The launcher temporarily maps the UNC path to a drive letter for CMD compatibility.

Even if you only download the entry file, the installer still pulls from GitHub:

- Latest installer logic
- Latest model catalog
- Latest config template
- Latest Skill

Fastest path:

**Download entry → Double-click → Choose client → Enter API Key → Restart client**

## Install From Source

macOS / Linux:

```bash
git clone https://github.com/66964432/cumob-oneclick-installer.git
cd cumob-oneclick-installer
bash install.sh
```

Windows PowerShell:

```powershell
git clone https://github.com/66964432/cumob-oneclick-installer.git
cd cumob-oneclick-installer
.\install.ps1
```

## What Gets Written

Default install location:

- Prefer the `CODEX_HOME` environment variable
- On Windows image generation, also infer Codex home from the installed skill path
- Otherwise:
  - macOS: `~/.codex`
  - Windows: `%USERPROFILE%\.codex`
- If a restricted shell still cannot resolve it, pass an absolute `--codex-home`

Files written:

```text
<CODEX_HOME>/
├── auth.json
├── config.toml
├── model-catalogs/
│   └── cumob-models.json
├── skills/
│   └── cumob-media-generation/
└── backups/
    └── cumob-installer-YYYYMMDD-HHMMSS/

<CLAUDE_HOME>/
├── settings.json
├── skills/
│   └── cumob-media-generation/
└── commands/
    └── cumob-media.md
```

The installer configures, depending on the selected clients:

- The latest `cumob-media-generation` Skill
- The CUMOB model catalog and provider config (Codex)
- The CUMOB API Key (Codex in `auth.json`; Claude Code in `settings.json` environment variables)
- The `/cumob-media` command when Claude Code is selected

## Verify Success

Check the selected client:

**Codex**

1. CUMOB models appear in the model list, for example `gpt-5.6-sol`
2. The `cumob-media-generation` Skill is available
3. Image generation no longer complains about a missing API Key / provider

**Claude Code**

1. `~/.claude/settings.json` contains the CUMOB environment variables
2. `~/.claude/skills/cumob-media-generation/SKILL.md` exists
3. The `/cumob-media` command is available, or Claude Code can invoke the Skill directly

## Upgrade

When the Skill or config is updated later:

1. Double-click the same install entry again
2. The installer re-downloads the latest version and upgrades in place
3. Your other Codex settings are preserved
4. Old files are backed up automatically

## Config Strategy

The installer never fully overwrites `config.toml`. It will:

- Back up the old config, auth, model catalog, and Skill first
- Back up and remove the legacy `cumob-image-generation4codex` directory during upgrades to avoid duplicate Skills
- Remove the previous CUMOB provider section and installer-managed section
- Write portable CUMOB settings and generate the local absolute model-catalog path
- Preserve other providers / MCP / plugins / desktop settings / project permissions
- Merge Claude Code's `settings.json.env` without replacing unrelated environment variables
- Support re-runs without creating duplicate TOML keys

Managed defaults:

```toml
model_provider = "cumob"
model = "gpt-6-astra"
disable_response_storage = true
model_reasoning_effort = "high"

[model_providers.cumob]
name = "cumob"
wire_api = "responses"
image_api = "images"
image_model = "gpt-image-2.5"
video_api = "videos"
video_model = "minimax-h3-2k"
requires_openai_auth = true
base_url = "https://api.cumob.com/v1"
```

Model catalog maintenance uses a single source of truth:

- Add, remove, or modify chat models only in `payload/cumob-models.json`
- The installer selects the model with the lowest `priority` among entries where `supported_in_api = true` and `visibility = "list"` as the default model
- The selected model's `default_reasoning_level` is also written to `model_reasoning_effort`
- `SOURCE.json` no longer stores a manually maintained model count; installer tests compare the source and installed catalogs automatically

Image and video models are provider settings and remain managed by `image_model` and `video_model` in `payload/cumob-config.template.toml`.

`base_url` accepts both `https://api.cumob.com/v1` and `https://api.cumob.cn/v1`.

- Interactive install prompt: `1 = https://api.cumob.com/v1` (default), `2 = https://api.cumob.cn/v1`
- No selection within 15 seconds automatically keeps the default `.com`
- `--no-prompt` / non-interactive installs use the default `.com`
- Force and skip the prompt with `CUMOB_BASE_URL=https://api.cumob.cn/v1`
- Image scripts always follow the Codex provider `base_url` and never hardcode one domain

## Security

- Release packages and the repository never include real API keys
- The API Key is not passed as a CLI argument and is not written to install logs
- For Codex, a new key is written only to `OPENAI_API_KEY` in `auth.json`
- For Claude Code, a new key is written to `CUMOB_API_KEY` and `OPENAI_API_KEY` in `settings.json`
- Existing unrelated auth / settings fields are preserved
- If no key is entered, existing authentication data is kept

Non-interactive install:

```bash
CUMOB_INSTALL_API_KEY="your-key" bash install.sh --no-prompt
```

```powershell
$env:CUMOB_INSTALL_API_KEY = "your-key"
.\install.ps1 -NoPrompt
Remove-Item Env:CUMOB_INSTALL_API_KEY
```

## Advanced Options

Dry run without modifying files:

```bash
bash install.sh --dry-run
```

```powershell
.\install.ps1 -DryRun
```

Custom Codex / Claude Code homes:

```bash
CODEX_HOME="/custom/codex" CLAUDE_HOME="/custom/claude" bash install.sh
```

```powershell
$env:CODEX_HOME = "D:\CodexHome"
$env:CLAUDE_HOME = "$env:USERPROFILE\.claude"
.\install.ps1
```

Preview platform detection and paths without modifying files:

```bash
bash install.sh --dry-run
```

Custom remote sources:

```bash
export CUMOB_INSTALLER_URL="https://github.com/66964432/cumob-oneclick-installer/archive/refs/heads/main.zip"
export CUMOB_SKILL_URL="https://github.com/66964432/cumob-media-generation/archive/refs/heads/main.zip"
export CUMOB_MODELS_URL="https://raw.githubusercontent.com/66964432/cumob-oneclick-installer/main/payload/cumob-models.json"
bash install.sh
```

Windows image runtime controls:

```powershell
# Skip automatic Node.js install and keep only the PowerShell fallback
$env:CUMOB_SKIP_NODE_INSTALL = "1"
.\install.ps1 -NoPrompt

# Custom Node install directory / download source
$env:CUMOB_NODE_INSTALL_DIR = "$env:LOCALAPPDATA\my-cumob-node"
$env:CUMOB_NODE_DIST_URL = "https://nodejs.org/dist/v22.14.0/node-v22.14.0-win-x64.zip"
.\install.ps1 -NoPrompt
```

## FAQ

### 1. Install fails with a network error

Confirm that:

- GitHub is reachable
- No corporate proxy / firewall is blocking the download
- These repositories are accessible:
  - `https://github.com/66964432/cumob-oneclick-installer`
  - `https://github.com/66964432/cumob-media-generation`

Then run the installer again.

### 2. Install succeeded, but the client does not show the change

Try:

1. Fully quit Codex / Claude Code and reopen it
2. Or create a new task
3. In Codex, re-check the model list and Skill; in Claude Code, check the `/cumob-media` command and Skill

### 3. Where do I get an API Key?

Open the CUMOB platform: https://api.cumob.com  
Sign in, create / copy an API Key, then run the installer and paste it. See “How to Get a CUMOB API Key” above for details.

### 4. What if I entered the wrong API Key?

Run the install entry again and type the correct key.

### 5. Will this overwrite my existing Codex / Claude Code configuration?

No full overwrite. The installer only:

- Updates CUMOB-related settings
- Preserves other Codex providers / plugins / desktop settings
- Merges Claude Code's `settings.json.env`
- Backs up Codex files before replacement and renames an existing Claude Code Skill directory to `.bak.YYYYMMDD-HHMMSS`

Codex backup directories:

- macOS: `~/.codex/backups/`
- Windows: `%USERPROFILE%\.codex\backups\`

Claude Code Skill backup:

- `~/.claude/skills/cumob-media-generation.bak.YYYYMMDD-HHMMSS/`

## Requirements

- Codex and/or Claude Code installed
- Network access to GitHub
- macOS / Linux: Bash, curl, unzip, and Node.js 18+ or Python 3
- The Windows PowerShell entry currently configures Codex; use Git Bash or WSL with `bash install.sh` for Claude Code on Windows
- The Claude Code CLI (`claude`) is optional; when available, the installer tries plugin installation first and falls back automatically
- The image Skill prefers Node.js 18+ or Python 3
- The Windows installer detects image runtimes automatically:
  - Reuses an existing Node.js 18+ or Python 3 installation
  - If neither is present, downloads Node.js LTS from nodejs.org into `%LOCALAPPDATA%\cumob-nodejs` and adds it to the current process PATH and the user PATH
  - Skip automatic install with `CUMOB_SKIP_NODE_INSTALL=1`
  - Optional overrides: `CUMOB_NODE_DIST_URL`, `CUMOB_NODE_INDEX_URL`, `CUMOB_NODE_INSTALL_DIR`
- Windows still keeps a PowerShell 5.1 fallback for emergency use when Node/Python are unavailable
- The image Skill on macOS / Linux still requires Node.js 18+ or Python 3

The Windows installation adds a unified launcher to the Skill:

```powershell
& "$env:USERPROFILE\.codex\skills\cumob-media-generation\scripts\generate-image-windows.cmd" `
  --prompt "A quick test image" `
  --out "$env:TEMP\cumob-test.png" `
  --dry-run
```

The launcher reads the Codex CUMOB configuration and `auth.json` automatically, prefers Node.js / Python, and only uses the built-in PowerShell fallback when needed.

## Development And Verification

macOS / Linux:

```bash
bash tests/test-install.sh
```

Windows:

```powershell
.\tests\test-install.ps1
```

Live network verification (downloads the Skill from GitHub):

```bash
CUMOB_LIVE_TEST=1 bash tests/test-install.sh
```

Build local release artifacts:

```bash
bash build-release.sh
```

## Repository Layout

```text
cumob-oneclick-installer/
├── install-macos.command
├── install-windows.cmd
├── install.sh
├── install.ps1
├── payload/
│   ├── cumob-config.template.toml
│   ├── cumob-models.json
│   ├── generate-image.ps1
│   └── generate-image-windows.cmd
├── scripts/
├── tests/
├── .github/workflows/
├── README.md
├── README.en.md
└── SOURCE.json
```

Users only need the entry files day to day. All configuration content continues to be maintained on GitHub.
