[CmdletBinding()]
param([Parameter(Mandatory)][string]$SiteUrl,[Parameter(Mandatory)][guid]$TenantId,[Parameter(Mandatory)][guid]$ClientId,[Parameter(Mandatory)][string]$LibraryName,[string]$FolderSiteRelativeUrl,[switch]$RecursiveFolders,[switch]$IncludeFiles,[int]$MaxFolders=5000,[int]$MaxItems=40000,[string[]]$ExpectedAccount,[switch]$ForceAuthentication,[switch]$IncludeDirectoryMembership,[string]$ExportPath,[string]$PnPModulePath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Canopy.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Canopy.Delegated.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Canopy.Items.psm1') -Force
if ($IncludeFiles) { $RecursiveFolders=$true }
$target=Resolve-CanopyTarget $SiteUrl
if ($RecursiveFolders -and $FolderSiteRelativeUrl) { throw 'Choose recursive folders or a single selected folder.' }
if ($MaxFolders -lt 1 -or $MaxItems -lt 1 -or $MaxItems -gt 40000) { throw 'Use positive limits; MaxItems cannot exceed 40000.' }
$pnp=if($PnPModulePath){$PnPModulePath}else{Join-Path $PSScriptRoot '../../work/modules/PnP.PowerShell/3.4.1/PnP.PowerShell.psd1'}
Import-Module $pnp
if ($ExportPath -and ((Test-Path -LiteralPath $ExportPath) -or !(Test-Path -LiteralPath ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ExportPath)))))) { throw 'Export requires a new filename in an existing directory.' }
$audit=[ordered]@{schemaVersion='0.2-delegated';applicationVersion='0.1.0-alpha.8';auditId=[guid]::NewGuid().ToString();startedAt=[DateTime]::UtcNow.ToString('o');completedAt=$null;tenantId=$TenantId.ToString();clientId=$ClientId.ToString();accountObjectId=$null;scope=@{siteUrl=$target.SiteUrl;library=$LibraryName;depth='root web and selected library only';includeFiles=[bool]$IncludeFiles;itemLimit=$MaxItems};state='partial';resources=[Collections.Generic.List[object]]::new();grants=[Collections.Generic.List[object]]::new();sharePointGroups=[Collections.Generic.List[object]]::new();directoryGroups=@();coverage=[Collections.Generic.List[object]]::new()}
$connection=$null;$stage='Authentication';$web=$null;$list=$null
function Coverage([string]$Operation,[string]$State,[string]$Reason) { $audit.coverage.Add([pscustomobject]@{operation=$Operation;state=$State;reason=$Reason;collectedAt=[DateTime]::UtcNow.ToString('o')}) }
function Identity([string]$Resource,[string[]]$Audience) {
    $token=Get-PnPAccessToken -ResourceTypeName $Resource -Connection $connection
    try { Get-CanopyTokenIdentity -Token $token -TenantId $TenantId.ToString() -ClientId $ClientId.ToString() -Audience $Audience } finally { $token=$null }
}
try {
    Write-Host '365Canopy delegated checkpoint — sign in to Microsoft and review the configured read permissions.'
    Connect-PnPOnline -Url $target.SiteUrl -Tenant $TenantId.ToString() -ClientId $ClientId.ToString() -Interactive -ForceAuthentication:$ForceAuthentication
    $connection=Get-PnPConnection
    $actor=Identity 'SharePoint' '00000003-0000-0ff1-ce00-000000000000'
    $audit.accountObjectId=$actor.objectId
    $identityWeb=Get-PnPWeb -Includes CurrentUser -Connection $connection
    Get-PnPProperty -ClientObject $identityWeb.CurrentUser -Property Email,LoginName -Connection $connection | Out-Null
    $login=([string]$identityWeb.CurrentUser.LoginName).Split('|')[-1]
    if ($ExpectedAccount -and $login -notin $ExpectedAccount -and [string]$identityWeb.CurrentUser.Email -notin $ExpectedAccount) { throw 'Signed-in SharePoint account does not match the requested test account.' }
    $audit.accountLogin=$login
    Coverage 'Collector account' 'observed' 'SharePoint CurrentUser login recorded. When an expected account is supplied, login/email must match it.'
    Coverage 'SharePoint identity' 'observed' 'Delegated tenant, client, SharePoint audience, expiry and account object ID verified against the MSAL-issued token.'
    $stage='Root web'
    try {
        $web=Get-PnPWeb -Includes Id,Title,Url,HasUniqueRoleAssignments -Connection $connection
        if ([string]$web.Url.TrimEnd('/') -ne $target.SiteUrl) { throw 'Returned web URL mismatch.' }
        $webId='web:'+ $web.Id
        $audit.resources.Add([pscustomobject]@{id=$webId;type='web';title=$web.Title;url=$web.Url;hasUniqueRoleAssignments=$web.HasUniqueRoleAssignments;sourceResourceId=$webId;collectedAt=[DateTime]::UtcNow.ToString('o')})
        Get-PnPProperty -ClientObject $web -Property RoleAssignments -Connection $connection | Out-Null
        $webGrants=Get-CanopyResourceGrants $web $webId {param($a) Get-PnPProperty -ClientObject $a -Property Member,RoleDefinitionBindings -Connection $connection }
        foreach ($g in $webGrants.grants) {$audit.grants.Add($g)}
        Coverage 'Root web grants' $webGrants.state $webGrants.reason
    } catch { Coverage 'Root web grants' (Get-CanopyFailureState $_) ('Web permissions unavailable; no access is added automatically. Exception type: '+$_.Exception.GetType().FullName) }
    $stage='Library'
    try {
        $list=Get-PnPList -Identity $LibraryName -Includes Id,Title,BaseType,HasUniqueRoleAssignments,RootFolder,ItemCount -Connection $connection
        if (!$list -or [string]$list.BaseType -ne 'DocumentLibrary') { throw 'Selected document library not found.' }
        $listId='list:'+ $list.Id
        $source=if ($list.HasUniqueRoleAssignments) {$listId} elseif ($web) {$webId} else {$null}
        $audit.resources.Add([pscustomobject]@{id=$listId;type='library';title=$list.Title;url=$list.RootFolder.ServerRelativeUrl;hasUniqueRoleAssignments=$list.HasUniqueRoleAssignments;sourceResourceId=$source;collectedAt=[DateTime]::UtcNow.ToString('o')})
        if ($list.HasUniqueRoleAssignments) {
            Get-PnPProperty -ClientObject $list -Property RoleAssignments -Connection $connection | Out-Null
            $listGrants=Get-CanopyResourceGrants $list $listId {param($a) Get-PnPProperty -ClientObject $a -Property Member,RoleDefinitionBindings -Connection $connection }
            foreach ($g in $listGrants.grants) {$audit.grants.Add($g)}
            Coverage 'Library grants' $listGrants.state $listGrants.reason
        } elseif ($web -and (Get-Variable webGrants -ErrorAction SilentlyContinue) -and $webGrants.state -eq 'observed') { Coverage 'Library grants' 'observed' 'Library inherits from the root web. Follow sourceResourceId to its observed grants.' }
        else { Coverage 'Library grants' 'partial' 'Library inherits; parent grants unavailable or incomplete.' }
    } catch { Coverage 'Library grants' (Get-CanopyFailureState $_) ('Library or permission metadata unavailable. No grants or inheritance are inferred. Exception type: '+$_.Exception.GetType().FullName) }
    $stage='SharePoint membership'
    if ($FolderSiteRelativeUrl) {
        $stage='Selected folder'
        try {
            if (!$list -or $FolderSiteRelativeUrl -match '(^/|\.\.|:|\\|[?#])') { throw 'Invalid site-relative folder target.' }
            $folder=Get-PnPFolder -Url $FolderSiteRelativeUrl -Includes ListItemAllFields,ServerRelativeUrl -Connection $connection
            $libraryRoot=$list.RootFolder.ServerRelativeUrl.TrimEnd('/')+'/'
            if (!$folder.ServerRelativeUrl.StartsWith($libraryRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Folder is outside the selected library.' }
            $item=$folder.ListItemAllFields
            Get-PnPProperty -ClientObject $item -Property Id,HasUniqueRoleAssignments -Connection $connection | Out-Null
            $folderId='folder:'+ $list.Id+':'+$item.Id
            $audit.resources.Add([pscustomobject]@{id=$folderId;type='folder';title=$folder.Name;url=$folder.ServerRelativeUrl;hasUniqueRoleAssignments=$item.HasUniqueRoleAssignments;sourceResourceId=$(if($item.HasUniqueRoleAssignments){$folderId}else{$null});collectedAt=[DateTime]::UtcNow.ToString('o')})
            if ($item.HasUniqueRoleAssignments) {
                Get-PnPProperty -ClientObject $item -Property RoleAssignments -Connection $connection | Out-Null
                $folderGrants=Get-CanopyResourceGrants $item $folderId {param($a) Get-PnPProperty -ClientObject $a -Property Member,RoleDefinitionBindings -Connection $connection }
                foreach($g in $folderGrants.grants){$audit.grants.Add($g)}
                Coverage 'Selected folder grants' $folderGrants.state $folderGrants.reason
            } else { Coverage 'Selected folder grants' 'partial' 'Folder inherits; intermediate ancestors were not traversed, so no permission source is inferred.' }
        } catch { Coverage 'Selected folder grants' (Get-CanopyFailureState $_) 'Selected folder metadata or grants unavailable; no access is added and no grants are inferred.' }
        $audit.scope.depth='root web, selected library and explicitly selected folder only'
        $audit.scope.folder=$FolderSiteRelativeUrl
    }
    $stage='SharePoint membership'
    $groupIds=[Collections.Generic.HashSet[string]]::new()
    if ($RecursiveFolders) {
        $stage='Library item discovery'
        $audit.scope.depth=if($IncludeFiles){'entire selected library: all returned folders and files; file contents excluded'}else{'selected library and recursive folders; files excluded'}
        $found=[Collections.Generic.List[object]]::new();$discoveryComplete=$false
        try {
            if (!$list) { throw 'Library unavailable.' }
            $filter=if($IncludeFiles){''}else{'<Where><Eq><FieldRef Name="FSObjType"/><Value Type="Integer">1</Value></Eq></Where>'}
            $query='<View Scope="RecursiveAll"><Query>'+ $filter +'</Query><ViewFields><FieldRef Name="FileRef"/><FieldRef Name="FileDirRef"/><FieldRef Name="FileLeafRef"/><FieldRef Name="FSObjType"/></ViewFields><RowLimit Paged="TRUE">200</RowLimit></View>'
            $limit=if($IncludeFiles){$MaxItems}else{$MaxFolders}
            Get-PnPListItem -List $list -Query $query -PageSize 200 -Connection $connection | ForEach-Object {
                if ($found.Count -ge $limit) { throw 'Item limit reached.' }
                $found.Add($_)
                if($found.Count -eq 1 -or $found.Count % 200 -eq 0){Write-Host ('CANOPY_PROGRESS:Discovering library items: '+$found.Count+' returned')}
            }
            $discoveryComplete=$true
            Coverage 'Library item discovery' 'observed' ('Paged recursive query completed: '+$found.Count+' items returned.')
        } catch { Coverage 'Library item discovery' 'partial' 'Discovery interrupted, denied or item limit reached. Returned items retained; remaining items unknown.' }
        $audit.scope.returnedItemCount=$found.Count
        if($list) {
            if($IncludeFiles) {
                $audit.scope.libraryItemCountAtStart=$list.ItemCount
                Coverage 'Library item count' $(if($discoveryComplete -and $found.Count -eq $list.ItemCount){'observed'}else{'partial'}) ('Library reported '+$list.ItemCount+' items; discovery returned '+$found.Count+'. Count agreement does not prove visibility of security-trimmed items; concurrent changes can affect counts.')
            }
            $inventory=Get-CanopyItemInventory -Items @($found.ToArray()) -LibraryId $listId -LibraryRoot $list.RootFolder.ServerRelativeUrl -LibrarySource $source -ReadMetadata {
                param($item)
                Get-PnPProperty -ClientObject $item -Property HasUniqueRoleAssignments -Connection $connection | Out-Null
                [bool]$item.HasUniqueRoleAssignments
            } -ReadGrants {
                param($item,$id)
                Get-PnPProperty -ClientObject $item -Property RoleAssignments -Connection $connection | Out-Null
                Get-CanopyResourceGrants $item $id {param($a) Get-PnPProperty -ClientObject $a -Property Member,RoleDefinitionBindings -Connection $connection }
            }
            foreach($r in $inventory.resources){$audit.resources.Add($r)}
            foreach($g in $inventory.grants){$audit.grants.Add($g)}
            foreach($c in $inventory.coverage){$audit.coverage.Add($c)}
        }
    }
    $directoryIds=[Collections.Generic.HashSet[string]]::new()
    $ownerIds=[Collections.Generic.HashSet[string]]::new()
    foreach ($grant in $audit.grants) {
        if ($grant.principal.type -eq 'SharePointGroup') { [void]$groupIds.Add($grant.principal.id) }
        $id=Get-CanopyDirectoryGroupId $grant.principal.loginName
        if ($id -and !$grant.principal.loginName.EndsWith('_o')) { [void]$directoryIds.Add($id) }
        elseif ($id) { [void]$ownerIds.Add($id) }
    }
    foreach ($id in $groupIds) {
        $entry=[ordered]@{id=$id;state='observed';members=@();collectedAt=[DateTime]::UtcNow.ToString('o')}
        try {
            $entry.members=@(Get-PnPGroupMember -Group ([int]$id) -Connection $connection | ForEach-Object { ConvertTo-CanopyPrincipal $_ })
            foreach ($m in $entry.members) { $directoryId=Get-CanopyDirectoryGroupId $m.loginName; if ($directoryId -and !$m.loginName.EndsWith('_o')) {[void]$directoryIds.Add($directoryId)} elseif ($directoryId) {[void]$ownerIds.Add($directoryId)} }
            Coverage ('SharePoint group '+$id) 'observed' 'Direct group members collected.'
        } catch { $entry.state=Get-CanopyFailureState $_; Coverage ('SharePoint group '+$id) $entry.state 'Members unknown; collection failed.' }
        $audit.sharePointGroups.Add([pscustomobject]$entry)
    }
    if ($IncludeDirectoryMembership -and ($directoryIds.Count -or $ownerIds.Count)) {
        $stage='Directory identity'
        $graphActor=Identity 'Graph' @('00000003-0000-0000-c000-000000000000','https://graph.microsoft.com')
        if ($graphActor.objectId -ne $actor.objectId) { throw 'SharePoint and Graph account mismatch.' }
        Coverage 'Directory identity' 'observed' 'SharePoint and Graph tenant, client and account object IDs match.'
        $stage='Directory membership'
        $directoryRead={
            param($uri)
            $raw=Invoke-PnPGraphMethod -Url $uri -Method Get -Raw -Connection $connection
            $raw | ConvertFrom-Json -AsHashtable
        }
        $audit.directoryGroups=@(Get-CanopyDirectoryMembership -GroupIds @($directoryIds) -Request $directoryRead) + @(Get-CanopyDirectoryMembership -GroupIds @($ownerIds) -Relationship owners -Request $directoryRead)
        Resolve-CanopyMemberIdentity -Groups $audit.directoryGroups -Request $directoryRead
        $unresolved=@($audit.directoryGroups | ForEach-Object {$_.members} | Where-Object {$_.type -eq '#microsoft.graph.user' -and !$_.userPrincipalName})
        Coverage 'Member identity resolution' $(if($unresolved.Count){'partial'}else{'observed'}) $(if($unresolved.Count){'Some usernames unavailable. Add Graph delegated User.ReadBasic.All, consent and rerun to read basic profiles. Object IDs retained.'}else{'Returned user memberships include usernames.'})
        foreach ($g in $audit.directoryGroups) { Coverage ('Directory group '+$g.id+' '+$g.relationship) $g.state $g.reason }
    } else { Coverage 'Directory membership' 'notRequested' 'Expansion disabled or no non-owner directory group principals found in observed grants/members.' }
} catch { Coverage $stage (Get-CanopyFailureState $_) ('Stage failed. Exception type: '+$_.Exception.GetType().FullName+'. Completed evidence retained; credentials and raw error bodies excluded.') }
finally {
    if ($connection) { try { Disconnect-PnPOnline; Coverage 'Disconnect' 'observed' 'PnP connection disconnected; no PersistLogin option was used. Browser/OS state can remain.' } catch { Coverage 'Disconnect' 'failed' 'Disconnect failed; exit the audit process to release session references.' } }
    $connection=$null
    $audit.completedAt=[DateTime]::UtcNow.ToString('o')
    if(!$IncludeFiles){Coverage 'File permissions' 'notRequested' 'File review was not selected.'}
    Coverage 'Sharing link details' 'notRequested' 'Sharing-link URLs, expiry and recipient details are outside this audit. Any sharing principals returned in role assignments are retained without interpreting link reach.'
    Coverage 'File contents' 'notRequested' 'No file contents or versions are opened or downloaded.'
    $audit.state=if(!$audit.resources.Count){'failed'}elseif(@($audit.coverage | Where-Object {$_.state -in @('partial','failed','denied','authenticationRequired','skipped')}).Count){'partial'}else{'completed'}
}
Write-Host "Collected $($audit.resources.Count) resources, $($audit.grants.Count) grants and $($audit.sharePointGroups.Count) SharePoint groups."
if ($ExportPath) {
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($ExportPath),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    $writer=$null
    try {$writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false));$writer.Write(($audit|ConvertTo-Json -Depth 40));$writer.Flush()} finally {if($writer){$writer.Dispose()};$stream.Dispose()}
    Write-Host 'Explicit JSON export completed.'
}
[pscustomobject]$audit
