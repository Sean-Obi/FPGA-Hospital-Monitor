#!/usr/bin/env python3
"""
Render the board the way it would come back from the fab: green solder
mask, white silkscreen, bare copper pads, drilled holes. KiCad 7's
command line cannot do a 3D render, so this composites the layers
itself.

    python hardware/tools/render_pcb.py

Writes hardware/images/pcb_front_render.png and pcb_back_render.png.
"""

import os
import subprocess
import tempfile

import cairosvg
import pcbnew
from PIL import Image, ImageChops, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
PCB = os.path.normpath(os.path.join(HERE, '..', 'kicad', 'hospital_monitor_shield.kicad_pcb'))
IMAGES = os.path.normpath(os.path.join(HERE, '..', 'images'))

WIDTH_PX = 1600                      # output width

# Colours of a typical green 1.6 mm board with HASL finish.
MASK_OVER_BARE = (10, 84, 48)        # mask over FR4
MASK_OVER_COPPER = (27, 124, 74)     # mask over copper: lighter, greener
PAD = (214, 214, 206)                # tinned pad
HOLE = (28, 24, 20)
SILK = (245, 245, 240)
EDGE = (40, 40, 40)


def layer_mask(layers, mirror, tmpdir, name):
    """Rasterise a set of layers to an 8-bit mask (255 where drawn)."""
    svg = os.path.join(tmpdir, name + '.svg')
    cmd = ['kicad-cli', 'pcb', 'export', 'svg', '--layers', layers,
           '--page-size-mode', '2', '--exclude-drawing-sheet',
           '--black-and-white', '-o', svg, PCB]
    if mirror:
        cmd.insert(-3, '--mirror')
    subprocess.run(cmd, check=True, capture_output=True)
    png = os.path.join(tmpdir, name + '.png')
    cairosvg.svg2png(url=svg, write_to=png, output_width=WIDTH_PX, background_color='white')
    img = Image.open(png).convert('L')
    return ImageChops.invert(img)     # drawn = white


def render(side, mirror):
    cu, mask, silk = ('F.Cu', 'F.Mask', 'F.SilkS') if side == 'front' else ('B.Cu', 'B.Mask', 'B.SilkS')

    with tempfile.TemporaryDirectory() as tmp:
        edge = layer_mask('Edge.Cuts', mirror, tmp, 'edge')
        copper = layer_mask(cu, mirror, tmp, 'cu')
        openings = layer_mask(mask, mirror, tmp, 'mask')
        silkscreen = layer_mask(silk, mirror, tmp, 'silk')

        # Every export uses the same page box, so the images line up.
        w, h = edge.size

        # The board area: fill inside the outline.
        board = Image.new('L', (w, h), 0)
        ImageDraw.Draw(board).rectangle(edge.getbbox(), fill=255)

        out = Image.new('RGB', (w, h), (255, 255, 255))
        out.paste(MASK_OVER_BARE, mask=board)
        out.paste(MASK_OVER_COPPER, mask=ImageChops.multiply(copper, board))
        out.paste(PAD, mask=openings)

        # Drill holes, from the board itself.
        b = pcbnew.LoadBoard(PCB)
        bbox = edge.getbbox()
        bx0, by0, bx1, by1 = [pcbnew.FromMM(v) for v in (0, 0, 80, 75)]
        sx = (bbox[2] - bbox[0]) / (bx1 - bx0)
        sy = (bbox[3] - bbox[1]) / (by1 - by0)
        draw = ImageDraw.Draw(out)

        def to_px(x, y):
            px = bbox[0] + (x - bx0) * sx
            if mirror:
                px = bbox[2] - (x - bx0) * sx
            return px, bbox[1] + (y - by0) * sy

        for fp in b.GetFootprints():
            for pad in fp.Pads():
                d = pad.GetDrillSize().x
                if d <= 0:
                    continue
                cx, cy = to_px(pad.GetPosition().x, pad.GetPosition().y)
                r = d * sx / 2
                draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=HOLE)

        # Silkscreen on top, but never over an exposed pad.
        silk_clipped = ImageChops.subtract(silkscreen, openings)
        out.paste(SILK, mask=silk_clipped)

        # Board edge.
        draw.rectangle(bbox, outline=EDGE, width=2)

        # Trim to the board with a small margin.
        m = 12
        out = out.crop((bbox[0] - m, bbox[1] - m, bbox[2] + m, bbox[3] + m))
        os.makedirs(IMAGES, exist_ok=True)
        path = os.path.join(IMAGES, f'pcb_{side}_render.png')
        out.save(path)
        print('wrote', path)


if __name__ == '__main__':
    render('front', mirror=False)
    render('back', mirror=True)
