$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../src/Canopy.Checkpoint/Canopy.Delegated.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../src/Canopy.Checkpoint/Canopy.Core.psm1') -Force
$script:checks=0
function Assert($Condition,[string]$Message) {if(!$Condition){throw "FAILED: $Message"};$script:checks++}
function Reject([scriptblock]$Action,[string]$Message) {$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed $Message}
function Token($Claims) { $json=$Claims|ConvertTo-Json -Compress; $body=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+','-').Replace('/','_'); 'e30.'+$body+'.synthetic-signature' }
$tenant='11111111-1111-1111-1111-111111111111';$client='22222222-2222-2222-2222-222222222222';$audience='00000003-0000-0ff1-ce00-000000000000'
try { throw 'Attempted to perform an unauthorized operation.' } catch { Assert ((Get-CanopyFailureState $_) -eq 'denied') 'Classify SharePoint CSOM permission denial' }
$claims=@{tid=$tenant;appid=$client;aud=$audience;oid='synthetic-account';scp='AllSites.Read';exp=[DateTimeOffset]::UtcNow.AddMinutes(5).ToUnixTimeSeconds()}
$identity=Get-CanopyTokenIdentity (Token $claims) $tenant $client $audience
Assert ($identity.objectId -eq 'synthetic-account' -and $identity.scopes[0] -eq 'AllSites.Read') 'Retain bound identity and delegated scope'
Reject {Get-CanopyTokenIdentity (Token $claims) $client $client $audience} 'Reject wrong tenant'
Reject {Get-CanopyTokenIdentity (Token $claims) $tenant $tenant $audience} 'Reject wrong client'
Reject {Get-CanopyTokenIdentity (Token $claims) $tenant $client 'wrong-resource'} 'Reject cross-resource token'
$appOnly=$claims.Clone();$appOnly.Remove('scp');$appOnly.roles=@('Sites.FullControl.All')
Reject {Get-CanopyTokenIdentity (Token $appOnly) $tenant $client $audience} 'Reject app-only authentication'
$expired=$claims.Clone();$expired.exp=1
Reject {Get-CanopyTokenIdentity (Token $expired) $tenant $client $audience} 'Reject expired token'
Reject {Get-CanopyTokenIdentity 'opaque-private-token' $tenant $client $audience} 'Opaque token fails closed'
$principal=[pscustomobject]@{Id=7;Title='Synthetic group';LoginName='Synthetic members';PrincipalType='SharePointGroup'}
$assignment=[pscustomobject]@{Member=$principal;RoleDefinitionBindings=@([pscustomobject]@{Id=4;Name='Limited Access';RoleTypeKind='Guest'},[pscustomobject]@{Id=9;Name='Custom review';RoleTypeKind='None'})}
$resource=[pscustomobject]@{RoleAssignments=@($assignment)}
$result=Get-CanopyResourceGrants $resource 'web:synthetic' {param($a)}
Assert ($result.grants[0].roles[0].name -eq 'Limited Access' -and $result.grants[0].roles[1].name -eq 'Custom review') 'Preserve custom roles and Limited Access'
Assert ($result.grants[0].resourceId -eq 'web:synthetic' -and $result.grants[0].principal.type -eq 'SharePointGroup') 'Preserve resource-to-principal relationship'
$resource.RoleAssignments=@($assignment,$assignment)
$counter=@{count=0}
$partial=Get-CanopyResourceGrants $resource 'list:synthetic' {param($a) $counter.count++;if($counter.count -eq 2){throw 'private service failure'}}
Assert ($partial.state -eq 'partial' -and $partial.grants.Count -eq 1) 'Preserve prior grants after subsequent failure'
Assert ($partial.reason -notmatch 'private service failure') 'Do not export raw service errors'
$serialized=$partial|ConvertTo-Json -Depth 20
Assert ($serialized -notmatch 'synthetic-signature|opaque-private-token') 'Evidence projection excludes authentication tokens'
Write-Host "$script:checks delegated checks passed. No tenant accessed."
