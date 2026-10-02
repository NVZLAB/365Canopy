$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../src/Canopy.Checkpoint/Canopy.Core.psm1') -Force
$script:checks=0
function Assert($condition, $message) { if (!$condition) { throw "FAILED: $message" }; $script:checks++ }
function Assert-Reject([scriptblock]$action, $message) { $rejected=$false; try { & $action | Out-Null } catch { $rejected=$true }; Assert $rejected $message }
$target=Resolve-CanopyTarget 'https://fabrikam.sharepoint.com/sites/test/'
Assert ($target.AdminUrl -eq 'https://fabrikam-admin.sharepoint.com' -and $target.SiteUrl -eq 'https://fabrikam.sharepoint.com/sites/test') 'Canonical site/admin binding'
foreach ($url in @('http://fabrikam.sharepoint.com','https://fabrikam.sharepoint.com.evil.example/sites/test','https://user@fabrikam.sharepoint.com/sites/test','https://fabrikam.sharepoint.com/sites/test?token=x','https://fabrikam-my.sharepoint.com','https://fabrikam.sharepoint.com/sites/test/Documents','https://fabrikam.sharepoint.com:444/sites/test')) { Assert-Reject { Resolve-CanopyTarget $url } "Reject unsafe/out-of-scope URL $url" }
Assert-Reject { Resolve-CanopyTarget 'https://fabrikam.sharepoint.com/sites/test' 'https://other-admin.sharepoint.com' } 'Reject mismatched admin host'
$a='11111111-1111-1111-1111-111111111111'; $b='22222222-2222-2222-2222-222222222222'
Assert ((Get-CanopyDirectoryGroupId "c:0t.c|tenant|$a") -eq $a) 'Recognize tenant group claim'
Assert ((Get-CanopyDirectoryGroupId "c:0o.c|federateddirectoryclaimprovider|${a}_o") -eq $a) 'Recognize Microsoft 365 owners claim'
Assert ($null -eq (Get-CanopyDirectoryGroupId "i:0#.f|membership|$a")) 'Do not reinterpret a user as a directory group'
Assert-Reject { Invoke-CanopyGraphRead 'https://evil.example/v1.0/groups/11111111-1111-1111-1111-111111111111/members' { throw 'Must not request' } } 'Reject foreign pagination host'
Assert-Reject { Invoke-CanopyGraphRead "https://graph.microsoft.com/v1.0/users/$a/manager" { throw 'Must not request' } } 'Reject non-allowlisted graph path'
Assert-Reject { Invoke-CanopyGraphRead 'https://graph.microsoft.com/v1.0/users/not-a-guid' { throw 'Must not request' } } 'Reject invalid user ID'
$script:lookups=0
$identityRequest={param($uri) $script:lookups++;@{id=$a;displayName='Test Person';userPrincipalName='person@example.test';mail='person@example.test'}}
$m1=[pscustomobject]@{id=$a;type='#microsoft.graph.user';displayName=$null;userPrincipalName=$null}
$m2=[pscustomobject]@{id=$a;type='#microsoft.graph.user';displayName=$null;userPrincipalName=$null}
Resolve-CanopyMemberIdentity @([pscustomobject]@{members=@($m1,$m2)}) $identityRequest
Assert ($script:lookups -eq 1 -and $m1.userPrincipalName -eq 'person@example.test' -and $m2.identityResolution -eq 'resolved') 'Resolve by ID and reuse cached profile'
$m3=[pscustomobject]@{id=$b;type='#microsoft.graph.user';displayName=$null;userPrincipalName=$null}
Resolve-CanopyMemberIdentity @([pscustomobject]@{members=@($m3)}) {throw 'denied'}
Assert ($m3.id -eq $b -and !$m3.userPrincipalName -and $m3.identityResolution -ne 'resolved') 'Failed lookup preserves identity and marks gap'
$m4=[pscustomobject]@{id=$b;type='#microsoft.graph.user';displayName=$null;userPrincipalName=$null}
Resolve-CanopyMemberIdentity @([pscustomobject]@{members=@($m4)}) $identityRequest
Assert (!$m4.userPrincipalName) 'Mismatched user response never attaches another profile'
$script:requests=0
$request={ param($uri)
    $script:requests++
    if ($uri -notmatch '/members') { return @{id=if($uri.Contains($a)){$a}else{$b}; displayName='Group'; visibility='Private'} }
    if ($uri.Contains($a)) { return @{value=@(@{id=$b; '@odata.type'='#microsoft.graph.group'; displayName='Nested'}); '@odata.nextLink'=$null} }
    return @{value=@(@{id=$a; '@odata.type'='#microsoft.graph.group'; displayName='Cycle'},@{id='user-id'; '@odata.type'='#microsoft.graph.user'}); '@odata.nextLink'=$null}
}
$groups=@(Get-CanopyDirectoryMembership @($a) $request)
Assert ($groups.Count -eq 2 -and $script:requests -eq 4) 'Nested cycle terminates; each group collected once'
Assert ($groups[1].members.Count -eq 2 -and $groups[1].members[1].displayName -eq $null) 'Preserve partial identity and immediate membership edges'
$hidden=@(Get-CanopyDirectoryMembership @($a) { param($uri) if ($uri.Contains('/members')) { throw 'Hidden members must not be queried' }; @{id=$a;displayName='Hidden';visibility='HiddenMembership'} })
 $owners=@(Get-CanopyDirectoryMembership @($a) -Relationship owners -Request {param($uri)
    if($uri.Contains('/members')){throw 'Owners must not use member endpoint'}
    if($uri.Contains('/owners')){return @{value=@(@{id='owner-id';'@odata.type'='#microsoft.graph.user';displayName=$null});'@odata.nextLink'=$null}}
    @{id=$a;displayName='Owners fixture';visibility='HiddenMembership'}
 })
Assert ($owners.Count -eq 1 -and $owners[0].relationship -eq 'owners' -and $owners[0].members[0].id -eq 'owner-id') 'Owner claim expands owners separately even when membership is hidden'
$ownerRedirect=@(Get-CanopyDirectoryMembership @($a) -Relationship owners -Request {param($uri)
    if($uri.Contains('/owners')){return @{value=@();'@odata.nextLink'="https://graph.microsoft.com/v1.0/groups/$a/members"}}
    @{id=$a;displayName='Redirect';visibility='Private'}
})
Assert ($ownerRedirect[0].state -eq 'failed') 'Reject owner-to-member pagination substitution'
Assert ($hidden[0].state -eq 'partial' -and $hidden[0].reason -match 'unknown') 'Hidden members remain unknown'
$partial=@(Get-CanopyDirectoryMembership @($a) { param($uri)
    if (!$uri.Contains('/members')) { return @{id=$a;displayName='Paged';visibility='Private'} }
    if ($uri.Contains('skiptoken')) { throw 'Second page failed' }
    @{value=@(@{id='user-one';'@odata.type'='#microsoft.graph.user'});'@odata.nextLink'="https://graph.microsoft.com/v1.0/groups/$a/members?`$skiptoken=x"}
})
Assert ($partial[0].state -eq 'partial' -and $partial[0].members.Count -eq 1) 'Retain completed page after later failure'
$foreign=@(Get-CanopyDirectoryMembership @($a) { param($uri)
    if (!$uri.Contains('/members')) { return @{id=$a;displayName='Paged';visibility='Private'} }
    @{value=@();'@odata.nextLink'="https://graph.microsoft.com/v1.0/groups/$b/members"}
})
Assert ($foreign[0].state -eq 'failed') 'Reject cross-group nextLink'
$deniedError=[Management.Automation.ErrorRecord]::new([UnauthorizedAccessException]::new('Access denied'),'denied',[Management.Automation.ErrorCategory]::PermissionDenied,$null)
Assert ((Get-CanopyFailureState $deniedError) -eq 'denied') 'Distinguish access denial'
$failedError=[Management.Automation.ErrorRecord]::new([Exception]::new('Network unavailable'),'failed',[Management.Automation.ErrorCategory]::ConnectionError,$null)
Assert ((Get-CanopyFailureState $failedError) -eq 'failed') 'Do not label network errors denied'
$json=$partial | ConvertTo-Json -Depth 40
Assert (($json | ConvertFrom-Json).members[0].id -eq 'user-one') 'JSON evidence preserves completed membership'
# Exercise the actual 5.1 helper protocol with synthetic success and denial providers.
$native=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
$helper=Join-Path $PSScriptRoot '../src/Canopy.Checkpoint/Collect-SharePoint.ps1'
$fake=Join-Path $PSScriptRoot 'fixtures/Synthetic-SPO.psm1'
foreach ($case in @('accessible','denied')) {
    $lines=@(& $native -NoProfile -File $helper -SiteUrl "https://fabrikam.sharepoint.com/sites/$case" -ModuleManifest $fake)
    $payload=@($lines | Where-Object { $_ -like 'CANOPY:*' })
    Assert ($LASTEXITCODE -eq 0 -and $payload.Count -eq 1) "Helper protocol: $case"
    $evidence=$payload[0].Substring(7) | ConvertFrom-Json
    Assert (@($evidence.coverage | Where-Object { $_.operation -eq 'SharePoint disconnect' -and $_.state -eq 'observed' }).Count -eq 1) "Helper disconnect: $case"
    if ($case -eq 'accessible') { Assert ($evidence.groups[0].members[0].directoryGroupId -eq $a) 'Project recognizable directory claim from site group' }
    else {
        Assert ($evidence.groups.Count -eq 0 -and @($evidence.coverage | Where-Object state -eq 'denied').Count -eq 1) 'Denied collection is a coverage gap'
        Assert ($payload[0] -notmatch 'private service detail') 'Raw service errors excluded from helper evidence'
    }
}
# Parse every script using PowerShell's own parser.
Get-ChildItem (Join-Path $PSScriptRoot '..') -Include '*.ps1','*.psm1' -Recurse | Where-Object { $_.FullName -notmatch '[\\/](work|artifacts|bin|obj)[\\/]' } | ForEach-Object {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) ('Syntax: '+$_.Name)
}
Write-Host "$script:checks synthetic checks passed. No tenant accessed."
