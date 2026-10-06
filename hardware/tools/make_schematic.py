#!/usr/bin/env python3
"""
Generate hardware/kicad/hospital_monitor_shield.kicad_sch.

The schematic is written as a KiCad 7 file directly, with the library
symbols it uses copied in (that is how KiCad stores them anyway), plus
four symbols of our own for the modules that have no library entry:
the Cmod A7, the AD8232 breakout, the MAX30102 module and the TMP36
on flying leads.

    python hardware/tools/make_schematic.py
    kicad-cli sch erc hardware/kicad/hospital_monitor_shield.kicad_sch
"""

import os
import uuid
from sexp import Sym, dump, flatten_symbol, symbol_pins, find, find_all

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'kicad', 'hospital_monitor_shield.kicad_sch')
SYMLIB = '/usr/share/kicad/symbols/'

PROJECT = 'hospital_monitor_shield'
ROOT_UUID = '7c1e4a3e-0f7c-4f3e-9d2a-1e0f2a3b4c5d'


def U():
    return str(uuid.uuid4())


def effects(size=1.27, hide=False, justify=None):
    e = [Sym('effects'), [Sym('font'), [Sym('size'), size, size]]]
    if justify:
        e.append([Sym('justify')] + [Sym(j) for j in justify.split()])
    if hide:
        e.append(Sym('hide'))
    return e


# ----------------------------------------------------------------------
# OUR OWN SYMBOLS
# ----------------------------------------------------------------------

def box_symbol(name, ref_prefix, value, footprint, width, pins_left, pins_right,
               pins_top=(), pins_bottom=(), pitch=2.54, pin_len=5.08):
    """
    A rectangular symbol with named pins down each side.

    pins_left / pins_right: list of (number, name, electrical type),
    top to bottom. Pin connection points are pin_len outside the box.
    """
    n = max(len(pins_left), len(pins_right))
    h = (n + 1) * pitch
    half_w = width / 2
    top = h / 2

    body = [Sym('symbol'), name + '_0_1',
            [Sym('rectangle'), [Sym('start'), -half_w, top], [Sym('end'), half_w, -top],
             [Sym('stroke'), [Sym('width'), 0.254], [Sym('type'), Sym('default')]],
             [Sym('fill'), [Sym('type'), Sym('background')]]]]

    pins = [Sym('symbol'), name + '_1_1']

    def pin(num, nm, etype, x, y, angle):
        return [Sym('pin'), Sym(etype), Sym('line'),
                [Sym('at'), x, y, angle], [Sym('length'), pin_len],
                [Sym('name'), nm, effects()],
                [Sym('number'), num, effects()]]

    for i, (num, nm, et) in enumerate(pins_left):
        y = top - pitch * (i + 1)
        pins.append(pin(num, nm, et, -half_w - pin_len, y, 0))
    for i, (num, nm, et) in enumerate(pins_right):
        y = top - pitch * (i + 1)
        pins.append(pin(num, nm, et, half_w + pin_len, y, 180))
    # Top pins sit left of centre and bottom pins right of centre, so
    # their vertical names do not run into each other in a short box.
    for i, (num, nm, et) in enumerate(pins_top):
        x = -pitch * 2 + (i - (len(pins_top) - 1) / 2) * pitch * 2
        pins.append(pin(num, nm, et, x, top + pin_len, 270))
    for i, (num, nm, et) in enumerate(pins_bottom):
        x = pitch * 2 + (i - (len(pins_bottom) - 1) / 2) * pitch * 2
        pins.append(pin(num, nm, et, x, -top - pin_len, 90))

    sym = [Sym('symbol'), name,
           [Sym('in_bom'), Sym('yes')], [Sym('on_board'), Sym('yes')],
           [Sym('property'), 'Reference', ref_prefix, [Sym('at'), 0, top + 1.27, 0], effects()],
           [Sym('property'), 'Value', value, [Sym('at'), 0, -top - 1.27, 0], effects()],
           [Sym('property'), 'Footprint', footprint, [Sym('at'), 0, 0, 0], effects(hide=True)],
           [Sym('property'), 'Datasheet', '', [Sym('at'), 0, 0, 0], effects(hide=True)],
           body, pins]
    return sym


CUSTOM = {
    'ECG:CmodA7': box_symbol(
        'CmodA7', 'U', 'Cmod A7-35T', 'ECG:CmodA7_DIP48', 45.72,
        pins_left=[('1', 'BUZZER  (DIP 1, pio1)', 'output'),
                   ('2', 'SCL  (DIP 2, pio2)', 'bidirectional'),
                   ('3', 'SDA  (DIP 3, pio3)', 'bidirectional'),
                   ('15', 'ECG  (DIP 15, ain15)', 'input'),
                   ('16', 'TEMP  (DIP 16, ain16)', 'input')],
        pins_right=[('24', 'VU  (DIP 24)', 'power_out')],
        pins_bottom=[('25', 'GND  (DIP 25)', 'power_in')]),

    'ECG:AD8232_Module': box_symbol(
        'AD8232_Module', 'J', 'AD8232 ECG breakout', 'Connector_PinSocket_2.54mm:PinSocket_1x06_P2.54mm_Vertical', 20.32,
        pins_left=[],
        pins_right=[('3', 'OUTPUT', 'output'), ('4', 'LO-', 'output'),
                    ('5', 'LO+', 'output'), ('6', 'SDN', 'input')],
        pins_top=[('2', '3.3V', 'power_in')],
        pins_bottom=[('1', 'GND', 'power_in')]),

    'ECG:MAX30102_Module': box_symbol(
        'MAX30102_Module', 'J', 'MAX30102 oximeter module', 'Connector_PinSocket_2.54mm:PinSocket_1x07_P2.54mm_Vertical', 20.32,
        pins_left=[],
        pins_right=[('2', 'SCL', 'bidirectional'),
                    ('3', 'SDA', 'bidirectional'), ('4', 'INT', 'output'),
                    ('5', 'IRD', 'output'), ('6', 'RD', 'output')],
        pins_top=[('1', 'VIN', 'power_in')],
        pins_bottom=[('7', 'GND', 'power_in')]),

    'ECG:TMP36_Leads': box_symbol(
        'TMP36_Leads', 'J', 'TMP36 on leads', 'Connector_PinSocket_2.54mm:PinSocket_1x03_P2.54mm_Vertical', 20.32,
        pins_left=[],
        pins_right=[('2', 'Vout', 'output')],
        pins_top=[('1', '+Vs', 'power_in')],
        pins_bottom=[('3', 'GND', 'power_in')]),
}

LIBRARY = {
    'Amplifier_Operational:MCP6002-xP': ('Amplifier_Operational', 'MCP6002-xP'),
    'Regulator_Linear:MCP1700x-330xxTO': ('Regulator_Linear', 'MCP1700x-330xxTO'),
    'Device:R': ('Device', 'R'),
    'Device:C': ('Device', 'C'),
    'Device:Buzzer': ('Device', 'Buzzer'),
    'power:+3V3': ('power', '+3V3'),
    'power:GND': ('power', 'GND'),
    'power:PWR_FLAG': ('power', 'PWR_FLAG'),
}


def lib_symbol(lib_id):
    if lib_id in CUSTOM:
        s = CUSTOM[lib_id]
    else:
        lib, name = LIBRARY[lib_id]
        s = flatten_symbol(SYMLIB + lib + '.kicad_sym', name)
    s = list(s)
    s[1] = lib_id                      # stored with the library prefix
    # sub-units keep the bare name; fine for KiCad
    return s


# ----------------------------------------------------------------------
# THE SCHEMATIC
# ----------------------------------------------------------------------

class Schematic:
    def __init__(self):
        self.items = []
        self.lib_symbols = {}
        self.pins = {}          # (ref, unit) -> {num: (x, y, outward_angle)}
        self.refs = {}

    # ---- symbols ----

    def place(self, lib_id, ref, value, x, y, unit=1, footprint=None,
              rot=0, ref_offset=(0, 0), hide_value=False, value_offset=None):
        if lib_id not in self.lib_symbols:
            self.lib_symbols[lib_id] = lib_symbol(lib_id)
        sym = self.lib_symbols[lib_id]

        # footprint from the symbol unless given
        fp_prop = next(p for p in find_all(sym, 'property') if p[1] == 'Footprint')
        if footprint is None:
            footprint = fp_prop[2]

        # pin positions in schematic space (lib y is up, sheet y is down)
        import math
        for num, nm, px, py, ang, u in symbol_pins(sym):
            if u not in (unit, 0):
                continue
            a = math.radians(rot)
            rx = px * math.cos(a) - py * math.sin(a)
            ry = px * math.sin(a) + py * math.cos(a)
            sx, sy = round(x + rx, 3), round(y - ry, 3)
            outward = (ang + 180 + rot) % 360
            self.pins.setdefault((ref, unit), {})[num] = (sx, sy, outward)

        props = [
            [Sym('property'), 'Reference', ref,
             [Sym('at'), x + ref_offset[0], y + ref_offset[1] - 1.27, 0], effects()],
            [Sym('property'), 'Value', value,
             [Sym('at'), x + (value_offset or ref_offset)[0],
              y + (value_offset or (ref_offset[0], ref_offset[1] + 2.54))[1] - (0 if value_offset else 1.27), 0],
             effects(hide=hide_value)],
            [Sym('property'), 'Footprint', footprint, [Sym('at'), x, y, 0], effects(hide=True)],
            [Sym('property'), 'Datasheet', '', [Sym('at'), x, y, 0], effects(hide=True)],
        ]
        pin_uuids = [[Sym('pin'), num, [Sym('uuid'), U()]]
                     for num, *_ in symbol_pins(sym)]
        node = ([Sym('symbol'), [Sym('lib_id'), lib_id], [Sym('at'), x, y, rot],
                 [Sym('unit'), unit], [Sym('in_bom'), Sym('yes')],
                 [Sym('on_board'), Sym('yes')], [Sym('dnp'), Sym('no')],
                 [Sym('uuid'), U()]] + props + pin_uuids +
                [[Sym('instances'), [Sym('project'), PROJECT,
                  [Sym('path'), '/' + ROOT_UUID,
                   [Sym('reference'), ref], [Sym('unit'), unit]]]]])
        self.items.append(node)

    # ---- geometry helpers ----

    def pin(self, ref, num, unit=1):
        return self.pins[(ref, unit)][num]

    def pin_xy(self, ref, num, unit=1):
        x, y, _ = self.pin(ref, num, unit)
        return x, y

    def stub(self, ref, num, length=5.08, unit=1):
        """Wire outward from a pin; returns the far end."""
        import math
        x, y, ang = self.pin(ref, num, unit)
        ex = x + length * math.cos(math.radians(ang))
        ey = y - length * math.sin(math.radians(ang))
        ex, ey = round(ex, 2), round(ey, 2)
        self.wire([(x, y), (ex, ey)])
        return ex, ey

    # ---- primitives ----

    def wire(self, pts):
        # Everything is rounded to a nanometre-safe 3 decimals: KiCad
        # only joins a wire to a pin when the coordinates match exactly.
        pts = [(round(a, 3), round(b, 3)) for a, b in pts]
        for a, b in zip(pts, pts[1:]):
            self.items.append([Sym('wire'),
                               [Sym('pts'), [Sym('xy'), a[0], a[1]], [Sym('xy'), b[0], b[1]]],
                               [Sym('stroke'), [Sym('width'), 0], [Sym('type'), Sym('default')]],
                               [Sym('uuid'), U()]])

    def label(self, name, x, y, angle=0):
        x, y = round(x, 3), round(y, 3)
        just = {0: 'left bottom', 180: 'right bottom', 90: 'left bottom', 270: 'right bottom'}[angle]
        self.items.append([Sym('label'), name, [Sym('at'), x, y, angle],
                           [Sym('fields_autoplaced')],
                           effects(justify=just), [Sym('uuid'), U()]])

    def no_connect(self, x, y):
        x, y = round(x, 3), round(y, 3)
        self.items.append([Sym('no_connect'), [Sym('at'), x, y], [Sym('uuid'), U()]])

    def junction(self, x, y):
        x, y = round(x, 3), round(y, 3)
        self.items.append([Sym('junction'), [Sym('at'), x, y], [Sym('diameter'), 0],
                           [Sym('color'), 0, 0, 0, 0], [Sym('uuid'), U()]])

    def text(self, s, x, y, size=1.27):
        self.items.append([Sym('text'), s, [Sym('at'), x, y, 0],
                           effects(size=size, justify='left bottom'), [Sym('uuid'), U()]])

    # ---- power symbols, placed so their pin lands on (x, y) ----

    _pwr_n = 0

    def power(self, kind, x, y, rot=0):
        x, y = round(x, 3), round(y, 3)
        Schematic._pwr_n += 1
        ref = '#PWR%02d' % Schematic._pwr_n
        value = {'+3V3': '+3V3', 'GND': 'GND', 'PWR_FLAG': 'PWR_FLAG'}[kind]
        self.place('power:' + kind, ref, value, x, y, rot=rot,
                   ref_offset=(0, 0), hide_value=(kind == 'PWR_FLAG'))
        # hide the reference of power symbols
        node = self.items[-1]
        for p in find_all(node, 'property'):
            if p[1] == 'Reference':
                p[4].append(Sym('hide'))
            if p[1] == 'Value' and kind != 'PWR_FLAG':
                dy = 3.81 if kind == 'GND' else -3.81
                if rot == 180:
                    dy = -dy
                p[3] = [Sym('at'), x, y + dy, 0]

    # ---- output ----

    def write(self, path):
        doc = [Sym('kicad_sch'), [Sym('version'), 20230121], [Sym('generator'), Sym('eeschema')],
               [Sym('uuid'), ROOT_UUID], [Sym('paper'), 'A4'],
               [Sym('title_block'), [Sym('title'), 'FPGA Hospital Monitor - sensor shield for the Cmod A7'],
                [Sym('date'), '2026-10-06'], [Sym('rev'), '1'],
                [Sym('comment'), 1, 'ECG (AD8232), SpO2 (MAX30102), skin temperature (TMP36)'],
                [Sym('comment'), 2, 'All signal processing is in the FPGA; this board only powers and connects the sensors.']],
               [Sym('lib_symbols')] + list(self.lib_symbols.values())]
        doc += self.items
        doc.append([Sym('sheet_instances'), [Sym('path'), '/', [Sym('page'), '1']]])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as f:
            f.write(dump(doc) + '\n')


# ----------------------------------------------------------------------
# DRAW IT
# ----------------------------------------------------------------------

def main():
    S = Schematic()

    # ---------------- the Cmod A7, right-hand side ----------------
    S.place('ECG:CmodA7', 'U3', 'Cmod A7-35T', 228.6, 83.82, ref_offset=(0, -11))
    for num, net in [('1', 'BUZZER'), ('2', 'SCL'), ('3', 'SDA'), ('15', 'ECG'), ('16', 'TEMP')]:
        ex, ey = S.stub('U3', num)
        S.label(net, ex, ey, 180)
    vu_x, vu_y = S.stub('U3', '24')
    S.label('VU', vu_x, vu_y, 0)
    S.power('GND', *S.pin_xy('U3', '25'))

    # ---------------- AD8232 ----------------
    S.place('ECG:AD8232_Module', 'J1', 'AD8232 ECG breakout', 40.64, 55.88, ref_offset=(0, -22))
    S.power('+3V3', *S.pin_xy('J1', '2'))
    S.power('GND', *S.pin_xy('J1', '1'))
    ex, ey = S.stub('J1', '3'); S.label('ECG', ex, ey)
    for num in ('4', '5', '6'):
        S.no_connect(*S.pin_xy('J1', num))
    S.text('LO-, LO+, SDN not used (SDN is pulled up on the breakout)', 25.4, 76.0, 1.0)

    # ---------------- MAX30102 ----------------
    S.place('ECG:MAX30102_Module', 'J2', 'MAX30102 oximeter module', 40.64, 104.14, ref_offset=(0, -24))
    S.power('+3V3', *S.pin_xy('J2', '1'))
    S.power('GND', *S.pin_xy('J2', '7'))
    ex, ey = S.stub('J2', '2'); S.label('SCL', ex, ey)
    ex, ey = S.stub('J2', '3'); S.label('SDA', ex, ey)
    for num in ('4', '5', '6'):
        S.no_connect(*S.pin_xy('J2', num))
    S.text('I2C pull-ups are on the module: set its jumper to 3.3 V', 25.4, 126.0, 1.0)

    # ---------------- TMP36 + buffer ----------------
    S.place('ECG:TMP36_Leads', 'J3', 'TMP36 on leads', 40.64, 152.4, ref_offset=(0, -22))
    vx, vy = S.pin_xy('J3', '1')
    S.power('+3V3', vx, vy)
    S.power('GND', *S.pin_xy('J3', '3'))

    # decoupling right at the sensor supply: tap the +3V3 pin stub
    S.place('Device:C', 'C3', '100n', 58.42, 142.24, ref_offset=(5, 0),
            footprint='Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm')
    c3t = S.pin_xy('C3', '1'); c3b = S.pin_xy('C3', '2')
    S.wire([(vx, vy), (vx, vy - 2.54), (c3t[0], vy - 2.54), c3t])
    S.power('GND', *c3b)

    # the op-amp, unit A as a follower
    S.place('Amplifier_Operational:MCP6002-xP', 'U1', 'MCP6002', 99.06, 149.86, unit=1,
            footprint='Package_DIP:DIP-8_W7.62mm', ref_offset=(0, -10))
    inp = S.pin_xy('U1', '3'); inn = S.pin_xy('U1', '2'); out = S.pin_xy('U1', '1')
    vout = S.pin_xy('J3', '2')
    S.wire([vout, (vout[0] + 7.62, vout[1]), (vout[0] + 7.62, inp[1]), inp])
    S.wire([out, (out[0] + 2.54, out[1]), (out[0] + 2.54, out[1] + 7.62),
            (inn[0] - 2.54, out[1] + 7.62), (inn[0] - 2.54, inn[1]), inn])
    S.junction(out[0] + 2.54, out[1])
    S.wire([(out[0] + 2.54, out[1]), (out[0] + 7.62, out[1])])
    S.label('TEMP', out[0] + 7.62, out[1])
    S.text('Unity-gain buffer: the TMP36 can source only 50 uA,', 76.2, 166.0, 1.0)
    S.text('the Cmod input divider needs ~250 uA. Same volts, more current.', 76.2, 168.0, 1.0)

    # unit B unused: IN+ to GND, OUT to IN-
    S.place('Amplifier_Operational:MCP6002-xP', 'U1', 'MCP6002', 99.06, 185.42, unit=2,
            footprint='Package_DIP:DIP-8_W7.62mm', ref_offset=(0, -10))
    inn = S.pin_xy('U1', '6', 2); out = S.pin_xy('U1', '7', 2)
    gx, gy = S.stub('U1', '5', 2.54, unit=2); S.power('GND', gx, gy, rot=180)
    S.wire([out, (out[0] + 2.54, out[1]), (out[0] + 2.54, out[1] + 7.62),
            (inn[0] - 2.54, out[1] + 7.62), (inn[0] - 2.54, inn[1]), inn])
    S.text('Unused half tied off', 88.9, 198.0, 1.0)

    # unit C power, with decoupling
    S.place('Amplifier_Operational:MCP6002-xP', 'U1', 'MCP6002', 139.7, 149.86, unit=3,
            footprint='Package_DIP:DIP-8_W7.62mm', ref_offset=(6, 0))
    S.power('+3V3', *S.pin_xy('U1', '8', 3))
    S.power('GND', *S.pin_xy('U1', '4', 3))
    S.place('Device:C', 'C4', '100n', 152.4, 149.86, ref_offset=(5, 0),
            footprint='Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm')
    S.power('+3V3', *S.pin_xy('C4', '1'))
    S.power('GND', *S.pin_xy('C4', '2'))

    # ---------------- power: VU -> 3.3 V ----------------
    S.place('Regulator_Linear:MCP1700x-330xxTO', 'U2', 'MCP1700-3302', 111.76, 45.72, ref_offset=(0, 10))
    vi = S.pin_xy('U2', '2'); vo = S.pin_xy('U2', '3'); gnd = S.pin_xy('U2', '1')
    S.power('GND', gnd[0], gnd[1], rot=180)
    S.wire([vi, (vi[0] - 7.62, vi[1]), (vi[0] - 17.78, vi[1])])
    S.label('VU', vi[0] - 17.78, vi[1], 180)
    S.place('Device:C', 'C1', '1u', vi[0] - 7.62, 53.34, ref_offset=(5, 0),
            footprint='Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm')
    S.wire([(vi[0] - 7.62, vi[1]), S.pin_xy('C1', '1')])
    S.junction(vi[0] - 7.62, vi[1])
    S.power('GND', *S.pin_xy('C1', '2'))
    S.wire([(vi[0] - 7.62, vi[1]), (vi[0] - 7.62, vi[1] - 5.08)])
    S.power('PWR_FLAG', vi[0] - 7.62, vi[1] - 5.08)
    S.wire([vo, (vo[0] + 7.62, vo[1]), (vo[0] + 12.7, vo[1])])
    S.power('+3V3', vo[0] + 12.7, vo[1])
    S.place('Device:C', 'C2', '1u', vo[0] + 7.62, 53.34, ref_offset=(5, 0),
            footprint='Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm')
    S.wire([(vo[0] + 7.62, vo[1]), S.pin_xy('C2', '1')])
    S.junction(vo[0] + 7.62, vo[1])
    S.power('GND', *S.pin_xy('C2', '2'))
    S.text('VU is the USB 5 V after a Schottky diode on the Cmod: about 4.7 V.', 83.82, 66.0, 1.0)
    S.text('MCP1700 dropout is 0.18 V, so 3.3 V out is comfortable. Max 250 mA.', 83.82, 68.0, 1.0)

    # a PWR_FLAG on GND so ERC knows it is driven
    S.power('PWR_FLAG', 157.48, 45.72)
    S.wire([(157.48, 45.72), (157.48, 50.8)])
    S.power('GND', 157.48, 50.8)

    # ---------------- buzzer ----------------
    S.place('Device:R', 'R1', '150', 165.1, 109.22, rot=90, ref_offset=(0, -4), value_offset=(0, 4),
            footprint='Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal')
    S.place('Device:Buzzer', 'BZ1', 'passive buzzer', 182.88, 111.76, ref_offset=(0, -9),
            footprint='Buzzer_Beeper:Buzzer_12x9.5RM7.6')
    r_a = S.pin_xy('R1', '1'); r_b = S.pin_xy('R1', '2')
    bz_p = S.pin_xy('BZ1', '1')
    lo, hi = (r_a, r_b) if r_a[0] < r_b[0] else (r_b, r_a)
    S.wire([(lo[0] - 7.62, lo[1]), lo])
    S.label('BUZZER', lo[0] - 7.62, lo[1], 180)
    S.wire([hi, (bz_p[0] - 2.54, hi[1]), (bz_p[0] - 2.54, bz_p[1]), bz_p])
    gx, gy = S.stub('BZ1', '2', 2.54); S.power('GND', gx, gy)
    S.text('Series resistor limits the FPGA pin current (LVCMOS33 ~12 mA).', 152.4, 124.0, 1.0)

    # ---------------- notes ----------------
    S.text('Signals to the Cmod A7 DIP pins:  BUZZER=1  SCL=2  SDA=3  ECG=15  TEMP=16   power: VU=24  GND=25', 25.4, 25.0, 1.4)
    S.text('ECG and TEMP are 0-3.3 V analogue inputs; the Cmod divides them to 0-1 V for the XADC (VAUX4, VAUX12).', 25.4, 28.0, 1.0)

    S.write(OUT)
    print('wrote', os.path.normpath(OUT))


if __name__ == '__main__':
    main()
