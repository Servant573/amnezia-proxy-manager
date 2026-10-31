"""Safe initial config and offline dependency checks, without host changes."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    base = Path(directory)
    env = dict(os.environ, HOME=str(base / 'home'), XDG_CONFIG_HOME=str(base / 'config'),
               AMNEZIA_PROXY_RUNTIME_DIR=str(base / 'runtime'),
               AMNEZIA_PROXY_STATE_DIR=str(base / 'state'), AMNEZIA_PROXY_CACHE_DIR=str(base / 'cache'))
    env.pop('AMNEZIA_PROXY_CONFIG', None)
    cli = Path(os.environ.get('APM_TEST_PROJECT_ROOT', ROOT)) / 'bin/amnezia-proxy'
    def run(*args, override=None):
        return subprocess.run(['/bin/bash', cli, *args], env=override or env, cwd=base,
                              capture_output=True, text=True, timeout=8)
    result = run('config', 'init')
    assert result.returncode == 0, result
    config = base / 'config/amnezia-proxy-manager/config'
    assert config.read_bytes() == (ROOT / 'config.example').read_bytes()
    assert stat.S_IMODE(config.stat().st_mode) == 0o600
    assert stat.S_IMODE(config.parent.stat().st_mode) == 0o700
    assert not any((base / n).exists() for n in ('runtime', 'state', 'cache'))
    config.write_text('original-private-config')
    assert run('config', 'init').returncode != 0
    assert config.read_text() == 'original-private-config'
    explicit = base / 'explicit/config with spaces'
    assert run('--config', str(explicit), 'config', 'init').returncode == 0
    env_file = base / 'env/config'
    assert run('config', 'init', override=dict(env, AMNEZIA_PROXY_CONFIG=str(env_file))).returncode == 0
    assert run('--config', 'relative-config', 'config', 'init').returncode == 0
    link = base / 'dangling'
    link.symlink_to(base / 'must-not-create')
    assert run('--config', str(link), 'config', 'init').returncode != 0
    assert link.is_symlink() and not (base / 'must-not-create').exists()
    parent = base / 'linked-parent'
    parent.symlink_to(config.parent)
    assert run('--config', str(parent / 'child'), 'config', 'init').returncode != 0
    assert not (config.parent / 'child').exists()
    unsafe = base / 'unsafe'
    unsafe.mkdir(mode=0o777); unsafe.chmod(0o777)
    assert run('--config', str(unsafe / 'config'), 'config', 'init').returncode != 0
    assert stat.S_IMODE(unsafe.stat().st_mode) == 0o777
    racing = base / 'race/config'
    processes = [subprocess.Popen(['/bin/bash', cli, '--config', racing, 'config', 'init'], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
    codes = []
    for process in processes:
        process.communicate(timeout=8)
        codes.append(process.returncode)
    assert sorted(codes) == [0, 1], codes
    assert racing.read_bytes() == (ROOT / 'config.example').read_bytes()
    assert not list(racing.parent.glob('.config-init-*'))
    # Hermetic PATH: available dependencies must not be executed by doctor.
    commands = base / 'commands'
    commands.mkdir()
    for name in ('dirname', 'stat', 'uname'):
        (commands / name).symlink_to(Path('/usr/bin') / name)
    config.write_text('VPN_ON=0\nPROXY_ON=1\nBLOCK_IPV6=off\nPROXY_STRING=203.0.113.1:3128:user:password\n')
    doctor_env = dict(env, PATH=str(commands))
    result = run('doctor', override=doctor_env)
    assert result.returncode == 1 and 'MISSING: 3proxy' in result.stdout and 'MISSING: curl' in result.stdout, result
    assert 'MISSING: awg' not in result.stdout and 'MISSING: sudo' not in result.stdout, result
    marker = base / 'dependency-was-executed'
    for name in ('flock', 'timeout', 'getent', '3proxy', 'ss', 'curl'):
        tool = commands / name
        tool.write_text(f'#!/bin/sh\necho executed > "{marker}"\nexit 99\n')
        tool.chmod(0o755)
    result = run('doctor', override=doctor_env)
    assert result.returncode == 0 and not marker.exists(), result
    result = run('doctor', '--sandbox', override=doctor_env)
    assert result.returncode == 1 and 'MISSING: bwrap' in result.stdout and 'MISSING: setpriv' in result.stdout, result
    assert run('doctor', '--invalid', override=doctor_env).returncode == 2
    # Missing config is allowed; default-mode requirements are reported.
    config.unlink()
    result = run('doctor', override=doctor_env)
    assert 'INFO: конфиг отсутствует' in result.stdout and 'MISSING: awg' in result.stdout, result
    # Conditional DNS dependency from a valid VPN config.
    config.write_bytes((ROOT / 'tests/fixtures/valid.conf').read_bytes())
    with config.open('a') as f:
        f.write('\nDNS=1.1.1.1\n')
    result = run('doctor', override=doctor_env)
    assert 'MISSING: resolvconf' in result.stdout, result
    with config.open('a') as f:
        f.write('PROXY_ON=0\n')
    result = run('doctor', override=doctor_env)
    assert '3proxy' not in result.stdout and 'MISSING: awg' in result.stdout, result
    result = run('doctor', '--sandbox', override=doctor_env)
    assert result.returncode == 1 and 'run требует включённый proxy' in result.stdout, result
    config.write_text('TYPO=private-marker\n')
    result = run('doctor', override=doctor_env)
    assert result.returncode == 1 and 'config validate' in result.stdout, result
    assert 'private-marker' not in result.stdout + result.stderr
    assert not marker.exists()
    assert not any((base / n).exists() for n in ('runtime', 'state', 'cache'))
print('OK: config init permissions, no-overwrite, symlinks, race; doctor offline dependency matrix and no writes')
