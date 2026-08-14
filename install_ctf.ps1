#Requires -Version 5.1
<#
.SYNOPSIS
Installs the GRIS CTF workstation toolset on Windows 11.

.DESCRIPTION
Native Windows tools are installed with winget or verified, pinned archives.
The Linux-only pwn stack (GDB, pwndbg and pwntools) is optional through WSL2.
Run from an elevated PowerShell prompt.
#>

[CmdletBinding()]
param(
    [string]$ToolsRoot = 'C:\CTF',
    [switch]$IncludeWSL,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$KeepDownloads
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:ForceInstall = $Force.IsPresent
$script:KeepDownloadCache = $KeepDownloads.IsPresent

$Versions = [ordered]@{
    Ghidra      = '12.1.2'
    Ffuf        = '2.2.1'
    John        = '1.9.0-jumbo-1'
    Steghide    = '0.5.1'
    DirBuster   = '1.0-RC1'
    ROPgadget   = '7.7'
    Pwndbg      = '2026.07.29'
    Pwntools    = '4.15.0'
}

$WingetPackages = @(
    [pscustomobject]@{ Id = '7zip.7zip';                         Version = '26.02';     Name = '7-Zip' },
    [pscustomobject]@{ Id = 'Git.Git';                           Version = '2.55.0.3';  Name = 'Git' },
    [pscustomobject]@{ Id = 'Python.Python.3.12';                Version = '3.12.10';  Name = 'Python' },
    [pscustomobject]@{ Id = 'Microsoft.OpenJDK.21';              Version = '21.0.12.8'; Name = 'OpenJDK' },
    [pscustomobject]@{ Id = 'WiresharkFoundation.Wireshark';     Version = '4.6.8';     Name = 'Wireshark' },
    [pscustomobject]@{ Id = 'PortSwigger.BurpSuite.Community';   Version = '2026.3.3';  Name = 'Burp Suite Community' },
    [pscustomobject]@{ Id = 'OliverBetz.ExifTool';               Version = '13.59';     Name = 'ExifTool' }
)

$Assets = @{
    Ghidra = [pscustomobject]@{
        Url = 'https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.2_build/ghidra_12.1.2_PUBLIC_20260605.zip'
        Sha256 = 'b62e81a0390618466c019c60d8c2f796ced2509c4c1aea4a37644a77272cf99d'
        FileName = 'ghidra_12.1.2_PUBLIC_20260605.zip'
    }
    Ffuf = [pscustomobject]@{
        Url = 'https://github.com/ffuf/ffuf/releases/download/v2.2.1/ffuf_2.2.1_windows_amd64.zip'
        Sha256 = '717e3d103ee36ce743a18605be66a4424fca27758eebed1e8ebb2eb0a3645589'
        FileName = 'ffuf_2.2.1_windows_amd64.zip'
    }
    John = [pscustomobject]@{
        Url = 'https://www.openwall.com/john/k/john-1.9.0-jumbo-1-win64.7z'
        Sha256 = 'ce05a898b72bb30c3c4f703e3ffcf25966c1b1801eb7e095030b44092ef92eaf'
        FileName = 'john-1.9.0-jumbo-1-win64.7z'
    }
    DirBuster = [pscustomobject]@{
        Url = 'https://downloads.sourceforge.net/project/dirbuster/DirBuster%20%28jar%20%2B%20lists%29/1.0-RC1/DirBuster-1.0-RC1.zip'
        Sha256 = 'da80d17bd363bc60d3e7216a3c43329617cbd620ac55e55e2751bd3177d09ea1'
        FileName = 'DirBuster-1.0-RC1.zip'
    }
    RockYou = [pscustomobject]@{
        Url = 'https://gitlab.com/kalilinux/packages/wordlists/-/raw/kali/master/rockyou.txt.gz'
        Sha256 = 'ded2d962815e1256df8f3a0d25173c4b21b6eee636117c36999246725a6d8f9f'
        FileName = 'rockyou.txt.gz'
    }
    Steghide = [pscustomobject]@{
        Url = 'https://downloads.sourceforge.net/project/steghide/steghide/0.5.1/steghide-0.5.1-win32.zip'
        Sha256 = 'd8211b43dc4dad1333c9ac8b60f5a468f5f8d744f80f9571df431def925cd579'
        FileName = 'steghide-0.5.1-win32.zip'
    }
    PwndbgDeb = [pscustomobject]@{
        Url = 'https://github.com/pwndbg/pwndbg/releases/download/2026.07.29/pwndbg_2026.07.29_amd64.deb'
        Sha256 = '27030bb5c86e54a386aed88a309a844483fe0ef63e0be28ab7a024e0e627a79b'
        FileName = 'pwndbg_2026.07.29_amd64.deb'
    }
}

function Write-Step {
    param([string]$Message)
    Write-Information "[*] $Message" -InformationAction Continue
}

function Write-Ok {
    param([string]$Message)
    Write-Information "[+] $Message" -InformationAction Continue
}

function Write-Skip {
    param([string]$Message)
    Write-Information "[-] $Message - already installed" -InformationAction Continue
}

function Assert-WindowsAdministrator {
    if ($DryRun) { return }

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'install_ctf.ps1 must run on Windows 11. Use -DryRun for validation on another OS.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'This installer requires 64-bit Windows 11.'
    }
    if ([Environment]::OSVersion.Version.Build -lt 22000) {
        throw 'Windows 11 build 22000 or newer is required.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw 'Open PowerShell as Administrator and run the installer again.'
    }

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'winget is required. Update/install Microsoft App Installer, then rerun.'
    }
}

function Assert-SystemResource {
    if ($IncludeWSL) {
        $minimumTotalRamGB = 8
        $minimumFreeRamGB = 4
        $minimumFreeDiskGB = 16
    }
    else {
        $minimumTotalRamGB = 4
        $minimumFreeRamGB = 2
        $minimumFreeDiskGB = 8
    }

    $description = "Resource preflight: total RAM >= $minimumTotalRamGB GB, free RAM >= $minimumFreeRamGB GB, free disk >= $minimumFreeDiskGB GB"
    Write-Step $description
    if ($DryRun) {
        Write-Information "[DRY-RUN] $description" -InformationAction Continue
        return
    }

    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
    $totalRamBytes = [double]$computer.TotalPhysicalMemory
    $freeRamBytes = [double]$operatingSystem.FreePhysicalMemory * 1KB
    $fullToolsPath = [IO.Path]::GetFullPath($ToolsRoot)
    $drive = Get-PSDrive -PSProvider FileSystem |
        Where-Object { $fullToolsPath.StartsWith($_.Root, [StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object { $_.Root.Length } -Descending |
        Select-Object -First 1

    if ($null -eq $drive -or $null -eq $drive.Free) {
        throw "Could not determine free disk space for $fullToolsPath."
    }
    if ($totalRamBytes -lt ($minimumTotalRamGB * 1GB)) {
        throw "Insufficient RAM: $([math]::Round($totalRamBytes / 1GB, 1)) GB total; $minimumTotalRamGB GB required."
    }
    if ($freeRamBytes -lt ($minimumFreeRamGB * 1GB)) {
        throw "Insufficient free RAM: $([math]::Round($freeRamBytes / 1GB, 1)) GB free; $minimumFreeRamGB GB required."
    }
    if ([double]$drive.Free -lt ($minimumFreeDiskGB * 1GB)) {
        throw "Insufficient disk space: $([math]::Round([double]$drive.Free / 1GB, 1)) GB free; $minimumFreeDiskGB GB required."
    }

    Write-Ok "Resource preflight passed ($([math]::Round($totalRamBytes / 1GB, 1)) GB RAM total, $([math]::Round($freeRamBytes / 1GB, 1)) GB RAM free, $([math]::Round([double]$drive.Free / 1GB, 1)) GB disk free)"
}

function Invoke-CheckedCommand {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$Description
    )

    Write-Step $Description
    if ($DryRun) {
        Write-Output "[DRY-RUN] $FilePath $($ArgumentList -join ' ')"
        return
    }

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

function Install-WingetPackage {
    param([pscustomobject]$Package)

    $description = "$($Package.Id) $($Package.Version) ($($Package.Name))"
    Write-Step "Install $description"
    if ($DryRun) {
        Write-Output "[DRY-RUN] winget install --id $($Package.Id) --version $($Package.Version)"
        return
    }

    $listOutput = (& winget.exe list --id $Package.Id --exact --accept-source-agreements 2>&1 | Out-String)
    $hasPinnedVersion = $LASTEXITCODE -eq 0 -and $listOutput.Contains($Package.Version)
    if ($hasPinnedVersion -and -not $script:ForceInstall) {
        Write-Skip $Package.Name
        return
    }

    $arguments = @(
        'install', '--id', $Package.Id, '--exact', '--version', $Package.Version,
        '--silent', '--disable-interactivity', '--force',
        '--accept-package-agreements', '--accept-source-agreements'
    )
    & winget.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $($Package.Id) $($Package.Version) (exit $LASTEXITCODE)"
    }
    Write-Ok "$($Package.Name) $($Package.Version) installed"
}

function Sync-ProcessPath {
    if ($DryRun) { return }
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

function Get-VerifiedAsset {
    param(
        [pscustomobject]$Asset,
        [string]$Label
    )

    $cacheDirectory = Join-Path $ToolsRoot 'downloads'
    $destination = Join-Path $cacheDirectory $Asset.FileName
    Write-Step "Download and verify $Label ($($Asset.FileName))"

    if ($DryRun) {
        Write-Information "[DRY-RUN] $Label <- $($Asset.Url) (SHA256 $($Asset.Sha256))" -InformationAction Continue
        return $destination
    }

    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $destination) {
        $cachedHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($cachedHash -eq $Asset.Sha256) {
            Write-Skip "$Label archive"
            return $destination
        }
        Remove-Item -LiteralPath $destination -Force
    }

    $partial = "$destination.part"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    try {
        Invoke-WebRequest -Uri $Asset.Url -OutFile $partial -UseBasicParsing
        $actualHash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $Asset.Sha256) {
            throw "$Label SHA256 mismatch: expected $($Asset.Sha256), got $actualHash"
        }
        Move-Item -LiteralPath $partial -Destination $destination -Force
    }
    finally {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }

    Write-Ok "$Label archive verified"
    return $destination
}

function Install-ZipAsset {
    param(
        [string]$Name,
        [string]$Version,
        [pscustomobject]$Asset,
        [string]$DirectoryName,
        [string]$Marker,
        [string]$ArchiveRoot = ''
    )

    $destination = Join-Path $ToolsRoot $DirectoryName
    $markerPath = Join-Path $destination $Marker
    Write-Step "Install $Name $Version -> $destination"
    if ($DryRun) {
        [void](Get-VerifiedAsset -Asset $Asset -Label "$Name $Version")
        return
    }

    if ((Test-Path -LiteralPath $markerPath) -and -not $script:ForceInstall) {
        Write-Skip "$Name $Version"
        return
    }

    $archive = Get-VerifiedAsset -Asset $Asset -Label "$Name $Version"
    $staging = "$destination.partial"
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
        if ([string]::IsNullOrEmpty($ArchiveRoot)) {
            Move-Item -LiteralPath $staging -Destination $destination
        }
        else {
            $source = Join-Path $staging $ArchiveRoot
            if (-not (Test-Path -LiteralPath $source)) {
                throw "$Name archive did not contain expected directory '$ArchiveRoot'"
            }
            Move-Item -LiteralPath $source -Destination $destination
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
        if (-not (Test-Path -LiteralPath $markerPath)) {
            throw "$Name install marker not found after extraction: $markerPath"
        }
    }
    catch {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }

    Write-Ok "$Name $Version installed"
}

function Install-John {
    $destination = Join-Path $ToolsRoot 'john'
    $marker = Join-Path $destination 'run\john.exe'
    Write-Step "Install John the Ripper $($Versions.John) -> $destination"
    if ($DryRun) {
        [void](Get-VerifiedAsset -Asset $Assets.John -Label "John the Ripper $($Versions.John)")
        return
    }

    if ((Test-Path -LiteralPath $marker) -and -not $script:ForceInstall) {
        Write-Skip "John the Ripper $($Versions.John)"
        return
    }

    $archive = Get-VerifiedAsset -Asset $Assets.John -Label "John the Ripper $($Versions.John)"
    $sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (-not (Test-Path -LiteralPath $sevenZip)) {
        $sevenZipCommand = Get-Command 7z.exe -ErrorAction SilentlyContinue
        if (-not $sevenZipCommand) { throw '7z.exe was not found after winget installation.' }
        $sevenZip = $sevenZipCommand.Source
    }

    $staging = "$destination.partial"
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        & $sevenZip x $archive "-o$staging" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7-Zip extraction failed with exit code $LASTEXITCODE" }
        $source = Join-Path $staging 'john-1.9.0-jumbo-1-win64'
        if (-not (Test-Path -LiteralPath $source)) { throw 'John archive layout is unexpected.' }
        Move-Item -LiteralPath $source -Destination $destination
        Remove-Item -LiteralPath $staging -Recurse -Force
        if (-not (Test-Path -LiteralPath $marker)) { throw 'john.exe not found after extraction.' }
    }
    catch {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    Write-Ok "John the Ripper $($Versions.John) installed"
}

function Install-RockYou {
    $wordlistsDirectory = Join-Path $ToolsRoot 'wordlists'
    $destination = Join-Path $wordlistsDirectory 'rockyou.txt'
    Write-Step "Install rockyou.txt -> $destination"
    if ($DryRun) {
        [void](Get-VerifiedAsset -Asset $Assets.RockYou -Label 'rockyou.txt')
        return
    }

    if ((Test-Path -LiteralPath $destination) -and -not $script:ForceInstall) {
        Write-Skip 'rockyou.txt'
        return
    }

    $archive = Get-VerifiedAsset -Asset $Assets.RockYou -Label 'rockyou.txt'
    New-Item -ItemType Directory -Path $wordlistsDirectory -Force | Out-Null
    $partial = "$destination.part"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue

    $inputStream = $null
    $gzipStream = $null
    $outputStream = $null
    try {
        $inputStream = [IO.File]::OpenRead($archive)
        $gzipStream = [IO.Compression.GZipStream]::new(
            $inputStream,
            [IO.Compression.CompressionMode]::Decompress
        )
        $outputStream = [IO.File]::Create($partial)
        $gzipStream.CopyTo($outputStream)
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($gzipStream) { $gzipStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
    }
    Move-Item -LiteralPath $partial -Destination $destination -Force
    Write-Ok 'rockyou.txt installed'
}

function Find-Python312 {
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($launcher) {
        return [pscustomobject]@{ FilePath = $launcher.Source; Prefix = @('-3.12') }
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'Python312\python.exe'),
        (Join-Path $env:LocalAppData 'Programs\Python\Python312\python.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return [pscustomobject]@{ FilePath = $candidate; Prefix = @() }
        }
    }
    throw 'Python 3.12 was not found after winget installation.'
}

function Install-PythonPackageSet {
    $venvDirectory = Join-Path $ToolsRoot 'venv'
    Write-Step "Install native Python packages: pycryptodome, ROPgadget==$($Versions.ROPgadget)"
    if ($DryRun) {
        Write-Output "[DRY-RUN] Python venv ${venvDirectory}: pycryptodome ROPgadget==$($Versions.ROPgadget)"
        return
    }

    $python = Find-Python312
    if (-not (Test-Path -LiteralPath (Join-Path $venvDirectory 'Scripts\python.exe'))) {
        $venvArgs = @($python.Prefix) + @('-m', 'venv', $venvDirectory)
        Invoke-CheckedCommand -FilePath $python.FilePath -ArgumentList $venvArgs -Description 'Create native Python virtual environment'
    }
    else {
        Write-Skip 'native Python virtual environment'
    }

    $venvPython = Join-Path $venvDirectory 'Scripts\python.exe'
    Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @(
        '-m', 'pip', 'install', '--no-cache-dir', '--upgrade', 'pip'
    ) -Description 'Upgrade pip'
    Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @(
        '-m', 'pip', 'install', '--no-cache-dir', 'pycryptodome', "ROPgadget==$($Versions.ROPgadget)"
    ) -Description 'Install pycryptodome and ROPgadget'
    Write-Ok 'native Python packages installed'
}

function Clear-DownloadCache {
    $cacheDirectory = Join-Path $ToolsRoot 'downloads'
    if ($script:KeepDownloadCache) {
        if ($DryRun) {
            Write-Information '[DRY-RUN] download cache will be kept' -InformationAction Continue
        }
        else {
            Write-Information '[i] download cache will be kept' -InformationAction Continue
        }
        return
    }
    if ($DryRun) {
        Write-Information '[DRY-RUN] download cache will be removed after a successful install' -InformationAction Continue
        return
    }
    if (Test-Path -LiteralPath $cacheDirectory) {
        Remove-Item -LiteralPath $cacheDirectory -Recurse -Force
        Write-Ok 'Download cache removed'
    }
}

function Write-CmdLauncher {
    param([string]$Name, [string]$Content)
    if ($DryRun) { return }
    $binDirectory = Join-Path $ToolsRoot 'bin'
    New-Item -ItemType Directory -Path $binDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $binDirectory "$Name.cmd") -Value $Content -Encoding ASCII
}

function Install-LauncherSet {
    Write-Step 'Create command launchers (ghidra, ffuf, john, steghide, dirbuster)'
    if ($DryRun) {
        Write-Output "[DRY-RUN] launchers -> $(Join-Path $ToolsRoot 'bin')"
        return
    }

    Write-CmdLauncher -Name 'ghidra' -Content @'
@echo off
call "%~dp0..\ghidra\ghidraRun.bat" %*
'@
    Write-CmdLauncher -Name 'ffuf' -Content @'
@echo off
"%~dp0..\ffuf\ffuf.exe" %*
'@
    Write-CmdLauncher -Name 'steghide' -Content @'
@echo off
"%~dp0..\steghide\steghide.exe" %*
'@
    Write-CmdLauncher -Name 'dirbuster' -Content @'
@echo off
pushd "%~dp0..\dirbuster"
java -jar "DirBuster-1.0-RC1.jar" %*
set EXITCODE=%ERRORLEVEL%
popd
exit /b %EXITCODE%
'@
    Write-CmdLauncher -Name 'john' -Content @'
@echo off
pushd "%~dp0..\john\run"
john.exe %*
set EXITCODE=%ERRORLEVEL%
popd
exit /b %EXITCODE%
'@
    Write-Ok 'command launchers created'
}

function Add-ToolsToMachinePath {
    $entries = @(
        (Join-Path $ToolsRoot 'bin'),
        (Join-Path $ToolsRoot 'venv\Scripts')
    )
    Write-Step "Add CTF tool directories to machine PATH: $($entries -join '; ')"
    if ($DryRun) {
        Write-Output "[DRY-RUN] machine PATH += $($entries -join '; ')"
        return
    }

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = @($machinePath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($entry in $entries) {
        if ($parts -notcontains $entry) { $parts += $entry }
        if (($env:Path -split ';') -notcontains $entry) { $env:Path += ";$entry" }
    }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'Machine')
    Write-Ok 'machine PATH updated'
}

function Install-WSLToolchain {
    Write-Step "Optional WSL Ubuntu-24.04 toolchain: gdb, pwndbg $($Versions.Pwndbg), pwntools==$($Versions.Pwntools)"
    if ($DryRun) {
        Write-Output "[DRY-RUN] Ubuntu-24.04: apt gdb + pwndbg $($Versions.Pwndbg) + pwntools==$($Versions.Pwntools)"
        return
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe is unavailable. Enable Windows Subsystem for Linux, reboot, and rerun with -IncludeWSL.'
    }

    $distro = 'Ubuntu-24.04'
    $installedDistros = @(& wsl.exe --list --quiet 2>$null | ForEach-Object { $_.Trim([char]0).Trim() })
    if ($installedDistros -notcontains $distro) {
        Invoke-CheckedCommand -FilePath 'wsl.exe' -ArgumentList @(
            '--install', '--distribution', $distro, '--no-launch'
        ) -Description "Install WSL distribution $distro"
        $installedDistros = @(& wsl.exe --list --quiet 2>$null | ForEach-Object { $_.Trim([char]0).Trim() })
        if ($installedDistros -notcontains $distro) {
            throw "WSL requested a reboot. Restart Windows, then rerun this script with -IncludeWSL."
        }
    }
    else {
        Write-Skip "WSL distribution $distro"
    }

    $linuxScript = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PIP_NO_CACHE_DIR=1
export MAKEFLAGS=-j2
apt-get update -qq
apt-get install -y sudo gdb git curl ca-certificates python3 python3-pip python3-venv build-essential \
  libssl-dev libffi-dev python3-dev
if [ ! -d /opt/ctf/venv ]; then
  python3 -m venv /opt/ctf/venv
fi
/opt/ctf/venv/bin/pip install --quiet --no-cache-dir --upgrade pip
/opt/ctf/venv/bin/pip install --quiet --no-cache-dir 'pwntools==__PWNTOOLS__'
if ! pwndbg --version 2>/dev/null | grep -Fq '__PWNDBG__'; then
  curl --proto '=https' --tlsv1.2 -LfsS '__PWNDBG_URL__' -o /tmp/pwndbg.deb
  printf '%s  %s\n' '__PWNDBG_SHA256__' /tmp/pwndbg.deb | sha256sum -c -
  apt-get install -y --allow-downgrades /tmp/pwndbg.deb
  rm -f /tmp/pwndbg.deb
fi
printf '%s\n' 'export PATH=/opt/ctf/venv/bin:$PATH' > /etc/profile.d/ctf-tools.sh
apt-get clean
rm -rf /var/lib/apt/lists/* /root/.cache/pip
'@
    $linuxScript = $linuxScript.Replace('__PWNTOOLS__', $Versions.Pwntools)
    $linuxScript = $linuxScript.Replace('__PWNDBG__', $Versions.Pwndbg)
    $linuxScript = $linuxScript.Replace('__PWNDBG_URL__', $Assets.PwndbgDeb.Url)
    $linuxScript = $linuxScript.Replace('__PWNDBG_SHA256__', $Assets.PwndbgDeb.Sha256)
    $encodedLinuxScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($linuxScript))
    $bootstrapCommand = "printf '%s' '$encodedLinuxScript' | base64 -d | bash"
    Invoke-CheckedCommand -FilePath 'wsl.exe' -ArgumentList @(
        '--distribution', $distro, '--user', 'root', '--',
        'bash', '-lc', $bootstrapCommand
    ) -Description "Configure gdb, pwndbg $($Versions.Pwndbg), and pwntools==$($Versions.Pwntools) in $distro"
    Write-Ok 'WSL pwn toolchain installed'
}

Write-Output '=== CTF Tools Installer for Windows 11 ==='
Write-Output "Tools root: $ToolsRoot"
if ($DryRun) { Write-Output 'Mode: DRY-RUN (no system changes)' }

Assert-WindowsAdministrator
Assert-SystemResource
if (-not $DryRun) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $ToolsRoot -Force | Out-Null
}

foreach ($package in $WingetPackages) {
    Install-WingetPackage -Package $package
}
Sync-ProcessPath

Install-ZipAsset -Name 'Ghidra' -Version $Versions.Ghidra -Asset $Assets.Ghidra `
    -DirectoryName 'ghidra' -Marker 'ghidraRun.bat' -ArchiveRoot 'ghidra_12.1.2_PUBLIC'
Install-ZipAsset -Name 'ffuf' -Version $Versions.Ffuf -Asset $Assets.Ffuf `
    -DirectoryName 'ffuf' -Marker 'ffuf.exe'
Install-John
Install-ZipAsset -Name 'steghide' -Version $Versions.Steghide -Asset $Assets.Steghide `
    -DirectoryName 'steghide' -Marker 'steghide.exe' -ArchiveRoot 'steghide'
Install-ZipAsset -Name 'DirBuster' -Version $Versions.DirBuster -Asset $Assets.DirBuster `
    -DirectoryName 'dirbuster' -Marker 'DirBuster-1.0-RC1.jar' -ArchiveRoot 'DirBuster-1.0-RC1'
Install-RockYou
Install-PythonPackageSet
Install-LauncherSet
Add-ToolsToMachinePath

if ($IncludeWSL) {
    Install-WSLToolchain
}
else {
    Write-Output '[i] WSL pwn stack skipped. Rerun with -IncludeWSL for gdb, pwndbg and pwntools.'
}

Clear-DownloadCache
Write-Output ''
Write-Output '=== Installation complete ==='
Write-Output "Tools: $ToolsRoot"
Write-Output "Wordlist: $(Join-Path $ToolsRoot 'wordlists\rockyou.txt')"
Write-Output 'Open a new terminal before using commands added to PATH.'
