$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Canopy.Checkpoint/Canopy.Items.psm1') -Force
$script:checks=0
function Assert($Condition,[string]$Message){if(!$Condition){throw "FAILED: $Message"};$script:checks++}
function Item($Id,$Path,$Parent,$Folder,$Unique){@{Id=$Id;FileRef=$Path;FileDirRef=$Parent;FileLeafRef=$Path.Split('/')[-1];FSObjType=[int]$Folder;unique=$Unique}}
$items=@(
    (Item 3 '/docs/Private/deep/inherited.docx' '/docs/Private/deep' 0 $false),
    (Item 2 '/docs/Private/deep' '/docs/Private' 1 $false),
    (Item 1 '/docs/Private' '/docs' 1 $true),
    (Item 4 '/docs/root.txt' '/docs' 0 $false),
    (Item 5 '/docs/Private/unique.docx' '/docs/Private' 0 $true),
    (Item 6 '/docs/Unknown' '/docs' 1 $false),
    (Item 7 '/docs/Unknown/retained.txt' '/docs/Unknown' 0 $false),
    (Item 8 '/elsewhere/escape.txt' '/elsewhere' 0 $false)
)
$calls=[Collections.Generic.List[string]]::new()
$inventory=Get-CanopyItemInventory -Items $items -LibraryId 'list:test' -LibraryRoot '/docs' -LibrarySource 'web:test' -ReadMetadata {param($i)if($i.Id -eq 6){throw 'private service body'};[bool]$i.unique} -ReadGrants {
    param($i,$id);$calls.Add($id)
    [pscustomobject]@{state='observed';reason='Synthetic grants';grants=@([pscustomobject]@{resourceId=$id;principal=@{id='owners'};roles=@()})}
}
$r=@{};foreach($node in $inventory.resources){$r[$node.id]=$node}
Assert ($inventory.resources.Count -eq 7) 'Retain returned in-library files and folders'
Assert ($r['file:test:3'].sourceResourceId -eq 'folder:test:1') 'Deep file inherits nearest unique folder'
Assert ($r['file:test:3'].parentResourceId -eq 'folder:test:2') 'Deep file attaches to actual parent'
Assert ($r['file:test:4'].sourceResourceId -eq 'web:test') 'Root-level file inherits library source'
Assert ($r['file:test:5'].sourceResourceId -eq 'file:test:5') 'Unique file uses its own grants'
Assert ($calls.Count -eq 2 -and $calls.Contains('file:test:5')) 'Read role assignments only for unique items'
Assert ($null -eq $r['folder:test:6'].hasUniqueRoleAssignments -and $null -eq $r['file:test:7'].sourceResourceId) 'Denied ancestor and descendant remain unknown without fallback'
Assert (@($inventory.coverage | Where-Object state -eq 'partial').Count -eq 3) 'Permission gaps and excluded items recorded'
Assert (($inventory | ConvertTo-Json -Depth 20) -notmatch 'private service body') 'Raw service failure never exported'
$partial=Get-CanopyItemInventory -Items @((Item 9 '/docs/failed.txt' '/docs' 0 $true)) -LibraryId 'list:test' -LibraryRoot '/docs' -LibrarySource 'web:test' -ReadMetadata {param($i)$true} -ReadGrants {throw 'failure'}
Assert ($partial.resources.Count -eq 1 -and $partial.coverage[0].state -eq 'partial') 'File retained when unique grant read fails'
$missing=Get-CanopyItemInventory -Items @((Item 10 '/docs/missing/file.txt' '/docs/missing' 0 $false)) -LibraryId 'list:test' -LibraryRoot '/docs' -LibrarySource 'web:test' -ReadMetadata {param($i)$false} -ReadGrants {throw 'must not request'}
Assert ($null -eq $missing.resources[0].sourceResourceId) 'Missing intermediate parent never implies library inheritance'
Write-Host "$script:checks item inventory checks passed. No tenant accessed."
