[CmdletBinding()]
param(
    [string]$SiteUrl,
    [string]$TenantId,
    [string]$LibraryName,
    [string]$ClientId,
    [string]$FolderSiteRelativeUrl,
    [switch]$RecursiveFolders,
    [switch]$IncludeFiles,
    [switch]$IncludeDirectoryMembership,
    [string]$ExportPath,
    [switch]$Check
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($Check) {
    & (Join-Path $PSScriptRoot 'tests/Checkpoint.Checks.ps1')
    if ($PSVersionTable.PSVersion.Major -ge 7) { & (Join-Path $PSScriptRoot 'tests/Delegated.Checks.ps1') }
    & (Join-Path $PSScriptRoot 'tests/Collector.ReadOnly.Checks.ps1')
    & (Join-Path $PSScriptRoot 'tests/ItemInventory.Checks.ps1')
    & (Join-Path $PSScriptRoot 'tests/PublicationPrivacy.Checks.ps1')
    return
}
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Start the checkpoint in PowerShell 7. The SharePoint helper uses Windows PowerShell 5.1 separately.' }
if ($IncludeFiles -and !$ClientId) { throw 'File review requires the delegated public-client route. Provide ClientId.' }
if ($ClientId) {
    if (!$SiteUrl -or !$TenantId -or !$LibraryName) { throw 'Delegated audit requires SiteUrl, TenantId, ClientId and LibraryName.' }
    & (Join-Path $PSScriptRoot 'src/Canopy.Checkpoint/Collect-Delegated.ps1') -SiteUrl $SiteUrl -TenantId $TenantId -ClientId $ClientId -LibraryName $LibraryName -FolderSiteRelativeUrl $FolderSiteRelativeUrl -RecursiveFolders:$RecursiveFolders -IncludeFiles:$IncludeFiles -IncludeDirectoryMembership:$IncludeDirectoryMembership -ExportPath $ExportPath
    return
}
Import-Module (Join-Path $PSScriptRoot 'src/Canopy.Checkpoint/Canopy.Core.psm1') -Force
if (!$SiteUrl) { $SiteUrl=Read-Host 'Test SharePoint site collection URL' }
$target=Resolve-CanopyTarget -SiteUrl $SiteUrl
if ($ExportPath) {
    $exportFullPath=[IO.Path]::GetFullPath($ExportPath)
    if ([IO.File]::Exists($exportFullPath) -or ![IO.Directory]::Exists([IO.Path]::GetDirectoryName($exportFullPath))) { throw 'Choose a new export filename in an existing directory before signing in.' }
}
if ($IncludeDirectoryMembership -and (!$TenantId -or $TenantId -notmatch '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')) { throw 'Directory expansion requires the expected tenant GUID.' }
function Find-WorkspaceModule([string]$Name) {
    $base=Join-Path $PSScriptRoot "work/modules/$Name"
    $manifest=Get-ChildItem $base -Filter "$Name.psd1" -Recurse -ErrorAction SilentlyContinue | Sort-Object { [version]$_.Directory.Name } -Descending | Select-Object -First 1
    if (!$manifest) { throw "Missing workspace module $Name. Run ./Setup-Checkpoint.ps1 first." }
    $manifest.FullName
}
$spo=Find-WorkspaceModule 'Microsoft.Online.SharePoint.PowerShell'
$graph=if ($IncludeDirectoryMembership) { Find-WorkspaceModule 'Microsoft.Graph.Authentication' } else { $null }
$snapshot=[ordered]@{ schemaVersion='0.1-spike'; applicationVersion='0.1.0-alpha'; auditId=[guid]::NewGuid().ToString(); startedAt=[DateTime]::UtcNow.ToString('o'); completedAt=$null; scope=@{ siteUrl=$target.SiteUrl; libraryName=$LibraryName; depth='site inventory and group membership only'; cloud='commercial' }; tenantId=$TenantId; tenantBinding='SharePoint host checked; SPO tenant GUID and account unverified'; graphAccount=$null; state='partial'; sharePoint=$null; directoryGroups=@(); capabilities=@(
    @{ operation='Web/library role assignments and inheritance'; state='unsupported'; reason='No documented collector under the no-custom-app module route has been established. No grants asserted.' },
    @{ operation='Folder/item permissions and sharing links'; state='notRequested'; reason='Outside this authentication spike.' }
); coverage=[Collections.Generic.List[object]]::new() }
Write-Host '365Canopy authentication/coverage spike — read-only, incomplete permissions coverage.'
Write-Host 'Sign in to Microsoft as your test-tenant administrator. No site access will be added.'
$stage='SharePoint helper'
try {
    $native=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $lines=@(& $native -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'src/Canopy.Checkpoint/Collect-SharePoint.ps1') -SiteUrl $target.SiteUrl -ModuleManifest $spo)
    $payload=@($lines | Where-Object { $_ -is [string] -and $_.StartsWith('CANOPY:') })
    if ($LASTEXITCODE -ne 0 -or $payload.Count -ne 1) { throw 'SharePoint helper did not return a valid snapshot.' }
    $snapshot.sharePoint=$payload[0].Substring(7) | ConvertFrom-Json
    if ($snapshot.sharePoint.siteUrl -ne $target.SiteUrl -or $snapshot.sharePoint.adminUrl -ne $target.AdminUrl) { throw 'SharePoint helper target mismatch.' }
    $ids=[Collections.Generic.HashSet[string]]::new()
    foreach ($group in $snapshot.sharePoint.groups) { foreach ($member in $group.members) { if ($member.directoryGroupId) { [void]$ids.Add($member.directoryGroupId) } } }
    if ($snapshot.sharePoint.site -and $snapshot.sharePoint.site.groupId -and $snapshot.sharePoint.site.groupId -ne [guid]::Empty.ToString()) { [void]$ids.Add($snapshot.sharePoint.site.groupId) }
    if ($IncludeDirectoryMembership -and $snapshot.sharePoint.connected -and $ids.Count) {
        $stage='Directory authentication'
        Import-Module $graph
        # Microsoft module public client; no custom client ID, app-only secret or token export.
        Connect-MgGraph -TenantId $TenantId -Scopes 'GroupMember.Read.All' -ContextScope Process -NoWelcome | Out-Null
        $context=Get-MgContext
        if ($context.TenantId -ne $TenantId -or $context.AuthType -ne 'Delegated' -or $context.ContextScope -ne 'Process') { throw 'Directory session tenant or authentication mode mismatch.' }
        $snapshot.graphAccount=$context.Account
        $stage='Directory membership'
        $snapshot.directoryGroups=@(Get-CanopyDirectoryMembership -GroupIds @($ids) -Request { param($uri) Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable })
        $snapshot.coverage.Add(@{ operation='Directory session'; state='observed'; reason='Graph tenant GUID verified; SharePoint host-to-GUID and same-account binding remain unverified.' })
    } else {
        $snapshot.coverage.Add(@{ operation='Directory membership'; state='notRequested'; reason='Expansion not enabled, SharePoint connection unavailable, or no recognized directory group IDs observed.' })
    }
} catch {
    $diagnostic='Exception type: '+$_.Exception.GetType().FullName+'; HRESULT: '+$_.Exception.HResult
    if ($_.Exception.Message -match 'AADSTS[0-9]+') { $diagnostic+='; '+$Matches[0] }
    if ($_.Exception.Message -match 'window handle') { $diagnostic+='; WAM requires an interactive terminal window handle' }
    $snapshot.coverage.Add(@{ operation=$stage; state=(Get-CanopyFailureState $_); reason="Stage failed or sign-in was interrupted. $diagnostic. Completed evidence retained; raw service errors and tokens excluded." })
} finally {
    if (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) {
        try {
            if (Get-MgContext) { Disconnect-MgGraph | Out-Null; $snapshot.coverage.Add(@{ operation='Directory disconnect'; state='observed'; reason='Disconnect command completed. Browser/OS state can remain.' }) }
        } catch { $snapshot.coverage.Add(@{ operation='Directory disconnect'; state='failed'; reason='Disconnect command failed; exit this process to release remaining session references.' }) }
    }
    $snapshot.completedAt=[DateTime]::UtcNow.ToString('o')
}
$groupCount=if ($snapshot.sharePoint) { @($snapshot.sharePoint.groups).Count } else { 0 }
Write-Host "Collected $groupCount SharePoint groups and $(@($snapshot.directoryGroups).Count) directory group records. Coverage: partial. Library grants: unsupported in this spike."
if ($ExportPath) {
    # Explicit export only; never overwrite previous evidence.
    $full=[IO.Path]::GetFullPath($ExportPath)
    $json=$snapshot | ConvertTo-Json -Depth 40
    $stream=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    $writer=$null
    try { $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false)); $writer.Write($json); $writer.Flush() } finally { if ($writer) { $writer.Dispose() }; $stream.Dispose() }
    Write-Host "JSON exported to $full"
}
# Return structured data for local inspection without automatically saving it.
[pscustomobject]$snapshot
