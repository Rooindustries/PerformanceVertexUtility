param([string]$PythonPath = $env:ROO_PYTHON_EXE)
$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
if ([string]::IsNullOrWhiteSpace($PythonPath)) {
    foreach ($name in @('python3', 'python.exe', 'python')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source -and $command.Source -notmatch 'Microsoft\\WindowsApps') { $PythonPath = $command.Source; break }
    }
}
if ([string]::IsNullOrWhiteSpace($PythonPath)) { throw 'Install Python 3.10+ with tools/validation/requirements.txt, or set ROO_PYTHON_EXE to the validation interpreter.' }
& $PythonPath (Join-Path $repoRoot 'tools\validation\check_baseline.py') --contracts-only
if ($LASTEXITCODE -ne 0) { throw "JSON Schema validation failed with exit code $LASTEXITCODE." }
