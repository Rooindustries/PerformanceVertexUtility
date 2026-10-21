#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 && ($# != 3 || $3 != --negative-records) ]]; then
  printf 'Usage: %s <source-directory> <artifact-directory> [--negative-records]\n' "$0" >&2
  exit 2
fi
source_dir=$(realpath -- "$1")
artifact_dir=$(realpath -- "$2")
report_dir="$artifact_dir/contract-validation"
mkdir -p -- "$report_dir"
records=$(mktemp "$report_dir/records.XXXXXX")
trap 'rm -f -- "$records"' EXIT
for definition in actionEnvelope gameTuneSessionRestoreEnvelope gameTuneSessionStatus processGovernorSessionStatus; do
  perl -MJSON::PP -e '
    my ($definition, $path) = @ARGV;
    open my $input, "<", $path or die $!;
    local $/;
    my $json = JSON::PP->new->allow_bignum;
    my $schema = $json->decode(<$input>);
    print $json->canonical->pretty->encode({"\$schema" => $schema->{"\$schema"}, "\$defs" => $schema->{"\$defs"}, "\$ref" => "#/\$defs/" . $definition});
  ' "$definition" "$source_dir/backend/contracts/roo-industries-backend-contracts.schema.json" > "$report_dir/$definition.schema.json"
done
mapfile -d '' files < <(find "$artifact_dir" -path "$report_dir" -prune -o -type f -name '*.json' -print0 | sort -z)
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
  ROO_INDUSTRIES_CONTRACT_INPUT="$file" ROO_INDUSTRIES_CONTRACT_SCHEMA="$report_dir/$definition.schema.json" \
    pwsh -NoProfile -NonInteractive -Command '
      try {
        $issues = @()
        $valid = Test-Json -LiteralPath $env:ROO_INDUSTRIES_CONTRACT_INPUT -SchemaFile $env:ROO_INDUSTRIES_CONTRACT_SCHEMA -ErrorAction SilentlyContinue -ErrorVariable issues
        if ($valid) { exit 0 }
        foreach ($issue in $issues) { $issue.ToString(); if ($issue.ErrorDetails) { $issue.ErrorDetails.Message } }
        $schema = [Json.Schema.JsonSchema]::FromFile($env:ROO_INDUSTRIES_CONTRACT_SCHEMA)
        $options = [Json.Schema.EvaluationOptions]::new()
        $options.OutputFormat = [Json.Schema.OutputFormat]::List
        $node = [System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($env:ROO_INDUSTRIES_CONTRACT_INPUT))
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
if [[ ${3:-} == --negative-records ]]; then
  negative_root="$report_dir/negative-records"
  mkdir -p -- "$negative_root"
  controls="$report_dir/observed-kept-controls.jsonl"
  : > "$controls"
  negative_count=0
  for file in "${files[@]}"; do
    action=$(jq -r 'if type == "object" then .actionId // empty else empty end' "$file")
    case "$action" in performance.rollbackProfile|performance.gameTune.stopSession|performance.gameTune.sessionStatus) ;; *) continue ;; esac
    for array in result root; do
      path='["result","leftAsSetItems",0]'
      [[ $array != root ]] || path='["leftAsSetItems",0]'
      item=$(jq -c --argjson path "$path" 'getpath($path) // empty' "$file")
      [[ -n $item ]] || continue
      jq -cn --arg source "$file" --arg array "$array" --argjson item "$item" '{source:$source,array:$array,item:$item}' >> "$controls"
      for mutation in missing-processId missing-processName missing-control missing-currentValue missing-appliedValue missing-originalValue missing-outcome missing-reason unknown-field wrong-control wrong-outcome bool-current object-current array-current null-current bool-applied object-original numeric-name string-numeric; do
        negative_count=$((negative_count+1))
        case_dir="$negative_root/$negative_count-$mutation"
        mkdir -- "$case_dir"
        jq --argjson path "$path" --arg mutation "$mutation" '
          getpath($path) as $item |
          (if ($mutation|startswith("missing-")) then $item|del(.[$mutation|ltrimstr("missing-")])
           elif $mutation=="unknown-field" then $item+{unexpected:true}
           elif $mutation=="wrong-control" then $item+{control:"not-a-control"}
           elif $mutation=="wrong-outcome" then $item+{outcome:"applied"}
           elif $mutation=="bool-current" then $item+{currentValue:true}
           elif $mutation=="object-current" then $item+{currentValue:{}}
           elif $mutation=="array-current" then $item+{currentValue:[]}
           elif $mutation=="bool-applied" then $item+{appliedValue:true}
           elif $mutation=="object-original" then $item+{originalValue:{}}
           elif $mutation=="numeric-name" then $item+{processName:3}
           elif $mutation=="string-numeric" then $item+{currentValue:(if $item.control=="memoryPriority" or $item.control=="affinityMask" then "3" else 3 end)}
           else $item+{currentValue:null} end) as $bad | setpath($path;$bad)' "$file" > "$case_dir/envelope.json"
        if bash "$0" "$source_dir" "$case_dir" > "$case_dir/validation.log" 2>&1; then
          printf 'FAIL malformed complete envelope accepted: %s %s\n' "$file" "$mutation"
          exit 1
        fi
        jq -e '.matched==1 and .passed==0 and .failed==1' "$case_dir/contract-validation/summary.json" > /dev/null
      done
    done
  done
  jq -s --argjson negativeCount "$negative_count" '{observed:.,negativeCount:$negativeCount,limitation:"Only actual supplied full producer envelopes and single-field negative copies; absent real control/legacy representations remain UNRUN"}' "$controls" > "$report_dir/kept-record-coverage.json"
  [[ $negative_count -gt 0 ]] || { printf 'FAIL no actual kept-record envelope was supplied\n'; exit 1; }
  printf 'Rejected %s single-field malformed complete envelopes\n' "$negative_count"
fi
