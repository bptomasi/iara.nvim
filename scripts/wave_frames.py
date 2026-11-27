"""Regenerate the start screen artwork with NumPy, Pillow, and SciPy.

Use the public-domain JP2972 IIIF main image from The Metropolitan Museum
of Art as the input. The checksum keeps the crop tied to that exact image.
See https://www.metmuseum.org/art/collection/search/56353.
"""

from argparse import ArgumentParser
from hashlib import sha256
from itertools import groupby
from math import pi, sin
from pathlib import Path
from re import findall

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter, map_coordinates, maximum_filter

SOURCE = (
    "https://collectionapi.metmuseum.org/api/collection/v1/"
    "iiif/56353/140298/main-image"
)
SOURCE_SHA256 = (
    "93188ad98b7c154606e71665042d588766e5e87cf36cdcc1bb308bba9af6d4a8"
)
OUTPUT = Path(__file__).resolve().parents[1] / "lua/iara/core/start_wave.lua"
WIDTH = 50
VARIANTS = ((15, 40, .285), (6, 25, .23), (3, 25, .225))
FRAME_COUNT = 216
EMPTY = "⠀"
CROP = (29, 63, 1171, 787)
SIZE = (500, 300)
BITS = ((0, 3), (1, 4), (2, 5), (6, 7))

# Delineate the original waterline, excluding the inscription and sky.
CREST = [
    (28, 277), (53, 285), (88, 289), (118, 280), (146, 257),
    (169, 228), (207, 190), (246, 155), (299, 123), (339, 106),
    (365, 94), (401, 88), (431, 78), (470, 76), (498, 88),
    (527, 110), (554, 116), (575, 132), (591, 155), (599, 181),
    (596, 193), (616, 204), (639, 207), (666, 215), (681, 230),
    (696, 252), (709, 255), (712, 276), (697, 284), (694, 309),
    (689, 337), (668, 352), (635, 350), (606, 330), (565, 322),
    (542, 300), (527, 306), (511, 318), (501, 339), (491, 362),
    (482, 387), (487, 418), (505, 466), (540, 515), (581, 552),
    (622, 574), (665, 597), (716, 599), (772, 590), (814, 587),
    (862, 559), (916, 543), (968, 510), (1017, 470), (1057, 432),
    (1101, 390), (1138, 353), (1172, 324),
]
FUJI = [
    (691, 567), (704, 554), (720, 542), (732, 533), (744, 519),
    (753, 512), (763, 519), (782, 539), (804, 553), (823, 570),
    (785, 578), (724, 577),
]
BOATS = [
    [(50, 407), (79, 441), (122, 482), (169, 504), (240, 519),
     (287, 533), (267, 557), (224, 574), (182, 570), (127, 540),
     (87, 494), (64, 449)],
    [(497, 615), (542, 653), (586, 681), (648, 707), (723, 724),
     (806, 723), (884, 714), (913, 724), (888, 743), (836, 755),
     (729, 747), (654, 731), (580, 700), (523, 655)],
    [(651, 549), (709, 570), (760, 579), (825, 571), (890, 545),
     (957, 498), (1045, 424), (1012, 475), (955, 527), (892, 566),
     (833, 588), (774, 595), (709, 592)],
]


def mask(polygons):
    image = Image.new("L", (1200, 810))
    draw = ImageDraw.Draw(image)
    for points in polygons:
        draw.polygon(points, fill=255)
    return np.asarray(image.crop(CROP).resize(SIZE)) / 255.


def smooth(start, end, value):
    x = np.clip((value - start) / (end - start), 0, 1)
    return x * x * (3 - 2 * x)


Y, X = np.mgrid[0:SIZE[1], 0:SIZE[0]].astype(float)
Y /= SIZE[1]
X /= SIZE[0]
FOREGROUND = smooth(.62, .875, Y)


def separate_print(path):
    with Image.open(path) as image:
        rgb = np.asarray(image.convert("RGB").crop(CROP).resize(SIZE))
    r, g, b = np.moveaxis(rgb.astype(float), -1, 0)
    water = mask([CREST + [(1172, 787), (28, 787)]])
    blue = smooth(-25, 10, b - r)
    turquoise = smooth(-7, 20, g - r)
    ink = np.maximum(blue, turquoise)
    dark = 1 - smooth(90, 145, r)
    paper = smooth(163, 219, r)
    foam_zone = np.exp(-((X - .452) / .190)**4 - ((Y - .204) / .231)**4)
    foam_zone *= .45 + .55 * smooth(.37, .58, X)
    foam_edges = gaussian_filter(ink, 2.3)
    # Light contours pick out the paper left between the original ink lines.
    foam = paper * smooth(.10, .38, foam_edges) * foam_zone * water
    rim = maximum_filter(water, size=5) - water
    shoulder = (1 - smooth(.51, .60, X)) * (1 - smooth(.31, .44, Y))
    rim *= shoulder * (.54 + .38 * smooth(.25, .45, X))
    claws = smooth(.36, .515, X) * (1 - smooth(.39, .48, Y))
    pale_ink = smooth(102, 188, r) * ink
    boats = mask(BOATS) * (.23 + .43 * dark + .35 * ink)
    density = np.maximum.reduce([water * ink * .73, foam * .85, rim, boats])
    tone = np.maximum.reduce([
        water * (turquoise * (.28 + .29*foam_zone) + pale_ink * claws * .63),
        foam,
        rim * (.43 + .36 * smooth(.29, .49, X)),
        boats * .65,
    ])
    mountain = mask([FUJI])
    # The snow is paper in the source, so isolate Fuji from the paper sky.
    fixed = mountain * (.8 + .2 * paper)
    fixed_tone = mountain * (.40 + .53 * paper)
    summit = maximum_filter(mountain, size=(23, 25))
    summit *= 1 - smooth(.666, .711, Y)
    return density, tone, fixed, fixed_tone, gaussian_filter(summit, 1.2)


def water_rows(t):
    # The swell travels across the print through local rises and dips.
    phase = 2 * pi * t
    offshore = smooth(.59, .87, X) * smooth(.25, .52, Y)
    coast = 5 * X - 4 * Y
    lift = offshore * .031 * (np.sin(coast - phase) - np.sin(coast))
    near = (1 - smooth(.14, .45, X)) * smooth(.65, .95, Y)
    eddy = 13 * X + 7 * Y
    lift += near * .025 * (np.cos(eddy - phase) - np.cos(eddy))
    depth = smooth(.40, .74, Y)
    angle = 19 * X + 5 * Y
    lift += depth * .013 * (np.sin(angle - phase) - np.sin(angle))
    return Y + (1 - .62 * FOREGROUND) * lift


def surface_texture(t, rows, density, tone):
    # Use full troughs in the deep water and shallow filaments in the curl.
    shore = (1 - smooth(.15, .33, X)) * smooth(.51, .76, Y)
    foreground = np.maximum(shore, smooth(.59, .85, Y))
    offshore = smooth(.59, .87, X) * smooth(.32, .58, Y)
    envelope = smooth(0, .14, t) * (1 - smooth(.84, 1, t))
    face = smooth(.035, .111, Y) * (1 - smooth(.52, .71, Y))
    face *= 1 - smooth(.54, .66, X)
    angle = 24 * X + 49 * rows + 1.7 * np.sin(8 * X + 6 * rows)
    open_water = .5 + .5 * np.cos(angle - 2 * pi * t)
    depth = np.maximum(foreground, offshore) * envelope
    depth *= 1 - .61 * FOREGROUND
    channel = depth * smooth(.57, .99, open_water)
    filament = .5 + .5 * np.cos(29 * X - 25 * rows - 2 * pi * t)
    shallow = face * envelope * smooth(.51, .99, filament)
    trough = np.maximum(.90 * channel, .48 * shallow)
    density *= 1 - trough
    ridge = depth * smooth(.56, .99, 1 - open_water) * density * .59
    ridge += face * envelope * smooth(.59, .99, 1 - filament) * density * .20
    return density, np.maximum(tone * (1 - .60 * trough), ridge)


def crest_rows(t, rows):
    # The lip flexes ahead of the shoulder while the curl stays raised.
    phase = 2 * pi * t
    lip = smooth(.26, .61, X) * (1 - smooth(.68, .80, X))
    lip *= 1 - smooth(.42, .65, Y)
    shoulder = smooth(.005, .32, X) * (1 - smooth(.40, .71, X))
    shoulder *= 1 - smooth(.35, .72, Y)
    curl = .017 * (sin(phase - .55) - sin(-.55))
    lift = .016 * (np.sin(phase - 3 * X) - np.sin(-3 * X))
    return rows - lip * curl - shoulder * lift


def sample(values, rows, edge="nearest"):
    return map_coordinates(
        values, [rows * SIZE[1], X * SIZE[0]], order=1, mode=edge
    )


def swell(t, water, colors):
    rows = water_rows(t)
    curl_rows = crest_rows(t, rows)
    crest = (1 - smooth(.62, .79, X)) * (1 - smooth(.68, .79, Y))
    bed = 1 - crest
    tide = sample(water, rows, "reflect") * bed
    tint = sample(colors, rows, "reflect") * bed
    tide += sample(water, curl_rows) * crest
    tint += sample(colors, curl_rows) * crest
    return surface_texture(t, rows, tide, tint)


def scene(t, layers):
    water, colors, mountain, snow, summit = layers
    density, tone = swell(t, water, colors)
    # Distant land stays fixed as the surface moves past its base.
    clear_sky = smooth(.016, .067, t) * (1 - smooth(.90, .995, t))
    foreground = 1 - mountain * (1 - smooth(.62, .70, Y))
    visibility = 1 - summit * clear_sky
    density = density * foreground * visibility
    tone = tone * foreground * visibility
    return np.maximum(density, mountain), np.maximum(tone, snow)


def dots(values, height):
    im = Image.fromarray(np.float32(values))
    size = (WIDTH * 2, height * 4)
    return np.asarray(im.resize(size, Image.Resampling.LANCZOS))


def braille_cell(density, tone, threshold):
    char, levels = 0x2800, []
    for y, bits in enumerate(BITS):
        for x, bit in enumerate(bits):
            if density[y, x] >= threshold:
                char |= 1 << bit
                levels.append(tone[y, x])
    color = np.mean(levels) if levels else 0
    tone_id = 3 if color > .415 else 2 if color > .212 else 1
    return chr(char), tone_id


def encode(density, tone, height, threshold):
    on, glow = dots(density, height), dots(tone, height)
    for y in range(0, height * 4, 4):
        cells = [
            braille_cell(on[y:y+4, x:x+2], glow[y:y+4, x:x+2], threshold)
            for x in range(0, WIDTH * 2, 2)
        ]
        yield pack_row(cells)


def pack_row(cells):
    # Carry the previous tone over blank cells to avoid extra color changes.
    row, previous = [], 1
    for char, tone in cells:
        if char != EMPTY:
            previous = tone
        row.append((char, previous))
    while len(row) > 1 and row[-1][0] == EMPTY:
        row.pop()
    parts = []
    for tone, group in groupby(row, key=lambda cell: cell[1]):
        parts.append(str(tone) + "".join(char for char, _ in group))
    return "".join(parts)


def lua_row(row):
    if len(row) <= 71:
        return [f'      "{row}",']
    # Split long rows at a color boundary so each part is still readable.
    spans = findall("[123][^123]+", row)
    right = ""
    while len(right) < len(row) / 2:
        right = spans.pop() + right
    left = "".join(spans)
    return [f'      "{left}"', f'        .. "{right}",']


def lua_frames(layers):
    variants = [[] for _ in VARIANTS]
    seen = [{} for _ in VARIANTS]
    for index in range(FRAME_COUNT):
        frame = scene(index / FRAME_COUNT, layers)
        for lines, poses, variant in zip(variants, seen, VARIANTS):
            height, _, threshold = variant
            rows = tuple(encode(*frame, height, threshold))
            previous = poses.get(rows)
            if previous is not None:
                lines.append(f"    {previous},")
                continue
            poses[rows] = index + 1
            lines.append("    {")
            for row in rows:
                lines.extend(lua_row(row))
            lines.append("    },")
    return variants


def lua_art(layers):
    lines = [
        "--- The Great Wave off Kanagawa by Katsushika Hokusai (ca. 1830–32).",
        "--- Public-domain image, The Metropolitan Museum of Art, JP2972.",
        "--- https://www.metmuseum.org/art/collection/search/56353",
        "--- Generated by scripts/wave_frames.py. Keep this file in sync.",
        "--- Each Braille span starts with its tone ID (tide, surf, or foam).",
        "--- A numeric entry repeats an earlier frame for one tick.",
        "local function variant(min_width, frames)",
        "  for index, frame in ipairs(frames) do",
        '    if type(frame) == "number" then',
        "      frames[index] = frames[frame]",
        "    end",
        "  end",
        "  return {",
        f"    width = {WIDTH},",
        "    min_width = min_width,",
        "    still = frames[1],",
        "    frames = frames,",
        "  }",
        "end",
        "",
        "return {",
    ]
    for (_, minimum, _), frames in zip(VARIANTS, lua_frames(layers)):
        lines.append(f"  variant({minimum}, {{")
        lines.extend(frames)
        lines.append("  }),")
    return "\n".join(lines + ["}", ""])


def main():
    parser = ArgumentParser(
        description=__doc__, epilog=f"Source image: {SOURCE}"
    )
    parser.add_argument("image", type=Path, help="The JP2972 IIIF main image")
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()
    try:
        digest = sha256(args.image.read_bytes()).hexdigest()
    except OSError as error:
        parser.error(str(error))
    if digest != SOURCE_SHA256:
        parser.error(f"The input must match the original Met image at {SOURCE}")
    layers = separate_print(args.image)
    args.output.write_text(lua_art(layers), encoding="utf-8")


if __name__ == "__main__":
    main()
