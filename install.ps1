<#
.SYNOPSIS
  atpage desktop installer for Windows (x64 and ARM64).

.DESCRIPTION
  Installs, updates, repairs, diagnoses or removes the atpage desktop app from
  https://github.com/danloh/atpage-release. Downloads are verified against the
  SHA-256 digests GitHub records for release assets.

    irm https://raw.githubusercontent.com/danloh/atpage-release/main/install.ps1 | iex

  With options:

    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/danloh/atpage-release/main/install.ps1))) -Update

  Both PowerShell-style (-Update, -Version 0.1.0) and GNU-style (--update,
  --version 0.1.0) options are accepted. Run with -Help for the full list.

  Works with Windows PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [switch]$Install,
  [switch]$Update,
  [switch]$Uninstall,
  [switch]$Repair,
  [Alias('Troubleshooting', 'Doctor')][switch]$Troubleshoot,
  [switch]$Check,
  [Alias('ListVersions')][switch]$List,
  [Alias('TargetVersion', 'Target')][string]$Version = 'latest',
  [string]$Format = '',
  [switch]$Purge,
  [switch]$Yes,
  [switch]$Force,
  [switch]$DryRun,
  [switch]$Help,
  [switch]$ScriptVersion,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$GnuArgs
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest is many times slower with the progress bar on Windows PowerShell 5.1.
$ProgressPreference = 'SilentlyContinue'

$AtpScriptVersion = '1.0.0'
$AtpRepo = if ($env:ATPAGE_REPO) { $env:ATPAGE_REPO } else { 'danloh/atpage-release' }
$AtpGhUrl = "https://github.com/$AtpRepo"
$AtpApiUrl = "https://api.github.com/repos/$AtpRepo"
$AtpRawUrl = "https://raw.githubusercontent.com/$AtpRepo/main/install.ps1"
$AtpAppName = 'atpage'              # productName: Add/Remove Programs entry, install folder
$AtpBinName = 'atpage-client'       # main binary / process name
$AtpScheme = 'app.atpage'           # deep-link URL scheme (OAuth sign-in callback)
$AtpIdentifier = 'app.atpage.client' # bundle identifier, names the app data folders
$AtpWebView2Guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$AtpInvokedAsFile = ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript')

# Options and state live in one hashtable: functions mutate it by reference, which works the
# same under `irm | iex`, `& ([scriptblock]::Create(...))` and `-File` (where `$script:`
# would point at different scopes).
$Opt = @{
  Install = [bool]$Install; Update = [bool]$Update; Uninstall = [bool]$Uninstall; Repair = [bool]$Repair
  Troubleshoot = [bool]$Troubleshoot; Check = [bool]$Check; List = [bool]$List
  Version = $Version; Format = $Format; Purge = [bool]$Purge; Yes = [bool]$Yes; Force = [bool]$Force
  DryRun = [bool]$DryRun; Help = [bool]$Help; ScriptVersion = [bool]$ScriptVersion
  Action = $null; Arch = $null; TempDir = $null
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "OK  $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "warning: $Message" -ForegroundColor Yellow }
function Write-Plain([string]$Message) { Write-Host $Message }
function Write-Section([string]$Title) { Write-Host ''; Write-Host $Title -ForegroundColor White }
function Write-Check([string]$Level, [string]$Message) {
  switch ($Level) {
    'ok' { Write-Host '  [ ok ] ' -ForegroundColor Green -NoNewline }
    'warn' { Write-Host '  [warn] ' -ForegroundColor Yellow -NoNewline }
    'fail' { Write-Host '  [fail] ' -ForegroundColor Red -NoNewline }
    default { Write-Host '  [info] ' -ForegroundColor DarkGray -NoNewline }
  }
  Write-Host $Message
}

function Show-Usage {
  @"
atpage installer for Windows (script $AtpScriptVersion)

Usage:
  irm $AtpRawUrl | iex
  & ([scriptblock]::Create((irm $AtpRawUrl))) [options]
  powershell -ExecutionPolicy Bypass -File install.ps1 [options]

Actions (default: -Install):
  -Install                  Install atpage (updates it if another version is installed)
  -Update                   Update an existing installation to the target version
  -Uninstall                Remove atpage (add -Purge to also delete local app data)
  -Repair                   Reinstall the installed version and re-register the
                            app.atpage:// sign-in handler and shortcuts
  -Troubleshoot             Diagnose the installation and system (no changes made)
  -Check                    Show the installed and the latest version
  -List                     List published versions

Options:
  -Version <X.Y.Z>          Target version (alias -TargetVersion; default: latest)
  -Format <exe|msi>         exe: per-user NSIS installer, no admin needed (default)
                            msi: per-machine Windows Installer, x64 only, needs admin
  -Purge                    With -Uninstall: delete settings, sessions and caches
  -Yes                      Do not ask for confirmation (closes a running atpage)
  -Force                    Reinstall the same version, or allow a downgrade
  -DryRun                   Show what would be done without changing anything
  -Help                     Show this help
  -ScriptVersion            Print the script version

GNU-style long options work too: --update, --version 0.1.0, --format msi, --dry-run, --yes ...

Environment:
  GITHUB_TOKEN              Optional token for GitHub API calls (rate limits)

Examples:
  irm $AtpRawUrl | iex
  & ([scriptblock]::Create((irm $AtpRawUrl))) -Update
  & ([scriptblock]::Create((irm $AtpRawUrl))) -Version 0.1.0
  & ([scriptblock]::Create((irm $AtpRawUrl))) -Troubleshoot
  & ([scriptblock]::Create((irm $AtpRawUrl))) -Uninstall -Purge
"@ | Write-Host
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

function ConvertTo-PlainVersion([string]$Value) {
  $v = $Value.Trim()
  if ($v.StartsWith('v') -or $v.StartsWith('V')) { $v = $v.Substring(1) }
  if ($v -notmatch '^\d+\.\d+\.\d+(-\d+)?$') { throw "invalid version '$Value' (expected X.Y.Z or X.Y.Z-N)" }
  return $v
}

# Maps GNU-style arguments (--update, --version 0.1.0, ...) onto the parameters.
function Resolve-GnuArguments {
  $items = @($GnuArgs | Where-Object { $null -ne $_ -and $_ -ne '' })
  $i = 0
  while ($i -lt $items.Count) {
    $arg = [string]$items[$i]
    $name = $arg
    $value = $null
    if ($arg -match '^(--?[A-Za-z-]+)=(.*)$') { $name = $Matches[1]; $value = $Matches[2] }
    $needsValue = $false
    switch -Regex ($name.ToLowerInvariant()) {
      '^(-i|--install)$' { $Opt.Install = $true; break }
      '^(-u|--update|--upgrade)$' { $Opt.Update = $true; break }
      '^(--uninstall|--remove)$' { $Opt.Uninstall = $true; break }
      '^(-r|--repair|--reinstall)$' { $Opt.Repair = $true; break }
      '^(-t|--troubleshoot|--troubleshooting|--doctor)$' { $Opt.Troubleshoot = $true; break }
      '^(-c|--check)$' { $Opt.Check = $true; break }
      '^(-l|--list|--list-versions)$' { $Opt.List = $true; break }
      '^(-v|--version|--target-version|--target)$' { $needsValue = 'Version'; break }
      '^(-f|--format)$' { $needsValue = 'Format'; break }
      '^--purge$' { $Opt.Purge = $true; break }
      '^(-y|--yes)$' { $Opt.Yes = $true; break }
      '^--force$' { $Opt.Force = $true; break }
      '^(-n|--dry-run)$' { $Opt.DryRun = $true; break }
      '^(-h|--help|/\?)$' { $Opt.Help = $true; break }
      '^--script-version$' { $Opt.ScriptVersion = $true; break }
      default { throw "unknown option: $arg (see -Help)" }
    }
    if ($needsValue) {
      if ($null -eq $value) {
        $i++
        if ($i -ge $items.Count) { throw "$name needs a value" }
        $value = [string]$items[$i]
      }
      if ($needsValue -eq 'Version') { $Opt.Version = $value } else { $Opt.Format = $value }
    }
    $i++
  }
}

function Resolve-Options {
  Resolve-GnuArguments

  $actions = @()
  if ($Opt.Install) { $actions += 'install' }
  if ($Opt.Update) { $actions += 'update' }
  if ($Opt.Uninstall) { $actions += 'uninstall' }
  if ($Opt.Repair) { $actions += 'repair' }
  if ($Opt.Troubleshoot) { $actions += 'troubleshoot' }
  if ($Opt.Check) { $actions += 'check' }
  if ($Opt.List) { $actions += 'list' }
  if ($actions.Count -gt 1) { throw "choose one action (got: $($actions -join ', '))" }
  $Opt.Action = if ($actions.Count -eq 1) { $actions[0] } else { 'install' }

  if ([string]::IsNullOrWhiteSpace($Opt.Version) -or $Opt.Version -eq 'latest') { $Opt.Version = 'latest' }
  else { $Opt.Version = ConvertTo-PlainVersion $Opt.Version }

  $f = "$($Opt.Format)".Trim().ToLowerInvariant()
  if ($f -eq 'nsis' -or $f -eq 'setup') { $f = 'exe' }
  if ($f -ne '' -and $f -ne 'exe' -and $f -ne 'msi') { throw "format '$($Opt.Format)' is not available on Windows (exe or msi)" }
  $Opt.Format = $f
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Confirm-Action([string]$Question, [bool]$Default) {
  if ($Opt.Yes) { return $true }
  $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
  try { $answer = Read-Host "$Question $hint" } catch { return $Default }
  if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
  return ($answer.Trim() -match '^[Yy]')
}

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Prints -1, 0 or 1 comparing X.Y.Z[-N] versions (a pre-release sorts before its release).
function Compare-AppVersion([string]$A, [string]$B) {
  $pa = $A.Split('-', 2); $pb = $B.Split('-', 2)
  $va = [version]($pa[0]); $vb = [version]($pb[0])
  $c = $va.CompareTo($vb)
  if ($c -ne 0) { return [math]::Sign($c) }
  $ra = if ($pa.Count -gt 1) { [int]$pa[1] } else { $null }
  $rb = if ($pb.Count -gt 1) { [int]$pb[1] } else { $null }
  if ($null -eq $ra -and $null -eq $rb) { return 0 }
  if ($null -eq $ra) { return 1 }
  if ($null -eq $rb) { return -1 }
  return [math]::Sign($ra.CompareTo($rb))
}

function Test-KnownVersion([string]$V) { return ($V -match '^\d+\.\d+\.\d+(-\d+)?$') }

function Get-NativeArch {
  $a = $null
  try {
    $a = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE).PROCESSOR_ARCHITECTURE
  } catch {}
  if (-not $a) { $a = $env:PROCESSOR_ARCHITEW6432 }
  if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
  switch ($a) {
    'AMD64' { return 'x64' }
    'ARM64' { return 'arm64' }
    default { throw "unsupported CPU architecture '$a' (atpage builds exist for x64 and ARM64)" }
  }
}

function New-TempDir {
  if ($Opt.TempDir) { return $Opt.TempDir }
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('atpage-install-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
  New-Item -ItemType Directory -Path $dir | Out-Null
  $Opt.TempDir = $dir
  return $dir
}

function Remove-TempDir {
  if ($Opt.TempDir -and (Test-Path $Opt.TempDir)) {
    Remove-Item -Recurse -Force $Opt.TempDir -ErrorAction SilentlyContinue
  }
  $Opt.TempDir = $null
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

function Initialize-Network {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  } catch {}
}

function Get-HttpStatus($ErrorRecord) {
  try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return 0 }
}

function Invoke-GitHubApi([string]$Path) {
  $headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'atpage-installer' }
  if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
  return Invoke-RestMethod -Uri ($AtpApiUrl + $Path) -Headers $headers -UseBasicParsing -TimeoutSec 30
}

# Latest published (non-pre-release) version. The releases/latest redirect needs no API quota.
function Get-LatestVersion {
  $tag = $null
  try {
    $req = [System.Net.HttpWebRequest]::Create("$AtpGhUrl/releases/latest")
    $req.Method = 'HEAD'
    $req.AllowAutoRedirect = $false
    $req.UserAgent = 'atpage-installer'
    $req.Timeout = 20000
    $resp = $req.GetResponse()
    $location = $resp.Headers['Location']
    $resp.Close()
    if ($location -match '/releases/tag/([^/?#]+)') { $tag = $Matches[1] }
  } catch {}
  if (-not $tag) {
    try { $tag = (Invoke-GitHubApi '/releases/latest').tag_name } catch {}
  }
  if (-not $tag) { throw "could not determine the latest release of $AtpRepo (network problem or no releases yet)" }
  return (ConvertTo-PlainVersion $tag)
}

function Resolve-TargetVersion {
  if ($Opt.Version -eq 'latest') { return Get-LatestVersion }
  return $Opt.Version
}

# Release metadata (asset names and digests); missing metadata is not fatal.
function Get-ReleaseInfo([string]$V) {
  try {
    return Invoke-GitHubApi "/releases/tags/v$V"
  } catch {
    if ((Get-HttpStatus $_) -eq 404) { throw "atpage $V is not published (see -List)" }
    Write-Warn "could not read release metadata from the GitHub API ($($_.Exception.Message)); checksum verification is skipped"
    return $null
  }
}

function Get-AssetSuffix([string]$Fmt) {
  if ($Fmt -eq 'msi') { return '_x64_en-US.msi' }
  return "_$($Opt.Arch)-setup.exe"
}

function Select-Asset($Release, [string]$Fmt, [string]$V) {
  $suffix = Get-AssetSuffix $Fmt
  if ($Release -and $Release.assets) {
    $match = $Release.assets | Where-Object { $_.name.EndsWith($suffix) } | Select-Object -First 1
    if ($match) { return $match }
  }
  $name = "$($AtpAppName)_$V$suffix"
  return [pscustomobject]@{ name = $name; browser_download_url = "$AtpGhUrl/releases/download/v$V/$name"; digest = $null }
}

function Save-Asset($Asset) {
  $dir = New-TempDir
  $out = Join-Path $dir $Asset.name
  Write-Step "downloading $($Asset.name)"
  try {
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $out -UseBasicParsing -Headers @{ 'User-Agent' = 'atpage-installer' }
  } catch {
    throw "download failed: $($Asset.browser_download_url) ($($_.Exception.Message))"
  }
  $digest = $null
  if ($Asset.PSObject.Properties['digest']) { $digest = [string]$Asset.digest }
  if ($digest -and $digest.StartsWith('sha256:')) {
    $expected = $digest.Substring(7).ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 -Path $out).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
      throw "checksum mismatch for $($Asset.name) (expected $expected, got $actual); the download is corrupted or was tampered with"
    }
    Write-Ok "checksum verified (sha256 $actual)"
  } else {
    Write-Warn "no published checksum for $($Asset.name); skipping verification"
  }
  try { Unblock-File -Path $out } catch {}
  return $out
}

# ---------------------------------------------------------------------------
# Installed state
# ---------------------------------------------------------------------------

$AtpUninstallRoots = @(
  @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'user' },
  @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'machine' },
  @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'machine' }
)

function Get-PropertyValue($Object, [string]$Name) {
  if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
  return $null
}

# Installations listed in Add/Remove Programs (NSIS: key "atpage"; MSI: product code key).
function Get-Installs {
  $found = @()
  $seen = @{}
  foreach ($root in $AtpUninstallRoots) {
    if (-not (Test-Path $root.Path)) { continue }
    foreach ($key in (Get-ChildItem -Path $root.Path -ErrorAction SilentlyContinue)) {
      $p = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
      if (-not $p -or (Get-PropertyValue $p 'DisplayName') -ne $AtpAppName) { continue }
      if ($seen.ContainsKey($key.PSChildName + $root.Scope)) { continue }
      $seen[$key.PSChildName + $root.Scope] = $true

      $isMsi = ((Get-PropertyValue $p 'WindowsInstaller') -eq 1)
      $location = "$(Get-PropertyValue $p 'InstallLocation')".Trim().Trim('"')
      $exeName = Get-PropertyValue $p 'MainBinaryName'
      if (-not $exeName) { $exeName = "$AtpBinName.exe" }
      $exe = $null
      if ($location) { $exe = Join-Path $location $exeName }
      if (-not $exe -or -not (Test-Path $exe)) {
        $icon = "$(Get-PropertyValue $p 'DisplayIcon')".Trim()
        if ($icon) {
          $icon = ($icon -replace ',\s*-?\d+$', '').Trim('"')
          if ($icon -like '*.exe' -and (Test-Path $icon)) { $exe = $icon }
        }
      }
      if ((-not $exe -or -not (Test-Path $exe)) -and $isMsi) {
        foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
          if (-not $pf) { continue }
          $candidate = Join-Path (Join-Path $pf $AtpAppName) $exeName
          if (Test-Path $candidate) { $exe = $candidate; break }
        }
      }
      if (-not $location -and $exe) { $location = Split-Path -Parent $exe }

      $version = "$(Get-PropertyValue $p 'DisplayVersion')"
      if (-not $version) { $version = 'unknown' }
      $found += [pscustomobject]@{
        Format          = if ($isMsi) { 'msi' } else { 'exe' }
        Version         = $version
        Location        = $location
        Exe             = $exe
        UninstallString = "$(Get-PropertyValue $p 'UninstallString')"
        ProductCode     = $key.PSChildName
        KeyPath         = $key.PSPath
        Scope           = $root.Scope
      }
    }
  }
  return $found
}

function Select-CurrentInstall([string]$Fmt) {
  $installs = @(Get-Installs)
  if ($installs.Count -eq 0) { return $null }
  if ($Fmt) {
    return ($installs | Where-Object { $_.Format -eq $Fmt } | Select-Object -First 1)
  }
  if ($installs.Count -gt 1) {
    Write-Warn "several installations found; using the $($installs[0].Format) one (choose with -Format):"
    foreach ($i in $installs) { Write-Plain "    $($i.Format) $($i.Version) $($i.Location)" }
  }
  return $installs[0]
}

function Get-AppProcess { return @(Get-Process -Name $AtpBinName -ErrorAction SilentlyContinue) }

# Closes a running atpage before files are replaced.
function Stop-App {
  if ((Get-AppProcess).Count -eq 0) { return }
  if ($Opt.DryRun) { Write-Step 'atpage is running; it would be closed'; return }
  if (-not (Confirm-Action 'atpage is running. Close it now?' $true)) { throw 'close atpage and run the script again' }
  Write-Step 'closing atpage'
  foreach ($proc in (Get-AppProcess)) { try { [void]$proc.CloseMainWindow() } catch {} }
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline -and (Get-AppProcess).Count -gt 0) { Start-Sleep -Milliseconds 500 }
  Get-AppProcess | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
}

# ---------------------------------------------------------------------------
# Sign-in handler (app.atpage://)
# ---------------------------------------------------------------------------

function Get-SchemeHandler {
  foreach ($root in @('HKCU:\Software\Classes', 'HKLM:\Software\Classes')) {
    $key = "$root\$AtpScheme\shell\open\command"
    if (Test-Path $key) {
      $command = (Get-Item $key).GetValue('')
      $exe = $null
      if ($command -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
      elseif ($command) { $exe = ($command -split '\s+')[0] }
      return [pscustomobject]@{ Root = "$root\$AtpScheme"; Command = $command; Exe = $exe }
    }
  }
  return $null
}

# Drops an app.atpage:// registration that points at a missing executable; the
# installer (and the app at startup) registers the current one.
function Clear-StaleSchemeHandler {
  $h = Get-SchemeHandler
  if ($h -and $h.Exe -and -not (Test-Path $h.Exe) -and $h.Root -like 'HKCU:*') {
    Write-Step "removing stale sign-in handler ($($h.Exe) no longer exists)"
    if (-not $Opt.DryRun) { Remove-Item -Recurse -Force $h.Root -ErrorAction SilentlyContinue }
  }
}

# ---------------------------------------------------------------------------
# Install / uninstall
# ---------------------------------------------------------------------------

function Start-Elevated([string]$File, [string]$Arguments, [bool]$NeedsAdmin) {
  if ($NeedsAdmin -and -not (Test-Admin)) {
    Write-Step 'administrator approval is needed (UAC prompt)'
    return Start-Process -FilePath $File -ArgumentList $Arguments -Verb RunAs -Wait -PassThru
  }
  return Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru
}

function Install-Exe([string]$File) {
  Write-Step 'running the installer (silent)'
  $proc = Start-Process -FilePath $File -ArgumentList '/S' -Wait -PassThru
  if ($proc.ExitCode -ne 0) { throw "the installer failed (exit code $($proc.ExitCode))" }
}

function Install-Msi([string]$File, [string]$Mode) {
  $log = Join-Path $env:TEMP 'atpage-msi-install.log'
  $extra = if ($Mode -eq 'reinstall') { ' REINSTALL=ALL REINSTALLMODE=vamus' } else { '' }
  Write-Step 'running the MSI installer (silent)'
  $proc = Start-Elevated 'msiexec.exe' "/i `"$File`" /qn /norestart$extra /l*v `"$log`"" $true
  switch ($proc.ExitCode) {
    0 { break }
    3010 { Write-Warn 'restart Windows to finish the installation'; break }
    1602 { throw 'installation cancelled' }
    1925 { throw 'administrator rights are required for the MSI; use -Format exe for a per-user install' }
    default { throw "msiexec failed (exit code $($proc.ExitCode)); log: $log" }
  }
}

function Wait-Uninstalled($Inst, [int]$Seconds) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    if (-not (Test-Path $Inst.KeyPath)) { return $true }
    Start-Sleep -Milliseconds 500
  }
  return (-not (Test-Path $Inst.KeyPath))
}

function Uninstall-Entry($Inst) {
  Write-Step "uninstalling atpage $($Inst.Version) ($($Inst.Format), $($Inst.Location))"
  if ($Opt.DryRun) { return }
  if ($Inst.Format -eq 'msi') {
    $proc = Start-Elevated 'msiexec.exe' "/x $($Inst.ProductCode) /qn /norestart" $true
    if ($proc.ExitCode -notin @(0, 1605, 3010)) { throw "msiexec /x failed (exit code $($proc.ExitCode))" }
    return
  }
  $uninstaller = $null
  if ($Inst.UninstallString -match '^\s*"([^"]+)"') { $uninstaller = $Matches[1] }
  elseif ($Inst.UninstallString) { $uninstaller = $Inst.UninstallString.Trim() }
  if (-not $uninstaller -or -not (Test-Path $uninstaller)) {
    Write-Warn 'the uninstaller is missing; removing the leftover registration and files'
    if ($Inst.Location -and (Test-Path $Inst.Location) -and (Split-Path -Leaf $Inst.Location) -eq $AtpAppName) {
      Remove-Item -Recurse -Force $Inst.Location -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $Inst.KeyPath -ErrorAction SilentlyContinue
    foreach ($lnk in @(
        (Join-Path ([Environment]::GetFolderPath('Programs')) "$AtpAppName.lnk"),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) "$AtpAppName.lnk"))) {
      if (Test-Path $lnk) { Remove-Item -Force $lnk -ErrorAction SilentlyContinue }
    }
    return
  }
  # The NSIS uninstaller re-launches itself from %TEMP% and returns at once; wait for
  # its registry entry to disappear.
  [void](Start-Elevated $uninstaller '/S' ($Inst.Scope -eq 'machine'))
  if (-not (Wait-Uninstalled $Inst 120)) { throw 'the uninstaller did not finish in time' }
}

# Downloads, verifies and installs a version. Mode: install|upgrade|reinstall|downgrade
function Install-Version([string]$V, [string]$Fmt, [string]$Mode) {
  if ($Fmt -eq 'msi' -and $Opt.Arch -ne 'x64') { throw 'MSI packages are only built for x64; use -Format exe' }
  $release = Get-ReleaseInfo $V
  $asset = Select-Asset $release $Fmt $V
  Write-Step "atpage $V ($Fmt, windows $($Opt.Arch)) - $Mode"
  if ($Opt.DryRun) {
    Write-Plain "  download: $($asset.browser_download_url)"
    if ($Fmt -eq 'msi') { Write-Plain '  install: msiexec /i (per machine, needs admin)' }
    else { Write-Plain "  install: $($asset.name) /S (per user, %LOCALAPPDATA%\$AtpAppName)" }
    Stop-App
    return
  }
  $file = Save-Asset $asset
  Stop-App
  Clear-StaleSchemeHandler
  if ($Fmt -eq 'msi') { Install-Msi $file $Mode } else { Install-Exe $file }

  $inst = Select-CurrentInstall $Fmt
  if (-not $inst) { throw 'the installer finished but atpage is not registered; run -Troubleshoot' }
  Write-Ok "atpage $($inst.Version) installed ($($inst.Location))"
  Write-Plain '  Start it from the Start menu (atpage).'
}

# ---------------------------------------------------------------------------
# Data folders
# ---------------------------------------------------------------------------

function Get-DataDirs {
  return @(
    (Join-Path $env:APPDATA $AtpIdentifier),
    (Join-Path $env:LOCALAPPDATA $AtpIdentifier)
  ) | Where-Object { Test-Path $_ }
}

function Get-DirSize([string]$Path) {
  try {
    $bytes = (Get-ChildItem -Recurse -Force -File -Path $Path -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { return '0 B' }
    if ($bytes -ge 1GB) { return '{0:N1} GB' -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return '{0:N1} MB' -f ($bytes / 1MB) }
    return '{0:N0} KB' -f ($bytes / 1KB)
  } catch { return '?' }
}

function Remove-AppData {
  $dirs = @(Get-DataDirs)
  if ($dirs.Count -eq 0) { Write-Step 'no local app data found'; return }
  Write-Plain 'Local app data (settings, sign-in sessions, caches):'
  foreach ($d in $dirs) { Write-Plain "    $d" }
  Write-Plain 'Your posts and account live on your PDS and are not affected.'
  if ($Opt.DryRun) { return }
  if (-not (Confirm-Action 'Delete this data?' $false)) { Write-Step 'kept local app data'; return }
  foreach ($d in $dirs) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue }
  Write-Ok 'local app data removed'
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Get-DefaultFormat($Current) {
  if ($Opt.Format) { return $Opt.Format }
  if ($Current) { return $Current.Format }
  return 'exe'
}

function Invoke-InstallAction {
  $cur = Select-CurrentInstall $Opt.Format
  $target = Resolve-TargetVersion
  $fmt = Get-DefaultFormat $cur
  if (-not $cur) { Install-Version $target $fmt 'install'; return }
  if (-not (Test-KnownVersion $cur.Version)) { Install-Version $target $fmt 'reinstall'; return }
  $c = Compare-AppVersion $target $cur.Version
  if ($c -eq 0 -and -not $Opt.Force) {
    Write-Ok "atpage $($cur.Version) is already installed ($($cur.Format), $($cur.Location))"
    Write-Plain '  To reinstall it, use -Repair (or -Force).'
  } elseif ($c -eq 0) {
    Install-Version $target $fmt 'reinstall'
  } elseif ($c -gt 0) {
    Write-Step "atpage $($cur.Version) is installed; updating to $target"
    Install-Version $target $fmt 'upgrade'
  } elseif ($Opt.Force) {
    Install-Version $target $fmt 'downgrade'
  } else {
    throw "atpage $($cur.Version) is newer than $target; pass -Force to downgrade"
  }
}

function Invoke-UpdateAction {
  $cur = Select-CurrentInstall $Opt.Format
  if (-not $cur) { Write-Step 'atpage is not installed; installing it'; Invoke-InstallAction; return }
  $target = Resolve-TargetVersion
  $fmt = Get-DefaultFormat $cur
  if (-not (Test-KnownVersion $cur.Version)) { Install-Version $target $fmt 'reinstall'; return }
  $c = Compare-AppVersion $target $cur.Version
  if ($c -gt 0) {
    Write-Step "updating atpage $($cur.Version) -> $target"
    Install-Version $target $fmt 'upgrade'
  } elseif ($c -eq 0) {
    if ($Opt.Force) { Install-Version $target $fmt 'reinstall' } else { Write-Ok "atpage $($cur.Version) is up to date" }
  } elseif ($Opt.Force) {
    Write-Step "downgrading atpage $($cur.Version) -> $target"
    Install-Version $target $fmt 'downgrade'
  } else {
    throw "installed atpage $($cur.Version) is newer than $target; pass -Force to downgrade"
  }
}

function Invoke-RepairAction {
  $cur = Select-CurrentInstall $Opt.Format
  if (-not $cur) { Write-Warn 'atpage is not installed; installing it'; Invoke-InstallAction; return }
  if ($Opt.Version -ne 'latest') { $target = $Opt.Version }
  elseif (Test-KnownVersion $cur.Version) { $target = $cur.Version }
  else { $target = Get-LatestVersion }
  $fmt = Get-DefaultFormat $cur
  Write-Step "repairing atpage $($cur.Version) ($($cur.Format))"
  Install-Version $target $fmt 'reinstall'
  Write-Plain "  Shortcuts and the ${AtpScheme}:// sign-in handler were re-registered."
  Write-Plain '  Still having problems? Run with -Troubleshoot.'
}

function Invoke-UninstallAction {
  $installs = @(Get-Installs)
  if ($Opt.Format) { $installs = @($installs | Where-Object { $_.Format -eq $Opt.Format }) }
  if ($installs.Count -eq 0) {
    Write-Step 'atpage is not installed'
  } else {
    Write-Plain 'Removing:'
    foreach ($i in $installs) { Write-Plain "    $($i.Format) $($i.Version) $($i.Location)" }
    if (-not $Opt.DryRun -and -not (Confirm-Action 'Uninstall atpage?' $true)) { throw 'cancelled' }
    Stop-App
    foreach ($i in $installs) { Uninstall-Entry $i }
    if (-not $Opt.DryRun) {
      Clear-StaleSchemeHandler
      Write-Ok 'atpage uninstalled'
    }
  }
  if ($Opt.Purge) { Remove-AppData }
  elseif (@(Get-DataDirs).Count -gt 0) { Write-Plain '  Local app data was kept; add -Purge to delete it.' }
}

function Invoke-CheckAction {
  $installs = @(Get-Installs)
  $latest = Get-LatestVersion
  if ($installs.Count -eq 0) {
    Write-Plain 'installed: none'
    Write-Plain "latest:    $latest"
    Write-Plain "Install with: irm $AtpRawUrl | iex"
    return
  }
  foreach ($i in $installs) { Write-Plain "installed: $($i.Version) ($($i.Format), $($i.Location))" }
  Write-Plain "latest:    $latest"
  $cur = $installs[0]
  if (-not (Test-KnownVersion $cur.Version) -or (Compare-AppVersion $latest $cur.Version) -gt 0) {
    Write-Host 'An update is available.' -ForegroundColor Yellow -NoNewline
    Write-Host " Update with: & ([scriptblock]::Create((irm $AtpRawUrl))) -Update"
  } else {
    Write-Ok 'up to date'
  }
}

function Invoke-ListAction {
  try { $releases = Invoke-GitHubApi '/releases?per_page=30' }
  catch { throw 'could not list releases (GitHub API unreachable or rate-limited; set GITHUB_TOKEN)' }
  $installed = @(Get-Installs | ForEach-Object { $_.Version })
  foreach ($r in @($releases)) {
    if ($r.draft) { continue }
    $date = if ($r.published_at) { ([datetime]$r.published_at).ToString('yyyy-MM-dd') } else { '' }
    $note = if ($r.prerelease) { ' (pre-release)' } else { '' }
    $mark = if ($installed -contains ($r.tag_name -replace '^v', '')) { '  <- installed' } else { '' }
    Write-Plain ('{0,-14} {1}{2}{3}' -f $r.tag_name, $date, $note, $mark)
  }
}

function Test-Url([string]$Url) {
  try {
    $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'atpage-installer' }
    return $true
  } catch {
    $status = Get-HttpStatus $_
    return ($status -gt 0 -and $status -lt 500)
  }
}

function Get-WebView2Version {
  $paths = @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$AtpWebView2Guid",
    "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$AtpWebView2Guid",
    "HKCU:\Software\Microsoft\EdgeUpdate\Clients\$AtpWebView2Guid"
  )
  foreach ($p in $paths) {
    if (Test-Path $p) {
      $v = (Get-ItemProperty -Path $p -ErrorAction SilentlyContinue).pv
      if ($v -and $v -ne '0.0.0.0') { return $v }
    }
  }
  return $null
}

function Invoke-TroubleshootAction {
  Write-Host "atpage troubleshooting (script $AtpScriptVersion, $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC)" -ForegroundColor White

  Write-Section 'System'
  $build = 0
  try {
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    Write-Check 'info' "$($os.Caption) $($os.Version), $($Opt.Arch)"
  } catch {
    Write-Check 'info' "Windows $([Environment]::OSVersion.Version), $($Opt.Arch)"
    $build = [Environment]::OSVersion.Version.Build
  }
  if ($build -gt 0 -and $build -lt 10240) { Write-Check 'fail' 'atpage needs Windows 10 or newer' }
  Write-Check 'info' "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)), admin: $(Test-Admin)"

  Write-Section 'Installation'
  $installs = @(Get-Installs)
  $latest = $null
  try { $latest = Get-LatestVersion } catch {}
  if ($installs.Count -eq 0) {
    Write-Check 'warn' 'atpage is not installed'
  } else {
    if ($installs.Count -gt 1) { Write-Check 'warn' "$($installs.Count) installations found; keep one (-Uninstall -Format <exe|msi>)" }
    foreach ($i in $installs) {
      if ($i.Exe -and (Test-Path $i.Exe)) { Write-Check 'ok' "$($i.Format) $($i.Version) at $($i.Exe) ($($i.Scope))" }
      else { Write-Check 'fail' "$($i.Format) $($i.Version): the app executable is missing (run -Repair)" }
      if ($latest -and (-not (Test-KnownVersion $i.Version) -or (Compare-AppVersion $latest $i.Version) -gt 0)) {
        Write-Check 'warn' "update available: $($i.Version) -> $latest (run -Update)"
      }
    }
  }
  if ($latest) { Write-Check 'info' "latest release: $latest" }
  $procs = Get-AppProcess
  if ($procs.Count -gt 0) { Write-Check 'info' "atpage is running (pid $(($procs | ForEach-Object { $_.Id }) -join ', '))" }

  Write-Section 'WebView2 runtime'
  $wv = Get-WebView2Version
  if ($wv) { Write-Check 'ok' "Microsoft Edge WebView2 $wv" }
  else { Write-Check 'fail' 'WebView2 runtime not found: run -Repair (the installer fetches it) or get it from https://developer.microsoft.com/microsoft-edge/webview2/' }

  Write-Section 'Network'
  try {
    $proxy = [System.Net.WebRequest]::DefaultWebProxy.GetProxy([uri]'https://github.com')
    if ($proxy -and $proxy.Host -ne 'github.com') { Write-Check 'info' "system proxy: $proxy" }
  } catch {}
  foreach ($u in @('https://github.com', 'https://bsky.social/xrpc/_health', 'https://atpage.app')) {
    if (Test-Url $u) { Write-Check 'ok' "reachable: $u" } else { Write-Check 'fail' "cannot reach $u (proxy, firewall or DNS?)" }
  }

  Write-Section "Sign-in handler (${AtpScheme}://)"
  $h = Get-SchemeHandler
  if (-not $h) {
    Write-Check 'fail' 'no handler registered (start atpage once, or run -Repair)'
  } elseif ($h.Exe -and (Test-Path $h.Exe)) {
    Write-Check 'ok' "$($h.Root) -> $($h.Exe)"
  } else {
    Write-Check 'fail' "$($h.Root) points to missing $($h.Exe) (run -Repair)"
  }

  Write-Section 'Local app data'
  foreach ($d in @(Get-DataDirs)) { Write-Check 'info' "$(Get-DirSize $d)  $d" }
  Write-Check 'info' 'a fresh start without reinstalling: -Uninstall -Purge, then install again'
  Write-Check 'info' 'blank or white window: set WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--disable-gpu and restart atpage'
  Write-Check 'info' 'builds are not code-signed yet: if antivirus quarantines atpage, restore it and allow it'

  Write-Section 'Help'
  Write-Plain "  Report problems at $AtpGhUrl/issues and include this output."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Invoke-AtpageInstaller {
  Resolve-Options
  if ($Opt.Help) { Show-Usage; return }
  if ($Opt.ScriptVersion) { Write-Plain $AtpScriptVersion; return }
  if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    throw "this script is for Windows; on macOS and Linux run: curl -fsSL https://raw.githubusercontent.com/$AtpRepo/main/install.sh | sh"
  }
  Initialize-Network
  $Opt.Arch = Get-NativeArch

  switch ($Opt.Action) {
    'install' { Invoke-InstallAction }
    'update' { Invoke-UpdateAction }
    'repair' { Invoke-RepairAction }
    'uninstall' { Invoke-UninstallAction }
    'check' { Invoke-CheckAction }
    'list' { Invoke-ListAction }
    'troubleshoot' { Invoke-TroubleshootAction }
  }
}

# `exit` would close the window of an `irm | iex` session, so errors only end the
# script (with exit code 1) when it runs as a file.
$AtpFailed = $false
try {
  Invoke-AtpageInstaller
} catch {
  $AtpFailed = $true
  Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
} finally {
  Remove-TempDir
}
if ($AtpFailed) {
  $global:LASTEXITCODE = 1
  if ($AtpInvokedAsFile) { exit 1 }
}
