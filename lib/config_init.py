"""Create a private config without following links or replacing existing files."""
import os
from pathlib import Path
import secrets
import stat
import sys


def create(template, destination):
    raw = Path(destination)
    if '..' in raw.parts or not raw.name:
        raise ValueError('Путь конфига не должен содержать ..')
    destination = Path(os.path.abspath(raw))
    content = Path(template).read_bytes()
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, name in enumerate(destination.parts[1:-1]):
            try:
                os.mkdir(name, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
            info = os.fstat(fd)
            if info.st_uid not in (0, os.getuid()):
                raise ValueError('Чужой владелец каталога конфигурации')
            writable = info.st_mode & 0o022
            shared_parent = info.st_uid == 0 and info.st_mode & stat.S_ISVTX and index < len(destination.parts[1:-1]) - 1
            if writable and not shared_parent:
                raise ValueError('Небезопасные права каталога конфигурации')
        if os.fstat(fd).st_uid != os.getuid():
            raise ValueError('Каталог конфига должен принадлежать пользователю')
        temporary = '.config-init-' + secrets.token_hex(16)
        tmp_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        try:
            with os.fdopen(tmp_fd, 'wb') as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            # link is atomic and refuses all existing entries, including symlinks.
            os.link(temporary, destination.name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
        finally:
            os.unlink(temporary, dir_fd=fd)
    finally:
        os.close(fd)


if __name__ == '__main__':
    try:
        create(sys.argv[1], sys.argv[2])
    except (OSError, ValueError) as error:
        print(f'Не удалось создать конфиг: {error}', file=sys.stderr)
        sys.exit(1)
