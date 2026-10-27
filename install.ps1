# Installs the oyzu CLI from a GitHub release on Windows (PowerShell 5.1 and 7+).
# Reference: https://docs.oyzu.ai/docs/reference/install-script
#
#   irm https://docs.oyzu.ai/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://docs.oyzu.ai/install.ps1))) -Channel beta
#
# It downloads the release executable for this platform (and its oyzu-shim
# companion when the release has one), refuses it unless its SHA-256 digest
# matches the digest GitHub reports, installs it into %LOCALAPPDATA%\Oyzu\bin and
# runs `oyzu --version`. It also downloads the release's Linux oyzu for this
# architecture, verified the same way, and runs `oyzu engine install --linux`, so
# isolated builds have their Linux engine. It then runs `oyzu shell install`, which activates oyzu
# in your shells and puts oyzu and its shims on your user Path (the registry, so
# IDEs and new processes see them); -NoModifyPath skips that.
param(
  [string]$Channel = $env:OYZU_CHANNEL,
  [string]$Version = $env:OYZU_VERSION,
  [string]$InstallDir = $env:OYZU_INSTALL_DIR,
  [switch]$NoModifyPath,
  [switch]$ModifyPath, # the old opt-in; setup is now the default, so this does nothing
  [switch]$Help
)

function Show-OyzuInstallHelp {
  Write-Host @'
Install the oyzu CLI from a GitHub release.

Usage: install.ps1 [-Channel NAME] [-Version TAG] [-InstallDir DIR] [-NoModifyPath] [-Help]

  -Channel NAME    stable (default), beta (release candidates) or nightly: install
                   the newest release of that channel and let `oyzu self` follow it
  -Version TAG     install this release tag (for example oyzu/v0.2.0) and pin it
  -InstallDir DIR  install into DIR (default: %LOCALAPPDATA%\Oyzu\bin)
  -NoModifyPath    do not set up your shells and Path (by default the installer
                   runs `oyzu shell install`: shell activation, oyzu and the
                   shims on your user Path)
  -Help            show this help

Environment:
  OYZU_CHANNEL, OYZU_VERSION, OYZU_INSTALL_DIR, OYZU_NO_MODIFY_PATH=1   same as the options
  GH_TOKEN or GITHUB_TOKEN   GitHub token, for a private OYZU_RELEASE_REPO or the rate limit
  OYZU_RELEASE_REPO          release repository (default: oyzuai/oyzu-releases)
  OYZU_API_BASE              GitHub API (default: https://api.github.com)
  OYZU_DOWNLOAD_BASE         release downloads (default: https://github.com)

Exit status: 0 installed, 1 failed, 2 usage error, 3 digest refused.
'@
}

function Stop-OyzuInstall([int]$Code, [string]$Message) {
  $e = New-Object System.Exception $Message
  $e.Data['OyzuExit'] = $Code
  throw $e
}

# Sends one GET request. With -OutFile the body is saved; otherwise it is parsed
# as JSON. The token goes only in a request header; PowerShell drops it when
# GitHub redirects the download to another host. Failures are explained plainly.
function Invoke-OyzuGet([hashtable]$Ctx, [string]$Url, [string]$Accept, [string]$What, [string]$OutFile) {
  $headers = @{ 'Accept' = $Accept; 'X-GitHub-Api-Version' = '2022-11-28' }
  if ($Ctx.Token) { $headers['Authorization'] = 'Bearer ' + $Ctx.Token }
  try {
    if ($OutFile) {
      Invoke-WebRequest -UseBasicParsing -Uri $Url -Headers $headers -OutFile $OutFile
      return
    }
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -Headers $headers
    return ($response.Content | ConvertFrom-Json)
  } catch {
    $failure = $_.Exception
    $status = 0
    if ($failure.Response) { $status = [int]$failure.Response.StatusCode }
    $repo = $Ctx.Repo
    switch ($status) {
      0 { Stop-OyzuInstall 1 "could not connect to download $What ($($failure.Message)). Check the network connection or proxy, then run again." }
      401 { Stop-OyzuInstall 1 "GitHub rejected the token in GH_TOKEN or GITHUB_TOKEN (HTTP 401) for $What. Check that it is valid and not expired." }
      { $_ -eq 403 -or $_ -eq 429 } { Stop-OyzuInstall 1 "GitHub refused $What (HTTP $status). Anonymous requests are limited to 60 an hour: set GH_TOKEN to a GitHub token, or try again later." }
      404 {
        if (-not $Ctx.Token) {
          Stop-OyzuInstall 1 ("GitHub answered 404 Not Found for $What. Either it does not exist, or $repo is private; if OYZU_RELEASE_REPO names a private repository you can read, " +
            'run again with a token: $env:GH_TOKEN = (gh auth token); irm https://docs.oyzu.ai/install.ps1 | iex')
        }
        Stop-OyzuInstall 1 "GitHub answered 404 Not Found for $What with your token: it does not exist, or the token cannot read $repo."
      }
      default { Stop-OyzuInstall 1 "GitHub answered HTTP $status for $What." }
    }
  }
}

# Downloads one asset into $Stage\$Target and checks the digest the release reports.
function Get-OyzuAsset([hashtable]$Ctx, $Release, $Asset, [string]$Stage, [string]$Target) {
  $tag = $Release.tag_name
  $expected = [string]$Asset.digest
  if (-not $expected.StartsWith('sha256:')) {
    Stop-OyzuInstall 3 "release $tag reports no SHA-256 digest for $($Asset.name), so the download cannot be verified; nothing was installed."
  }
  $path = Join-Path $Stage $Target
  if ($Ctx.Token) { $url = "$($Ctx.Api)/repos/$($Ctx.Repo)/releases/assets/$($Asset.id)" }
  else { $url = "$($Ctx.Download)/$($Ctx.Repo)/releases/download/$tag/$($Asset.name)" }
  Invoke-OyzuGet $Ctx $url 'application/octet-stream' "$($Asset.name) from release $tag" $path
  $actual = 'sha256:' + (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
  if ($actual -ne $expected) {
    Stop-OyzuInstall 3 "$($Asset.name) from release $tag has digest $actual, but the release reports $expected. The download was refused; nothing was installed."
  }
  return $path
}

# The channel a release tag belongs to, as `oyzu self` reads it: 1 stable (no
# prerelease part), 2 beta (-rc, -beta, -alpha), 3 nightly (-nightly, or a nightly part after a
# prerelease number: -alpha.0.nightly, -rc.1.nightly), 9 none of them.
function Get-OyzuChannelRank([string]$Tag) {
  $v = $Tag -replace '^oyzu/', '' -replace '^v', ''
  $dash = $v.IndexOf('-')
  if ($dash -lt 0) { return 1 }
  $pre = $v.Substring($dash + 1)
  if ($pre -match '^nightly(\.|$)' -or $pre -match '^(rc|beta|alpha)\..*\.nightly(\.|$)') { return 3 }
  if ($pre -match '^(rc|beta|alpha)(\.|$)') { return 2 }
  return 9
}

# Runs `oyzu engine install --linux` with the release's Linux oyzu, so isolated
# builds have their Linux engine. A failure does not undo the install.
function Initialize-OyzuEngine([string]$Exe, [string]$Linux, [string]$Name) {
  Push-Location (Split-Path -Parent $Linux)
  $prior = $env:OYZU_SELF_UPDATE; $env:OYZU_SELF_UPDATE = 'off'  # no update check right after installing
  try { & $Exe engine install --linux $Linux | Out-Null } finally { Pop-Location; $env:OYZU_SELF_UPDATE = $prior }
  if ($LASTEXITCODE -eq 0) { Write-Host "Installed the Linux engine for isolated builds ($Name)" }
  else { [Console]::Error.WriteLine("oyzu install: oyzu is installed, but setting up the Linux engine for isolated builds failed. Run it again later with the same release's ${Name}: & '$Exe' engine install --linux <file>") }
}

# Runs `oyzu shell install`: activation in each shell found, plus oyzu and the
# shims folder on the user Path. A failure does not undo the install.
function Initialize-OyzuShell([string]$Exe) {
  Write-Host ''
  & $Exe shell install
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("oyzu install: oyzu is installed, but setting up your shells and Path failed. Run it again later: & '$Exe' shell install")
  }
}

function Initialize-OyzuPlugins([string]$Exe) {
  try {
    & $Exe config show --global *> $null
    if ($LASTEXITCODE -ne 0) { throw 'could not read user configuration' }
    & $Exe config get --global plugins.preview *> $null
    if ($LASTEXITCODE -eq 0) { return }
    & $Exe config set --global plugins.preview true | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'could not enable preview plugins' }
    Write-Host 'Enabled first-party preview plugins. To undo: oyzu config set --global plugins.preview false'
  } catch {
    [Console]::Error.WriteLine("oyzu install: warning: preview plugin setup failed ($($_.Exception.Message)). Run: oyzu config set --global plugins.preview true")
  }
}

function Install-Oyzu([string]$Channel, [string]$Version, [string]$InstallDir, [bool]$NoModifyPath) {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Stop-OyzuInstall 1 'install.ps1 installs oyzu on Windows. On macOS and Linux run: curl -fsSL https://docs.oyzu.ai/install.sh | sh'
  }
  # Windows PowerShell 5.1 may not offer TLS 1.2 by default.
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }

  $ctx = @{
    Repo = if ($env:OYZU_RELEASE_REPO) { $env:OYZU_RELEASE_REPO } else { 'oyzuai/oyzu-releases' }
    Api = if ($env:OYZU_API_BASE) { $env:OYZU_API_BASE.TrimEnd('/') } else { 'https://api.github.com' }
    Download = if ($env:OYZU_DOWNLOAD_BASE) { $env:OYZU_DOWNLOAD_BASE.TrimEnd('/') } else { 'https://github.com' }
    Token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
  }
  if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Oyzu\bin' }
  if (-not $Channel -and $Version) { $Channel = @{ 2 = 'beta'; 3 = 'nightly' }[(Get-OyzuChannelRank $Version)] }
  if (-not $Channel) { $Channel = 'stable' }
  $Channel = $Channel.ToLowerInvariant()
  $rank = @{ stable = 1; beta = 2; nightly = 3 }[$Channel]
  if (-not $rank) { Stop-OyzuInstall 2 "unknown channel ${Channel}: use stable, beta or nightly" }

  # The native architecture: the registry value is not changed by x64 emulation on ARM64.
  $native = $null
  try { $native = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE } catch { }
  if (-not $native) { $native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE } }
  switch ($native) {
    'AMD64' { $arch = 'x86_64' }
    'ARM64' { $arch = 'arm64' }
    default { Stop-OyzuInstall 1 "oyzu releases have no executable for the $native architecture. Build it from source instead: https://docs.oyzu.ai/docs/get-started/install" }
  }
  $assetName = "oyzu-windows-$arch.exe"
  $shimName = "oyzu-shim-windows-$arch.exe"
  # Isolated builds run a Linux oyzu of this architecture in the container.
  $linuxName = "oyzu-linux-$arch"

  if ($Version) {
    $releases = Invoke-OyzuGet $ctx "$($ctx.Api)/repos/$($ctx.Repo)/releases/tags/$Version" 'application/vnd.github+json' "release $Version of $($ctx.Repo)"
  } else {
    $releases = Invoke-OyzuGet $ctx "$($ctx.Api)/repos/$($ctx.Repo)/releases?per_page=30" 'application/vnd.github+json' "the release list of $($ctx.Repo)"
  }
  $release = $null; $asset = $null
  foreach ($candidate in $releases) {
    if ($candidate.draft) { continue }
    if (-not $Version -and (($candidate.tag_name -like '*/*' -and $candidate.tag_name -notlike 'oyzu/v*') -or (Get-OyzuChannelRank $candidate.tag_name) -gt $rank)) { continue }
    $asset = $candidate.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if ($asset) { $release = $candidate; break }
  }
  if (-not $release) {
    if ($Version) { Stop-OyzuInstall 1 "release $Version of $($ctx.Repo) has no $assetName, the executable for this platform. Choose another release, or build from source: https://docs.oyzu.ai/docs/get-started/install" }
    Stop-OyzuInstall 1 "no published $Channel release of $($ctx.Repo) has $assetName, the executable for this platform. Try -Channel beta or nightly, or build from source: https://docs.oyzu.ai/docs/get-started/install"
  }
  $tag = $release.tag_name
  Write-Host "Installing oyzu $tag for windows/$arch from $($ctx.Repo)"

  $stage = Join-Path ([IO.Path]::GetTempPath()) ('oyzu-install-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $stage | Out-Null
  try {
    $exe = Get-OyzuAsset $ctx $release $asset $stage 'oyzu.exe'
    $files = @($exe)
    $shim = $release.assets | Where-Object { $_.name -eq $shimName } | Select-Object -First 1
    if ($shim) { $files += Get-OyzuAsset $ctx $release $shim $stage 'oyzu-shim.exe' }
    $linux = $null
    $linuxAsset = $release.assets | Where-Object { $_.name -eq $linuxName } | Select-Object -First 1
    if ($linuxAsset) {
      $engineStage = Join-Path $stage 'engine'
      New-Item -ItemType Directory -Path $engineStage | Out-Null
      $linux = Get-OyzuAsset $ctx $release $linuxAsset $engineStage $linuxName
    } else {
      Write-Host "Release $tag has no $linuxName, so isolated builds (--isolated) will not work with this install."
    }

    # Run the new executable before replacing anything, so one that cannot run leaves the old one.
    $ver = $null
    try { $ver = (& $exe --version) -join "`n" } catch { Stop-OyzuInstall 1 "the downloaded $assetName does not run on this host: $($_.Exception.Message)" }
    if ($LASTEXITCODE -ne 0) { Stop-OyzuInstall 1 "the downloaded $assetName does not run on this host (exit status $LASTEXITCODE)." }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $target = Join-Path $InstallDir 'oyzu.exe'
    if (Test-Path -LiteralPath $target) { Write-Host "Replacing $target" }
    foreach ($file in $files) {
      $dest = Join-Path $InstallDir (Split-Path -Leaf $file)
      try { Move-Item -LiteralPath $file -Destination $dest -Force }
      catch { Stop-OyzuInstall 1 "cannot write $dest. If oyzu is running, close it and run the installer again. ($($_.Exception.Message))" }
    }
    # Records the install for `oyzu self` (its channel, pin and digest) beside the binaries.
    $v = $tag -replace '^oyzu/', '' -replace '^v', ''
    $receipt = [ordered]@{ type = 'https://oyzu.dev/self-install/v1alpha1'; channel = $Channel; pin = $(if ($Version) { $v } else { $null })
      mode = 'auto'; repository = $ctx.Repo; version = $v; tag = $tag; digest = [string]$asset.digest
      installedBy = 'install.ps1'; installedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    try { [IO.File]::WriteAllText((Join-Path $InstallDir '.oyzu-install.json'), ($receipt | ConvertTo-Json -Compress) + "`n") }
    catch { [Console]::Error.WriteLine("oyzu install: could not record the install for oyzu self in $InstallDir") }
    if ($linux) { Initialize-OyzuEngine (Join-Path $InstallDir 'oyzu.exe') $linux $linuxName }
  } finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Installed oyzu $tag ($assetName, $($asset.digest)) to $target"
  Write-Host $ver
  Initialize-OyzuPlugins $target
  $onPath = ($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') }) -contains $InstallDir.TrimEnd('\')
  if (-not $NoModifyPath) {
    Initialize-OyzuShell $target
    if (-not $onPath) { $env:Path = "$InstallDir;$env:Path" }
  } elseif (-not $onPath) {
    Write-Host ''
    Write-Host "$InstallDir is not on this session's Path, and you asked the installer not to change your shells or Path. To use oyzu:"
    Write-Host "  this PowerShell session:  `$env:Path = `"$InstallDir;`$env:Path`""
    Write-Host "  every new terminal:       & '$target' shell install"
  }
}

if ($Help) { Show-OyzuInstallHelp; return }
$oyzuExit = 0
try {
  Install-Oyzu $Channel $Version $InstallDir ($NoModifyPath -or $env:OYZU_NO_MODIFY_PATH -eq '1')
} catch {
  $oyzuExit = $_.Exception.Data['OyzuExit']
  if ($null -eq $oyzuExit) { $oyzuExit = 1 }
  [Console]::Error.WriteLine('oyzu install: ' + $_.Exception.Message)
}
# `exit` would close the window of someone running `irm ... | iex`, so only a
# script file run (powershell -File install.ps1) reports its status that way.
if ($PSCommandPath) { exit $oyzuExit } elseif ($oyzuExit) { $global:LASTEXITCODE = $oyzuExit }
