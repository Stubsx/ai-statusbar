#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/lingmou-ecosystem-tests.XXXXXX")"
trap 'rm -rf "$TASK_OUTPUT"' EXIT
"$TASK_ROOT/scripts/with-xcode.sh" swiftc \
    "$TASK_ROOT/AIStatusBar/Sources/PetTheme.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/PetSharing.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/Maintenance.swift" \
    "$TASK_ROOT/tests/EcosystemNativeTests/main.swift" -o "$TASK_OUTPUT/tests"
python3 - "$TASK_OUTPUT" <<'PYZIP'
from pathlib import Path
import sys
import warnings
import zipfile
warnings.simplefilter('ignore', UserWarning)
root = Path(sys.argv[1])
for name, entries in {
    'traversal': [('../idle.png', b'x')],
    'duplicate': [('idle.png', b'x'), ('idle.png', b'y')],
    'multiple': [('one/idle.png', b'x'), ('two/working.png', b'y')],
    'oversize': [('pet.json', b' ' * 70000)],
    'image-limit': [('idle.png', b' ' * (33 * 1024 * 1024))],
}.items():
    with zipfile.ZipFile(root / (name + '.zip'), 'w', zipfile.ZIP_DEFLATED) as archive:
        for entry, data in entries:
            archive.writestr(entry, data)
PYZIP
"$TASK_OUTPUT/tests" "$TASK_OUTPUT"
