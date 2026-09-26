#!/usr/bin/env python3
"""Sync a bounded common-policy block without replacing personal instructions."""
import argparse
import os
import shutil
import tempfile
from pathlib import Path

START = '<!-- agent-harness:operating-contract:start -->'
END = '<!-- agent-harness:operating-contract:end -->'
ROOT = Path(__file__).resolve().parents[2]


def render(existing, policy):
    block = START + '\n' + policy.rstrip() + '\n' + END
    if START not in existing and END not in existing:
        return block + '\n\n' + existing
    if existing.count(START) != 1 or existing.count(END) != 1:
        raise ValueError('malformed or repeated managed markers; refusing to overwrite')
    a, b = existing.index(START), existing.index(END)
    if b < a:
        raise ValueError('reversed managed markers; refusing to overwrite')
    return existing[:a] + block + existing[b + len(END):]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--claude', type=Path, help='Claude instruction file (not settings JSON)')
    parser.add_argument('--codex', type=Path, help='Codex instruction file (not config TOML)')
    parser.add_argument('--check', action='store_true', help='read-only; exit 1 on drift')
    args = parser.parse_args()
    targets = [p for p in (args.claude, args.codex) if p is not None]
    if not targets:
        targets = [Path.home() / '.claude/CLAUDE.md',
                   Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'AGENTS.md']
    policy = (ROOT / 'rules/policy/operating-contract.md').read_text()
    # Validate every target before changing any of them.
    pending = []
    for target in dict.fromkeys(targets):
        if target.is_symlink():
            raise ValueError(f'{target}: symlink target must be supplied explicitly')
        old = target.read_bytes().decode('utf-8') if target.exists() else ''
        new = render(old, policy)
        pending.append((target, old, new))
    drift = False
    for target, old, new in pending:
        if old == new:
            print(f'OK {target}')
            continue
        drift = True
        if args.check:
            print(f'DRIFT {target}')
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            fd, backup = tempfile.mkstemp(prefix=target.name + '.before-sync-', dir=target.parent)
            os.close(fd)
            shutil.copyfile(target, backup)
            print(f'BACKUP {backup}')
        fd, temporary = tempfile.mkstemp(prefix='.' + target.name + '.', dir=target.parent)
        try:
            with os.fdopen(fd, 'w', encoding='utf-8', newline='') as stream:
                stream.write(new)
            if target.exists():
                os.chmod(temporary, target.stat().st_mode & 0o777)
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        print(f'UPDATED {target}')
    return int(args.check and drift)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        raise SystemExit(str(exc))
