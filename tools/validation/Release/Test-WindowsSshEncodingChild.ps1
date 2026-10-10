param([switch]$Fail)
$text='middot '+[char]0x00B7+' arrow '+[char]0x2192+' pound '+[char]0x00A3+' accent '+[char]0x00E9
Write-Output ('PASS native child '+$text)
if($Fail){Write-Output ('FATAL native child '+$text);exit 17}
