import fnmatch
import os
from pathlib import Path
import stat


def linked(info):
    return stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT


def entries(root, pattern='*', links=False):
    start = os.path.normpath(os.fspath(root))
    try:
        top = os.lstat(start)
    except FileNotFoundError:
        return
    if linked(top):
        raise NotADirectoryError(f'a walk does not start at a link: {root}')
    pending = [start]
    while pending:
        try:
            listing = os.scandir(pending.pop())
        except (FileNotFoundError, NotADirectoryError, PermissionError):
            continue
        with listing:
            for entry in listing:
                info = entry.stat(follow_symlinks=False)
                if linked(info) and not links:
                    continue
                if stat.S_ISDIR(info.st_mode) and not linked(info):
                    pending.append(entry.path)
                if fnmatch.fnmatch(entry.name, pattern):
                    yield Path(entry.path)
