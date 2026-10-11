#!/usr/bin/env python3
"""Save an optional JEV research key locally. Does not enable JEV in chat."""
import argparse
import getpass
import json
import os
from pathlib import Path
import tempfile


def save_key(filename, key):
    if not key or len(key) > 4096 or any(not 33 <= ord(c) <= 126 for c in key):
        raise ValueError('Enter a non-empty API key without spaces or control characters.')
    filename = Path(filename).expanduser()
    filename.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if filename.parent.is_symlink() or filename.is_symlink():
        raise ValueError('Key storage must not use symbolic links.')
    os.chmod(filename.parent, 0o700)
    fd, temporary = tempfile.mkstemp(prefix='.jev-', dir=filename.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump({'api_key': key, 'enabled': False}, output)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, filename)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--file', type=Path, default=Path.home()/'.config/black-team/jev.json')
    args = parser.parse_args()
    save_key(args.file, getpass.getpass('JEV / Typesafe API key (hidden): ').strip())
    print('Research key saved privately. JEV remains disabled in Black Team chat.')


if __name__ == '__main__':
    main()
