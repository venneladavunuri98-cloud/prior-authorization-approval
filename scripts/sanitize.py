"""Sanitize n8n workflow exports before pushing to a public repo.
Usage: python sanitize.py <input.json> <output.json>
- removes pinData (captured test executions, may hold real customer data)
- removes instanceId, workflow id/versionId, webhookId
- replaces credential IDs with placeholders (n8n re-links on import)
- masks Google Sheet IDs, n8n host, emails, phone numbers, vendor agent IDs
"""
import json, re, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
d['pinData'] = {}
for k in ('id', 'versionId', 'shared', 'triggerCount'):
    d.pop(k, None)
d['meta'] = {k: v for k, v in (d.get('meta') or {}).items() if k != 'instanceId'}
d['active'] = False
for n in d.get('nodes', []):
    n.pop('webhookId', None)
    for ctype in list((n.get('credentials') or {}).keys()):
        n['credentials'][ctype] = {'id': 'REPLACE_WITH_YOUR_CREDENTIAL', 'name': f'{ctype} (configure in n8n)'}
s = json.dumps(d, ensure_ascii=False, indent=2)
SUBS = [
    (r'(docs\.google\.com/spreadsheets/d/)[A-Za-z0-9_\-]{20,}', r'\1YOUR_GOOGLE_SHEET_ID'),
    (r'"(value|documentId|sheetId|cachedResultUrl)": "1[A-Za-z0-9_\-]{30,}"', r'"\1": "YOUR_GOOGLE_SHEET_ID"'),
    (r'https?://n8n\.[a-z0-9.\-]+\.hstgr\.cloud', 'https://YOUR-N8N-HOST'),
    (r'[A-Za-z0-9._%+\-]+@synergisticaisolns\.com', 'team@example.com'),
    (r'[A-Za-z0-9._%+\-]+@(gmail|yahoo|outlook)\.com', 'user@example.com'),
    (r'\+91[\s\-]?\d{10}\b', '+910000000000'),
    (r'\+1\d{10}\b', '+10000000000'),
    (r'\b9032467289\b', '0000000000'),
    (r'(AGENT_ID\s*=\s*)\d+', r'\g<1>Number($env.OMNIDIM_AGENT_ID || 0)'),
]
for pat, rep in SUBS:
    s = re.sub(pat, rep, s)
open(dst, 'w').write(s + '\n')
