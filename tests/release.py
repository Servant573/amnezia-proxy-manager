"""Reproducibility, manifest and archive-only installation without Git."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from install import EXECUTABLES, FILES  # noqa: E402

with tempfile.TemporaryDirectory() as directory:
    base = Path(directory)
    source = base / 'source'
    names = set(FILES.values()) | {'Makefile', 'scripts/install.py', 'scripts/release.py', 'LICENSE', 'CHANGELOG.md'}
    assert not any('REVIEW' in name or 'AUDIT' in name or name.startswith('docs/tasks/') for name in names)
    for name in names:
        out = source / name
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, out)
    for name in ('AUDIT.md', 'REVIEW_demo.md', 'FIX_REVIEW_demo.md', 'docs/tasks/private-plan.md'):
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('synthetic-internal-document')
    (source / 'local.conf').write_text('PRIVATE_KEY=synthetic-secret')
    (source / '.git').mkdir()
    (source / '.git/private').write_text('synthetic-git-data')
    (source / 'tests').mkdir()
    (source / 'tests/not-shipped').write_text('synthetic-test-data')
    # Paths must not inherit GitHub runner or developer-shell configuration.
    env = dict(os.environ, HOME=str(base / 'home'),
               XDG_CONFIG_HOME=str(base / 'home/.config'),
               XDG_CACHE_HOME=str(base / 'home/.cache'),
               XDG_STATE_HOME=str(base / 'home/.local/state'),
               XDG_RUNTIME_DIR=str(base / 'xdg-runtime'),
               AMNEZIA_PROXY_STATE_DIR=str(base / 'state'),
               AMNEZIA_PROXY_CACHE_DIR=str(base / 'cache'), DISTDIR=str(base / 'out'),
               SOURCE_DATE_EPOCH='0', PREFIX=str(base / 'installed'), DESTDIR='',
               AMNEZIA_PROXY_RUNTIME_DIR=str(base / 'runtime'))
    env.pop('AMNEZIA_PROXY_CONFIG', None)
    for key in ('BINDIR', 'LIBEXECDIR', 'DATADIR'):
        env.pop(key, None)
    def make(target, cwd=source, ok=True, override=None):
        result = subprocess.run(['make', target], cwd=cwd, env=override or env,
                                capture_output=True, text=True, timeout=30)
        assert (result.returncode == 0) == ok, result
        return result
    make('dist')
    archive, = (base / 'out').glob('*.tar.gz')
    first = archive.read_bytes()
    # Source timestamps and umask do not affect normalized metadata.
    for name in names:
        os.utime(source / name, (1700000000, 1700000000))
    previous_umask = os.umask(0o077)
    try:
        make('dist')
    finally:
        os.umask(previous_umask)
    assert archive.read_bytes() == first
    value, filename = (base / 'out' / (archive.name + '.sha256')).read_text().split()
    assert filename == archive.name and value == hashlib.sha256(first).hexdigest()
    with tarfile.open(archive) as tar:
        members = tar.getmembers()
        roots = {Path(m.name).parts[0] for m in members}
        assert len(roots) == 1
        stem = roots.pop()
        assert all(not Path(m.name).is_absolute() and '..' not in Path(m.name).parts and
                   (m.isdir() or m.isfile()) for m in members)
        files = {str(Path(m.name).relative_to(stem)): m for m in members if m.isfile()}
        assert set(files) == names | {'RELEASE.json'}
        manifest = json.load(tar.extractfile(files['RELEASE.json']))
        assert archive.name == f'apm-{manifest["version"]}-linux.tar.gz'
        assert manifest['license'] == 'MIT' and manifest['platform'] == 'linux'
        assert set(manifest['files']) == names
        for name, info in manifest['files'].items():
            member = files[name]
            assert hashlib.sha256(tar.extractfile(member).read()).hexdigest() == info['sha256']
            assert member.mode == (0o755 if name in EXECUTABLES else 0o644)
            assert int(info['mode'], 8) == member.mode
            assert member.uid == member.gid == member.mtime == 0
        extracted = base / 'extracted'
        # All entries were checked above; no links or traversal can be extracted.
        tar.extractall(extracted)
    tree = extracted / stem
    source.rename(base / 'source-hidden')
    make('install', cwd=tree)
    app = base / 'installed/bin/apm'
    result = subprocess.run([app, '--version'], env=env, cwd=base, capture_output=True, text=True)
    assert result.returncode == 0 and result.stdout.strip() == f'apm {manifest["version"]}', result
    result = subprocess.run([app, 'config', 'init'], env=env, cwd=base, capture_output=True)
    assert result.returncode == 0, result
    config = base / 'home/.config/amnezia-proxy-manager/config'
    before = config.read_bytes()
    assert before == (tree / 'config.example').read_bytes()
    metadata = base / 'installed/share/doc/amnezia-proxy-manager'
    assert (metadata / 'LICENSE').read_bytes() == (tree / 'LICENSE').read_bytes()
    make('uninstall', cwd=tree)
    assert not app.exists() and config.read_bytes() == before
    # The extracted distribution can reproduce itself with no Git/source checkout.
    make('dist', cwd=tree, override=dict(env, DISTDIR=str(base / 'rebuilt')))
    assert (base / 'rebuilt' / archive.name).read_bytes() == first
    make('dist', cwd=tree, ok=False, override=dict(env, SOURCE_DATE_EPOCH='-1'))
    original_license = (tree / 'LICENSE').read_bytes()
    (tree / 'LICENSE').unlink()
    (tree / 'LICENSE').symlink_to(tree / 'CHANGELOG.md')
    make('dist', cwd=tree, ok=False)
    (tree / 'LICENSE').unlink()
    (tree / 'LICENSE').write_bytes(original_license)
    original_cli = (tree / 'bin/amnezia-proxy').read_bytes()
    (tree / 'bin/amnezia-proxy').write_bytes(original_cli.replace(
        f'VERSION="{manifest["version"]}"'.encode(), b'VERSION="99.0.0"', 1))
    make('dist', cwd=tree, ok=False)
    assert archive.read_bytes() == first
print('OK: deterministic release, SHA256, explicit payload, manifest, archive-only install/init/uninstall and rebuild')
