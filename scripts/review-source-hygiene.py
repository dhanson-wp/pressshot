#!/usr/bin/env python3
"""Read-only pre-commit review of indexed files, with redacted findings.

This targeted scan isn't a replacement for a dedicated secret scanner before push.
It checks paths and common credential signatures; candidates need human review.
"""
import re
import subprocess
import sys

patterns = {
    'private key': rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
    'GitHub credential': rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})',
    'Slack credential': rb'xox[baprs]-[A-Za-z0-9-]{20,}',
    'AWS access key candidate': rb'(?:AKIA|ASIA)[A-Z0-9]{16}',
    'Google API key candidate': rb'AIza[A-Za-z0-9_-]{35}',
    'credential in URL': rb'https?://[^\s/<>\"]+:[^\s/<>\"]+@',
}
forbidden = re.compile(r'(^|/)(node_modules|DerivedData|xcuserdata|wp-admin|wp-includes|wp-content|uploads|captures|recordings|\.git)(/|$)|\.(?:p12|pfx|mobileprovision|sqlite3?|sql|dmg|xcresult|xcarchive)$')
paths = subprocess.check_output(['git', 'ls-files', '-z']).decode().split('\0')
findings = []
for path in filter(None, paths):
    if forbidden.search(path):
        findings.append((path, 0, 'forbidden path'))
    content = subprocess.check_output(['git', 'show', ':' + path])
    for name, expression in patterns.items():
        for match in re.finditer(expression, content):
            line = content[:match.start()].count(b'\n') + 1
            findings.append((path, line, name))
print(f'Scanned {len([p for p in paths if p])} indexed paths. Candidate findings: {len(findings)}')
for path, line, name in findings:
    print(f'{path}:{line}: {name} (value redacted)')
sys.exit(1 if findings else 0)
