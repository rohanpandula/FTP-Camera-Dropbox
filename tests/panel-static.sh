#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
panel="$repo_root/panel/index.html"
sed -n '/<script>/,/<\/script>/p' "$panel" | sed '1d;$d' | node --check --input-type=commonjs

python3 - "$panel" <<'PY'
from pathlib import Path
import sys

html = Path(sys.argv[1]).read_text()

required = (
    '["now", "Now"]',
    '["library", "Library"]',
    '["attention", "Attention"]',
    '["automations", "Automations"]',
    'overview: "now"',
    'folders: "library"',
    'quarantine: "attention"',
    'rules: "automations"',
    'decisions: "attention"',
    'switches: "automations"',
    'const esc = value =>',
    'data-armed="0"',
    '/api/status',
    '/api/library',
    '/api/quarantine',
    '/api/decisions',
    '/api/config',
)

for marker in required:
    assert marker in html, f"missing panel contract: {marker}"

import re

assert re.search(r"\son[a-z]+\s*=", html) is None, "use delegated handlers, not inline events"
assert "style=" not in html, "keep presentation in the design system"
assert html.count("f=${encodeURIComponent(") >= 2, "thumb URLs must encodeURIComponent the rel path"
PY

echo "panel static checks passed"
