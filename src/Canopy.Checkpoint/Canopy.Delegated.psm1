Set-StrictMode -Version Latest
function Get-CanopyTokenIdentity {
    param([Parameter(Mandatory)][string]$Token,[Parameter(Mandatory)][string]$TenantId,[Parameter(Mandatory)][string]$ClientId,[Parameter(Mandatory)][string[]]$Audience)
    # Tokens come from MSAL via the documented PnP command; this is claim binding, not a standalone JWT signature validator.
    try {
        $parts=$Token.Split('.')
        if ($parts.Count -ne 3) { throw 'Opaque token' }
        $encoded=$parts[1].Replace('-','+').Replace('_','/')
        $encoded=$encoded.PadRight($encoded.Length+(4-$encoded.Length%4)%4,'=')
        $claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json -AsHashtable
        $app=if ($claims.ContainsKey('azp')) { $claims['azp'] } else { $claims['appid'] }
        if ($claims['tid'] -ne $TenantId -or $app -ne $ClientId -or $claims['aud'] -notin $Audience -or !$claims['scp'] -or !$claims['oid'] -or [long]$claims['exp'] -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { throw 'Binding mismatch' }
        [pscustomobject]@{tenantId=$claims['tid'];objectId=$claims['oid'];clientId=$app;scopes=([string]$claims['scp']).Split(' ')}
    } catch { throw 'Unable to verify delegated token tenant, client, audience, expiry and account binding.' }
    finally { $Token=$null; $claims=$null }
}

function ConvertTo-CanopyPrincipal {
    param($Principal)
    [pscustomobject]@{id=[string]$Principal.Id;title=[string]$Principal.Title;loginName=[string]$Principal.LoginName;type=[string]$Principal.PrincipalType}
}

function Get-CanopyResourceGrants {
    param($Resource,[string]$ResourceId,[scriptblock]$LoadAssignment)
    $grants=[Collections.Generic.List[object]]::new()
    $state='observed';$reason='Role assignments collected; these are observed grants, not policy-aware effective access.'
    try {
        foreach ($assignment in $Resource.RoleAssignments) {
            & $LoadAssignment $assignment | Out-Null
            $roles=@($assignment.RoleDefinitionBindings | ForEach-Object { [pscustomobject]@{id=[string]$_.Id;name=[string]$_.Name;kind=[string]$_.RoleTypeKind} })
            $grants.Add([pscustomobject]@{resourceId=$ResourceId;principal=(ConvertTo-CanopyPrincipal $assignment.Member);roles=$roles;source='SharePoint CSOM RoleAssignments';collectedAt=[DateTime]::UtcNow.ToString('o')})
        }
    } catch { $state=if ($grants.Count) {'partial'} else {'failed'}; $reason='Role-assignment collection failed. Completed grants retained; remaining grants unknown.' }
    [pscustomobject]@{state=$state;reason=$reason;grants=$grants.ToArray()}
}
Export-ModuleMember -Function Get-CanopyTokenIdentity,ConvertTo-CanopyPrincipal,Get-CanopyResourceGrants
