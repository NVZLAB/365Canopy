[CmdletBinding()]
param([Parameter(Mandatory)][string]$SiteUrl,[Parameter(Mandatory)][guid]$TenantId,[Parameter(Mandatory)][guid]$ClientId,[Parameter(Mandatory)][string]$PnPModulePath,[switch]$IncludeFiles)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Canopy.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Canopy.Delegated.psm1') -Force
Import-Module $PnPModulePath
$target=Resolve-CanopyTarget $SiteUrl
$root=[uri]$target.SiteUrl
if($root.AbsolutePath -ne '/'){throw 'OneDrive discovery requires the tenant SharePoint root URL.'}
$personalHost=$root.Host.Replace('.sharepoint.com','-my.sharepoint.com')
$audit=[ordered]@{
    schemaVersion='0.2-delegated';applicationVersion='0.1.0-alpha.10';auditId=[guid]::NewGuid().ToString()
    startedAt=[DateTime]::UtcNow.ToString('o');completedAt=$null;tenantId=$TenantId.ToString();clientId=$ClientId.ToString()
    accountObjectId=$null;accountLogin=$null;state='partial'
    scope=@{siteUrl=$target.SiteUrl;library='OneDrive document libraries';depth='Provisioned OneDrives returned by tenant discovery';includeFiles=[bool]$IncludeFiles;discovered=0;attempted=0;completed=0}
    resources=[Collections.Generic.List[object]]::new();grants=[Collections.Generic.List[object]]::new()
    sharePointGroups=[Collections.Generic.List[object]]::new();directoryGroups=@();coverage=[Collections.Generic.List[object]]::new()
}
function Add-Coverage($operation,$state,$reason) {
    $audit.coverage.Add([pscustomobject]@{operation=$operation;state=$state;reason=$reason;collectedAt=[DateTime]::UtcNow.ToString('o')})
}
$rootId='onedrives'
$audit.resources.Add([pscustomobject]@{id=$rootId;type='web';title='Tenant OneDrives';url=$target.SiteUrl;hasUniqueRoleAssignments=$null;sourceResourceId=$null})
$urls=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$directory=@{}
$admin=$null;$seed=$null;$batchSize=0L
try {
    Write-Host 'CANOPY_PROGRESS:Signing in for OneDrive discovery…'
    $admin=Connect-PnPOnline -Url $target.AdminUrl -Tenant $TenantId.ToString() -ClientId $ClientId.ToString() -Interactive -ReturnConnection
    $token=Get-PnPAccessToken -ResourceTypeName SharePoint -Connection $admin
    try {$actor=Get-CanopyTokenIdentity -Token $token -TenantId $TenantId.ToString() -ClientId $ClientId.ToString() -Audience '00000003-0000-0ff1-ce00-000000000000'} finally {$token=$null}
    $audit.accountObjectId=$actor.objectId
    $outOfScope=0
    try {
        Get-PnPTenantSite -IncludeOneDriveSites -Filter "Url -like '-my.sharepoint.com/personal/'" -Connection $admin | ForEach-Object {
            try {$url=Resolve-CanopyTarget $_.Url -AllowOneDrive} catch {$outOfScope++;return}
            if(([uri]$url.SiteUrl).Host -ne $personalHost){$outOfScope++}else{[void]$urls.Add($url.SiteUrl)}
        }
        Add-Coverage 'OneDrive discovery' 'observed' ("Tenant administration returned {0} provisioned OneDrive sites on the selected host." -f $urls.Count)
    } catch {Add-Coverage 'OneDrive discovery' 'partial' 'Tenant discovery failed or was interrupted. Any sites returned before the failure are retained. Verify SharePoint administrator access.'}
    if($outOfScope){Add-Coverage 'Other OneDrive hosts' 'skipped' "$outOfScope sites outside the supported personal-site URL format or selected host were excluded. Multi-geo discovery is not supported."}
    $audit.scope.discovered=$urls.Count
    foreach($url in ($urls | Sort-Object)){
        if($audit.coverage.Count -ge 190000){Add-Coverage 'Batch evidence limit' 'partial' 'Coverage limit reached; remaining drives were not attempted.';break}
        $audit.scope.attempted++
        $n=$audit.scope.attempted
        Write-Host ("CANOPY_PROGRESS:Reviewing OneDrive {0} of {1}" -f $n,$urls.Count)
        $connection=$null
        try {
            if(!$seed){$seed=Connect-PnPOnline -Url $url -Tenant $TenantId.ToString() -ClientId $ClientId.ToString() -Interactive -ReturnConnection;$connection=$seed}
            else{$connection=Connect-PnPOnline -Url $url -Tenant $TenantId.ToString() -ClientId $ClientId.ToString() -Interactive -Connection $seed -ReturnConnection}
            $drive=& (Join-Path $PSScriptRoot 'Collect-Delegated.ps1') -SiteUrl $url -TenantId $TenantId -ClientId $ClientId -LibraryName Documents -RecursiveFolders -IncludeFiles:$IncludeFiles -IncludeDirectoryMembership -PnPModulePath $PnPModulePath -ExistingConnection $connection -ExpectedObjectId $actor.objectId
        } catch {
            Add-Coverage ("OneDrive: "+$url) (Get-CanopyFailureState $_) 'Drive could not be read. No access was granted automatically.'
            if(!$seed){Add-Coverage 'OneDrive sign-in' 'partial' 'Could not establish the OneDrive session. Remaining drives were not attempted.';break}
            continue
        }
        if($drive.accountObjectId -ne $actor.objectId -or !$drive.resources.Count){
            Add-Coverage ("OneDrive: "+$url) 'failed' 'No resources collected. Verify the same administrator signed in and has existing access to this OneDrive.'
            continue
        }
        $prefix="drive:${n}:"
        $libraryNode=$drive.resources | Where-Object type -eq library | Select-Object -First 1
        $libraryId=if($libraryNode){$prefix+$libraryNode.id}else{$rootId}
        foreach($r in $drive.resources){
            $r.id=$prefix+$r.id
            if($r.sourceResourceId){$r.sourceResourceId=$prefix+$r.sourceResourceId}
            if($r.PSObject.Properties['parentResourceId'] -and $r.parentResourceId){$r.parentResourceId=$prefix+$r.parentResourceId}
            elseif($r.type -in @('folder','file')){$r.parentResourceId=$libraryId}
            elseif($r.PSObject.Properties['parentResourceId']){$r.parentResourceId=$rootId}
            else{$r | Add-Member -NotePropertyName parentResourceId -NotePropertyValue $rootId}
            if($r.type -eq 'web'){$r.title=([uri]$url).Segments[-1]}
        }
        foreach($g in $drive.grants){
            $g.resourceId=$prefix+$g.resourceId
            if($g.principal.type -eq 'SharePointGroup'){$g.principal.id=$prefix+$g.principal.id}
        }
        foreach($g in $drive.sharePointGroups){
            $g.id=$prefix+$g.id
            foreach($m in $g.members){if($m.type -eq 'SharePointGroup'){$m.id=$prefix+$m.id}}
        }
        foreach($c in $drive.coverage){$c.operation="$url · "+$c.operation}
        $batchSize+=($drive | ConvertTo-Json -Depth 40 -Compress).Length
        if($batchSize -gt 75MB -or ($audit.resources.Count+$drive.resources.Count) -gt 200000 -or ($audit.grants.Count+$drive.grants.Count) -gt 200000 -or ($audit.sharePointGroups.Count+$drive.sharePointGroups.Count) -gt 200000 -or ($audit.coverage.Count+$drive.coverage.Count) -gt 190000 -or ($directory.Count+$drive.directoryGroups.Count) -gt 200000){
            Add-Coverage 'Batch evidence limit' 'partial' ("Stopped at OneDrive {0}; its evidence and the remaining drives were not retained. Earlier results are available." -f $n)
            break
        }
        if($drive.accountLogin){$audit.accountLogin=$drive.accountLogin}
        $libraryNode=$drive.resources | Where-Object type -eq library | Select-Object -First 1
        $libraryId=if($libraryNode){$prefix+$libraryNode.id}else{$rootId}
        foreach($r in $drive.resources){$audit.resources.Add($r)}
        foreach($g in $drive.grants){$audit.grants.Add($g)}
        foreach($g in $drive.sharePointGroups){$audit.sharePointGroups.Add($g)}
        foreach($c in $drive.coverage){$audit.coverage.Add($c)}
        foreach($g in $drive.directoryGroups){
            $key="$($g.id):$($g.relationship)"
            if(!$directory.ContainsKey($key) -or ($directory[$key].state -ne 'observed' -and $g.state -eq 'observed')){$directory[$key]=$g}
        }
        if($drive.state -eq 'completed'){$audit.scope.completed++}
    }
} catch {Add-Coverage 'OneDrive audit' (Get-CanopyFailureState $_) 'Tenant sign-in or batch collection failed. Check prerequisites and coverage; earlier evidence was retained.'}
finally {
    $seed=$null;$admin=$null
    $audit.directoryGroups=@($directory.Values)
    $audit.completedAt=[DateTime]::UtcNow.ToString('o')
    $audit.state=if(@($audit.coverage | Where-Object {$_.state -notin @('observed','notRequested')}).Count){'partial'}else{'completed'}
    Add-Coverage 'OneDrive summary' 'observed' ("{0} discovered, {1} attempted, {2} completed without recorded gaps." -f $audit.scope.discovered,$audit.scope.attempted,$audit.scope.completed)
}
[pscustomobject]$audit
