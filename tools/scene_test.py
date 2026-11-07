"""Automated two-instance scene test (host A + client B on the virtual monitor).

  python tools/scene_test.py plans.json [level ...]

Each plan: {level, start, steps:[{wait, target: host|client, cmd}], expect_replicated_flags}.
cmd: "flag <name>" | "tp x y z yaw" | "killnear" | "status" | "down" | "revive".
Writes results/<level>/{result.json, host_*.png, client_*.png}. A level fails when a script runtime
error shows up on only one side (coop-caused; errors on both sides are the stock script), when a game
stops advancing, or when an expected flag never reaches the client.
"""
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GAME = os.path.join(os.path.dirname(ROOT), 'Call of Duty 4-Modern Warfare')
RESULTS = os.path.join(ROOT, 'build', 'scene_results')
BG = os.path.join(HERE, 'bg.ps1')


def ps(*args):
    return subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', BG] + list(args),
                          capture_output=True, text=True).stdout.strip()


def kill_all():
    subprocess.run(['taskkill', '/F', '/IM', 'iw3sp.exe'], capture_output=True)
    time.sleep(1.5)


def read(path):
    try:
        return open(path, encoding='latin-1', errors='replace').read()
    except OSError:
        return ''


def native_log(tag):
    return read(os.path.join(GAME, 'coop_native_%s.log' % tag))


def console(mod):
    return read(os.path.join(GAME, 'Mods', mod, 'console.log'))


def hb_times(tag):
    return [int(x) for x in re.findall(r'gsc: hb t=(\d+)', native_log(tag))]


def errors(mod):
    out = {}
    for m in re.finditer(r'script runtime error \*+\r?\n(.+?): \(file \'([^\']+)\', line (\d+)\)', console(mod)):
        key = '%s:%s %s' % (m.group(2), m.group(3), m.group(1))
        out[key] = out.get(key, 0) + 1
    if 'script compile error' in console(mod):
        out['COMPILE ERROR'] = 1
    return out


def send(tag, cmd):
    if cmd.startswith('tp '):
        line = 'set coop_test_tp ' + cmd[3:]
    else:
        line = 'set coop_test_cmd ' + cmd
    with open(os.path.join(GAME, 'coop_cmd_%s.txt' % tag), 'w') as f:
        f.write(line)
    time.sleep(0.6)


def wait_until(pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(2)
    return False


def run(plan):
    lvl = plan['level']
    outdir = os.path.join(RESULTS, lvl)
    os.makedirs(outdir, exist_ok=True)
    kill_all()
    for f in os.listdir(GAME):
        if f.startswith('coop_native_') or f.startswith('coop_cmd_') or f.startswith('coop_shot_'):
            try:
                os.remove(os.path.join(GAME, f))
            except OSError:
                pass
    for mod in ('coop', 'coopb'):
        try:
            os.remove(os.path.join(GAME, 'Mods', mod, 'console.log'))
        except OSError:
            pass
    start = plan.get('start') or ''
    start_arg = '+set start %s ' % start if start else ''
    common = '+set coop_heartbeat 1 +set coop_debug 1'
    ps('launch', 'A', '+set fs_game mods/coop %s +set coop_host 1 +set coop_wait 2 +set coop_name Host %s+set coop_startmap %s' % (common, start_arg, lvl))
    time.sleep(3)
    ps('launch', 'B', '+set fs_game mods/coopb %s +set coop_connect 127.0.0.1 +set coop_name Buddy' % common)
    res = {'level': lvl, 'start': start, 'steps': [], 'problems': []}
    fatal = lambda: 'com_errorMessage' in console('coop') or 'com_errorMessage' in console('coopb')
    ok = wait_until(lambda: (max(hb_times('A') or [0]) >= 20250 and max(hb_times('B') or [0]) >= 20250) or fatal(), 260)
    if fatal():
        res['problems'].append('fatal script error (error screen)')
    if not ok:
        res['problems'].append('did not reach 20 s of gameplay on both (host %s, client %s)' % (max(hb_times('A') or [0]), max(hb_times('B') or [0])))
    ps('shot', 'A', os.path.join(outdir, 'host_0.png'), '0.5')
    ps('shot', 'B', os.path.join(outdir, 'client_0.png'), '0.5')
    for i, st in enumerate(plan.get('steps', [])):
        time.sleep(min(float(st.get('wait', 3)), 60))
        send('A' if st['target'] == 'host' else 'B', st['cmd'])
        res['steps'].append(st['cmd'])
    time.sleep(14)
    ps('shot', 'A', os.path.join(outdir, 'host_1.png'), '0.5')
    ps('shot', 'B', os.path.join(outdir, 'client_1.png'), '0.5')
    # still running?
    a0, b0 = max(hb_times('A') or [0]), max(hb_times('B') or [0])
    time.sleep(11)
    a1, b1 = max(hb_times('A') or [0]), max(hb_times('B') or [0])
    if a1 <= a0:
        res['problems'].append('host stopped advancing (t=%d)' % a1)
    if b1 <= b0:
        res['problems'].append('client stopped advancing (t=%d)' % b1)
    eh, ec = errors('coop'), errors('coopb')
    res['errors_host'], res['errors_client'] = eh, ec
    one_sided = sorted(set(eh) ^ set(ec))
    if one_sided:
        res['problems'].append('one-sided script errors: ' + '; '.join(one_sided))
    blog = native_log('B')
    for fl in plan.get('expect_replicated_flags', []):
        if not re.search(r'recv 0\|%s\|F\|%s\|1' % (re.escape(lvl), re.escape(fl)), blog):
            res['problems'].append('flag %s never reached the client' % fl)
    res['pulls'] = re.findall(r'gsc: (pulled to .*)', blog)[-3:]
    res['pass'] = not res['problems']
    json.dump(res, open(os.path.join(outdir, 'result.json'), 'w'), indent=1)
    print('%-18s %s %s' % (lvl, 'PASS' if res['pass'] else 'FAIL', '' if res['pass'] else res['problems']), flush=True)
    return res


def main():
    plans = json.load(open(sys.argv[1]))
    only = set(sys.argv[2:])
    allres = []
    for p in plans:
        if only and p['level'] not in only:
            continue
        allres.append(run(p))
    kill_all()
    json.dump(allres, open(os.path.join(RESULTS, 'summary.json'), 'w'), indent=1)


if __name__ == '__main__':
    main()
