#!/usr/bin/env python3
"""Point the xctestrun's coverage metadata at the local packages' real binaries.

Xcode builds a local package product that both the app and the test bundle
link as a dynamic `<Name>_<hash>_PackageProduct.framework`, and records it in
`__xctestrun_metadata__.CodeCoverageBuildableInfos` with `IsStatic = true`.
xccov then reads the framework as a static archive and reports the target with
no files; some package targets get no entry at all. Measured on Xcode 26.3:
`llvm-cov report` on PalaceAuth's framework with the run's profdata shows 1,167
lines, while the xcresult lists PalaceAuth with 0 files.

This rewrites one entry per source directory under Palace/Packages/*/Sources:
the PackageFrameworks binary when there is one, otherwise the app binary the
target is linked into statically. Every other entry is left as Xcode wrote it.

Usage: ci-xctestrun-package-coverage.py <file.xctestrun> [--repo-root DIR]
Exit: 0 rewritten, 1 nothing to rewrite or a package source has no binary,
2 unreadable input.

prior-art-checked: the coverage pipeline has no step that edits the xctestrun.
"""
import argparse
import glob
import os
import plistlib
import sys
from typing import Dict, List, Optional

META = '__xctestrun_metadata__'
INFOS = 'CodeCoverageBuildableInfos'
APP_NAME = 'Palace.app'


def package_targets(repo_root: str) -> Dict[str, str]:
    """{target name: absolute Sources/<target>/ directory} for every local package."""
    out = {}
    for src in sorted(glob.glob(os.path.join(repo_root, 'Palace', 'Packages', '*', 'Sources', '*'))):
        if os.path.isdir(src):
            out[os.path.basename(src)] = src.rstrip('/') + '/'
    return out


def swift_files(directory: str) -> List[str]:
    files = []
    for root, _, names in os.walk(directory):
        for n in names:
            if n.endswith('.swift'):
                files.append(os.path.relpath(os.path.join(root, n), directory))
    return sorted(files)


def framework_product_path(products_dir: str, target: str) -> Optional[str]:
    """`__TESTROOT__/...` path of the target's PackageProduct framework binary."""
    for fw in sorted(glob.glob(os.path.join(products_dir, '*', 'PackageFrameworks',
                                            f'{target}_*_PackageProduct.framework'))):
        binary = os.path.join(fw, os.path.basename(fw)[:-len('.framework')])
        if os.path.isfile(binary):
            return '__TESTROOT__/' + os.path.relpath(binary, products_dir)
    return None


def rewrite(plist: dict, products_dir: str, repo_root: str) -> List[str]:
    infos = plist.get(META, {}).get(INFOS)
    if not isinstance(infos, list):
        raise ValueError(f'no {META}.{INFOS} in the xctestrun')
    app = next((e for e in infos if e.get('Name') == APP_NAME), None)
    if app is None:
        raise ValueError(f'no {APP_NAME} entry in {INFOS}')
    targets = package_targets(repo_root)
    if not targets:
        raise ValueError(f'no package sources under {repo_root}/Palace/Packages')

    kept = [e for e in infos if e.get('Name') not in targets]
    log = []
    for name, src in targets.items():
        files = swift_files(src)
        if not files:
            continue
        path = framework_product_path(products_dir, name)
        where = 'framework'
        if path is None:
            path, where = app['ProductPath'], 'app binary'
        kept.append({
            'Architecture': app.get('Architecture', 'arm64'),
            'BuildableIdentifier': f'{name}:primary',
            'IncludeInReport': True,
            'IsStatic': False,
            'Name': name,
            'ProductPath': path,
            'SourceFiles': files,
            'SourceFilesCommonPathPrefix': src,
            'Toolchains': app.get('Toolchains', ['com.apple.dt.toolchain.XcodeDefault']),
        })
        log.append(f'{name}: {len(files)} files -> {where} {path}')
    plist[META][INFOS] = kept
    return log


def main(argv=None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument('xctestrun')
    p.add_argument('--repo-root', default=os.getcwd())
    args = p.parse_args(argv)
    try:
        with open(args.xctestrun, 'rb') as f:
            plist = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException) as e:
        print(f'cannot read {args.xctestrun}: {e}', file=sys.stderr)
        return 2
    try:
        log = rewrite(plist, os.path.dirname(os.path.abspath(args.xctestrun)),
                      os.path.abspath(args.repo_root))
    except ValueError as e:
        print(f'::error::{e}', file=sys.stderr)
        return 1
    with open(args.xctestrun, 'wb') as f:
        plistlib.dump(plist, f)
    print('\n'.join(log))
    return 0


if __name__ == '__main__':
    sys.exit(main())
