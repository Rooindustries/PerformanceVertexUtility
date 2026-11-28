#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOST="${HOST:?Set the authorized SSH alias}"
MACHINE="${MACHINE:?Set the expected COMPUTERNAME}"
OUT="${OUT:?Set a run-specific local evidence directory}"
PY="${PY:-python3}"
OLD_INSTALLER="${OLD_INSTALLER:-}"
mkdir -p "$OUT/runner" "$OUT/suites" "$OUT/lifecycle" "$OUT/screens" "$OUT/installer"

winps() { "$PY" "$ROOT/tools/validation/windows_ssh.py" --host "$HOST" --expected-machine "$MACHINE" run "$1"; }
ps_literal() { "$PY" -c "import sys; print(\"'\" + sys.argv[1].replace(\"'\",\"''\") + \"'\")" "$1"; }
winps_text() { local f status=0; f="$(mktemp /tmp/roo-industries-ps-XXXX.ps1)"; printf '%s\n' "$1" > "$f"; winps "$f" 2>&1 | sed '/^<Objs/d; /^#< CLIXML/d; s/\r$//' || status=$?; rm -f "$f"; return "$status"; }
field() { "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$OUT/stage.json" "$1"; }
args_json() {
  "$PY" - "$@" <<'PY'
import json,sys
values=sys.argv[1:]; result={}
while values:
    key=values.pop(0)
    if not key.startswith('-'): raise SystemExit('Expected a parameter name: '+key)
    if any(existing.casefold()==key[1:].casefold() for existing in result): raise SystemExit('Duplicate parameter: '+key)
    result[key[1:]]=values.pop(0) if values and not values[0].startswith('-') else True
print(json.dumps(result))
PY
}
load_run() {
  [[ -f "$OUT/stage.json" ]] || { echo 'Missing explicit source/run receipt; stage a fresh frame first.' >&2; return 1; }
  REMOTE_STAGE="$(field stagingPath)"; RUN_ROOT="$(field runRoot)"; MANIFEST_SHA="$(field manifestSha256)"; FRAME_ID="$(field frameId)"
  [[ "$(field machine)" == "$MACHINE" ]] || { echo 'Source receipt belongs to another machine.' >&2; return 1; }
  REMOTE_EVIDENCE="$RUN_ROOT\evidence"; REMOTE_BACKUP="$RUN_ROOT\recovery"; GI_WORK="$RUN_ROOT\gi-$FRAME_ID"; REMOTE_RELEASE="$RUN_ROOT\release"
}
stage() {
  [[ ! -e "$OUT/stage.json" ]] || { echo 'This run already has a source receipt; use it or select a fresh OUT.' >&2; return 1; }
  "$PY" "$ROOT/tools/validation/windows_ssh.py" --host "$HOST" --expected-machine "$MACHINE" upload --directory roo-industries-final-run --parent "${STAGING_PARENT:?Set an existing admin-protected staging parent}" --include-frontend > "$OUT/stage.json.pending"
  mv "$OUT/stage.json.pending" "$OUT/stage.json"
  echo "staged fresh verified source at $(field stagingPath)"
}
interactive() {
  local directory="$1" script="$2" minutes="$3" log="$4" status=0; shift 4
  load_run
  "$PY" "$ROOT/tools/validation/windows_ssh.py" --host "$HOST" --expected-machine "$MACHINE" interactive --receipt "$OUT/stage.json" --script "${directory}\\${script}" --minutes "$minutes" --arguments "$(args_json "$@")" > "$log" 2>&1 || status=$?
  [[ "$status" -eq 0 ]] && ! grep -aqE '^[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+ +)?(FAIL|FATAL|ERROR|SKIP(PED)?|NOT RUN)([[:space:]:]|$)' "$log"
}
phase() {
  local name="$1"; shift; load_run
  local log="$OUT/runner/$(date -u +%H%M%S)-$name.log"
  interactive 'tools\validation\Release' Invoke-IntegrationVerification.ps1 "${MINUTES:-60}" "$log" -Phase "$name" -Source "$REMOTE_STAGE" -Evidence "$REMOTE_EVIDENCE" -BackupRoot "$REMOTE_BACKUP" "$@" || { echo "$log"; return 1; }
  echo "$log"
}
script() {
  local directory="$1" name="$2" minutes="$3"; shift 3
  local log="$OUT/suites/$name-$(date -u +%H%M%S).log"
  interactive "$directory" "$name" "$minutes" "$log" "$@" || { echo "$log"; return 1; }
  echo "$log"
}
gi() {
  local label="$1" phase_name="$2"; shift 2; load_run
  local owner='' log="$OUT/lifecycle/$label.json"
  if [[ "$phase_name" != initialize ]]; then
    [[ -f "$OUT/gi-owner.json" ]] || { echo 'Missing GI owner receipt; initialize this fresh frame first.' >&2; return 1; }
    owner="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["ownerSha256"])' "$OUT/gi-owner.json")"
  fi
  interactive 'tools\validation\Governor' Test-GovernorInstalled.ps1 "${GI_MINUTES:-10}" "$log" -Phase "$phase_name" -GIWork "$GI_WORK" -Source "$REMOTE_STAGE" -SourceManifestSha256 "$MANIFEST_SHA" -FixtureId "$FRAME_ID" -OwnerSha256 "$owner" "$@" || { cat "$log"; return 1; }
  "$PY" - "$log" "$phase_name" "$OUT/gi-owner.json" <<'PY'
import json,sys
from pathlib import Path
text=Path(sys.argv[1]).read_text(encoding='utf-8-sig'); dec=json.JSONDecoder(); result=None
for index,char in enumerate(text):
    if char!='{': continue
    try: obj,_=dec.raw_decode(text[index:])
    except ValueError: continue
    if isinstance(obj,dict) and 'phase' in obj and 'checks' in obj: result=obj;break
if result is None or not result['checks'] or any(c.get('passed') is not True for c in result['checks']): raise SystemExit('Missing or failed GI checks')
if sys.argv[2]=='initialize': Path(sys.argv[3]).write_text(json.dumps({'fixtureId':result['fixtureId'],'ownerSha256':result['ownerSha256']}))
print(json.dumps(result,indent=2))
PY
}
giui() { gi "$@"; }
screen() {
  local name="$1" page="${2:-Games}" log="$OUT/screens/$1.log"
  interactive 'tools\validation\Governor' Capture-GovernorUi.ps1 3 "$log" -Name "$name" -Page "$page" || return 1
  winps_text "[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path ([IO.Path]::GetTempPath()) $(ps_literal "roo-industries-governor-ui\shot-$name.png"))))" | tail -1 | base64 -d > "$OUT/screens/$name.png"
  echo "$OUT/screens/$name.png"
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
  echo 'The PC did not return with a desktop session'; return 1
}
fetch() { local remote="$1" local_dir="$2" linked; linked="$(winps_text "$(printf "if(((Get-Item -LiteralPath %s -Force).Attributes -band 1024) -or @(Get-ChildItem -LiteralPath %s -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop).Count){'LINKED'}else{'PLAIN'}" "$(ps_literal "$remote")" "$(ps_literal "$remote")")" | tail -1)" || return 1; [[ "$linked" == PLAIN ]] || { echo "The remote folder is or holds a link, so it is not copied with scp -r: $remote" >&2; return 1; }; mkdir -p "$local_dir"; scp -o BatchMode=yes -o ProxyCommand=none -o ProxyJump=none -r "$HOST:${remote//\\//}" "$local_dir/"; }
run_all() {
  load_run
  [[ -n "$OLD_INSTALLER" ]] || { echo 'Set OLD_INSTALLER to the explicit retained 0.9.0-beta installer.' >&2; return 1; }
  local old="$OLD_INSTALLER" new="${NEW_INSTALLER:-$REMOTE_RELEASE\RooIndustries-OptimizationSuite-0.10.0-beta-setup.exe}"
  [[ "$old" == *0.9.0-beta-setup.exe && "$new" == *0.10.0-beta-setup.exe ]] || { echo 'Explicit old/new installer versions do not match.' >&2; return 1; }
  local from="${FROM:-preflight}" go=0 name
  local -a steps=(preflight validators release-build install-old migration-before upgrade migration-after static-checks migration-undo-blocker migration-timer-on permissions launchers override incomplete invalidation modes setup-fallbacks hardware loadtimes summary)
  [[ " ${steps[*]} " == *" $from "* ]] || { echo "Unknown starting phase: $from"; return 2; }
  [[ -z "${SKIP:-}" ]] || { echo 'Required verification phases cannot be skipped.' >&2; return 1; }
  for name in "${steps[@]}"; do
    [[ "$name" == "$from" ]] && go=1; [[ "$go" -eq 1 ]] || continue
    case "$name" in
      preflight) phase preflight ;;
      validators) MINUTES=150 phase validators ;;
      release-build) MINUTES=40 phase release-build -BuildOutput "$REMOTE_RELEASE" ;;
      install-old) phase install-old -OldInstaller "$old" ;;
      upgrade) phase upgrade -NewInstaller "$new" ;;
      static-checks) phase static-checks ;;
      setup-fallbacks) MINUTES=30 phase setup-fallbacks ;;
      summary) phase summary ;;
      modes)
        local hook_release="$RUN_ROOT\release-test-hooks" modes_status=0
        local hook_installer="$hook_release\RooIndustries-OptimizationSuite-0.10.0-beta-setup.exe"
        script 'tools\scripts' Build-Release.ps1 40 -TestHooks -OutputRoot "$hook_release" || return 1
        phase install-other -OtherInstaller "$hook_installer" -Label modes-hooks || return 1
        MINUTES=45 phase scenario -Scenario modes || modes_status=$?
        phase install-other -OtherInstaller "$new" -Label production-after-modes || return 1
        [[ "$modes_status" -eq 0 ]] || return "$modes_status"
        ;;
      loadtimes) MINUTES=90 phase scenario -Scenario loadtimes -Minutes 80 ;;
      *) MINUTES=45 phase scenario -Scenario "$name" ;;
    esac || { echo "Stopped at $name"; return 1; }
  done
}
lifecycle() {
  load_run; local new="${1:?Specify the retained 0.10.0-beta installer}"
  [[ "$new" == *0.10.0-beta-setup.exe ]] || { echo 'Expected 0.10.0-beta installer.' >&2; return 1; }
  phase uninstall
  phase install-other -OtherInstaller "$new" -Label fresh
  gi initialize initialize
  gi create-rule create-rule
  gi verify-running-1 verify-running
  gi measure measure
  screen governor-running Games
  gi disable-task disable-task
  screen governor-task-disabled Games
  gi restore-task restore-task
  gi damage-rule damage-rule
  screen governor-damaged-rule Games
  gi remove-damaged-rule remove-damaged-rule
  screen governor-undo-row 'Undo changes'
  giui app-cycle app-cycle
  reboot_wait
  gi new-probe-after-reboot new-probe
  gi verify-running-after-reboot verify-running
  MINUTES=30 phase scenario -Scenario launchers-session
  gi pause pause
  reboot_wait
  gi new-probe-after-paused-reboot new-paused-probe
  gi verify-paused-after-reboot verify-paused
  gi resume resume
  gi verify-running-resumed verify-running
  gi record record
  phase install-other -OtherInstaller "$new" -Label reinstall
  gi verify-replaced verify-replaced
  gi new-probe-before-uninstall new-probe
  phase uninstall
  gi verify-removed verify-removed
  phase install-other -OtherInstaller "$new" -Label reinstall-resumes
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
  giui) giui "$@" ;;
  lifecycle) lifecycle "$@" ;;
  all) run_all ;;
  *) echo "usage: $0 stage | phase <name> [parameters] | gi <label> <phase> | script <directory> <name> <minutes> [parameters] | screen <name> [page] | reboot | fetch <remote> <local dir> | lifecycle <installer> | all"; exit 2 ;;
esac
