"""Writes the license text of every installed top-level package in Tooling's lockfile, sorted by name.

Usage: python3 Scripts/licenses.py Tooling > Licenses/JavaScript-dependencies.txt
Nested copies (another version installed inside a dependent package) are listed by their install path,
such as `mermaid/node_modules/katex`. Packages without a license file in their directory (such as
esbuild's platform binaries) are skipped.
"""
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
lock = json.loads((root / 'package-lock.json').read_text())
entries = []
for path, info in lock['packages'].items():
    name = path[len('node_modules/'):]
    directory = root / path
    if not path.startswith('node_modules/') or not directory.is_dir():
        continue
    files = sorted(p for p in directory.iterdir() if p.is_file() and p.name.lower().startswith(('license', 'licence')))
    if not files:
        continue
    text = '\n'.join(p.read_text() for p in files)
    entries.append((name, f"\n\n{name} {info['version']}\n{info.get('license', '')}\n\n{text}"))
sys.stdout.write('\n'.join(entry for _, entry in sorted(entries)).rstrip('\n'))
