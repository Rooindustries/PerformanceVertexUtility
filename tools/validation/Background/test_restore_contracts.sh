#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then
  printf 'Usage: %s <source-directory> <artifact-directory>\n' "$0" >&2
  exit 2
fi
source_dir=$(realpath -- "$1")
artifact_dir=$(realpath -- "$2")
report_dir="$artifact_dir/contract-validation"
mkdir -p -- "$report_dir"
records=$(mktemp "$report_dir/records.XXXXXX")
trap 'rm -f -- "$records"' EXIT
for definition in actionEnvelope gameTuneSessionRestoreEnvelope gameTuneSessionStatus processGovernorSessionStatus; do
  jq --arg definition "$definition" '{"$schema": ."$schema", "$defs": ."$defs", "$ref": ("#/$defs/" + $definition)}' \
    "$source_dir/backend/contracts/roo-industries-backend-contracts.schema.json" > "$report_dir/$definition.schema.json"
done
mapfile -d '' files < <(find "$artifact_dir" -type f -name '*.json' -print0 | sort -z)
matched=0
failed=0
for file in "${files[@]}"; do
  action=$(jq -r 'if type == "object" then .actionId // empty else empty end' "$file")
  case "$action" in
    performance.rollbackProfile) definition=actionEnvelope ;;
    performance.gameTune.stopSession) definition=gameTuneSessionRestoreEnvelope ;;
    performance.gameTune.sessionStatus) definition=gameTuneSessionStatus ;;
    performance.governor.sessionStatus) definition=processGovernorSessionStatus ;;
    *) continue ;;
  esac
  matched=$((matched + 1))
  printf -v errors '%s/%04d.errors.log' "$report_dir" "$matched"
  status=0
  ROO_CONTRACT_INPUT="$file" ROO_CONTRACT_SCHEMA="$report_dir/$definition.schema.json" \
    pwsh -NoProfile -NonInteractive -Command '
      try {
        $issues = @()
        $valid = Test-Json -LiteralPath $env:ROO_CONTRACT_INPUT -SchemaFile $env:ROO_CONTRACT_SCHEMA -ErrorAction SilentlyContinue -ErrorVariable issues
        if ($valid) { exit 0 }
        foreach ($issue in $issues) { $issue.ToString(); if ($issue.ErrorDetails) { $issue.ErrorDetails.Message } }
        $schema = [Json.Schema.JsonSchema]::FromFile($env:ROO_CONTRACT_SCHEMA)
        $options = [Json.Schema.EvaluationOptions]::new()
        $options.OutputFormat = [Json.Schema.OutputFormat]::List
        $node = [System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($env:ROO_CONTRACT_INPUT))
        foreach ($detail in $schema.Evaluate($node, $options).Details) {
          if (-not $detail.IsValid -and $detail.Errors) { $detail.InstanceLocation.ToString() + ": " + ($detail.Errors | ConvertTo-Json -Compress) }
        }
      } catch { $_.ToString() }
      exit 1
    ' > "$errors" 2>&1 || status=$?
  if [[ $status == 0 ]]; then
    printf 'PASS %s\n' "$file"
  else
    failed=$((failed + 1))
    printf 'FAIL %s (%s)\n' "$file" "$errors"
  fi
  jq -cn --arg file "$file" --arg definition "$definition" --arg errors "$errors" --argjson status "$status" \
    '{file:$file,definition:$definition,exit:$status,errors:$errors}' >> "$records"
done
jq -s '{matched:length,passed:([.[]|select(.exit==0)]|length),failed:([.[]|select(.exit!=0)]|length),envelopes:.}' \
  "$records" > "$report_dir/summary.json"
printf 'Restore contracts: %s matched, %s passed, %s failed\n' "$matched" "$((matched - failed))" "$failed"
if [[ $matched == 0 ]]; then printf 'FAIL no matching restore envelopes found\n'; exit 1; fi
[[ $failed == 0 ]]
