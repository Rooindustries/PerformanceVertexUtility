import json
import posixpath
from pathlib import Path
import re
import xml.parsers.expat

HERE = Path(__file__).resolve().parent
CLASSES = json.loads((HERE / 'reparse-walk-calls.json').read_text(encoding='utf-8'))
SCOPE = ('tools/validation/', 'tools/scripts/', 'backend/scripts/', '.github/', 'LeanClientOptimizer.ps1')
PRODUCT = ('backend/native/', 'docs/internal/frontend/')
HOLE, PATH, SELF, BLOCK, ROOT = '\0', '\1', '\2', '\3', '\4'
MARKERS = (HOLE, PATH, SELF, BLOCK, ROOT)


def fact(file, line, text, kind, name, args=None, **extra):
    return {'file': file, 'line': line, 'text': text, 'kind': kind, 'name': name, 'args': args, **extra}


def tagged(facts, language):
    return [dict(f, language=f.get('language', language)) for f in facts]


def split_command_line(pieces):
    tokens, current, quoted = [], None, False
    for piece in pieces:
        if piece in MARKERS:
            current = (current or []) + [piece]
            continue
        for letter in piece:
            if letter == '"':
                quoted = not quoted
                current = current or []
            elif letter.isspace() and not quoted:
                if current is not None:
                    tokens.append(current)
                current = None
            else:
                current = current or []
                if current and current[-1] not in MARKERS:
                    current[-1] += letter
                else:
                    current.append(letter)
    if current is not None:
        tokens.append(current)
    return tokens


def cmd_facts(relative, line, text, source):
    out = []
    if re.search(r'[%^!`\r\n]', source):
        return [fact(relative, line, text, 'unreadable', 'cmd expands %, ! or ^ or breaks at a new line in this command line, so the check cannot read it')]
    for part in re.split(r'&&|\|\||[&|]', source):
        words = [''.join(w) for w in split_command_line([re.sub(r'\d?>>?\s*\S+|<\s*\S+', ' ', part)]) if w]
        while words and words[0].lower().lstrip('@') == 'if':
            words = words[1:]
            while words and words[0].lower() in ('/i', 'not'):
                words = words[1:]
            first = words[0].lower() if words else ''
            if first in ('exist', 'defined', 'errorlevel', 'cmdextversion'):
                words = words[2:]
            elif len(words) > 2 and words[1].lower() in ('==', 'equ', 'neq', 'lss', 'leq', 'gtr', 'geq'):
                words = words[3:]
            elif '==' in first:
                words = words[1:]
            else:
                out.append(fact(relative, line, text, 'unreadable', 'cmd runs a command after a condition the check cannot read', language='cmd'))
                words = []
        if not words or words[0].startswith(':'):
            continue
        if words[0].startswith('('):
            out.append(fact(relative, line, text, 'unreadable', 'cmd runs a parenthesized block the check does not read', language='cmd'))
            continue
        name = words[0].lstrip('@').lower()
        head = re.match(r'[^/]+', name)
        if head and head.group(0) in CLASSES['cmd'] and head.group(0) != name:
            words = [head.group(0), name[len(head.group(0)):]] + words[1:]
            name = head.group(0)
        out.append(fact(relative, line, text, 'command', name, words[1:], shell='cmd', language='cmd'))
    return out


def lines_of(text):
    return re.split(r'\r\n|\r|\n', text)


def msbuild_facts(relative, data, files=()):
    facts, stack, texts, properties = [], [], [], {}

    def expanded(value, depth=0):
        if depth > 8:
            return value
        return re.sub(r'\$\((\w+)\)', lambda m: '' if m.group(1) in CLASSES['msbuild path properties'] else expanded(properties[m.group(1)], depth + 1) if m.group(1) in properties else m.group(0), value)
    lines = lines_of(data.decode('utf-8-sig', 'replace'))
    parser = xml.parsers.expat.ParserCreate()

    def functions(value, line, source):
        for named in re.finditer(r'\$\(\s*\[([\w.]+)\]::(\w+)|\$\(\s*\[', value):
            if named.group(1):
                facts.append(fact(relative, line, source, 'call', named.group(1) + '.' + named.group(2), None))
            else:
                facts.append(fact(relative, line, source, 'unreadable', 'an MSBuild property function is written in a form the check cannot read'))

    def start(name, attributes):
        line = parser.CurrentLineNumber
        source = lines[line - 1] if line <= len(lines) else ''
        texts.append([])
        project = attributes.get('Project', '')
        local = posixpath.normpath(posixpath.join(posixpath.dirname(relative), re.sub(r'^\$\(MSBuildThisFileDirectory\)', '', project).replace('\\', '/'))) if name == 'Import' else None
        if name == 'UsingTask':
            facts.append(fact(relative, line, source, 'unreadable', 'an MSBuild task defined here runs code the check cannot read'))
        elif name == 'Import' and not ('$' not in project.replace('$(MSBuildThisFileDirectory)', '') and '*' not in project and local in files) or (
                name in ('Project', 'Import', 'Sdk') and 'Sdk' in attributes and not re.fullmatch(r'Microsoft\.NET\.Sdk(\.\w+)*', attributes['Sdk'])):
            facts.append(fact(relative, line, source, 'call', 'msbuild:import', None))
        elif stack and stack[-1] == 'ItemGroup' and any(re.search(r'\*\*|[*?][^\\/;]*[\\/]', expanded(attributes.get(key, ''))) for key in ('Include', 'Exclude', 'Remove', 'Update')):
            facts.append(fact(relative, line, source, 'call', 'msbuild:item glob', None))
        elif stack and stack[-1] == 'ItemGroup' and any('$(' in expanded(attributes.get(key, '')) for key in ('Include', 'Exclude', 'Remove', 'Update')):
            facts.append(fact(relative, line, source, 'call', 'msbuild:item from a property', None))
        elif stack and stack[-1] == 'Target' and name not in ('PropertyGroup', 'ItemGroup', 'OnError'):
            if name == 'Exec':
                facts.append(fact(relative, line, source, 'command', 'cmd', [], language='cmd'))
                facts.extend(cmd_facts(relative, line, source, attributes.get('Command', '')))
            else:
                facts.append(fact(relative, line, source, 'call', 'msbuild:' + name, None))
        for value in attributes.values():
            functions(value, line, source)
        stack.append(name)

    def end(name):
        stack.pop()
        content = ''.join(texts.pop())
        if stack and stack[-1] == 'PropertyGroup':
            properties[name] = content
        line = parser.CurrentLineNumber
        functions(content, line, lines[line - 1] if line <= len(lines) else '')

    parser.StartElementHandler = start
    parser.EndElementHandler = end
    parser.CharacterDataHandler = lambda content: texts[-1].append(content)
    try:
        parser.Parse(data, True)
    except xml.parsers.expat.ExpatError as error:
        return [fact(relative, error.lineno, '', 'unreadable', f'MSBuild cannot read this project: {error}')]
    return facts


NAMED = CLASSES['names']
REASONS = ('R1', 'R2', 'R3')
LANGUAGES = {'py': 'python', 'ps1': 'powershell', 'psm1': 'powershell', 'psd1': 'powershell', 'cs': 'csharp', 'sh': 'bash', 'cmd': 'cmd', 'bat': 'cmd', 'yml': 'workflow', 'yaml': 'workflow',
             'csproj': 'msbuild', 'props': 'msbuild', 'targets': 'msbuild'}
SHELL_LANGUAGES = ('bash', 'cmd', 'powershell', 'workflow', 'msbuild')
TAIL = r'(?:\.exe|\.com)?(?![\w.-])'
ESCAPED = r'(?<=[\\`][ntr])'


def anywhere(name):
    return re.compile(r'(?:(?<![A-Za-z0-9_])|' + ESCAPED + ')' + re.escape(name), re.IGNORECASE)


def word(name):
    return re.compile(r'(?:(?<![\w.$-])|' + ESCAPED + ')' + re.escape(name) + TAIL, re.IGNORECASE)


def prefixes(text):
    return re.escape(text[0]) + ''.join('(?:' + re.escape(letter) for letter in text[1:]) + ')?' * (len(text) - 1)


def switch(rule):
    parts = [r'(?<![\w-])-(?!(?:' + '|'.join(NAMED['not switches']) + r')(?![\w-]))(?=[a-z0-9]{1,4}(?![\w-]))[a-z0-9]*[' + re.escape(rule['letters']) + ']'] if 'letters' in rule else []
    parts += [r'(?<![\w-])--' + prefixes(option[2:]) + r'(?![\w-])' for option in rule.get('long', [])]
    parts += [r'(?<![\w-])-' + prefixes(name) + r'(?![\w-])' for name in rule.get('param', [])]
    if 'slash' in rule:
        letters = re.escape(rule['slash'])
        parts.append(r'(?:/[a-z?]{1,2})*/(?:[a-z]?[' + letters + r']|[' + letters + r'][a-z]?)(?::\S*)?(?:/[a-z?]{1,2})*(?![\w\\./-])')
    parts += [(r'(?<![\w.$-])' if text[0].isalnum() else r'(?<![\w.$])') + re.escape(text) + r'(?![\w.-])' for text in rule.get('words', [])]
    return re.compile('|'.join(parts), re.IGNORECASE)


def value(name):
    return re.compile(r'(?<=[\'"])' + re.escape(name) + r'(?=[\'"])|(?:(?<![\w-])-\w+\s*:?\s*|=\s*)' + re.escape(name) + r'(?![\w.-])', re.IGNORECASE)


def program(name, shell):
    name = re.escape(name)
    position = r'(?:^\s*[@&.]?|[;|&({`]|\$\(|\b(?:then|do|else)\s|(?<![\w-])[-/](?:c|k|command)\s)\s*' if shell else r'(?:[;|&]|(?<![\w-])[-/](?:c|k|command)\s)\s*'
    return re.compile(name + r'\.(?:exe|com)(?![\w.-])|(?<=[\\/])' + name + TAIL + r'|(?<=[\'"])' + name + TAIL + '|' + position + name + TAIL, re.IGNORECASE)


MATCHERS = []
for _harm in REASONS:
    _rules = NAMED[_harm]
    MATCHERS += [(_harm, n, 'anywhere', anywhere(n), None) for n in _rules['anywhere']]
    MATCHERS += [(_harm, n, 'word', word(n), None) for n in _rules['words']]
    MATCHERS += [(_harm, n, 'switched', word(n), switch(rule)) for n, rule in _rules['switched'].items()]
    MATCHERS += [(_harm, n, 'value', value(n), None) for n in _rules.get('values', [])]
    MATCHERS += [(_harm, n, 'program', None, {True: program(n, True), False: program(n, False)}) for n in _rules.get('programs', [])]
    MATCHERS += [(_harm, n, 'pattern', re.compile(rule['pattern'], re.IGNORECASE), None) for n, rule in _rules['patterns'].items()]
WILDCARD = re.compile(NAMED['wildcard folder']['pattern'], re.IGNORECASE)


def in_class(text, index):
    opened = text.rfind('[', 0, index)
    return opened >= 0 and text[opened + 1:opened + 2] not in ('"', "'") and not re.search(r'[\]\s]', text[opened + 1:index])


def named(text, language, statement):
    shell = language in SHELL_LANGUAGES
    found = []
    for harm, name, kind, pattern, extra in MATCHERS:
        searched = extra[shell] if kind == 'program' else pattern
        if searched.search(text) and (kind != 'switched' or extra.search(statement)):
            found.append((harm, name))
    if any(not in_class(text, match.start()) for match in WILDCARD.finditer(text)):
        found.append(('R1', 'a wildcard folder'))
    return found


def statements(lines):
    out, start = [], 0
    while start < len(lines):
        end, depth = start, 0
        while True:
            depth = max(depth + len(re.findall(r'[(\[]', lines[end])) - len(re.findall(r'[)\]]', lines[end])), 0)
            if not (depth or re.search(r'(?:[\\`^,|+(\[]|&&)\s*$', lines[end])) or end + 1 >= len(lines) or end - start >= 11:
                break
            end += 1
        out.append((start, end))
        start = end + 1
    return out


def harm_of(program, tokens):
    base = re.sub(r'\.(exe|com)$', '', re.split(r'[\\/]', program.lower())[-1])
    switches = ' '.join(t for t in tokens or [] if isinstance(t, str))
    for harm in REASONS:
        rules = NAMED[harm]
        if base in (n.lower() for n in rules['anywhere'] + rules['words'] + rules.get('programs', []) + rules.get('values', [])):
            return harm
    for harm in REASONS:
        rule = next((r for n, r in NAMED[harm]['switched'].items() if n.lower() == base), None)
        if rule and switch(rule).search(switches):
            return harm
    return NAMED['measured programs'].get(base, 'program')


def launch(program, tokens=None):
    if not program:
        return ('this starts a program the check cannot name', 'program named by a value the check cannot read', '')
    return (f'this starts {program}', harm_of(program, tokens), program.lower())


def call_harm(name):
    return next((harm for harm, _, kind, pattern, _ in MATCHERS if kind in ('anywhere', 'pattern') and pattern.search(name)), None)


def language_of(relative):
    extension = relative.rsplit('.', 1)[-1].lower() if '.' in relative.rsplit('/', 1)[-1] else ''
    if extension in ('csproj', 'props', 'targets'):
        return 'msbuild'
    if relative.startswith('.github/workflows/'):
        return LANGUAGES.get(extension)
    return LANGUAGES.get(extension) if relative.startswith(SCOPE + PRODUCT) and extension not in ('yml', 'yaml') else None


def name_findings(root, paths):
    found = {}
    for relative in paths:
        language = language_of(relative)
        if language is None:
            continue
        data = (root / relative).read_bytes()
        text = data.decode('utf-16') if data.startswith((b'\xff\xfe', b'\xfe\xff')) else data.decode('utf-8-sig', 'replace')
        lines = lines_of(text)
        for start, end in statements(lines):
            joined = ' '.join(lines[start:end + 1])
            for number in range(start, end + 1):
                for harm, name in named(lines[number], language, joined):
                    found.setdefault((relative, number + 1), (lines[number], []))[1].append((f'this line names {name}, which the names list calls {harm}', harm, ''))
    return found
