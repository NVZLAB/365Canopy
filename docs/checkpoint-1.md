# Checkpoint 1 — authentication and coverage spike

This checkpoint is a runnable **partial prototype**, not a complete SharePoint permissions audit. It deliberately tests the no-custom-app boundary before building the WPF interface.

Live validation on 30 September 2026: SharePoint browser authentication, selected-site metadata, three site groups, and their member listings succeeded, followed by successful SharePoint disconnect. An isolated interactive Graph sign-in verified the supplied tenant GUID and delegated authentication; subsequent combined and membership-only attempts failed authentication, so directory membership has **not** passed live validation. No library grants or inheritance have been collected. All 35 synthetic checks pass in both PowerShell 7 and Windows PowerShell 5.1, including helper success/denial, disconnect and sanitized errors. Private live evidence is kept only under ignored `work/`.

## Run

Use PowerShell 7 on Windows. Modules live only under ignored `work/modules`; the SPO collector runs in a fresh Windows PowerShell 5.1 process. Setup downloads Microsoft modules from PowerShell Gallery; it does not install them globally.

Pinned module versions: SharePoint 16.0.27709.12000; Graph Authentication 2.40.0.

```powershell
./Setup-Checkpoint.ps1
./Start-365Canopy.ps1 -Check
$audit = ./Start-365Canopy.ps1 -SiteUrl 'https://TENANT.sharepoint.com/sites/TEST' -LibraryName 'Documents'
# Optional second Microsoft sign-in/consent for group membership:
$audit = ./Start-365Canopy.ps1 -SiteUrl 'https://TENANT.sharepoint.com/sites/TEST' -TenantId 'TENANT-GUID' -LibraryName 'Documents' -IncludeDirectoryMembership
# Save only when explicitly requested; filename must not already exist:
$audit = ./Start-365Canopy.ps1 -SiteUrl 'https://TENANT.sharepoint.com/sites/TEST' -TenantId 'TENANT-GUID' -IncludeDirectoryMembership -ExportPath './test-audit.json'
```

Sign in to Microsoft with the test tenant administrator in each sign-in window. Use the same account for SharePoint and Graph. Do not enter passwords or MFA codes into this script or chat. Graph requests delegated `GroupMember.Read.All` using Microsoft's module public client and a process-scoped context. Existing Microsoft clients still involve consent/service principals and Microsoft audit records.

Run this from an interactive PowerShell terminal. In local validation, Graph WAM sign-in failed from a plain redirected process and succeeded with an interactive terminal. The native desktop integration must supply a working interactive authentication host rather than depending on a background process.

LibraryName records the desired test target only. The collector does not read that library, grants or inheritance yet; the snapshot explicitly marks those unsupported. Only commercial `*.sharepoint.com` site collection roots are accepted; sovereign clouds, multi-geo and OneDrive are excluded from this spike.

The SPO module exposes no supported account-context query used here. Its sign-in is bound to the requested admin URL and returned site URL; the account and tenant GUID remain independently unverified. Graph's tenant GUID/delegated/process context is checked separately. Do not interpret these as a proven shared-account/shared-tenant session.

## Capability matrix

| Operation | Prototype route | Evidence boundary |
| --- | --- | --- |
| MFA-capable SharePoint sign-in | Connect-SPOService, system browser | Live test passed; no custom app credentials |
| Requested site metadata | Get-SPOSite -Identity | Inventory only; not content access |
| SharePoint groups and group roles | Get-SPOSiteGroup | Bounded to 5000; reported roles lack verified resource scope |
| SharePoint group members | Get-SPOUser -Group -Limit All | Requires site collection admin access; failure remains unknown |
| Nested Entra membership | Graph v1.0 group metadata and direct members | Recognized claims and associated site group IDs only; preserved edges; hidden members not requested |
| Site/library role assignments and inheritance | No supported no-custom-app route established | Unsupported; no inferred grants |
| Sharing links, folders, items | Not collected | Outside spike |
| Account and tenant binding across both providers | Graph context plus SPO target checks | Incomplete; blocking the full checkpoint acceptance |

Graph's drive-item sharing-permissions API is a possible future limited provider, but Microsoft states that non-owner callers receive only sharing permissions applicable to themselves. It must not be presented as an exhaustive SharePoint library role-assignment audit. No additional file/site consent scopes were requested in this spike.

Membership expansion preserves immediate edges, handles cycles, follows bounded validated pagination and retains prior pages on failure. API throttling retries are bounded. Graph v1.0 has a documented omission for service principals, and inaccessible identity fields can be null; an observed page listing is not certified complete membership. Dynamic membership is a time-bound observation. Recognized Microsoft 365 owner claims map to the underlying group membership but **do not establish an owners-only grant path**; this remains inventory, not access evidence.

No tenant write cmdlets, cookie extraction, private module-session reflection, app-registration creation, credential export or site-administrator elevation are used. Disconnect is attempted in finally blocks; the SPO helper exits after returning evidence. Browser/OS sign-in state and module-managed state may remain; no claim is made that Microsoft module cache behavior is entirely memory-only.

The prototype returns the snapshot to the local PowerShell session; it writes nothing automatically. Explicit JSON export refuses to overwrite an existing file. Exports contain tenant identifiers and memberships and should be kept private. No production UI, portable packaging, cancellation/resume workflow or schema import is included yet. Ctrl+C ends the prototype; completed results are retained for handled failures, but abrupt process termination can lose in-memory results.

## Live test and acceptance

1. Confirm the supplied URL is a site collection root and the administrator already has site collection access. The prototype will not grant access.
2. Complete SharePoint sign-in; inspect `$audit.sharePoint.coverage` for site/group outcomes.
3. If an Entra group is in a SharePoint group, enable directory expansion; inspect `$audit.directoryGroups` and compare direct/nested membership in Microsoft administration UI.
4. Test an inaccessible site separately. A denial must not produce a complete empty permission list.
5. Explicitly export JSON and confirm it contains partial/unsupported states and no credentials.
6. Resolve the missing supported library-grant collector and shared-session binding before calling the original one-site permissions checkpoint complete. If the no-custom-app constraint prevents this, report the tested capability boundary and agree on the next scope; do not substitute undocumented token reuse.

## Sources

- [Connect-SPOService](https://learn.microsoft.com/en-us/powershell/module/microsoft.online.sharepoint.powershell/connect-sposervice?view=sharepoint-ps)
- [Get-SPOSiteGroup](https://learn.microsoft.com/en-us/powershell/module/microsoft.online.sharepoint.powershell/get-spositegroup?view=sharepoint-ps)
- [Get-SPOUser](https://learn.microsoft.com/en-us/powershell/module/microsoft.online.sharepoint.powershell/get-spouser?view=sharepoint-ps)
- [Graph group members and limitations](https://learn.microsoft.com/en-us/graph/api/group-list-members?view=graph-rest-1.0)
- [Graph drive-item sharing-permissions visibility](https://learn.microsoft.com/en-us/graph/api/driveitem-list-permissions?view=graph-rest-1.0)
- [PnP authentication requires an app registration](https://pnp.github.io/powershell/articles/authentication.html)
