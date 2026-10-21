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
for definition in actionEnvelope gameTuneSessionRestoreEnvelope gameTuneSessionStatus processGovernorSessionStatus processProfileBackupManifest; do
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
raw_profile_matched=0
for file in "${files[@]}"; do
  action=$(jq -r 'if type == "object" then .actionId // empty else empty end' "$file")
  case "$action" in
    performance.applyProfile)
      [[ ${file##*/} == producer-profile-backup.json ]] || continue
      definition=processProfileBackupManifest
      ;;
    performance.rollbackProfile) definition=actionEnvelope ;;
    performance.gameTune.stopSession) definition=gameTuneSessionRestoreEnvelope ;;
    performance.gameTune.sessionStatus) definition=gameTuneSessionStatus ;;
    performance.governor.sessionStatus) definition=processGovernorSessionStatus ;;
    *) continue ;;
  esac
  matched=$((matched + 1))
  if [[ $definition == processProfileBackupManifest ]]; then
    raw_profile_matched=$((raw_profile_matched+1))
  fi
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
  if [[ $raw_profile_matched -eq 0 ]]; then
    jq -n '{rawProfileMatched:0,rawProfileNegativeCount:0,coverageComplete:false,missingProfile:true,scope:"No supplied whole Profile producer backup; combined negative coverage is incomplete."}' \
      > "$report_dir/profile-backup-coverage.json"
    printf 'FAIL Profile backup coverage requires an actual whole producer backup\n' >&2
    exit 1
  fi
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
  raw_profile_negative_count=0
  raw_profile_source=''
  raw_profile_memory_negative_count=0
  raw_profile_memory_positive_count=0
  for file in "${files[@]}"; do
    [[ ${file##*/} == producer-profile-backup.json ]] || continue
    [[ $(jq -r '.actionId // empty' "$file") == performance.applyProfile ]] || continue
    raw_profile_source=$file
    for field in originalMemoryPriority proposedMemoryPriority processStartTimeUtc; do
      case_dir="$negative_root/profile-$field"
      mkdir -- "$case_dir"
      perl -MJSON::PP -e '
        my ($field, $path) = @ARGV;
        open my $input, "<", $path or die $!;
        local $/;
        my $json = JSON::PP->new->allow_bignum;
        my $data = $json->decode(<$input>);
        die "Expected actual Profile snapshot" unless ref($data->{snapshots}) eq "ARRAY" && @{$data->{snapshots}};
        $data->{snapshots}[0]{$field} = {};
        print $json->canonical->pretty->encode($data);
      ' "$field" "$file" > "$case_dir/producer-profile-backup.json"
      if bash "$0" "$source_dir" "$case_dir" > "$case_dir/validation.log" 2>&1; then
        printf 'FAIL malformed complete Profile backup accepted: %s %s\n' "$file" "$field"
        exit 1
      fi
      jq -e '.matched==1 and .passed==0 and .failed==1' "$case_dir/contract-validation/summary.json" > /dev/null
      raw_profile_negative_count=$((raw_profile_negative_count+1))
    done
    for field in originalMemoryPriority proposedMemoryPriority; do
      for value in 0 6 1 5 null absent; do
        case_dir="$negative_root/profile-$field-$value"
        mkdir -- "$case_dir"
        perl -MJSON::PP -e '
          my ($field, $value, $path) = @ARGV;
          open my $input, "<", $path or die $!;
          local $/;
          my $json = JSON::PP->new->allow_bignum;
          my $data = $json->decode(<$input>);
          die "Expected actual Profile snapshot" unless ref($data->{snapshots}) eq "ARRAY" && @{$data->{snapshots}};
          if ($value eq "absent") { delete $data->{snapshots}[0]{$field}; }
          else { $data->{snapshots}[0]{$field} = $json->decode($value); }
          print $json->canonical->pretty->encode($data);
        ' "$field" "$value" "$file" > "$case_dir/producer-profile-backup.json"
        profile_status=0
        bash "$0" "$source_dir" "$case_dir" > "$case_dir/validation.log" 2>&1 || profile_status=$?
        printf '%s\n' "$profile_status" > "$case_dir/validation.exit"
        if [[ $value == 0 || $value == 6 ]]; then
          [[ $profile_status -eq 1 ]] || { printf 'FAIL out-of-range Profile memory value was not rejected: %s %s\n' "$field" "$value" >&2; exit 1; }
          jq -e '.matched==1 and .passed==0 and .failed==1' "$case_dir/contract-validation/summary.json" > /dev/null
          raw_profile_memory_negative_count=$((raw_profile_memory_negative_count+1))
        else
          [[ $profile_status -eq 0 ]] || { printf 'FAIL valid optional Profile memory value was rejected: %s %s\n' "$field" "$value" >&2; exit 1; }
          jq -e '.matched==1 and .passed==1 and .failed==0' "$case_dir/contract-validation/summary.json" > /dev/null
          raw_profile_memory_positive_count=$((raw_profile_memory_positive_count+1))
        fi
      done
    done
    break
  done
  jq -s --argjson negativeCount "$negative_count" '{observed:.,negativeCount:$negativeCount,limitation:"Only actual supplied full producer envelopes and single-field negative copies; absent real control/legacy representations remain UNRUN"}' "$controls" > "$report_dir/kept-record-coverage.json"
  [[ $negative_count -gt 0 ]] || { printf 'FAIL no actual kept-record envelope was supplied\n'; exit 1; }
  case_dir="$negative_root/profile-absent"
  mkdir -- "$case_dir"
  kept_source=$(jq -ers '.[0].source' "$controls")
  cp -- "$kept_source" "$case_dir/envelope.json"
  cmp -- "$kept_source" "$case_dir/envelope.json"
  sha256sum -- "$kept_source" "$case_dir/envelope.json" > "$case_dir/original-bytes.sha256"
  absence_status=0
  bash "$0" "$source_dir" "$case_dir" --negative-records > "$case_dir/validation.log" 2>&1 || absence_status=$?
  printf '%s\n' "$absence_status" > "$case_dir/validation.exit"
  [[ $absence_status -eq 1 ]] || { printf 'FAIL combined negative validation did not refuse missing Profile coverage\n' >&2; exit 1; }
  jq -e '.matched==1 and .passed==1 and .failed==0' "$case_dir/contract-validation/summary.json" > /dev/null
  jq -e '.rawProfileMatched==0 and .rawProfileNegativeCount==0 and .coverageComplete==false and .missingProfile==true' "$case_dir/contract-validation/profile-backup-coverage.json" > /dev/null
  jq -n --argjson matched "$raw_profile_matched" --argjson rejected "$raw_profile_negative_count" \
    --argjson memoryRejected "$raw_profile_memory_negative_count" --argjson memoryAccepted "$raw_profile_memory_positive_count" --arg source "$raw_profile_source" \
    '{rawProfileMatched:$matched,rawProfileNegativeCount:$rejected,rawProfileMemoryNegativeCount:$memoryRejected,rawProfileMemoryPositiveCount:$memoryAccepted,missingProfileRefused:true,coverageComplete:true,negativeSource:$source,scope:"Whole supplied Profile producer backups; three object-type refusals, four memory-range refusals, eight nullable/optional boundary acceptances and one missing-Profile refusal with an unchanged kept envelope. Derived copies are contract artifacts, not restore inputs or native proof."}' \
    > "$report_dir/profile-backup-coverage.json"
  [[ $raw_profile_matched -gt 0 && $raw_profile_negative_count -eq 3 && $raw_profile_memory_negative_count -eq 4 && $raw_profile_memory_positive_count -eq 8 ]] || {
    printf 'FAIL incomplete Profile backup boundary coverage\n' >&2
    exit 1
  }
  printf 'Rejected %s single-field malformed complete envelopes\n' "$negative_count"
fi
