import os
from pathlib import Path
import subprocess
import json
import hashlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('BASH', 'C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else '/bin/bash')


class InstallerTests(unittest.TestCase):
    def run_shell(self, command, env=None):
        return subprocess.run([BASH, '-c', command], cwd=ROOT,
                              capture_output=True, text=True, encoding='utf-8', env=env)

    def test_bootstrap_main_in_disposable_filesystem(self):
        # Only absolute filesystem locations and external commands are adapted.
        # main(), traps, config preservation and admission logic are unchanged.
        for manager in ('apk', 'opkg'):
            for mode in ('success', 'activate', 'installed', 'existing_files', 'existing_rpc',
                         'bad_digest', 'install_failure', 'restart_failure', 'pending'):
                with self.subTest(manager=manager, mode=mode), tempfile.TemporaryDirectory(dir=ROOT) as tmp:
                    root = Path(tmp)
                    shell_root = self.run_shell(f"cd '{root.as_posix()}' && pwd -P").stdout.strip()
                    for folder in ('etc/config', 'etc/init.d', 'usr/share/rpcd/ucode', 'www/luci-static', 'tmp', 'bin'):
                        (root / folder).mkdir(parents=True, exist_ok=True)
                    (root / 'etc/openwrt_release').write_text('OpenWrt fixture', encoding='utf-8')
                    config = 'config core main\n option mediaurlbase /luci-static/bootstrap\n option custom keep\n'
                    (root / 'etc/config/luci').write_text(config, encoding='utf-8')
                    if mode == 'existing_files':
                        (root / 'www/luci-static/proton2025').mkdir()
                    if mode == 'existing_rpc':
                        (root / 'usr/share/rpcd/ucode/luci.proton-packages').write_text('foreign', encoding='utf-8')
                    source = (ROOT / 'install-proton2025-theme.sh').read_text(encoding='utf-8')
                    for prefix in ('/etc/', '/usr/', '/www/', '/tmp/'):
                        source = source.replace(prefix, shell_root + prefix)
                    (root / 'installer.sh').write_text(source, encoding='utf-8', newline='\n')
                    scripts = {
                        'bin/id': 'echo 0',
                        'bin/uci': '''case "$1" in
changes) [ "$TEST_MODE" != pending ] || echo luci.main.custom=unsaved;;
set) printf 'activated\\n' >> "$TEST_ROOT/etc/config/luci";;
commit) :;;
*) exit 1;; esac''',
                        'bin/jq': 'exit 1',  # Presence only; JSON adapter below parses fixture fields.
                        f'bin/{manager}': '''case "$1" in
info) [ "$TEST_MODE" = installed ];;
status) if [ "$TEST_MODE" = installed ]; then printf 'Status: install user installed\\n'; fi;;
add|install) echo install >> "$TEST_ROOT/pm-calls"
 printf damaged > "$TEST_ROOT/etc/config/luci"
 [ "$TEST_MODE" != install_failure ];;
*) exit 1;; esac''',
                        'etc/init.d/rpcd': '[ "$TEST_MODE" != restart_failure ]',
                        'etc/init.d/uhttpd': 'exit 0',
                    }
                    for name, body in scripts.items():
                        path = root / name
                        path.write_text('#!/bin/sh\nset -eu\n' + body + '\n', encoding='utf-8', newline='\n')
                        path.chmod(0o755)
                    asset = 'luci-theme-proton2025-1.4.4-r1.apk' if manager == 'apk' else 'luci-theme-proton2025_1.4.4_all.ipk'
                    payload = b'isolated fake package'
                    (root / 'package').write_bytes(payload)
                    digest = hashlib.sha256(payload).hexdigest() if mode != 'bad_digest' else '0' * 64
                    (root / 'release.json').write_text(json.dumps({'tag_name': 'v1.4.4', 'assets': [{
                        'name': asset, 'digest': 'sha256:' + digest,
                        'browser_download_url': f'https://github.com/ChesterGoodiny/luci-theme-proton2025/releases/download/v1.4.4/{asset}'}]}), encoding='utf-8')
                    env = dict(os.environ, TEST_ROOT=shell_root, TEST_MODE=mode,
                               PROTON2025_VERSION='v1.4.4', PROTON2025_ACTIVATE='1' if mode == 'activate' else '0')
                    result = self.run_shell(
                        f'export PATH="{shell_root}/bin:$PATH"; PROTON2025_LIBRARY_ONLY=1 . "{shell_root}/installer.sh"; '
                        'json_get() { python tests/test_installer.py --field "$1" "$2"; }; '
                        'download() { case "$1" in */release*/*) cp "$TEST_ROOT/release.json" "$2";; esac; '
                        'case "$1" in *.apk|*.ipk) cp "$TEST_ROOT/package" "$2";; esac; }; main', env=env)
                    success = mode in ('success', 'activate')
                    self.assertEqual(result.returncode == 0, success, result.stderr)
                    self.assertEqual((root / 'pm-calls').exists(), mode in ('success', 'activate', 'install_failure', 'restart_failure'))
                    self.assertEqual((root / 'etc/config/luci').read_text(encoding='utf-8'), config + ('activated\n' if mode == 'activate' else ''))
                    self.assertEqual(list((root / 'tmp').iterdir()), [])

    def test_missing_version_rejected_before_any_install(self):
        result = self.run_shell('env -u PROTON2025_VERSION sh install-proton2025-theme.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PROTON2025_VERSION', result.stderr)

    def test_existing_theme_uses_transactional_upgrade(self):
        result = self.run_shell('PROTON2025_LIBRARY_ONLY=1 . ./install-proton2025-theme.sh; '
                                'command -v update_existing')
        self.assertEqual(result.returncode, 0, 'existing installations still have no upgrade route')

    def test_backend_pins_and_routerdesk_copy_match(self):
        code = (ROOT / 'install-proton2025-theme.sh').read_text(encoding='utf-8')
        for backend in ('proton-transaction.sh', 'proton-dependencies.sh', 'proton-luci-health.sh'):
            data = (ROOT / 'lib' / backend).read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            self.assertIn(f'{backend}) backend_hash={digest};;', code)
            rd = ROOT.parent / 'RouterDesk/RouterDesk.Core/Scripts' / backend
            if rd.exists():
                self.assertEqual(rd.read_text(encoding='utf-8'), data.decode('utf-8'), backend)

    def test_same_version_is_noop_and_downgrade_is_refused(self):
        for installed, expected in [('1.4.4', 0), ('1.4.5', 1)]:
            result = self.run_shell('PROTON2025_LIBRARY_ONLY=1 . ./install-proton2025-theme.sh; '
                                    f'PROTON2025_VERSION=v1.4.4; update_existing {installed}')
            self.assertEqual(result.returncode, expected, result.stderr)

    def test_invalid_version_rejected(self):
        result = self.run_shell("PROTON2025_VERSION='v1; touch /tmp/injected' sh install-proton2025-theme.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PROTON2025_VERSION', result.stderr)

    def test_version_requires_exact_three_numeric_components(self):
        for version in ('v1.4.4', 'v25.12.5', 'v1v.4.4', 'v1.4.4.5',
                        'v1.4.4v', 'v1..4', '1.4.4', 'v1.4', '', 'v1.4.4\nv9.0.0'):
            with self.subTest(version=version):
                result = self.run_shell(
                    'PROTON2025_LIBRARY_ONLY=1 . ./install-proton2025-theme.sh; '
                    f"PROTON2025_VERSION='{version}'; validate_version")
                self.assertEqual(result.returncode == 0, version in ('v1.4.4', 'v25.12.5'), result.stderr)

    def test_digest_verification_rejects_mismatch(self):
        result = self.run_shell("PROTON2025_LIBRARY_ONLY=1 . ./install-proton2025-theme.sh; verify_digest README.md sha256:0000000000000000000000000000000000000000000000000000000000000000")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SHA-256', result.stderr)

    def test_digest_verification_accepts_real_digest(self):
        result = self.run_shell('PROTON2025_LIBRARY_ONLY=1 . ./install-proton2025-theme.sh; hash=$(sha256sum README.md); verify_digest README.md "sha256:${hash%% *}"')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_no_custom_rpc_patch_or_forced_activation(self):
        code = (ROOT / 'install-proton2025-theme.sh').read_text(encoding='utf-8')
        self.assertNotIn('patch_theme_updater', code)
        self.assertNotIn('runCommand', code)
        self.assertIn('PROTON2025_ACTIVATE', code)

    def test_bootstrap_preserves_luci_config_even_if_package_postinstall_changes_it(self):
        code = (ROOT / 'install-proton2025-theme.sh').read_text(encoding='utf-8')
        self.assertIn('cp -p /etc/config/luci "$TMP_DIR/luci.before"', code)
        self.assertIn('cp -p "$TMP_DIR/luci.before" /etc/config/luci', code)

    def test_asset_selection_exact_rejects_duplicate_and_foreign_url(self):
        # The adapter supplies parsed JSON fields; selection logic remains real shell.
        asset = 'luci-theme-proton2025_1.4.2_all.ipk'
        valid = {'name': asset, 'browser_download_url':
                 f'https://github.com/ChesterGoodiny/luci-theme-proton2025/releases/download/v1.4.2/{asset}',
                 'digest': 'sha256:' + 'a' * 64}
        cases = [([valid], 'v1.4.2', 0), ([valid, valid], 'v1.4.2', 1),
                 ([dict(valid, name='other.ipk')], 'v1.4.2', 1),
                 ([dict(valid, browser_download_url='https://evil.invalid/package')], 'v1.4.2', 1),
                 ([valid], 'v9.0.0', 1)]
        for assets, tag, expected in cases:
            with self.subTest(assets=assets, tag=tag), tempfile.TemporaryDirectory(dir=ROOT) as tmp:
                fixture = Path(tmp) / 'release.json'
                fixture.write_text(json.dumps({'tag_name': tag, 'assets': assets}), encoding='utf-8')
                relative = fixture.relative_to(ROOT).as_posix()
                result = self.run_shell(
                    "PROTON2025_LIBRARY_ONLY=1 . ./install-proton2025-theme.sh; "
                    "json_get() { python tests/test_installer.py --field \"$1\" \"$2\"; }; "
                    f"PROTON2025_VERSION=v1.4.2; select_asset '{relative}' '{asset}'")
                self.assertEqual(result.returncode, expected, result.stderr)


if __name__ == '__main__':
    import re
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == '--field':
        data = json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
        try:
            for part in re.findall(r'[A-Za-z_]+|\d+', sys.argv[3]):
                data = data[int(part)] if part.isdigit() else data[part]
            print(data)
        except (KeyError, IndexError):
            pass
    else:
        unittest.main()
