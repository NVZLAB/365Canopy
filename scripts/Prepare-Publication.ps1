[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
& (Join-Path $root 'tests/PublicationPrivacy.Checks.ps1')
$top=@('.gitignore','.gitattributes','SECURITY.txt','global.json','LICENSE','README.md','RELEASE_NOTES.txt','THIRD_PARTY_NOTICES.txt','Setup-Checkpoint.ps1','Start-365Canopy.ps1','Register-365Canopy.ps1')
$files=@($top | ForEach-Object {Get-Item -LiteralPath (Join-Path $root $_)})
foreach($directory in @('src','tests','scripts','docs','design','licenses')){
    $files+=Get-ChildItem -LiteralPath (Join-Path $root $directory) -File -Recurse | Where-Object {
        $_.FullName -notmatch '[\\/](bin|obj|work|exports|artifacts|\.git)[\\/]' -and
        $_.Extension -in @('.cs','.csproj','.xaml','.ps1','.psm1','.md','.txt','.html','.js','.iss','.png','.ico','.json')
    }
}
$files=@($files | Sort-Object FullName -Unique)
$destination=Join-Path $root ('artifacts/publication/source-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$manifest=@(foreach($file in $files){
    $relative=[IO.Path]::GetRelativePath($root,$file.FullName)
    if($relative -match '(^|[\\/])(work|exports|artifacts|bin|obj|\.git)([\\/]|$)'){throw 'Private/generated path entered publication list.'}
    $target=Join-Path $destination $relative
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $target
    @{path=$relative.Replace('\','/');bytes=$file.Length;sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash}
})
$manifestPath=$destination+'-manifest.json'
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8
Write-Host ('Publication source snapshot: '+$destination)
Write-Host ('Review manifest: '+$manifestPath)
Write-Host ($manifest.Count.ToString()+' allowlisted files copied. No Git commit, push or visibility change performed.')
