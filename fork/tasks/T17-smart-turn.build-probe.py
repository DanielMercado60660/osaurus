#!/usr/bin/env python3
"""Build a standalone production-source probe using existing Xcode dependency
artifacts (read-only), or just Accelerate features. No fetch/build/install of deps.
Usage: python3 ...build-probe.py --derived-data PATH [--configuration Release]
       python3 ...build-probe.py --features-only
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--derived-data', type=Path)
p.add_argument('--configuration', default='Release')
p.add_argument('--features-only', action='store_true')
a = p.parse_args()
out = root / 'build/T17'
out.mkdir(parents=True, exist_ok=True)
source = root / 'Packages/OsaurusCore/Services/Voice/SmartTurn'
cmd = ['swiftc', '-O', '-swift-version', '6', '-module-cache-path', str(root / 'build/ModuleCache'),
       '-o', str(out / ('features-probe' if a.features_only else 'smart-turn-probe')),
       str(source / 'SmartTurnFeatures.swift'), str(root / 'fork/tasks/T17-smart-turn.probe.swift')]
if a.features_only:
    cmd += ['-D', 'SMART_TURN_FEATURES_ONLY']
else:
    if a.derived_data is None:
        p.error('--derived-data is required for the MLX probe')
    products = a.derived_data / 'Build/Products' / a.configuration
    checkouts = a.derived_data / 'SourcePackages/checkouts'
    mlx = next((checkouts / name for name in ['vmlx-swift', 'mlx-swift'] if (checkouts / name).is_dir()), None)
    if mlx is None:
        p.error('No MLX checkout in the supplied DerivedData')
    cmd += [str(source / 'SmartTurnModel.swift'), '-I', str(products),
            '-I', str(mlx / 'Source/Cmlx/include'),
            '-I', str(checkouts / 'swift-numerics/Sources/_NumericsShims/include')]
    for name in ['MLX', 'MLXNN', 'MLXRandom', 'Cmlx', 'Numerics', 'RealModule', 'ComplexModule', '_NumericsShims']:
        cmd.append(str(products / (name + '.o')))
    if (products / 'CmlxGraphShim.o').exists():
        cmd.append(str(products / 'CmlxGraphShim.o'))
    cmd += ['-lc++', '-framework', 'Metal', '-framework', 'Foundation', '-framework', 'Accelerate']
    bundle = products / 'mlx-swift_Cmlx.bundle'
    if bundle.exists():
        shutil.copytree(bundle, out / bundle.name, dirs_exist_ok=True)
        metallib = bundle / 'Contents/Resources/default.metallib'
        if metallib.exists():
            shutil.copy(metallib, out / 'default.metallib')
print(' '.join(cmd), flush=True)
env = os.environ.copy()
env.update(GIT_TERMINAL_PROMPT='0', GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='credential.helper', GIT_CONFIG_VALUE_0='')
subprocess.run(cmd, cwd=root, env=env, check=True)
