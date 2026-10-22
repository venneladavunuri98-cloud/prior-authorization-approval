"""Fail if anything that looks like a secret or personal data is about to be committed.
Usage: python scripts/check_secrets.py [files...]   (no args = scan whole repo)
"""
import re, sys, pathlib
PATTERNS = {
    'OpenAI key': r'sk-(?:proj-)?[A-Za-z0-9_\-]{20,}',
    'Google API key': r'AIza[0-9A-Za-z_\-]{30,}',
    'JWT / Supabase key': r'eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}',
    'Bearer token': r'(?i)bearer\s+(?!\{\{)[A-Za-z0-9_\-\.]{20,}',
    'Slack token/webhook': r'xox[abpr]-[A-Za-z0-9\-]{10,}|hooks\.slack\.com/services/\w+',
    'Google Sheet ID': r'spreadsheets/d/(?!YOUR_)[A-Za-z0-9_\-]{20,}',
    'n8n instanceId': r'"instanceId"\s*:',
    'pinData with content': r'"pinData"\s*:\s*\{\s*"',
    'Real email': r'[A-Za-z0-9._%+\-]+@(?!example\.com)[A-Za-z0-9\-]+\.[A-Za-z.]{2,}',
    'Phone number': r'\+(?!\d{0,3}0{9,})\d{10,13}\b',
}
SKIP = {'.git', 'node_modules'}
files = [pathlib.Path(f) for f in sys.argv[1:]] or [p for p in pathlib.Path('.').rglob('*') if p.is_file() and not SKIP & set(p.parts)]
bad = 0
for f in files:
    if f.suffix not in {'.json', '.md', '.js', '.py', '.txt', '.env', '.yml', '.yaml', '.sql'} or f.name == 'check_secrets.py':
        continue
    text = f.read_text(errors='ignore')
    for label, pat in PATTERNS.items():
        for m in re.finditer(pat, text):
            if label == 'Real email' and m.group(0).endswith(('@n8n.io', '@github.com')):
                continue
            bad += 1
            print(f'BLOCKED  {f}: {label}: {m.group(0)[:60]}')
if bad:
    print(f'\n{bad} problem(s) found. Run scripts/sanitize.py or fix by hand before committing.')
    sys.exit(1)
print('No secrets or personal data found.')
