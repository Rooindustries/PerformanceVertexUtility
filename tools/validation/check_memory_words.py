from __future__ import annotations

import json
from pathlib import Path
import re
import tempfile

APP = Path('docs/internal/frontend/RooIndustries.OptimizationSuite.App')
XAML = (APP / 'Views/MemoryLatencyPage.xaml', APP / 'Views/MemoryGuidesPanel.xaml')
VIEW_MODEL = APP / 'ViewModels/MemoryLatencyViewModel.cs'
GUIDES = APP / 'Assets/Guides/memory-guides.json'
WORDS = Path('tools/validation/MemoryUi/plain-words.json')
SOURCES = (*XAML, VIEW_MODEL, GUIDES, WORDS)
ATTRIBUTE = re.compile(r'\b(?:Text|Content|Header|PlaceholderText|ToolTipService\.ToolTip|AutomationProperties\.Name)="([^"{][^"]*)"')
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
RAW_ERROR = re.compile(r'\.(?:Error|Message)\b(?!\s*==\s*AppLog\.\w+)')


def rules(root: Path) -> list[tuple[re.Pattern[str], str]]:
    words = json.loads((root / WORDS).read_text(encoding='utf-8'))
    return [(re.compile(item['pattern'], 0 if item.get('caseSensitive') else re.IGNORECASE), item['why']) for item in words['banned']]


def guide_text(value: object):
    if isinstance(value, dict):
        for key, item in value.items():
            if key != 'id':
                yield from guide_text(item)
    elif isinstance(value, list):
        for item in value:
            yield from guide_text(item)
    elif isinstance(value, str):
        yield value


def shown(root: Path):
    for path in XAML:
        for match in ATTRIBUTE.finditer((root / path).read_text(encoding='utf-8-sig')):
            yield path, match.group(1).replace('&apos;', "'").replace('&quot;', '"').replace('&amp;', '&')
    for line in (root / VIEW_MODEL).read_text(encoding='utf-8-sig').splitlines():
        if 'AppLog.Write(' not in line:
            for match in LITERAL.finditer(line):
                yield VIEW_MODEL, match.group(1)
    for text in guide_text(json.loads((root / GUIDES).read_text(encoding='utf-8-sig'))):
        yield GUIDES, text


def check(root: Path | str) -> list[str]:
    root = Path(root)
    failures = []
    banned = rules(root)
    for path, text in shown(root):
        for pattern, why in banned:
            if pattern.search(text):
                failures.append(f'{path.as_posix()}: the Memory screen shows {why}: "{text}"')
    for number, line in enumerate((root / VIEW_MODEL).read_text(encoding='utf-8-sig').splitlines(), 1):
        if 'AppLog.Write(' not in line and RAW_ERROR.search(line):
            failures.append(f'{VIEW_MODEL.as_posix()}:{number}: backend error text reaches the Memory screen; write it to the app log and show a plain sentence')
    return failures


MUTATIONS = {
    'a "Memory by process" panel title': (XAML[0], 'Text="Apps using the most RAM"', 'Text="Memory by process"'),
    'a backend error shown under the app list': (VIEW_MODEL, 'TopMemoryNote = classification is null ? TopUnavailable : "";', 'TopMemoryNote = classification is null ? classificationResult.Error ?? "" : "";'),
    'an "Excluded" row state': (VIEW_MODEL, 'p.Protected ? "Never limited" : ""', 'p.Protected ? "Excluded" : "Normal"'),
    'a "Left alone" row state': (VIEW_MODEL, 'p.Protected ? "Never limited" : ""', 'p.Protected ? "Left alone" : ""'),
    'a hex mask in a guide': (GUIDES, 'Close what you don\'t need before you start a game.', 'Set affinity 0x3F before you start a game.'),
    'a raw category value': (VIEW_MODEL, '"See temperatures, clock speeds and fan speeds."', '"foregroundGame"'),
}


def negative_controls(root: Path | str) -> dict[str, bool]:
    root = Path(root)
    caught = {}
    for label, (target, old, new) in MUTATIONS.items():
        with tempfile.TemporaryDirectory() as scratch:
            copy = Path(scratch)
            for source in SOURCES:
                text = (root / source).read_text(encoding='utf-8-sig')
                if source == target:
                    if old not in text:
                        caught[label] = False
                        break
                    text = text.replace(old, new)
                (copy / source).parent.mkdir(parents=True, exist_ok=True)
                (copy / source).write_text(text, encoding='utf-8')
            else:
                caught[label] = bool(check(copy))
    return caught


if __name__ == '__main__':
    import sys
    repo = Path(__file__).resolve().parents[2]
    problems = check(repo) + [f'Negative control failed: {label} passed' for label, ok in negative_controls(repo).items() if not ok]
    print('\n'.join(problems) or 'Memory screen plain words: OK')
    sys.exit(1 if problems else 0)
