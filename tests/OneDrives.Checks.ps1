$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $root ('work/onedrive-check-'+[guid]::NewGuid().ToString('N')+'.psm1')
New-Item -Path (Split-Path $fixture) -ItemType Directory -Force | Out-Null
@'
function Connect-PnPOnline {
    param($Url,$Tenant,$ClientId,[switch]$Interactive,[switch]$ReturnConnection,$Connection)
    if ($Url -match '/personal/' -and $Url -notmatch '/personal/alpha$' -and !$Connection) {throw 'Missing same-host session reuse'}
    [pscustomobject]@{Url=$Url;Tenant=$Tenant;ClientId=$ClientId}
}
function Get-PnPAccessToken {
    param($ResourceTypeName,$Connection)
    $oid=if($Connection.Url.EndsWith('/wrong')){'wrong'}else{'expected'}
    $json=@{tid=$Connection.Tenant;appid=$Connection.ClientId;aud='00000003-0000-0ff1-ce00-000000000000';scp='AllSites.FullControl';oid=$oid;exp=[DateTimeOffset]::UtcNow.AddMinutes(5).ToUnixTimeSeconds()} | ConvertTo-Json -Compress
    'fixture.'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=')+'.fixture'
}
function Get-PnPTenantSite {
    param([switch]$IncludeOneDriveSites,$Filter,$Connection)
    if(!$IncludeOneDriveSites -or !$Connection.Url.Contains('-admin.')){throw 'Missing discovery options'}
    foreach($name in @('alpha','alpha','bravo','denied','wrong')){[pscustomobject]@{Url="https://contoso-my.sharepoint.com/personal/$name"}}
    [pscustomobject]@{Url='https://fabrikam-my.sharepoint.com/personal/other'}
}
function Get-PnPWeb {
    param($Includes,$Connection)
    if($Connection.Url.EndsWith('/denied')){throw 'Fixture denies access'}
    if($Connection.Url.EndsWith('/wrong')){throw 'Unexpected account must be blocked before read'}
    [pscustomobject]@{
        Id='same-web';Title='OneDrive';Url=$Connection.Url;HasUniqueRoleAssignments=$true
        CurrentUser=[pscustomobject]@{Email='admin@example.test';LoginName='admin@example.test'}
        RoleAssignments=@([pscustomobject]@{Member=[pscustomobject]@{Id=3;Title='Members';LoginName='Members';PrincipalType='SharePointGroup'};RoleDefinitionBindings=@([pscustomobject]@{Id=1;Name='Read';RoleTypeKind='Reader'})})
    }
}
function Get-PnPProperty {param($ClientObject,$Property,$Connection)}
function Get-PnPList {
    param($Identity,$Includes,$Connection)
    if($Identity -ne 'Documents'){throw 'Incorrect OneDrive library'}
    [pscustomobject]@{Id='same-list';Title='Documents';BaseType='DocumentLibrary';HasUniqueRoleAssignments=$false;RootFolder=[pscustomobject]@{ServerRelativeUrl=([uri]$Connection.Url).AbsolutePath+'/Documents'};ItemCount=0}
}
function Get-PnPListItem {param($List,$Query,$PageSize,$Connection)}
function Get-PnPGroupMember {param($Group,$Connection);[pscustomobject]@{Id=11;Title=([uri]$Connection.Url).Segments[-1];LoginName='member@example.test';PrincipalType='User'}}
'@ | Set-Content -LiteralPath $fixture -Encoding utf8
try {
    $tenant=[guid]::NewGuid();$client=[guid]::NewGuid()
    $line=& (Join-Path $root 'src/Canopy.Checkpoint/Desktop-Audit.ps1') -SiteUrl 'https://contoso.sharepoint.com' -TenantId $tenant -ClientId $client -AllOneDrives -PnPModulePath $fixture
    if($line -isnot [string] -or !$line.StartsWith('CANOPY:')){throw 'Invalid desktop protocol.'}
    $audit=$line.Substring(7) | ConvertFrom-Json
    if($audit.scope.discovered -ne 4 -or $audit.scope.attempted -ne 4 -or $audit.scope.completed -ne 2 -or $audit.state -ne 'partial'){throw 'Unexpected batch coverage or drive counts.'}
    if($audit.resources.Count -ne 5 -or @($audit.resources.id | Sort-Object -Unique).Count -ne 5){throw 'Resources were lost or IDs collided.'}
    if($audit.grants.Count -ne 2 -or $audit.sharePointGroups.Count -ne 2 -or $audit.grants[0].principal.id -eq $audit.grants[1].principal.id){throw 'Site-local group IDs collided.'}
    foreach($library in $audit.resources | Where-Object type -eq 'library'){
        if($library.parentResourceId -ne $library.sourceResourceId -or $library.parentResourceId -notin $audit.resources.id){throw 'Library parent/source was lost.'}
    }
    if(!($audit.coverage | Where-Object {$_.operation -eq 'Other OneDrive hosts' -and $_.state -eq 'skipped'})){throw 'Missing excluded host coverage.'}
    if(@($audit.coverage | Where-Object {$_.operation -like 'OneDrive: *' -and $_.state -eq 'failed'}).Count -ne 2){throw 'Expected blocked and wrong-account drives in coverage.'}
    Write-Host 'OneDrive batch synthetic checks passed: discovery, deduplication, same-host reuse, account binding, per-drive isolation, partial results and desktop JSON.'
} finally {
    Remove-Module ([IO.Path]::GetFileNameWithoutExtension($fixture)) -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixture -Force
}
