"""Test a source-independent installation, packaging, conflicts and rollback."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from install import FILES  # noqa: E402
with tempfile.TemporaryDirectory() as directory:
    base = Path(directory)
    source = base / 'source'
    source.mkdir()
    # Reproduce only the installable source tree, never internal audit/plans.
    names = set(FILES.values()) | {'Makefile', 'scripts/install.py', 'scripts/release.py'}
    assert not any('REVIEW' in name or 'AUDIT' in name or name.startswith('docs/tasks/') for name in names)
    for name in names:
        out = source / name
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, out)
    prefix = base / "prefix with 'quote"
    # Paths must not inherit GitHub runner or developer-shell configuration.
    env = dict(os.environ, HOME=str(base / 'home'),
               XDG_CONFIG_HOME=str(base / 'home/.config'),
               XDG_CACHE_HOME=str(base / 'home/.cache'),
               XDG_STATE_HOME=str(base / 'home/.local/state'),
               XDG_RUNTIME_DIR=str(base / 'xdg-runtime'),
               AMNEZIA_PROXY_STATE_DIR=str(base / 'state'),
               AMNEZIA_PROXY_CACHE_DIR=str(base / 'cache'), PREFIX=str(prefix), DESTDIR='',
               AMNEZIA_PROXY_RUNTIME_DIR=str(base / 'runtime'))
    env.pop('AMNEZIA_PROXY_CONFIG', None)
    env.pop('BINDIR', None); env.pop('LIBEXECDIR', None); env.pop('DATADIR', None)
    def make(action='install', ok=True, override=None):
        r = subprocess.run(['make', action], cwd=source, env=override or env, capture_output=True, text=True)
        assert (r.returncode == 0) == ok, r
        return r
    make()
    make()  # repeat the same installation
    app = prefix / 'bin/apm'
    current = prefix / 'libexec/amnezia-proxy-manager/current'
    first = current.resolve()
    # Hide source tree completely while executing installed commands.
    away = base / 'hidden-source'
    source.rename(away)
    try:
        r = subprocess.run([app, '--version'], cwd=base, env=env, capture_output=True)
        assert r.returncode == 0 and r.stdout.startswith(b'apm '), r
        for alias in ('apm', 'amnezia-proxy-manager'):
            alias_result = subprocess.run([prefix / 'bin' / alias, '--version'], env=env, capture_output=True)
            assert alias_result.returncode == 0 and alias_result.stdout == r.stdout
        for alias in ('apm-gui', 'amnezia-proxy-gui'):
            alias_result = subprocess.run([prefix / 'bin' / alias], env=env, capture_output=True)
            assert alias_result.returncode == 2 and 'Требуется команда'.encode() in alias_result.stderr
        config = base / 'config' 
        config.write_bytes((ROOT / 'tests/fixtures/valid.conf').read_bytes())
        r = subprocess.run([app, '--config', config, 'config', 'validate'], cwd=base, env=env, capture_output=True)
        assert r.returncode == 0, r
        if os.environ.get('APM_INSTALL_NETWORK_TEST') == '1':
            installed_env = dict(env, APM_TEST_PROJECT_ROOT=str(first))
            r = subprocess.run(['python3', ROOT / 'tests/component-lifecycle.py'],
                               cwd=base, env=installed_env, capture_output=True, timeout=40)
            assert r.returncode == 0, r
        onboarding_env = dict(env, APM_TEST_PROJECT_ROOT=str(first))
        r = subprocess.run(['python3', ROOT / 'tests/onboarding.py'], cwd=base,
                           env=onboarding_env, capture_output=True, timeout=40)
        assert r.returncode == 0, r
        # Python helper is available from the same pinned release.
        r = subprocess.run(['python3', first / 'lib/collapse_routes.py'], input=b'192.0.2.0/32\n192.0.2.1/32\n', capture_output=True)
        assert r.returncode == 0 and b'192.0.2.0/31' in r.stdout
    finally:
        away.rename(source)
    runtime = base / 'runtime'
    runtime.mkdir()
    (runtime / 'session.state').write_text('remaining state')
    make(ok=False); make('uninstall', ok=False)
    assert current.resolve() == first and app.exists()
    (runtime / 'session.state').unlink()
    # A read failure during staging preserves the entire previous release.
    fault = r'''
import sys
from unittest.mock import patch
sys.path.insert(0, 'scripts')
import install
original = install.shutil.copyfile
calls = 0
def fail_copy(*args, **kwargs):
    global calls
    calls += 1
    if calls == 2:
        raise OSError('synthetic copy failure')
    return original(*args, **kwargs)
sys.argv = ['install.py', 'install']
with patch.object(install.shutil, 'copyfile', fail_copy):
    install.main()
'''
    result = subprocess.run(['python3', '-c', fault], cwd=source, env=env, capture_output=True)
    assert result.returncode != 0 and b'synthetic copy failure' in result.stderr
    assert current.resolve() == first
    helper = source / 'lib/vpn_link.py'
    helper.unlink()
    make(ok=False)
    assert current.resolve() == first
    shutil.copy2(ROOT / 'lib/vpn_link.py', helper)
    with (source / 'lib/vpn.sh').open('a') as f:
        f.write('\n# new release\n')
    make()
    assert current.resolve() != first and first.exists()
    # Foreign files prevent recursive removal.
    foreign = first / 'foreign'
    foreign.write_text('keep')
    make('uninstall', ok=False)
    assert foreign.read_text() == 'keep'
    foreign.unlink()
    config_dir = base / 'home/.config/amnezia-proxy-manager'
    config_dir.mkdir(parents=True)
    user_config = config_dir / 'config'
    user_config.write_text('private config')
    make('uninstall')
    assert not any((prefix / 'bin' / name).exists() for name in ('apm', 'apm-gui', 'amnezia-proxy-manager', 'amnezia-proxy-gui'))
    assert not app.exists() and user_config.read_text() == 'private config'
    make('uninstall')
    # DESTDIR produces logical paths, never embedded staging paths.
    stage = base / 'stage'
    staged_env = dict(env, PREFIX='/usr', DESTDIR=str(stage))
    (runtime / 'session.state').write_text('not relevant to staged package')
    make(override=staged_env)
    wrapper = (stage / 'usr/bin/apm').read_text()
    assert str(stage) not in wrapper and '/usr/libexec/' in wrapper
    make('uninstall', override=staged_env)
    # Never overwrite unrelated executables.
    app.parent.mkdir(parents=True, exist_ok=True)
    app.write_text('foreign command')
    (runtime / 'session.state').unlink()
    make(ok=False)
    assert app.read_text() == 'foreign command'
print('OK: install/update/uninstall, pinned releases, DESTDIR, active state, foreign paths and source-independent CLI')
