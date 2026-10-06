#!/usr/bin/env python3
"""
Import the Freerouting result into the board, pour a ground plane on
the back, refill zones and save.

    python hardware/tools/finish_pcb.py build/shield.ses
"""

import os
import sys
import pcbnew
from pcbnew import VECTOR2I_MM as MM

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sexp import parse, find, find_all

HERE = os.path.dirname(os.path.abspath(__file__))
PCB = os.path.normpath(os.path.join(HERE, '..', 'kicad', 'hospital_monitor_shield.kicad_pcb'))


def import_ses(board, ses_path):
    """
    Read Freerouting's session file and add its tracks and vias.

    pcbnew's own ImportSpecctraSES needs the GUI, so this does the
    same job by hand. Units: the file says (resolution um 10), i.e.
    10 units per micrometre. Specctra's y axis points up, KiCad's
    down, so y is negated.
    """
    tree = parse(open(ses_path).read())[0]
    routes = find(tree, 'routes')
    res = find(routes, 'resolution')
    per_um = int(res[2])

    def to_nm(v):
        return int(round(int(v) * 1000 / per_um))

    layers = {'F.Cu': pcbnew.F_Cu, 'B.Cu': pcbnew.B_Cu}
    n_tracks = n_vias = 0

    for net in find_all(find(routes, 'network_out'), 'net'):
        netinfo = board.FindNet(net[1])
        if netinfo is None:
            raise SystemExit(f'SES names unknown net {net[1]}')

        for wire in find_all(net, 'wire'):
            path = find(wire, 'path')
            layer, width = path[1], to_nm(path[2])
            coords = [to_nm(v) for v in path[3:]]
            pts = [(coords[i], -coords[i + 1]) for i in range(0, len(coords), 2)]
            for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
                t = pcbnew.PCB_TRACK(board)
                t.SetStart(pcbnew.VECTOR2I(x1, y1))
                t.SetEnd(pcbnew.VECTOR2I(x2, y2))
                t.SetWidth(width)
                t.SetLayer(layers[layer])
                t.SetNet(netinfo)
                board.Add(t)
                n_tracks += 1

        for via in find_all(net, 'via'):
            # "Via[0-1]_800:400_um" -> diameter 800 um, drill 400 um
            name = via[1]
            dia, drill = name.split('_')[1].split(':')
            drill = drill.replace('um', '')
            v = pcbnew.PCB_VIA(board)
            v.SetPosition(pcbnew.VECTOR2I(to_nm(via[2]), -to_nm(via[3])))
            v.SetWidth(int(dia) * 1000)
            v.SetDrill(int(drill) * 1000)
            v.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
            v.SetNet(netinfo)
            board.Add(v)
            n_vias += 1

    print(f'imported {n_tracks} track segments and {n_vias} vias from {ses_path}')


def main(ses):
    board = pcbnew.LoadBoard(PCB)
    import_ses(board, ses)

    # Ground pour on the back layer, the whole board.
    gnd = board.FindNet('GND')
    zone = pcbnew.ZONE(board)
    zone.SetLayer(pcbnew.B_Cu)
    zone.SetNet(gnd)
    zone.SetLocalClearance(pcbnew.FromMM(0.3))
    zone.SetMinThickness(pcbnew.FromMM(0.25))
    zone.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    zone.SetThermalReliefGap(pcbnew.FromMM(0.4))
    zone.SetThermalReliefSpokeWidth(pcbnew.FromMM(0.5))
    outline = zone.Outline()
    outline.NewOutline()
    for x, y in ((0.8, 0.8), (79.2, 0.8), (79.2, 74.2), (0.8, 74.2)):
        outline.Append(pcbnew.FromMM(x), pcbnew.FromMM(y))
    board.Add(zone)

    filler = pcbnew.ZONE_FILLER(board)
    filler.Fill(board.Zones())

    board.Save(PCB)
    tracks = sum(1 for t in board.GetTracks() if t.GetClass() == 'PCB_TRACK')
    vias = sum(1 for t in board.GetTracks() if t.GetClass() == 'PCB_VIA')
    print(f'saved {PCB}: {tracks} track segments, {vias} vias, ground pour on B.Cu')


if __name__ == '__main__':
    main(sys.argv[1])
