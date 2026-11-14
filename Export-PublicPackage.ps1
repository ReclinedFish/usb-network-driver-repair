#requires -Version 5.1
[CmdletBinding()]
param([string]$DestinationDirectory)

$ErrorActionPreference = 'Stop'
if (-not $DestinationDirectory) {
    $DestinationDirectory = Join-Path $PSScriptRoot ('dist\public-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
}
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationDirectory)
$archive = $destination + '.zip'
if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $archive)) {
    throw 'Destination already exists. Choose a new directory; no files were overwritten.'
}

# Never recursively copy the development tree: reports and driver packages are private.
$allowed = @('.gitignore','LICENSE','README.md','PRIVACY.md','Repair-UsbNetworkDriver.ps1',
    'Export-PublicPackage.ps1','tests\Repair-UsbNetworkDriver.Tests.ps1')
$suspicious = @(
    '(?i)[a-z]:\\Users\\[^\\\s]+',
    '(?i)\b[0-9a-f]{2}(?:[:-][0-9a-f]{2}){5}\b',
    '(?i)\b(?:gh[pousr]_[a-z0-9]{30,}|github_pat_[a-z0-9_]{20,})',
    '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
)
$localMarkers = @($env:USERNAME, $env:COMPUTERNAME) | Where-Object { $_ -and $_.Length -ge 8 }
foreach ($relative in $allowed) {
    $source = Join-Path $PSScriptRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ('Required source file is missing: ' + $relative) }
    $content = Get-Content -LiteralPath $source -Raw
    foreach ($pattern in $suspicious) {
        if ($content -match $pattern) { throw ('Potential sensitive content in ' + $relative + '; review locally. Nothing packaged.') }
    }
    foreach ($marker in $localMarkers) {
        if ($content.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw ('Local identity found in ' + $relative + '; review locally. Nothing packaged.')
        }
    }
}
New-Item -ItemType Directory -Path (Join-Path $destination 'tests') -Force | Out-Null
foreach ($relative in $allowed) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination (Join-Path $destination $relative)
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($destination, $archive)
[pscustomobject]@{Directory=$destination;Archive=$archive;FileCount=$allowed.Count;ArchiveSHA256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash}
