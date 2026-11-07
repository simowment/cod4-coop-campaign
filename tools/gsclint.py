"""Static lint for our GSC (catches the compile errors iw3sp would show at map load).

  python tools/gsclint.py [--raw C:/Users/got/cod4-decomp/raw] [--builtins C:/Users/got/cod4-decomp/builtins_all.txt] [files...]

Checks: balanced braces/parens/brackets, every called function resolves to (a) a function in the same
file, (b) a function in an #include'd file, (c) path::func in a mod or stock file, or (d) an engine
builtin; known-missing builtins in iw3sp 1.0 (islinked, angleclamp180 as builtin...); stray statements
at file scope; 'foreach'/'continue' misuse is out of scope.
Stock scripts are looked up in the extracted raw folder (the user's own files, never shipped).
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COMMON = None
ROOT = os.path.dirname(HERE)

KEYWORDS = {'if', 'else', 'for', 'while', 'switch', 'case', 'default', 'return', 'break', 'continue',
            'wait', 'waittill', 'waittillmatch', 'waittillframeend', 'notify', 'endon', 'thread',
            'isdefined', 'self', 'level', 'game', 'anim', 'undefined', 'true', 'false', 'size'}
# GSC statements/operators that look like calls
PSEUDO = {'wait', 'waittill', 'waittillmatch', 'notify', 'endon', 'isdefined', 'if', 'while', 'for',
          'switch', 'return', 'thread', 'prof_begin', 'prof_end', 'assert', 'assertex', 'assertmsg',
          'println', 'print', 'print3d', 'line', 'isdefined'}

def strip(src):
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j; continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2); seg = src[i:(n if j < 0 else j + 2)]
            out.append('\n' * seg.count('\n')); i = n if j < 0 else j + 2; continue
        if src.startswith('/#', i):  # dev block: compiled out in retail
            j = src.find('#/', i + 2); seg = src[i:(n if j < 0 else j + 2)]
            out.append('\n' * seg.count('\n')); i = n if j < 0 else j + 2; continue
        if c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == '\\' else 1
            out.append('""'); i = j + 1; continue
        out.append(c); i += 1
    return ''.join(out)

FUNC_DEF = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*$', re.M)

def defs_of(text):
    s = strip(text)
    names = set()
    depth = 0
    for line in s.split('\n'):
        if depth == 0:
            m = FUNC_DEF.match(line.strip())
            if m:
                names.add(m.group(1).lower())
        depth += line.count('{') - line.count('}')
    return names

class Resolver:
    def __init__(self, mod_dir, raw_dir):
        self.mod_dir, self.raw_dir = mod_dir, raw_dir
        self.cache = {}
    def path_of(self, inc):
        rel = inc.replace('\\', '/') + '.gsc'
        for base in (self.mod_dir, self.raw_dir):
            p = os.path.join(base, rel)
            if os.path.isfile(p):
                return p
        return None
    def defs(self, inc):
        key = inc.lower()
        if key not in self.cache:
            p = self.path_of(inc)
            self.cache[key] = defs_of(open(p, encoding='latin-1').read()) if p else None
        return self.cache[key]

def lint(path, res, builtins):
    errs = []
    text = open(path, encoding='latin-1').read()
    s = strip(text)
    lines = s.split('\n')
    # balance
    for o, c in ('{}', '()', '[]'):
        if s.count(o) != s.count(c):
            errs.append('%s: unbalanced %s%s (%d vs %d)' % (path, o, c, s.count(o), s.count(c)))
    includes = re.findall(r'^#include\s+([A-Za-z0-9_\\/]+)\s*;', s, re.M)
    local = defs_of(text)
    inc_defs = set()
    for inc in includes:
        d = res.defs(inc)
        if d is None:
            errs.append('%s: #include %s not found' % (path, inc))
        else:
            inc_defs |= d
    # a function name may not also come from an #include'd file ("function 'x' already defined")
    for inc in includes:
        d = res.defs(inc) or set()
        for name in sorted(local & d):
            errs.append('%s: function %s() is also defined in #include %s' % (path, name, inc))
    # file-scope junk
    depth = 0
    for ln, line in enumerate(lines, 1):
        st = line.strip()
        if depth == 0 and st and not st.startswith('#') and not FUNC_DEF.match(st) and st not in ('{', '}'):
            errs.append('%s:%d: statement at file scope: %s' % (path, ln, st[:60]))
        if depth > 0 and FUNC_DEF.match(st) and ln < len(lines) and lines[ln].strip() == '{' \
                and not re.match(r'^(if|while|for|switch)\b', st):
            errs.append('%s:%d: function definition inside a function body: %s' % (path, ln, st[:60]))
        if re.search(r'\bthread\s*$', st) or re.search(r'\bthread\s*;', st):
            errs.append('%s:%d: dangling thread keyword' % (path, ln))
        depth += line.count('{') - line.count('}')
    # calls
    for ln, line in enumerate(lines, 1):
        if line.strip().startswith('#'):
            continue
        for m in re.finditer(r'([A-Za-z_][A-Za-z0-9_\\/]*::)?([A-Za-z_][A-Za-z0-9_]*)\s*\(', line):
            qual, name = m.group(1), m.group(2)
            lname = name.lower()
            pre = line[:m.start()].rstrip()
            if qual:
                inc = qual[:-2]
                if inc and COMMON is not None and path.replace('\\', '/').find('/mod/') >= 0:
                    key = inc.replace('\\', '/').lower() + '.gsc'
                    if key not in COMMON and not os.path.isfile(os.path.join(res.mod_dir, key)):
                        errs.append('%s:%d: %s is a level-specific script (not in common.ff); referencing it '
                                    'breaks every other level' % (path, ln, inc))
                        continue
                d = res.defs(inc) if inc else local
                if d is None:
                    errs.append('%s:%d: unknown script file %s' % (path, ln, inc))
                elif lname not in d:
                    errs.append('%s:%d: %s has no function %s' % (path, ln, inc, name))
                continue
            if lname in PSEUDO or lname in KEYWORDS:
                continue
            # function definitions at depth 0 are handled above; skip the def line itself
            if FUNC_DEF.match(line.strip()) and line.strip().startswith(name):
                continue
            if pre.endswith('::'):
                continue
            if lname in local or lname in inc_defs or lname in builtins:
                continue
            errs.append('%s:%d: call to undefined function %s' % (path, ln, name))
        for m in re.finditer(r'::([A-Za-z_][A-Za-z0-9_]*)\b(?!\s*\()', line):
            # function pointer ::fn
            nm = m.group(1).lower()
            before = line[:m.start()]
            if re.search(r'[A-Za-z0-9_\\/]$', before):
                continue
            if nm not in local and nm not in inc_defs:
                errs.append('%s:%d: function pointer ::%s not found' % (path, ln, m.group(1)))
    return errs

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--raw', default=r'C:/Users/got/cod4-decomp/raw')
    ap.add_argument('--builtins', default=r'C:/Users/got/cod4-decomp/builtins_all.txt')
    ap.add_argument('--mod', default=os.path.join(ROOT, 'mod'))
    ap.add_argument('--game', default=os.path.join(os.path.dirname(ROOT), 'Call of Duty 4-Modern Warfare'))
    ap.add_argument('files', nargs='*')
    a = ap.parse_args()
    builtins = set()
    for line in open(a.builtins):
        parts = line.split()
        if len(parts) >= 2:
            builtins.add(parts[1].lower())
    global COMMON
    ff = os.path.join(a.game, 'zone', 'english', 'common.ff')
    if os.path.isfile(ff):
        sys.path.insert(0, HERE)
        import ffraw
        COMMON = set(k.lower() for k in ffraw.rawfiles(ff))
    res = Resolver(a.mod, a.raw)
    files = a.files
    if not files:
        for dp, _, fs in os.walk(a.mod):
            files += [os.path.join(dp, f) for f in fs if f.endswith('.gsc')]
    errs = []
    for f in sorted(files):
        errs += lint(f, res, builtins)
    for e in errs:
        print(e)
    print('%d file(s), %d problem(s)' % (len(files), len(errs)))
    sys.exit(1 if errs else 0)

if __name__ == '__main__':
    main()
