#!/usr/bin/env python3
"""把 .shot 里列出的命令真跑一遍，渲染成终端样式的 SVG。

.shot 格式（一行一条，`#` 开头的是给渲染器的指令，不显示）：

    # title: shellkit doctor
    # cwd: .
    # setup: rm -rf /tmp/shellkit-demo
    $ ./shellkit doctor

画面里的文本逐字来自真实输出。渲染器只做两件事：加窗口外壳、按行首前缀上色。
颜色只是让人一眼分清 [ERROR] 和 [ OK ]，不改动任何一个字符。

用法：
    python3 tools/term_shot.py docs/shots/*.shot
    python3 tools/term_shot.py --check docs/shots/*.shot     # 只比对，不写盘
"""

import os
import subprocess
import sys
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FONT_SIZE = 13
LINE_HEIGHT = 19
PAD = 18
BAR_H = 30
MAX_COLS = 96
TIMEOUT = 120

BG = '#11161d'
BAR = '#1b222c'
FG = '#e6edf3'
DIM = '#8b949e'
GREEN = '#3fb950'
RED = '#f85149'
YELLOW = '#d29922'
BLUE = '#58a6ff'

COLORS = (
    ('[ERROR]', RED),
    ('[FAIL]', RED),
    ('FAIL:', RED),
    ('[ OK ]', GREEN),
    ('PASS', GREEN),
    ('[WARN]', YELLOW),
    ('[INFO]', BLUE),
    ('[debug]', DIM),
)

FONT_STACK = 'SFMono-Regular, Menlo, Consolas, DejaVu Sans Mono, monospace'


def char_width():
    """等宽字体的单字符宽度。有 PIL 就量真字体，没有就按 Menlo 比例估。"""
    ratio = FONT_SIZE * 0.602
    for path in (
        '/System/Library/Fonts/SFNSMono.ttf',
        '/System/Library/Fonts/Menlo.ttc',
        '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
    ):
        if not os.path.exists(path):
            continue
        try:
            from PIL import ImageFont
        except Exception:
            return ratio
        try:
            return float(ImageFont.truetype(path, FONT_SIZE).getlength('M'))
        except Exception:
            continue
    return ratio


def parse(path):
    title = os.path.basename(path)[:-5]
    cwd = ROOT
    setup = []
    cmds = []
    with open(path, 'r', encoding='utf-8') as fh:
        for raw in fh:
            line = raw.rstrip('\n')
            if not line.strip():
                continue
            if line.startswith('# title:'):
                title = line[8:].strip()
            elif line.startswith('# cwd:'):
                cwd = os.path.join(ROOT, line[6:].strip())
            elif line.startswith('# setup:'):
                setup.append(line[8:].strip())
            elif line.startswith('$ '):
                cmds.append(line[2:])
            elif line.startswith('#'):
                continue
            else:
                sys.exit('%s: unrecognised line: %s' % (path, line))
    return title, cwd, setup, cmds


def run(cmd, cwd):
    env = dict(os.environ)
    env['SHELLKIT_COLOR'] = 'never'
    env['NO_COLOR'] = '1'
    env['TERM'] = 'dumb'
    env.pop('SHELLKIT_DEBUG', None)
    try:
        p = subprocess.run(
            cmd, shell=True, cwd=cwd, env=env, timeout=TIMEOUT,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
    except subprocess.TimeoutExpired:
        return 124, ''
    return p.returncode, p.stdout.decode('utf-8', 'replace').rstrip('\n')


def capture(cwd, setup, cmds):
    for s in setup:
        run(s, cwd)
    lines = []
    for c in cmds:
        lines.append('$ ' + c)
        rc, out = run(c, cwd)
        if out:
            lines.extend(out.split('\n'))
        if rc != 0:
            lines.append('[exit %d]' % rc)
    return lines


def wrap(line):
    out = []
    while len(line) > MAX_COLS:
        out.append(line[:MAX_COLS])
        line = '  ' + line[MAX_COLS:]
    out.append(line)
    return out


def color_for(line):
    if line.startswith('$ '):
        return FG
    if line.startswith('[exit '):
        return DIM
    for prefix, col in COLORS:
        if line.startswith(prefix):
            return col
    return FG


def render(title, lines):
    cols = max([len(x) for x in lines] + [len(title) + 8, 48])
    cw = char_width()
    width = int(round(cols * cw)) + PAD * 2
    height = BAR_H + PAD * 2 + len(lines) * LINE_HEIGHT
    parts = []
    parts.append(
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        'viewBox="0 0 %d %d" role="img" aria-label="%s">'
        % (width, height, width, height, escape(title))
    )
    parts.append('<rect x="0" y="0" width="%d" height="%d" rx="10" fill="%s"/>' % (width, height, BG))
    parts.append('<path d="M0 40 A0 0 0 0 0 0 0 Z" fill="none"/>')
    parts.append('<rect x="0" y="0" width="%d" height="%d" rx="10" fill="%s"/>' % (width, BAR_H, BAR))
    parts.append('<rect x="0" y="%d" width="%d" height="%d" fill="%s"/>' % (BAR_H - 10, width, 10, BAR))
    for i, col in enumerate(('#ff5f56', '#ffbd2e', '#27c93f')):
        parts.append('<circle cx="%d" cy="%d" r="5" fill="%s"/>' % (18 + i * 20, BAR_H // 2, col))
    parts.append(
        '<text x="%d" y="%d" font-family="%s" font-size="11" fill="%s">%s</text>'
        % (84, BAR_H // 2 + 4, FONT_STACK, DIM, escape(title))
    )
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        y = BAR_H + PAD + FONT_SIZE + i * LINE_HEIGHT
        parts.append(
            '<text x="%d" y="%d" font-family="%s" font-size="%d" fill="%s" xml:space="preserve">%s</text>'
            % (PAD, y, FONT_STACK, FONT_SIZE, color_for(line), escape(line))
        )
    parts.append(
        '<rect x="0.5" y="0.5" width="%d" height="%d" rx="10" fill="none" stroke="#30363d"/>'
        % (width - 1, height - 1)
    )
    parts.append('</svg>')
    return '\n'.join(parts) + '\n'


def main(argv):
    check = '--check' in argv
    files = [a for a in argv if not a.startswith('-')]
    if not files:
        sys.exit('usage: term_shot.py [--check] FILE.shot...')
    rc = 0
    for path in files:
        title, cwd, setup, cmds = parse(path)
        if not cmds:
            sys.exit('%s: no command lines' % path)
        lines = []
        for raw in capture(cwd, setup, cmds):
            lines.extend(wrap(raw))
        svg = render(title, lines)
        out = os.path.splitext(path)[0] + '.svg'
        if check:
            old = ''
            if os.path.exists(out):
                with open(out, 'r', encoding='utf-8') as fh:
                    old = fh.read()
            if old != svg:
                sys.stderr.write('%s: out of date\n' % out)
                rc = 1
        elif os.path.exists(out):
            with open(out, 'r', encoding='utf-8') as fh:
                old = fh.read()
            if old != svg:
                with open(out, 'w', encoding='utf-8') as fh:
                    fh.write(svg)
                sys.stderr.write('%s: updated\n' % out)
        else:
            with open(out, 'w', encoding='utf-8') as fh:
                fh.write(svg)
            sys.stderr.write('%s: created\n' % out)
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
