# Synthetic provider for isolated helper contract checks. Never contacts a tenant.
function Connect-SPOService { param([string]$Url,[bool]$UseSystemBrowser) }
function Disconnect-SPOService {}
function Get-SPOSite { param([string]$Identity) [pscustomobject]@{Url=$Identity;Title='Synthetic';Template='STS#3';GroupId=[guid]::Empty;Status='Active'} }
function Get-SPOSiteGroup {
    param([string]$Site,[int]$Limit)
    if ($Site.EndsWith('/denied')) { throw [UnauthorizedAccessException]::new('Access denied. Synthetic private service detail must not escape.') }
    [pscustomobject]@{Id=1;Title='Synthetic members';Roles=@('Edit')}
}
function Get-SPOUser {
    param([string]$Site,[string]$Group,[string]$Limit)
    [pscustomobject]@{LoginName='c:0t.c|tenant|11111111-1111-1111-1111-111111111111';DisplayName='Synthetic directory group';IsSiteAdmin=$false}
}
Export-ModuleMember -Function Connect-SPOService,Disconnect-SPOService,Get-SPOSite,Get-SPOSiteGroup,Get-SPOUser
