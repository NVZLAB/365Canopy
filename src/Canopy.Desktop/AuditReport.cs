using System.Net;
using System.IO;
using System.Text;
using System.Text.Json.Nodes;

namespace Canopy.Desktop;
public static class AuditReport
{
    static string S(JsonNode? n,string k)=>n?[k]?.ToString()??"";
    static string E(string s)=>WebUtility.HtmlEncode(s);
    static IEnumerable<JsonNode> Items(JsonNode? n,string k)=>(n?[k] as JsonArray??new()).OfType<JsonNode>();
    static string Name(JsonNode p)=>S(p,"title") is {Length:>0} t?t:S(p,"displayName") is {Length:>0} d?d:S(p,"id");
    public record Row(string Kind,string Resource,string Inheritance,string Source,string Principal,string Roles,string Path,string User,string Id,string State,string Note);
    static IEnumerable<(string path,string user,string id,string state,string note)> People(JsonObject audit,JsonNode p,string path,HashSet<string> seen)
    {
        if(seen.Count>=200){yield return(path,"","","partial","Expansion depth limit reached.");yield break;}
        if(S(p,"type")=="SharePointGroup") {
            var key="sp:"+S(p,"id");if(!seen.Add(key)){yield return(path,"",S(p,"id"),"partial","Group cycle encountered.");yield break;}
            var g=Items(audit,"sharePointGroups").FirstOrDefault(x=>S(x,"id")==S(p,"id"));
            if(g==null||!Items(g,"members").Any()) {yield return(path,"",S(p,"id"),g==null?"unknown":S(g,"state"),"No members recorded; review coverage.");yield break;}
            foreach(var m in Items(g,"members"))foreach(var row in People(audit,m,path+" → "+Name(m),new(seen)))yield return row;
            if(S(g,"state")!="observed")yield return(path,"",S(p,"id"),S(g,"state"),"Remaining members unknown.");
            yield break;
        }
        var match=System.Text.RegularExpressions.Regex.Match(S(p,"loginName"),@"^c:(?:0t\.c\|tenant\||0o\.c\|federateddirectoryclaimprovider\|)([\da-f-]{36})(_o)?$",System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        string id=match.Success?match.Groups[1].Value:S(p,"id");
        if(match.Success||S(p,"type")=="#microsoft.graph.group") {
            string relation=match.Success&&match.Groups[2].Success?"owners":"members",key="aad:"+id+":"+relation;
            if(!seen.Add(key)){yield return(path,"",id,"partial","Group cycle encountered.");yield break;}
            var g=Items(audit,"directoryGroups").FirstOrDefault(x=>S(x,"id").Equals(id,StringComparison.OrdinalIgnoreCase)&&(S(x,"relationship")==""?"members":S(x,"relationship"))==relation);
            var label=path+" → "+(g==null?id:Name(g))+" ("+relation+")";
            if(g==null||!Items(g,"members").Any()){yield return(label,"",id,g==null?"unknown":S(g,"state"),g==null?"Membership not collected.":S(g,"reason"));yield break;}
            foreach(var m in Items(g,"members"))foreach(var row in People(audit,m,label+" → "+Name(m),new(seen)))yield return row;
            if(S(g,"state")!="observed")yield return(label,"",id,S(g,"state"),S(g,"reason"));
            yield break;
        }
        string user=S(p,"userPrincipalName");if(user=="")user=S(p,"loginName");
        yield return(path,user,id,user==""?"unresolved":"observed",user==""?(S(p,"identityReason")==""?"Identity details unavailable.":S(p,"identityReason")):"Observed membership; effective access may differ.");
    }
    public static List<Row> Rows(JsonObject audit,bool expandInherited=true)
    {
        var rows=new List<Row>();var resources=Items(audit,"resources").ToList();var resourceMap=resources.ToDictionary(x=>S(x,"id"));var grantMap=Items(audit,"grants").ToLookup(x=>S(x,"resourceId"));
        foreach(var r in resources) {
            string sourceId=S(r,"sourceResourceId"),source=resourceMap.TryGetValue(sourceId,out var src)?S(src,"url"):"Unresolved";
            string inheritance=r["hasUniqueRoleAssignments"]==null?"Unknown":S(r,"hasUniqueRoleAssignments")=="true"?"Unique":"Inherited";
            var grants=grantMap[sourceId].ToList();
            rows.Add(new("resource",S(r,"url"),inheritance,source,"","","","",S(r,"id"),grants.Count==0?"unknown":"observed",grants.Count==0?"No grants recorded; this does not prove no access.":""));
            if(!expandInherited&&inheritance=="Inherited")continue;
            foreach(var g in grants) {
                var p=g["principal"]!;string roles=string.Join(", ",Items(g,"roles").Select(x=>S(x,"name")));
                rows.Add(new("grant",S(r,"url"),inheritance,source,Name(p),roles,Name(p),"",S(p,"id"),"observed",""));
                foreach(var m in People(audit,p,Name(p),new())) {
                    if(rows.Count>=250000)throw new InvalidDataException("Report exceeds 250,000 rows. Export JSON for the full snapshot.");
                    rows.Add(new("membership",S(r,"url"),inheritance,source,Name(p),roles,m.path,m.user,m.id,m.state,m.note));
                }
            }
        }
        foreach(var c in Items(audit,"coverage"))rows.Add(new("coverage","","","",S(c,"operation"),"","","","",S(c,"state"),S(c,"reason")));
        return rows;
    }
    static string CsvCell(string s){if(s.TrimStart().StartsWith('=')||s.TrimStart().StartsWith('+')||s.TrimStart().StartsWith('-')||s.TrimStart().StartsWith('@')||s.StartsWith('\t')||s.StartsWith('\r')||s.StartsWith('\n'))s="'"+s;return "\""+s.Replace("\"","\"\"")+"\"";}
    public static string Csv(JsonObject audit) {
        var b=new StringBuilder("Kind,Resource,Inheritance,Permission source,Principal,Roles,Membership path,Username,Object ID,State,Note\r\n");
        foreach(var r in Rows(audit))b.AppendLine(string.Join(",",new[]{r.Kind,r.Resource,r.Inheritance,r.Source,r.Principal,r.Roles,r.Path,r.User,r.Id,r.State,r.Note}.Select(CsvCell)));
        return b.ToString();
    }

    sealed class TreeEvidence
    {
        public readonly Dictionary<string,JsonNode> Classic;
        public readonly Dictionary<string,JsonNode> Directory;
        int nodes;
        public TreeEvidence(JsonObject audit){Classic=Items(audit,"sharePointGroups").GroupBy(x=>S(x,"id")).ToDictionary(g=>g.Key,g=>g.First());Directory=Items(audit,"directoryGroups").GroupBy(x=>S(x,"id").ToLowerInvariant()+":"+(S(x,"relationship")==""?"members":S(x,"relationship"))).ToDictionary(g=>g.Key,g=>g.First());}
        public void Count(){if(++nodes>250000)throw new InvalidDataException("Report exceeds 250,000 tree entries. Export JSON for the full snapshot.");}
    }
    static void AppendPrincipalTree(StringBuilder b,TreeEvidence evidence,JsonNode p,HashSet<string> seen,string roles="")
    {
        evidence.Count();
        string label=Name(p),id=S(p,"id"),key="",kind="Person",relation="members";JsonNode? group=null;
        if(S(p,"type")=="SharePointGroup"){key="sp:"+id;kind="SharePoint group";evidence.Classic.TryGetValue(id,out group);}
        else {
            var match=System.Text.RegularExpressions.Regex.Match(S(p,"loginName"),@"^c:(?:0t\.c\|tenant\||0o\.c\|federateddirectoryclaimprovider\|)([\da-f-]{36})(_o)?$",System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            if(match.Success||S(p,"type")=="#microsoft.graph.group"){
                if(match.Success){id=match.Groups[1].Value;relation=match.Groups[2].Success?"owners":"members";}
                key="aad:"+id.ToLowerInvariant()+":"+relation;kind="Entra group · "+relation;evidence.Directory.TryGetValue(id.ToLowerInvariant()+":"+relation,out group);if(group!=null)label=Name(group);
            }
        }
        string badge=roles==""?"":$"<span class=badge>{E(roles)}</span>";
        if(key==""){
            string user=S(p,"userPrincipalName");if(user=="")user=S(p,"loginName");
            b.Append($"<li class=person><span class=kind>{E(kind)}</span><strong>{E(label)}</strong>{badge}<div>{E(user==""?"Identity details unavailable":user)}</div><div class=id>Object ID: {E(id)}</div>");
            if(user=="")b.Append($"<div class=tree-gap>{E(S(p,"identityReason"))}</div>");b.Append("</li>");return;
        }
        b.Append($"<li><details open><summary><span class=kind>{E(kind)}</span>{E(label)}{badge}</summary>");
        if(seen.Count>=200||!seen.Add(key)){b.Append("<p class=tree-gap>Group cycle encountered or expansion depth limit reached. Remaining members unknown.</p></details></li>");return;}
        if(group==null){b.Append("<p class=tree-gap>Membership not collected. People unknown; review coverage.</p></details></li>");return;}
        if(!Items(group,"members").Any())b.Append("<p class=tree-gap>No members recorded; review coverage.</p>");
        else {b.Append("<ul>");foreach(var member in Items(group,"members"))AppendPrincipalTree(b,evidence,member,new(seen));b.Append("</ul>");}
        if(S(group,"state")!="observed")b.Append($"<p class=tree-gap>{E(S(group,"state"))}: {E(S(group,"reason"))} Remaining members unknown.</p>");
        b.Append("</details></li>");
    }
    static void AppendResourceTree(StringBuilder b,JsonObject audit,List<JsonNode> resources)
    {
        var map=resources.ToDictionary(r=>S(r,"id"));var anchors=resources.Select((r,i)=>(id:S(r,"id"),index:i)).ToDictionary(x=>x.id,x=>x.index);
        var parents=new Dictionary<string,string>();var gaps=new Dictionary<string,string>();var grantMap=Items(audit,"grants").ToLookup(g=>S(g,"resourceId"));var evidence=new TreeEvidence(audit);
        string web=resources.Where(r=>S(r,"type")=="web").Select(r=>S(r,"id")).FirstOrDefault()??"";
        string library=resources.Where(r=>S(r,"type")=="library").Select(r=>S(r,"id")).FirstOrDefault()??"";
        foreach(var r in resources){string id=S(r,"id"),parent=S(r,"parentResourceId");if(parent==""){if(S(r,"type")=="library")parent=web;else if(S(r,"type") is "folder" or "file")parent=library;}if(parent!=""&&!map.ContainsKey(parent)){gaps[id]="Parent resource unavailable; shown at the top level. This does not change the recorded permission source.";parent="";}parents[id]=parent;}
        foreach(string id in parents.Keys.ToList()){var seen=new HashSet<string>{id};string parent=parents[id];while(parent!=""){if(!seen.Add(parent)||seen.Count>200){parents[id]="";gaps[id]="Resource hierarchy cycle or depth limit encountered; shown at the top level. Review the original evidence.";break;}parent=parents.TryGetValue(parent,out string? next)?next:"";}}
        var children=resources.ToLookup(r=>parents[S(r,"id")]);var rendered=new HashSet<string>();
        void WriteResource(JsonNode r){
            string id=S(r,"id");if(!rendered.Add(id))return;evidence.Count();string sourceId=S(r,"sourceResourceId"),inheritance=r["hasUniqueRoleAssignments"]==null?"Unknown":S(r,"hasUniqueRoleAssignments")=="true"?"Unique":"Inherited";
            string type=S(r,"type") switch{"web"=>"Site","library"=>"Library","folder"=>"Folder","file"=>"File",_=>"Resource"};
            b.Append($"<li><details open id=resource-{anchors[id]}><summary><span class=kind>{E(type)}</span>{E(Name(r))}<span class='badge {(inheritance=="Unknown"?"unknown":"")}'>{inheritance} permissions</span></summary><div class=resource-info>{E(S(r,"url"))}</div>");
            if(gaps.TryGetValue(id,out string? gap))b.Append($"<p class=tree-gap>{E(gap)}</p>");
            string sourceHtml=map.TryGetValue(sourceId,out var source)?$"<a href='#resource-{anchors[sourceId]}'>{E(Name(source))}</a>":"Unresolved";
            b.Append($"<p class=resource-info><strong>Permission source:</strong> {sourceHtml}</p>");
            if(inheritance=="Inherited")b.Append(source==null?"<p class=tree-gap>Inheritance was recorded, but its source is unavailable. Access remains unknown.</p>":"<p class=muted>Follow the permission source above to see the granted groups and people. Any gaps recorded there also apply here.</p>");
            else if(inheritance=="Unknown")b.Append("<p class=tree-gap>Permission inheritance is unknown. This does not prove no access; review coverage.</p>");
            else {
                var grants=grantMap[sourceId].ToList();if(grants.Count==0)b.Append("<p class=tree-gap>No grants recorded. Review coverage; this does not prove no access.</p>");
                else{b.Append("<div class=permissions-label>Granted access &amp; people</div><ul class=people-tree>");foreach(var grant in grants)AppendPrincipalTree(b,evidence,grant["principal"]!,new(),string.Join(", ",Items(grant,"roles").Select(x=>S(x,"name"))));b.Append("</ul>");}
            }
            var descendants=children[id].OrderBy(child=>S(child,"type")=="file"?1:0).ThenBy(child=>Name(child),StringComparer.OrdinalIgnoreCase).ToList();if(descendants.Count>0){b.Append("<ul>");foreach(var child in descendants)WriteResource(child);b.Append("</ul>");}b.Append("</details></li>");
        }
        b.Append("<ul class=resource-tree aria-label='SharePoint permission tree'>");foreach(var root in children[""])WriteResource(root);foreach(var r in resources)if(!rendered.Contains(S(r,"id")))WriteResource(r);b.Append("</ul>");
    }

    public static string Html(JsonObject audit)
    {
        var rows=Rows(audit,false);var resources=Items(audit,"resources").ToList();
        var b=new StringBuilder("""
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:"><title>365Canopy · SharePoint access report</title><style>
:root{color-scheme:light dark;--bg:#f4f7f4;--paper:#fff;--ink:#193126;--muted:#53665b;--line:#dce5de;--green:#176940}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 system-ui,sans-serif}main{max-width:1180px;margin:auto;padding:48px 28px}header{border-bottom:3px solid var(--green);padding-bottom:24px}h1{font-size:36px;line-height:1.2;margin:10px 0}h2{font-size:24px;margin-top:36px}h3{margin:8px 0}.brand{color:var(--green);font-weight:800;letter-spacing:1px}.muted,small{color:var(--muted)}.stats{display:flex;gap:16px;flex-wrap:wrap;margin:24px 0}.stat{background:var(--paper);border:1px solid var(--line);border-radius:14px;padding:18px 24px;min-width:160px}.stat strong{display:block;font-size:30px}.notice{border-left:4px solid #b58a23;padding:16px 20px;background:var(--paper);border-radius:6px}article,details{background:var(--paper);border:1px solid var(--line);border-radius:12px;margin:16px 0;padding:20px}summary{cursor:pointer;font-weight:650}.badge{display:inline-block;border:1px solid var(--line);border-radius:20px;padding:2px 10px;font-size:12px;margin-left:8px}table{border-collapse:collapse;width:100%;margin:14px 0}th,td{padding:12px;text-align:left;vertical-align:top;border-bottom:1px solid var(--line);overflow-wrap:anywhere}th{font-size:12px;text-transform:uppercase;letter-spacing:.6px;color:var(--muted)}.path{font-size:13px}.id{font:12px ui-monospace,monospace;color:var(--muted);overflow-wrap:anywhere}p{overflow-wrap:anywhere}a{color:var(--green)}nav{margin-top:18px}nav a{margin-right:20px}@media(prefers-color-scheme:dark){:root{--bg:#101a14;--paper:#19261e;--ink:#e8f2eb;--muted:#a9bdaf;--line:#344a3b;--green:#81d69e}}@media(max-width:700px){main{padding:24px 14px}table,tbody,tr,td{display:block}thead{display:none}td{padding:8px}.stats{gap:8px}h1{font-size:28px}}@media print{:root{color-scheme:light;--bg:white;--paper:white;--ink:#193126;--muted:#53665b;--line:#dce5de;--green:#176940}main{padding:0}nav{display:none}article{break-inside:avoid}details{break-inside:auto}body{font-size:10pt}h1{font-size:24pt}}

.resource-tree,.resource-tree ul,.people-tree,.people-tree ul{list-style:none;margin:0;padding-left:18px}.resource-tree{padding-left:0}.resource-tree ul,.people-tree ul{border-left:2px solid var(--line);margin:8px 0 8px 10px}.resource-tree li,.people-tree li{position:relative;margin:6px 0}.resource-tree ul>li:before,.people-tree ul>li:before{content:"";position:absolute;left:-18px;top:22px;width:16px;border-top:2px solid var(--line)}.resource-tree details,.people-tree details{padding:10px 14px;margin:6px 0;border-radius:8px}.resource-tree summary{overflow-wrap:anywhere}.resource-info{margin:8px 0;color:var(--muted);font-size:13px}.people-tree{margin:12px 0}.person{padding:8px 12px;background:var(--bg);border-radius:6px;overflow-wrap:anywhere}.tree-gap{color:var(--muted);padding:8px 12px;border-left:3px solid #b58a23}.unknown{border-color:#b58a23}.kind{font-size:12px;color:var(--muted);margin-right:8px;font-weight:400}.permissions-label{font-size:14px;font-weight:650;margin:12px 0 4px}@media(max-width:700px){.resource-tree ul,.people-tree ul{padding-left:10px;margin-left:4px}.resource-tree details,.people-tree details{padding:8px}.badge{margin-left:4px}}@media print{.resource-tree details,.people-tree details{break-inside:auto}.resource-tree ul,.people-tree ul{padding-left:12px}.person{break-inside:avoid}}
</style></head><body><main><header><div class="brand">365CANOPY / SHAREPOINT VISIBILITY</div><h1>Who has access?</h1>
""");
        b.Append("<p class=muted>Collected "+E(S(audit,"completedAt"))+"</p><p><strong>Site:</strong> "+E(S(audit["scope"],"siteUrl"))+"<br><strong>Library:</strong> "+E(S(audit["scope"],"library"))+"<br><strong>Collected by:</strong> "+E(S(audit,"accountLogin"))+"<br><strong>Collection status:</strong> "+E(S(audit,"state"))+"</p><nav><a href=#permissions>Permissions &amp; people</a><a href=#coverage>Coverage &amp; limitations</a></nav></header><div class=stats>");
        foreach(var stat in new[]{(resources.Count,"Resources"),(resources.Count(x=>S(x,"type")=="file"),"Files reviewed"),(Items(audit,"grants").Count(),"Direct grants"),(resources.Count(x=>S(x,"hasUniqueRoleAssignments")=="true"),"Unique permission sets"),(rows.Where(x=>x.Kind=="membership"&&x.State=="unresolved").Select(x=>x.Id).Distinct().Count(),"Unresolved identities")})b.Append($"<div class=stat><strong>{stat.Item1}</strong>{stat.Item2}</div>");
        b.Append("</div><div class=notice><strong>Observed permissions and memberships</strong><br>This report describes the evidence returned during this audit. Inherited permissions use the recorded ancestor’s grants. Missing evidence does not mean no access. Policies, sharing links and uncollected resources can affect access. See coverage below.</div><h2 id=permissions>Permissions &amp; people</h2><p class=muted>Expand or collapse a site, library, folder or file to follow its permissions. Groups expand into their observed members. Inherited items link to the resource that grants access. Sections start expanded; reopen any collapsed sections before printing.</p>");
        AppendResourceTree(b,audit,resources);
        b.Append("<h2 id=coverage>Coverage &amp; limitations</h2><p class=muted>Observed means that operation returned evidence. Partial, denied or failed entries leave a gap. Not requested entries are outside the selected audit.</p><table><thead><tr><th>Operation</th><th>Status</th><th>Detail</th></tr></thead><tbody>");
        foreach(var c in Items(audit,"coverage"))b.Append($"<tr><td>{E(S(c,"operation"))}</td><td>{E(S(c,"state"))}</td><td>{E(S(c,"reason"))}</td></tr>");
        b.Append("</tbody></table><footer class=muted>365Canopy · Local report · No external resources or scripts. Treat this report as sensitive tenant information.</footer></main></body></html>");return b.ToString();
    }
}
