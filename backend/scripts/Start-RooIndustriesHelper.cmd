@echo off
setlocal DisableDelayedExpansion
set RANDOM=
call :clear
call :clear
for %%p in (DOTNET_ COMPlus_ CORECLR_ COR_ COREHOST_) do set %%p>nul 2>&1 & if not errorlevel 1 exit /b 91
set DOTNET_EnableDiagnostics=0
set COMPlus_EnableDiagnostics=0
set DOTNET_EnableDiagnostics_IPC=0
set COMPlus_EnableDiagnostics_IPC=0
set DOTNET_EnableDiagnostics_Debugger=0
set COMPlus_EnableDiagnostics_Debugger=0
set DOTNET_EnableDiagnostics_Profiler=0
set COMPlus_EnableDiagnostics_Profiler=0
set "P1="&set "P2="&set "P3="&set "P4="
for /f "tokens=2-5 delims=?" %%a in ("%~1") do set "P1=%%a"&set "P2=%%b"&set "P3=%%c"&set "P4=%%d"
if not defined P1 exit /b 87
if defined P4 ("%P1%" "%P2%" "%P3%" "%P4%") else if defined P3 ("%P1%" "%P2%" "%P3%") else if defined P2 ("%P1%" "%P2%") else ("%P1%")
exit /b
:clear
for %%p in (DOTNET_ COMPlus_ CORECLR_ COR_ COREHOST_) do set %%p>nul 2>&1 & if not errorlevel 1 goto list
exit /b
:list
set "RooIndustriesHelperList=%~dp0RooIndustriesHelperEnvironment-%RANDOM%%RANDOM%.txt"
(for %%p in (DOTNET_ COMPlus_ CORECLR_ COR_ COREHOST_) do set %%p) 2>nul >"%RooIndustriesHelperList%"
(for /f "usebackq delims==" %%v in ("%RooIndustriesHelperList%") do set "%%v=") 2>nul & del "%RooIndustriesHelperList%" >nul 2>&1
exit /b
