"""Compile Python sources and reject f-string quote reuse requiring Python 3.12.

The Docker job runs the real Python 3.11 interpreter. Newer ast parsers do not
fully enforce pre-PEP701 f-string rules even with feature_version=(3, 11).
"""
import ast
import io
from pathlib import Path
import re
import token
import tokenize

ROOT = Path(__file__).resolve().parents[1]


def check(source, filename):
    ast.parse(source, filename=filename, feature_version=(3, 11))
    quotes = []
    for item in tokenize.generate_tokens(io.StringIO(source).readline):
        kind = token.tok_name[item.type]
        if kind in ('FSTRING_START', 'STRING'):
            match = re.match("(?i)^[rubf]*('''|\"\"\"|'|\")", item.string)
            if match and any(match[1].startswith(q) for q in quotes):
                raise SyntaxError(f'{filename}:{item.start[0]}: f-string quote reuse requires Python 3.12')
            if kind == 'FSTRING_START':
                quotes.append(match[1])
        elif kind == 'FSTRING_END':
            quotes.pop()


for directory in ('lib', 'scripts', 'tests'):
    for path in sorted((ROOT / directory).rglob('*.py')):
        if '__pycache__' not in path.parts:
            check(path.read_text(), str(path))
try:
    check("print(f'{target / 'apm'}')", '<regression>')
except SyntaxError:
    pass
else:
    raise AssertionError('f-string regression check is ineffective')
print('OK: Python syntax and pre-3.12 f-string quote compatibility')
