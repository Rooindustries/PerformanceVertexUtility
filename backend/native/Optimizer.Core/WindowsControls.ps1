$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
function Invoke-SystemTool([string]$name,[string[]]$arguments){
    $output=& (Join-Path ([Environment]::GetFolderPath('System')) $name) @arguments 2>&1
    if($LASTEXITCODE -ne 0){throw ($name+' exited '+$LASTEXITCODE+': '+($output -join ' '))}
    return ($output -join [Environment]::NewLine)
}
function Get-Adapters([string]$target='primary') {
    if($target.StartsWith('interfaces:')){
        $ids=@($target.Substring(11).Split(';')|ForEach-Object {([guid]$_).ToString('D')})
        if($ids.Count -eq 0 -or $ids.Count -gt 64){throw 'Invalid captured adapter selection.'}
        $adapters=@(Get-NetAdapter -IncludeHidden|Where-Object {([guid]$_.InterfaceGuid).ToString('D') -in $ids}|Sort-Object InterfaceGuid)
        if($adapters.Count -ne $ids.Count){throw 'A captured network adapter is missing.'}
        return $adapters
    }
    if($target -ne 'primary'){throw 'Unknown adapter selection.'}
    $indices=@(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -ExpandProperty InterfaceIndex -Unique)
    $adapters=@(Get-NetAdapter -IncludeHidden | Where-Object {$_.Status -eq 'Up' -and $_.InterfaceIndex -in $indices} | Sort-Object InterfaceGuid)
    if($adapters.Count -eq 0){throw 'No active adapter with an IPv4 default route was found. No wildcard adapter fallback is allowed.'}
    return $adapters
}
function Assert-AdapterExposes([object[]]$errors,[int]$count,[string]$setting,$adapter){
    $failures=@($errors|Where-Object {[string]$_.FullyQualifiedErrorId -notlike 'CmdletizationQuery_NotFound*'})
    if($failures.Count -gt 0){throw $failures[0]}
    if($count -gt 0){return}
    $current=@(Get-NetAdapter -IncludeHidden|Where-Object {$_.InterfaceGuid -eq $adapter.InterfaceGuid -and $_.Name -ceq $adapter.Name})
    if($current.Count -ne 1 -or $adapter.Hidden){throw ($setting+' configuration is unavailable for '+$adapter.Name)}
    throw ('No devices expose '+$setting+' on the '+$adapter.Name+' adapter.')
}
function Get-CanonicalAddress([string]$value){
    if($value.Contains('/')){
        $parts=$value.Split('/');if($parts.Count -ne 2){throw 'Unexpected firewall address format.'}
        $ip=[Net.IPAddress]::Parse($parts[0]);if($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'This block list requires IPv4 addresses.'}
        [uint64]$number=0;foreach($byte in $ip.GetAddressBytes()){$number=$number*256+$byte}
        [uint64]$mask=0
        if($parts[1].Contains('.')){foreach($byte in ([Net.IPAddress]::Parse($parts[1])).GetAddressBytes()){$mask=$mask*256+$byte}}
        else {$prefix=[int]$parts[1];if($prefix -lt 0 -or $prefix -gt 32){throw 'Invalid firewall network prefix.'};$mask=[uint64]([Math]::Pow(2,32)-[Math]::Pow(2,32-$prefix))}
        [uint64]$inverse=4294967295-$mask
        if(($inverse -band ($inverse+1)) -ne 0){throw 'The firewall returned a non-contiguous network mask.'}
        [uint64]$first=$number -band $mask;[uint64]$last=$first -bor $inverse
        $start=((24,16,8,0|ForEach-Object {($first -shr $_) -band 255}) -join '.')
        if($first -eq $last){return $start}
        return $start+'-'+((24,16,8,0|ForEach-Object {($last -shr $_) -band 255}) -join '.')
    }
    if($value.Contains('-')){return (($value.Split('-')|ForEach-Object {([Net.IPAddress]::Parse($_)).ToString()}) -join '-')}
    return ([Net.IPAddress]::Parse($value)).ToString()
}
function Get-PowerDevices {
    $classes=@{};foreach($device in Get-PnpDevice){$classes[$device.InstanceId.ToUpperInvariant()]=[string]$device.ClassGuid}
    $devices=@(Get-CimInstance -Namespace root/wmi -ClassName MSPower_DeviceEnable|Where-Object {
        $id=($_.InstanceName -replace '_\d+$','').ToUpperInvariant()
        $classes.ContainsKey($id) -and $classes[$id] -notmatch '4d36e972'
    }|Sort-Object InstanceName)
    if($devices.Count -eq 0){throw 'No devices expose the supported power-management property.'}
    return $devices
}
function Get-MitigationFields {
    $warnings=@();$policy=Get-ProcessMitigation -System -WarningAction SilentlyContinue -WarningVariable warnings
    if($warnings){throw ($warnings -join '; ')}
    if($null -eq $policy){throw 'System process mitigation policy is unavailable.'}
    $fields=[ordered]@{}
    foreach($group in $policy.PSObject.Properties|Sort-Object Name){
        if($null -eq $group.Value -or $group.Value.GetType().Namespace -ne 'Microsoft.Samples.PowerShell.Commands'){continue}
        foreach($field in $group.Value.PSObject.Properties|Sort-Object Name){
            $name=$group.Name+'.'+$field.Name
            if($field.Value -is [bool]){$fields[$name]=[bool]$field.Value}
            elseif($null -ne $field.Value -and [string]$field.Value -cin @('ON','OFF','NOTSET')){$fields[$name]=[string]$field.Value}
        }
    }
    if($fields.Count -eq 0){throw 'Windows returned no typed mitigation fields.'}
    return $fields
}
function Get-BootObject {
    $store=Invoke-CimMethod -Namespace root/wmi -ClassName BcdStore -MethodName OpenStore -Arguments @{File=''}
    if($store.ReturnValue -isnot [bool] -or -not $store.ReturnValue){throw 'BCD OpenStore did not succeed.'}
    $object=Invoke-CimMethod -InputObject $store.Store -MethodName OpenObject -Arguments @{Id='{fa926493-6f1c-4193-a414-58f0b2456d1e}'}
    if($object.ReturnValue -isnot [bool] -or -not $object.ReturnValue -or -not $object.Object.Id){throw 'The current BCD object could not be identified.'}
    return $object.Object
}
function Get-BootType($address){
    if($address.target -ne 'current'){throw 'Unknown boot object selection.'}
    switch($address.property){'disabledynamictick'{return [uint32]0x260000A5};'hypervisorlaunchtype'{return [uint32]0x250000F0};default{throw 'Unknown boot element.'}}
}
function Read-Control($address){
    $address=[pscustomobject]@{kind=$address.kind;target=$address.target;property=$address.property}
    $binding=$address.kind+':'+$address.target
    $value=$null
    $displayName=$null
    switch($address.kind){
        'firewall-profile' {
            if($address.property -ne 'enabled' -or $address.target -notin @('Domain','Private','Public')){throw 'An exact firewall profile is required.'}
            $profile=Get-NetFirewallProfile -Profile $address.target -PolicyStore PersistentStore
            $value=[string]$profile.Enabled
            if($value -notin @('True','False','NotConfigured')){throw 'The local firewall profile returned an unknown state.'}
            $effective=Get-NetFirewallProfile -Profile $address.target -PolicyStore ActiveStore
            $displayName=$address.target+' firewall: local '+$value+', effective '+[string]$effective.Enabled
        }
        'boot-configuration' {
            $type=Get-BootType $address;$object=Get-BootObject
            $elements=Invoke-CimMethod -InputObject $object -MethodName EnumerateElements
            if($elements.ReturnValue -isnot [bool] -or -not $elements.ReturnValue){throw 'BCD element enumeration failed; absence is unknown.'}
            $matches=@($elements.Elements|Where-Object {$_.Type -eq $type})
            if($matches.Count -gt 1){throw 'BCD element identity is ambiguous.'}
            if($matches.Count -eq 1){
                $read=Invoke-CimMethod -InputObject $object -MethodName GetElement -Arguments @{Type=$type}
                if($read.ReturnValue -isnot [bool] -or -not $read.ReturnValue){throw 'BCD element read failed.'}
                $value=if($address.property -eq 'disabledynamictick'){[bool]$read.Element.Boolean}else{[uint64]$read.Element.Integer}
            }
            $binding=$binding+':'+$object.Id+':'+$object.Type
        }
        'mitigations' {
            if($address.target -ne 'system' -or $address.property -ne 'policy'){throw 'Unknown mitigation policy target.'}
            $value=Get-MitigationFields
            $module=Get-Module ProcessMitigations
            if($null -eq $module -or -not $module.Path){throw 'The mitigation module identity is unavailable.'}
            $binding=$binding+':'+$module.Version+':'+(Get-FileHash -LiteralPath $module.Path -Algorithm SHA256).Hash
        }
        'defender' {
            if($address.target -ne 'system' -or $address.property -ne 'SubmitSamplesConsent'){throw 'Unknown Defender preference.'}
            $preference=Get-MpPreference
            if($null -eq $preference.SubmitSamplesConsent){throw 'The Defender preference is unavailable.'}
            $value=[int]$preference.SubmitSamplesConsent
        }
        'device-power' {
            if($address.target -ne 'non-network' -or $address.property -ne 'enabled'){throw 'Unknown power-device selection.'}
            $devices=@(Get-PowerDevices);$values=[ordered]@{}
            foreach($device in $devices){if($device.Enable -isnot [bool]){throw 'A power-management device returned an unknown value.'};$values[$device.InstanceName]=[bool]$device.Enable}
            $binding=$binding+':'+(($devices|ForEach-Object {$_.InstanceName}) -join '|');$value=$values
        }
        'dns-over-https' {
            if($address.property -ne 'configuration'){throw 'Unknown encrypted DNS control.'}
            $ip=([Net.IPAddress]::Parse($address.target)).ToString()
            if($script:BatchDoh){if($null -eq $script:DohServers){$script:DohServers=@(Get-DnsClientDohServerAddress)};$servers=$script:DohServers}else{$servers=Get-DnsClientDohServerAddress}
            $entries=@($servers|Where-Object {([Net.IPAddress]::Parse($_.ServerAddress)).ToString() -ceq $ip})
            if($entries.Count -gt 1){throw 'More than one encrypted DNS entry has this address.'}
            if($entries.Count -eq 1){$value=[ordered]@{template=[string]$entries[0].DohTemplate;allowFallback=[bool]$entries[0].AllowFallbackToUdp;autoUpgrade=[bool]$entries[0].AutoUpgrade}}
            $binding='dns-over-https:'+$ip
        }
        'teredo' {
            if($address.target -ne 'system' -or $address.property -ne 'type'){throw 'Unknown Teredo control.'}
            $config=@(Get-NetTeredoConfiguration -PolicyStore PersistentStore)
            if($config.Count -ne 1 -or $null -eq $config[0].Type){throw 'The persisted Teredo configuration is unavailable.'}
            $value=[string]$config[0].Type
        }
        'memory' {
            if($address.property -ne 'compression' -or $address.target -ne 'system'){throw 'Unknown memory setting.'}
            $agent=Get-MMAgent
            if($null -eq $agent -or $agent.MemoryCompression -isnot [bool]){throw 'The memory-compression state is unavailable.'}
            $value=[bool]$agent.MemoryCompression
        }
        'filesystem' {
            if($address.property -ne 'last-access' -or $address.target -ne 'ntfs'){throw 'Unknown file-system setting.'}
            $text=Invoke-SystemTool 'fsutil.exe' @('behavior','query','disablelastaccess')
            if($text -notmatch '=\s*([0-3])\b'){throw ('Could not read the NTFS last-access mode: '+$text)}
            $value=[int]$Matches[1]
        }
        'reserved-storage' {
            if($address.target -ne 'system' -or $address.property -ne 'enabled'){throw 'Unknown reserved-storage setting.'}
            $state=[string](Get-WindowsReservedStorageState).ReservedStorageState
            if($state -notin @('Enabled','Disabled')){throw ('Reserved storage has an unresolved state: '+$state)}
            $value=$state -eq 'Enabled'
        }
        'windows-feature' {
            if($address.property -ne 'enabled' -or $address.target -match '[*?\\/]'){throw 'An exact Windows feature name is required.'}
            $feature=Get-WindowsOptionalFeature -Online -FeatureName $address.target
            if($feature.State -notin @('Enabled','Disabled','DisabledWithPayloadRemoved')){throw ('Windows feature state requires a restart or servicing recovery: '+$feature.State)}
            $value=[string]$feature.State
            $binding=$binding+':'+$feature.FeatureName
        }
        'network-adapter' {
            $adapters=@(Get-Adapters $address.target);$values=[ordered]@{}
            $address.target='interfaces:'+(($adapters|ForEach-Object {([guid]$_.InterfaceGuid).ToString('D')}) -join ';')
            foreach($adapter in $adapters){
                $id=([string]$adapter.InterfaceGuid).ToUpperInvariant()
                switch($address.property){
                    'ipv6-binding' {$item=@(Get-NetAdapterBinding -Name ([WildcardPattern]::Escape([string]$adapter.Name)) -ComponentID 'ms_tcpip6');if($item.Count -ne 1 -or $item[0].Enabled -isnot [bool]){throw ('IPv6 binding is unavailable for '+$adapter.Name)};$values[$id]=[bool]$item[0].Enabled}
                    'lso' {$item=@(Get-NetAdapterLso -Name ([WildcardPattern]::Escape([string]$adapter.Name)) -WarningAction SilentlyContinue -WarningVariable controlWarnings -ErrorAction SilentlyContinue -ErrorVariable controlErrors); if($controlWarnings){throw ($controlWarnings -join '; ')}; Assert-AdapterExposes $controlErrors $item.Count 'LSO' $adapter; if($item.Count -ne 1 -or $item[0].V1IPv4Enabled -isnot [bool] -or $item[0].IPv4Enabled -isnot [bool] -or $item[0].IPv6Enabled -isnot [bool]){throw ('LSO configuration is unavailable for '+$adapter.Name)}; $item=$item[0]; $values[$id]=[ordered]@{ipv4v1=[bool]$item.V1IPv4Enabled;ipv4=[bool]$item.IPv4Enabled;ipv6=[bool]$item.IPv6Enabled}}
                    'rsc' {$item=@(Get-NetAdapterRsc -Name ([WildcardPattern]::Escape([string]$adapter.Name)) -WarningAction SilentlyContinue -WarningVariable controlWarnings -ErrorAction SilentlyContinue -ErrorVariable controlErrors); if($controlWarnings){throw ($controlWarnings -join '; ')}; Assert-AdapterExposes $controlErrors $item.Count 'RSC' $adapter; if($item.Count -ne 1 -or $item[0].IPv4Enabled -isnot [bool] -or $item[0].IPv6Enabled -isnot [bool]){throw ('RSC configuration is unavailable for '+$adapter.Name)}; $item=$item[0]; $values[$id]=[ordered]@{ipv4=[bool]$item.IPv4Enabled;ipv6=[bool]$item.IPv6Enabled}}
                    default {
                        if(-not $address.property.StartsWith('advanced:')){throw 'Unknown network-adapter setting.'}
                        $keyword=$address.property.Substring(9)
                        $item=Get-NetAdapterAdvancedProperty -Name ([WildcardPattern]::Escape([string]$adapter.Name)) -RegistryKeyword $keyword -AllProperties -ErrorAction SilentlyContinue -ErrorVariable controlErrors
                        Assert-AdapterExposes $controlErrors @($item).Count $keyword $adapter
                        if(@($item).Count -ne 1){throw ('The adapter does not expose exactly one '+$keyword+' property: '+$adapter.Name)}
                        $values[$id]=@($item.RegistryValue | ForEach-Object {[string]$_})
                    }
                }
            }
            $binding=$address.kind+':'+$address.target+':'+(($adapters | ForEach-Object {([string]$_.InterfaceGuid).ToUpperInvariant()+':'+$_.PnPDeviceID+':'+$_.DriverVersion+':'+$_.InterfaceDescription}) -join '|')
            $value=$values
        }
        'firewall-blocklist' {
            if($address.property -ne 'rule' -or $address.target -notmatch '^RooIndustries-Block-[a-f0-9]{16,32}$'){throw 'An exact firewall rule identity from this app is required.'}
            $policy=New-Object -ComObject HNetCfg.FwPolicy2
            $rules=@($policy.Rules | Where-Object {$_.Name -ceq $address.target})
            if($rules.Count -gt 1){throw 'More than one firewall rule uses this identity.'}
            if($rules.Count -eq 1){
                $rule=$rules[0]
                if($rule.Grouping -cne 'Roo Industries' -or $rule.Direction -ne 2 -or $rule.Action -ne 0 -or $rule.Protocol -ne 256 -or $rule.Profiles -ne 2147483647 -or $rule.ApplicationName -or $rule.ServiceName -or $rule.LocalAddresses -ne '*' -or $rule.InterfaceTypes -ne 'All' -or $rule.Interfaces){throw 'This firewall rule no longer matches its recorded scope.'}
                $addresses=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
                foreach($remote in ([string]$rule.RemoteAddresses).Split(',')){$null=$addresses.Add((Get-CanonicalAddress $remote))}
                $value=[ordered]@{enabled=[bool]$rule.Enabled;addresses=[string[]]@($addresses)}
            }
        }
        default {throw ('Unknown Windows control kind: '+$address.kind)}
    }
    return [ordered]@{address=$address;identity=($address.kind+':'+$address.target+':'+$address.property);binding=$binding;value=$value;displayName=$displayName}
}
function Write-Control($address,$value){
    switch($address.kind){
        'firewall-profile' {
            if($address.property -ne 'enabled' -or $address.target -notin @('Domain','Private','Public') -or $value -notin @('True','False','NotConfigured')){throw 'Unknown firewall profile choice.'}
            Set-NetFirewallProfile -Profile $address.target -PolicyStore PersistentStore -Enabled $value
        }
        'boot-configuration' {
            $type=Get-BootType $address;$object=Get-BootObject
            if($null -eq $value){$result=Invoke-CimMethod -InputObject $object -MethodName DeleteElement -Arguments @{Type=$type}}
            elseif($address.property -eq 'disabledynamictick'){$result=Invoke-CimMethod -InputObject $object -MethodName SetBooleanElement -Arguments @{Type=$type;Boolean=[bool]$value}}
            else {
                if($value -notin @(0,1)){throw 'Invalid hypervisor launch type.'}
                $result=Invoke-CimMethod -InputObject $object -MethodName SetIntegerElement -Arguments @{Type=$type;Integer=[uint64]$value}
            }
            if($result.ReturnValue -isnot [bool] -or -not $result.ReturnValue){throw 'BCD setter did not succeed.'}
        }
        'mitigations' { throw 'System mitigation writes require the native registry transaction.' }
        'defender' {
            if($value -notin @(0,1,2,3)){throw 'Invalid sample-submission choice.'}
            Set-MpPreference -SubmitSamplesConsent ([int]$value)
        }
        'device-power' {
            foreach($device in @(Get-PowerDevices)){
                $id=$device.InstanceName
                $desired=if($null -ne $value -and $value.PSObject.Properties.Name -contains $id){$value.$id}else{$value}
                if($desired -isnot [bool]){throw 'A Boolean power-management value is required.'}
                Set-CimInstance -InputObject $device -Property @{Enable=[bool]$desired}|Out-Null
            }
        }
        'dns-over-https' {
            $ip=([Net.IPAddress]::Parse($address.target)).ToString()
            $entries=@(Get-DnsClientDohServerAddress|Where-Object {([Net.IPAddress]::Parse($_.ServerAddress)).ToString() -ceq $ip})
            if($null -eq $value){if($entries.Count -eq 1){Remove-DnsClientDohServerAddress -InputObject $entries[0] -Confirm:$false};return}
            $uri=[Uri]$value.template
            if($uri.Scheme -ne 'https' -or $value.allowFallback -isnot [bool] -or $value.autoUpgrade -isnot [bool]){throw 'Invalid encrypted DNS configuration.'}
            $parameters=@{DohTemplate=[string]$value.template;AllowFallbackToUdp=[bool]$value.allowFallback;AutoUpgrade=[bool]$value.autoUpgrade}
            if($entries.Count -eq 1){Set-DnsClientDohServerAddress -InputObject $entries[0] @parameters}
            else {Add-DnsClientDohServerAddress -ServerAddress $ip @parameters}
        }
        'teredo' {
            if($value -notin @('Default','Disabled','Client','EnterpriseClient','Server')){throw 'Unknown Teredo type.'}
            Set-NetTeredoConfiguration -PolicyStore PersistentStore -Type ([string]$value)
        }
        'memory' {
            $startup=(Get-Service -Name SysMain).StartType
            if($value -and $startup -eq 'Disabled'){throw 'Memory compression requires SysMain startup to remain enabled.'}
            try{if($value){Enable-MMAgent -MemoryCompression}else{Disable-MMAgent -MemoryCompression}}
            finally{if((Get-Service -Name SysMain).StartType -ne $startup){Set-Service -Name SysMain -StartupType $startup}}
        }
        'filesystem' {
            if($value -notin @(0,1,2,3)){throw 'Invalid NTFS last-access mode.'}
            $null=Invoke-SystemTool 'fsutil.exe' @('behavior','set','disablelastaccess',[string]$value)
        }
        'reserved-storage' {Set-WindowsReservedStorageState -State $(if($value){'Enabled'}else{'Disabled'})|Out-Null}
        'windows-feature' {
            if($value -eq 'Enabled'){$result=Enable-WindowsOptionalFeature -Online -FeatureName $address.target -NoRestart}
            elseif($value -eq 'Disabled'){$result=Disable-WindowsOptionalFeature -Online -FeatureName $address.target -NoRestart}
            elseif($value -eq 'DisabledWithPayloadRemoved'){$result=Disable-WindowsOptionalFeature -Online -FeatureName $address.target -Remove -NoRestart}
            else {throw 'Invalid Windows feature state.'}
            if($result.RestartNeeded){throw 'Windows servicing requires a restart to finish this change; recovery remains recorded.'}
        }
        'network-adapter' {
            foreach($adapter in @(Get-Adapters $address.target)){
                $id=([string]$adapter.InterfaceGuid).ToUpperInvariant()
                $desired=if($null -ne $value -and $value.PSObject.Properties.Name -contains $id){$value.$id}else{$value}
                switch($address.property){
                    'ipv6-binding' {if($desired){Enable-NetAdapterBinding -Name ([WildcardPattern]::Escape([string]$adapter.Name)) -ComponentID 'ms_tcpip6'}else{Disable-NetAdapterBinding -Name ([WildcardPattern]::Escape([string]$adapter.Name)) -ComponentID 'ms_tcpip6'}}
                    'lso' {Set-NetAdapterLso -Name ([WildcardPattern]::Escape([string]$adapter.Name)) -V1IPv4Enabled ([bool]$desired.ipv4v1) -IPv4Enabled ([bool]$desired.ipv4) -IPv6Enabled ([bool]$desired.ipv6) -NoRestart}
                    'rsc' {Set-NetAdapterRsc -Name ([WildcardPattern]::Escape([string]$adapter.Name)) -IPv4Enabled ([bool]$desired.ipv4) -IPv6Enabled ([bool]$desired.ipv6) -NoRestart}
                    default {Set-NetAdapterAdvancedProperty -Name ([WildcardPattern]::Escape([string]$adapter.Name)) -RegistryKeyword $address.property.Substring(9) -RegistryValue @($desired) -NoRestart}
                }
            }
        }
        'firewall-blocklist' {
            $policy=New-Object -ComObject HNetCfg.FwPolicy2
            if($null -eq $value){$policy.Rules.Remove($address.target);return}
            if(@($policy.Rules|Where-Object {$_.Name -ceq $address.target}).Count -gt 0){throw 'Restore the existing block rule before replacing its contents.'}
            $rule=New-Object -ComObject HNetCfg.FWRule
            $rule.Name=$address.target;$rule.Grouping='Roo Industries';$rule.Description='Roo Industries selected address block list'
            $rule.Direction=2;$rule.Action=0;$rule.Protocol=256;$rule.Profiles=2147483647
            $rule.LocalAddresses='*';$rule.RemoteAddresses=@($value.addresses) -join ',';$rule.InterfaceTypes='All';$rule.Enabled=[bool]$value.enabled
            $policy.Rules.Add($rule)
        }
        default {throw ('Unknown Windows control kind: '+$address.kind)}
    }
}
try {
    $request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:ROO_INDUSTRIES_CONTROL_REQUEST))|ConvertFrom-Json
    if($request.action -eq 'read-batch'){
        $script:BatchDoh=$true;$index=0
        foreach($item in @($request.addresses)){
            $text=try{(Read-Control $item)|ConvertTo-Json -Compress -Depth 30}catch{@{error=$_.Exception.Message}|ConvertTo-Json -Compress}
            [Console]::Out.WriteLine('ROO_INDUSTRIES_CONTROL '+$index+' '+$text);[Console]::Out.Flush();$index++
        }
        exit 0
    }
    if($request.action -eq 'restore-points'){
        $points=@(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction Stop|ForEach-Object {
            [ordered]@{sequence=[uint32]$_.SequenceNumber;description=[string]$_.Description;createdAtUtc=[Management.ManagementDateTimeConverter]::ToDateTime([string]$_.CreationTime).ToUniversalTime().ToString('o')}
        })
        [Console]::Out.Write((ConvertTo-Json -InputObject $points -Compress -Depth 5));exit 0
    }
    $current=Read-Control $request.address
    if($request.action -eq 'write'){
        $expected=[ordered]@{address=$request.before.address;identity=$request.before.identity;binding=$request.before.binding;value=$request.before.value}
        $observed=[ordered]@{address=$current.address;identity=$current.identity;binding=$current.binding;value=$current.value}
        if(($observed|ConvertTo-Json -Compress -Depth 30) -cne ($expected|ConvertTo-Json -Compress -Depth 30)){throw 'The Windows control changed after review.'}
        $null=Write-Control $request.address $request.after
        $current=Read-Control $request.address
    } elseif($request.action -ne 'read'){throw 'Unknown Windows control action.'}
    [Console]::Out.Write(($current|ConvertTo-Json -Compress -Depth 30))
} catch { [Console]::Out.Write((@{error=$_.Exception.Message}|ConvertTo-Json -Compress));exit 0 }
