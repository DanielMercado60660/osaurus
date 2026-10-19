#!/usr/bin/env python3
"""Negative startup checks. Both paths exit before tsnet or network startup."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
helper = root / 'build/osaurus-ts'
with tempfile.TemporaryDirectory(dir=root / 'build/t04b') as state:
    env = {
        'PATH': '/usr/bin:/bin',
        'OSAURUS_PHONE_UPSTREAM': 'http://127.0.0.1:9',
        'OSAURUS_PHONE_STATE': state,
    }
    fd = os.open(state, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = subprocess.run([helper], input='s' * 64 + '\n', text=True,
                                capture_output=True, env=env, timeout=10)
        assert result.returncode != 0
        assert json.loads(result.stdout) == {
            'type': 'error', 'value': 'another Osaurus instance is using phone access'
        }, result.stdout
        assert not (Path(state) / 'node-name').exists()
        print('PASS: lock conflict emits error status and exits before tsnet')
    finally:
        os.close(fd)
    env['OSAURUS_PHONE_SECRET'] = 's' * 64
    result = subprocess.run([helper], input='', text=True, capture_output=True,
                            env=env, timeout=10)
    assert result.returncode != 0
    assert json.loads(result.stdout) == {'type': 'error', 'value': 'invalid launch secret line'}
    assert not (Path(state) / 'node-name').exists()
    print('PASS: legacy environment secret cannot replace stdin handshake')
