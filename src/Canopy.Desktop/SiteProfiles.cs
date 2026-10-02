using System.IO;
using System.Security.Cryptography;
using System.Text.Json;

namespace Canopy.Desktop;
public sealed record SiteProfile(string Name,string SiteUrl,string TenantId,string ClientId,string LibraryName,bool IncludeFiles,bool RecursiveFolders)
{
    public SiteProfile Validate()
    {
        if(string.IsNullOrWhiteSpace(Name)||Name.Length>120||Name.Any(char.IsControl))throw new InvalidDataException("Choose a friendly site name of up to 120 characters.");
        if(!Uri.TryCreate(SiteUrl,UriKind.Absolute,out var site)||site.Scheme!="https"||site.Port!=443||site.UserInfo!=""||site.Query!=""||site.Fragment!=""||!System.Text.RegularExpressions.Regex.IsMatch(site.Host,@"^[a-z0-9][a-z0-9-]*\.sharepoint\.com$",System.Text.RegularExpressions.RegexOptions.IgnoreCase)||System.Text.RegularExpressions.Regex.IsMatch(site.Host,@"-(admin|my)\.sharepoint\.com$",System.Text.RegularExpressions.RegexOptions.IgnoreCase)||!System.Text.RegularExpressions.Regex.IsMatch(site.AbsolutePath.TrimEnd('/'),@"^(|/(sites|teams)/[^/]+)$"))throw new InvalidDataException("Enter an HTTPS SharePoint site root, without query strings or embedded credentials.");
        if(!Guid.TryParse(TenantId,out _)||!Guid.TryParse(ClientId,out _))throw new InvalidDataException("Enter the tenant and public client IDs as GUIDs.");
        if(string.IsNullOrWhiteSpace(LibraryName)||LibraryName.Length>256||LibraryName.Any(char.IsControl))throw new InvalidDataException("Enter a document library name.");
        return this with{Name=Name.Trim(),SiteUrl=site.AbsoluteUri.TrimEnd('/'),TenantId=Guid.Parse(TenantId).ToString(),ClientId=Guid.Parse(ClientId).ToString(),LibraryName=LibraryName.Trim(),RecursiveFolders=IncludeFiles||RecursiveFolders};
    }
}
public sealed class SiteProfileStore
{
    public static string DefaultPath=>Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"365Canopy","sites.protected");
    readonly string path;
    public SiteProfileStore(string? path=null)=>this.path=path??DefaultPath;
    public List<SiteProfile> Read()
    {
        if(!File.Exists(path))return new();
        if(new FileInfo(path).Length>1024*1024)throw new InvalidDataException("Saved sites file exceeds the supported size.");
        byte[] plain=ProtectedData.Unprotect(File.ReadAllBytes(path),null,DataProtectionScope.CurrentUser);
        try {
            var sites=JsonSerializer.Deserialize<List<SiteProfile>>(plain)??throw new InvalidDataException("Saved sites file is invalid.");
            if(sites.Count>100||sites.Any(s=>s==null))throw new InvalidDataException("Saved sites file is invalid.");
            var validated=sites.Select(s=>s.Validate()).ToList();
            if(validated.Select(s=>s.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count()!=validated.Count)throw new InvalidDataException("Saved sites have duplicate names.");
            return validated.OrderBy(s=>s.Name,StringComparer.OrdinalIgnoreCase).ToList();
        } finally {CryptographicOperations.ZeroMemory(plain);}
    }
    public void Write(IEnumerable<SiteProfile> profiles)
    {
        var sites=profiles.Select(s=>s.Validate()).ToList();
        if(sites.Count>100||sites.Select(s=>s.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count()!=sites.Count)throw new InvalidDataException("Save up to 100 sites with distinct friendly names.");
        byte[] plain=JsonSerializer.SerializeToUtf8Bytes(sites),cipher;
        try{cipher=ProtectedData.Protect(plain,null,DataProtectionScope.CurrentUser);}finally{CryptographicOperations.ZeroMemory(plain);}
        string directory=Path.GetDirectoryName(Path.GetFullPath(path))!;Directory.CreateDirectory(directory);
        string temporary=Path.Combine(directory,"sites-"+Guid.NewGuid().ToString("N")+".tmp");
        try{File.WriteAllBytes(temporary,cipher);File.Move(temporary,path,true);}finally{if(File.Exists(temporary))File.Delete(temporary);}
    }
}
