"""
Tiny s-expression reader/writer for KiCad files.

KiCad 7 stores schematics, symbols and boards as nested lists in
parentheses. This is just enough to read a symbol out of a library,
flatten an "extends" inheritance, and write it back out.
"""


class Sym(str):
    """A bare token (as opposed to a quoted string)."""
    __slots__ = ()


def parse(text):
    """Parse one or more s-expressions from text. Returns a list."""
    i, n = 0, len(text)
    stack = [[]]
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif c == '(':
            stack.append([])
            i += 1
        elif c == ')':
            node = stack.pop()
            stack[-1].append(node)
            i += 1
        elif c == '"':
            j = i + 1
            out = []
            while text[j] != '"':
                if text[j] == '\\':
                    out.append(text[j + 1])
                    j += 2
                else:
                    out.append(text[j])
                    j += 1
            stack[-1].append(''.join(out))
            i = j + 1
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in '()':
                j += 1
            stack[-1].append(Sym(text[i:j]))
            i = j
    return stack[0]


def dump(node, indent=0):
    """Write an s-expression back out, one list per line."""
    if isinstance(node, Sym):
        return str(node)
    if isinstance(node, str):
        return '"' + node.replace('\\', '\\\\').replace('"', '\\"') + '"'
    if isinstance(node, (int, float)):
        return repr(node)
    # a list
    if not node:
        return '()'
    parts = [dump(node[0])]
    simple = all(not isinstance(x, list) for x in node)
    if simple:
        return '(' + ' '.join(dump(x) for x in node) + ')'
    for x in node[1:]:
        if isinstance(x, list):
            parts.append('\n' + '  ' * (indent + 1) + dump(x, indent + 1))
        else:
            parts.append(' ' + dump(x))
    return '(' + ''.join(parts) + ')'


def find(node, key):
    """First child list whose head is `key`."""
    for x in node:
        if isinstance(x, list) and x and x[0] == key:
            return x
    return None


def find_all(node, key):
    return [x for x in node if isinstance(x, list) and x and x[0] == key]


def load_symbol(lib_path, name):
    """Return the symbol node `name` from a .kicad_sym file."""
    with open(lib_path) as f:
        tree = parse(f.read())[0]
    for s in find_all(tree, 'symbol'):
        if s[1] == name:
            return s
    raise KeyError(f'{name} not in {lib_path}')


def flatten_symbol(lib_path, name):
    """
    Return a symbol with any `extends` resolved: the parent's body
    with the child's name and the child's property overrides, which is
    how KiCad stores derived symbols inside a schematic.
    """
    sym = load_symbol(lib_path, name)
    ext = find(sym, 'extends')
    if not ext:
        return sym
    parent = flatten_symbol(lib_path, ext[1])
    out = [Sym('symbol'), name]
    child_props = {p[1]: p for p in find_all(sym, 'property')}
    for x in parent[2:]:
        if isinstance(x, list) and x and x[0] == 'property':
            out.append(child_props.get(x[1], x))
        elif isinstance(x, list) and x and x[0] == 'symbol':
            # sub-unit names carry the parent name: rename
            sub = list(x)
            sub[1] = name + x[1][len(parent[1]):]
            out.append(sub)
        else:
            out.append(x)
    # child-only properties (e.g. a datasheet) are appended
    have = {p[1] for p in find_all(out, 'property')}
    for pname, p in child_props.items():
        if pname not in have:
            out.insert(2, p)
    return out


def symbol_pins(sym):
    """[(number, name, x, y, angle)] for every pin in every sub-unit."""
    pins = []
    for sub in find_all(sym, 'symbol'):
        for p in find_all(sub, 'pin'):
            at = find(p, 'at')
            num = find(p, 'number')[1]
            nm = find(p, 'name')[1]
            unit = int(sub[1].rsplit('_', 2)[1])
            pins.append((num, nm, float(at[1]), float(at[2]),
                         float(at[3]) if len(at) > 3 else 0.0, unit))
    return pins
