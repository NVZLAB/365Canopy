param([string]$SiteUrl,[guid]$TenantId,[guid]$ClientId,[string]$LibraryName,[switch]$RecursiveFolders,[switch]$IncludeFiles,[switch]$AllOneDrives,[Parameter(Mandatory)][string]$PnPModulePath)
$ErrorActionPreference='Stop'
if ($AllOneDrives) {
    $snapshot=& (Join-Path $PSScriptRoot 'Collect-OneDrives.ps1') -SiteUrl $SiteUrl -TenantId $TenantId -ClientId $ClientId -IncludeFiles:$IncludeFiles -PnPModulePath $PnPModulePath
} else {
    $snapshot=& (Join-Path $PSScriptRoot 'Collect-Delegated.ps1') -SiteUrl $SiteUrl -TenantId $TenantId -ClientId $ClientId -LibraryName $LibraryName -RecursiveFolders:$RecursiveFolders -IncludeFiles:$IncludeFiles -IncludeDirectoryMembership -PnPModulePath $PnPModulePath
}
Write-Output ('CANOPY:'+($snapshot|ConvertTo-Json -Depth 40 -Compress))
