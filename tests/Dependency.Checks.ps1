param([string]$VendorArchive)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Canopy.Checkpoint/Canopy.Dependency.psm1') -Force
$root=Join-Path $PSScriptRoot ('../work/dependency-checks-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$zip=Join-Path $root 'unsafe.zip'
$archive=[IO.Compression.ZipFile]::Open($zip,[IO.Compression.ZipArchiveMode]::Create)
$entry=$archive.CreateEntry('../escaped.txt');$writer=[IO.StreamWriter]::new($entry.Open());$writer.Write('unsafe');$writer.Dispose();$archive.Dispose()
$hash=(Get-FileHash $zip).Hash
$failed=$false;try{Expand-CanopyDependencyArchive $zip (Join-Path $root 'payload') $hash}catch{$failed=$true}
if(!$failed -or (Test-Path (Join-Path $root 'escaped.txt'))){throw 'Archive traversal check failed.'}
$failed=$false;try{Expand-CanopyDependencyArchive $zip (Join-Path $root 'payload') ('0'*64)}catch{$failed=$true}
if(!$failed){throw 'Hash mismatch check failed.'}
$existing=Join-Path $root 'existing';New-Item $existing -ItemType Directory | Out-Null;Set-Content (Join-Path $existing 'preserved.txt') 'keep'
$failed=$false;try{Install-CanopyDependency $existing $zip}catch{$failed=$true}
if(!$failed -or (Get-Content (Join-Path $existing 'preserved.txt')) -ne 'keep'){throw 'Existing installation preservation check failed.'}
$destination=Join-Path $root 'failed-install';$failed=$false;try{Install-CanopyDependency $destination $zip}catch{$failed=$true}
if(!$failed -or (Test-Path $destination) -or @(Get-ChildItem $root -Directory -Filter '.canopy-setup-*').Count){throw 'Failed install cleanup check failed.'}
Write-Host '4 dependency setup safety checks passed.'

if($VendorArchive){
    $destination=Join-Path $root 'verified'
    Install-CanopyDependency $destination $VendorArchive
    if((Get-Content (Join-Path $destination '.canopy-ready') -Raw).Trim() -ne '82062BD1DA5464BFFAC78113ED85355C42225FBACE5CB5681E759C45A1B2DEB6'){throw 'Ready marker mismatch.'}
    $stamp=(Get-Item (Join-Path $destination '.canopy-ready')).LastWriteTimeUtc
    Install-CanopyDependency $destination (Join-Path $root 'nonexistent.nupkg')
    if((Get-Item (Join-Path $destination '.canopy-ready')).LastWriteTimeUtc -ne $stamp){throw 'Repeat setup changed an existing installation.'}
    Write-Host 'Verified vendor import and repeat setup without another download passed.'
}
