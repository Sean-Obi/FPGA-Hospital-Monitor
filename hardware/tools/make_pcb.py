#!/usr/bin/env python3
"""
Build hardware/kicad/hospital_monitor_shield.kicad_pcb from the schematic's
netlist, using KiCad's own pcbnew Python module.

    kicad-cli sch export netlist --format kicadsexpr -o build/shield.net hardware/kicad/hospital_monitor_shield.kicad_sch
    python hardware/tools/make_pcb.py build/shield.net

Places every footprint, draws the board outline and mounting holes,
sets the design rules, and writes the board unrouted plus a Specctra
DSN for Freerouting. route.sh then autoroutes it and pours the ground
plane.
"""

import os
import sys
import pcbnew
from pcbnew import VECTOR2I_MM as MM

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sexp import parse, find, find_all

HERE = os.path.dirname(os.path.abspath(__file__))
KICAD_DIR = os.path.normpath(os.path.join(HERE, '..', 'kicad'))
OUT = os.path.join(KICAD_DIR, 'hospital_monitor_shield.kicad_pcb')
FP_LIB = '/usr/share/kicad/footprints/'

# Where everything goes (mm). The Cmod sits on the right; sensors on
# the left so their cables leave the board away from the USB plug.
#                   (x, y, rotation)
PLACE = {
    'U3':  (62.0, 38.0, 0),     # Cmod A7 socket
    'J1':  (6.5, 12.0, 0),      # AD8232, 1x6 socket
    'J2':  (6.5, 33.0, 0),      # MAX30102, 1x7 socket
    'J3':  (6.5, 56.0, 0),      # TMP36 leads, 1x3 socket
    'U1':  (27.0, 60.0, 90),    # MCP6002 DIP-8
    'C3':  (14.0, 62.0, 90),    # TMP36 decoupling
    'C4':  (38.0, 60.0, 0),     # op-amp decoupling
    'U2':  (27.0, 10.0, 0),     # MCP1700 TO-92
    'C1':  (20.0, 18.0, 0),
    'C2':  (34.0, 18.0, 0),
    'R1':  (23.0, 34.0, 0),
    'BZ1': (41.0, 33.0, 0),
    'H1':  (3.5, 3.5, 0),
    'H2':  (76.5, 3.5, 0),
    'H3':  (3.5, 71.5, 0),
    'H4':  (76.5, 71.5, 0),
}

BOARD_W, BOARD_H = 80.0, 75.0


def load_footprint(lib_id):
    lib, name = lib_id.split(':')
    if lib == 'ECG':
        path = os.path.join(KICAD_DIR, 'ECG.pretty')
    else:
        path = os.path.join(FP_LIB, lib + '.pretty')
    fp = pcbnew.FootprintLoad(path, name)
    if fp is None:
        raise SystemExit(f'footprint not found: {lib_id}')
    return fp


def main(netlist_path):
    tree = parse(open(netlist_path).read())[0]
    board = pcbnew.BOARD()

    # ---- design rules: generous, for a hobby-grade fab ----
    ds = board.GetDesignSettings()
    nc = ds.m_NetSettings.m_DefaultNetClass
    nc.SetClearance(pcbnew.FromMM(0.2))      # TO-92 pads are 1.27 mm apart
    nc.SetTrackWidth(pcbnew.FromMM(0.5))
    nc.SetViaDiameter(pcbnew.FromMM(0.8))
    nc.SetViaDrill(pcbnew.FromMM(0.4))
    ds.m_MinClearance = pcbnew.FromMM(0.15)
    ds.m_TrackMinWidth = pcbnew.FromMM(0.25)
    ds.m_CopperEdgeClearance = pcbnew.FromMM(0.5)

    # ---- nets ----
    nets = {}
    for n in find_all(find(tree, 'nets'), 'net'):
        name = find(n, 'name')[1]
        if name.startswith('unconnected'):
            continue
        item = pcbnew.NETINFO_ITEM(board, name)
        board.Add(item)
        nets[name] = (item, [(find(x, 'ref')[1], find(x, 'pin')[1]) for x in find_all(n, 'node')])

    # ---- footprints ----
    fps = {}
    for comp in find_all(find(tree, 'components'), 'comp'):
        ref = find(comp, 'ref')[1]
        value = find(comp, 'value')[1]
        lib_id = find(comp, 'footprint')[1]
        fp = load_footprint(lib_id)
        fp.SetReference(ref)
        fp.SetValue(value)
        x, y, rot = PLACE[ref]
        fp.SetPosition(MM(x, y))
        fp.SetOrientationDegrees(rot)
        board.Add(fp)
        fps[ref] = fp

    # mounting holes
    for ref in ('H1', 'H2', 'H3', 'H4'):
        fp = load_footprint('MountingHole:MountingHole_3.2mm_M3')
        fp.SetReference(ref)
        fp.SetValue('M3')
        x, y, rot = PLACE[ref]
        fp.SetPosition(MM(x, y))
        board.Add(fp)

    # ---- connect pads to nets ----
    for name, (item, nodes) in nets.items():
        for ref, pin in nodes:
            pad = fps[ref].FindPadByNumber(pin)
            if pad is None:
                raise SystemExit(f'{ref} has no pad {pin}')
            pad.SetNet(item)

    # ---- outline ----
    rect = pcbnew.PCB_SHAPE(board)
    rect.SetShape(pcbnew.SHAPE_T_RECT)
    rect.SetStart(MM(0, 0))
    rect.SetEnd(MM(BOARD_W, BOARD_H))
    rect.SetLayer(pcbnew.Edge_Cuts)
    rect.SetWidth(pcbnew.FromMM(0.1))
    board.Add(rect)

    # ---- silkscreen notes ----
    def note(text, x, y, size=1.0, layer=pcbnew.F_SilkS):
        t = pcbnew.PCB_TEXT(board)
        t.SetText(text)
        t.SetPosition(MM(x, y))
        t.SetLayer(layer)
        t.SetTextSize(pcbnew.VECTOR2I(pcbnew.FromMM(size), pcbnew.FromMM(size)))
        t.SetTextThickness(pcbnew.FromMM(0.15))
        if layer == pcbnew.B_SilkS:
            t.SetMirrored(True)          # readable when the board is turned over
        board.Add(t)

    note('FPGA HOSPITAL MONITOR  shield rev 1', 40.0, 2.5, 1.2)
    note('AD8232:  GND 3V3 OUT LO- LO+ SDN', 24.0, 4.5, 0.8)
    note('MAX30102:  VIN SCL SDA INT IRD RD GND', 25.0, 24.5, 0.8)
    note('TMP36:  +Vs Vout GND', 17.0, 51.0, 0.8)
    note('not a medical device', 40.0, 73.0, 0.8)
    note('github: Sean-Obi/FPGA-Hospital-Monitor', 40.0, 2.5, 1.0, pcbnew.B_SilkS)

    board.Save(OUT)
    print('wrote', OUT)

    dsn = os.path.join(os.path.dirname(netlist_path), 'shield.dsn')
    if not pcbnew.ExportSpecctraDSN(board, dsn):
        raise SystemExit('DSN export failed')
    print('wrote', dsn)


if __name__ == '__main__':
    main(sys.argv[1])
