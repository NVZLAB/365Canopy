param([string]$SiteUrl,[guid]$TenantId,[guid]$ClientId,[string]$LibraryName,[switch]$RecursiveFolders,[switch]$IncludeFiles,[switch]$AllOneDrives,[Parameter(Mandatory)][string]$PnPModulePath,[string]$ResultPath)
$ErrorActionPreference='Stop'
if ($AllOneDrives) {
    $snapshot=& (Join-Path $PSScriptRoot 'Collect-OneDrives.ps1') -SiteUrl $SiteUrl -TenantId $TenantId -ClientId $ClientId -IncludeFiles:$IncludeFiles -PnPModulePath $PnPModulePath
} else {
    $snapshot=& (Join-Path $PSScriptRoot 'Collect-Delegated.ps1') -SiteUrl $SiteUrl -TenantId $TenantId -ClientId $ClientId -LibraryName $LibraryName -RecursiveFolders:$RecursiveFolders -IncludeFiles:$IncludeFiles -IncludeDirectoryMembership -PnPModulePath $PnPModulePath
}
if (!$ResultPath) {
    Write-Output ('CANOPY:'+($snapshot|ConvertTo-Json -Depth 40 -Compress))
    return
}
Write-Host 'CANOPY_PROGRESS:Saving local recovery snapshot…'
$pending=$ResultPath+'.pending'
$stream=[IO.File]::Open($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
try {
    $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false),65536,$true)
    try {$writer.Write(($snapshot | ConvertTo-Json -Depth 40 -Compress))} finally {$writer.Dispose()}
    $stream.Flush($true)
} finally {$stream.Dispose()}
[IO.File]::Move($pending,$ResultPath)