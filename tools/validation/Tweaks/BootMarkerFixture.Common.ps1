function Get-TweakBootMarkerSnapshot {
    $gate=[Threading.Mutex]::new($false,'Global\RooIndustriesBootMarker');$held=$false
    try{$held=$gate.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not$held){$gate.Dispose();throw 'BootMarker snapshot mutex timeout'}
    try {
    $machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try {
        $parent=$machine.OpenSubKey('SOFTWARE\RooIndustriesOptimizationSuite')
        if(-not $parent){return [pscustomobject][ordered]@{parentExists=$false;parentSecurity=$null;rows=@()}}
        try {
            $parentSecurity=[Convert]::ToBase64String($parent.GetAccessControl([Security.AccessControl.AccessControlSections]::All).GetSecurityDescriptorBinaryForm())
            $marker=$parent.OpenSubKey('BootMarker')
            if(-not $marker){return [pscustomobject][ordered]@{parentExists=$true;parentSecurity=$parentSecurity;rows=@()}}
            $rows=[Collections.Generic.List[object]]::new()
            function Read-Key($Key,[string]$Relative) {
                $values=@($Key.GetValueNames()|Sort-Object|ForEach-Object {[pscustomobject][ordered]@{name=$_;kind=[string]$Key.GetValueKind($_);value=$Key.GetValue($_,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}})
                $security=$Key.GetAccessControl([Security.AccessControl.AccessControlSections]::All)
                $rows.Add([pscustomobject][ordered]@{relative=$Relative;values=$values;security=[Convert]::ToBase64String($security.GetSecurityDescriptorBinaryForm())})
                foreach($name in @($Key.GetSubKeyNames()|Sort-Object)){$child=$Key.OpenSubKey($name);try{Read-Key $child ($Relative+'\'+$name)}finally{$child.Dispose()}}
            }
            try{Read-Key $marker ''}finally{$marker.Dispose()}
            [pscustomobject][ordered]@{parentExists=$true;parentSecurity=$parentSecurity;rows=@($rows.ToArray())}
        }finally{$parent.Dispose()}
    }finally{$machine.Dispose()}
    }finally{$gate.ReleaseMutex();$gate.Dispose()}
}
function Restore-TweakBootMarkerSnapshot($Before) {
    $gate=[Threading.Mutex]::new($false,'Global\RooIndustriesBootMarker');$held=$false
    try{$held=$gate.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not$held){$gate.Dispose();throw 'BootMarker restore mutex timeout'}
    try {
    $after=Get-TweakBootMarkerSnapshot
    if((ConvertTo-Json -InputObject $Before -Depth 30 -Compress) -ceq (ConvertTo-Json -InputObject $after -Depth 30 -Compress)){return}
    $root=@($after.rows|Where-Object relative -CEQ '')
    if($root.Count -ne 1){throw 'BootMarker changed outside the validator; retained'}
    if($Before.parentExists -and $Before.parentSecurity -cne $after.parentSecurity){throw 'Product parent security changed; retained'}
    $id=@($root[0].values|Where-Object name -IEQ 'Id')
    $parsed=[Guid]::Empty
    if($id.Count -ne 1 -or $id[0].kind -cne 'String' -or -not[Guid]::TryParseExact([string]$id[0].value,'N',[ref]$parsed)){throw 'BootMarker has no exact validator Id; retained'}
    $original=@($Before.rows|Where-Object relative -CEQ '')
    if($original.Count){
        $oldRows=@($Before.rows|ForEach-Object {$row=$_;[ordered]@{relative=$row.relative;values=@($row.values|Where-Object {$row.relative -cne '' -or $_.name -ine 'Id'});security=$row.security}})
        $newRows=@($after.rows|ForEach-Object {$row=$_;[ordered]@{relative=$row.relative;values=@($row.values|Where-Object {$row.relative -cne '' -or $_.name -ine 'Id'});security=$row.security}})
        if((ConvertTo-Json -InputObject $oldRows -Depth 30 -Compress) -cne (ConvertTo-Json -InputObject $newRows -Depth 30 -Compress)){throw 'BootMarker neighbors or security changed; retained'}
    }elseif($after.rows.Count -ne 1 -or $root[0].values.Count -ne 1){throw 'New BootMarker has unknown neighbors; retained'}
    $machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try {
        $parent=$machine.OpenSubKey('SOFTWARE\RooIndustriesOptimizationSuite',$true)
        try{
            $marker=$parent.OpenSubKey('BootMarker',$true)
            try{
                if($marker.GetValueKind('Id') -ne [Microsoft.Win32.RegistryValueKind]::String -or $marker.GetValue('Id',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -cne $id[0].value){throw 'BootMarker Id drifted before restore; retained'}
                if($original.Count){$saved=@($original[0].values|Where-Object name -IEQ 'Id');$marker.DeleteValue($id[0].name,$true);if($saved.Count){$marker.SetValue($saved[0].name,$saved[0].value,[Microsoft.Win32.RegistryValueKind]$saved[0].kind)}}
                else{if($marker.ValueCount -ne 1 -or $marker.SubKeyCount -ne 0){throw 'BootMarker neighbors appeared before removal; retained'};$marker.DeleteValue('Id',$true)}
                $marker.Flush()
            }finally{$marker.Dispose()}
            if(-not $original.Count){$parent.DeleteSubKey('BootMarker',$true)}
            if(-not$Before.parentExists){if($parent.ValueCount -ne 0 -or $parent.SubKeyCount -ne 0){throw 'Created product parent has foreign neighbors; retained'}}
        }finally{$parent.Dispose()}
        if(-not$Before.parentExists){$machine.DeleteSubKey('SOFTWARE\RooIndustriesOptimizationSuite',$true)}
    }finally{$machine.Dispose()}
    $restored=Get-TweakBootMarkerSnapshot
    if((ConvertTo-Json -InputObject $Before -Depth 30 -Compress) -cne (ConvertTo-Json -InputObject $restored -Depth 30 -Compress)){throw 'BootMarker exact restore failed'}
    }finally{$gate.ReleaseMutex();$gate.Dispose()}
}
