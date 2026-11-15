#!/usr/bin/env python3
"""Генератор карты для HOI-CC.

Делает map.lua: материки с изрезанными берегами, провинции, страны, соседей.
Запуск:  python3 gen_map.py [seed]     (нужны numpy, scipy, pillow)
Каждый seed даёт новый мир. Кладёшь получившийся map.lua рядом с main.lua.
"""
import sys, random, collections
import numpy as np
from scipy import ndimage

SEED = int(sys.argv[1]) if len(sys.argv) > 1 else 7
W, H = 240, 130            # размер мира в клетках
CW, CH = 6, 9              # размер клетки монитора в пикселях (для правильных пропорций)
N_PROV = 56
N_COUNTRIES = 8

rng = np.random.default_rng(SEED)
pyr = random.Random(SEED)

X = (np.arange(W)[None, :] + 0.5) * CW * np.ones((H, 1))
Y = (np.arange(H)[:, None] + 0.5) * CH * np.ones((1, W))
PW, PH = W * CW, H * CH


def fractal(octaves=5, base=3, persistence=0.55):
    total = np.zeros((H, W))
    amp, norm = 1.0, 0.0
    for i in range(octaves):
        g = base * (2 ** i)
        small = rng.random((max(2, g * H // W + 2), g + 2))
        up = ndimage.zoom(small, (H / small.shape[0], W / small.shape[1]), order=3)
        up = up[:H, :W]
        if up.shape != (H, W):
            up = np.pad(up, ((0, H - up.shape[0]), (0, W - up.shape[1])), mode="edge")
        total += amp * up
        norm += amp
        amp *= persistence
    total /= norm
    return (total - total.min()) / (total.max() - total.min())


# ---------------------------------------------------------------- суша
noise = fractal(6, 3, 0.55)
blobs = np.zeros((H, W))
centers = [(0.22, 0.38, 0.20), (0.52, 0.55, 0.23), (0.80, 0.35, 0.19), (0.62, 0.15, 0.10),
           (0.30, 0.80, 0.11)]
for cx, cy, r in centers:
    d2 = ((X - cx * PW) ** 2 + (Y - cy * PH) ** 2) / (r * PW) ** 2
    blobs += np.exp(-d2)
edge = np.minimum.reduce([X / PW, (PW - X) / PW, Y / PH, (PH - Y) / PH])
edge = np.clip(edge / 0.07, 0, 1)
height = (0.95 * noise + 0.60 * blobs) * edge
land = height > np.quantile(height, 0.58)

# убираем крошечные острова и озёра
lab, n = ndimage.label(land)
sizes = ndimage.sum(land, lab, range(1, n + 1))
for i, s in enumerate(sizes, 1):
    if s < 90:
        land[lab == i] = False
lab, n = ndimage.label(~land)
sizes = ndimage.sum(~land, lab, range(1, n + 1))
for i, s in enumerate(sizes, 1):
    if s < 60:
        land[lab == i] = True

# ---------------------------------------------------------------- семена провинций
land_cells = np.argwhere(land)


def px(c):
    return np.array([(c[1] + 0.5) * CW, (c[0] + 0.5) * CH])


seeds = [tuple(land_cells[rng.integers(len(land_cells))])]
while len(seeds) < N_PROV:
    best, bd = None, -1
    for _ in range(40):
        c = tuple(land_cells[rng.integers(len(land_cells))])
        d = min(np.hypot(*(px(c) - px(s))) for s in seeds)
        if d > bd:
            best, bd = c, d
    seeds.append(best)

# каждому крупному острову — свой центр
lab, n = ndimage.label(land)
for comp in range(1, n + 1):
    if not any(lab[s] == comp for s in seeds):
        cells = np.argwhere(lab == comp)
        seeds.append(tuple(cells[len(cells) // 2]))

# ---------------------------------------------------------------- провинции (Voronoi с искажением)
amp = 38
wx = X + (fractal(4, 4) - 0.5) * 2 * amp
wy = Y + (fractal(4, 4) - 0.5) * 2 * amp
dist = np.stack([np.hypot(wx - px(s)[0], wy - px(s)[1]) for s in seeds])
prov = np.argmin(dist, axis=0) + 1
prov[~land] = 0

# каждая провинция — одна связная область, куски отдельно пересаживаем соседям
for i, s in enumerate(seeds, 1):
    m = prov == i
    l, k = ndimage.label(m)
    if k <= 1:
        continue
    keep = l[s] if l[s] > 0 else int(np.argmax(ndimage.sum(m, l, range(1, k + 1)))) + 1
    prov[m & (l != keep)] = -1
for _ in range(400):
    changed = False
    cur = prov.copy()
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nb = np.roll(np.roll(prov, dy, 0), dx, 1)
        take = (cur == -1) & (nb > 0)
        if take.any():
            cur[take] = nb[take]
            changed = True
    prov = cur
    if not changed:
        break
prov[prov == -1] = 0
land = prov > 0

# убираем провинции, которые стали слишком мелкими: вливаем в соседа
present = [i for i in range(1, len(seeds) + 1) if (prov == i).sum() > 0]
remap = {old: new for new, old in enumerate(present, 1)}
newprov = np.zeros_like(prov)
for old, new in remap.items():
    newprov[prov == old] = new
prov = newprov
NP = len(present)

# ---------------------------------------------------------------- соседи, центры
nbrs = [set() for _ in range(NP + 1)]
coast = [False] * (NP + 1)
for dy, dx in ((1, 0), (0, 1)):
    a = prov[: H - dy, : W - dx]
    b = prov[dy:, dx:]
    m = (a != b) & (a > 0) & (b > 0)
    for p, q in zip(a[m], b[m]):
        nbrs[p].add(int(q))
        nbrs[q].add(int(p))
    m = (a != b) & ((a == 0) | (b == 0))
    for p, q in zip(a[m], b[m]):
        coast[max(p, q)] = True

labelcell = [None] * (NP + 1)
for i in range(1, NP + 1):
    m = prov == i
    dt = ndimage.distance_transform_edt(m, sampling=(CH, CW))
    y, x = np.unravel_index(np.argmax(dt), dt.shape)
    labelcell[i] = (int(x) + 1, int(y) + 1)   # 1-индексация для Lua

# ---------------------------------------------------------------- страны
cent = {i: np.array(labelcell[i], float) * [CW, CH] for i in range(1, NP + 1)}
caps = [pyr.randint(1, NP)]
while len(caps) < N_COUNTRIES:
    best = max((i for i in range(1, NP + 1) if i not in caps),
               key=lambda i: min(np.hypot(*(cent[i] - cent[c])) for c in caps))
    caps.append(best)
owner = {c: k for k, c in enumerate(caps)}
size = [1] * N_COUNTRIES
while len(owner) < NP:
    progress = False
    for k in sorted(range(N_COUNTRIES), key=lambda k: size[k] + pyr.random()):
        cand = [q for p, o in owner.items() if o == k for q in nbrs[p] if q not in owner]
        if cand:
            q = pyr.choice(cand)
            owner[q] = k
            size[k] += 1
            progress = True
            break
    if not progress:  # острова без сухопутной связи
        free = [i for i in range(1, NP + 1) if i not in owner]
        i = free[0]
        k = min(range(N_COUNTRIES), key=lambda k: min(
            np.hypot(*(cent[i] - cent[p])) for p, o in owner.items() if o == k))
        owner[i] = k
        size[k] += 1

# ---------------------------------------------------------------- имена
CNAMES = ["Arvandor", "Kestria", "Morvania", "Tallis", "Zephyria", "Brannock", "Dravia", "Solmark"]
CIDS = ["ARV", "KES", "MOR", "TAL", "ZEP", "BRA", "DRA", "SOL"]
COLORS = [  # (имя слота палитры, hex)
    ("red", 0xB8483F), ("orange", 0xD9893B), ("yellow", 0xCDBB57), ("green", 0x4F9B5B),
    ("cyan", 0x3BA39A), ("magenta", 0x9C5A97), ("purple", 0x7466B0), ("brown", 0x93704A),
]
pyr.shuffle(COLORS)
A = ["ar", "al", "bel", "bor", "cal", "dor", "el", "fen", "gar", "hel", "isk", "kar", "lor", "mar",
     "nor", "ost", "pol", "ran", "sel", "tor", "ul", "val", "wen", "yar", "zan", "mor", "tev", "ben"]
B = ["a", "o", "i", "e", "u", "an", "en", "or", "is", "ia"]
Cend = ["burg", "grad", "ton", "ford", "haven", "vik", "polis", "stead", "dale", "mont", "ria", "land",
        "mere", "port", "wick"]
used = set()


def pname():
    while True:
        n = pyr.choice(A) + (pyr.choice(B) if pyr.random() < 0.4 else "") + pyr.choice(Cend)
        n = n.capitalize()
        if n not in used and len(n) <= 10:
            used.add(n)
            return n


def lum(h):
    r, g, b = (h >> 16) & 255, (h >> 8) & 255, h & 255
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255


provs = []
for i in range(1, NP + 1):
    is_cap = i in caps
    provs.append(dict(
        id=i, name=pname(), owner=CIDS[owner[i]], cx=labelcell[i][0], cy=labelcell[i][1],
        cap=is_cap, pop=pyr.randint(2, 9) + (6 if is_cap else 0),
        ind=pyr.randint(0, 4) + (4 if is_cap else 0), nb=sorted(nbrs[i]), coast=coast[i]))

# ---------------------------------------------------------------- глубина моря
dist_land = ndimage.distance_transform_edt(~land, sampling=(CH, CW))
grid = prov.copy()
grid[(~land) & (dist_land <= 22)] = -1       # мелководье

# ---------------------------------------------------------------- вывод Lua
PALETTE = {
    "black": 0x151B24, "white": 0xFFFFFF, "gray": 0x555B66, "lightGray": 0xB5BBC4,
    "blue": 0x2B5C9E, "lightBlue": 0x4F8FD0, "lime": 0x7CC450, "pink": 0xE58FA8,
}
for name, hx in COLORS:
    PALETTE[name] = hx

out = ["-- map.lua: СГЕНЕРИРОВАНО gen_map.py (seed %d). Руками не править." % SEED,
       "return {", "  w = %d, h = %d," % (W, H),
       '  seaDeep = "blue", seaShallow = "lightBlue",', "  palette = {"]
for k, v in PALETTE.items():
    out.append("    %s = 0x%06X," % (k, v))
out.append("  },")
out.append("  countries = {")
for k in range(N_COUNTRIES):
    name, hx = COLORS[k]
    out.append('    { id = "%s", name = "%s", color = "%s", fg = "%s" },' % (
        CIDS[k], CNAMES[k], name, "black" if lum(hx) > 0.55 else "white"))
out.append("  },")
out.append("  provinces = {")
for p in provs:
    out.append('    { name = "%s", owner = "%s", cx = %d, cy = %d, cap = %s, pop = %d, ind = %d, '
               'coast = %s, nb = {%s} },' % (
                   p["name"], p["owner"], p["cx"], p["cy"], str(p["cap"]).lower(), p["pop"],
                   p["ind"], str(p["coast"]).lower(), ",".join(map(str, p["nb"]))))
out.append("  },")
out.append("  rows = {")
for y in range(H):
    runs, cur, n = [], grid[y][0], 0
    for v in grid[y]:
        if v == cur:
            n += 1
        else:
            runs.append("%d:%d" % (cur, n))
            cur, n = v, 1
    runs.append("%d:%d" % (cur, n))
    out.append('    "%s",' % ",".join(runs))
out.append("  },")
out.append("}")
open("map.lua", "w").write("\n".join(out) + "\n")

# ---------------------------------------------------------------- превью
try:
    from PIL import Image
    img = np.zeros((H, W, 3), np.uint8)

    def rgb(h):
        return [(h >> 16) & 255, (h >> 8) & 255, h & 255]
    for y in range(H):
        for x in range(W):
            v = grid[y, x]
            if v == 0:
                img[y, x] = rgb(PALETTE["blue"])
            elif v == -1:
                img[y, x] = rgb(PALETTE["lightBlue"])
            else:
                img[y, x] = rgb(COLORS[owner[v]][1])
    for dy, dx in ((1, 0), (0, 1)):
        a = grid[: H - dy, : W - dx]
        b = grid[dy:, dx:]
        m = (a != b) & (a > 0)
        ys, xs = np.nonzero(m)
        for y, x in zip(ys, xs):
            same = owner.get(int(a[y, x])) == owner.get(int(b[y, x])) if b[y, x] > 0 else False
            img[y, x] = rgb(PALETTE["gray"]) if same else rgb(PALETTE["black"])
    Image.fromarray(img).resize((W * CW // 2, H * CH // 2), Image.NEAREST).save("preview.png")
except Exception as e:
    print("preview skipped:", e)

print("provinces:", NP, "countries:", N_COUNTRIES, "land cells:", int(land.sum()))
