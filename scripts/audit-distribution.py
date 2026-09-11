#!/usr/bin/env python3
"""Checagem local complementar; não substitui revisão de texto e capturas."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
ignored = {'.git', '.build', 'dist', '__pycache__'}
private_names = {'.config.json', '.glossario.json', '.voiceprints.json', 'auth.json',
                 'transcript.md', 'resumo.md', 'notas.md', 'segments.json', 'speakers.json',
                 'chat.json', 'meta.json', 'followup.md', '.env'}
private_suffixes = {'.wav', '.caf', '.mp3', '.m4a', '.pem', '.key', '.p12', '.pfx', '.bak'}
patterns = [
    re.compile(r'/' r'Users/(?!\$|<|you(?:/|\b)|user(?:/|\b))[^/\s]+/'),
    re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    re.compile(r'\b(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}'),
    re.compile(r'\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{30,}'),
]
issues = []
count = 0
for path in sorted(root.rglob('*')):
    relative = path.relative_to(root)
    if any(part in ignored for part in relative.parts) or not path.is_file():
        continue
    count += 1
    if path.name in private_names or path.suffix.lower() in private_suffixes or path.name.startswith('.env.'):
        issues.append(f'Arquivo privado: {relative}')
    if path.suffix in {'.swift', '.md', '.json', '.sh', '.py', '.yml', '.plist'} or path.name in {'Makefile', 'LICENSE'}:
        text = path.read_text(errors='replace')
        if any(pattern.search(text) for pattern in patterns):
            issues.append(f'Revisar conteúdo sensível: {relative}')
if issues:
    print('\n'.join(issues))
    sys.exit(1)
print(f'OK: {count} arquivos revisados; nenhum arquivo de usuário, chave ou caminho pessoal detectado.')
