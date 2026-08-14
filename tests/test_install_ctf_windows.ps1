[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Deterministic test doubles for CIM and drive data.')]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Installer = Join-Path $RepoRoot 'install_ctf.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "[FAIL] $Message" }
}

function Assert-Substring {
    param([string]$Text, [string]$Expected)
    Assert-True ($Text.Contains($Expected)) "dry-run output is missing: $Expected"
}

Assert-True (Test-Path -LiteralPath $Installer) 'install_ctf.ps1 does not exist'

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $Installer,
    [ref]$tokens,
    [ref]$parseErrors
)
Assert-True ($parseErrors.Count -eq 0) "PowerShell parser found errors: $($parseErrors -join '; ')"

$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'ctftools-windows-dry-run'
Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue

$nativeOutput = (& $Installer -DryRun -ToolsRoot $TestRoot *>&1 | Out-String)

$nativeExpected = @(
    '7zip.7zip 26.02',
    'Git.Git 2.55.0.3',
    'Python.Python.3.12 3.12.10',
    'Microsoft.OpenJDK.21 21.0.12.8',
    'WiresharkFoundation.Wireshark 4.6.8',
    'PortSwigger.BurpSuite.Community 2026.3.3',
    'OliverBetz.ExifTool 13.59',
    'Ghidra 12.1.2',
    'ffuf 2.2.1',
    'John the Ripper 1.9.0-jumbo-1',
    'steghide 0.5.1',
    'DirBuster 1.0-RC1',
    'rockyou.txt',
    'pycryptodome',
    'ROPgadget==7.7',
    'Resource preflight: total RAM >= 4 GB, free RAM >= 2 GB, free disk >= 8 GB',
    'download cache will be removed after a successful install'
)
foreach ($expected in $nativeExpected) {
    Assert-Substring $nativeOutput $expected
}
Assert-True (-not (Test-Path -LiteralPath $TestRoot)) 'DryRun created the tools directory'

$wslOutput = (& $Installer -DryRun -ToolsRoot $TestRoot -IncludeWSL *>&1 | Out-String)
foreach ($expected in @(
    'Ubuntu-24.04',
    'gdb',
    'pwndbg 2026.07.29',
    'pwntools==4.15.0',
    'Resource preflight: total RAM >= 8 GB, free RAM >= 4 GB, free disk >= 16 GB'
)) {
    Assert-Substring $wslOutput $expected
}
Assert-True (-not (Test-Path -LiteralPath $TestRoot)) 'DryRun with WSL created the tools directory'

$keepOutput = (& $Installer -DryRun -ToolsRoot $TestRoot -KeepDownloads *>&1 | Out-String)
Assert-Substring $keepOutput 'download cache will be kept'
Assert-True (-not (Test-Path -LiteralPath $TestRoot)) 'DryRun with KeepDownloads created the tools directory'

$source = Get-Content -LiteralPath $Installer -Raw
foreach ($hash in @(
    'b62e81a0390618466c019c60d8c2f796ced2509c4c1aea4a37644a77272cf99d',
    '717e3d103ee36ce743a18605be66a4424fca27758eebed1e8ebb2eb0a3645589',
    'ce05a898b72bb30c3c4f703e3ffcf25966c1b1801eb7e095030b44092ef92eaf',
    'da80d17bd363bc60d3e7216a3c43329617cbd620ac55e55e2751bd3177d09ea1',
    'ded2d962815e1256df8f3a0d25173c4b21b6eee636117c36999246725a6d8f9f',
    'd8211b43dc4dad1333c9ac8b60f5a468f5f8d744f80f9571df431def925cd579',
    '27030bb5c86e54a386aed88a309a844483fe0ef63e0be28ab7a024e0e627a79b'
)) {
    Assert-Substring $source $hash
}

# Dot-source once so helper return types can be checked without performing changes.
$null = . $Installer -DryRun -ToolsRoot $TestRoot 6>&1
$assetPath = Get-VerifiedAsset -Asset $Assets.Ffuf -Label 'ffuf return-type test' 6>$null
Assert-True ($assetPath -is [string]) 'Get-VerifiedAsset returned log records mixed with the path'
Assert-True ($assetPath.EndsWith('ffuf_2.2.1_windows_amd64.zip')) 'Get-VerifiedAsset returned the wrong path'

# Exercise resource thresholds with deterministic CIM/drive data.
$script:MockTotalRamBytes = 5GB
$script:MockFreeRamKB = 3GB / 1KB
$script:MockFreeDiskBytes = 10GB
function Get-CimInstance {
    param([string]$ClassName)
    if ($ClassName -eq 'Win32_ComputerSystem') {
        return [pscustomobject]@{ TotalPhysicalMemory = $script:MockTotalRamBytes }
    }
    return [pscustomobject]@{ FreePhysicalMemory = $script:MockFreeRamKB }
}
function Get-PSDrive {
    param([string]$PSProvider)
    $null = $PSProvider
    return [pscustomobject]@{
        Root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($ToolsRoot))
        Free = $script:MockFreeDiskBytes
    }
}
$DryRun = $false
$IncludeWSL = $false
Assert-True (-not $DryRun -and -not $IncludeWSL) 'resource test did not enter native execution mode'
Assert-SystemResource 6>$null
$script:MockTotalRamBytes = 3GB
$resourceCheckFailed = $false
try { Assert-SystemResource 6>$null }
catch { $resourceCheckFailed = $true }
Assert-True $resourceCheckFailed 'resource preflight accepted a 3 GB VM'
$script:MockTotalRamBytes = 5GB
$script:MockFreeDiskBytes = 7GB
$diskCheckFailed = $false
try { Assert-SystemResource 6>$null }
catch { $diskCheckFailed = $true }
Assert-True $diskCheckFailed 'resource preflight accepted a VM with only 7 GB free disk'

# Exercise cache cleanup and explicit retention in a temporary path.
$ToolsRoot = Join-Path ([IO.Path]::GetTempPath()) "ctftools-cache-test-$PID"
$cacheDirectory = Join-Path $ToolsRoot 'downloads'
New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
Set-Content -LiteralPath (Join-Path $cacheDirectory 'asset.zip') -Value 'fixture'
$script:KeepDownloadCache = $false
Clear-DownloadCache 6>$null
Assert-True (-not (Test-Path -LiteralPath $cacheDirectory)) 'download cache was not removed'
New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
Set-Content -LiteralPath (Join-Path $cacheDirectory 'asset.zip') -Value 'fixture'
$script:KeepDownloadCache = $true
Clear-DownloadCache 6>$null
Assert-True (Test-Path -LiteralPath $cacheDirectory) 'KeepDownloads did not preserve the cache'
Remove-Item -LiteralPath $ToolsRoot -Recurse -Force

Write-Output '[PASS] install_ctf.ps1 syntax and dry-run contract'
