import fnmatch
import os
from pathlib import Path
import stat


def entries(root, pattern='*'):
    pending = [os.fspath(root)]
    while pending:
        try:
            listing = os.scandir(pending.pop())
        except (FileNotFoundError, NotADirectoryError, PermissionError):
            continue
        with listing:
            for entry in listing:
                info = entry.stat(follow_symlinks=False)
                linked = getattr(info, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
                if stat.S_ISDIR(info.st_mode) and not linked:
                    pending.append(entry.path)
                if fnmatch.fnmatch(entry.name, pattern):
                    yield Path(entry.path)
