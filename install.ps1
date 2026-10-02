[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoPrompt
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadDir = Join-Path $scriptDir "payload"
$defaultInstallerArchiveUrl = "https://github.com/66964432/cumob-oneclick-installer/archive/refs/heads/main.zip"
$defaultSkillArchiveUrl = "https://github.com/66964432/cumob-media-generation/archive/refs/heads/main.zip"
$defaultModelsUrl = "https://raw.githubusercontent.com/66964432/cumob-oneclick-installer/main/payload/cumob-models.json"
$defaultTemplateUrl = "https://raw.githubusercontent.com/66964432/cumob-oneclick-installer/main/payload/cumob-config.template.toml"
$defaultPowerShellFallbackUrl = "https://raw.githubusercontent.com/66964432/cumob-oneclick-installer/main/payload/generate-image.ps1"
$defaultWindowsImageLauncherUrl = "https://raw.githubusercontent.com/66964432/cumob-oneclick-installer/main/payload/generate-image-windows.cmd"

function Download-File {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Write-Host "Downloading $Url"
    $parsedUrl = $null
    if ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsedUrl) -and $parsedUrl.IsFile) {
        Copy-Item -LiteralPath $parsedUrl.LocalPath -Destination $Destination -Force
        return
    }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

function Backup-Directory {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        return
    }

    # Copy the directory contents explicitly. PowerShell 5.1 can otherwise
    # treat a destination whose leaf matches the source leaf as a nested copy
    # and fail when the installer is run repeatedly in the same second.
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-PythonRuntimeCommand {
    foreach ($candidate in @("py", "python", "python3")) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if (-not $command) {
            continue
        }
        try {
            if ($candidate -eq "py") {
                & $command.Source -3 -c "import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)" | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    return @{
                        Kind = "python"
                        Command = $command.Source
                        Arguments = @("-3")
                        Detail = "Python 3 via py launcher"
                    }
                }
            } else {
                $major = (& $command.Source -c "import sys; print(sys.version_info[0])").Trim()
                if ($major -eq "3") {
                    return @{
                        Kind = "python"
                        Command = $command.Source
                        Arguments = @()
                        Detail = "Python 3 ($($command.Source))"
                    }
                }
            }
        } catch {
            continue
        }
    }
    return $null
}

function Get-NodeRuntimeCommand {
    $command = Get-Command node -ErrorAction SilentlyContinue
    if (-not $command) {
        return $null
    }
    try {
        $majorText = (& $command.Source -p "Number(process.versions.node.split('.')[0])").Trim()
        $major = [int]$majorText
        if ($major -ge 18) {
            return @{
                Kind = "node"
                Command = $command.Source
                Arguments = @()
                Detail = "Node.js $((& $command.Source -v).Trim())"
                Major = $major
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Get-ImageRuntimeStatus {
    $node = Get-NodeRuntimeCommand
    if ($node) {
        return $node
    }
    $python = Get-PythonRuntimeCommand
    if ($python) {
        return $python
    }
    return @{
        Kind = "none"
        Command = $null
        Arguments = @()
        Detail = "No Node.js 18+ or Python 3 runtime detected"
    }
}

function Add-DirectoryToProcessAndUserPath {
    param([Parameter(Mandatory = $true)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "PATH directory does not exist: $Directory"
    }

    $env:Path = "$Directory;" + ($env:Path -replace [regex]::Escape($Directory + ";"), "" -replace [regex]::Escape(";" + $Directory), "")

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $userPath = ""
    }
    $parts = @($userPath -split ";" | Where-Object { $_ -and ($_ -ne $Directory) })
    $newUserPath = ($Directory + ";" + ($parts -join ";")).TrimEnd(";")
    [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
}

function Resolve-NodeDownloadAsset {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
        "arm64"
    } elseif ([Environment]::Is64BitOperatingSystem) {
        "x64"
    } else {
        "x86"
    }

    if ($env:CUMOB_NODE_DIST_URL) {
        $fileName = [IO.Path]::GetFileName($env:CUMOB_NODE_DIST_URL.Split("?")[0])
        return @{
            Version = "custom"
            Arch = $arch
            Url = $env:CUMOB_NODE_DIST_URL
            FileName = if ($fileName) { $fileName } else { "node-win-$arch.zip" }
        }
    }

    $indexUrl = if ($env:CUMOB_NODE_INDEX_URL) { $env:CUMOB_NODE_INDEX_URL } else { "https://nodejs.org/dist/index.json" }
    Write-Host "Resolving Node.js LTS download from $indexUrl"
    $index = Invoke-RestMethod -Uri $indexUrl -UseBasicParsing
    $release = @(
        $index | Where-Object {
            $_.lts -and $_.lts -ne $false -and $_.files -contains ("win-" + $arch + "-zip")
        } | Select-Object -First 1
    )
    if (-not $release) {
        $release = @(
            $index | Where-Object {
                $_.lts -and $_.lts -ne $false -and $_.files -contains "win-x64-zip"
            } | Select-Object -First 1
        )
        if ($release) {
            $arch = "x64"
        }
    }
    if (-not $release) {
        throw "Unable to resolve a Node.js LTS Windows zip from $indexUrl."
    }

    $version = [string]$release.version
    if (-not $version.StartsWith("v")) {
        $version = "v$version"
    }
    $fileName = "node-$version-win-$arch.zip"
    $url = "https://nodejs.org/dist/$version/$fileName"
    return @{
        Version = $version
        Arch = $arch
        Url = $url
        FileName = $fileName
    }
}

function Install-NodeRuntime {
    if ($env:CUMOB_SKIP_NODE_INSTALL -eq "1") {
        throw "No Node.js 18+ or Python 3 runtime was detected, and CUMOB_SKIP_NODE_INSTALL=1 prevented automatic Node.js installation."
    }

    $asset = Resolve-NodeDownloadAsset
    $installRoot = if ($env:CUMOB_NODE_INSTALL_DIR) {
        $env:CUMOB_NODE_INSTALL_DIR
    } else {
        Join-Path $env:LOCALAPPDATA "cumob-nodejs"
    }
    $downloadRoot = Join-Path ([IO.Path]::GetTempPath()) ("cumob-node-setup-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $downloadRoot, $installRoot | Out-Null

    try {
        $archive = Join-Path $downloadRoot $asset.FileName
        Write-Host "No Node.js 18+ or Python 3 detected."
        Write-Host "Downloading Node.js $($asset.Version) ($($asset.Arch)) for image generation..."
        Download-File -Url $asset.Url -Destination $archive

        $extractDir = Join-Path $downloadRoot "extracted"
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        Expand-Archive -LiteralPath $archive -DestinationPath $extractDir -Force

        $payloadDir = Get-ChildItem -LiteralPath $extractDir -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "node.exe") -PathType Leaf } |
            Select-Object -First 1
        if (-not $payloadDir) {
            $directNode = Join-Path $extractDir "node.exe"
            if (Test-Path -LiteralPath $directNode -PathType Leaf) {
                $payloadDir = Get-Item -LiteralPath $extractDir
            }
        }
        if (-not $payloadDir) {
            throw "Downloaded Node.js archive did not contain node.exe."
        }

        $versionDirName = if ($asset.Version -and $asset.Version -ne "custom") {
            "node-$($asset.Version)-win-$($asset.Arch)"
        } else {
            $payloadDir.Name
        }
        $versionDir = Join-Path $installRoot $versionDirName
        if (Test-Path -LiteralPath $versionDir) {
            Remove-Item -LiteralPath $versionDir -Recurse -Force
        }
        # Destination must not exist yet so the extracted folder is renamed into place.
        Copy-Item -LiteralPath $payloadDir.FullName -Destination $versionDir -Recurse

        $nodeExeInVersion = Join-Path $versionDir "node.exe"
        if (-not (Test-Path -LiteralPath $nodeExeInVersion -PathType Leaf)) {
            throw "Node.js installation failed: $nodeExeInVersion is missing after extracting the archive."
        }

        $currentLink = Join-Path $installRoot "current"
        if (Test-Path -LiteralPath $currentLink) {
            Remove-Item -LiteralPath $currentLink -Recurse -Force
        }
        # Keep a stable PATH entry named "current". Do not use -LiteralPath with wildcards:
        # PowerShell treats "*" literally and copies nothing.
        Copy-Item -LiteralPath $versionDir -Destination $currentLink -Recurse

        $nodeExe = Join-Path $currentLink "node.exe"
        if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf)) {
            # Fall back to the versioned directory if the stable alias copy failed.
            Write-Warning "Stable Node.js alias is missing node.exe; using versioned install directory instead."
            $currentLink = $versionDir
            $nodeExe = $nodeExeInVersion
        }
        if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf)) {
            throw "Node.js installation failed: $nodeExe is missing."
        }

        Add-DirectoryToProcessAndUserPath -Directory $currentLink

        $versionText = (& $nodeExe -v).Trim()
        Write-Host "Installed Node.js $versionText to $currentLink"
        Write-Host "Added Node.js to the current process PATH and the user PATH."
        return $currentLink
    } finally {
        if (Test-Path -LiteralPath $downloadRoot) {
            Remove-Item -LiteralPath $downloadRoot -Recurse -Force
        }
    }
}

function Ensure-ImageRuntime {
    param(
        [switch]$DryRun
    )

    $status = Get-ImageRuntimeStatus
    if ($status.Kind -ne "none") {
        Write-Host "Image runtime detected: $($status.Detail)"
        return $status
    }

    if ($DryRun) {
        Write-Host "No Node.js 18+ or Python 3 detected. A real install would download and install Node.js LTS automatically."
        return $status
    }

    if ($env:CUMOB_SKIP_NODE_INSTALL -eq "1") {
        Write-Warning "No Node.js 18+ or Python 3 detected. Skipping automatic Node.js install because CUMOB_SKIP_NODE_INSTALL=1."
        return $status
    }

    Install-NodeRuntime | Out-Null
    $status = Get-ImageRuntimeStatus
    if ($status.Kind -ne "node") {
        throw "Automatic Node.js installation finished, but node.exe is still unavailable on PATH. Open a new terminal and re-run the installer, or install Node.js 18+ manually."
    }
    Write-Host "Image runtime ready: $($status.Detail)"
    return $status
}

function Get-DefaultModelFromCatalog {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    try {
        $catalog = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch {
        throw "Invalid model catalog JSON: $($_.Exception.Message)"
    }

    $models = @($catalog.models)
    $eligible = @($models | Where-Object {
        $_ -and
        $_.supported_in_api -eq $true -and
        $_.visibility -eq "list" -and
        -not [string]::IsNullOrWhiteSpace([string]$_.slug) -and
        $null -ne $_.priority -and
        -not [string]::IsNullOrWhiteSpace([string]$_.default_reasoning_level)
    })
    if ($eligible.Count -eq 0) {
        throw "Invalid model catalog: no visible API-supported model with a valid priority"
    }

    $selected = $null
    foreach ($candidate in $eligible) {
        if ($null -eq $selected -or [int]$candidate.priority -lt [int]$selected.priority) {
            $selected = $candidate
        }
    }
    return @{
        Slug = [string]$selected.slug
        ReasoningLevel = [string]$selected.default_reasoning_level
    }
}

function Ensure-RuntimeAssets {
    $catalogSource = Join-Path $payloadDir "cumob-models.json"
    $templateSource = Join-Path $payloadDir "cumob-config.template.toml"
    $powerShellFallbackSource = Join-Path $payloadDir "generate-image.ps1"
    $windowsImageLauncherSource = Join-Path $payloadDir "generate-image-windows.cmd"

    if ((Test-Path -LiteralPath $catalogSource -PathType Leaf) -and
        (Test-Path -LiteralPath $templateSource -PathType Leaf) -and
        (Test-Path -LiteralPath $powerShellFallbackSource -PathType Leaf) -and
        (Test-Path -LiteralPath $windowsImageLauncherSource -PathType Leaf)) {
        return @{
            CatalogSource = $catalogSource
            TemplateSource = $templateSource
            PowerShellFallbackSource = $powerShellFallbackSource
            WindowsImageLauncherSource = $windowsImageLauncherSource
            DownloadRoot = $null
        }
    }

    $downloadRoot = Join-Path ([IO.Path]::GetTempPath()) ("cumob-installer-runtime-" + [Guid]::NewGuid().ToString("N"))
    $payloadRuntime = Join-Path $downloadRoot "payload"
    New-Item -ItemType Directory -Force -Path $payloadRuntime | Out-Null

    $catalogTarget = Join-Path $payloadRuntime "cumob-models.json"
    $templateTarget = Join-Path $payloadRuntime "cumob-config.template.toml"
    $powerShellFallbackTarget = Join-Path $payloadRuntime "generate-image.ps1"
    $windowsImageLauncherTarget = Join-Path $payloadRuntime "generate-image-windows.cmd"

    if (Test-Path -LiteralPath $catalogSource -PathType Leaf) {
        Copy-Item -LiteralPath $catalogSource -Destination $catalogTarget
    } else {
        $modelsUrl = if ($env:CUMOB_MODELS_URL) { $env:CUMOB_MODELS_URL } else { $defaultModelsUrl }
        Download-File -Url $modelsUrl -Destination $catalogTarget
    }

    if (Test-Path -LiteralPath $templateSource -PathType Leaf) {
        Copy-Item -LiteralPath $templateSource -Destination $templateTarget
    } else {
        $templateUrl = if ($env:CUMOB_CONFIG_TEMPLATE_URL) { $env:CUMOB_CONFIG_TEMPLATE_URL } else { $defaultTemplateUrl }
        Download-File -Url $templateUrl -Destination $templateTarget
    }

    if (Test-Path -LiteralPath $powerShellFallbackSource -PathType Leaf) {
        Copy-Item -LiteralPath $powerShellFallbackSource -Destination $powerShellFallbackTarget
    } else {
        $powerShellFallbackUrl = if ($env:CUMOB_POWERSHELL_FALLBACK_URL) { $env:CUMOB_POWERSHELL_FALLBACK_URL } else { $defaultPowerShellFallbackUrl }
        Download-File -Url $powerShellFallbackUrl -Destination $powerShellFallbackTarget
    }

    if (Test-Path -LiteralPath $windowsImageLauncherSource -PathType Leaf) {
        Copy-Item -LiteralPath $windowsImageLauncherSource -Destination $windowsImageLauncherTarget
    } else {
        $windowsImageLauncherUrl = if ($env:CUMOB_WINDOWS_IMAGE_LAUNCHER_URL) { $env:CUMOB_WINDOWS_IMAGE_LAUNCHER_URL } else { $defaultWindowsImageLauncherUrl }
        Download-File -Url $windowsImageLauncherUrl -Destination $windowsImageLauncherTarget
    }

    if (-not (Test-Path -LiteralPath $catalogTarget -PathType Leaf) -or
        -not (Test-Path -LiteralPath $templateTarget -PathType Leaf) -or
        -not (Test-Path -LiteralPath $powerShellFallbackTarget -PathType Leaf) -or
        -not (Test-Path -LiteralPath $windowsImageLauncherTarget -PathType Leaf)) {
        throw "Failed to obtain installer assets from GitHub. Existing Codex files were not changed."
    }

    return @{
        CatalogSource = $catalogTarget
        TemplateSource = $templateTarget
        PowerShellFallbackSource = $powerShellFallbackTarget
        WindowsImageLauncherSource = $windowsImageLauncherTarget
        DownloadRoot = $downloadRoot
    }
}


function Normalize-CumobBaseUrl {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $trimmed = $Value.Trim().TrimEnd('/')
    if ($trimmed -notmatch '^(?i)https?://api\.cumob\.(com|cn)(?:/v1)?$') {
        return $null
    }
    if ($trimmed -notmatch '(?i)/v1$') {
        $trimmed = "$trimmed/v1"
    }
    return $trimmed
}

function Get-ExistingCumobBaseUrl {
    param([string]$ConfigPath)

    if (-not $ConfigPath -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return $null
    }

    $configText = [IO.File]::ReadAllText($ConfigPath)
    $match = [regex]::Match(
        $configText,
        '(?im)^\s*base_url\s*=\s*"(https?://api\.cumob\.(?:com|cn)(?:/v1)?)"\s*(?:#.*)?$'
    )
    if (-not $match.Success) {
        return $null
    }
    return (Normalize-CumobBaseUrl $match.Groups[1].Value)
}

function Read-CumobBaseUrlChoice {
    param(
        [int]$TimeoutSeconds = 15,
        [string]$DefaultBaseUrl = 'https://api.cumob.com/v1'
    )

    $defaultUrl = Normalize-CumobBaseUrl $DefaultBaseUrl
    if (-not $defaultUrl) {
        $defaultUrl = 'https://api.cumob.com/v1'
    }
    $cnUrl = 'https://api.cumob.cn/v1'

    Write-Host ""
    Write-Host "Select CUMOB API endpoint:"
    Write-Host "  1) $defaultUrl  (default)"
    Write-Host "  2) $cnUrl"
    Write-Host "Press 1 or 2 within $TimeoutSeconds seconds. Empty input or timeout keeps the default."

    $choiceExe = Get-Command choice.exe -ErrorAction SilentlyContinue
    if ($choiceExe) {
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & choice.exe /C 12 /N /T $TimeoutSeconds /D 1 /M "Endpoint" | Out-Null
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorAction
        }
        if ($exitCode -eq 2) {
            Write-Host "Selected: $cnUrl"
            return $cnUrl
        }
        Write-Host "Selected: $defaultUrl"
        return $defaultUrl
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $buffer = New-Object Text.StringBuilder
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq "Enter") {
                break
            }
            if ($key.Key -eq "Backspace") {
                if ($buffer.Length -gt 0) {
                    [void]$buffer.Remove($buffer.Length - 1, 1)
                    Write-Host "`b `b" -NoNewline
                }
                continue
            }
            if ($key.KeyChar -match '[12]') {
                [void]$buffer.Clear()
                [void]$buffer.Append($key.KeyChar)
                Write-Host $key.KeyChar
                break
            }
        }
        Start-Sleep -Milliseconds 100
    }

    $choice = $buffer.ToString().Trim()
    if ($choice -eq "2") {
        Write-Host "Selected: $cnUrl"
        return $cnUrl
    }
    if (-not $choice) {
        Write-Host "No selection within $TimeoutSeconds seconds. Using default: $defaultUrl"
    } else {
        Write-Host "Selected: $defaultUrl"
    }
    return $defaultUrl
}

function Resolve-CumobBaseUrl {
    param(
        [string]$ConfigPath,
        [switch]$NoPrompt,
        [string]$DefaultBaseUrl = 'https://api.cumob.com/v1'
    )

    $fromEnv = Normalize-CumobBaseUrl $env:CUMOB_BASE_URL
    if ($fromEnv) {
        Write-Host "Using CUMOB_BASE_URL: $fromEnv"
        return $fromEnv
    }

    $defaultUrl = Normalize-CumobBaseUrl $DefaultBaseUrl
    if (-not $defaultUrl) {
        $defaultUrl = 'https://api.cumob.com/v1'
    }

    $existing = Get-ExistingCumobBaseUrl -ConfigPath $ConfigPath
    if ($existing) {
        Write-Host "Existing CUMOB endpoint in config.toml: $existing"
    }

    if ($NoPrompt -or [Console]::IsInputRedirected) {
        Write-Host "Using default CUMOB endpoint: $defaultUrl"
        return $defaultUrl
    }

    return (Read-CumobBaseUrlChoice -TimeoutSeconds 15 -DefaultBaseUrl $defaultUrl)
}

function Add-WindowsImageFallback {
    param(
        [Parameter(Mandatory = $true)][string]$SkillDirectory,
        [Parameter(Mandatory = $true)][string]$PowerShellFallbackSource,
        [Parameter(Mandatory = $true)][string]$WindowsImageLauncherSource
    )

    $skillScriptsDir = Join-Path $SkillDirectory "scripts"
    New-Item -ItemType Directory -Force -Path $skillScriptsDir | Out-Null
    Copy-Item -LiteralPath $PowerShellFallbackSource `
        -Destination (Join-Path $skillScriptsDir "generate-image.ps1") `
        -Force
    Copy-Item -LiteralPath $WindowsImageLauncherSource `
        -Destination (Join-Path $skillScriptsDir "generate-image-windows.cmd") `
        -Force

    $skillInstructionsPath = Join-Path $SkillDirectory "SKILL.md"
    $skillInstructions = [IO.File]::ReadAllText($skillInstructionsPath)
    $skillInstructions = $skillInstructions.Replace(
        'base_url = "http://api.cumob.com/v1"',
        'base_url = "https://api.cumob.com/v1"'
    )
    $skillInstructions = $skillInstructions.Replace(
        'For CUMOB, configure `base_url = "https://api.cumob.com/v1"`, `image_api = "images"`, and `image_model = "gpt-image-2"`.',
        'For CUMOB, configure `image_api = "images"` and `image_model = "gpt-image-2.5"`. Use either `base_url = "https://api.cumob.com/v1"` or `base_url = "https://api.cumob.cn/v1"`; both domains are valid, and the scripts always follow the provider `base_url` from Codex config.'
    )
    $skillInstructions = $skillInstructions.Replace(
        'For CUMOB, configure `base_url = "http://api.cumob.com/v1"`, `image_api = "images"`, and `image_model = "gpt-image-2"`.',
        'For CUMOB, configure `image_api = "images"` and `image_model = "gpt-image-2.5"`. Use either `base_url = "https://api.cumob.com/v1"` or `base_url = "https://api.cumob.cn/v1"`; both domains are valid, and the scripts always follow the provider `base_url` from Codex config.'
    )
    $skillInstructions = $skillInstructions.Replace(
        'image_model = "gpt-image-2"',
        'image_model = "gpt-image-2.5"'
    )
    $skillInstructions = $skillInstructions.Replace(
        'If neither Node nor Python is available, stop and tell the user one local runtime is required. Do not try to install one unless the user explicitly approves it.',
        'On native Windows, use `scripts\generate-image-windows.cmd`. Prefer Node.js 18+ or Python 3; the one-click Windows installer auto-installs Node.js LTS when neither is present. The launcher can still fall back to Windows PowerShell if needed. On macOS or Linux, stop if neither Node.js nor Python is available, and do not install one unless the user explicitly approves it.'
    )

    $fallbackMarkerBegin = "<!-- BEGIN CUMOB WINDOWS POWERSHELL FALLBACK -->"
    $fallbackMarkerEnd = "<!-- END CUMOB WINDOWS POWERSHELL FALLBACK -->"
    $fallbackInstructions = @'

<!-- BEGIN CUMOB WINDOWS POWERSHELL FALLBACK -->
## Native Windows Launcher

On native Windows, invoke `scripts\generate-image-windows.cmd` instead of calling Node.js or Python directly. Prefer Node.js 18+ or Python 3 for full feature parity. The one-click Windows installer detects these runtimes and automatically downloads Node.js LTS into `%LOCALAPPDATA%\cumob-nodejs` when neither is present. The launcher then selects Node.js 18+ when available, then Python 3, and finally the bundled Windows PowerShell implementation as an emergency fallback.

```powershell
& "<skill-dir>\scripts\generate-image-windows.cmd" --prompt "A precise image prompt" --out "<absolute-output-file>" --size 1536x1024 --quality high
```

Run the launcher exactly once and wait for it to finish. Do not retry because the command is still running, and do not switch to another image-generation skill merely because a temporary fallback path is used. The PowerShell fallback supports both configured Images and Responses backends; it uploads original input files without the optional local image optimization performed by the Node.js and Python implementations. The launcher and PowerShell fallback automatically resolve Codex home from CODEX_HOME, the installed skill path, or the user profile. If a restricted shell still cannot locate config.toml / auth.json, pass an absolute --codex-home once.

Always pass absolute paths to `--out`, `--image`, and `--mask` when the Codex workspace is on a UNC share such as `\\Mac\...`. CMD cannot preserve a UNC current directory, but the PowerShell fallback can read and write absolute UNC paths.

CUMOB accepts both `https://api.cumob.com/v1` and `https://api.cumob.cn/v1`. Image scripts always follow the provider `base_url` from Codex config and do not hardcode one domain.
<!-- END CUMOB WINDOWS POWERSHELL FALLBACK -->
'@
    $beginIndex = $skillInstructions.IndexOf($fallbackMarkerBegin)
    $endIndex = $skillInstructions.IndexOf($fallbackMarkerEnd)
    if ($beginIndex -ge 0 -and $endIndex -gt $beginIndex) {
        $endIndex = $endIndex + $fallbackMarkerEnd.Length
        while ($endIndex -lt $skillInstructions.Length -and ($skillInstructions[$endIndex] -eq "`r" -or $skillInstructions[$endIndex] -eq "`n")) {
            $endIndex++
        }
        $skillInstructions = $skillInstructions.Substring(0, $beginIndex).TrimEnd() +
            [Environment]::NewLine + [Environment]::NewLine +
            $fallbackInstructions.Trim() +
            [Environment]::NewLine + [Environment]::NewLine +
            $skillInstructions.Substring($endIndex).TrimStart()
    } else {
        $runtimeAnchor = "## Runtime And Dependencies"
        if ($skillInstructions.Contains($runtimeAnchor)) {
            $skillInstructions = $skillInstructions.Replace(
                $runtimeAnchor,
                ($fallbackInstructions.Trim() + [Environment]::NewLine + [Environment]::NewLine + $runtimeAnchor)
            )
        } else {
            $skillInstructions = $skillInstructions.TrimEnd() + [Environment]::NewLine + $fallbackInstructions.TrimStart()
        }
    }

    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText(
        $skillInstructionsPath,
        ($skillInstructions.TrimEnd() + [Environment]::NewLine),
        $utf8NoBom
    )
}

$codexHome = if ($env:CODEX_HOME) {
    $env:CODEX_HOME
} else {
    Join-Path $HOME ".codex"
}

$skillsDir = Join-Path $codexHome "skills"
$skillTarget = Join-Path $skillsDir "cumob-media-generation"
$legacySkillTarget = Join-Path $skillsDir "cumob-media-generation4codex"
$previousLegacySkillTarget = Join-Path $skillsDir "cumob-image-generation4codex"
$catalogDir = Join-Path $codexHome "model-catalogs"
$catalogTarget = Join-Path $catalogDir "cumob-models.json"
$configPath = Join-Path $codexHome "config.toml"
$authPath = Join-Path $codexHome "auth.json"

if ($DryRun) {
    Write-Host "Dry run only; no files will be changed."
    Write-Host "Codex home: $codexHome"
    Write-Host "Skill target: $skillTarget"
    Write-Host "Catalog target: $catalogTarget"
    Write-Host "Config target: $configPath"
    Write-Host "Auth target: $authPath"
    $null = Ensure-ImageRuntime -DryRun
    $dryRunInstallerUrl = if ($env:CUMOB_INSTALLER_URL) { $env:CUMOB_INSTALLER_URL } else { $defaultInstallerArchiveUrl }
    $dryRunSkillUrl = if ($env:CUMOB_SKILL_URL) { $env:CUMOB_SKILL_URL } else { $defaultSkillArchiveUrl }
    $dryRunModelsUrl = if ($env:CUMOB_MODELS_URL) { $env:CUMOB_MODELS_URL } else { $defaultModelsUrl }
    $dryRunPowerShellFallbackUrl = if ($env:CUMOB_POWERSHELL_FALLBACK_URL) { $env:CUMOB_POWERSHELL_FALLBACK_URL } else { $defaultPowerShellFallbackUrl }
    Write-Host "Installer source: $dryRunInstallerUrl"
    Write-Host "Skill source: $dryRunSkillUrl"
    Write-Host "Models source: $dryRunModelsUrl"
    Write-Host "Windows PowerShell fallback source: $dryRunPowerShellFallbackUrl"
    $dryRunRuntime = Ensure-ImageRuntime -DryRun
    if ($dryRunRuntime.Kind -eq "none") {
        Write-Host "Image runtime handling: Node.js LTS will be installed automatically if needed."
        Write-Output "Image runtime handling: Node.js LTS will be installed automatically if needed."
    } else {
        Write-Host "Image runtime handling: $($dryRunRuntime.Detail)"
        Write-Output "Image runtime handling: $($dryRunRuntime.Detail)"
    }
    exit 0
}

$runtimeAssets = Ensure-RuntimeAssets
$catalogSource = $runtimeAssets.CatalogSource
$templateSource = $runtimeAssets.TemplateSource
$powerShellFallbackSource = $runtimeAssets.PowerShellFallbackSource
$windowsImageLauncherSource = $runtimeAssets.WindowsImageLauncherSource
$downloadRoot = $runtimeAssets.DownloadRoot
$catalogDefaults = Get-DefaultModelFromCatalog -Path $catalogSource
$defaultModel = $catalogDefaults.Slug
$defaultReasoningLevel = $catalogDefaults.ReasoningLevel

try {
    $imageRuntime = Ensure-ImageRuntime
    $skillSource = $env:CUMOB_SKILL_SOURCE_DIR
    if ([string]::IsNullOrWhiteSpace($skillSource)) {
        if ([string]::IsNullOrWhiteSpace($downloadRoot)) {
            $downloadRoot = Join-Path ([IO.Path]::GetTempPath()) ("cumob-skill-download-" + [Guid]::NewGuid().ToString("N"))
        }
        $skillArchive = Join-Path $downloadRoot "cumob-media-generation.zip"
        $skillExtractDir = Join-Path $downloadRoot "skill-extracted"
        New-Item -ItemType Directory -Force -Path $skillExtractDir | Out-Null

        if ($env:CUMOB_SKILL_ARCHIVE -and (Test-Path -LiteralPath $env:CUMOB_SKILL_ARCHIVE -PathType Leaf)) {
            Copy-Item -LiteralPath $env:CUMOB_SKILL_ARCHIVE -Destination $skillArchive
        } else {
            $skillUrl = if ($env:CUMOB_SKILL_ARCHIVE) {
                $env:CUMOB_SKILL_ARCHIVE
            } elseif ($env:CUMOB_SKILL_URL) {
                $env:CUMOB_SKILL_URL
            } else {
                $defaultSkillArchiveUrl
            }
            Download-File -Url $skillUrl -Destination $skillArchive
        }

        Expand-Archive -LiteralPath $skillArchive -DestinationPath $skillExtractDir -Force
        $skillSource = Get-ChildItem -LiteralPath $skillExtractDir -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "SKILL.md") -PathType Leaf } |
            Select-Object -First 1 -ExpandProperty FullName
    }

    $nodeSkillScript = if ($skillSource) { Join-Path $skillSource "scripts\generate-image.mjs" } else { "" }
    $pythonSkillScript = if ($skillSource) { Join-Path $skillSource "scripts\generate-image.py" } else { "" }
    if ([string]::IsNullOrWhiteSpace($skillSource) -or
        -not (Test-Path -LiteralPath (Join-Path $skillSource "SKILL.md") -PathType Leaf) -or
        (-not (Test-Path -LiteralPath $nodeSkillScript -PathType Leaf) -and
         -not (Test-Path -LiteralPath $pythonSkillScript -PathType Leaf))) {
        throw "Downloaded Skill archive is invalid or incomplete. Existing Codex files were not changed."
    }

    $skillVersion = "latest"
    $skillVersionPath = Join-Path $skillSource "VERSION"
    if (Test-Path -LiteralPath $skillVersionPath -PathType Leaf) {
        $skillVersion = ([IO.File]::ReadAllText($skillVersionPath)).Trim()
    }

    $apiKey = $env:CUMOB_INSTALL_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey) -and -not $NoPrompt) {
        $secureKey = Read-Host "CUMOB API Key (leave blank to keep existing auth.json)" -AsSecureString
        $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        try {
            $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
        }
    }

    $cumobBaseUrl = Resolve-CumobBaseUrl -ConfigPath $configPath -NoPrompt:$NoPrompt

    $authObject = $null
    if (-not [string]::IsNullOrWhiteSpace($apiKey)) {
        if (Test-Path -LiteralPath $authPath -PathType Leaf) {
            $authText = [IO.File]::ReadAllText($authPath)
            if ([string]::IsNullOrWhiteSpace($authText)) {
                $authObject = [PSCustomObject]@{}
            } else {
                $authObject = $authText | ConvertFrom-Json
                if ($null -eq $authObject -or $authObject -is [Array]) {
                    throw "$authPath must contain a JSON object."
                }
            }
        } else {
            $authObject = [PSCustomObject]@{}
        }
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupDir = Join-Path $codexHome "backups\cumob-installer-$timestamp"
    if (Test-Path -LiteralPath $backupDir) {
        $backupDir = "$backupDir-$PID"
    }

    New-Item -ItemType Directory -Force -Path $backupDir, $skillsDir, $catalogDir | Out-Null

    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupDir "config.toml")
    }
    if (Test-Path -LiteralPath $authPath -PathType Leaf) {
        Copy-Item -LiteralPath $authPath -Destination (Join-Path $backupDir "auth.json")
    }
    if (Test-Path -LiteralPath $catalogTarget -PathType Leaf) {
        Copy-Item -LiteralPath $catalogTarget -Destination (Join-Path $backupDir "cumob-models.json")
    }
    Backup-Directory `
        -Source $skillTarget `
        -Destination (Join-Path $backupDir "cumob-media-generation")
    Backup-Directory `
        -Source $legacySkillTarget `
        -Destination (Join-Path $backupDir "cumob-media-generation4codex")
    Backup-Directory `
        -Source $previousLegacySkillTarget `
        -Destination (Join-Path $backupDir "cumob-image-generation4codex")

    $tempSkill = Join-Path $skillsDir ".cumob-media-generation.tmp.$PID"
    if (Test-Path -LiteralPath $tempSkill) {
        Remove-Item -LiteralPath $tempSkill -Recurse -Force
    }
    Copy-Item -LiteralPath $skillSource -Destination $tempSkill -Recurse
    Add-WindowsImageFallback `
        -SkillDirectory $tempSkill `
        -PowerShellFallbackSource $powerShellFallbackSource `
        -WindowsImageLauncherSource $windowsImageLauncherSource
    if (Test-Path -LiteralPath $skillTarget) {
        Remove-Item -LiteralPath $skillTarget -Recurse -Force
    }
    Move-Item -LiteralPath $tempSkill -Destination $skillTarget
    if (Test-Path -LiteralPath $legacySkillTarget) {
        Remove-Item -LiteralPath $legacySkillTarget -Recurse -Force
    }
    if (Test-Path -LiteralPath $previousLegacySkillTarget) {
        Remove-Item -LiteralPath $previousLegacySkillTarget -Recurse -Force
    }
    Copy-Item -LiteralPath $catalogSource -Destination $catalogTarget -Force

    $filteredLines = New-Object "System.Collections.Generic.List[string]"
    $inManagedBlock = $false
    $section = ""
    $skipSection = $false

    $existingLines = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        [IO.File]::ReadAllLines($configPath)
    } else {
        @()
    }

    foreach ($line in $existingLines) {
        $trimmedLine = $line.Trim()
        if ($line -eq "# BEGIN CUMOB CODEX ONE-CLICK INSTALLER") {
            $inManagedBlock = $true
            continue
        }

        if ($inManagedBlock) {
            if ($line -eq "# END CUMOB CODEX ONE-CLICK INSTALLER") {
                $inManagedBlock = $false
                $section = ""
                $skipSection = $false
            }
            continue
        }

        if ($trimmedLine -match '^\[model_providers\.(?:cumob|"cumob"|''cumob'')\]\s*(?:#.*)?$') {
            $skipSection = $true
            continue
        }

        if ($line -match '^\s*\[([^\[\]]+)\]\s*(?:#.*)?$') {
            $section = ($Matches[1] -replace '\s', '').ToLowerInvariant()
            $skipSection = @(
                "model_providers.cumob",
                'model_providers."cumob"',
                "model_providers.'cumob'"
            ) -contains $section

            if ($skipSection) {
                continue
            }
        }

        if ($skipSection) {
            continue
        }

        if ($section -eq "" -and
            $line -match '^\s*(model_provider|model|disable_response_storage|model_catalog_json|model_reasoning_effort)\s*=') {
            continue
        }

        $filteredLines.Add($line)
    }

    $catalogTomlPath = $catalogTarget.Replace("\", "/").Replace('"', '\"')
    $templateText = [IO.File]::ReadAllText($templateSource)
    $managedBody = $templateText.
        Replace("{{MODEL_CATALOG_PATH}}", [string]$catalogTomlPath).
        Replace("{{DEFAULT_MODEL}}", [string]$defaultModel).
        Replace("{{DEFAULT_REASONING_LEVEL}}", [string]$defaultReasoningLevel).
        Replace("{{CUMOB_BASE_URL}}", [string]$cumobBaseUrl).
        TrimEnd()
    $managedLines = New-Object "System.Collections.Generic.List[string]"
    $managedLines.Add("# BEGIN CUMOB CODEX ONE-CLICK INSTALLER")
    foreach ($line in ($managedBody -split "`r?`n")) {
        $managedLines.Add($line)
    }
    $managedLines.Add("# END CUMOB CODEX ONE-CLICK INSTALLER")

    while ($filteredLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($filteredLines[0])) {
        $filteredLines.RemoveAt(0)
    }

    $newLines = New-Object "System.Collections.Generic.List[string]"
    $newLines.AddRange([string[]]$managedLines)
    if ($filteredLines.Count -gt 0) {
        $newLines.Add("")
        $newLines.AddRange([string[]]$filteredLines)
    }

    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    $tempConfig = "$configPath.cumob-installer-$PID.tmp"
    [IO.File]::WriteAllText($tempConfig, (($newLines -join [Environment]::NewLine) + [Environment]::NewLine), $utf8NoBom)
    Move-Item -LiteralPath $tempConfig -Destination $configPath -Force

    if (-not [string]::IsNullOrWhiteSpace($apiKey)) {
        $keyProperty = $authObject.PSObject.Properties["OPENAI_API_KEY"]
        if ($null -eq $keyProperty) {
            $authObject | Add-Member -MemberType NoteProperty -Name "OPENAI_API_KEY" -Value $apiKey
        } else {
            $authObject.OPENAI_API_KEY = $apiKey
        }

        $tempAuth = "$authPath.cumob-installer-$PID.tmp"
        $authJson = $authObject | ConvertTo-Json -Depth 100
        [IO.File]::WriteAllText($tempAuth, ($authJson + [Environment]::NewLine), $utf8NoBom)
        Move-Item -LiteralPath $tempAuth -Destination $authPath -Force
    } elseif (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) {
        Write-Warning "No API Key was provided. Run the installer again to complete authentication."
    }

    $installedPowerShellFallback = Join-Path $skillTarget "scripts\generate-image.ps1"
    $fallbackValidationText = (& $installedPowerShellFallback `
        --prompt "Installer configuration check" `
        --out (Join-Path ([IO.Path]::GetTempPath()) "cumob-installer-validation.png") `
        --dry-run `
        --no-progress | Out-String)
    $fallbackValidation = $fallbackValidationText | ConvertFrom-Json
    $expectedEndpoint = "$cumobBaseUrl/images/generations"
    if ($fallbackValidation.image_api -ne "images" -or
        $fallbackValidation.endpoint -ne $expectedEndpoint -or
        $fallbackValidation.image_model -ne "gpt-image-2.5") {
        throw "Windows PowerShell image fallback validation failed. Existing Codex files were backed up to $backupDir."
    }

    $finalRuntime = Get-ImageRuntimeStatus
    if ($finalRuntime.Kind -eq "node") {
        $runtimeMessage = "Image runtime: $($finalRuntime.Detail). Windows PowerShell fallback also installed."
    } elseif ($finalRuntime.Kind -eq "python") {
        $runtimeMessage = "Image runtime: $($finalRuntime.Detail). Windows PowerShell fallback also installed."
    } else {
        $runtimeMessage = "No Node.js 18+ or Python 3 runtime was detected; image generation will use the Windows PowerShell fallback. Re-run the installer with network access to auto-install Node.js, or install Node.js 18+ / Python 3 manually."
    }

    Write-Host ""
    Write-Host "codex 一键接入自定义路由 - cumob 篇 安装完成。"
    Write-Host "Backup: $backupDir"
    Write-Host "Skill: $skillTarget (downloaded version: $skillVersion)"
    Write-Host "Model catalog: $catalogTarget"
    Write-Host "Config: $configPath"
    Write-Host "CUMOB endpoint: $cumobBaseUrl"
    Write-Host $runtimeMessage
    Write-Host "Restart Codex or create a new task to reload the skill and model catalog."
}
finally {
    if ($downloadRoot -and (Test-Path -LiteralPath $downloadRoot)) {
        Remove-Item -LiteralPath $downloadRoot -Recurse -Force
    }
}
