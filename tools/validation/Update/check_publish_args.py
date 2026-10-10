import argparse
import ast
import json
from pathlib import Path
import subprocess
from types import SimpleNamespace

parser = argparse.ArgumentParser()
parser.add_argument('--vercel-root', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
version = json.loads((args.vercel_root / 'package.json').read_text())['version']
if version != '59.3.0':
    raise ValueError('This check targets the reviewed Vercel CLI 59.3.0 parser')
repo = Path(__file__).resolve().parents[3]
tree = ast.parse((repo / 'tools/release/publish_update.py').read_text())
publish = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'publish')
command_node = next(node.value for node in publish.body if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == 'commands' for target in node.targets))
commands = eval(compile(ast.Expression(command_node), '<publisher commands>', 'eval'), {'str': str}, {'args': SimpleNamespace(installer='installer.exe', manifest='beta.json', installer_path='b/fixture/installer.exe', feed_path='u/fixture/beta.json')})
source = (args.vercel_root / 'dist/chunks/chunk-XLKFJPMT.js').read_text()
start = source.index('var require_arg = __commonJS(')
end = source.index('// src/util/get-args.ts', start)
script = r'''
const fs=require('fs'),vm=require('vm');
const input=JSON.parse(fs.readFileSync(0,'utf8'));
const context={__commonJS:factory=>{let mod;return()=>{if(!mod){mod={exports:{}};Object.values(factory)[0](mod.exports,mod);}return mod.exports;};},cases:input.commands.map(c=>c.slice(3))};
const rows=vm.runInNewContext(input.parser+'\nconst parse=require_arg();const spec={"--access":String,"--pathname":String,"--add-random-suffix":Boolean,"--allow-overwrite":Boolean,"--content-type":String,"--cache-control-max-age":Number};cases.map(argv=>parse(spec,{argv}));',context);
process.stdout.write(JSON.stringify(rows));
'''
result = subprocess.run(['node', '-e', script], input=json.dumps({'parser': source[start:end], 'commands': commands}), text=True, capture_output=True, check=True)
parsed = json.loads(result.stdout)
observed = [{'addRandomSuffix': row.get('--add-random-suffix', False), 'allowOverwrite': row.get('--allow-overwrite', False), 'cacheControlMaxAge': row.get('--cache-control-max-age')} for row in parsed]
if observed != [{'addRandomSuffix': False, 'allowOverwrite': False, 'cacheControlMaxAge': None}, {'addRandomSuffix': False, 'allowOverwrite': True, 'cacheControlMaxAge': 60}]:
    raise ValueError(observed)
args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_text(json.dumps({'cliVersion': version, 'commands': commands, 'parsed': parsed, 'observed': observed, 'uploads': 0, 'passed': True}, indent=2))
print(json.dumps(observed))
