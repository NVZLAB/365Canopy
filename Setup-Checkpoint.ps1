[CmdletBinding()]
param([switch]$DesktopOnly)
$ErrorActionPreference='Stop'
$destination=Join-Path $PSScriptRoot 'work/modules'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
# Workspace-only modules; no global installation or tenant modification.
if (!$DesktopOnly) {
Save-Module -Name Microsoft.Online.SharePoint.PowerShell -RequiredVersion 16.0.27709.12000 -Path $destination -Repository PSGallery
Save-Module -Name Microsoft.Graph.Authentication -RequiredVersion 2.40.0 -Path $destination -Repository PSGallery
}
Save-Module -Name PnP.PowerShell -RequiredVersion 3.4.1 -Path $destination -Repository PSGallery
Write-Host 'Workspace modules saved. Start with ./Start-365Canopy.ps1 -Check.'
