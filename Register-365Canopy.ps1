[CmdletBinding()]
param([Parameter(Mandatory)][guid]$TenantId, [switch]$DeviceCode)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$name='365Canopy Development'
$manifest=Join-Path $PSScriptRoot 'work/modules/Microsoft.Graph.Authentication/2.40.0/Microsoft.Graph.Authentication.psd1'
Import-Module $manifest
$configPath=Join-Path $PSScriptRoot 'work/canopy-registration.json'
Write-Host 'Registering/reusing 365Canopy Development: single tenant, localhost public client, no secret or certificate.'
Write-Host 'Runtime delegated permissions: SharePoint AllSites.Read; Graph GroupMember.Read.All and User.Read.'
Write-Host 'Bootstrap sign-in requests Application.ReadWrite.All to create and verify the approved registration. Runtime audits do not request this scope.'
try {
    $login=@{ TenantId=$TenantId.ToString(); Scopes=@('Application.ReadWrite.All'); ContextScope='Process'; NoWelcome=$true }
    if ($DeviceCode) { $login.UseDeviceCode=$true }
    Connect-MgGraph @login | Out-Null
    $context=Get-MgContext
    if ($context.TenantId -ne $TenantId.ToString() -or $context.AuthType -ne 'Delegated' -or $context.ContextScope -ne 'Process') { throw 'Bootstrap tenant or authentication mode mismatch.' }
    function Read-Graph([string]$Path) { Invoke-MgGraphRequest -Method GET -Uri ('https://graph.microsoft.com/v1.0/'+$Path) -OutputType Hashtable }
    $graphApp='00000003-0000-0000-c000-000000000000'
    $spoApp='00000003-0000-0ff1-ce00-000000000000'
    $graph=(Read-Graph ('servicePrincipals?$filter='+[uri]::EscapeDataString("appId eq '$graphApp'"))).value
    $spo=(Read-Graph ('servicePrincipals?$filter='+[uri]::EscapeDataString("appId eq '$spoApp'"))).value
    if (@($graph).Count -ne 1 -or @($spo).Count -ne 1) { throw 'Expected Microsoft resource service principals not found uniquely.' }
    function Scope-Id($Resource,[string]$Value) {
        $scopes=@($Resource.oauth2PermissionScopes | Where-Object { $_.value -eq $Value -and $_.isEnabled })
        if ($scopes.Count -ne 1) { throw "Required delegated scope $Value not found uniquely." }
        $scopes[0].id
    }
    $access=@(
        @{resourceAppId=$spoApp;resourceAccess=@(@{id=(Scope-Id $spo[0] 'AllSites.Read');type='Scope'})},
        @{resourceAppId=$graphApp;resourceAccess=@(@{id=(Scope-Id $graph[0] 'GroupMember.Read.All');type='Scope'},@{id=(Scope-Id $graph[0] 'User.Read');type='Scope'})}
    )
    $body=@{displayName=$name;description='365Canopy delegated development checkpoint. Read-only collector; no application credentials.';signInAudience='AzureADMyOrg';isFallbackPublicClient=$true;publicClient=@{redirectUris=@('http://localhost')};requiredResourceAccess=$access}
    $existing=@((Read-Graph ('applications?$filter='+[uri]::EscapeDataString("displayName eq '$name'"))).value)
    if ($existing.Count -gt 1) { throw 'Multiple registrations with this name exist; refusing to select or alter one.' }
    if ($existing.Count -eq 1) {
        $app=$existing[0]
        if ($app.signInAudience -ne 'AzureADMyOrg' -or !$app.isFallbackPublicClient -or @($app.passwordCredentials).Count -or @($app.keyCredentials).Count -or @($app.publicClient.redirectUris).Count -ne 1 -or $app.publicClient.redirectUris[0] -ne 'http://localhost') { throw 'Existing app does not match the secretless single-tenant public-client configuration. It was not modified.' }
        $actual=@($app.requiredResourceAccess | ForEach-Object { $resource=$_.resourceAppId; $_.resourceAccess | ForEach-Object { "$resource/$($_.id)/$($_.type)" } } | Sort-Object)
        $expected=@($access | ForEach-Object { $resource=$_.resourceAppId; $_.resourceAccess | ForEach-Object { "$resource/$($_.id)/$($_.type)" } } | Sort-Object)
        if (($actual -join ',') -ne ($expected -join ',')) { throw 'Existing registration permissions differ; refusing to broaden or replace them.' }
        Write-Host 'Reusing the matching existing registration.'
    } else {
        # No retry of this mutation: rerun resolves unknown outcomes by the unique display name.
        $app=Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/applications' -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -OutputType Hashtable
        Write-Host 'Development application registration created.'
    }
    # Save only identifiers before creating the enterprise application, so failures are recoverable.
    $config=@{tenantId=$TenantId.ToString();clientId=$app.appId;applicationObjectId=$app.id;displayName=$name;sharePointScope='AllSites.Read';graphScopes=@('GroupMember.Read.All','User.Read');createdOrVerifiedAt=[DateTime]::UtcNow.ToString('o')}
    $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding utf8
    $principals=@((Read-Graph ('servicePrincipals?$filter='+[uri]::EscapeDataString("appId eq '$($app.appId)'"))).value)
    if ($principals.Count -gt 1) { throw 'Unexpected duplicate enterprise applications.' }
    if (!$principals.Count) { $sp=Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' -Body (@{appId=$app.appId} | ConvertTo-Json) -ContentType 'application/json' -OutputType Hashtable; $config.servicePrincipalObjectId=$sp.id }
    else { $config.servicePrincipalObjectId=$principals[0].id }
    $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding utf8
    Write-Host 'Registration identifiers saved under ignored work/canopy-registration.json. Microsoft will request runtime consent during audit sign-in.'
} finally { if (Get-MgContext) { Disconnect-MgGraph | Out-Null } }
