import copy
import json
from pathlib import Path
import re


CATALOG = 'modules/tool-launchers.json'
VIEW_MODEL = 'docs/internal/frontend/RooIndustries.OptimizationSuite.App/ViewModels/ToolsDiagnosticsViewModel.cs'
PAGE = 'docs/internal/frontend/RooIndustries.OptimizationSuite.App/Views/ToolsDiagnosticsPage.xaml'
JARGON = re.compile(r'\b(?:telemetry|mitigations?|runtimes?|redistributable|legacy|librar(?:y|ies)|components?|interrupts?|parking|pcie|x64|x86|dpc|isr|qos|affinity|registry|powershell|processes|process|child|dynamic boosts?|execution|profiles?|enum|0x[0-9a-f]+)\b', re.I)
RAW_ERROR = re.compile(r'\b(?:ex|error|exception)\.Message\b')
LONGEST = 42


def view_categories(source):
    match = re.search(r'Categories \{ get; \} = \[([^\]]*)\]', source)
    return re.findall(r'"([^"]*)"', match.group(1)) if match else []


def page_text(page):
    return re.findall(r'\b(?:Text|Content|PlaceholderText|AutomationProperties\.Name)="([^"{][^"]*)"', page)


def word_failures(catalog, source, page):
    failures = []
    categories = view_categories(source)
    if not categories or categories[0] != 'All tools':
        return [VIEW_MODEL + ' has no category list starting with All tools']
    for tool in catalog['tools']:
        for field in ('description', 'category'):
            text = tool[field]
            if JARGON.search(text):
                failures.append(f'Tool {tool["id"]} {field} "{text}" uses jargon ({JARGON.search(text).group(0)})')
            if tool['id'] in text or '—' in text or '–' in text:
                failures.append(f'Tool {tool["id"]} {field} "{text}" shows an internal id or a dash')
        if len(tool['description']) > LONGEST:
            failures.append(f'Tool {tool["id"]} description is longer than {LONGEST} characters and is cut off on its card')
        if tool['category'] not in categories[1:]:
            failures.append(f'Tool {tool["id"]} category "{tool["category"]}" is not in the Tools category list')
    for category in categories[1:]:
        if JARGON.search(category):
            failures.append(f'Tools category "{category}" uses jargon')
        if not any(tool['category'] == category for tool in catalog['tools']):
            failures.append(f'Tools category "{category}" lists no tools')
    for text in page_text(page) + re.findall(r'"((?:[^"\\]|\\.)*)"', source):
        if JARGON.search(text) or '—' in text:
            failures.append(f'Tools page text "{text}" uses jargon or an em dash')
    if RAW_ERROR.search(source):
        failures.append(VIEW_MODEL + ' shows raw error text instead of a plain sentence')
    return failures


def negative_controls(catalog, source, page):
    def tool(change):
        variant = copy.deepcopy(catalog)
        change(variant['tools'][0])
        return word_failures(variant, source, page)
    cases = {
        'tool description with jargon': ('uses jargon', tool(lambda item: item.update(description='Windows privacy and telemetry controls'))),
        'tool category the list does not show': ('not in the Tools category list', tool(lambda item: item.update(category='Runtimes'))),
        'tool description with an en dash': ('a dash', tool(lambda item: item.update(description='Microsoft C++ 2015–2022'))),
        'tool description cut off on its card': ('cut off', tool(lambda item: item.update(description='Find drivers causing audio dropouts and stutter in games'))),
        'raw error in the status line': ('raw error text', word_failures(catalog, source.replace('Status = ToolLauncherService.Explain(row.Definition, ex);', 'Status = row.Name + ": " + ex.Message;'), page)),
        'jargon category in the list': ('uses jargon', word_failures(catalog, source.replace('"Game support"', '"Runtimes"'), page)),
        'jargon on the page': ('Tools page text', word_failures(catalog, source, page.replace('Text="Tools"', 'Text="Tools and child processes"'))),
    }
    return {label: any(expected in failure for failure in failures) for label, (expected, failures) in cases.items()}


def check(root):
    for path in (CATALOG, VIEW_MODEL, PAGE):
        if not (root / path).is_file():
            return [path + ' is missing']
    catalog = json.loads((root / CATALOG).read_text(encoding='utf-8'))
    source = (root / VIEW_MODEL).read_text(encoding='utf-8')
    page = (root / PAGE).read_text(encoding='utf-8')
    failures = word_failures(catalog, source, page)
    failures += ['Negative control failed: a ' + label + ' passed the Tools words check' for label, rejected in negative_controls(catalog, source, page).items() if not rejected]
    return failures


if __name__ == '__main__':
    errors = check(Path(__file__).resolve().parents[2])
    print(json.dumps({'failures': errors}, indent=2))
    raise SystemExit(bool(errors))
