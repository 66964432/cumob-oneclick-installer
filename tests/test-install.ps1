$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$rootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("cumob-installer-test-" + [Guid]::NewGuid().ToString("N"))
$env:CODEX_HOME = Join-Path $testRoot ".codex"
$env:CUMOB_INSTALL_API_KEY = "test-key-one"
$configPath = $null

try {
    # Replace only the HTTP client factory in a temporary installer copy. Production
    # URL/auth/version checks, HttpClient streaming, schema validation and writes run unchanged.
    Add-Type -AssemblyName System.Net.Http
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Add-Type -Path (Join-Path $rootDir 'tests/CatalogFixtureHandler.cs') -ReferencedAssemblies 'System.Net.Http'
    } else {
        Add-Type -Path (Join-Path $rootDir 'tests/CatalogFixtureHandler.cs')
    }
    function Write-FixtureInstaller {
        param([string]$Destination)
        $source = [IO.File]::ReadAllText((Join-Path $rootDir 'install.ps1'))
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw 'Installer has PowerShell syntax errors.' }
        $factory = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CumobCatalogHttpClient' }, $true)
        if ($null -eq $factory) { throw 'Catalog HTTP factory was not found.' }
        $replacement = 'function New-CumobCatalogHttpClient { return [Net.Http.HttpClient]::new([CumobCatalogFixtureHandler]::new()) }'
        $source = $source.Remove($factory.Extent.StartOffset, $factory.Extent.EndOffset - $factory.Extent.StartOffset).Insert($factory.Extent.StartOffset, $replacement)
        [IO.File]::WriteAllText($Destination, $source, [Text.UTF8Encoding]::new($true))
    }
    function ConvertTo-FixtureFileUrl {
        param([string]$Path)
        $builder = [UriBuilder]::new()
        $builder.Scheme = 'file'
        $builder.Host = ''
        $builder.Path = [IO.Path]::GetFullPath($Path)
        return $builder.Uri.AbsoluteUri
    }
    $localInstallerRoot = Join-Path $testRoot 'local-installer'
    New-Item -ItemType Directory -Force -Path $localInstallerRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $rootDir 'payload') -Destination (Join-Path $localInstallerRoot 'payload') -Recurse
    # The local JSON must not be necessary even for a complete installation package.
    Remove-Item -LiteralPath (Join-Path $localInstallerRoot 'payload/cumob-models.json')
    $localInstaller = Join-Path $localInstallerRoot 'install.ps1'
    Write-FixtureInstaller $localInstaller
    $env:CUMOB_TEST_CATALOG = Join-Path $testRoot 'catalog.json'
    Copy-Item -LiteralPath (Join-Path $rootDir 'payload/cumob-models.json') -Destination $env:CUMOB_TEST_CATALOG
    $env:CUMOB_TEST_EXPECTED_KEY = 'test-key-one'
    $env:CUMOB_CODEX_CLIENT_VERSION = '0.162.1'
    $env:CUMOB_TEST_REQUESTS = Join-Path $testRoot 'requests.log'

    $fixtureSkill = Join-Path $testRoot "fixture-skill"
    $fixtureScripts = Join-Path $fixtureSkill "scripts"
    New-Item -ItemType Directory -Force -Path $fixtureScripts | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixtureSkill "SKILL.md"), "---`nname: cumob-media-generation`ndescription: Installer test fixture.`n---`n")
    [IO.File]::WriteAllText((Join-Path $fixtureSkill "VERSION"), "test-fixture`n")
    [IO.File]::WriteAllText((Join-Path $fixtureScripts "generate-image.py"), "print('test fixture')`n")
    $env:CUMOB_SKILL_SOURCE_DIR = $fixtureSkill

    $oldSkill = Join-Path $env:CODEX_HOME "skills\cumob-image-generation4codex"
    $catalogDir = Join-Path $env:CODEX_HOME "model-catalogs"
    New-Item -ItemType Directory -Force -Path $oldSkill, $catalogDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $oldSkill "OLD.txt"), "old skill")

    $seedConfig = @"
model_provider = "old-provider"
model = "old-model"
model_catalog_json = "C:/old/models.json"

[features]
api_key_model_discovery = false
other_feature = true

[model_providers.cumob]
name = "old-cumob"
base_url = "https://old.invalid/v1"

[model_providers.other]
name = "keep-me"

[desktop]
localeOverride = "zh-CN"
"@
    [IO.File]::WriteAllText((Join-Path $env:CODEX_HOME "config.toml"), $seedConfig)
    [IO.File]::WriteAllText((Join-Path $env:CODEX_HOME "auth.json"), '{"OPENAI_API_KEY":"old-key","OTHER_AUTH_FIELD":"keep-me"}')

    $installerSource = [IO.File]::ReadAllText((Join-Path $rootDir "install.ps1"))
    foreach ($helperName in @(
            "function Get-PythonRuntimeCommand",
            "function Get-NodeRuntimeCommand",
            "function Get-ImageRuntimeStatus",
            "function Add-DirectoryToProcessAndUserPath",
            "function Resolve-NodeDownloadAsset",
            "function Install-NodeRuntime",
            "function Ensure-ImageRuntime"
        )) {
        if (-not $installerSource.Contains($helperName)) {
            throw "install.ps1 is missing helper: $helperName"
        }
    }
    if (-not $installerSource.Contains("CUMOB_SKIP_NODE_INSTALL")) {
        throw "install.ps1 does not support CUMOB_SKIP_NODE_INSTALL"
    }
    if (-not $installerSource.Contains("CUMOB_NODE_DIST_URL") -or
        -not $installerSource.Contains("CUMOB_NODE_INDEX_URL") -or
        -not $installerSource.Contains("CUMOB_NODE_INSTALL_DIR")) {
        throw "install.ps1 is missing Node download override environment variables"
    }
    if (-not $installerSource.Contains("Ensure-ImageRuntime -DryRun") -or
        -not $installerSource.Contains('$imageRuntime = Ensure-ImageRuntime')) {
        throw "install.ps1 does not call Ensure-ImageRuntime in dry-run and real install paths"
    }
    if (-not $installerSource.Contains("nodejs.org/dist") -or
        -not $installerSource.Contains("cumob-nodejs")) {
        throw "install.ps1 does not default to the Node.js LTS zip install path"
    }
    if ($installerSource.Contains('Join-Path $versionDir "*"')) {
        throw "install.ps1 still uses LiteralPath wildcard copy that leaves current\node.exe missing"
    }
    if (-not $installerSource.Contains('Copy-Item -LiteralPath $versionDir -Destination $currentLink -Recurse')) {
        throw "install.ps1 does not copy the versioned Node.js directory into the stable current alias"
    }
    $installerBytes = [IO.File]::ReadAllBytes((Join-Path $rootDir "install.ps1"))
    if ($installerBytes.Length -lt 3 -or
        $installerBytes[0] -ne 0xEF -or
        $installerBytes[1] -ne 0xBB -or
        $installerBytes[2] -ne 0xBF) {
        throw "install.ps1 is missing the required UTF-8 BOM"
    }

    & $localInstaller -NoPrompt

    $configPath = Join-Path $env:CODEX_HOME "config.toml"
    $authPath = Join-Path $env:CODEX_HOME "auth.json"
    $installedSkill = Join-Path $env:CODEX_HOME "skills\cumob-media-generation"
    $powerShellFallback = Join-Path $installedSkill "scripts\generate-image.ps1"
    $windowsImageLauncher = Join-Path $installedSkill "scripts\generate-image-windows.cmd"
    $config = [IO.File]::ReadAllText($configPath)
    $auth = [IO.File]::ReadAllText($authPath) | ConvertFrom-Json
    $sourceCatalog = [IO.File]::ReadAllText((Join-Path $rootDir "payload\cumob-models.json")) | ConvertFrom-Json

    if (Test-Path -LiteralPath $oldSkill) { throw "legacy Skill directory was not removed" }
    $legacyBackup = Get-ChildItem -LiteralPath (Join-Path $env:CODEX_HOME "backups") -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "cumob-image-generation4codex\OLD.txt") } |
        Select-Object -First 1
    if ($null -eq $legacyBackup) { throw "legacy Skill directory was not backed up" }
    if ([regex]::Matches($config, "(?m)^model_provider\s*=").Count -ne 1) { throw "model_provider is not unique" }
    if ([regex]::Matches($config, "(?m)^\[model_providers\.cumob\]\r?$" ).Count -ne 1) { throw "CUMOB table is not unique" }
    if (-not $config.Contains("[model_providers.other]")) { throw "other provider was removed" }
    if (-not $config.Contains('localeOverride = "zh-CN"')) { throw "desktop settings were removed" }
    if (-not $config.Contains('video_api = "videos"')) { throw "video_api was not installed" }
    if (-not $config.Contains('video_model = "minimax-h3-2k"')) { throw "video model was not installed" }
    if ($auth.OPENAI_API_KEY -ne "test-key-one" -or $auth.OTHER_AUTH_FIELD -ne "keep-me") { throw "auth.json merge failed" }
    if ($config -match '(?m)^model_catalog_json\s*=') { throw "Local catalog still overrides remote discovery" }
    if (-not $config.Contains('model_catalog_url = "https://api.cumob.com/v1/codex/models"')) { throw "Remote catalog URL not installed" }
    if (-not $config.Contains('api_key_model_discovery = true') -or $config.Contains('api_key_model_discovery = false')) { throw "API key model discovery not enabled" }
    if (-not $config.Contains('other_feature = true')) { throw "Other feature removed" }
    if (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'model-catalogs/cumob-models.json')) { throw "Installer copied a local catalog" }
    $expectedDefault = @($sourceCatalog.models |
        Where-Object { $_.supported_in_api -eq $true -and $_.visibility -eq "list" } |
        Sort-Object { [int]$_.priority } |
        Select-Object -First 1)
    $configuredModel = [regex]::Match($config, '(?m)^model\s*=\s*"([^"]+)"\r?$')
    if (-not $configuredModel.Success -or $configuredModel.Groups[1].Value -ne [string]$expectedDefault.slug) {
        $actualModel = if ($configuredModel.Success) { $configuredModel.Groups[1].Value } else { "<missing>" }
        throw "default model was not derived from the catalog (expected=$($expectedDefault.slug), actual=$actualModel)"
    }
    $configuredReasoning = [regex]::Match($config, '(?m)^model_reasoning_effort\s*=\s*"([^"]+)"\r?$')
    if (-not $configuredReasoning.Success -or $configuredReasoning.Groups[1].Value -ne [string]$expectedDefault.default_reasoning_level) { throw "default reasoning level was not derived from the catalog" }
    if (-not (Test-Path -LiteralPath $powerShellFallback -PathType Leaf)) { throw "PowerShell image fallback was not installed" }
    if (-not (Test-Path -LiteralPath $windowsImageLauncher -PathType Leaf)) { throw "Windows image launcher was not installed" }
    $installedSkillInstructions = [IO.File]::ReadAllText((Join-Path $installedSkill "SKILL.md"))
    if (-not $installedSkillInstructions.Contains("## Native Windows Launcher")) {
        throw "Windows fallback instructions were not added to the Skill"
    }
    if (-not $installedSkillInstructions.Contains("auto-installs Node.js LTS") -and
        -not $installedSkillInstructions.Contains("automatically downloads Node.js LTS")) {
        throw "Windows Skill instructions do not mention automatic Node.js installation"
    }
    if ($installedSkillInstructions.Contains('base_url = "http://api.cumob.com/v1"')) {
        throw "Skill instructions still use the obsolete CUMOB HTTP endpoint"
    }
    if (-not $installedSkillInstructions.Contains('api.cumob.com') -or -not $installedSkillInstructions.Contains('api.cumob.cn')) {
        throw "Skill instructions do not document both CUMOB domains"
    }
    $launcherText = [IO.File]::ReadAllText($windowsImageLauncher)
    if (-not $launcherText.Contains('py.exe -3 -c "import sys"')) {
        throw "Windows image launcher does not verify that Python 3 can start"
    }
    if (-not $launcherText.Contains('where python.exe')) {
        throw "Windows image launcher does not support Python installations without py.exe"
    }

    $fallbackDryRunText = (& $powerShellFallback `
        --prompt "Installer fallback configuration check" `
        --out (Join-Path $testRoot "unused.png") `
        --dry-run `
        --no-progress | Out-String)
    $fallbackDryRun = $fallbackDryRunText | ConvertFrom-Json
    if ($fallbackDryRun.image_api -ne "images") { throw "PowerShell fallback did not load image_api" }
    if ($fallbackDryRun.endpoint -ne "https://api.cumob.com/v1/images/generations") { throw "PowerShell fallback endpoint is incorrect" }
    if ($fallbackDryRun.image_model -ne "gpt-image-2.5") { throw "PowerShell fallback image model is incorrect" }
    if (-not $fallbackDryRun.has_api_key) { throw "PowerShell fallback did not detect the API key" }
    if ($fallbackDryRunText.Contains("test-key-one")) { throw "PowerShell fallback dry-run leaked the API key" }

    $nestedSkillScripts = Join-Path $env:CODEX_HOME "skills\cumob-media-generation\scripts"
    $nestedFallback = Join-Path $nestedSkillScripts "generate-image.ps1"
    $nestedLauncher = Join-Path $nestedSkillScripts "generate-image-windows.cmd"
    if (-not (Test-Path -LiteralPath $nestedFallback -PathType Leaf)) {
        throw "installed PowerShell fallback is missing for home-resolution tests"
    }

    $savedCodexHome = $env:CODEX_HOME
    $savedUserProfile = $env:USERPROFILE
    $savedHome = $env:HOME
    $savedHomeDrive = $env:HOMEDRIVE
    $savedHomePath = $env:HOMEPATH
    try {
        Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
        $profileRoot = Join-Path $testRoot "profile-home"
        $profileCodexHome = Join-Path $profileRoot ".codex"
        New-Item -ItemType Directory -Force -Path $profileCodexHome | Out-Null
        Copy-Item -LiteralPath (Join-Path $savedCodexHome "config.toml") -Destination (Join-Path $profileCodexHome "config.toml")
        Copy-Item -LiteralPath (Join-Path $savedCodexHome "auth.json") -Destination (Join-Path $profileCodexHome "auth.json")
        $env:USERPROFILE = $profileRoot
        $env:HOME = Join-Path $testRoot "missing-home"
        $env:HOMEDRIVE = "C:"
        $env:HOMEPATH = "\Users\runneradmin"

        $standaloneFallback = Join-Path $rootDir "payload\generate-image.ps1"
        $profileDryRunText = (& $standaloneFallback `
            --prompt "Infer Codex home from user profile" `
            --image (Join-Path $testRoot "profile-input.png") `
            --action edit `
            --out (Join-Path $testRoot "unused-profile.png") `
            --dry-run `
            --no-progress | Out-String)
        $profileDryRun = $profileDryRunText | ConvertFrom-Json
        if ($profileDryRun.codex_home -ne ([IO.Path]::GetFullPath($profileCodexHome))) {
            throw "Standalone PowerShell fallback did not infer Codex home from USERPROFILE"
        }
        if ($profileDryRun.request.images.Count -ne 1) {
            throw "PowerShell fallback argument parsing lost the repeated image option"
        }

        $inferredDryRunText = (& $nestedFallback `
            --prompt "Infer Codex home from skill path" `
            --out (Join-Path $testRoot "unused-inferred.png") `
            --dry-run `
            --no-progress | Out-String)
        $inferredDryRun = $inferredDryRunText | ConvertFrom-Json
        if ($inferredDryRun.codex_home -ne ([IO.Path]::GetFullPath($savedCodexHome))) {
            throw "PowerShell fallback did not infer Codex home from the installed skill path"
        }
        if ($inferredDryRun.image_model -ne "gpt-image-2.5") {
            throw "Skill-path home inference loaded the wrong image model"
        }

        $explicitHome = Join-Path $testRoot "explicit-codex-home"
        New-Item -ItemType Directory -Force -Path $explicitHome | Out-Null
        Copy-Item -LiteralPath (Join-Path $savedCodexHome "config.toml") -Destination (Join-Path $explicitHome "config.toml")
        Copy-Item -LiteralPath (Join-Path $savedCodexHome "auth.json") -Destination (Join-Path $explicitHome "auth.json")
        $explicitDryRunText = (& $nestedFallback `
            --prompt "Explicit Codex home override" `
            --out (Join-Path $testRoot "unused-explicit.png") `
            --codex-home $explicitHome `
            --dry-run `
            --no-progress | Out-String)
        $explicitDryRun = $explicitDryRunText | ConvertFrom-Json
        if ($explicitDryRun.codex_home -ne ([IO.Path]::GetFullPath($explicitHome))) {
            throw "PowerShell fallback ignored --codex-home"
        }

        if ($env:OS -eq 'Windows_NT') {
        $env:CUMOB_IMAGE_FORCE_POWERSHELL = "1"
        $launcherInferredText = (& $nestedLauncher `
            --prompt "Launcher infers Codex home" `
            --out (Join-Path $testRoot "unused-launcher-inferred.png") `
            --dry-run `
            --no-progress | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "Windows image launcher failed while inferring Codex home with exit code $LASTEXITCODE"
        }
        $launcherInferred = $launcherInferredText | ConvertFrom-Json
        if ($launcherInferred.codex_home -ne ([IO.Path]::GetFullPath($savedCodexHome))) {
            throw "Windows image launcher did not infer Codex home from its install path"
        }
        Remove-Item Env:CUMOB_IMAGE_FORCE_POWERSHELL -ErrorAction SilentlyContinue
        }
    } finally {
        if ($null -ne $savedCodexHome) { $env:CODEX_HOME = $savedCodexHome } else { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
        if ($null -ne $savedUserProfile) { $env:USERPROFILE = $savedUserProfile } else { Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue }
        if ($null -ne $savedHome) { $env:HOME = $savedHome } else { Remove-Item Env:HOME -ErrorAction SilentlyContinue }
        if ($null -ne $savedHomeDrive) { $env:HOMEDRIVE = $savedHomeDrive } else { Remove-Item Env:HOMEDRIVE -ErrorAction SilentlyContinue }
        if ($null -ne $savedHomePath) { $env:HOMEPATH = $savedHomePath } else { Remove-Item Env:HOMEPATH -ErrorAction SilentlyContinue }
        Remove-Item Env:CUMOB_IMAGE_FORCE_POWERSHELL -ErrorAction SilentlyContinue
    }

    if ($env:OS -eq 'Windows_NT') {
    $env:CUMOB_IMAGE_FORCE_POWERSHELL = "1"
    $launcherDryRunText = (& $windowsImageLauncher `
        --prompt "Installer launcher configuration check" `
        --out (Join-Path $testRoot "unused-launcher.png") `
        --dry-run `
        --no-progress | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Windows image launcher PowerShell fallback failed with exit code $LASTEXITCODE" }
    $launcherDryRun = $launcherDryRunText | ConvertFrom-Json
    if ($launcherDryRun.image_model -ne "gpt-image-2.5") { throw "Windows image launcher selected the wrong model" }
    Remove-Item Env:CUMOB_IMAGE_FORCE_POWERSHELL

    }

    # No-prompt installs use the default .com endpoint even if config previously used .cn.
    $cnConfig = [IO.File]::ReadAllText($configPath).Replace(
        'base_url = "https://api.cumob.com/v1"',
        'base_url = "https://api.cumob.cn/v1"'
    )
    [IO.File]::WriteAllText($configPath, $cnConfig)
    & $localInstaller -NoPrompt
    $configAfterDefault = [IO.File]::ReadAllText($configPath)
    if (-not $configAfterDefault.Contains('base_url = "https://api.cumob.com/v1"')) {
        throw "no-prompt reinstall did not fall back to the default api.cumob.com endpoint"
    }

    # Explicit env override selects .cn and skips the prompt.
    $env:CUMOB_BASE_URL = "https://api.cumob.cn/v1"
    & $localInstaller -NoPrompt
    $configAfterCn = [IO.File]::ReadAllText($configPath)
    if (-not $configAfterCn.Contains('model_catalog_url = "https://api.cumob.cn/v1/codex/models"')) {
        throw "CUMOB_BASE_URL override did not select api.cumob.cn"
    }
    $cnDryRunText = (& $powerShellFallback `
        --prompt "CN endpoint configuration check" `
        --out (Join-Path $testRoot "unused-cn.png") `
        --dry-run `
        --no-progress | Out-String)
    $cnDryRun = $cnDryRunText | ConvertFrom-Json
    if ($cnDryRun.endpoint -ne "https://api.cumob.cn/v1/images/generations") {
        throw "PowerShell fallback did not follow api.cumob.cn base_url"
    }

    # Explicit env override can also force .com again.
    $env:CUMOB_BASE_URL = "https://api.cumob.com/v1"
    & $localInstaller -NoPrompt
    $configAfterEnv = [IO.File]::ReadAllText($configPath)
    if (-not $configAfterEnv.Contains('base_url = "https://api.cumob.com/v1"')) {
        throw "CUMOB_BASE_URL override was ignored"
    }
    Remove-Item Env:CUMOB_BASE_URL -ErrorAction SilentlyContinue

    $remoteOnlyDir = Join-Path $testRoot "remote-only-installer"
    New-Item -ItemType Directory -Force -Path $remoteOnlyDir | Out-Null
    Write-FixtureInstaller (Join-Path $remoteOnlyDir "install.ps1")

    $fixtureRemote = Join-Path $testRoot "remote-fixture"
    New-Item -ItemType Directory -Force -Path (Join-Path $fixtureRemote "payload") | Out-Null
    Copy-Item -LiteralPath (Join-Path $rootDir "payload\cumob-models.json") -Destination (Join-Path $fixtureRemote "payload\cumob-models.json")
    Copy-Item -LiteralPath (Join-Path $rootDir "payload\cumob-config.template.toml") -Destination (Join-Path $fixtureRemote "payload\cumob-config.template.toml")
    Copy-Item -LiteralPath (Join-Path $rootDir "payload\generate-image.ps1") -Destination (Join-Path $fixtureRemote "payload\generate-image.ps1")
    Copy-Item -LiteralPath (Join-Path $rootDir "payload\generate-image-windows.cmd") -Destination (Join-Path $fixtureRemote "payload\generate-image-windows.cmd")

    $remoteCatalogPath = Join-Path $fixtureRemote "payload\cumob-models.json"
    $remoteCatalog = [IO.File]::ReadAllText($remoteCatalogPath) | ConvertFrom-Json
    $oldDefault = @($remoteCatalog.models |
        Where-Object { $_.supported_in_api -eq $true -and $_.visibility -eq "list" } |
        Sort-Object { [int]$_.priority } |
        Select-Object -First 1)[0]
    $remoteCatalog.models = @($remoteCatalog.models | Where-Object { $_.slug -ne $oldDefault.slug })
    [IO.File]::WriteAllText($remoteCatalogPath, ($remoteCatalog | ConvertTo-Json -Depth 100))
    $newDefault = @($remoteCatalog.models |
        Where-Object { $_.supported_in_api -eq $true -and $_.visibility -eq "list" } |
        Sort-Object { [int]$_.priority } |
        Select-Object -First 1)[0]

    $env:CUMOB_TEST_CATALOG = $remoteCatalogPath
    $env:CUMOB_CONFIG_TEMPLATE_URL = (ConvertTo-FixtureFileUrl (Join-Path $fixtureRemote "payload\cumob-config.template.toml"))
    $env:CUMOB_POWERSHELL_FALLBACK_URL = (ConvertTo-FixtureFileUrl (Join-Path $fixtureRemote "payload\generate-image.ps1"))
    $env:CUMOB_WINDOWS_IMAGE_LAUNCHER_URL = (ConvertTo-FixtureFileUrl (Join-Path $fixtureRemote "payload\generate-image-windows.cmd"))
    $env:CUMOB_INSTALL_API_KEY = "test-key-two"
    $env:CUMOB_TEST_EXPECTED_KEY = "test-key-two"
    & (Join-Path $remoteOnlyDir "install.ps1") -NoPrompt

    $config = [IO.File]::ReadAllText($configPath)
    $auth = [IO.File]::ReadAllText($authPath) | ConvertFrom-Json
    $backups = Get-ChildItem -LiteralPath (Join-Path $env:CODEX_HOME "backups")
    if ([regex]::Matches($config, "(?m)^model_provider\s*=").Count -ne 1) { throw "reinstall duplicated model_provider" }
    if ($auth.OPENAI_API_KEY -ne "test-key-two") { throw "reinstall did not update API key" }
    if (-not $config.Contains(('model = "{0}"' -f $newDefault.slug))) { throw "remote catalog deletion did not update the default model" }
    if ($config -match '(?m)^model_catalog_json\s*=') { throw "Reinstall configured a local catalog" }
    if ($backups.Count -lt 2) { throw "reinstall did not create a second backup" }

    # Static coverage for automatic Node install controls.
    # Prefer real Node/Python when present; never force a live nodejs.org download in CI.
    $env:CUMOB_SKIP_NODE_INSTALL = "1"
    $skipDryRunOutput = & $localInstaller -DryRun 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "install.ps1 -DryRun failed under CUMOB_SKIP_NODE_INSTALL=1"
    }
    $runtimeContractInSource = $installerSource.Contains("Node.js LTS automatically") -or
        $installerSource.Contains("automatically if needed")
    if ($skipDryRunOutput -notmatch "Image runtime detected|automatically" -and -not $runtimeContractInSource) {
        throw "install.ps1 -DryRun did not report image runtime handling under CUMOB_SKIP_NODE_INSTALL=1"
    }
    Remove-Item Env:CUMOB_SKIP_NODE_INSTALL -ErrorAction SilentlyContinue

    # Static contract: auto-installed Node.js must be added to process PATH and user PATH.
    if (-not $installerSource.Contains('Add-DirectoryToProcessAndUserPath -Directory $currentLink')) {
        throw "install.ps1 does not add the installed Node.js directory to PATH"
    }
    if (-not $installerSource.Contains('[Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")')) {
        throw "install.ps1 does not persist Node.js to the user PATH"
    }

    function Get-TestSnapshot {
        $entries = @(Get-ChildItem -LiteralPath $env:CODEX_HOME -Recurse -File | Sort-Object FullName | ForEach-Object {
            $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        })
        return ($entries -join "`n")
    }
    function Assert-UnchangedFailure {
        param([string]$Expected)
        $before = Get-TestSnapshot
        $requestsBefore = @([IO.File]::ReadAllLines($env:CUMOB_TEST_REQUESTS)).Count
        $caught = $null
        try { & $localInstaller -NoPrompt 6>$null }
        catch { $caught = $_.Exception.Message }
        if (-not $caught -or $caught -notmatch $Expected) { throw "Expected preflight failure matching $Expected; got $caught" }
        if ($caught.Contains('test-key-')) { throw 'Preflight error leaked credentials.' }
        if ($before -cne (Get-TestSnapshot)) { throw 'Failed preflight modified installed user files or backups.' }
        $requestsAfter = @([IO.File]::ReadAllLines($env:CUMOB_TEST_REQUESTS)).Count
        if ($requestsAfter - $requestsBefore -gt 1) { throw 'Catalog request was retried.' }
    }
    foreach ($mode in @('401', 'redirect', 'timeout', 'invalid-json', 'oversize')) {
        $env:CUMOB_TEST_MODE = $mode
        Assert-UnchangedFailure 'Remote catalog'
    }
    Remove-Item Env:CUMOB_TEST_MODE
    $validCatalog = [IO.File]::ReadAllText($env:CUMOB_TEST_CATALOG)
    foreach ($badCatalog in @('{"models":[]}', '{"data":[]}')) {
        [IO.File]::WriteAllText($env:CUMOB_TEST_CATALOG, $badCatalog)
        Assert-UnchangedFailure 'Remote catalog'
    }
    [IO.File]::WriteAllText($env:CUMOB_TEST_CATALOG, $validCatalog)
    [IO.File]::AppendAllText($configPath, "`n[profiles.blocking]`nmodel_catalog_json = `"/profile/models.json`"`n")
    Assert-UnchangedFailure 'Profile blocking'
    $profileConfig = [IO.File]::ReadAllText($configPath).Replace('[profiles.blocking]', "[profiles.other]`nmodel_provider = `"other`"")
    [IO.File]::WriteAllText($configPath, $profileConfig)
    Remove-Item Env:CUMOB_INSTALL_API_KEY
    & $localInstaller -NoPrompt
    if (-not [IO.File]::ReadAllText($configPath).Contains('[profiles.other]')) { throw 'Other provider profile was removed.' }
    $savedHomeForFresh = $env:CODEX_HOME
    $env:CODEX_HOME = Join-Path $testRoot 'fresh-codex'
    $env:CUMOB_INSTALL_API_KEY = 'test-key-two'
    & $localInstaller -NoPrompt
    $freshConfig = [IO.File]::ReadAllText((Join-Path $env:CODEX_HOME 'config.toml'))
    if ($freshConfig.Contains('model_catalog_json') -or -not $freshConfig.Contains('api_key_model_discovery = true')) { throw 'Fresh remote discovery config is incorrect.' }
    if (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'model-catalogs')) { throw 'Fresh install created a local catalog directory.' }
    $env:CODEX_HOME = $savedHomeForFresh

    Write-Host "PowerShell installer integration test passed (CMD launcher checks run on Windows only)."

} catch {
    $diagnostic = $_.Exception.Message
    if ($configPath -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $tableLines = @([IO.File]::ReadAllLines($configPath) | Where-Object { $_ -match 'model_providers\.cumob' })
        $diagnostic = "$diagnostic; config_matches=$($tableLines -join ' | ')"
    }
    Write-Output ("::error title=Windows installer test failure::{0}" -f $diagnostic)
    throw
} finally {
    Remove-Item Env:CUMOB_INSTALL_API_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:CUMOB_SKILL_SOURCE_DIR -ErrorAction SilentlyContinue
    foreach ($name in @('CUMOB_TEST_CATALOG', 'CUMOB_TEST_EXPECTED_KEY', 'CUMOB_CODEX_CLIENT_VERSION', 'CUMOB_TEST_REQUESTS', 'CUMOB_TEST_MODE')) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    Remove-Item Env:CUMOB_CONFIG_TEMPLATE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:CUMOB_POWERSHELL_FALLBACK_URL -ErrorAction SilentlyContinue
    Remove-Item Env:CUMOB_WINDOWS_IMAGE_LAUNCHER_URL -ErrorAction SilentlyContinue
    Remove-Item Env:CUMOB_IMAGE_FORCE_POWERSHELL -ErrorAction SilentlyContinue
    Remove-Item Env:CUMOB_BASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:CUMOB_SKIP_NODE_INSTALL -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
