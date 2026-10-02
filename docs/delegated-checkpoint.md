# Delegated administrator audit

365Canopy uses a tenant-specific native public-client registration and interactive administrator sign-in through Microsoft. There is no client secret, certificate or app-only credential. Operators supply their own site URL, tenant ID, client ID and document library. Connection fields start blank.

## Registration and consent

Configure a single-tenant registration with native redirect `http://localhost`. Tested delegated permissions are SharePoint `AllSites.FullControl`, Graph `GroupMember.Read.All` and `User.Read`; add `User.ReadBasic.All` for other users' basic names and usernames. The test registration also consented `AllSites.Read`.

Read-only SharePoint consent enabled metadata and inheritance but denied role-assignment enumeration during testing. Delegated Full Control enabled these reads. This is write-capable authority; the audit collector performs read operations. Consent and site access require tenant administrator review. The collector does not grant consent, elevate access, change permissions or create fixtures.

`Register-365Canopy.ps1` is a separate development bootstrap using Graph `Application.ReadWrite.All` to create/verify a secretless registration with initial read scopes. It refuses to silently broaden a mismatched existing registration. Identifiers are stored in ignored `work/canopy-registration.json`. Registration is separate from runtime audits.

## Run an audit

Use the packaged desktop app or PowerShell 7 and the configured PnP module:

```powershell
./Start-365Canopy.ps1 -Check
$registration = Get-Content ./work/canopy-registration.json -Raw | ConvertFrom-Json
$audit = ./Start-365Canopy.ps1 -SiteUrl 'https://TENANT.sharepoint.com/sites/TEST' -TenantId $registration.tenantId -ClientId $registration.clientId -LibraryName 'Documents' -IncludeFiles -IncludeDirectoryMembership -ExportPath './work/delegated-audit.json'
```

File review is opt-in. `-IncludeFiles` implies recursive folders. Without it, `-RecursiveFolders` reviews folders only. Single-folder targets cannot be combined with recursion.

Microsoft handles credentials and MFA. PnP runs without `PersistLogin`. MSAL-issued token claims are checked for tenant, client, resource audience, expiry and delegated scopes. Graph and SharePoint account IDs must agree. Tokens are never exported; unverifiable tokens fail closed. This claim binding is not a standalone JWT signature validator.

## Evidence and limits

Web, library, folder and file resources preserve inheritance flags and permission source IDs. Unique resources retain their observed role assignments, including custom roles and Limited Access. Returned evidence survives failures. Unreadable metadata is unknown; missing ancestors do not imply library inheritance.

Classic SharePoint members are expanded. Entra member and owner queries remain separate, with bounded, cycle-safe traversal. Limited identity information retains object IDs and explicit gaps. Hidden membership and Graph v1.0 omissions remain limitations.

File contents, versions and sharing-link details are not collected. Sharing principals returned by assignments are retained without asserting link reach. Discovery limits, failures and inaccessible items produce coverage gaps. Observed permissions do not establish complete policy-aware effective access.

## Privacy and publication

Results remain in memory until explicit export. Audit reports, registration identifiers, logs and screenshots must remain private. Private working directories and generated packages are ignored by Git; do not force-add them. Source examples use placeholders or synthetic identities. Tenant-specific data must not be embedded in source, documentation or packaged defaults.

## Validation

Development validation covered web/library/folder grants, inheritance, classic and Entra membership, username resolution, identity binding and disconnect. File review has synthetic traversal/report validation; live file validation is pending sign-in. Clean-machine installation and publisher signing remain release gates.

Offline checks cover token binding, unknown inheritance, partial evidence, endpoints, group cycles, exports and mutation-method guards. CSOM reads can use HTTP POST transport; a POST alone does not indicate a write. Read-only code guards do not remove token authority or prevent service access/sign-in logging.

## References

- [PnP interactive sign-in](https://pnp.github.io/powershell/cmdlets/Connect-PnPOnline.html)
- [PnP property loading](https://pnp.github.io/powershell/cmdlets/Get-PnPProperty.html)
- [PnP group members](https://pnp.github.io/powershell/cmdlets/Get-PnPGroupMember.html)
- [PnP token retrieval](https://pnp.github.io/powershell/cmdlets/Get-PnPAccessToken.html)
