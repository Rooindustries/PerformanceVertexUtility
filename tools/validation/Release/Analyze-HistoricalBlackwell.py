import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('win', ROOT / 'tools/validation/windows_ssh.py')
WIN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WIN)
parser = argparse.ArgumentParser()
parser.add_argument('--receipt', required=True)
args = parser.parse_args()
receipt = json.loads(Path(args.receipt).read_text())
if receipt['machine'] != 'CS2-GEN4' or receipt['sid'] != 'S-1-5-21-1846494563-3099854232-4004002307-1001' or not re.fullmatch(r'C:\\ProgramData\\RooRecoveryBlackwell-[a-f0-9]{32}', receipt['frame']):
    raise ValueError('Wrong historical snapshot receipt')
FRAME = receipt['frame'].replace('\\', '/')
APPROVED = {'roo-industries-cache-check', 'roo-industries-migration-check', 'roo-industries-migration-timer', 'roo-industries-migration-blocker', 'roo-migration-check', 'roo-cache-check'}
EXPECTED = {'original': '71B282CD2E17350580AF59E58932BF2BFDCEA24E8E3CAC6581A49C7525A635DC', 'asnow': '7A045E71ED86E7B59E9778AA43962A99A62A30219E128F50A5E3888309C09994'}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest().upper()


with tempfile.TemporaryDirectory(prefix='roo-blackwell-private-state-') as directory:
    decoded = {}
    for name, relative in [('original', 'original-state.bin'), ('asnow', 'registry-asnow/value-0000.bin')]:
        path = Path(directory) / name
        subprocess.run(['scp', *WIN.SSH_OPTIONS, 'blackwell-lan:' + FRAME + '/' + relative, str(path)], capture_output=True, check=True)
        path.chmod(0o600)
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest().upper() != EXPECTED[name]:
            raise RuntimeError('State snapshot changed')
        decoded[name] = json.loads(data)
    old, new = decoded['original'], decoded['asnow']
    histories = [{item['operationId']: item for item in x.get('history', [])} for x in (old, new)]
    added = [item for key, item in histories[1].items() if key not in histories[0]]
    missing = set(histories[0]) - set(histories[1])
    changed = [key for key in histories[0].keys() & histories[1].keys() if digest(histories[0][key]) != digest(histories[1][key])]
    proof = {
        'frame': FRAME, 'hashes': EXPECTED,
        'shape': {name: {'keys': sorted(state), 'historyCount': len(state.get('history', [])), 'duplicateHistoryIds': len(state.get('history', []))-len({i['operationId'] for i in state.get('history', [])}), 'profileCount': len(state.get('profiles', [])), 'heldCount': len(state.get('held', [])), 'controlCount': len(state.get('controls', []))} for name, state in decoded.items()},
        'changedTopLevelFields': [key for key in old.keys() | new.keys() if digest(old.get(key)) != digest(new.get(key))],
        'originalHistoryMissing': len(missing), 'originalHistoryChanged': len(changed),
        'contextExact': digest(old.get('context')) == digest(new.get('context')),
        'heldExact': digest(old.get('held')) == digest(new.get('held')),
        'addedHistory': [{'operationIdHash': digest(item.get('operationId')), 'profileId': item.get('profileId') if item.get('profileId') in APPROVED else 'unclassified:' + digest(item.get('profileId')), 'keys': sorted(item), 'atUtc': item.get('atUtc'), 'changeCount': len(item.get('changes', [])), 'changes': [{'keys': sorted(change), 'beforeKeys': sorted(change.get('before', {})), 'addressIsTransparency': change.get('before', {}).get('address', {}).get('hive') == 'CurrentUser' and change.get('before', {}).get('address', {}).get('keyPath', '').lower() == 'software\\microsoft\\windows\\currentversion\\themes\\personalize' and change.get('before', {}).get('address', {}).get('valueName') == 'EnableTransparency', 'beforeAddressKeys': sorted(change.get('before', {}).get('address', {})), 'addressHash': digest(change.get('before', {}).get('address')), 'beforeValue': change.get('before', {}).get('value') if isinstance(change.get('before', {}).get('value'), dict) and all(k in ['kind','data','type','exists'] for k in change.get('before', {}).get('value')) else 'omitted', 'afterKeys': sorted(change.get('after', {}) or {})} for change in item.get('changes', [])], 'controlCount': len(item.get('controls', []))} for item in added],
        'changedOriginalHistoryIdHashes': [digest(key) for key in changed],
        'changedOriginalHistoryFields': [{ 'operationIdHash': digest(key), 'fields': [field for field in histories[0][key].keys() | histories[1][key].keys() if digest(histories[0][key].get(field)) != digest(histories[1][key].get(field))]} for key in changed],
        'profiles': {name: [{'id': x.get('id') if x.get('id') in APPROVED else 'unclassified:' + digest(x.get('id')), 'keys': sorted(x)} for x in state.get('profiles', [])] for name, state in decoded.items()},
        'privateValuesPrinted': False,
    }
    output = ROOT / 'artifacts/continuation/blackwell-historical-state-delta-readonly.json'
    output.write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(proof, indent=2))
