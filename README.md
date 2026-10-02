# 一键接入自定义路由 - cumob 篇 (Codex / Claude Code)

[English](README.en.md)

macOS / Windows 双击安装，把 Codex 和/或 Claude Code 一键接入 CUMOB 自定义路由。

> 安装时会提示选择目标平台（Codex / Claude Code / 两者都装）

安装后自动完成：

1. 安装最新 `cumob-media-generation` Skill
2. 写入 CUMOB provider 配置
3. 安装自定义模型目录 `cumob-models.json`
4. 将 CUMOB API Key 合并进 Codex `auth.json`
5. 支持选择为 Codex 或 Claude Code（或同时）安装

## 设计目标

- 用户只需要下载很小的安装入口，双击即可
- 安装时从 GitHub 实时拉取最新 Skill、配置模板、模型目录
- 不打包真实 API Key
- 重复安装可升级，不破坏用户已有的其他 Codex 配置

## 仓库

- 安装器：[`66964432/cumob-oneclick-installer`](https://github.com/66964432/cumob-oneclick-installer)
- Skill：[`66964432/cumob-media-generation`](https://github.com/66964432/cumob-media-generation)
- 最新发布页：https://github.com/66964432/cumob-oneclick-installer/releases/latest

## 安装前准备

1. 已安装 [Codex](https://chatgpt.com/codex) 和/或 [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
2. 电脑可访问 GitHub
3. 准备好你的 CUMOB API Key（见下方「如何获取 CUMOB API Key」）

## 如何获取 CUMOB API Key

安装器本身不提供密钥，需要先到 CUMOB 平台（https://api.cumob.com）注册 / 登录后自行创建。

### 平台与域名

| 用途 | 域名 |
| --- | --- |
| 平台入口（获取密钥、账户管理） | [https://api.cumob.com](https://api.cumob.com) |
| API 接入（环太平洋） | `https://api.cumob.com/v1` |
| API 接入（东亚地区） | `https://api.cumob.cn/v1` |

说明：

- 用户访问与密钥管理请打开：https://api.cumob.com
- 安装器里的 `base_url` 使用 API 接入地址：`https://api.cumob.com/v1` 或 `https://api.cumob.cn/v1`
- 平台入口与 Codex 调用都走 CUMOB 域名；安装时按提示选择 `.com` / `.cn` 线路即可

### 推荐步骤

1. 打开 [CUMOB 平台](https://api.cumob.com)
2. 注册账号，或使用已有账号登录
3. 在 API Key 页面中创建 / 复制 API Key
4. 回到本安装器，按提示粘贴该 Key
5. 如需切换线路，安装时可选择：
   - `1` → `https://api.cumob.com/v1`（默认）
   - `2` → `https://api.cumob.cn/v1`

如果平台页面里的菜单名称与上述描述不完全一致，以控制台实际文案为准；只要能创建并复制 API Key 即可。

## 一键安装（推荐）

### macOS

1. 下载：[`install-macos.command`](https://github.com/66964432/cumob-oneclick-installer/releases/latest/download/install-macos.command)
2. 双击运行
3. 如果系统提示“无法打开”，请：
   - 右键文件 → 选择“打开”
   - 或到“系统设置 → 隐私与安全性”中允许运行
4. 按提示输入 CUMOB API Key
   - 输入时不会显示字符，属正常现象
   - 如果本机已配置过 Key，可直接回车跳过
5. 看到 `Installation finished` 后，关闭窗口
6. 重启 Codex，或新建一个任务

### Windows

1. 下载：[`install-windows.cmd`](https://github.com/66964432/cumob-oneclick-installer/releases/latest/download/install-windows.cmd)
2. 双击运行
3. 如果 SmartScreen 拦截，选择“仍要运行”
4. 按提示输入 CUMOB API Key
   - 输入时不会显示字符，属正常现象
   - 如果本机已配置过 Key，可直接回车跳过
5. 看到 `Installation finished` 后，按任意键关闭窗口
6. 重启 Codex，或新建一个任务

Parallels 的 `\\Mac\...` 共享目录也可直接运行；启动器会临时映射盘符，以兼容 CMD 不支持 UNC 当前目录的限制。

即使只下载入口文件，安装器也会从 GitHub 拉取：

- 最新安装逻辑
- 最新模型目录
- 最新配置模板
- 最新 Skill

最快安装流程：

**下载入口 → 双击安装 → 输入 API Key → 重启 Codex**

## 从源码安装

macOS / Linux：

```bash
git clone https://github.com/66964432/cumob-oneclick-installer.git
cd cumob-oneclick-installer
bash install.sh
```

Windows PowerShell：

```powershell
git clone https://github.com/66964432/cumob-oneclick-installer.git
cd cumob-oneclick-installer
.\install.ps1
```

## 安装后会写入什么

默认写入位置：

- 优先使用环境变量 `CODEX_HOME`
- Windows 生图脚本还会从已安装 skill 路径反推 Codex home
- 未设置时：
  - macOS：`~/.codex`
  - Windows：`%USERPROFILE%\.codex`
- 受限 shell 仍解析失败时，可显式传 `--codex-home`

写入内容：

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
```

安装器会自动配置：

- 最新 `cumob-media-generation` Skill
- CUMOB 模型目录
- CUMOB provider 配置
- API Key 到 Codex `auth.json`

## 如何确认安装成功

打开 Codex 后检查：

1. 模型列表里能看到 CUMOB 模型，例如 `gpt-5.6-sol`
2. 可以调用媒体 Skill：`cumob-media-generation`
3. 生成图片时不再提示缺少 API Key / provider

## 升级

以后如果 Skill 或配置有更新：

1. 再次双击同一个安装入口
2. 安装器会重新拉取最新版本并覆盖升级
3. 你的其他 Codex 配置会保留
4. 旧文件会自动备份

## 配置策略

安装器不会整文件覆盖 `config.toml`。它会：

- 先备份旧配置、旧 auth、旧模型目录、旧 Skill
- 升级时备份并移除旧名称 `cumob-image-generation4codex`，避免两个 Skill 并存
- 删除旧的 CUMOB provider 段和本安装器受管段
- 写入可移植 CUMOB 配置，并生成当前机器上的模型目录绝对路径
- 保留其他 provider / MCP / 插件 / 桌面设置 / 项目权限
- 重复运行时升级，不产生重复 TOML 键

受管配置默认值：

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

模型目录维护采用单一来源：

- 新增、删除或修改聊天模型时，只编辑 `payload/cumob-models.json`
- 安装器会从模型目录中选择 `priority` 最小、且 `supported_in_api = true`、`visibility = "list"` 的模型作为默认模型
- 默认模型的 `default_reasoning_level` 也会自动写入 `model_reasoning_effort`
- `SOURCE.json` 不再手动记录模型数量，安装测试会自动比较源目录和安装后的目录

图片模型和视频模型属于 provider 配置，仍分别由 `payload/cumob-config.template.toml` 中的 `image_model` 和 `video_model` 管理。

`base_url` 支持 `https://api.cumob.com/v1` 与 `https://api.cumob.cn/v1`。两个域名都有效。

- 安装时交互选择端点：`1 = https://api.cumob.com/v1`（默认），`2 = https://api.cumob.cn/v1`
- 15 秒内无操作，自动选择默认 `.com`
- `--no-prompt` / 非交互安装直接使用默认 `.com`
- 也可通过环境变量强制指定并跳过选择：`CUMOB_BASE_URL=https://api.cumob.cn/v1`
- 生图脚本始终读取 Codex provider 的 `base_url`，不会写死域名

## 安全

- 发行包与仓库都不包含真实 API Key
- API Key 不作为命令行参数传递，也不会写入安装日志
- 新 Key 只写入 `auth.json` 的 `OPENAI_API_KEY`
- 现有其他 auth 字段会保留
- 不输入 Key 时，保留已有 `auth.json`

非交互安装：

```bash
CUMOB_INSTALL_API_KEY="your-key" bash install.sh --no-prompt
```

```powershell
$env:CUMOB_INSTALL_API_KEY = "your-key"
.\install.ps1 -NoPrompt
Remove-Item Env:CUMOB_INSTALL_API_KEY
```

## 高级选项

只预览，不改文件：

```bash
bash install.sh --dry-run
```

```powershell
.\install.ps1 -DryRun
```

自定义 Codex 目录：

```bash
CODEX_HOME="/custom/path" bash install.sh
```

```powershell
$env:CODEX_HOME = "D:\CodexHome"
.\install.ps1
```

自定义远程源：

```bash
export CUMOB_INSTALLER_URL="https://github.com/66964432/cumob-oneclick-installer/archive/refs/heads/main.zip"
export CUMOB_SKILL_URL="https://github.com/66964432/cumob-media-generation/archive/refs/heads/main.zip"
export CUMOB_MODELS_URL="https://raw.githubusercontent.com/66964432/cumob-oneclick-installer/main/payload/cumob-models.json"
bash install.sh
```

Windows 图片运行时控制：

```powershell
# 跳过自动安装 Node.js，仅保留 PowerShell 后备
$env:CUMOB_SKIP_NODE_INSTALL = "1"
.\install.ps1 -NoPrompt

# 自定义 Node 安装目录 / 下载源
$env:CUMOB_NODE_INSTALL_DIR = "$env:LOCALAPPDATA\my-cumob-node"
$env:CUMOB_NODE_DIST_URL = "https://nodejs.org/dist/v22.14.0/node-v22.14.0-win-x64.zip"
.\install.ps1 -NoPrompt
```

## 常见问题

### 1. 安装失败，提示网络错误

请确认：

- 能打开 GitHub
- 没有被公司代理 / 防火墙拦截
- 可访问：
  - `https://github.com/66964432/cumob-oneclick-installer`
  - `https://github.com/66964432/cumob-media-generation`

然后重新双击安装。

### 2. 安装成功，但 Codex 里看不到变化

请：

1. 完全退出 Codex 再打开
2. 或新建一个任务
3. 再检查模型列表和 Skill

### 3. API Key 从哪里获取？

打开 CUMOB 平台：https://api.cumob.com  
登录后创建 / 复制 API Key，再运行安装器填入。详细步骤见上文「如何获取 CUMOB API Key」。

### 4. API Key 输错了怎么办

再次运行安装入口，重新输入正确 Key 即可。

### 5. 会不会覆盖我原来的 Codex 配置？

不会整份覆盖。安装器只会：

- 更新 CUMOB 相关配置
- 保留其他 provider / 插件 / 桌面设置
- 先备份旧文件

备份目录：

- macOS：`~/.codex/backups/`
- Windows：`%USERPROFILE%\.codex\backups\`

## 运行要求

- Codex 已安装
- 网络可访问 GitHub
- 图片 Skill 优先使用 Node.js 18+ 或 Python 3
- Windows 安装器会自动检测运行时：
  - 已有 Node.js 18+ 或 Python 3：直接复用
  - 两者都没有：默认从 nodejs.org 下载 Node.js LTS，安装到 `%LOCALAPPDATA%\cumob-nodejs`，并写入当前进程 PATH 与用户 PATH
  - 如需跳过自动安装：设置 `CUMOB_SKIP_NODE_INSTALL=1`
  - 可选覆盖：`CUMOB_NODE_DIST_URL`、`CUMOB_NODE_INDEX_URL`、`CUMOB_NODE_INSTALL_DIR`
- Windows 仍保留 PowerShell 5.1 后备脚本，仅在 Node/Python 不可用时应急使用
- macOS / Linux 的图片 Skill 仍需 Node.js 18+ 或 Python 3

Windows 安装后，Skill 中会增加统一启动器：

```powershell
& "$env:USERPROFILE\.codex\skills\cumob-media-generation\scripts\generate-image-windows.cmd" `
  --prompt "A quick test image" `
  --out "$env:TEMP\cumob-test.png" `
  --dry-run
```

该启动器会自动读取 Codex 的 CUMOB 配置和 `auth.json`，优先调用 Node.js / Python，必要时才使用内置 PowerShell 后备脚本。

## 开发与验证

macOS / Linux：

```bash
bash tests/test-install.sh
```

Windows：

```powershell
.\tests\test-install.ps1
```

真实联网验证（会从 GitHub 下载 Skill）：

```bash
CUMOB_LIVE_TEST=1 bash tests/test-install.sh
```

构建本地发布包：

```bash
bash build-release.sh
```

## 仓库结构

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
├── README.md
├── README.en.md
└── SOURCE.json
```

用户日常只需要下载入口文件，配置内容全部在 GitHub 上持续更新。
