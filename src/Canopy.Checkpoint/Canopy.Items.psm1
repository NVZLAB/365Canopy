Set-StrictMode -Version Latest
# Traversal projects metadata and role assignments only. It never opens file contents.
function Get-CanopyItemInventory {
    param([object[]]$Items,[string]$LibraryId,[string]$LibraryRoot,[AllowNull()][string]$LibrarySource,
        [Parameter(Mandatory)][scriptblock]$ReadMetadata,[Parameter(Mandatory)][scriptblock]$ReadGrants)
    $resources=[Collections.Generic.List[object]]::new();$grants=[Collections.Generic.List[object]]::new();$coverage=[Collections.Generic.List[object]]::new()
    $nodes=@{};$ids=[Collections.Generic.HashSet[string]]::new();$paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $root=$LibraryRoot.TrimEnd('/');$nodes[$root]=@{id=$LibraryId;source=$LibrarySource}
    $reviewed=0
    foreach($item in ($Items | Sort-Object {([string]$_['FileRef']).Split('/').Count},{[int]$_['FSObjType'] -eq 0},{[string]$_['FileRef']})) {
        $path=[string]$item['FileRef'];$parent=[string]$item['FileDirRef'];$kind=if([int]$item['FSObjType'] -eq 1){'folder'}else{'file'}
        $id=$kind+':'+$LibraryId.Substring(5)+':'+$item.Id
        $state='partial';$reason='Permission metadata unavailable; resource retained and access unknown.'
        try {
            if([int]$item['FSObjType'] -notin @(0,1) -or !$path.StartsWith($root+'/',[StringComparison]::OrdinalIgnoreCase) -or $path.Contains('/../') -or !$path.StartsWith($parent.TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase) -or $path.Substring($parent.TrimEnd('/').Length+1).Contains('/') -or !$ids.Add($id) -or !$paths.Add($path)) {throw 'Invalid or duplicate library item.'}
        } catch {
            $coverage.Add([pscustomobject]@{operation='Item validation';state='partial';reason='An invalid, duplicate or out-of-library item was excluded.';collectedAt=[DateTime]::UtcNow.ToString('o')});continue
        }
        $parentNode=$nodes[$parent]
        $resource=[pscustomobject]@{id=$id;type=$kind;title=[string]$item['FileLeafRef'];url=$path;parentResourceId=$(if($parentNode){$parentNode.id}else{$null});hasUniqueRoleAssignments=$null;sourceResourceId=$null;permissionState='unknown';collectedAt=[DateTime]::UtcNow.ToString('o')}
        $resources.Add($resource)
        try {
            $unique=& $ReadMetadata $item
            if($unique -isnot [bool]){throw 'Invalid inheritance metadata.'}
            $resource.hasUniqueRoleAssignments=$unique
            $resource.sourceResourceId=if($unique){$id}elseif($parentNode -and $parentNode.source){$parentNode.source}else{$null}
            if($unique) {
                $result=& $ReadGrants $item $id
                foreach($g in $result.grants){$grants.Add($g)}
                $state=$result.state;$reason=$result.reason
            } else {
                $state=if($resource.sourceResourceId){'observed'}else{'partial'}
                $reason=if($resource.sourceResourceId){'Inherited from the recorded ancestor permission source.'}else{'Inheritance observed but parent permission source is unknown.'}
            }
            $resource.permissionState=$state
        } catch { $state='partial' }
        if($kind -eq 'folder'){$nodes[$path]=@{id=$id;source=$resource.sourceResourceId}}
        $coverage.Add([pscustomobject]@{operation=($kind+' permissions '+$path);state=$state;reason=$reason;collectedAt=[DateTime]::UtcNow.ToString('o')})
        $reviewed++
        if($reviewed -eq 1 -or $reviewed % 25 -eq 0 -or $reviewed -eq $Items.Count){Write-Host ('CANOPY_PROGRESS:Reviewing permissions: '+$reviewed+' / '+$Items.Count+' discovered items')}
    }
    [pscustomobject]@{resources=$resources.ToArray();grants=$grants.ToArray();coverage=$coverage.ToArray()}
}
Export-ModuleMember -Function Get-CanopyItemInventory
