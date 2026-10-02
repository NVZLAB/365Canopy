$ErrorActionPreference='Stop'
function Expand-CanopyDependencyArchive {
    param([Parameter(Mandatory)][string]$Archive,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$ExpectedHash)
    if((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ne $ExpectedHash){throw 'Dependency archive hash does not match the reviewed release.'}
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $base=[IO.Path]::GetFullPath($Destination)+[IO.Path]::DirectorySeparatorChar
        $total=0L;$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($entry in $zip.Entries){
            $target=[IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if(!$target.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or !$seen.Add($target)){throw 'Unsafe or duplicate archive path.'}
            $total+=$entry.Length
            if($total -gt 600MB -or $zip.Entries.Count -gt 10000){throw 'Dependency archive exceeds extraction limits.'}
        }
        [IO.Compression.ZipFileExtensions]::ExtractToDirectory($zip,$Destination)
    } finally {$zip.Dispose()}
}
function Install-CanopyDependency {
    param([Parameter(Mandatory)][string]$Destination,[string]$Archive)
    $hash='82062BD1DA5464BFFAC78113ED85355C42225FBACE5CB5681E759C45A1B2DEB6'
    $destination=[IO.Path]::GetFullPath($Destination)
    if((Test-Path -LiteralPath (Join-Path $Destination '.canopy-ready')) -and (Test-Path -LiteralPath (Join-Path $Destination 'PnP.PowerShell.psd1')) -and (Get-Content -LiteralPath (Join-Path $Destination '.canopy-ready') -Raw).Trim() -eq $hash){return}
    if(Test-Path -LiteralPath $Destination){throw 'An incomplete dependency folder already exists. Choose a new folder or remove it before retrying setup.'}
    $parent=Split-Path $Destination -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $stage=Join-Path $parent ('.canopy-setup-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        if(!$Archive){
            $Archive=Join-Path $stage 'download.nupkg'
            $http=[Net.Http.HttpClient]::new();$http.Timeout=[TimeSpan]::FromMinutes(5)
            try {
                $response=$http.GetAsync('https://www.powershellgallery.com/api/v2/package/PnP.PowerShell/3.4.1',[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                $response.EnsureSuccessStatusCode() | Out-Null
                $input=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult();$output=[IO.File]::Create($Archive)
                try {$buffer=[byte[]]::new(65536);$total=0L;while(($count=$input.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$count;if($total -gt 150MB){throw 'Download exceeds size limit.'};$output.Write($buffer,0,$count)}}finally{$input.Dispose();$output.Dispose();$response.Dispose()}
            }finally{$http.Dispose()}
        }
        $payload=Join-Path $stage 'payload'
        Expand-CanopyDependencyArchive -Archive $Archive -Destination $payload -ExpectedHash $hash
        if(!(Test-Path -LiteralPath (Join-Path $payload 'PnP.PowerShell.psd1'))){throw 'Dependency manifest is missing.'}
        # Validate import in this isolated setup process before marking installation ready.
        Import-Module (Join-Path $payload 'PnP.PowerShell.psd1') -ErrorAction Stop
        Get-Command Connect-PnPOnline,Get-PnPListItem,Invoke-PnPGraphMethod -ErrorAction Stop | Out-Null
        Remove-Module PnP.PowerShell
        Set-Content -LiteralPath (Join-Path $payload '.canopy-ready') -Value $hash
        Move-Item -LiteralPath $payload -Destination $Destination
    }finally{
        $resolved=[IO.Path]::GetFullPath($stage)
        if($resolved.StartsWith([IO.Path]::GetFullPath($parent)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf).StartsWith('.canopy-setup-')){Remove-Item -LiteralPath $resolved -Recurse -Force}
    }
}
Export-ModuleMember -Function Install-CanopyDependency,Expand-CanopyDependencyArchive
