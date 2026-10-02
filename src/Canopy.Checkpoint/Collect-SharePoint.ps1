# Runs in an isolated Windows PowerShell 5.1 process: SPO's supported module runtime.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SiteUrl, [Parameter(Mandatory)][string]$ModuleManifest)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'Canopy.Core.psm1') -Force
$target = Resolve-CanopyTarget -SiteUrl $SiteUrl
$coverage = [Collections.Generic.List[object]]::new()
$groups = [Collections.Generic.List[object]]::new()
$result = [ordered]@{ siteUrl=$target.SiteUrl; adminUrl=$target.AdminUrl; site=$null; connected=$false; accountVerification='unavailable: SPO exposes no supported session-account query in this spike'; groups=$groups; coverage=$coverage; moduleVersion=$null }
$stage='module initialization'
function Add-Coverage($operation, $state, $reason) { $coverage.Add([pscustomobject]@{ operation=$operation; state=$state; reason=$reason; collectedAt=[DateTime]::UtcNow.ToString('o') }) }
try {
    Import-Module $ModuleManifest -DisableNameChecking
    $result.moduleVersion = [string](Get-Module Microsoft.Online.SharePoint.PowerShell).Version
    if (!(Get-Command Connect-SPOService).Parameters.ContainsKey('UseSystemBrowser')) { throw 'Module lacks supported browser sign-in.' }
    $stage='browser authentication'
    Connect-SPOService -Url $target.AdminUrl -UseSystemBrowser $true | Out-Null
    $result.connected=$true
    Add-Coverage 'SharePoint connection' 'observed' 'Interactive module sign-in succeeded against the requested admin URL; session account and tenant GUID are not independently verified.'
    try {
        $site = Get-SPOSite -Identity $target.SiteUrl
        if ([string]$site.Url.TrimEnd('/') -ne $target.SiteUrl) { throw 'Site identity mismatch.' }
        $result.site = [pscustomobject]@{ url=$site.Url; title=$site.Title; template=$site.Template; groupId=[string]$site.GroupId; status=[string]$site.Status }
        Add-Coverage 'Site inventory' 'observed' 'Requested site metadata returned; this does not establish library or item access.'
    } catch { Add-Coverage 'Site inventory' (Get-CanopyFailureState $_) 'Site metadata unavailable. Verify URL and administrative rights.' }
    try {
        # Cmdlet has no paging API. Always disclose the bounded enumeration.
        $siteGroups = @(Get-SPOSiteGroup -Site $target.SiteUrl -Limit 5000)
        Add-Coverage 'SharePoint groups' 'partial' 'Bounded group listing (limit 5000); not a resource role-assignment enumeration.'
        foreach ($group in $siteGroups) {
            $entry=[ordered]@{ id=[string]$group.Id; title=$group.Title; reportedRoles=@($group.Roles); rolesMeaning='Module-reported group roles only; resource scope and inheritance unverified'; membershipState='failed'; members=@(); collectedAt=[DateTime]::UtcNow.ToString('o') }
            try {
                $entry.members=@(Get-SPOUser -Site $target.SiteUrl -Group $group.Title -Limit All | ForEach-Object { [pscustomobject]@{ loginName=$_.LoginName; displayName=$_.DisplayName; isSiteAdmin=$_.IsSiteAdmin; directoryGroupId=(Get-CanopyDirectoryGroupId $_.LoginName) } })
                $entry.membershipState='observed'
            } catch { $entry.membershipState=Get-CanopyFailureState $_; Add-Coverage ('Members of group '+$group.Id) $entry.membershipState 'Group members unavailable; do not infer zero members.' }
            $groups.Add([pscustomobject]$entry)
        }
    } catch { Add-Coverage 'SharePoint groups' (Get-CanopyFailureState $_) 'Group listing unavailable; Microsoft requires site collection administrator access for these cmdlets.' }
} catch { Add-Coverage 'SharePoint connection' (Get-CanopyFailureState $_) ("Failed during $stage. Exception type: " + $_.Exception.GetType().FullName + '; HRESULT: ' + $_.Exception.HResult + '. No credentials or service error bodies are included.') }
finally {
    if (Get-Command Disconnect-SPOService -ErrorAction SilentlyContinue) {
        try { Disconnect-SPOService | Out-Null; Add-Coverage 'SharePoint disconnect' 'observed' 'Disconnect command completed; helper process exits after returning results.' } catch { Add-Coverage 'SharePoint disconnect' 'failed' 'Disconnect failed; helper process exit ends its session.' }
    }
}
# No token or password is read, serialized or written to disk.
[Console]::WriteLine('CANOPY:' + ($result | ConvertTo-Json -Depth 30 -Compress))
