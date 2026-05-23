#!/usr/bin/env python3
"""
decomp.py — decomp-assisted query tool for hook authoring.

Resolves anything in the matched OoT ntsc-1.0 decomp build against the actual
disassembly + source. Goal: short-circuit the manual "where is this function,
what does it do, what's its struct" loop that eats most of every PR.

Subcommands:
  addr 0xRAM [-d]        RAM address → function + offset + source file [+ disasm]
  sym NAME [-d]          symbol → address + size + source file [+ disasm]
  actor ActorOrDir       overlay actor → all its functions with addresses + source
  counters TARGET        scan C source for raw frame-counter patterns
  xref SYM               find all callers (jal/j) of a function in the matched ELF

Inputs (relative to repo root):
  oot/build/ntsc-1.0/oot-ntsc-1.0.elf      (matched ELF)
  oot/build/ntsc-1.0/oot-ntsc-1.0.map      (link map)
  oot/src/...                              (decomp C/H source)
  tools/mips-toolchain/bin/...             (binutils)

Notes
- The decomp ELF is vanilla OoT NTSC 1.0. Overlays in Patcher64+ Redux are
  byte-identical, so overlay addresses resolve 1:1. A handful of code-segment
  functions are patcher-modified — addresses in the 0x800110A0+ code segment
  resolve to the vanilla layout; spot-check before relying on them.
- Source line numbers are NOT available (the matched build emits .mdebug, not
  DWARF). Function-level resolution + source-file path is what you get.
"""
import argparse
import bisect
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ELF = REPO / "oot/build/ntsc-1.0/oot-ntsc-1.0.elf"
MAP = REPO / "oot/build/ntsc-1.0/oot-ntsc-1.0.map"
DECOMP_SRC = REPO / "oot/src"
TOOLCHAIN = REPO / "tools/mips-toolchain/bin"
NM = TOOLCHAIN / "mips-linux-gnu-nm"
OBJDUMP = TOOLCHAIN / "mips-linux-gnu-objdump"


def die(msg):
    print(f"decomp: {msg}", file=sys.stderr)
    sys.exit(1)


def need(path, what):
    if not path.exists():
        die(f"{what} missing: {path.relative_to(REPO) if path.is_absolute() else path}\n"
            f"        build the decomp first (cd oot && make) or rebuild the mips toolchain.")


@dataclass
class Sym:
    addr: int
    size: int
    kind: str
    name: str


_SYMS = None
def load_syms():
    global _SYMS
    if _SYMS is not None:
        return _SYMS
    need(ELF, "matched decomp ELF")
    need(NM, "mips binutils nm")
    out = subprocess.check_output(
        [str(NM), "-nS", "--defined-only", str(ELF)], text=True
    )
    syms = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            addr_s, kind, name = parts
            size = 0
        elif len(parts) == 4:
            addr_s, size_s, kind, name = parts
            try: size = int(size_s, 16)
            except ValueError: size = 0
        else:
            continue
        try: addr = int(addr_s, 16)
        except ValueError: continue
        syms.append(Sym(addr, size, kind, name))
    syms.sort(key=lambda s: s.addr)
    _SYMS = syms
    return syms


def sym_for_addr(addr):
    syms = load_syms()
    addrs = [s.addr for s in syms]
    i = bisect.bisect_right(addrs, addr) - 1
    while i >= 0:
        s = syms[i]
        if s.kind in "TtWw" and (s.size == 0 or addr < s.addr + s.size):
            return s, addr - s.addr
        if s.kind not in "Aa":  # absolute syms shouldn't gate the search
            i -= 1
            continue
        i -= 1
    return None, None


_RANGES = None  # sorted list of (start, end, file_path_from_map)
def load_map_ranges():
    """Walk the .map and record every (start, end, source_file) text/data section."""
    global _RANGES
    if _RANGES is not None:
        return _RANGES
    need(MAP, "matched decomp map file")
    text = MAP.read_text()
    ranges = []
    # Section lines look like:
    #   .text         0xADDR  0xSIZE   build/.../foo.o
    #   .text         0xADDR  0xSIZE   build/.../segments/ovl_X.plf
    # Size 0 sections are skipped (they'd add false-positive zero-width hits).
    sec_pat = re.compile(
        r"^\s+\.\S+\s+(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)\s+(\S+)\s*$"
    )
    for line in text.splitlines():
        m = sec_pat.match(line)
        if not m:
            continue
        path = m.group(3)
        # Path must look like a build artifact (.o, .oa, .plf, .a, etc.)
        if "/" not in path and "\\" not in path:
            continue
        if not re.search(r"\.(o[a-z]?|plf|a)$", path):
            continue
        lo = int(m.group(1), 16)
        size = int(m.group(2), 16)
        if size == 0:
            continue
        ranges.append((lo, lo + size, path))
    ranges.sort()
    _RANGES = ranges
    return ranges


def map_file_for_addr(addr):
    ranges = load_map_ranges()
    lo_list = [r[0] for r in ranges]
    i = bisect.bisect_right(lo_list, addr) - 1
    if i < 0:
        return None
    start, end, path = ranges[i]
    return path if start <= addr < end else None


def src_for_map_path(path):
    """build/ntsc-1.0/{src/foo/bar.o, segments/ovl_X.plf} → oot/src/.../source file."""
    if not path:
        return None
    # Source .o → matching .c/.s next to the .o's source.
    m = re.match(r"build/ntsc-[\d.]+/(.+)\.o[a-z]?$", path)
    if m:
        rel = m.group(1)
        for ext in (".c", ".s"):
            p = REPO / "oot" / (rel + ext)
            if p.exists():
                return p
        return None
    # Overlay .plf → look up the overlay's source directory.
    m = re.match(r"build/ntsc-[\d.]+/segments/(ovl_\w+)\.plf$", path)
    if m:
        ovl = m.group(1)
        for parent in ("overlays/actors", "overlays/effects",
                       "overlays/gamestates", "overlays/kaleido_scope",
                       "overlays/misc"):
            d = DECOMP_SRC / parent / ovl
            if d.is_dir():
                src = next(iter(d.glob("z_*.c")), None) or next(iter(d.glob("z_*.s")), None)
                if src:
                    return src
        return None
    return None


def src_for_sym(sym):
    return src_for_map_path(map_file_for_addr(sym.addr))


def disasm(start, end):
    need(OBJDUMP, "mips binutils objdump")
    return subprocess.check_output(
        [
            str(OBJDUMP), "-d", "-M", "no-aliases",
            f"--start-address=0x{start:x}",
            f"--stop-address=0x{end:x}",
            str(ELF),
        ],
        text=True,
    )


def cmd_addr(args):
    addr = int(args.addr, 0)
    s, off = sym_for_addr(addr)
    if not s:
        die(f"no text symbol contains 0x{addr:08x}")
    src = src_for_sym(s)
    print(f"0x{addr:08X}  {s.name}+0x{off:x}  (size 0x{s.size:x})")
    if src:
        print(f"  source: {src.relative_to(REPO)}")
    else:
        path = map_file_for_addr(addr)
        if path:
            print(f"  segment: {path} (no .c source found)")
    if args.d:
        end = s.addr + (s.size or 0x80)
        print()
        sys.stdout.write(disasm(s.addr, end))


def cmd_sym(args):
    syms = load_syms()
    hits = [s for s in syms if s.name == args.name]
    if not hits and args.partial:
        rx = re.compile(re.escape(args.name), re.IGNORECASE)
        hits = [s for s in syms if rx.search(s.name)]
    if not hits:
        die(f"no symbol matches: {args.name}")
    for s in hits:
        src = src_for_sym(s)
        print(f"{s.name}  @ 0x{s.addr:08X}  size 0x{s.size:x}  [{s.kind}]")
        if src:
            print(f"  source: {src.relative_to(REPO)}")
    if args.d and len(hits) == 1 and hits[0].size:
        print()
        sys.stdout.write(disasm(hits[0].addr, hits[0].addr + hits[0].size))


_CAMEL_BREAK = re.compile(r"(?<!^)(?=[A-Z])")
def to_snake(name):
    return _CAMEL_BREAK.sub("_", name)


def find_actor_dir(name):
    """Resolve BgHidanSyoku / Bg_Hidan_Syoku / bg_hidan_syoku → overlay dir."""
    p = Path(name)
    if p.is_dir():
        return p.resolve()
    snake = to_snake(name)
    candidates = [
        DECOMP_SRC / "overlays/actors" / f"ovl_{snake}",
        DECOMP_SRC / "overlays/actors" / f"ovl_{name}",
        DECOMP_SRC / "overlays/effects" / f"ovl_{snake}",
        DECOMP_SRC / "overlays/gamestates" / f"ovl_{snake}",
        DECOMP_SRC / "overlays/kaleido_scope" / f"ovl_{snake}",
        DECOMP_SRC / "overlays/misc" / f"ovl_{snake}",
    ]
    for c in candidates:
        if c.exists():
            return c
    # Loose glob fallback
    needle = snake.lower()
    for d in DECOMP_SRC.glob("overlays/*/ovl_*"):
        if d.is_dir() and needle in d.name.lower():
            return d
    return None


def cmd_actor(args):
    d = find_actor_dir(args.actor)
    if not d:
        die(f"no overlay directory matches: {args.actor}")
    rel = d.relative_to(REPO) if d.is_relative_to(REPO) else d
    print(f"actor dir: {rel}")
    cfile = next((f for f in d.glob("z_*.c")), None)
    hfile = next((f for f in d.glob("z_*.h")), None)
    if cfile: print(f"  c: {cfile.relative_to(REPO)}")
    if hfile: print(f"  h: {hfile.relative_to(REPO)}")
    syms = load_syms()
    print("\nfunctions (text):")
    needle_dir = d.name              # e.g. ovl_Bg_Hidan_Syoku
    needle_plf = f"{d.name}.plf"
    rows = []
    for s in syms:
        if s.kind not in "Tt":
            continue
        if s.size == 0:                                  # segment-boundary labels
            continue
        if s.name.startswith("_ovl_") or "Segment" in s.name:
            continue
        path = map_file_for_addr(s.addr) or ""
        if needle_plf in path or f"/{needle_dir}/" in path:
            rows.append(s)
    for s in rows:
        print(f"  0x{s.addr:08X}  size 0x{s.size:04x}  {s.name}")
    if not rows:
        print("  (no symbols matched — overlay name normalisation may be off; try -d <path>)")
    if hfile:
        print("\nstruct (from header — verify offsets vs ELF before using):")
        emit_struct(hfile)


def emit_struct(hfile):
    """Print struct fields with the /* 0xNNN */ offset comments from the decomp .h."""
    txt = hfile.read_text()
    # Look for typedef struct ... { ... } NAME;
    m = re.search(r"typedef\s+struct\s+\w*\s*\{(.+?)\}\s*(\w+)\s*;",
                  txt, re.DOTALL)
    if not m:
        return
    body, struct_name = m.group(1), m.group(2)
    print(f"  {struct_name} {{")
    for line in body.splitlines():
        s = line.strip()
        if not s or s.startswith("//"):
            continue
        print(f"    {s}")
    print("  }")


# Raw frame-counter patterns. Conservative — only flag struct-field touches,
# not local-variable counters (those are scratch and don't persist across frames).
COUNTERS = [
    (re.compile(r"\b(this->\w+(?:\.\w+)*)\s*--"),                        "post-decrement"),
    (re.compile(r"--\s*(this->\w+(?:\.\w+)*)"),                          "pre-decrement"),
    (re.compile(r"\b(this->\w+(?:\.\w+)*)\s*-=\s*1\b"),                  "subtract 1"),
    (re.compile(r"\b(this->\w+(?:\.\w+)*)\s*\+\+"),                      "post-increment"),
    (re.compile(r"\+\+\s*(this->\w+(?:\.\w+)*)"),                        "pre-increment"),
    (re.compile(r"\b(this->\w+(?:\.\w+)*)\s*\+=\s*1\b"),                 "add 1"),
    (re.compile(r"\bMath_StepToF\s*\(\s*&(this->\w+(?:\.\w+)*)\s*,"),    "Math_StepToF"),
    (re.compile(r"\bMath_SmoothStepToF\s*\(\s*&(this->\w+(?:\.\w+)*)\s*,"), "Math_SmoothStepToF"),
    (re.compile(r"\bMath_ApproachF\s*\(\s*&(this->\w+(?:\.\w+)*)\s*,"),   "Math_ApproachF"),
]


def cmd_counters(args):
    target = args.target
    candidates = []
    p = Path(target)
    if p.exists():
        if p.is_dir():
            candidates = sorted(p.glob("z_*.c"))
        else:
            candidates = [p]
    else:
        d = find_actor_dir(target)
        if not d:
            die(f"can't resolve: {target}")
        candidates = sorted(d.glob("z_*.c"))
    if not candidates:
        die(f"no z_*.c source to scan for: {target}")
    for cfile in candidates:
        scan_counters_in(cfile)


def scan_counters_in(cfile):
    rel = cfile.relative_to(REPO) if cfile.is_relative_to(REPO) else cfile
    print(f"\nscanning: {rel}")
    src = cfile.read_text()
    # Strip line + block comments to avoid false positives inside doc comments
    src_nocom = re.sub(r"//[^\n]*", "", src)
    src_nocom = re.sub(r"/\*.*?\*/", "", src_nocom, flags=re.DOTALL)
    # Track field → hits across all patterns
    by_field = {}
    for ln_no, line in enumerate(src_nocom.splitlines(), 1):
        for pat, kind in COUNTERS:
            for m in pat.finditer(line):
                field = m.group(1)
                by_field.setdefault(field, []).append((ln_no, kind, line.strip()))
    if not by_field:
        print("  (no raw counter touches found)")
        return
    for field in sorted(by_field):
        occ = by_field[field]
        print(f"\n  {field}  ({len(occ)} touch{'es' if len(occ)!=1 else ''})")
        for ln_no, kind, ln in occ:
            print(f"    L{ln_no:>5}  [{kind:<18}]  {ln}")
    print("\nclassify against work/FIX_PATTERNS.md:")
    print("  - only `== 0` / `!= 0` / `if (field)` reads          → seed-mod  (Pattern A/B/C/D)")
    print("  - `< N` / `% N` / `>> N` / equality vs nonzero       → tick-mod  (Pattern E/F)")
    print("  - Math_StepToF / Math_SmoothStepToF / Math_ApproachF → step-scale (Pattern G)")


def cmd_xref(args):
    """Find every jal/j to a function in the matched ELF."""
    target = args.sym
    syms = load_syms()
    hits = [s for s in syms if s.name == target]
    if not hits:
        die(f"symbol not found: {target}")
    s = hits[0]
    need(OBJDUMP, "mips binutils objdump")
    out = subprocess.check_output(
        [str(OBJDUMP), "-d", "-M", "no-aliases", str(ELF)], text=True
    )
    # objdump line example: "808dd728:\t0c20ef45 \tjal\t0x8043bd14"
    addr_hex_short = f"{s.addr:08x}"
    print(f"callers of {target} @ 0x{s.addr:08X}:")
    pat = re.compile(
        rf"^\s*([0-9a-f]+):\s+\S+\s+(jal|j)\s+(?:0x)?({addr_hex_short})\b"
    )
    found = 0
    for line in out.splitlines():
        m = pat.match(line)
        if m:
            caller_addr = int(m.group(1), 16)
            csym, off = sym_for_addr(caller_addr)
            cname = f"{csym.name}+0x{off:x}" if csym else "?"
            src = src_for_sym(csym) if csym else None
            tail = f"  ({src.relative_to(REPO)})" if src else ""
            print(f"  0x{caller_addr:08X}  {m.group(2):<3}  {cname}{tail}")
            found += 1
    if not found:
        print("  (no callers)")


def main():
    ap = argparse.ArgumentParser(prog="decomp",
        description="decomp-assisted query tool (see top of file for details)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("addr", help="RAM address → function + source")
    a.add_argument("addr", help="hex RAM address, e.g. 0x808dd728")
    a.add_argument("-d", action="store_true", help="also print disasm of the containing function")
    a.set_defaults(fn=cmd_addr)

    a = sub.add_parser("sym", help="symbol → address + source")
    a.add_argument("name")
    a.add_argument("-d", action="store_true", help="also print disasm")
    a.add_argument("--partial", action="store_true", help="substring match instead of exact")
    a.set_defaults(fn=cmd_sym)

    a = sub.add_parser("actor", help="overlay actor → functions + source + struct")
    a.add_argument("actor", help="actor name (BgHidanSyoku) or overlay dir path")
    a.set_defaults(fn=cmd_actor)

    a = sub.add_parser("counters", help="scan source for raw frame-counter patterns")
    a.add_argument("target", help="actor name, C file path, or directory")
    a.set_defaults(fn=cmd_counters)

    a = sub.add_parser("xref", help="find callers of a function in the matched ELF")
    a.add_argument("sym", help="symbol name")
    a.set_defaults(fn=cmd_xref)

    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
