@echo off
setlocal DisableDelayedExpansion
set DOTNET_STARTUP_HOOKS=
set DOTNET_ADDITIONAL_DEPS=
set DOTNET_SHARED_STORE=
set CORECLR_ENABLE_PROFILING=
set CORECLR_PROFILER=
set CORECLR_PROFILER_PATH=
set CORECLR_PROFILER_PATH_32=
set CORECLR_PROFILER_PATH_64=
set CORECLR_PROFILER_PATH_ARM64=
set COR_ENABLE_PROFILING=
set COR_PROFILER=
set COR_PROFILER_PATH=
set COR_PROFILER_PATH_32=
set COR_PROFILER_PATH_64=
set "P1="&set "P2="&set "P3="&set "P4="
for /f "tokens=2-5 delims=?" %%a in ("%~1") do set "P1=%%a"&set "P2=%%b"&set "P3=%%c"&set "P4=%%d"
if not defined P1 exit /b 87
if defined P4 ("%P1%" "%P2%" "%P3%" "%P4%") else if defined P3 ("%P1%" "%P2%" "%P3%") else if defined P2 ("%P1%" "%P2%") else ("%P1%")
exit /b %ERRORLEVEL%
