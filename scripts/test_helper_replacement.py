#!/usr/bin/env python3
"""Exercise signed helper replacement while a previous MCP process is alive.

Uses temporary copies of real helpers; never replaces an app or user data.
"""
import argparse
import json
import os
import pathlib
import selectors
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--helpers', type=pathlib.Path, required=True)
args = parser.parse_args()
# Helpers make and open libraries in the system temp folder only for tests that say so.
os.environ['FACIENDA_TEST_LIBRARY'] = '1'
root = pathlib.Path(tempfile.mkdtemp(prefix='facienda-replacement-'))


def install_helpers():
    for name in ('facienda-mcp', 'facienda-hook'):
        subprocess.run(['/usr/bin/install', '-m', '755', str(args.helpers / name), str(root / name)], check=True)


install_helpers()
subprocess.run([str(root / 'facienda-mcp'), '--database', str(root / 'prior.sqlite'), '--init'], capture_output=True, text=True, timeout=10, check=True)
process = subprocess.Popen([str(root / 'facienda-mcp'), '--database', str(root / 'prior.sqlite')],
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def request(identifier, method, params):
    process.stdin.write(json.dumps(dict(jsonrpc='2.0', id=identifier, method=method, params=params)) + '\n')
    process.stdin.flush()
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        assert selector.select(10), f'Timeout: {method}'
        reply = json.loads(process.stdout.readline())
    assert reply['id'] == identifier and 'result' in reply, reply
    return reply['result']


try:
    request(1, 'initialize', dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='ReplacementTest', version='1')))
    process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    process.stdin.flush()
    before = {name: (root / name).stat().st_ino for name in ('facienda-mcp', 'facienda-hook')}
    install_helpers()
    for name, inode in before.items():
        assert (root / name).stat().st_ino != inode, f'{name} was overwritten in place'
    subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('integration_smoke.py')),
                    '--helpers', str(root), '--workspace'], check=True)
    assert len(request(2, 'tools/list', {})['tools']) == 21
    print('PASS: fresh helper inodes; replacement handshake and all tools pass; prior MCP process still responds.')
finally:
    process.stdin.close()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=3)
