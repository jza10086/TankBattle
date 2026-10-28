#!/usr/bin/env python3
"""Launch genuine localhost Godot/ENet host and client processes, not hotseat.

Human input is scripted only by network_peer.gd; production game contains no AI.
Host fixture injection is explicitly marked and used only to stimulate replicated
combat fields. Full snapshot hashes are compared at identical epoch/tick pairs.
"""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run_case(binary: str, count: int, address: str, base: Path, port: int) -> bool:
    case = base / f"players-{count}-{'ipv6' if ':' in address else 'ipv4'}"
    case.mkdir(parents=True, exist_ok=True)
    (case / 'stage.txt').unlink(missing_ok=True)
    processes: list[tuple[str, subprocess.Popen, object, Path]] = []
    env = os.environ.copy()
    for kind in ('CACHE', 'DATA', 'CONFIG'):
        path = case / kind.lower()
        path.mkdir(exist_ok=True)
        env[f'XDG_{kind}_HOME'] = str(path)
    cpus = sorted(os.sched_getaffinity(0))

    def affinity():
        os.sched_setaffinity(0, cpus[:2])

    def launch(role: str, index: int):
        name = f'{role}-{index}'
        path = case / f'{name}.log'
        log = path.open('w')
        command = [binary, '--headless', '--audio-driver', 'Dummy', '--path', str(ROOT),
                   '--script', 'res://tests/network_peer.gd', '--', f'role={role}',
                   f'index={index}', f'expected={count}', f'port={port}',
                   f'address={address}', f'out={case}']
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   env=env, preexec_fn=affinity)
        processes.append((name, process, log, path))

    launch('host', 0)
    time.sleep(0.4)
    for index in range(1, count):
        launch('client', index)
        time.sleep(0.12)
    full_spawned = late_spawned = False
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        stage_path = case / 'stage.txt'
        stage = stage_path.read_text() if stage_path.exists() else ''
        if stage == 'full_lobby' and count == 8 and not full_spawned:
            launch('reject_full', 8)
            full_spawned = True
        if stage == 'playing' and not late_spawned:
            launch('reject_late', 9)
            late_spawned = True
        if all(p.poll() is not None for _, p, _, _ in processes):
            break
        time.sleep(0.05)
    success = True
    for name, process, log, path in processes:
        if process.poll() is None:
            process.kill()
            success = False
        process.wait(timeout=3)
        log.close()
        text = path.read_text(errors='replace')
        result = re.search(r'NETWORK_PEER_RESULT.*failures=(\d+)', text)
        good = process.returncode == 0 and result and result[1] == '0' and not re.search(r'SCRIPT ERROR|^ERROR:|FAIL:', text, re.M)
        if not good:
            success = False
            print(f'FAIL {name} exit={process.returncode}\n{text[-10000:]}')
        else:
            print(f'PASS {name}: {result[0]}')
    host_log = (case / 'host-0.log').read_text(errors='replace')
    host_hashes = {(int(a), int(b)): h for a, b, h in re.findall(r'^SNAP (\d+) (\d+) (\w+)$', host_log, re.M)}
    for name, _, _, path in processes:
        if not name.startswith('client-'):
            continue
        hashes = re.findall(r'^SNAP (\d+) (\d+) (\w+)$', path.read_text(errors='replace'), re.M)
        matched = mismatch = 0
        for a, b, value in hashes:
            key = (int(a), int(b))
            if key in host_hashes:
                if host_hashes[key] == value:
                    matched += 1
                else:
                    mismatch += 1
        if matched < 30 or mismatch:
            print(f'FAIL snapshot consistency {name}: matched={matched} mismatch={mismatch}')
            success = False
        else:
            print(f'PASS snapshot consistency {name}: {matched} identical authoritative snapshots')
    if not late_spawned or (count == 8 and not full_spawned):
        print('FAIL rejection probe was not launched')
        success = False
    print(f'NETWORK_CASE players={count} address={address} result={"PASS" if success else "FAIL"} logs={case}')
    return success


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--godot', default=os.environ.get('GODOT_BIN', 'godot'))
    parser.add_argument('--players', type=int, nargs='+', default=[2, 8])
    parser.add_argument('--address', default='127.0.0.1')
    parser.add_argument('--base-port', type=int, default=17777)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    base = args.output or Path(tempfile.mkdtemp(prefix='tankbattle-enet-'))
    results = [run_case(args.godot, count, args.address, base, args.base_port + i) for i, count in enumerate(args.players)]
    print(f'NETWORK_TESTS: {sum(results)}/{len(results)} cases passed; logs={base}')
    return 0 if all(results) else 1

if __name__ == '__main__':
    sys.exit(main())
