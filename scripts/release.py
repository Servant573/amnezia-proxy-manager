#!/usr/bin/env python3
"""Build a deterministic source distribution from an explicit allowlist."""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import tarfile
import tempfile

from install import EXECUTABLES, FILES, ROOT


def build():
    epoch = int(os.environ.get('SOURCE_DATE_EPOCH', '0'))
    if not 0 <= epoch <= 4294967295:
        raise ValueError('SOURCE_DATE_EPOCH должен быть от 0 до 4294967295')
    names = set(FILES.values()) | {'Makefile', 'scripts/install.py', 'scripts/release.py', 'LICENSE', 'CHANGELOG.md'}
    payload = {}
    for name in sorted(names):
        path = ROOT / name
        if any(parent.is_symlink() for parent in (path, *path.parents)) or not path.is_file():
            raise ValueError(f'Необычный или отсутствующий файл поставки: {name}')
        payload[name] = path.read_bytes()
    match = re.search(rb'^VERSION="([^"]+)"$', payload['bin/amnezia-proxy'], re.M)
    if not match:
        raise ValueError('Не найдена версия CLI')
    version = match.group(1).decode('ascii')
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?', version):
        raise ValueError('Некорректная версия CLI')
    if f'## {version} '.encode() not in payload['CHANGELOG.md']:
        raise ValueError('Для версии CLI отсутствует раздел CHANGELOG.md')
    manifest = {'version': version, 'platform': 'linux', 'license': 'MIT',
                'files': {name: {'sha256': hashlib.sha256(content).hexdigest(),
                                 'mode': '0755' if name in EXECUTABLES else '0644'}
                          for name, content in payload.items()}}
    payload['RELEASE.json'] = (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode()
    stem = f'apm-{version}-linux'
    out = Path(os.environ.get('DISTDIR', str(ROOT / 'dist'))).absolute()
    out.mkdir(parents=True, exist_ok=True)
    archive = out / (stem + '.tar.gz')
    checksum = out / (archive.name + '.sha256')
    with tempfile.TemporaryDirectory(prefix='.release-', dir=out) as temporary:
        staged = Path(temporary) / archive.name
        with staged.open('wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=epoch) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.PAX_FORMAT) as tar:
                directories = {stem}
                for name in payload:
                    directories.update(str(p) for p in Path(stem, name).parents if p != Path('.'))
                for name in sorted(directories):
                    entry = tarfile.TarInfo(name)
                    entry.type = tarfile.DIRTYPE
                    entry.mode = 0o755
                    entry.mtime = epoch
                    tar.addfile(entry)
                for name, content in sorted(payload.items()):
                    entry = tarfile.TarInfo(stem + '/' + name)
                    entry.size = len(content)
                    entry.mode = 0o755 if name in EXECUTABLES else 0o644
                    entry.mtime = epoch
                    tar.addfile(entry, io.BytesIO(content))
        value = hashlib.sha256(staged.read_bytes()).hexdigest()
        staged_checksum = Path(temporary) / checksum.name
        staged_checksum.write_text(f'{value}  {archive.name}\n')
        os.replace(staged, archive)
        os.replace(staged_checksum, checksum)
    print(archive)
    print(checksum)
    return archive


if __name__ == '__main__':
    try:
        build()
    except (OSError, ValueError) as error:
        raise SystemExit(f'Ошибка сборки релиза: {error}') from None
