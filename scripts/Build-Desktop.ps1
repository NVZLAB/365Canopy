[CmdletBinding()]
param(
    [string]$Dotnet='dotnet',
    [Parameter(Mandatory)][string]$PowerShellRuntime,
    [string]$PnPModulePath=(Join-Path $PSScriptRoot '../work/modules/PnP.PowerShell/3.4.1'),
    [string]$InnoCompiler='C:/Program Files (x86)/Inno Setup 6/ISCC.exe'
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
& (Join-Path $root 'tests/PublicationPrivacy.Checks.ps1')
$dotnetCommand=Get-Command $Dotnet -ErrorAction Stop
$PowerShellRuntime=(Resolve-Path -LiteralPath $PowerShellRuntime).Path
$PnPModulePath=(Resolve-Path -LiteralPath $PnPModulePath).Path
if(!(Test-Path -LiteralPath (Join-Path $PnPModulePath 'PnP.PowerShell.psd1'))){throw 'Run Setup-Checkpoint.ps1 -DesktopOnly, or provide PnPModulePath.'}
if(!(Test-Path -LiteralPath $InnoCompiler)){throw 'Install Inno Setup 6, or provide InnoCompiler.'}
if((Get-AuthenticodeSignature (Join-Path $PowerShellRuntime 'pwsh.exe')).Status -ne 'Valid'){throw 'Source PowerShell runtime signature is invalid.'}
$package=Join-Path $root 'artifacts/desktop/365Canopy'
# Preserve the previous package; build into a fresh directory so stale files cannot be released.
if(Test-Path -LiteralPath $package){
    $resolved=[IO.Path]::GetFullPath($package)
    $allowed=[IO.Path]::GetFullPath((Join-Path $root 'artifacts/desktop'))+[IO.Path]::DirectorySeparatorChar
    if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Package path escaped build output.'}
    Move-Item -LiteralPath $resolved -Destination ($resolved+'-previous-'+[guid]::NewGuid().ToString('N'))
}
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
$env:POWERSHELL_TELEMETRY_OPTOUT='1'
New-Item $package -ItemType Directory -Force | Out-Null
& $Dotnet publish (Join-Path $root 'src/Canopy.Desktop/Canopy.Desktop.csproj') -c Release -r win-x64 --self-contained true -p:DebugType=None -p:DebugSymbols=false -o $package
if($LASTEXITCODE){throw 'Desktop publish failed.'}
if((Get-AuthenticodeSignature (Join-Path $PowerShellRuntime 'pwsh.exe')).Status -ne 'Valid'){throw 'Source PowerShell runtime signature is invalid.'}
$runtime=Join-Path $package 'runtime/powershell'
New-Item $runtime -ItemType Directory -Force | Out-Null
Get-ChildItem -LiteralPath $PowerShellRuntime -Force | Copy-Item -Destination $runtime -Recurse -Force
$modules=Join-Path $package 'work/modules/PnP.PowerShell'
New-Item $modules -ItemType Directory -Force | Out-Null
Copy-Item -LiteralPath $PnPModulePath -Destination $modules -Recurse -Force
$collector=Join-Path $package 'src/Canopy.Checkpoint'
New-Item $collector -ItemType Directory -Force | Out-Null
foreach($file in @('Canopy.Core.psm1','Canopy.Delegated.psm1','Canopy.Items.psm1','Collect-Delegated.ps1','Desktop-Audit.ps1')){Copy-Item -LiteralPath (Join-Path $root "src/Canopy.Checkpoint/$file") -Destination $collector -Force}
Copy-Item -LiteralPath (Join-Path $root 'docs/desktop-preview.md') -Destination (Join-Path $package 'README.txt') -Force
$licenses=Join-Path $package 'licenses'
New-Item -ItemType Directory -Path $licenses -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'LICENSE'),(Join-Path $root 'THIRD_PARTY_NOTICES.txt') -Destination $package
Copy-Item -LiteralPath (Join-Path $root 'licenses/PnP.PowerShell-3.4.1-LICENSE.txt') -Destination $licenses
$config=Get-Content (Join-Path $package '365Canopy.runtimeconfig.json') -Raw | ConvertFrom-Json
$nugetRoot=if($env:NUGET_PACKAGES){$env:NUGET_PACKAGES}else{Join-Path ([Environment]::GetFolderPath('UserProfile')) '.nuget/packages'}
foreach($framework in $config.runtimeOptions.includedFrameworks){
    $pack=Join-Path $nugetRoot ($framework.name.ToLowerInvariant()+'.runtime.win-x64/'+$framework.version)
    $target=Join-Path $licenses $framework.name
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $terms=@(Get-ChildItem -LiteralPath $pack -File | Where-Object {$_.Name -match '^(LICENSE|THIRD-PARTY-NOTICES|ThirdPartyNotices)(\.|$)'})
    if(!$terms){throw ('Runtime license files not found: '+$framework.name)}
    $terms | Copy-Item -Destination $target
}
foreach($notice in @('LICENSE.txt','ThirdPartyNotices.txt')){if(!(Test-Path -LiteralPath (Join-Path $runtime $notice))){throw 'Official PowerShell license/notice files are required.'}}
$smoke=Join-Path $root 'work/desktop-smoke.txt'
$p=Start-Process -FilePath (Join-Path $package '365Canopy.exe') -ArgumentList @('--smoke-test',"`"$smoke`"") -WindowStyle Hidden -Wait -PassThru
if($p.ExitCode -ne 0 -or !(Test-Path $smoke)){throw 'Desktop smoke test failed.'}
& (Join-Path $runtime 'pwsh.exe') -NoLogo -NoProfile -Command "Import-Module '$modules/3.4.1/PnP.PowerShell.psd1' -ErrorAction Stop; Get-Command Connect-PnPOnline,Get-PnPListItem,Invoke-PnPGraphMethod | Select-Object -ExpandProperty Name"
if($LASTEXITCODE){throw 'Packaged module validation failed.'}
Get-ChildItem $package -File -Recurse | ForEach-Object {@{path=[IO.Path]::GetRelativePath($package,$_.FullName);sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash}} | ConvertTo-Json | Set-Content (Join-Path $root 'artifacts/desktop/package-files.json')
& $InnoCompiler /Qp ('/DPayload='+$package) ('/DOutput='+ (Join-Path $root 'artifacts/desktop')) (Join-Path $PSScriptRoot 'Canopy.iss')
if($LASTEXITCODE){throw 'Installer compilation failed.'}
$installer=Join-Path $root 'artifacts/desktop/365Canopy-0.1.0-alpha.7-Setup.exe'
$digest=(Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
[IO.File]::WriteAllText($installer+'.sha256',$digest+'  '+[IO.Path]::GetFileName($installer)+[Environment]::NewLine)
Get-FileHash -LiteralPath $installer -Algorithm SHA256 | Format-List
