param([string]$Source, [string]$InstallRoot, [switch]$NoLaunch, [switch]$ResetToken, [switch]$VerifyAll)
. (Join-Path $PSScriptRoot 'Common.ps1')
if (!$InstallRoot) { $InstallRoot = Join-Path $PSScriptRoot 'Game' }
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$launcherRoot = [IO.Path]::GetDirectoryName($InstallRoot)
$stateRoot = Join-Path $launcherRoot ('.' + [IO.Path]::GetFileName($InstallRoot) + '-update')
$lock = $null
try {
    Write-Host 'LUMEN ONLINE - update and play (no Unity build)' -ForegroundColor Cyan
    if (!$Source) {
        $settings = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'launcher.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $Source = [string]$settings.source
    }
    if (!$Source) { throw 'Set the distribution URL or shared folder in launcher.json first.' }
    if ($Source -match '^[a-zA-Z]+://' -and $Source -notmatch '^https?://') { throw 'Use an HTTPS URL or a shared folder path.' }
    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    $lock = [IO.File]::Open((Join-Path $stateRoot 'update.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    if ($Source -match '^https://api\.github\.com/repos/') {
        $tokenPath = Join-Path $stateRoot 'github-token.xml'
        if ($env:LUMEN_UPDATE_TOKEN) { [LumenDistribution.BlockTransfer]::GitHubToken = $env:LUMEN_UPDATE_TOKEN }
        else {
            if ($ResetToken -or !(Test-Path -LiteralPath $tokenPath)) {
                Write-Host 'First-time setup: enter a GitHub token with read-only Contents permission for the game distribution repository.'
                $secret = Read-Host 'GitHub token (hidden)' -AsSecureString
                if ($secret.Length -eq 0) { throw 'A token is required for private GitHub downloads.' }
                $secret | Export-Clixml -LiteralPath $tokenPath
            }
            $secret = Import-Clixml -LiteralPath $tokenPath
            [LumenDistribution.BlockTransfer]::GitHubToken = ([Net.NetworkCredential]::new('', $secret)).Password
        }
    }
    $exe = Get-SafePath $InstallRoot 'LumenOnline.exe'
    foreach ($player in @(Get-Process -Name LumenOnline -ErrorAction SilentlyContinue)) {
        if (!$player.Path -or $player.Path -eq $exe) { throw 'Close LumenOnline before updating. The current match will not be stopped automatically.' }
    }
    $bytes = [LumenDistribution.BlockTransfer]::Fetch($Source, 'manifest.json', 16MB)
    $json = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    $manifest = $json | ConvertFrom-Json
    Assert-Manifest $manifest $InstallRoot
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $identity = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    $stageRoot = Join-Path $stateRoot $identity
    $installedManifest = Join-Path $stateRoot 'installed.json'
    $previous = $null
    $previousFiles = @{}
    if (Test-Path -LiteralPath $installedManifest) {
        $previous = Get-Content -LiteralPath $installedManifest -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Manifest $previous $InstallRoot
        foreach ($file in $previous.files) { $previousFiles[$file.path] = $file }
    }
    [LumenDistribution.BlockTransfer]::DownloadedBytes = 0
    [LumenDistribution.BlockTransfer]::ReusedBytes = 0
    $changed = [Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($file in $manifest.files) {
        $index++
        Write-Progress -Activity "Updating $($manifest.version)" -Status $file.path -PercentComplete (100 * $index / @($manifest.files).Count)
        $target = Get-SafePath $InstallRoot $file.path
        $unchanged = $false
        if ([IO.File]::Exists($target)) {
            $info = Get-Item -LiteralPath $target
            if ($info.Length -eq $file.length) {
                $cached = $previousFiles[$file.path]
                $unchanged = !$VerifyAll -and $cached -and $cached.sha256 -eq $file.sha256 -and
                    ($cached.PSObject.Properties.Name -contains 'verifiedLastWriteUtcTicks') -and
                    $cached.verifiedLastWriteUtcTicks -eq $info.LastWriteTimeUtc.Ticks.ToString()
                if (!$unchanged) { $unchanged = [LumenDistribution.BlockTransfer]::Hash($target) -eq $file.sha256 }
            }
        }
        if ($unchanged) {
            [LumenDistribution.BlockTransfer]::ReusedBytes += $file.length
            continue
        }
        $record = [LumenDistribution.FileRecord]::new()
        $record.path = $file.path; $record.length = $file.length; $record.sha256 = $file.sha256; $record.blocks = [string[]]@($file.blocks)
        $staging = Get-SafePath $stageRoot $file.path
        [LumenDistribution.BlockTransfer]::Stage($record, $target, $staging, $Source)
        $changed.Add($file)
    }
    # Complete and verify every download before touching the playable installation.
    foreach ($file in $changed) {
        $target = Get-SafePath $InstallRoot $file.path
        $staging = Get-SafePath $stageRoot $file.path
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        [LumenDistribution.BlockTransfer]::Commit($staging, $target)
    }
    if ($previous) {
        $keep = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $manifest.files) { $null = $keep.Add($file.path) }
        foreach ($file in $previous.files) {
            if (!$keep.Contains($file.path)) {
                $obsolete = Get-SafePath $InstallRoot $file.path
                if ([IO.File]::Exists($obsolete)) { [IO.File]::Delete($obsolete) }
            }
        }
    }
    foreach ($file in $manifest.files) {
        $target = Get-SafePath $InstallRoot $file.path
        $file | Add-Member -NotePropertyName verifiedLastWriteUtcTicks -NotePropertyValue (Get-Item -LiteralPath $target).LastWriteTimeUtc.Ticks.ToString() -Force
    }
    Write-AtomicText $installedManifest ($manifest | ConvertTo-Json -Depth 8)
    Write-Progress -Activity 'Updating' -Completed
    Write-Host ('Ready: {0}. Downloaded {1:N2} MiB; reused {2:N2} MiB.' -f $manifest.version, ([LumenDistribution.BlockTransfer]::DownloadedBytes / 1MB), ([LumenDistribution.BlockTransfer]::ReusedBytes / 1MB)) -ForegroundColor Green
    if (!$NoLaunch) { Start-Process -FilePath $exe -WorkingDirectory $InstallRoot -WindowStyle Normal }
} catch {
    Write-Host ('Update failed. The game was not launched. ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally { [LumenDistribution.BlockTransfer]::GitHubToken = $null; if ($lock) { $lock.Dispose() } }
