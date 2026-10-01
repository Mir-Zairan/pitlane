#!/usr/bin/env python3
"""Generate Pitlane's logo: an animated mark and an animated banner, as SMIL SVG.

The SVG is the single source. `render.sh` plays it in headless Chrome frame by frame to make the GIF
and the static PNGs, so every format shows exactly the same artwork.

Concept: one main line (your repository) forks into three pit lanes (worktrees). Three cars (Claude
sessions) peel off one after another, each into its own bay; the bay light goes red -> amber -> green
as the worktree gets ready; the car leaves across a checkered finish. The dot of the "i" in the
wordmark is a pit-lane light on the same clock.
"""
import math
import pathlib

OUT = pathlib.Path(__file__).resolve().parent
T = 5.2  # seconds per loop

# -- palette -----------------------------------------------------------------------------------
ASPHALT = '#0B0F14'
TILE = '#11161D'
TRACK = '#1C232D'
EDGE = '#2A3340'
INK = '#F3F6FA'
MUTED = '#8792A2'
CARS = ['#FFC53D', '#3DDCF0', '#FF5C93']          # amber, cyan, pink
OFF, RED, AMBER, GREEN = '#2A1A1F', '#FF4D5E', '#FFB224', '#2EE07F'

LANES = [64, 120, 176]                              # y of the three pit lanes
TRUNK_Y, FORK_X, BAY_X, BAY_W = 120, 56, 136, 64
FINISH_X = 214


def lane_path(y):
    if y == TRUNK_Y:
        return f'M-48,{TRUNK_Y} H320'
    return f'M-48,{TRUNK_Y} H{FORK_X} C{FORK_X + 32},{TRUNK_Y} {FORK_X + 32},{y} {FORK_X + 64},{y} H320'


def path_points(y, n=4000):
    """Sampled points along a lane path, for its length and the fraction at the bay centre."""
    pts = []
    for i in range(n + 1):
        s = i / n
        pts.append(s)
    # piecewise: segment A straight, B cubic, C straight
    def cubic(p0, p1, p2, p3, t):
        a = (1 - t) ** 3
        b = 3 * (1 - t) ** 2 * t
        c = 3 * (1 - t) * t ** 2
        d = t ** 3
        return (a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0],
                a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1])
    out = [(-48, TRUNK_Y), (FORK_X, TRUNK_Y)]
    if y != TRUNK_Y:
        p0, p1, p2, p3 = (FORK_X, TRUNK_Y), (FORK_X + 32, TRUNK_Y), (FORK_X + 32, y), (FORK_X + 64, y)
        out += [cubic(p0, p1, p2, p3, i / 400) for i in range(1, 401)]
    out.append((320, y))
    return out


def fraction_at_x(y, x):
    pts = path_points(y)
    seg = [math.dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1)]
    total = sum(seg)
    acc = 0.0
    for i, d in enumerate(seg):
        (x0, _), (x1, _) = pts[i], pts[i + 1]
        if x0 <= x <= x1 and x1 != x0:
            return (acc + d * (x - x0) / (x1 - x0)) / total
        acc += d
    return 1.0


def fmt(v):
    return f'{v:.4f}'.rstrip('0').rstrip('.')


def car_timeline(k):
    """keyTimes for car k: wait, drive into its bay, park, leave, wait off-stage."""
    o = 0.11 * k
    arrive, leave, gone = o + 0.20, o + 0.62, min(o + 0.78, 0.995)
    return o, arrive, leave, gone


def defs():
    return f'''
  <defs>
    <filter id="glow" x="-60%" y="-60%" width="220%" height="220%">
      <feGaussianBlur stdDeviation="3.2" result="b"/>
      <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <filter id="softglow" x="-40%" y="-40%" width="180%" height="180%">
      <feGaussianBlur stdDeviation="7"/>
    </filter>
    <pattern id="checker" width="10" height="10" patternUnits="userSpaceOnUse">
      <rect width="10" height="10" fill="#E9EDF2"/>
      <rect width="5" height="5" fill="#0B0F14"/><rect x="5" y="5" width="5" height="5" fill="#0B0F14"/>
    </pattern>
    <linearGradient id="tilegrad" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#151B23"/><stop offset="1" stop-color="#0D1117"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0"/>
      <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.10"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <clipPath id="tileclip"><rect width="240" height="240" rx="44"/></clipPath>
    <linearGradient id="sweep" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="160" y2="0">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0"/>
      <stop offset="0.5" stop-color="#FFE7A3" stop-opacity="0.95"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
      <animateTransform attributeName="gradientTransform" type="translate" dur="{T}s" repeatCount="indefinite"
        keyTimes="0;0.60;0.77;1" values="150 0;150 0;860 0;860 0"/>
    </linearGradient>
  </defs>'''


def mark(x=0, y=0):
    """The 240x240 animated mark."""
    g = [f'<g transform="translate({x},{y})">',
         '<rect width="240" height="240" rx="44" fill="url(#tilegrad)"/>',
         '<g clip-path="url(#tileclip)">']
    # faint track texture
    for i in range(-240, 480, 24):
        g.append(f'<line x1="{i}" y1="0" x2="{i + 240}" y2="240" stroke="#FFFFFF" stroke-opacity="0.018" stroke-width="10"/>')
    # lanes: a wide asphalt band with edge lines
    for y_ in LANES:
        d = lane_path(y_)
        g.append(f'<path d="{d}" fill="none" stroke="{EDGE}" stroke-width="30" stroke-linecap="round"/>')
        g.append(f'<path d="{d}" fill="none" stroke="{TRACK}" stroke-width="26" stroke-linecap="round"/>')
    # animated centre dashes on the trunk — the sense of speed
    g.append(f'<path d="M-48,{TRUNK_Y} H{FORK_X}" stroke="#3B4655" stroke-width="2.4" stroke-dasharray="9 9" stroke-linecap="round">'
             f'<animate attributeName="stroke-dashoffset" from="36" to="0" dur="0.45s" repeatCount="indefinite"/></path>')
    # bays, lights
    for k, y_ in enumerate(LANES):
        o, arrive, leave, gone = car_timeline(k)
        c = CARS[k]
        bay = (f'<rect x="{BAY_X}" y="{y_ - 17}" width="{BAY_W}" height="34" rx="10" fill="#0E131A" '
               f'stroke="{EDGE}" stroke-width="2">'
               f'<animate attributeName="stroke" dur="{T}s" repeatCount="indefinite" calcMode="discrete" '
               f'keyTimes="0;{fmt(arrive)};{fmt(leave)};1" values="{EDGE};{c};{EDGE};{EDGE}"/></rect>')
        g.append(bay)
        # bay box marks (parking brackets)
        for bx in (BAY_X + 8, BAY_X + BAY_W - 8):
            g.append(f'<line x1="{bx}" y1="{y_ - 9}" x2="{bx}" y2="{y_ + 9}" stroke="{EDGE}" stroke-width="2" stroke-linecap="round"/>')
        lx, ly = BAY_X + BAY_W - 6, y_ - 25
        light_keys = f'0;{fmt(arrive)};{fmt(arrive + 0.07)};{fmt(arrive + 0.15)};{fmt(leave + 0.04)};1'
        light_vals = f'{OFF};{RED};{AMBER};{GREEN};{OFF};{OFF}'
        g.append(f'<circle cx="{lx}" cy="{ly}" r="9" fill="{GREEN}" opacity="0" filter="url(#softglow)">'
                 f'<animate attributeName="opacity" dur="{T}s" repeatCount="indefinite" calcMode="discrete" '
                 f'keyTimes="{light_keys}" values="0;0.55;0.55;0.75;0;0"/>'
                 f'<animate attributeName="fill" dur="{T}s" repeatCount="indefinite" calcMode="discrete" '
                 f'keyTimes="{light_keys}" values="{light_vals}"/></circle>')
        g.append(f'<circle cx="{lx}" cy="{ly}" r="4.6" fill="{OFF}" stroke="#05080B" stroke-width="1.5">'
                 f'<animate attributeName="fill" dur="{T}s" repeatCount="indefinite" calcMode="discrete" '
                 f'keyTimes="{light_keys}" values="{light_vals}"/></circle>')
        # a tiny "ready" tick that pops when the light is green
        g.append(f'<path d="M{BAY_X + 14},{y_ + 23} l4,4 l8,-8" fill="none" stroke="{GREEN}" stroke-width="2.6" '
                 f'stroke-linecap="round" stroke-linejoin="round" opacity="0">'
                 f'<animate attributeName="opacity" dur="{T}s" repeatCount="indefinite" calcMode="discrete" '
                 f'keyTimes="0;{fmt(arrive + 0.15)};{fmt(leave)};1" values="0;1;0;0"/></path>')
    # finish line
    g.append(f'<rect x="{FINISH_X}" y="36" width="10" height="168" fill="url(#checker)" opacity="0.9"/>')
    # cars
    for k, y_ in enumerate(LANES):
        o, arrive, leave, gone = car_timeline(k)
        c = CARS[k]
        pb = fraction_at_x(y_, BAY_X + BAY_W / 2)
        kt = f'0;{fmt(o)};{fmt(arrive)};{fmt(leave)};{fmt(gone)};1'
        kp = f'0;0;{fmt(pb)};{fmt(pb)};1;1'
        ks = '0 0 1 1;0.15 0.6 0.25 1;0 0 1 1;0.6 0 0.9 0.4;0 0 1 1'
        motion = (f'<animateMotion dur="{T}s" repeatCount="indefinite" rotate="auto" calcMode="spline" '
                  f'keyTimes="{kt}" keyPoints="{kp}" keySplines="{ks}" path="{lane_path(y_)}"/>')
        trail_vals = '0;0.9;0;0;0.9;0'
        car = f'''<g>
      <g opacity="0">
        <animate attributeName="opacity" dur="{T}s" repeatCount="indefinite" calcMode="discrete" keyTimes="0;{fmt(o)};{fmt(gone)};1" values="0;1;0;0"/>
        <line x1="-34" y1="0" x2="-14" y2="0" stroke="{c}" stroke-width="3" stroke-linecap="round" opacity="0">
          <animate attributeName="opacity" dur="{T}s" repeatCount="indefinite" keyTimes="{kt}" values="{trail_vals}"/>
        </line>
        <rect x="-14" y="-8" width="28" height="16" rx="7" fill="{c}" filter="url(#glow)"/>
        <rect x="1" y="-5.5" width="7" height="11" rx="2.5" fill="#0B0F14" opacity="0.75"/>
        <rect x="-12" y="-9.5" width="7" height="3" rx="1.5" fill="#0B0F14" opacity="0.55"/>
        <rect x="-12" y="6.5" width="7" height="3" rx="1.5" fill="#0B0F14" opacity="0.55"/>
      </g>
      {motion}
    </g>'''
        g.append(car)
    g.append('</g>')
    # a soft sheen across the tile
    g.append('<rect width="240" height="240" rx="44" fill="none" stroke="#FFFFFF" stroke-opacity="0.06" stroke-width="1.5"/>')
    g.append('</g>')
    return '\n    '.join(g)


# -- wordmark: hand-built monoline lowercase, no font needed ------------------------------------
def wordmark(x, y):
    w = 13
    glyphs = [
        # p
        (0, 'M0,-58 V32', ('circle', 29, -29, 29)),
        # i (stem; the dot is the light)
        (88, 'M0,-58 V0', None),
        # t
        (118, 'M0,-86 V-14 Q0,0 15,0 H25 M-12,-58 H24', None),
        # l
        (172, 'M0,-94 V-14 Q0,0 13,0', None),
        # a
        (214, 'M58,-58 V0', ('circle', 29, -29, 29)),
        # n
        (304, 'M0,-58 V0 M0,-29 a29,29 0 0,1 58,0 V0', None),
        # e
        (392, 'M2,-29 H58 A29,29 0 1,0 49.5,-8.5', None),
    ]
    def letters(paint):
        g = [f'<g transform="translate({x},{y}) skewX(-11)" fill="none" stroke="{paint}" stroke-width="{w}" '
             f'stroke-linecap="round" stroke-linejoin="round">']
        for gx, d, extra in glyphs:
            g.append(f'<path transform="translate({gx},0)" d="{d}"/>')
            if extra:
                _, cx, cy, r = extra
                g.append(f'<circle transform="translate({gx},0)" cx="{cx}" cy="{cy}" r="{r}"/>')
        g.append('</g>')
        return g
    out = letters(INK)
    # The sheen: ONE band in banner coordinates, shown only where the letters are (a mask), so it
    # glides across the whole word instead of restarting inside every letter.
    out.append('<mask id="wordmask" maskUnits="userSpaceOnUse" x="0" y="0" width="900" height="260">')
    out += letters('#FFFFFF')
    out.append('</mask>')
    out.append(f'<rect x="{x - 40}" y="{y - 110}" width="520" height="150" fill="url(#sweep)" mask="url(#wordmask)"/>')
    # the i-dot: a pit light, on the master clock
    dot_keys = '0;0.18;0.30;0.40;0.90;1'
    dot_vals = f'{RED};{RED};{AMBER};{GREEN};{GREEN};{RED}'
    ix = x + 85 + math.tan(math.radians(11)) * 86
    iy = y - 86
    out.append(f'<circle cx="{fmt(ix)}" cy="{iy}" r="16" fill="{GREEN}" opacity="0.5" filter="url(#softglow)">'
               f'<animate attributeName="fill" dur="{T}s" repeatCount="indefinite" calcMode="discrete" keyTimes="{dot_keys}" values="{dot_vals}"/></circle>')
    out.append(f'<circle cx="{fmt(ix)}" cy="{iy}" r="9.5" fill="{GREEN}">'
               f'<animate attributeName="fill" dur="{T}s" repeatCount="indefinite" calcMode="discrete" keyTimes="{dot_keys}" values="{dot_vals}"/></circle>')
    # three speed streaks before the p, in the cars' colours
    for k, c in enumerate(CARS):
        sy = y - 50 + k * 15
        ln = 30 - k * 8
        out.append(f'<line x1="{x - 22 - ln}" y1="{sy}" x2="{x - 20}" y2="{sy}" stroke="{c}" stroke-width="5" stroke-linecap="round" opacity="0.9">'
                   f'<animate attributeName="x1" dur="{T / 4}s" repeatCount="indefinite" values="{x - 22 - ln};{x - 22 - ln - 8};{x - 22 - ln}"/></line>')
    return '\n    '.join(out)


def svg(w, h, body, title):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img" aria-labelledby="t">
  <title id="t">{title}</title>{defs()}
  {body}
</svg>
'''


def banner():
    W, H = 900, 260
    body = [f'<rect width="{W}" height="{H}" rx="36" fill="{ASPHALT}"/>',
            f'<rect width="{W}" height="{H}" rx="36" fill="none" stroke="#FFFFFF" stroke-opacity="0.05" stroke-width="1.5"/>',
            mark(10 + 0, 10),
            wordmark(338, 150),
            f'<text x="306" y="214" fill="{MUTED}" font-family="Inter, \'Segoe UI\', Helvetica, Arial, \'DejaVu Sans\', sans-serif" '
            f'font-size="19" letter-spacing="0.3">parallel Claude Code sessions, each in its own lane</text>']
    return svg(W, H, '\n  '.join(body), 'Pitlane')


def mark_only():
    return svg(240, 240, mark(), 'Pitlane')


if __name__ == '__main__':
    (OUT / 'pitlane-banner.svg').write_text(banner())
    (OUT / 'pitlane-mark.svg').write_text(mark_only())
    print('wrote', OUT / 'pitlane-banner.svg', OUT / 'pitlane-mark.svg')
