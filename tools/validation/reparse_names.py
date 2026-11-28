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
SHELLS = {'workflow': ('bash', 'cmd', 'powershell'), 'msbuild': ('cmd',)}


def anywhere(name):
    return re.compile(r'(?<![A-Za-z])' + re.escape(name), re.IGNORECASE)


def word(name, quoted=None):
    if quoted == 'python':
        return re.compile(r'(?<=[\'"/\\])' + re.escape(name) + r'(?:\.exe)?(?![\w.-])')
    if quoted == 'csharp':
        return re.compile(r'(?<=[\'"])' + re.escape(name) + r'(?:\.exe(?![\w.-])|\s)')
    return re.compile(r'(?<![\w.$-])' + re.escape(name) + r'(?:\.exe)?(?![\w.-])', re.IGNORECASE)


MATCHERS = []
for _harm in REASONS:
    _rules = NAMED[_harm]
    MATCHERS += [(_harm, n, None, anywhere(n), None, None) for n in _rules['anywhere']]
    MATCHERS += [(_harm, n, languages, word(n), {'python': word(n, 'python'), 'csharp': word(n, 'csharp')}, None) for n, languages in _rules['words'].items()]
    MATCHERS += [(_harm, n, rule['languages'], word(n), {'python': word(n, 'python'), 'csharp': word(n, 'csharp')}, rule) for n, rule in _rules['switched'].items()]
    MATCHERS += [(_harm, n, rule['languages'], re.compile(rule['pattern'], re.IGNORECASE), None, None) for n, rule in _rules['patterns'].items()]


def flagged(rule, tokens):
    words = [t for t in tokens or [] if isinstance(t, str)]
    lowered = [w.lower() for w in words]
    options = [w.split('=')[0] for w in lowered if w.startswith('--') and len(w.split('=')[0]) > 2]
    return bool(lowered[:1] and lowered[0] in rule.get('first', [])
                or any(letter in rule.get('switches', '') for w in lowered if w.startswith('/') for letter in w.replace('/', ''))
                or any(long.startswith(option) for option in options for long in rule.get('long', []))
                or any(re.fullmatch(r'-[a-z]+', w, re.I) and set(w[1:]) & set(rule.get('letters', '')) for w in words))


def prose_blanked(text):
    out, quote, first = list(text), None, False
    for index, letter in enumerate(text):
        if quote is None:
            if letter in '\'"':
                quote, first = letter, True
        elif letter == quote and text[index - 1] not in '\\`':
            quote = None
        elif first and letter.isspace() and index > 0 and text[index - 1] not in '\'"':
            first = False
        elif not first:
            out[index] = ' '
    return ''.join(out)


def named(text, language):
    text = text or ''
    words = prose_blanked(text)
    found = []
    for harm, name, languages, pattern, quoted, rule in MATCHERS:
        searched = text if quoted is None else words
        if languages is not None and 'all' not in languages and not set(SHELLS.get(language, (language,))) & set(languages):
            if quoted is None or language not in quoted:
                continue
            pattern = quoted[language]
        if any(rule is None or flagged(rule, text[match.end():].split()) for match in pattern.finditer(searched)):
            found.append((harm, name))
    return found


def harm_of(program, tokens):
    base = re.split(r'[\\/]', program.lower())[-1]
    shell = CLASSES['shell programs'].get(re.sub(r'\.(exe|com)$', '', base))
    harms = [harm_named(base, tokens)]
    if shell:
        harms += [harm for harm, _ in named(' '.join(t for t in tokens or [] if isinstance(t, str)), shell)]
    return next((harm for harm in harms if harm in REASONS), harms[0])


def harm_named(program, tokens):
    base = re.sub(r'\.(exe|com)$', '', program)
    for harm in REASONS:
        if base in NAMED[harm]['words'] or any(base == n.lower() for n in NAMED[harm]['anywhere']):
            return harm
    for harm in REASONS:
        rule = NAMED[harm]['switched'].get(base)
        if rule and flagged(rule, tokens):
            return harm
    return NAMED['measured programs'].get(base, 'program')


def launch(program, tokens=None):
    if not program:
        return ('this starts a program the check cannot name', 'program named by a value the check cannot read', '')
    return (f'this starts {program}', harm_of(program, tokens), program.lower())


def call_harm(name):
    return next((harm for harm, _, languages, pattern, _, _ in MATCHERS if languages is None and pattern.search(name)), None)


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
        for number, line in enumerate(lines_of(text), 1):
            for harm, name in named(line, language):
                found.setdefault((relative, number), (line, []))[1].append((f'this line names {name}, which the names list calls {harm}', harm, ''))
    return found
