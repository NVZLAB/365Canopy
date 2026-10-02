Set-StrictMode -Version Latest

function Resolve-CanopyTarget {
    param([Parameter(Mandatory)][string]$SiteUrl, [string]$AdminUrl)
    $site = $null
    if (![uri]::TryCreate($SiteUrl, [UriKind]::Absolute, [ref]$site) -or $site.Scheme -ne 'https' -or $site.Port -ne 443 -or $site.UserInfo -or $site.Query -or $site.Fragment -or $site.Host -notmatch '^[a-z0-9][a-z0-9-]*\.sharepoint\.com$' -or $site.Host -match '-(admin|my)\.sharepoint\.com$') { throw 'Use an HTTPS commercial-cloud SharePoint site collection URL without a query or fragment.' }
    if ($site.AbsolutePath.TrimEnd('/') -ne '' -and $site.AbsolutePath -notmatch '^/(sites|teams)/[^/]+/?$') { throw 'Provide the site collection root, not a library, item or subsite URL.' }
    $expected = 'https://' + $site.Host.Replace('.sharepoint.com', '-admin.sharepoint.com')
    if ($AdminUrl -and $AdminUrl.TrimEnd('/') -ne $expected) { throw 'Admin URL must match the selected site host. Multi-geo and sovereign clouds are outside this spike.' }
    [pscustomobject]@{ SiteUrl = $site.AbsoluteUri.TrimEnd('/'); AdminUrl = $expected }
}

function Get-CanopyFailureState {
    param($ErrorRecord)
    $code = 0
    try { $code = [int]$ErrorRecord.Exception.Response.StatusCode } catch {}
    if ($code -eq 403) { return 'denied' }
    if ($code -eq 401) { return 'authenticationRequired' }
    # SPO cmdlets do not consistently expose HTTP status. Classify only recognizable denial.
    if ([string]$ErrorRecord.Exception.Message -match '(?i)access (is )?denied|unauthorizedaccess|unauthorized operation') { return 'denied' }
    'failed'
}

function Get-CanopyDirectoryGroupId {
    param([string]$LoginName)
    # Recognized Entra group claims only; do not treat arbitrary user GUIDs as groups.
    if ($LoginName -match '^(?:c:0t\.c\|tenant\||c:0o\.c\|federateddirectoryclaimprovider\|)([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})(?:_o)?$') { return $Matches[1].ToLowerInvariant() }
    $null
}

function Invoke-CanopyGraphRead {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][scriptblock]$Request)
    $parsed = [uri]$Uri
    if ($parsed.Scheme -ne 'https' -or $parsed.Host -ne 'graph.microsoft.com' -or $parsed.Port -ne 443 -or $parsed.UserInfo -or $parsed.Fragment -or $parsed.AbsolutePath -notmatch '^/v1\.0/(?:groups/[0-9a-fA-F-]{36}(?:/(?:members|owners))?|users/[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$') { throw 'Graph endpoint is outside the checkpoint read allowlist.' }
    # Bounded retries; retain page results outside this function on later failure.
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try { return (& $Request $Uri) } catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            if ($code -notin @(429,503,504) -or $attempt -eq 2) { throw }
            $delay = [math]::Pow(2, $attempt + 1)
            try { $hint = [int]$_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds; if ($hint -gt 0) { $delay = [math]::Min(30, $hint) } } catch {}
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-CanopyDirectoryMembership {
    param([string[]]$GroupIds, [Parameter(Mandatory)][scriptblock]$Request, [int]$MaxGroups = 200, [int]$MaxPages = 100, [ValidateSet('members','owners')][string]$Relationship='members')
    $pending = [Collections.Generic.Queue[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $groups = [Collections.Generic.List[object]]::new()
    foreach ($id in $GroupIds) { if ($id -match '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { $pending.Enqueue($id) } else { throw 'Invalid directory group ID.' } }
    while ($pending.Count -gt 0) {
        $id = $pending.Dequeue()
        if (!$seen.Add($id)) { continue }
        $members = [Collections.Generic.List[object]]::new()
        $entry = [ordered]@{ id=$id; relationship=$Relationship; state='partial'; reason=''; collectedAt=[DateTime]::UtcNow.ToString('o'); members=$members }
        if ($groups.Count -ge $MaxGroups) { $entry.state='skipped'; $entry.reason='Group expansion budget reached.'; $groups.Add([pscustomobject]$entry); continue }
        try {
            $metadata = Invoke-CanopyGraphRead -Uri ('https://graph.microsoft.com/v1.0/groups/' + $id + '?$select=id,displayName,visibility') -Request $Request
            if ([string]$metadata.id -ne $id) { throw 'Group identity mismatch.' }
            $entry.displayName = $metadata.displayName
            if ($Relationship -eq 'members' -and $metadata.visibility -eq 'HiddenMembership') { $entry.reason='Hidden membership not requested; members remain unknown.'; $groups.Add([pscustomobject]$entry); continue }
            $next = 'https://graph.microsoft.com/v1.0/groups/' + $id + '/'+$Relationship+'?$select=id,displayName,userPrincipalName,userType&$top=999'
            $pages = [Collections.Generic.HashSet[string]]::new()
            while ($next) {
                if ($pages.Count -ge $MaxPages -or !$pages.Add($next)) { throw 'Pagination budget or repeated page detected.' }
                # A nextLink must remain on this group's members collection.
                $nextUri = [uri]$next
                if ($nextUri.AbsolutePath -ne "/v1.0/groups/$id/$Relationship") { throw 'Unexpected pagination target.' }
                $page = Invoke-CanopyGraphRead -Uri $next -Request $Request
                if (!$page.Contains('value')) { throw 'Missing membership page.' }
                foreach ($member in @($page.value)) {
                    $members.Add([pscustomobject]@{ id=$member['id']; type=$member['@odata.type']; displayName=$member['displayName']; userPrincipalName=$member['userPrincipalName']; userType=$member['userType']; sourceGroupId=$id })
                    if ($Relationship -eq 'members' -and $member['@odata.type'] -eq '#microsoft.graph.group') { $pending.Enqueue([string]$member.id) }
                }
                $next = [string]$page['@odata.nextLink']
            }
            $entry.state='observed'; $entry.reason="Returned direct $Relationship pages collected. Graph v1.0 can omit service principals; limited identity fields can be null. Not a complete effective-access claim."
        } catch { $entry.state = if ($members.Count) { 'partial' } else { Get-CanopyFailureState $_ }; $entry.reason='Membership collection did not complete. Returned members, if any, are retained; remaining members are unknown.' }
        $groups.Add([pscustomobject]$entry)
    }
    $groups.ToArray()
}

function Resolve-CanopyMemberIdentity {
    param([object[]]$Groups, [Parameter(Mandatory)][scriptblock]$Request, [int]$MaxUsers=1000)
    $cache=@{}
    foreach($group in $Groups) {
        foreach($member in $group.members) {
            if($member.type -ne '#microsoft.graph.user') { continue }
            $id=[string]$member.id
            if($member.displayName -and $member.userPrincipalName) { continue }
            if(!$cache.ContainsKey($id)) {
                $result=@{state='unresolved';reason='Basic profile unavailable. Graph delegated User.ReadBasic.All may be required.';profile=$null}
                if($cache.Count -ge $MaxUsers) { $result.reason='User lookup limit reached.' }
                else {
                    try {
                        $profile=Invoke-CanopyGraphRead -Uri ('https://graph.microsoft.com/v1.0/users/'+$id+'?$select=id,displayName,userPrincipalName,mail') -Request $Request
                        if([string]$profile.id -ne $id) { throw 'User identity mismatch.' }
                        if($profile['userPrincipalName']) { $result=@{state='resolved';reason='Basic profile read by object ID.';profile=$profile} }
                    } catch { $result.state=Get-CanopyFailureState $_ }
                }
                $cache[$id]=$result
            }
            $result=$cache[$id]
            if($result.profile) {
                $member.displayName=$result.profile['displayName'];$member.userPrincipalName=$result.profile['userPrincipalName']
                $member | Add-Member -NotePropertyName mail -NotePropertyValue $result.profile['mail'] -Force
            }
            $member | Add-Member -NotePropertyName identityResolution -NotePropertyValue $result.state -Force
            $member | Add-Member -NotePropertyName identityReason -NotePropertyValue $result.reason -Force
        }
    }
}

Export-ModuleMember -Function Resolve-CanopyTarget,Get-CanopyFailureState,Get-CanopyDirectoryGroupId,Invoke-CanopyGraphRead,Get-CanopyDirectoryMembership,Resolve-CanopyMemberIdentity
