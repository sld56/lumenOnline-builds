$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!('LumenDistribution.BlockTransfer' -as [type])) {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        # HttpWebRequest keeps the same download implementation on Windows PowerShell 5.1.
        Add-Type -Path (Join-Path $PSScriptRoot 'BlockTransfer.cs') -CompilerOptions '/nowarn:SYSLIB0014'
    } else { Add-Type -Path (Join-Path $PSScriptRoot 'BlockTransfer.cs') }
}
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Write-AtomicText([string]$Path, [string]$Text) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
        [LumenDistribution.BlockTransfer]::Commit($temporary, $Path)
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Get-SafePath([string]$Root, [string]$Relative) {
    if (!$Relative -or $Relative.Length -gt 220 -or $Relative -match '[\\:\x00-\x1f<>"|?*]' -or $Relative.StartsWith('/')) {
        throw "Invalid package path: $Relative"
    }
    foreach ($segment in $Relative.Split('/')) {
        if (!$segment -or $segment -in @('.', '..') -or $segment -match '[. ]$' -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "Invalid package path: $Relative"
        }
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $target = [IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (!$target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'Package path escapes installation.' }
    $current = $target
    while ($current -and $current.Length -ge $base.TrimEnd('\').Length) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Links are not allowed inside the installation: $current" }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    return $target
}

function Assert-Manifest($Manifest, [string]$Root) {
    if ($Manifest.schema -ne 1 -or $Manifest.blockSize -ne [LumenDistribution.BlockTransfer]::BlockSize -or $Manifest.executable -ne 'LumenOnline.exe') { throw 'Unsupported update format.' }
    if (!$Manifest.version -or @($Manifest.files).Count -eq 0 -or @($Manifest.files).Count -gt 20000) { throw 'Invalid update manifest.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $Manifest.files) {
        $null = Get-SafePath $Root $file.path
        if (!$seen.Add($file.path)) { throw "Duplicate package path: $($file.path)" }
        if ($file.length -lt 0 -or $file.length -gt 100GB -or $file.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid file metadata.' }
        if (@($file.blocks).Count -ne [math]::Ceiling($file.length / [double]$Manifest.blockSize)) { throw 'Invalid block count.' }
        foreach ($hash in $file.blocks) { if ($hash -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid block hash.' } }
    }
    if (!$seen.Contains($Manifest.executable)) { throw 'The package does not contain LumenOnline.exe.' }
    foreach ($file in $Manifest.files) {
        $parent = [IO.Path]::GetDirectoryName($file.path).Replace('\', '/')
        while ($parent) {
            if ($seen.Contains($parent)) { throw 'A package file is also used as a directory.' }
            $parent = [IO.Path]::GetDirectoryName($parent).Replace('\', '/')
        }
    }
}
