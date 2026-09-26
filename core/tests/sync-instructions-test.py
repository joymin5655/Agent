#!/usr/bin/env python3
"""Behavioral tests for instruction synchronization, isolated from user settings."""
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'core/infra/sync-instructions.py'
spec = importlib.util.spec_from_file_location('sync_instructions', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SyncTests(unittest.TestCase):
    def test_preserves_personal_text_on_refresh(self):
        text = 'before\n' + module.START + '\nold\n' + module.END + '\nafter\n'
        self.assertEqual(module.render(text, 'new'),
                         'before\n' + module.START + '\nnew\n' + module.END + '\nafter\n')

    def test_rejects_broken_markers(self):
        for text in [module.START, module.END, module.END + module.START,
                     module.START * 2 + module.END]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                module.render(text, 'new')

    def test_check_apply_repeat_and_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / 'CLAUDE.md'
            p.write_text('personal\n')
            cmd = ['python3', str(SCRIPT), '--claude', str(p)]
            self.assertEqual(subprocess.run(cmd + ['--check'], capture_output=True, check=False).returncode, 1)
            self.assertEqual(p.read_text(), 'personal\n')
            self.assertEqual(list(Path(directory).iterdir()), [p])
            subprocess.run(cmd, check=True, capture_output=True)
            self.assertTrue(p.read_text().endswith('personal\n'))
            backups = list(Path(directory).glob('*.before-sync-*'))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(), 'personal\n')
            before = p.stat().st_mtime_ns
            subprocess.run(cmd, check=True, capture_output=True)
            self.assertEqual(p.stat().st_mtime_ns, before)
            self.assertEqual(len(list(Path(directory).glob('*.before-sync-*'))), 1)
            self.assertEqual(subprocess.run(cmd + ['--check'], capture_output=True, check=False).returncode, 0)

    def test_validates_all_before_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            a, b = Path(directory) / 'a', Path(directory) / 'b'
            a.write_text('original'); b.write_text(module.START)
            result = subprocess.run(['python3', str(SCRIPT), '--claude', str(a),
                                     '--codex', str(b)], capture_output=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(a.read_text(), 'original')

    def test_preserves_crlf_personal_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / 'AGENTS.md'
            p.write_bytes(b'personal\r\nsecond line\r\n')
            subprocess.run(['python3', str(SCRIPT), '--codex', str(p)],
                           check=True, capture_output=True)
            self.assertTrue(p.read_bytes().endswith(b'personal\r\nsecond line\r\n'))
            before = p.read_bytes()
            subprocess.run(['python3', str(SCRIPT), '--codex', str(p), '--check'],
                           check=True, capture_output=True)
            self.assertEqual(p.read_bytes(), before)

    def test_missing_and_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            a = Path(directory) / 'missing' / 'AGENTS.md'
            cmd = ['python3', str(SCRIPT), '--codex', str(a)]
            self.assertEqual(subprocess.run(cmd + ['--check'], capture_output=True, check=False).returncode, 1)
            self.assertFalse(a.parent.exists())
            subprocess.run(cmd, check=True, capture_output=True)
            link = Path(directory) / 'link'; link.symlink_to(a)
            result = subprocess.run(['python3', str(SCRIPT), '--codex', str(link)], capture_output=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(link.is_symlink())


if __name__ == '__main__':
    unittest.main()
