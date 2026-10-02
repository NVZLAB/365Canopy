param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Canopy.Dependency.psm1') -Force
Install-CanopyDependency -Destination $Destination
Write-Output 'CANOPY_SETUP:ready'
