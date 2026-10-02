$ErrorActionPreference='Stop'
# Regression guard for the delegated runtime, separate from tenant setup scripts.
$allowed=@('Connect-PnPOnline','Disconnect-PnPOnline','Get-PnPAccessToken','Get-PnPConnection','Get-PnPFolder','Get-PnPGroupMember','Get-PnPList','Get-PnPListItem','Get-PnPProperty','Get-PnPWeb','Invoke-PnPGraphMethod')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../src/Canopy.Checkpoint/Collect-Delegated.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Collector parser errors.'}
$commands=$ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)
foreach($command in $commands){
    $name=$command.GetCommandName()
    if($name -like '*-PnP*' -and $name -notin $allowed){throw "Unreviewed PnP runtime command: $name"}
    if($name -eq 'Invoke-PnPGraphMethod'){
        $elements=$command.CommandElements
        $method=$null
        for($i=0;$i -lt $elements.Count-1;$i++){if($elements[$i].Extent.Text -eq '-Method'){$method=$elements[$i+1].Extent.Text}}
        if($method -ne 'Get'){throw 'Graph runtime must use explicit GET.'}
    }
}
Write-Host 'Collector PnP allowlist and Graph GET regression checks passed. This is a code guard, not an absolute side-effect guarantee.'
foreach($file in @('Canopy.Items.psm1','Canopy.Delegated.psm1','Collect-Delegated.ps1')) {
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "../src/Canopy.Checkpoint/$file"),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw "Parser errors: $file"}
    foreach($node in $ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true)){
        if($node.Member.Extent.Text -match '^(BreakRoleInheritance|ResetRoleInheritance|DeleteObject|Update|Recycle|SaveBinary|SaveBinaryDirect|AddRoleAssignment|EnsureUser)$'){throw "Mutation method in runtime: $file"}
    }
}
Write-Host 'Item traversal and CSOM mutation-method regression checks passed.'
