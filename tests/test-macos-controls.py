#!/usr/bin/env python3
"""Native controls regressions using isolated homes and launchctl fakes only."""
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
LABEL = 'io.github.claude-ac.macos-watcher'
COMMAND_SOURCE = REPO / 'mac/native/Sources/ClaudeMenu/Command.swift'


class NativeControlsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='claude-controls-', dir='/private/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.mac = self.root / 'mac'
        self.bin = self.root / 'bin'
        self.mac.mkdir()
        self.bin.mkdir()
        self.app = self.home / 'Applications/Claude Auto Continue.app'
        self.plist = self.home / f'Library/LaunchAgents/{LABEL}.plist'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        self.plist.parent.mkdir(parents=True)
        self.marker = self.app / 'old-install'
        self.marker.write_text('preserve me')
        self.plist.write_bytes(plistlib.dumps({'RunAtLoad': True, 'ProgramArguments': [
            str(self.app / 'Contents/MacOS/ClaudeResume'), 'watch', '--session', 'local_same',
            '--session', 'local_same', '--session', 'local_other']}))
        self.before = self.plist.read_bytes()
        self.calls = self.root / 'calls'
        self.calls.touch()
        self.loaded = self.root / 'loaded'
        self.loaded.touch()
        self.disabled = self.root / 'disabled'
        self.disabled.touch()
        shutil.copy(REPO / 'mac/install-watcher.sh', self.mac)
        built = self.root / 'built.app'
        (built / 'Contents/MacOS').mkdir(parents=True)
        self.write_executable(built / 'Contents/MacOS/ClaudeResume', '#!/bin/bash\nexit 0\n')
        (self.mac / 'build-native.sh').write_text(f'#!/bin/bash\nprintf "%s\\n" "{built}"\n')
        (self.mac / 'install-menu.sh').write_text('#!/bin/bash\nexit 0\n')
        (self.mac / 'build-menu.sh').write_text(f'#!/bin/bash\nprintf "%s\\n" "{built}"\n')
        self.write_executable(self.bin / 'launchctl', '''#!/bin/bash
printf '%s\\n' "$*" >> "$TEST_CALLS"
if [[ "$TEST_MODE" == hang-enable && "$1" == enable ]]; then
  trap '' TERM
  sleep 3
  echo late > "$TEST_LATE"
  exit 0
fi
case "$1" in
print)
  if [[ "$TEST_MODE" == inspect-error || ( "$TEST_MODE" == inspect-after-unload && ! -f "$TEST_LOADED" ) ]]; then echo 'Permission denied' >&2; exit 1; fi
  if [[ -f "$TEST_LOADED" ]]; then
    if [[ -f "$TEST_RUNNING" ]]; then printf 'state = running\\npid = 12345\\n'; else printf 'state = waiting\\n'; fi
    exit 0
  fi
  echo 'Could not find service' >&2; exit 113 ;;
print-disabled)
  if [[ -f "$TEST_DISABLED" ]]; then printf '\"io.github.claude-ac.macos-watcher\" => true\\n'; else printf '{}\\n'; fi ;;
bootout)
  if [[ "$TEST_MODE" == reject ]]; then echo 'Boot-out failed: 5: Input/output error' >&2; exit 5; fi
  if [[ "$TEST_MODE" != stuck ]]; then rm -f "$TEST_LOADED" "$TEST_RUNNING"; fi ;;
enable) rm -f "$TEST_DISABLED" ;;
disable) touch "$TEST_DISABLED" ;;
kickstart) touch "$TEST_RUNNING" ;;
bootstrap)
  if [[ -f "$TEST_DISABLED" ]]; then echo 'Bootstrap failed: service disabled' >&2; exit 5; fi
  touch "$TEST_LOADED" ;;
esac
''')
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin) + ':' + os.environ['PATH'],
                        TEST_CALLS=str(self.calls), TEST_LOADED=str(self.loaded),
                        TEST_DISABLED=str(self.disabled), TEST_RUNNING=str(self.root / 'running'),
                        TEST_LATE=str(self.root / 'late-marker'), TEST_MODE='normal')

    def write_executable(self, path, text):
        path.write_text(text)
        path.chmod(0o700)

    def install(self, *args, mode='normal'):
        return subprocess.run(['bash', str(self.mac / 'install-watcher.sh'), *args],
                              env=dict(self.env, TEST_MODE=mode), capture_output=True, text=True, timeout=12)

    def assert_preserved(self):
        self.assertTrue(self.marker.exists(), 'existing bundle deleted despite unload failure')
        self.assertEqual(self.plist.read_bytes(), self.before)

    def test_rejected_unload_preserves_installation(self):
        for args in [('--uninstall',), ('--session', 'local_same')]:
            with self.subTest(args=args):
                result = self.install(*args, mode='reject')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Boot-out failed', result.stderr)
                self.assert_preserved()

    def test_inspection_error_preserves_installation(self):
        result = self.install('--uninstall', mode='inspect-error')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Permission denied', result.stderr)
        self.assert_preserved()

    def test_inspection_error_after_unload_preserves_installation(self):
        result = self.install('--uninstall', mode='inspect-after-unload')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Permission denied', result.stderr)
        self.assert_preserved()

    def test_unload_timeout_preserves_installation(self):
        result = self.install('--uninstall', mode='stuck')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('still unloading', result.stderr)
        self.assert_preserved()

    def test_uninstall_uses_exact_service_target_and_preserves_data(self):
        data = self.home / 'Library/Application Support/Claude Auto Continue/attempts.json'
        data.parent.mkdir(parents=True)
        data.write_text('retained')
        result = self.install('--uninstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.app.exists())
        self.assertFalse(self.plist.exists())
        self.assertEqual(data.read_text(), 'retained')
        self.assertIn(f'bootout gui/{os.getuid()}/{LABEL}\n', self.calls.read_text())

    def test_absent_service_can_be_uninstalled(self):
        self.loaded.unlink()
        result = self.install('--uninstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('bootout', self.calls.read_text())

    def test_reinstall_enables_and_deduplicates_sessions(self):
        result = self.install('--session', 'local_same', '--session', 'local_same', '--session', 'local_other')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Installed for 2 sessions.', result.stdout)
        args = plistlib.loads(self.plist.read_bytes())['ProgramArguments']
        self.assertEqual(args[2:], ['--session', 'local_same', '--session', 'local_other'])
        calls = self.calls.read_text().splitlines()
        self.assertLess(calls.index(f'enable gui/{os.getuid()}/{LABEL}'),
                        calls.index(f'bootstrap gui/{os.getuid()} {self.plist}'))

    def test_installer_normalizes_duplicate_ids_when_already_enabled(self):
        self.disabled.unlink()
        result = self.install('--session', 'local_same', '--session', 'local_same', '--session', 'local_other')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Installed for 2 sessions.', result.stdout)
        self.assertEqual(plistlib.loads(self.plist.read_bytes())['ProgramArguments'][2:],
                         ['--session', 'local_same', '--session', 'local_other'])

    def test_packaged_instructions_find_installed_controls(self):
        resources = self.home / 'Applications/Claude Auto Continue Menu.app/Contents/Resources'
        resources.mkdir(parents=True)
        self.write_executable(self.bin / 'make', '#!/bin/bash\npwd\n')
        instructions = (REPO / 'CONTROL.md').read_text()
        block = re.search(r'```bash\n(.*?)```', instructions, re.S).group(1)
        result = subprocess.run(['bash', '-e', '-c', block], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(resources))

    def menu_install(self, *args, mode='normal'):
        shutil.copy(REPO / 'mac/install-menu.sh', self.mac / 'menu-real.sh')
        return subprocess.run(['bash', str(self.mac / 'menu-real.sh'), *args],
                              env=dict(self.env, TEST_MODE=mode), capture_output=True, text=True, timeout=12)

    def test_menu_inspection_error_and_rejected_unload_preserve_install(self):
        app = self.home / 'Applications/Claude Auto Continue Menu.app'
        marker = app / 'old-menu'
        plist = self.plist.with_name('io.github.claude-ac.macos-menu.plist')
        for args in [('--uninstall',), ()]:
            for mode, message in [('inspect-error', 'Permission denied'), ('reject', 'Boot-out failed'),
                                  ('inspect-after-unload', 'Permission denied')]:
                with self.subTest(args=args, mode=mode):
                    self.loaded.touch()
                    app.mkdir(exist_ok=True)
                    marker.write_text('preserve menu')
                    plist.write_text('original plist')
                    result = self.menu_install(*args, mode=mode)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)
                    self.assertTrue(marker.exists())
                    self.assertEqual(plist.read_text(), 'original plist')

    def test_menu_uninstall_succeeds_for_loaded_or_absent_service(self):
        app = self.home / 'Applications/Claude Auto Continue Menu.app'
        plist = self.plist.with_name('io.github.claude-ac.macos-menu.plist')
        for loaded in [True, False]:
            with self.subTest(loaded=loaded):
                self.calls.write_text('')
                if loaded:
                    self.loaded.touch()
                else:
                    self.loaded.unlink(missing_ok=True)
                app.mkdir()
                plist.write_text('menu plist')
                result = self.menu_install('--uninstall')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(app.exists())
                self.assertFalse(plist.exists())
                expected = f'bootout gui/{os.getuid()}/io.github.claude-ac.macos-menu\n'
                self.assertEqual(expected in self.calls.read_text(), loaded)

    def prepare_control_apps(self):
        self.write_executable(self.app / 'Contents/MacOS/ClaudeResume', '#!/bin/bash\nexit 0\n')
        menu = self.home / 'Applications/Claude Auto Continue Menu.app/Contents/MacOS/ClaudeMenu'
        menu.parent.mkdir(parents=True, exist_ok=True)
        self.write_executable(menu, '#!/bin/bash\nexit 0\n')
        self.plist.with_name('io.github.claude-ac.macos-menu.plist').write_text('menu plist')

    def test_control_recipes_reject_inspection_errors(self):
        self.prepare_control_apps()
        for target in ['status', 'start', 'stop', 'menu']:
            with self.subTest(target=target):
                self.loaded.touch()
                self.calls.write_text('')
                result = subprocess.run(['/usr/bin/make', '--no-print-directory', '-C', str(REPO), target],
                                        env=dict(self.env, TEST_MODE='inspect-error'), capture_output=True, text=True, timeout=8)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Permission denied', result.stderr)
                self.assertNotIn('Watcher: OFF', result.stdout)
                self.assertNotIn('bootstrap', self.calls.read_text())
                self.assertNotIn('bootout', self.calls.read_text())
                self.assertNotIn('kickstart', self.calls.read_text())

    def test_stop_rejects_inspection_error_after_unload(self):
        result = subprocess.run(['/usr/bin/make', '--no-print-directory', '-C', str(REPO), 'stop'],
                                env=dict(self.env, TEST_MODE='inspect-after-unload'), capture_output=True, text=True, timeout=8)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Permission denied', result.stderr)
        self.assertNotIn('Watcher: OFF', result.stdout)

    def test_control_recipes_accept_only_confirmed_absence(self):
        self.prepare_control_apps()
        for target in ['status', 'start', 'stop', 'menu']:
            with self.subTest(target=target):
                self.loaded.unlink(missing_ok=True)
                (self.root / 'running').unlink(missing_ok=True)
                self.disabled.touch()
                self.calls.write_text('')
                result = subprocess.run(['/usr/bin/make', '--no-print-directory', '-C', str(REPO), target],
                                        env=self.env, capture_output=True, text=True, timeout=8)
                self.assertEqual(result.returncode, 0, result.stderr)
                if target in ['status', 'stop']:
                    self.assertIn('Watcher: OFF (not loaded)', result.stdout)
                    self.assertNotIn('bootstrap', self.calls.read_text())
                    self.assertNotIn('bootout', self.calls.read_text())
                else:
                    plist = self.plist if target == 'start' else self.plist.with_name('io.github.claude-ac.macos-menu.plist')
                    self.assertIn(f'bootstrap gui/{os.getuid()} {plist}\n', self.calls.read_text())
                    self.assertIn('kickstart', self.calls.read_text())
                    self.assertFalse(self.disabled.exists())

    def test_start_stop_preserve_selection_state_and_logs(self):
        self.write_executable(self.app / 'Contents/MacOS/ClaudeResume', '#!/bin/bash\nexit 0\n')
        data = self.home / 'Library/Application Support/Claude Auto Continue/attempts.json'
        log = self.home / 'Library/Logs/Claude Auto Continue/watcher.log'
        for path in [data, log]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('retain this')
        for target, expected, disabled in [('start', 'Watcher: ON (PID 12345)', False),
                                           ('stop', 'Watcher: OFF (not loaded)', True)]:
            result = subprocess.run(['/usr/bin/make', '--no-print-directory', '-C', str(REPO), target],
                                    env=self.env, capture_output=True, text=True, timeout=8)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, result.stdout)
            self.assertEqual(self.disabled.exists(), disabled)
            self.assertEqual(self.plist.read_bytes(), self.before)
            self.assertEqual(data.read_text(), 'retain this')
            self.assertEqual(log.read_text(), 'retain this')

    def test_menu_deadline_applies_to_real_start_with_hung_launchctl(self):
        self.write_executable(self.app / 'Contents/MacOS/ClaudeResume', '#!/bin/bash\nexit 0\n')
        shutil.copy(REPO / 'Makefile', self.root / 'Makefile')
        harness = self.root / 'Harness.swift'
        harness.write_text('''import Foundation
@main struct Harness {
    @MainActor static func main() async {
        let result = await MakeCommand(timeout: .seconds(1)).run("start")
        print(result.exitCode)
        print(result.output)
    }
}
''')
        compiled = subprocess.run(['swiftc', '-swift-version', '6', '-module-cache-path', str(self.root / 'cache'),
                                   str(COMMAND_SOURCE), str(harness), '-o', str(self.root / 'harness')],
                                  env=dict(self.env, TMPDIR=str(self.root)), capture_output=True, text=True, timeout=60)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        start = time.monotonic()
        result = subprocess.run([str(self.root / 'harness')], env=dict(self.env, TEST_MODE='hang-enable', TMPDIR=str(self.root)),
                                capture_output=True, text=True, timeout=6)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], '124', result.stdout)
        self.assertLess(time.monotonic() - start, 2.0)
        self.assertIn('timed out', result.stdout)
        time.sleep(2.2)
        self.assertFalse((self.root / 'late-marker').exists(), 'hung launchctl survived its owning command')

    def test_status_counts_distinct_session_ids(self):
        result = subprocess.run(['/usr/bin/make', '--no-print-directory', '-C', str(REPO), 'status'],
                                env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Selected sessions: 2\n', result.stdout)


if __name__ == '__main__':
    unittest.main()
