param([string]$PythonPath=$env:ROO_INDUSTRIES_PYTHON_EXE)
$ErrorActionPreference='Stop'
if(-not $PythonPath){
    foreach($name in @('python3','python.exe','python')){
        $command=Get-Command $name -ErrorAction SilentlyContinue
        if($command -and $command.Source -and $command.Source -notmatch 'Microsoft\\WindowsApps'){$PythonPath=$command.Source;break}
    }
}
if(-not $PythonPath){throw 'Set ROO_INDUSTRIES_PYTHON_EXE to the validation Python interpreter.'}
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
& $PythonPath (Join-Path $root 'tools\validation\test_storage_measurement.py')
exit $LASTEXITCODE
