#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Patches and checks the OpenWRT One DTS for SolarMatrix.

  openwrt-one-dts.py patch DTS TAG     edit DTS in place, only if every check passes
  openwrt-one-dts.py check-source DTS  check an already patched DTS
  openwrt-one-dts.py check-dtb DTB     check the NOR table of a compiled DTB

The source edits:

  - userspace SPI for the CAN module: UART2 disabled (its pins collide with
    SPI1), the mikrobus-reset gpio-export dropped (the controller drives the
    reset line itself), and a spidev@0 node under &spi1. It is declared
    silabs,si3210 because the kernel spidev driver binds only to the parts in
    spidev_dt_ids and rejects a generic "spidev" compatible (OpenWRT PR #17399).
  - the NOR factory partition split in two: factory shrinks to
    <0x40000 0xa0000> and stays read-only; factory-secrets <0xe0000 0x20000>
    (the erased tail of the old factory) is added, writable, before fip-nor.

The NOR table is then checked as a whole, because the kernel's ofpart parser
treats every child of the fixed-partitions node that has a reg as an MTD
partition, whatever it is called. The source check refuses anything that
could change the table from outside the &spi2 block (/delete-*/ directives,
&{/path} references, overrides of labels defined in it). It is only the early
failure: dtc resolves includes and overrides the source check cannot see, so
the build checks the compiled DTB with the same table rules.
"""
import re
import subprocess
import sys
from pathlib import Path

# The NOR layout this firmware and the provisioning tool are built for.
NOR_LAYOUT = [
    ("bl2-nor", 0x0, 0x40000),
    ("factory", 0x40000, 0xa0000),
    ("factory-secrets", 0xe0000, 0x20000),
    ("fip-nor", 0x100000, 0x80000),
    ("recovery", 0x180000, 0xc80000),
]
# Cells the kernel reads MACs and WiFi calibration from, by unit address.
FACTORY_CELLS = ("eeprom@0", "macaddr@4", "macaddr@24")


def parse_node(s, i):
    """Parses the DTS node body that starts just after its '{' at s[i].

    Returns (node, index just past the closing '};'), where node is
    {"props": {name: raw value, or True for a flag}, "children": [(name, node)]}.
    """
    props, children = {}, []
    while True:
        i = re.compile(r"\s*").match(s, i).end()
        if i >= len(s):
            raise ValueError("unterminated node")
        if s[i] == "}":
            end = re.compile(r"\}\s*;").match(s, i)
            if not end:
                raise ValueError("node not closed with '};'")
            return {"props": props, "children": children}, end.end()
        j = i
        while j < len(s) and s[j] not in "{;}":
            if s[j] == '"':
                j += 1
                while j < len(s) and s[j] != '"':
                    j += 2 if s[j] == "\\" else 1
            j += 1
        if j >= len(s) or s[j] == "}":
            raise ValueError("statement not terminated: %r" % s[i:j][:40])
        head = s[i:j].strip()
        if s[j] == "{":
            child, i = parse_node(s, j + 1)
            children.append((head.split(":")[-1].strip(), child))
        else:
            name, eq, value = head.partition("=")
            props[name.strip()] = value.strip() if eq else True
            i = j + 1


def child(node, name):
    return next((c for n, c in node["children"] if n == name), None)


def num(token):
    return int(token, 16) if token.lower().startswith("0x") else int(token)


def reg_of(node):
    m = re.fullmatch(r"<\s*(\S+)\s+(\S+)\s*>", str(node["props"].get("reg", "")))
    if not m:
        return None
    try:
        return num(m.group(1)), num(m.group(2))
    except ValueError:
        return None


def unit_address(name):
    try:
        return num("0x" + name.split("@", 1)[1]) if "@" in name else None
    except ValueError:
        return None


def compatible(node):
    return str(node["props"].get("compatible", "")).strip()


def table_problems(table):
    """Checks a fixed-partitions node. Every child is a partition."""
    problems, parts = [], []
    layout = set(NOR_LAYOUT)
    # Another parser (a different compatible) would read the children its own
    # way, so none of the checks below would say anything about the result.
    if compatible(table) != '"fixed-partitions"':
        problems.append('NOR partitions node is %s, expected "fixed-partitions"'
                        % (compatible(table) or "without a compatible"))
    for name, node in table["children"]:
        label = str(node["props"].get("label", "")).strip('"')
        reg = reg_of(node)
        if reg is None:
            problems.append("NOR child %s has no parsable reg" % name)
            continue
        if unit_address(name) != reg[0]:
            problems.append("NOR %s (%s) unit address does not match its reg "
                            "offset 0x%x" % (name, label, reg[0]))
        if (label, reg[0], reg[1]) not in layout:
            problems.append("NOR %s (%s) 0x%x+0x%x is not in the NOR layout"
                            % (name, label, reg[0], reg[1]))
        parts.append((label, reg[0], reg[1], node))
    parts.sort(key=lambda p: p[1])

    labels = [p[0] for p in parts]
    for label in sorted(set(labels)):
        if labels.count(label) > 1:
            problems.append("NOR partition %s appears %d times"
                            % (label, labels.count(label)))
    for a, b in zip(parts, parts[1:]):
        a_end = a[1] + a[2]
        if a_end > b[1]:
            problems.append("NOR partition %s (0x%x-0x%x) overlaps %s (starts 0x%x)"
                            % (a[0], a[1], a_end - 1, b[0], b[1]))
        elif a_end < b[1]:
            problems.append("NOR gap between %s (ends 0x%x) and %s (starts 0x%x)"
                            % (a[0], a_end - 1, b[0], b[1]))
    if [p[:3] for p in parts] != NOR_LAYOUT:
        def fmt(ps):
            return ", ".join("%s 0x%x+0x%x" % p[:3] for p in ps)
        problems.append("NOR partitions are [%s], expected [%s]"
                        % (fmt(parts), fmt(NOR_LAYOUT)))

    by_label = {p[0]: p for p in parts}
    factory = by_label.get("factory")
    if factory:
        if "read-only" not in factory[3]["props"]:
            problems.append("factory is not read-only; its MACs and WiFi "
                            "calibration would be writable")
        cells = child(factory[3], "nvmem-layout") or {"props": {}, "children": []}
        if compatible(cells) != '"fixed-layout"':
            problems.append('factory nvmem-layout is %s, expected "fixed-layout"'
                            % (compatible(cells) or "missing or without a compatible"))
        for cell_name in FACTORY_CELLS:
            cell = child(cells, cell_name)
            reg = cell and reg_of(cell)
            if not cell:
                problems.append("factory nvmem cell %s is missing" % cell_name)
            elif (not reg or reg[0] != unit_address(cell_name)
                  or reg[0] + reg[1] > factory[2]):
                problems.append("factory nvmem cell %s is not at its unit "
                                "address inside factory" % cell_name)
    secrets = by_label.get("factory-secrets")
    if secrets and "read-only" in secrets[3]["props"]:
        problems.append("factory-secrets is read-only; the provisioning tool "
                        "could not write it")
    return problems


def strip_comments(text):
    return re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)


def source_problems(text):
    """Checks the NOR table of a patched source DTS under &spi2 flash@0."""
    text = strip_comments(text)
    refs = list(re.finditer(r"&spi2\s*\{", text))
    if len(refs) != 1:
        return ["expected one &spi2 node, found %d" % len(refs)]
    try:
        spi2, end = parse_node(text, refs[0].end())
    except ValueError as e:
        return ["cannot parse &spi2: %s" % e]
    block = text[refs[0].start():end]
    problems = []
    for directive in re.findall(r"/delete-(?:property|node)/\s*[^;]*", block):
        problems.append("&spi2 contains %s; the NOR table must be plain" % directive)
    for path_ref in re.findall(r"&\{[^}]*\}", text):
        problems.append("path reference %s is not allowed: it could change "
                        "the NOR table unseen" % path_ref)
    for label in re.findall(r"([A-Za-z_]\w*)\s*:\s*[\w@,.+-]+\s*\{", block):
        if re.search(r"&%s\s*\{" % re.escape(label), text):
            problems.append("&%s overrides a node of the NOR table" % label)
    _, nor_problems = nor_flash_problems(spi2, "&spi2")
    return problems + nor_problems


def walk(node, path="/"):
    yield path, node
    for name, sub in node["children"]:
        yield from walk(sub, path.rstrip("/") + "/" + name)


# The SoC's SPI controllers, from mt7981b.dtsi as completed by
# target/linux/mediatek/patches-6.12/117-complete-mt7981b-dtsi.patch:
# spi2 = spi@11009000 carries the NOR, spi0 = spi@1100a000 the NAND, and
# spi1 = spi@1100b000 the mikroBUS spidev.
SPI2_PATH, SPI2_ADDR = "/soc/spi@11009000", 0x11009000
SPI0_PATH = "/soc/spi@1100a000"


def available(node):
    # As of_device_is_available(): no status, "okay" or "ok".
    return str(node["props"].get("status", '"okay"')).strip() in ('"okay"', '"ok"')


def cells(node, prop):
    """All 32-bit cells of a <...> property, or None."""
    value = node["props"].get(prop)
    if not isinstance(value, str) or not value.startswith("<"):
        return None
    try:
        return [num(t) for t in re.findall(r"[^\s<>,]+", value)]
    except ValueError:
        return None


def cs0_flash(ctrl):
    """The enabled children of an SPI controller at chip select 0."""
    return [(n, c) for n, c in ctrl["children"]
            if available(c) and (cells(c, "reg") or [None])[0] == 0]


def nor_flash_problems(ctrl, ctrl_path):
    """Checks the NOR on controller ctrl: its one enabled CS0 child (by reg,
    not by node name) and that child's partition table.

    Returns (path of the checked table or None, problems).
    """
    problems, table_path = [], None
    if not available(ctrl):
        problems.append("%s is disabled" % ctrl_path)
    flashes = cs0_flash(ctrl)
    chosen = None
    if len(flashes) != 1:
        problems.append("%s has %s enabled CS0 flash (reg = <0>)"
                        % (ctrl_path, "no" if not flashes else "more than one"))
    else:
        name, chosen = flashes[0]
        table = child(chosen, "partitions")
        if not table:
            problems.append("%s/%s has no partitions node" % (ctrl_path, name))
        else:
            table_path = "%s/%s/partitions" % (ctrl_path, name)
            problems += table_problems(table)
    for name, node in ctrl["children"]:
        if node is not chosen and child(node, "partitions"):
            problems.append("%s/%s has a partitions node but is not the enabled "
                            "CS0 flash" % (ctrl_path, name))
    return table_path, problems


def dtb_problems(dtb):
    """Checks the NOR table in a compiled DTB, as the kernel will see it.

    The controller is found at its fixed path, never through __symbols__:
    the source can write any __symbols__ node it likes.
    """
    try:
        text = subprocess.run(["dtc", "-q", "-I", "dtb", "-O", "dts", "-o", "-", dtb],
                              check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        return ["cannot decompile %s: %s" % (dtb, e)]
    root = re.search(r"^/\s*\{", text, flags=re.M)
    if not root:
        return ["%s has no root node" % dtb]
    try:
        tree, _ = parse_node(text, root.end())
    except ValueError as e:
        return ["cannot parse the decompiled %s: %s" % (dtb, e)]
    nodes = dict(walk(tree))

    problems, allowed = [], set()
    unit = SPI2_PATH.rsplit("/", 1)[1]
    named = [p for p in nodes if p.rsplit("/", 1)[-1] == unit]
    if len(named) != 1:
        problems.append("expected one %s node (spi2), found %d%s"
                        % (unit, len(named), (": " + ", ".join(named)) if named else ""))
    elif named[0] != SPI2_PATH:
        problems.append("spi2 is at %s, expected %s" % (named[0], SPI2_PATH))
    else:
        ctrl = nodes[SPI2_PATH]
        parent = nodes[SPI2_PATH.rsplit("/", 1)[0]]
        n_addr = (cells(parent, "#address-cells") or [2])[0]
        reg = cells(ctrl, "reg") or []
        addr = 0
        for cell in reg[:n_addr]:
            addr = (addr << 32) | cell
        if len(reg) < n_addr or addr != SPI2_ADDR:
            problems.append("%s reg starts at %s, expected 0x%x"
                            % (SPI2_PATH, "0x%x" % addr if reg else "nothing", SPI2_ADDR))
        table_path, nor_problems = nor_flash_problems(ctrl, SPI2_PATH)
        problems += nor_problems
        allowed.add(table_path)

    symbols = child(tree, "__symbols__")
    target = symbols and symbols["props"].get("spi2")
    if target and str(target).strip('"') != SPI2_PATH:
        problems.append('__symbols__/spi2 is %s, expected "%s"' % (target, SPI2_PATH))

    # The NAND table on spi0's CS0 flash is the only other one allowed.
    nand_ctrl = nodes.get(SPI0_PATH)
    nand = cs0_flash(nand_ctrl) if nand_ctrl else []
    if len(nand) == 1 and child(nand[0][1], "partitions"):
        allowed.add("%s/%s/partitions" % (SPI0_PATH, nand[0][0]))

    # Any other partition table could be the one that binds, whatever it holds.
    for path, node in walk(tree):
        is_table = ('"fixed-partitions"' in compatible(node)
                    or path.rsplit("/", 1)[-1] == "partitions")
        if is_table and path not in allowed:
            problems.append("%s is a partition table outside the NOR and NAND "
                            "flashes" % path)
    return problems


def patch(path, tag):
    text = path.read_text()

    text = re.sub(r'(&uart2\s*\{[^{}]*?status\s*=\s*")okay(";)',
                  r'\1disabled\2', text, flags=re.S)
    text = re.sub(r'(gpio-export\s*\{[^{}]*)gpio-0\s*\{[^{}]*?\};',
                  r'\1', text, flags=re.S)
    text = re.sub(r'(&spi1\s*\{[^}]*)(status\s*=\s*"okay";\s*)(\};)',
                  r'''\1\2
	spidev@0 {
		compatible = "silabs,si3210";
		reg = <0>;
		#address-cells = <1>;
		#size-cells = <0>;
		spi-max-frequency = <52000000>;
	};
\3''', text, flags=re.S)

    # factory keeps its MACs and WiFi calibration read-only in 0x0-0x9ffff of
    # the partition; the free, erased tail (0xa0000-0xbffff, measured) becomes
    # factory-secrets, written once by the provisioning tool. The nvmem cells
    # all sit in the first 0x1000 bytes, so shrinking moves none of them.
    text, n_factory = re.subn(
        r'(label\s*=\s*"factory";\s*reg\s*=\s*<)0x40000 0xc0000(>;)',
        r'\g<1>0x40000 0xa0000\2', text)
    text, n_secrets = re.subn(
        r'(\n(\t+)partition@100000 \{\n\t+label = "fip-nor";)',
        lambda m: ('\n%spartition@e0000 {\n%s\tlabel = "factory-secrets";\n'
                   '%s\treg = <0xe0000 0x20000>;\n%s};\n' % ((m.group(2),) * 4))
                  + m.group(1),
        text, count=1)

    problems = []
    if "spidev@0" not in text:
        problems.append("spidev@0 node was not added under &spi1")
    if "silabs,si3210" not in text:
        problems.append("spidev compatible string is missing")
    if "mikrobus-reset" in text:
        problems.append("mikrobus-reset gpio-export was not removed")
    if re.search(r'&uart2\s*\{[^{}]*?status\s*=\s*"okay"', text, flags=re.S):
        problems.append("uart2 is still enabled and will collide with SPI1")
    if n_factory != 1:
        problems.append("factory partition was not shrunk to 0x40000 0xa0000")
    if n_secrets != 1 or 'label = "factory-secrets"' not in text:
        problems.append("factory-secrets partition was not added before fip-nor")
    problems += source_problems(text)
    if problems:
        fail("DTS patch did not apply cleanly to %s" % tag, problems,
             "The upstream DTS likely changed shape in this release.\n"
             "  %s was left unmodified." % path)

    path.write_text(text)
    print("Verified: spidev@0 added, mikrobus-reset removed, uart2 disabled, "
          "factory split into factory + factory-secrets, NOR table as expected")


def fail(what, problems, hint=None):
    sys.stderr.write("ERROR: %s:\n" % what)
    for problem in problems:
        sys.stderr.write("  - %s\n" % problem)
    if hint:
        sys.stderr.write("  %s\n" % hint)
    raise SystemExit(1)


def main(argv):
    if len(argv) == 3 and argv[0] == "patch":
        patch(Path(argv[1]), argv[2])
    elif len(argv) == 2 and argv[0] == "check-source":
        problems = source_problems(Path(argv[1]).read_text())
        if problems:
            fail("NOR partition table in %s is wrong" % argv[1], problems)
        print("Verified: NOR partition table in %s" % argv[1])
    elif len(argv) == 2 and argv[0] == "check-dtb":
        problems = dtb_problems(argv[1])
        if problems:
            fail("NOR partition table in the compiled %s is wrong" % argv[1], problems)
        print("Verified: NOR partition table in the compiled %s" % argv[1])
    else:
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        raise SystemExit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
