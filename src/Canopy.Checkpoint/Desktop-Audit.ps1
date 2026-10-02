param([string]$SiteUrl,[guid]$TenantId,[guid]$ClientId,[string]$LibraryName,[switch]$RecursiveFolders,[switch]$IncludeFiles)
$ErrorActionPreference='Stop'
$snapshot=& (Join-Path $PSScriptRoot 'Collect-Delegated.ps1') -SiteUrl $SiteUrl -TenantId $TenantId -ClientId $ClientId -LibraryName $LibraryName -RecursiveFolders:$RecursiveFolders -IncludeFiles:$IncludeFiles -IncludeDirectoryMembership
Write-Output ('CANOPY:'+($snapshot|ConvertTo-Json -Depth 40 -Compress))
