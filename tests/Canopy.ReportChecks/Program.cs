using System.IO;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Canopy.Desktop;
void Check(bool condition,string message){if(!condition)throw new Exception(message);Console.WriteLine("Passed: "+message);}
var audit=JsonNode.Parse("""
{"completedAt":"test","resources":[{"id":"w","title":"<script>alert(1)</script>","url":"/site","hasUniqueRoleAssignments":true,"sourceResourceId":"w"},{"id":"f","title":"Child","url":"/site/child","hasUniqueRoleAssignments":false,"sourceResourceId":"w"}],"grants":[{"resourceId":"w","principal":{"id":"1","type":"SharePointGroup","title":"=Owners"},"roles":[{"name":"Read"}]}],"sharePointGroups":[{"id":"1","state":"observed","members":[{"id":"u","type":"User","title":"Alice","loginName":"alice@example.test"},{"id":"1","type":"SharePointGroup","title":"Cycle"}]}],"directoryGroups":[],"coverage":[{"operation":"Files","state":"notRequested","reason":"Not collected"}]}
""")!.AsObject();
var rows=AuditReport.Rows(audit);var html=AuditReport.Html(audit);var csv=AuditReport.Csv(audit);
Check(!html.Contains("<script>alert")&&html.Contains("&lt;script&gt;"),"HTML escapes tenant-controlled markup");
Check(html.Contains("alice@example.test")&&html.Contains("Group cycle encountered"),"HTML includes identity paths and cycle gap");
Check(rows.Any(r=>r.Resource=="/site/child"&&r.Inheritance=="Inherited"&&r.User=="alice@example.test"),"Inherited resources expand ancestor grants");
Check(csv.Contains("\"'=Owners\""),"CSV neutralizes formula cells");
Check(rows.Any(r=>r.Kind=="coverage"&&r.State=="notRequested"),"CSV retains coverage evidence");
Check(html.Contains("default-src 'none'")&&!html.Contains("<script>"),"Report is offline and script-free");
audit["resources"]!.AsArray().Add(JsonNode.Parse("""{"id":"u","title":"Unreadable.pdf","type":"file","url":"/site/Unreadable.pdf","hasUniqueRoleAssignments":null,"sourceResourceId":null}"""));
audit["resources"]!.AsArray().Add(JsonNode.Parse("""{"id":"i","title":"Inherited.docx","type":"file","url":"/site/Inherited.docx","hasUniqueRoleAssignments":false,"sourceResourceId":"w"}"""));
var fileRows=AuditReport.Rows(audit);
Check(fileRows.Any(r=>r.Resource=="/site/Unreadable.pdf"&&r.Inheritance=="Unknown"&&r.State=="unknown"),"Unreadable file is unknown, never inherited");
Check(fileRows.Any(r=>r.Resource=="/site/Inherited.docx"&&r.User=="alice@example.test"),"File inherits membership paths from source");
Check(AuditReport.Html(audit).Contains("Files reviewed"),"HTML report summarizes file review");
Check(AuditReport.Rows(audit,false).Count(r=>r.Resource=="/site/Inherited.docx")==1&&AuditReport.Html(audit).Contains("Follow the permission source"),"HTML links inherited files to shared permission evidence without repeating people");
if(args.Length==2){var live=JsonNode.Parse(File.ReadAllText(args[0]))!.AsObject();Directory.CreateDirectory(args[1]);File.WriteAllText(Path.Combine(args[1],"365Canopy-report.html"),AuditReport.Html(live));File.WriteAllText(Path.Combine(args[1],"365Canopy-report.csv"),AuditReport.Csv(live),new System.Text.UTF8Encoding(true));}

var profileDirectory=Path.Combine(Environment.CurrentDirectory,"work","profile-checks",Guid.NewGuid().ToString("N"));
var profilePath=Path.Combine(profileDirectory,"sites.protected");
var store=new SiteProfileStore(profilePath);
var profile=new SiteProfile("Demo sales site","https://fabrikam.sharepoint.com/sites/test","11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222","Documents",false,true);
store.Write(new[]{profile});var cipher=File.ReadAllBytes(profilePath);
Check(store.Read().Single()==profile,"Saved site round-trips for current Windows account");
Check(!System.Text.Encoding.UTF8.GetString(cipher).Contains(profile.SiteUrl),"Saved-site file does not store plaintext tenant metadata");
Check((profile with{IncludeFiles=true,RecursiveFolders=false}).Validate().RecursiveFolders,"File profile retains required recursive scope");
bool rejected=false;try{store.Write(new[]{profile with{SiteUrl=profile.SiteUrl+"?token=test"}});}catch(InvalidDataException){rejected=true;}
Check(rejected&&File.ReadAllBytes(profilePath).SequenceEqual(cipher),"Unsafe profile is rejected without overwriting saved sites");
rejected=false;try{store.Write(new[]{profile,profile with{Name="DEMO SALES SITE"}});}catch(InvalidDataException){rejected=true;}
Check(rejected,"Duplicate friendly names are rejected");
var tampered=cipher.ToArray();tampered[^1]^=1;File.WriteAllBytes(profilePath,tampered);
rejected=false;try{store.Read();}catch(CryptographicException){rejected=true;}
Check(rejected&&File.ReadAllBytes(profilePath).SequenceEqual(tampered),"Corrupt profile file is rejected and preserved");
File.WriteAllBytes(profilePath,cipher);store.Write(Array.Empty<SiteProfile>());
Check(store.Read().Count==0,"Forgetting a site clears saved metadata");


var treeAudit=JsonNode.Parse("""
{"schemaVersion":"0.2-delegated","state":"completed","completedAt":"Synthetic preview","scope":{"siteUrl":"https://fabrikam.sharepoint.com/sites/test","library":"Documents"},"resources":[{"id":"site","type":"web","title":"Demo sales site","url":"/sites/test","hasUniqueRoleAssignments":true,"sourceResourceId":"site"},{"id":"library","type":"library","title":"Documents","url":"/sites/test/Documents","hasUniqueRoleAssignments":false,"sourceResourceId":"site"},{"id":"private","parentResourceId":"library","type":"folder","title":"Private","url":"/sites/test/Documents/Private","hasUniqueRoleAssignments":true,"sourceResourceId":"private"},{"id":"file","parentResourceId":"private","type":"file","title":"Budget.xlsx","url":"/sites/test/Documents/Private/Budget.xlsx","hasUniqueRoleAssignments":false,"sourceResourceId":"private"},{"id":"unknown","parentResourceId":"library","type":"file","title":"Unavailable.pdf","url":"/sites/test/Documents/Unavailable.pdf","hasUniqueRoleAssignments":null,"sourceResourceId":null}],"grants":[{"resourceId":"site","principal":{"id":"members","type":"SharePointGroup","title":"Site Members"},"roles":[{"name":"Edit"}]},{"resourceId":"private","principal":{"id":"owners","type":"SharePointGroup","title":"Site Owners"},"roles":[{"name":"Full Control"}]}],"sharePointGroups":[{"id":"members","state":"observed","members":[{"id":"alice","type":"User","title":"Alice Example","loginName":"alice@example.test"}]},{"id":"owners","state":"observed","members":[{"id":"22222222-2222-2222-2222-222222222222","type":"SecurityGroup","title":"Team owners","loginName":"c:0o.c|federateddirectoryclaimprovider|22222222-2222-2222-2222-222222222222_o"}]}],"directoryGroups":[{"id":"22222222-2222-2222-2222-222222222222","relationship":"owners","displayName":"Sales team","state":"observed","members":[{"id":"admin","type":"#microsoft.graph.user","displayName":"Jordan Example","userPrincipalName":"jordan@example.test"}]}],"coverage":[{"operation":"Unavailable.pdf permissions","state":"denied","reason":"Permissions could not be read; access remains unknown."}]}
""")!.AsObject();
var treeHtml=AuditReport.Html(treeAudit);
var hierarchy=new Dictionary<string,string>();var detailStack=new Stack<string>();
foreach(System.Text.RegularExpressions.Match tag in System.Text.RegularExpressions.Regex.Matches(treeHtml,@"</?details(?:\s[^>]*)?>")){
    if(tag.Value.StartsWith("</")){detailStack.Pop();continue;}
    var id=System.Text.RegularExpressions.Regex.Match(tag.Value,@"id=resource-(\d+)");string value=id.Success?id.Groups[1].Value:"";
    if(value!="")hierarchy[value]=detailStack.FirstOrDefault(parent=>parent!="")??"";
    detailStack.Push(value);
}
Check(hierarchy["1"]=="0"&&hierarchy["2"]=="1"&&hierarchy["3"]=="2","HTML nests library, folder and file under their resource parents");
Check(System.Net.WebUtility.HtmlDecode(treeHtml).Contains("Entra group · owners")&&treeHtml.Contains("jordan@example.test")&&treeHtml.Contains("Site Owners"),"HTML expands classic groups into Entra owners and named people");
Check(treeHtml.Contains("href='#resource-2'")&&treeHtml.Contains("Permission inheritance is unknown"),"HTML preserves inherited source links and unknown evidence");
var invalidTree=treeAudit.DeepClone().AsObject();invalidTree["resources"]![0]!["parentResourceId"]="private";invalidTree["resources"]![4]!["parentResourceId"]="missing";
var invalidHtml=AuditReport.Html(invalidTree);
Check(System.Text.RegularExpressions.Regex.Matches(invalidHtml,@"id=resource-\d+").Count==5&&invalidHtml.Contains("hierarchy cycle")&&invalidHtml.Contains("Parent resource unavailable"),"Malformed resource hierarchy stays bounded and retains every resource with explicit gaps");
if(args.Length==1){Directory.CreateDirectory(args[0]);File.WriteAllText(Path.Combine(args[0],"365Canopy-tree-report.html"),treeHtml);File.WriteAllText(Path.Combine(args[0],"synthetic-audit.json"),treeAudit.ToJsonString());}
