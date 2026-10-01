#!/usr/bin/env bash
# Linux-side driver for the release verification on a Windows test PC. Every step runs a named phase of
# tools/validation/Release/Invoke-IntegrationVerification.ps1 (or another named script), keeps its log under
# $OUT, and the whole sequence is repeatable: Run-FinalVerification.sh all
# usage: Run-FinalVerification.sh <step> [arguments]
#   steps: stage | phase <name> [runner arguments] | gi <phase> | screens | reboot | fetch <remote> <local> |
#          lifecycle | upgrade-path | ui | all
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOST="${HOST:-optimizer-9070}"
MACHINE="${MACHINE:-SERVI-WINDOWS-D}"
OUT="${OUT:-$ROOT/artifacts/final-run/9070}"
PY="${PY:-python3}"
STAGE="${STAGE:-roo-industries-final-run}"
TASK="${TASK:-RooIndustries_VerifyRun}"
OLD_INSTALLER="${OLD_INSTALLER:-}"
WINUSER="${WINUSER:-servi windows box}"
WINTEMP="C:\\Users\\$WINUSER\\AppData\\Local\\Temp"
REMOTE_STAGE="$WINTEMP\\$STAGE"
REMOTE_INSTALLERS="$WINTEMP\\roo-industries-installers"
REMOTE_RELEASE="$WINTEMP\\roo-industries-release"
mkdir -p "$OUT/runner" "$OUT/suites" "$OUT/lifecycle" "$OUT/screens" "$OUT/installer"

winps() { "$PY" "$ROOT/tools/validation/windows_ssh.py" --host "$HOST" --expected-machine "$MACHINE" run "$1"; }
winps_text() { local f; f="$(mktemp /tmp/roo-industries-ps-XXXX.ps1)"; printf '%s\n' "$1" > "$f"; winps "$f" 2>&1 | grep -av '^<Objs\|^#< CLIXML'; rm -f "$f"; }

stage() {
  winps_text "\$p=Join-Path ([IO.Path]::GetTempPath()) '$STAGE'; if(Test-Path -LiteralPath \$p){\$e=\$p+'-empty';[IO.Directory]::CreateDirectory(\$e)|Out-Null;& robocopy.exe \$e \$p /MIR /NFL /NDL /NJH /NJS /NP|Out-Null;Remove-Item -LiteralPath \$p -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath \$e -Recurse -Force -ErrorAction SilentlyContinue}; 'cleaned'" > /dev/null
  "$PY" "$ROOT/tools/validation/windows_ssh.py" --host "$HOST" --expected-machine "$MACHINE" upload --directory "$STAGE" --include-frontend > "$OUT/stage.json"
  echo "staged $STAGE at $(git -C "$ROOT" rev-parse --short HEAD)"
}

interactive() {
  local directory="$1" script="$2" minutes="$3" log="$4"; shift 4
  local arguments="$*" file; file="$(mktemp /tmp/roo-industries-interactive-XXXX.ps1)"
  cat > "$file" <<PS
\$ProgressPreference='SilentlyContinue'
\$user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
\$W=Join-Path ([IO.Path]::GetTempPath()) '$STAGE\\$directory'
\$Script='$script'
\$done=Join-Path \$W (\$Script+'.done'); Remove-Item \$done -ErrorAction SilentlyContinue
\$log=Join-Path \$W (\$Script+'.log'); Remove-Item \$log -ErrorAction SilentlyContinue
\$task='$TASK'
if(Get-ScheduledTask -TaskName \$task -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName \$task -Confirm:\$false}
\$inner="& { try { & '"+(Join-Path \$W \$Script)+"' $arguments *>&1 | Out-File -FilePath '"+\$log+"' -Encoding utf8 -Width 400 } catch { \`\$_ | Out-String | Out-File -FilePath '"+\$log+"' -Append -Encoding utf8 } finally { 'x' | Set-Content '"+\$done+"' } }"
\$enc=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(\$inner))
\$a=New-ScheduledTaskAction -Execute 'C:\\Windows\\System32\\conhost.exe' -Argument ('--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+\$enc) -WorkingDirectory \$W
\$pr=New-ScheduledTaskPrincipal -UserId \$user -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName \$task -Action \$a -Principal \$pr -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes ($minutes+5)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 4) -Force|Out-Null
Start-ScheduledTask -TaskName \$task
\$deadline=(Get-Date).AddMinutes($minutes)
while((Get-Date) -lt \$deadline -and -not (Test-Path \$done)){Start-Sleep 3}
"RESULT done=\$(Test-Path \$done) lastResult=\$((Get-ScheduledTaskInfo -TaskName \$task).LastTaskResult)"
if(-not (Test-Path \$done)){Stop-ScheduledTask -TaskName \$task -ErrorAction SilentlyContinue}
Unregister-ScheduledTask -TaskName \$task -Confirm:\$false
Get-Content \$log -ErrorAction SilentlyContinue
PS
  winps "$file" 2>&1 | grep -av '^<Objs\|^#< CLIXML' | sed 's/\r$//' > "$log"
  rm -f "$file"
  grep -a '^RESULT done' "$log" | head -1
}

phase() {
  local name="$1"; shift
  local log="$OUT/runner/$(date -u +%H%M%S)-$name.log" minutes="${MINUTES:-60}"
  interactive 'tools\validation\Release' 'Invoke-IntegrationVerification.ps1' "$minutes" "$log" -Phase "$name" -Source "'$REMOTE_STAGE'" "$@"
  echo "$log"; echo "FAIL lines: $(grep -ac '^[^ ]* FAIL ' "$log")"
}

script() {
  local directory="$1" name="$2" minutes="$3" log="$OUT/suites/$2-$(date -u +%H%M%S).log"; shift 3
  interactive "$directory" "$name" "$minutes" "$log" "$@"
  echo "$log"; echo "FAIL lines: $(grep -ac '^FAIL ' "$log")"
}

gi() {
  local label="$1"; shift
  winps_text "& '$REMOTE_STAGE\\tools\\validation\\Governor\\Test-GovernorInstalled.ps1' -Phase $* " | tee "$OUT/lifecycle/$label.json" | grep -a '^\(PASS\|FAIL\)'
}

screen() {
  local name="$1" page="${2:-Games}"
  local log="$OUT/screens/$name.log"
  interactive 'tools\validation\Governor' 'Capture-GovernorUi.ps1' 3 "$log" -Name "$name" -Page "'$page'"
  grep -a 'GovernorStatus\|GovernorDetail\|Pause enabled\|Page texts' "$log" | head -4
  winps_text "[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path ([IO.Path]::GetTempPath()) 'roo-industries-governor-ui\\shot-$name.png')))" | tail -1 | base64 -d > "$OUT/screens/$name.png"
  ls -la "$OUT/screens/$name.png" | awk '{print $5, $9}'
}

reboot_wait() {
  local before after
  before="$(winps_text '(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("o")' | tail -1)"
  winps_text 'Restart-Computer -Force' > /dev/null 2>&1 || true
  sleep 45
  for _ in $(seq 1 90); do
    after="$(winps_text '$b=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("o"); $e=@(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -ge 1).Count; "$b|$e"' 2>/dev/null | tail -1)" || true
    if [[ "$after" == *"|"* && "${after%%|*}" != "$before" && "${after##*|}" -ge 1 ]]; then sleep 60; echo "rebooted: $before -> ${after%%|*}"; return 0; fi
    sleep 10
  done
  echo "the PC did not come back with a desktop session"; return 1
}

fetch() {
  local remote="$1" local_dir="$2"; mkdir -p "$local_dir"
  scp -o BatchMode=yes -o ProxyCommand=none -o ProxyJump=none -r "$HOST:${remote//\\//}" "$local_dir/"
}

upload() { scp -o BatchMode=yes -o ProxyCommand=none -o ProxyJump=none "$1" "$HOST:${2//\\//}"; }

giui() {
  local label="$1" phase_name="$2"
  interactive 'tools\validation\Governor' 'Test-GovernorInstalled.ps1' 5 "$OUT/lifecycle/$label.json" -Phase "$phase_name"
}

governor_task_state() {
  winps_text "Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' | ForEach-Object { \$_.$1 }" | head -1
}

worker_action() {
  winps_text ". 'C:\\Program Files\\Roo Industries\\Optimization Suite\\backend\\scripts\\BrandCompatibility.Common.ps1'; \$root=Join-Path (Get-RooIndustriesLocalDataRoot) 'process-rules'; & 'C:\\Program Files\\Roo Industries\\Optimization Suite\\backend\\scripts\\Invoke-ProcessPolicyWorker.ps1' -Action $1 -PolicyRoot \$root -ConfirmApply" | tail -3 | cut -c1-300
}

lifecycle() {
  local new="$1"
  phase uninstall
  phase install-other -OtherInstaller "'$new'" -Label fresh
  gi create-rule create-rule
  gi verify-running-1 verify-running
  gi measure measure
  screen governor-running Games
  winps_text "Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' | Disable-ScheduledTask | Out-Null; 'disabled'"
  screen governor-task-disabled Games
  winps_text "Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' | Enable-ScheduledTask | Out-Null; 'enabled'"
  winps_text ". 'C:\\Program Files\\Roo Industries\\Optimization Suite\\backend\\scripts\\BrandCompatibility.Common.ps1'; \$r=Join-Path (Get-RooIndustriesLocalDataRoot) 'process-rules\\rules'; [IO.File]::WriteAllText((Join-Path \$r 'roo-industries-damaged-check.json'),'{ this is not a rule'); 'damaged rule written'"
  screen governor-damaged-rule Games
  winps_text ". 'C:\\Program Files\\Roo Industries\\Optimization Suite\\backend\\scripts\\BrandCompatibility.Common.ps1'; Remove-Item (Join-Path (Get-RooIndustriesLocalDataRoot) 'process-rules\\rules\\roo-industries-damaged-check.json') -Force; 'damaged rule removed'"
  screen governor-undo-row 'Undo changes'
  giui app-cycle app-cycle
  reboot_wait
  gi verify-running-after-reboot verify-running
  MINUTES=30 phase scenario -Scenario launchers-session
  gi new-probe-after-reboot new-probe
  gi pause pause
  reboot_wait
  gi verify-paused-after-reboot verify-paused
  worker_action Resume
  gi verify-running-resumed verify-running
  gi record record
  phase install-other -OtherInstaller "'$new'" -Label reinstall
  gi verify-replaced verify-replaced
  gi new-probe-before-uninstall new-probe
  phase uninstall
  gi verify-removed verify-removed
  phase install-other -OtherInstaller "'$new'" -Label reinstall-resumes
  gi verify-running-after-reinstall verify-running
  gi cleanup cleanup
}

step="${1:-}"; shift || true
case "$step" in
  stage) stage ;;
  phase) phase "$@" ;;
  gi) gi "$@" ;;
  script) script "$@" ;;
  screen) screen "$@" ;;
  reboot) reboot_wait ;;
  fetch) fetch "$@" ;;
  upload) upload "$@" ;;
  giui) giui "$@" ;;
  lifecycle) lifecycle "$@" ;;
  *) echo "usage: $0 stage | phase <name> [runner arguments] | gi <label> <phase> | screen <name> [page] | reboot | fetch <remote> <local dir> | upload <local file> <remote path>"; exit 2 ;;
esac
