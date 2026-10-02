$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(Test-Path -LiteralPath (Join-Path $root '.git')) {
    $tracked=@(& git -C $root ls-files)
    if($LASTEXITCODE){throw 'Cannot inspect tracked files before publication.'}
    foreach($relative in $tracked){
        if($relative -match '(^|/)(work|exports|artifacts|bin|obj)/|(^|/)(sites\.protected|canopy-registration\.json|365Canopy-audit[^/]*|audit\.json)$'){throw 'Private data or generated output is already tracked. Remove it from the index and review history before publishing.'}
    }
}
$files=Get-ChildItem -LiteralPath $root -File -Recurse -Force | Where-Object {$_.FullName -notmatch '[\\/](work|exports|artifacts|bin|obj|\.git)[\\/]' -and $_.Extension -in @('.cs','.ps1','.psm1','.md','.html','.js','.json','.iss','.csproj')}
foreach($file in $files){
    $text=[IO.File]::ReadAllText($file.FullName)
    foreach($match in [regex]::Matches($text,'(?i)https://([a-z0-9-]+)\.sharepoint\.com')){
        if($match.Groups[1].Value -notin @('TENANT','fabrikam','fabrikam-admin','fabrikam-my','other-admin','contoso','contoso-admin')){throw "Tenant-specific SharePoint URL in publishable file: $($file.Name)"}
    }
    foreach($match in [regex]::Matches($text,'(?i)[a-z0-9._%+-]+@([a-z0-9.-]+\.[a-z]{2,})')){
        if($match.Groups[1].Value -notin @('example.test','example.invalid','example.com','fabrikam.sharepoint.com')){throw "Non-synthetic email address in publishable file: $($file.Name)"}
    }
    foreach($match in [regex]::Matches($text,'(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b')){
        if($match.Value -notin @('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222','00000003-0000-0000-c000-000000000000','00000003-0000-0ff1-ce00-000000000000','A2290B44-421D-42F2-9F06-7C9E8725D6CB')){throw "Unreviewed identifier in publishable file: $($file.Name)"}
    }
}
Write-Host 'Publication privacy checks passed: no non-synthetic tenant URLs, emails or unreviewed GUID constants in checked source files.'
