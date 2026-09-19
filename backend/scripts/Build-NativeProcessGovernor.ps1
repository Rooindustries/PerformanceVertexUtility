param(
    [string]$OutputPath = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

try {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $sourcePath = Join-Path $repoRoot 'backend\native\ProcessGovernor\RooIndustriesProcessGovernor.cs'
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Native process governor source file was not found: $sourcePath"
    }

    $defaultOutputPath = Join-Path $repoRoot 'backend\bin\RooIndustriesProcessGovernor.exe'
    $resolvedOutputPath = Resolve-RooIndustriesPath $OutputPath $defaultOutputPath
    if ((Test-Path -LiteralPath $resolvedOutputPath) -and -not $Force) {
        $source = Get-Item -LiteralPath $sourcePath
        $existing = Get-Item -LiteralPath $resolvedOutputPath
        if ($existing.LastWriteTimeUtc -ge $source.LastWriteTimeUtc) {
            $result = [pscustomobject]@{
                actionId = 'performance.nativeGovernor.build'
                schemaVersion = 1
                productName = $script:RooIndustriesProcessProductName
                status = 'upToDate'
                sourcePath = $sourcePath
                outputPath = $resolvedOutputPath
                compilerPath = $null
                toolchain = 'csc-dotnet-framework'
                workerClassification = 'managed-csc'
                workerIsTrueNative = $false
                serviceInstalled = $false
                serviceInstallActionPerformed = $false
            }
            Write-RooIndustriesJsonOutput $result ''
            exit 0
        }
    }

    $framework64Csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $frameworkCsc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    $cscPath = if (Test-Path -LiteralPath $framework64Csc) { $framework64Csc } elseif (Test-Path -LiteralPath $frameworkCsc) { $frameworkCsc } else { $null }
    if (-not $cscPath) {
        throw 'No built-in .NET Framework csc.exe compiler was found.'
    }

    Ensure-RooIndustriesDirectory (Split-Path $resolvedOutputPath -Parent)
    $compilerOutput = & $cscPath /nologo /optimize+ /target:exe /platform:x64 /out:$resolvedOutputPath /reference:System.Web.Extensions.dll $sourcePath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "csc.exe failed with exit code $LASTEXITCODE :: $($compilerOutput -join ' ')"
    }

    $result = [pscustomobject]@{
        actionId = 'performance.nativeGovernor.build'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        status = 'built'
        sourcePath = $sourcePath
        outputPath = $resolvedOutputPath
        compilerPath = $cscPath
        toolchain = 'csc-dotnet-framework'
        workerClassification = 'managed-csc'
        workerIsTrueNative = $false
        nativeAot = $false
        serviceInstalled = $false
        serviceInstallActionPerformed = $false
        compilerOutput = @($compilerOutput)
    }
    Write-RooIndustriesJsonOutput $result ''
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.nativeGovernor.build'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        status = 'failed'
        outputPath = $OutputPath
        errors = @((New-RooIndustriesIssue 'NATIVE_GOVERNOR_BUILD_FAILED' $_.Exception.Message 'error' 'performance.nativeGovernor' $OutputPath $true 'Check csc.exe availability and source parser errors.' $null))
    }
    Write-RooIndustriesJsonOutput $errorResult ''
    exit 1
}
