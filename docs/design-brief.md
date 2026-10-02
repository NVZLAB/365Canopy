# 365Canopy — design brief

Version 0.1 · 30 September 2026 · proposed design

Development decision, 30 September 2026: the user approved a delegated public-client app registration for full SharePoint permission collection, retaining administrator MFA sign-in and no application credentials. The no-custom-registration statements below describe the original feasibility target, not the revised development route. See [delegated checkpoint](delegated-checkpoint.md) for the current configuration and validation status.

## Purpose

Make SharePoint access understandable: what a resource inherits, who has a grant, who belongs to each granted group, and where evidence is incomplete. Start as a Windows desktop audit tool; leave room for a wider Microsoft 365 overview and a future Lantern investigation module.

Primary users are tenant administrators, consultants and security reviewers. A successful audit lets a reviewer trace a person to a resource through a named grant and membership chain, then export that evidence with its collection scope and limitations.

## Product principles

- Minimum tenant footprint: interactive administrator sign-in, no custom app registration, client secret, certificate or unattended app-only credential in the default workflow.
- Read-only collection: do not grant the signed-in administrator site access, change inheritance, redeem sharing links, or modify membership to complete an audit.
- Evidence before confidence: missing access is a coverage gap, never an empty permission list or proof that a site is safe.
- Local by default: retain audit data in memory until explicit export; no telemetry or hosted collection service.
- Familiar operation: adopt Lantern's portable Windows packaging, fixed read-only PowerShell helpers, delegated session checks, and System/Light/Dark controls.

## Authentication and feasibility gate

The user signs in through Microsoft's browser-based MFA-capable flow with a Global Administrator account. Canopy never collects that account's password. The desired route uses Microsoft's existing public clients through supported Microsoft modules, similar to Lantern's `Connect-MgGraph -ContextScope Process` helper. OAuth still has a client application identity: “no custom app registration” does not mean no enterprise application, consent grant, sign-in log or browser/OS session state.

Use the SharePoint Online Management Shell as the first candidate for tenant/site inventory and Microsoft Graph delegated access for directory membership. Microsoft documents system-browser authentication for `Connect-SPOService`. This does **not** prove that the same route supports exhaustive web/list/item role assignments. Do not assume a Graph token can be reused against SharePoint or that an inventory module is a complete permissions collector.

Before building the collector, spike these capabilities in a test tenant: site discovery; web, library, folder and item role assignments; inheritance; SharePoint group members; Entra group membership; sharing-link metadata; and explicit denial behavior. Verify supported token acquisition for each audience without harvesting browser cookies, impersonating an unrelated client, or relying on undocumented endpoints.

Global and SharePoint administrators do not automatically have content access to every site. Do not call `Set-SPOUser` to add site administrators. Report accessible sites and denied sites separately. Full tenant coverage under an unchanged tenant may be impossible; show that limit plainly.

PnP PowerShell currently requires a tenant app registration for interactive authentication. It is not the default answer to this requirement. If the feasibility spike cannot meet the requirement, return a concrete capability matrix and keep no-custom-app mode limited to what supported APIs permit. A separate optional custom delegated public-client mode would require a future product decision; it is outside this initial design.

Request only justified delegated scopes. Assess `GroupMember.Read.All` for membership; add profile scopes only when needed for names and identity details. Hidden membership requires additional permission and potentially applicable directory roles; keep it optional and mark unresolved groups. Specify the final SharePoint scopes only after the collector spike. Consent requirements and actual user rights must be shown in preflight.

Disconnect ends helper processes and releases in-memory data and references. It cannot promise to remove browser/Windows state, previously granted consent, or Microsoft audit records.

## Initial scope

1. Connect: tenant identifier/admin URL, Microsoft interactive sign-in, verified tenant/account, capability and consent summary.
2. Scope: all discoverable SharePoint sites or selected sites. Exclude OneDrive by default. Choose site/library scan or explicit deep item scan, and show workload before starting.
3. Audit: cancellable scan, pagination, bounded concurrency, server retry guidance, per-source timestamps, partial-result retention and counts of collected/denied/failed/skipped sources.
4. Review: tenant → site → web → list/library → folder → item. Load children on demand from collected evidence. Show inherited versus unique assignments and their source ancestor.
5. Explain access: principal → role definition → membership chain → person. Distinguish SharePoint groups, Entra security groups, Microsoft 365 groups, direct users, guests, broad principals and sharing links.
6. Export: JSON, CSV, XML and standalone HTML from the same collected snapshot.

Anonymous links are link-based access, not named people. Organization links are not evidence that every employee used the link. Preserve Limited Access and custom role names rather than treating them as Full Control or Read. A guest identity alone does not establish current external access. Avoid a universal “effective access” claim: grants are observed paths and may be affected by policy, link constraints, account state and unresolved membership.

Nested groups preserve intermediate chains, deduplicate identities for counts, and detect cycles. Dynamic groups display collected membership at the snapshot time. Deleted principals remain identified by stable IDs. Hidden or unavailable members remain explicit unresolved branches. Never expand a group into a misleading zero-member result after a failed request.

## Information architecture and interaction

Sidebar: Overview, Permissions, Coverage, Exports, Settings. Reserve future modules without presenting nonfunctional Exchange or Lantern navigation in v1.

Permissions is a three-part workspace: resource tree; selected resource and grant list; selected grant's identity/membership details. Search finds collected resources or principals and reports its search boundary. Filters include unique permissions, external principals and unresolved evidence. A visible coverage banner links to failures and scope details.

Use compact readable tables and tree rows, clear breadcrumbs and restrained green accents. Keyboard interaction: arrow-key tree navigation, Enter to select, visible focus and accessible expanded state. Status uses text plus icons, never color alone. Deep scans require an explicit scope choice. Cancel preserves completed evidence; a failed connection cannot show stale data as live.

Theme defaults to System and responds to OS changes. Explicit Light/Dark overrides remain until changed; persist only appearance settings. Native implementation should use Lantern's theme service pattern and Windows high-contrast resources. Mockup uses browser system preference and has responsive layouts.

## Evidence and exports

Canonical snapshot includes schemaVersion, applicationVersion, auditId, tenantId, account identifier, scope, startedAt/completedAt UTC, collection depth, capability results and coverage records. Resource, principal, grant and membership records use stable IDs and provenance. Keep explicit states: complete, partial, denied, failed, skipped and not requested.

- JSON: canonical linked model and provenance; versioned schema suitable for future offline re-opening.
- CSV: separate resources, grants, principals, memberships and coverage files in a ZIP; stable IDs join them. Escape correctly and protect spreadsheet text from formula execution. Do not flatten away membership chains.
- XML: versioned equivalent of the canonical model with escaped data and safe import behavior; disable external entity resolution.
- HTML: self-contained human-readable report with scope, coverage, permissions, membership paths and UTC timestamps; escape all tenant strings, require no remote assets, and support printing. Sensitive sharing-link URLs are excluded by default.

No export silently re-queries the tenant. Exports reflect a time-bounded snapshot, not an atomic tenant transaction. Surface schema and evidence limits in every format. Future import validates format/version and treats content as untrusted. The mockup's download buttons export a small synthetic example only, not the proposed full production schema.

## Architecture and growth

Proposed C#/.NET WPF desktop app consistent with Lantern: Canopy.Core (models, graph traversal, coverage, export), Canopy.Desktop (UI, session coordination), provider-specific read-only collectors and synthetic checks. Keep command/endpoint allowlists, tenant binding and sanitized diagnostics at helper boundaries. Collection modules return evidence plus capability/coverage results rather than UI text.

Use a shared tenant/session abstraction and neutral evidence envelope so Lantern could become an Investigations module later. Keep permissions and investigation schemas independently versioned. Future consolidation needs a separate decision about shared sign-in, consent, data retention and migration; do not copy Lantern's incident-specific scopes into a permissions audit.

## Delivery sequence and acceptance

1. Authentication/coverage spike: prove supported no-custom-app operations and document unmet capabilities before committing to exhaustive collection.
2. Vertical slice: one accessible site, a unique library grant, a SharePoint group containing an Entra group, and a denied site. Every visible membership chain must retain provenance.
3. Audit hardening: pagination, throttling, cancellation, nested membership, deleted principals, hidden membership, deep-scan scope, and partial export.
4. Desktop and exports: keyboard/high-contrast QA; System theme changes; identical evidence and coverage across four export formats; output-escaping checks.
5. Release gate: MFA/Conditional Access and consent tests in a disposable tenant, clean-machine portable package, no automatic tenant changes, no application token persistence, and measured scan performance on representative data.

MVP excludes remediation, unattended scheduled scans, OneDrive by default, policy simulation, live access verification, and complete Microsoft 365 coverage.

## References and inspected inspiration

- Local Lantern: README.md; src/Lantern.Desktop/ModuleSession.ps1; ThemeService.cs; MainWindow.xaml; design/mockups/README.md. These establish module-based delegated sign-in, coverage honesty, explicit exports and theme behavior.
- [Microsoft: Connect-SPOService](https://learn.microsoft.com/en-us/powershell/module/microsoft.online.sharepoint.powershell/connect-sposervice?view=sharepoint-ps)
- [Microsoft: SharePoint Administrator role and site access](https://learn.microsoft.com/en-us/sharepoint/sharepoint-admin-role)
- [PnP: authentication requirements](https://pnp.github.io/powershell/articles/authentication.html)
- [Microsoft Graph: transitive group members](https://learn.microsoft.com/en-us/graph/api/group-list-transitivemembers?view=graph-rest-1.0)

The supplied GitHub URL could not be read during this design pass. The local Canopy directory was empty and not a Git checkout; no claim is made about remote repository contents.
