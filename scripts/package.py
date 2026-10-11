#!/usr/bin/env python3
"""Build an offline Linux preview from a reviewed upstream Electron ZIP."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tarfile
import tempfile
import zipfile


def digest(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def copy_tree(source, target):
    if source.is_symlink():
        raise ValueError(f'Symlinks are not allowed in app payload: {source.name}')
    if source.is_dir():
        target.mkdir(parents=True, exist_ok=True)
        for child in sorted(source.iterdir()):
            copy_tree(child, target / child.name)
    elif source.is_file():
        if source.suffix == '.map':
            raise ValueError('Source maps must not be included in this customer preview.')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        target.chmod(0o644)
    else:
        raise ValueError(f'Unsupported app payload entry: {source.name}')


def extract_runtime(source, target):
    with zipfile.ZipFile(source) as archive:
        for entry in archive.infolist():
            member = PurePosixPath(entry.filename)
            mode = entry.external_attr >> 16
            if (member.is_absolute() or '..' in member.parts or '\\' in entry.filename
                    or stat.S_ISLNK(mode)):
                raise ValueError('Runtime ZIP contains an unsafe archive entry.')
            if entry.filename == 'resources/default_app.asar':
                continue
            destination = target.joinpath(*member.parts)
            if entry.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as incoming, destination.open('wb') as output:
                shutil.copyfileobj(incoming, output)
            destination.chmod(0o755 if mode & 0o111 else 0o644)
    for name in ('electron', 'LICENSE', 'LICENSES.chromium.html', 'version'):
        if not (target / name).is_file():
            raise ValueError(f'Runtime ZIP is missing {name}.')
    version = (target / 'version').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:[-.a-zA-Z0-9]+)?', version):
        raise ValueError('Invalid Electron runtime version.')
    (target / 'electron').chmod(0o755)
    return version


def archive_tree(source, destination, root_name=None):
    epoch = int(os.environ.get('SOURCE_DATE_EPOCH', '0'))
    with destination.open('wb') as raw, gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=epoch) as compressed:
        with tarfile.open(fileobj=compressed, mode='w') as archive:
            for item in sorted(source.rglob('*')):
                if not item.is_file() or item.is_symlink():
                    continue
                name = item.relative_to(source).as_posix()
                if root_name:
                    name = f'{root_name}/{name}'
                info = archive.gettarinfo(str(item), arcname=name)
                info.uid = info.gid = 0
                info.uname = info.gname = ''
                info.mtime = epoch
                with item.open('rb') as contents:
                    archive.addfile(info, contents)


def build(project, runtime_zip, out):
    package = json.loads((project / 'package.json').read_text())
    version = package['version']
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', version):
        raise ValueError('Unsafe application version.')
    if not (project / 'dist/index.html').is_file():
        raise ValueError('Run npm run build before packaging.')
    out.mkdir(parents=True, exist_ok=True)
    stem = f'black-team-{version}-linux-x64'
    with tempfile.TemporaryDirectory(prefix='black-team-package-') as temporary:
        work = Path(temporary)
        payload = work / 'payload'
        payload.mkdir()
        runtime_version = extract_runtime(runtime_zip, payload)
        app = payload / 'resources/app'
        app.mkdir(parents=True, exist_ok=True)
        # Explicit allowlist: never package a home profile, node_modules, caches,
        # source checkout, model weights, or a prior distribution directory.
        for name in ('main.cjs', 'preload.cjs', 'dist'):
            copy_tree(project / name, app / name)
        for name in ('scripts/agent-runner.py', 'plugins/companion-tools/__init__.py', 'plugins/companion-tools/plugin.yaml'):
            copy_tree(project / name, app / name)
        modules = sorted((project / 'lib').glob('*.cjs'))
        if not modules:
            raise ValueError('Application lib/*.cjs modules are missing.')
        for module in modules:
            copy_tree(module, app / 'lib' / module.name)
        app_package = {key: package[key] for key in ('name', 'version', 'description', 'productName') if key in package}
        app_package['main'] = 'main.cjs'
        (app / 'package.json').write_text(json.dumps(app_package, indent=2) + '\n')
        copy_tree(project / 'THIRD-PARTY-NOTICES.md', app / 'THIRD-PARTY-NOTICES.md')
        copy_tree(project / 'LICENSE', app / 'LICENSE')
        for dependency in ('react', 'react-dom', 'scheduler', 'qrcode', 'dijkstrajs'):
            # Packages name this file differently (LICENSE, license, LICENSE.md).
            folder = project / 'node_modules' / dependency
            license_path = next((folder / name for name in ('LICENSE', 'LICENSE.md', 'license', 'license.md') if (folder / name).is_file()), folder / 'LICENSE')
            if not license_path.is_file():
                raise ValueError(f'Missing bundled dependency license: {dependency}')
            # License files are copied explicitly; node_modules itself is never followed.
            destination = app / 'third-party' / f'{dependency}-LICENSE.txt'
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(license_path, destination)
        (payload / 'RELEASE_VERSION').write_text(version + '\n')
        (payload / 'BUILD.json').write_text(json.dumps({
            'product': 'Black Team', 'version': version, 'platform': 'linux',
            'architecture': 'x64', 'channel': 'alpha', 'electron': runtime_version,
            'runtimeZipSha256': digest(runtime_zip),
        }, indent=2) + '\n')
        manifest = {p.relative_to(payload).as_posix(): digest(p)
                    for p in sorted(payload.rglob('*')) if p.is_file()}
        (payload / 'MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
        distribution = work / 'distribution'
        distribution.mkdir()
        archive_tree(payload, distribution / 'payload.tar.gz')
        (distribution / 'SHA256SUMS').write_text(digest(distribution / 'payload.tar.gz') + '  payload.tar.gz\n')
        (distribution / 'VERSION').write_text(version + '\n')
        copy_tree(project / 'scripts/install.sh', distribution / 'install.sh')
        (distribution / 'install.sh').chmod(0o755)
        copy_tree(project / 'docs/DISTRIBUTION.md', distribution / 'DISTRIBUTION.md')
        for name in ('README.md', 'LICENSE', 'docs/DISTRIBUTION.md', 'docs/PHONE.md', 'docs/PRIVACY.md',
                     'docs/VERIFICATION.md', 'docs/CONTEXT-RESEARCH.md', 'docs/HARNESSES.md', 'docs/MODELS.md', 'docs/JEV.md',
                     'docs/CODE.md', 'docs/MEMORY.md'):
            if (project / name).is_file():
                copy_tree(project / name, distribution / name)
        artifact = out / f'{stem}.tar.gz'
        archive_tree(distribution, artifact, stem)
        (out / f'{stem}.tar.gz.sha256').write_text(digest(artifact) + f'  {artifact.name}\n')
        print(json.dumps({'artifact': str(artifact), 'sha256': digest(artifact),
                          'bytes': artifact.stat().st_size, 'electron': runtime_version,
                          'payloadFiles': len(manifest)}, indent=2))
        return artifact


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-zip', type=Path, required=True)
    parser.add_argument('--out', type=Path, default=Path('release'))
    args = parser.parse_args()
    build(Path(__file__).resolve().parents[1], args.runtime_zip.resolve(), args.out.resolve())
