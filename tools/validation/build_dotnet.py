import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
EXCLUDED = {
    'docs/internal/frontend/RooIndustries.OptimizationSuite.App/RooIndustries.OptimizationSuite.App.csproj': 'WinUI XAML compilation runs only on Windows; tools/scripts/Build-Frontend.ps1 builds it there.',
    'tools/validation/Release/ReleaseHostFixture/ReleaseHostFixture.csproj': 'Each scenario builds it with its own -p:FixtureProgram source.',
    'tools/validation/BugReportE2E/applog/Roo70LogProof.csproj': 'Requires the original-frame RooIndustriesBindingFile; Invoke-BugReportE2E.ps1 builds the selected native scenario explicitly.',
    'tools/validation/BugReportE2E/desktop/RenderedBugReport.csproj': 'Requires the original-frame RooIndustriesBindingFile and Windows WinUI; Invoke-BugReportE2E.ps1 builds the selected native scenario explicitly.',
}


def main():
    listed = subprocess.check_output(['git', 'ls-files', '-z', '--', '*.csproj'], cwd=ROOT).decode()
    projects = [project for project in listed.split('\0') if project]
    failures = [f'{project}: excluded project is no longer tracked' for project in EXCLUDED if project not in projects]
    dotnet = os.environ.get('DOTNET', 'dotnet')
    built = 0
    for project in projects:
        if project in EXCLUDED:
            print(f'skip {project}: {EXCLUDED[project]}')
            continue
        result = subprocess.run([dotnet, 'build', project, '--configuration', 'Release', '-p:EnableWindowsTargeting=true', '-nologo', '-verbosity:quiet'], cwd=ROOT, capture_output=True, text=True)
        built += 1
        if result.returncode:
            failures.append(f'{project}: build failed')
            print(f'FAILED {project}\n{result.stdout}{result.stderr}')
        else:
            print(f'ok {project}')
    for failure in failures:
        print(failure)
    print(f'.NET build: {built} projects built, {len(EXCLUDED)} excluded, {len(failures)} failures')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
