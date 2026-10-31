#!/usr/bin/env python3
"""Install immutable releases; publish the selected release with one rename."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = 'amnezia-proxy-manager'
LIB_FILES = '''vpn_link.py check_ipv6_guard.py sandbox_forwarder.py manager.sh vpn.sh
config.sh diagnostics.sh network.sh check_guard.py session.sh validation.sh
collapse_routes.py proxy.sh sandbox.sh paths.sh ipv6.sh transport.sh guard.sh
runtime.sh tunnel.sh log.sh onboarding.sh config_init.py'''.split()
FILES = {name: name for name in ('apm', 'apm-gui', 'amnezia-proxy-manager', 'bin/amnezia-proxy', 'bin/amnezia-proxy-gui')}
FILES.update({f'lib/{name}': f'lib/{name}' for name in LIB_FILES})
FILES.update({'config.example': 'share/config.example', 'README.md': 'share/doc/README.md',
              'docs/REFERENCE.md': 'share/doc/docs/REFERENCE.md',
              'docs/CONFIGURATION.md': 'share/doc/docs/CONFIGURATION.md',
              'docs/INSTALLATION.md': 'share/doc/docs/INSTALLATION.md'})
FILES = {dest: source for source, dest in FILES.items()}
FILES['share/doc/config.example'] = 'config.example'
FILES['share/doc/AUDIT.md'] = 'AUDIT.md'
for task in ('INSTALLATION', 'COMPONENT_MODES', 'MACOS', 'GO_MIGRATION', 'LOCAL_ISOLATION'):
    FILES[f'share/doc/docs/tasks/{task}.md'] = f'docs/tasks/{task}.md'
EXECUTABLES = {'apm', 'apm-gui', 'amnezia-proxy-manager', 'bin/amnezia-proxy', 'bin/amnezia-proxy-gui'}


def fail(message):
    raise RuntimeError(message)


def absolute(value):
    p = Path(value)
    if not p.is_absolute() or '..' in p.parts or p == Path('/'):
        fail(f'Требуется абсолютный путь, отличный от / и без ..: {value}')
    return p


def no_symlinks(path):
    for p in reversed((path, *path.parents)):
        if p.is_symlink():
            fail(f'Симлинк в пути установки: {p}')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def expected_release(path):
    """Reject modified or foreign files before any recursive deletion/reuse."""
    receipt = path / 'receipt.json'
    if receipt.is_symlink() or not receipt.is_file():
        fail(f'Отсутствует receipt установленной версии: {path}')
    data = json.loads(receipt.read_text())
    if not isinstance(data, dict):
        fail(f'Некорректный receipt: {path}')
    if data.get('application') != APP or not isinstance(data.get('files'), dict) or not data['files']:
        fail(f'Неизвестный состав установленной версии: {path}')
    for name, checksum in data['files'].items():
        part = Path(name)
        if part.is_absolute() or '..' in part.parts or str(part) != name or name == 'receipt.json':
            fail(f'Некорректный путь в receipt: {name}')
        if name not in (APP, 'apm', 'apm-gui') and not name.startswith(('bin/', 'lib/', 'share/')):
            fail(f'Неизвестный путь в receipt: {name}')
        if not isinstance(checksum, str) or not re.fullmatch('[0-9a-f]{64}', checksum):
            fail(f'Некорректный SHA256 в receipt: {name}')
    expected = set(data['files']) | {'receipt.json'}
    expected_dirs = {str(p) for name in expected for p in Path(name).parents if p != Path('.')}
    for item in path.rglob('*'):
        name = str(item.relative_to(path))
        if item.is_symlink() or (item.is_dir() and name not in expected_dirs) or (not item.is_dir() and name not in expected):
            fail(f'Посторонний файл в установке: {item}')
    for name, checksum in data['files'].items():
        item = path / name
        if not item.is_file() or digest(item) != checksum:
            fail(f'Установленный файл изменён: {item}')


@contextlib.contextmanager
def stopped_session(staged):
    if staged:
        yield
        return
    homes = [(Path.home(), os.getuid())]
    if os.environ.get('SUDO_UID'):
        uid = int(os.environ['SUDO_UID'])
        homes.append((Path(pwd.getpwuid(uid).pw_dir), uid))
    paths = set()
    for home, uid in homes:
        runtime = os.environ.get('AMNEZIA_PROXY_RUNTIME_DIR')
        xdg = os.environ.get('XDG_RUNTIME_DIR')
        paths.add(Path(runtime) if runtime else Path(xdg) / APP if xdg else Path(os.environ.get('TMPDIR', '/tmp')) / f'{APP}-{uid}')
        paths.add(Path('/run/user') / str(uid) / APP)
        paths.add(Path('/tmp') / f'{APP}-{uid}')
    with contextlib.ExitStack() as stack:
        for directory in sorted(paths):
            if not directory.exists():
                continue
            no_symlinks(directory)
            for name in ('sandbox.lock', 'manager.lock'):
                lock = directory / name
                if lock.exists() or lock.is_symlink():
                    if lock.is_symlink() or not lock.is_file():
                        fail(f'Небезопасный lock: {lock}')
                    fd = stack.enter_context(lock.open('rb'))
                    try:
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        fail(f'Активная операция; сначала выполните apm stop прежней версией')
            if any(p.name.endswith(('.owner', '.pid')) or p.name == 'session.state' for p in directory.iterdir()):
                fail(f'Осталось состояние в {directory}; выполните apm stop прежней версией')
        yield


@contextlib.contextmanager
def installation_lock(base):
    no_symlinks(base.parent)
    base.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    lock = base.parent / ('.' + APP + '.install.lock')
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'r+') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail('Другая установка или удаление уже выполняется')
        yield


def main():
    os.umask(0o022)
    if len(sys.argv) != 2 or sys.argv[1] not in ('install', 'uninstall'):
        fail('Использование: install.py install|uninstall')
    action = sys.argv[1]
    prefix = absolute(os.environ.get('PREFIX', str(Path.home() / '.local')))
    bindir = absolute(os.environ.get('BINDIR', str(prefix / 'bin')))
    libexec = absolute(os.environ.get('LIBEXECDIR', str(prefix / 'libexec')))
    datadir = absolute(os.environ.get('DATADIR', str(prefix / 'share')))
    stage = absolute(os.environ['DESTDIR']) if os.environ.get('DESTDIR') else None
    def target(p):
        return stage / p.relative_to('/') if stage else p
    base = target(libexec / APP)
    current = base / 'current'
    releases = base / 'releases'
    # Public wrappers point at the logical prefix, never at DESTDIR.
    wrappers = {}
    for command, entry in (('apm', 'apm'), ('apm-gui', 'apm-gui'), (APP, APP), ('amnezia-proxy-gui', 'bin/amnezia-proxy-gui')):
        wrappers[target(bindir / command)] = ('#!/bin/sh\n'
            + 'APP_ROOT=$(CDPATH= cd ' + shlex.quote(str(libexec / APP / 'current'))
            + ' && pwd -P) || exit 1\n'
            + 'exec "$APP_ROOT"/' + entry + ' "$@"\n')
    links = {target(datadir / APP): str(libexec / APP / 'current/share'),
             target(datadir / 'doc' / APP): str(libexec / APP / 'current/share/doc')}
    public = [*wrappers, *links]
    if len(set(public)) != len(public):
        fail('Каталоги команд и данных создают конфликтующие пути')
    for path in public:
        if path == base or base in path.parents or path in base.parents:
            fail(f'Публичный путь пересекается с деревом программы: {path}')
        if any(other != path and other in path.parents for other in public):
            fail(f'Пересекающиеся публичные пути: {path}')
    with stopped_session(stage is not None), installation_lock(base):
        for directory in (base, releases, target(bindir), target(datadir), target(datadir / 'doc')):
            no_symlinks(directory)
        installed = base.exists()
        if installed:
            if not (base / '.managed').is_file() or (base / '.managed').is_symlink() or (base / '.managed').read_text() != APP + '\n':
                fail(f'Чужой каталог: {base}')
            if set(p.name for p in base.iterdir()) != {'.managed', 'releases', 'current'}:
                fail(f'Посторонние файлы в {base}')
            if not current.is_symlink() or not re.fullmatch(r'releases/[0-9a-f]{20}', os.readlink(current)):
                fail(f'Неизвестная ссылка версии: {current}')
            if not current.exists():
                fail(f'Повреждена ссылка версии: {current}')
            for release in releases.iterdir():
                if release.is_symlink() or not release.is_dir() or not re.fullmatch('[0-9a-f]{20}', release.name):
                    fail(f'Чужой файл: {release}')
                expected_release(release)
        for path, content in wrappers.items():
            if path.exists() or path.is_symlink():
                if not installed or path.is_symlink() or not path.is_file() or path.read_text() != content:
                    fail(f'Не перезаписываю чужую команду: {path}')
        for path, dest in links.items():
            if path.exists() or path.is_symlink():
                if not installed or not path.is_symlink() or os.readlink(path) != dest:
                    fail(f'Не перезаписываю чужой путь: {path}')
        if action == 'uninstall':
            if not installed:
                print('Программа не установлена')
                return
            for path in (*wrappers, *links):
                if path.exists() or path.is_symlink():
                    path.unlink()
            shutil.rmtree(base)
            print('Программа удалена; пользовательские конфиги и данные сохранены')
            return
        hashes = {dest: digest(ROOT / source) for dest, source in FILES.items()}
        release_id = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()[:20]
        created = []
        made_base = not installed
        temporary = None
        try:
            releases.mkdir(parents=True, exist_ok=True, mode=0o755)
            if made_base:
                (base / '.managed').write_text(APP + '\n')
                (base / '.managed').chmod(0o644)
            temporary = Path(tempfile.mkdtemp(prefix='.install-', dir=base))
            temporary.chmod(0o755)
            for dest, source in FILES.items():
                out = temporary / dest
                out.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                shutil.copyfile(ROOT / source, out)
                out.chmod(0o755 if source in EXECUTABLES else 0o644)
            (temporary / 'receipt.json').write_text(json.dumps({'application': APP, 'files': hashes}, sort_keys=True))
            (temporary / 'receipt.json').chmod(0o644)
            expected_release(temporary)
            release = releases / release_id
            if not release.exists():
                temporary.rename(release)
                temporary = None
                created.append(release)
            for path, content in wrappers.items():
                path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                if not path.exists():
                    with path.open('x') as f:
                        f.write(content)
                    created.append(path)
                    path.chmod(0o755)
            for path, dest in links.items():
                path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                if not path.is_symlink():
                    path.symlink_to(dest)
                    created.append(path)
            pointer = base / '.next'
            pointer.symlink_to('releases/' + release_id)
            created.append(pointer)
            os.replace(pointer, current)
        except BaseException:
            for p in reversed(created):
                if p.is_dir() and not p.is_symlink():
                    shutil.rmtree(p)
                else:
                    p.unlink(missing_ok=True)
            if made_base and base.exists():
                shutil.rmtree(base)
            raise
        finally:
            if temporary is not None and temporary.exists():
                shutil.rmtree(temporary)
        print(f'Установлено: {bindir / 'apm'} (версия файлов {release_id})')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        print(f'Ошибка установки: {error}', file=sys.stderr)
        sys.exit(1)
