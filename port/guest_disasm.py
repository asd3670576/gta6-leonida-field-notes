#!/usr/bin/env python3
r"""Disassemble a slice of the guest image (game_scarlett_master.exe) by RVA.

Reads only the PE section table (the game package is never written to), maps RVA -> file
offset, cuts the bytes and feeds them to llvm-mc's x86-64 disassembler in Intel syntax.

    python -X utf8 -s guest_disasm.py --rva 0x5925915 --len 48
    python -X utf8 -s guest_disasm.py --from 5925700 --to 5925a00
    python -X utf8 -s guest_disasm.py --rva 5925903 --len 16 --no-annotate

A bare number is read as hex, because that is how the runtime trace prints them
(`exe+0x5925915`); an explicit 0x prefix also works. The printed `exe+0x...` column is
the same RVA the trace names; the `(...)` column is that RVA with the image base
(0x140000000 for this exe, read from the PE header) added.

llvm-mc disassembles a slice as if it started at address 0, so every line is re-addressed
here, and the numeric relative call/jmp targets it prints are turned into `exe+0x...`.
"""
from __future__ import annotations

import argparse
import os
import re
import struct
import subprocess
import sys
import tempfile

DEFAULT_EXE = r"H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK\game_scarlett_master.exe"
DEFAULT_MC = (r"C:\Users\L.S\AppData\Local\miniforge3\envs\llvm-tools\Library\bin"
              r"\llvm-mc.exe")

# llvm-mc --show-encoding line: "<instruction text>\t# encoding: [0x48,0x89,...]"
ENC_RE = re.compile(r"^(.*?)\s*#\s*encoding:\s*\[([^\]]*)\]\s*$")
# llvm-mc notes an unresolvable branch displacement on the line(s) below the instruction:
#   #   fixup A - offset: 1, value: 36, kind: FK_PCRel_1
# those placeholder bytes are left out of the encoding list, so they must be added back to
# get the instruction length (a raw slice has no symbols to fold them into).
FIXUP_RE = re.compile(r"^\s*#\s*fixup\s+\S+\s*-\s*offset:\s*\d+.*kind:\s*FK_(?:PCRel|Data)_(\d+)")
HEXBYTE_RE = re.compile(r"0x[0-9a-fA-F]{1,2}")
# Data directives llvm-mc emits for bytes it cannot decode; they also advance the address.
DATA_RE = re.compile(r"^\s*\.(\w+)(?:\s+(.*))?$")
DATA_WIDTH = {"byte": 1, "short": 2, "word": 2, "long": 4, "quad": 8,
              "zero": 1, "fill": 1}
NUM_RE = re.compile(r"0x[0-9a-fA-F]+|\b\d+\b")
# A call/jmp/jcc/loop whose operand llvm-mc printed as a bare signed number is a relative
# branch: with no symbols in a raw slice llvm-mc prints the *displacement*, so the guest
# target is (instruction address) + (instruction length) + (that displacement).
BRANCH_RE = re.compile(r"^(call|jmp|j\w+|loop\w*)\s+(-?0x[0-9a-fA-F]+|-?\d+)$")
# llvm-mc prints a RIP-relative operand as the raw displacement too, so the data address is
# (instruction address) + (length) + (displacement).
RIP_RE = re.compile(r"\[rip\s*([+-])\s*(0x[0-9a-fA-F]+|\d+)\]", re.I)


def px(text: str) -> int:
    """A byte count or RVA as the trace prints it: bare digits are hex, 0x is honoured too."""
    t = text.strip()
    return int(t, 16) if t[:2].lower() != "0x" else int(t, 16)


def read_pe(path: str) -> dict:
    """image base, entry point and the section table of a PE32/PE32+ image."""
    with open(path, "rb") as f:
        dos = f.read(0x40)
        if dos[:2] != b"MZ":
            raise SystemExit(f"not a DOS/PE image: {path}")
        lfanew = struct.unpack_from("<I", dos, 0x3C)[0]
        f.seek(lfanew)
        if f.read(4) != b"PE\0\0":
            raise SystemExit(f"bad PE signature at 0x{lfanew:x}: {path}")
        machine, nsec, _t, _s, _p, opt_size, _chr = struct.unpack(
            "<HHIIIHH", f.read(20))
        opt = f.read(opt_size)
        magic = struct.unpack_from("<H", opt, 0)[0]
        if magic == 0x20B:                                  # PE32+
            image_base, = struct.unpack_from("<Q", opt, 0x18)
            entry, = struct.unpack_from("<I", opt, 0x10)
        elif magic == 0x10B:                                # PE32
            image_base, = struct.unpack_from("<I", opt, 0x1C)
            entry, = struct.unpack_from("<I", opt, 0x10)
        else:
            raise SystemExit(f"unknown optional-header magic 0x{magic:x}")
        table = f.read(nsec * 40)
    sections = []
    for i in range(nsec):
        rec = table[i * 40:(i + 1) * 40]
        name = rec[0:8].rstrip(b"\0").decode("latin-1")
        vsize, va, raw_size, raw_ptr = struct.unpack_from("<IIII", rec, 8)
        chars, = struct.unpack_from("<I", rec, 36)
        sections.append(dict(name=name, va=va, vsize=vsize, raw_ptr=raw_ptr,
                             raw_size=raw_size, chars=chars))
    return dict(machine=machine, image_base=image_base, entry=entry, nsec=nsec,
                sections=sections)


def rva_to_offset(pe: dict, rva: int):
    """(section, file offset, bytes left in that section's raw data) or (None, None, 0)."""
    for s in pe["sections"]:
        if s["va"] <= rva < s["va"] + max(s["vsize"], s["raw_size"]):
            off = s["raw_ptr"] + (rva - s["va"])
            return s, off, max(0, s["raw_ptr"] + s["raw_size"] - off)
    return None, None, 0


def cut(exe: str, pe: dict, start: int, length: int) -> list:
    """[(section, file_offset, data)] over [start, start+length), split at section ends."""
    chunks, done = [], 0
    with open(exe, "rb") as f:
        while done < length:
            sec, off, avail = rva_to_offset(pe, start + done)
            if sec is None or avail == 0:
                raise SystemExit(f"RVA 0x{start + done:x} maps to no file data "
                                 f"(unmapped, or past the section's raw data)")
            f.seek(off)
            data = f.read(min(length - done, avail))
            if not data:
                raise SystemExit(f"short read at RVA 0x{start + done:x}")
            chunks.append((sec, off, data))
            done += len(data)
    return chunks


def llvm_mc_disassemble(data: bytes, mc: str, intel: bool = True) -> str:
    """llvm-mc -disassemble takes hex *text* (--hex), and needs a file, not a pipe."""
    hex_text = "\n".join(" ".join(f"{b:02x}" for b in data[i:i + 16])
                         for i in range(0, len(data), 16))
    with tempfile.NamedTemporaryFile("w", suffix=".hex", delete=False,
                                     encoding="ascii") as tf:
        tf.write(hex_text + "\n")
        tmp = tf.name
    cmd = [mc, "--triple=x86_64", "--disassemble", "--hex", "--show-encoding"]
    if intel:
        # x86 output variants: 0 = AT&T, 1 = Intel. (--disassembler-style is gone in LLVM 20+.)
        cmd.append("--output-asm-variant=1")
    cmd.append(tmp)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=300)
    finally:
        os.unlink(tmp)
    out = r.stdout or ""
    if r.returncode != 0:
        out = f";; llvm-mc exit {r.returncode}: {(r.stderr or '').strip()}\n" + out
    elif (r.stderr or "").strip():
        out += f";; llvm-mc stderr: {r.stderr.strip()}\n"
    return out


def renumber(raw: str, start: int, image_base: int, annotate: bool):
    """Re-address llvm-mc's origin-0 output onto the guest image.

    An instruction's real length is the encoding bytes llvm-mc printed plus the width of
    every fixup listed under it: branch displacements are left out of the byte list
    because a raw slice has no symbol to resolve them against.

    Returns (rows, bytes_consumed). `start` is the RVA of this slice's first byte; the
    numbers llvm-mc prints for relative branches are addresses in the same slice-local
    space, so a printed target T is really exe+0x(start + T).
    """
    rows, addr, i, lines = [], start, 0, raw.splitlines()
    while i < len(lines):
        stripped = lines[i].strip()
        if not stripped:
            i += 1
            continue
        if stripped.startswith(";;"):
            rows.append(f"{'':30}  {stripped}")
            i += 1
            continue
        m = ENC_RE.match(lines[i])
        if m:
            text, enc = m.group(1).strip(), m.group(2)
            hexes = HEXBYTE_RE.findall(enc)
            widths, j = [], i + 1
            while j < len(lines):
                f = FIXUP_RE.match(lines[j])
                if not f:
                    break
                widths.append(int(f.group(1)))
                j += 1
            note = ""
            length = len(hexes) + sum(widths)
            if annotate:
                b = BRANCH_RE.match(text)
                if b:
                    disp = int(b.group(2), 0)
                    note = f"        ; -> exe+0x{addr + length + disp:x}  (disp {disp:+d})"
                else:
                    r = RIP_RE.search(text)
                    if r:
                        disp = int(r.group(2), 0) * (-1 if r.group(1) == "-" else 1)
                        tgt = addr + length + disp
                        note = (f"    ; [rip] -> exe+0x{tgt:x}"
                                f"  (va 0x{image_base + tgt:x}, disp {disp:+d})")
            enc_text = "[" + " ".join("0x" + h for h in hexes) + "]"
            if widths:
                enc_text += f" +{sum(widths)}B disp"
            rows.append(f"  exe+0x{addr:08x}  ({image_base + addr:016x})  "
                        f"{enc_text:<32}{text}{note}")
            addr += length
            i = j
            continue
        d = DATA_RE.match(lines[i])
        if d and d.group(1) in DATA_WIDTH:
            kind, arg = d.group(1), (d.group(2) or "")
            nums = NUM_RE.findall(arg)
            if kind in ("zero", "fill"):
                n = int(nums[0], 0) if nums else 0
            elif arg.startswith('"'):
                n = len(arg) - 2 + (1 if kind.endswith("z") else 0)
            else:
                n = len(nums) * DATA_WIDTH[kind]
            rows.append(f"  exe+0x{addr:08x}  ({image_base + addr:016x})  {stripped}")
            addr += n
            i += 1
            continue
        rows.append(f"{'':30}  {stripped}")
        i += 1
    return rows, addr - start


def read_rva(exe: str, pe: dict, rva: int, n: int) -> bytes:
    """Read n bytes at an RVA (crossing a section end is not expected for headers/tables)."""
    sec, off, avail = rva_to_offset(pe, rva)
    if sec is None or avail < n:
        return b""
    with open(exe, "rb") as f:
        f.seek(off)
        return f.read(n)


def data_directories(exe: str, pe_info: dict) -> list:
    """The optional header's data directories (RVA, size) pairs, in the PE order."""
    with open(exe, "rb") as f:
        f.seek(struct.unpack_from("<I", read_rva(exe, pe_info, 0, 0) or b"\0" * 4, 0)[0] or 0)
    return []


def imports(exe: str, pe: dict) -> list:
    """[(dll, [(iat_rva, hint, name_or_ordinal)])] from the PE import directory."""
    opt_rva = pe["opt_rva"]
    # NumberOfRvaAndSizes and the data directory follow the standard-header fields; the offset
    # depends only on the optional-header magic, which read_pe() already distinguished.
    dd_off = 0x70 if pe["magic"] == 0x20B else 0x60
    dd = read_rva(exe, pe, opt_rva + dd_off, 16 * 8)
    if len(dd) < 16:
        return []
    import_rva, import_size = struct.unpack_from("<II", dd, 8)   # directory entry 1
    if not import_rva:
        return []
    entry_w, flag = (8, 0x8000000000000000) if pe["magic"] == 0x20B else (4, 0x80000000)
    out, i = [], 0
    while True:
        desc = read_rva(exe, pe, import_rva + i * 20, 20)
        if len(desc) < 20 or desc == b"\0" * 20:
            break
        int_rva, _ts, _fc, name_rva, iat_rva = struct.unpack("<IIIII", desc)
        dll = read_rva(exe, pe, name_rva, 256).split(b"\0")[0].decode("latin-1")
        table_rva = int_rva or iat_rva
        entries, j = [], 0
        while True:
            raw = read_rva(exe, pe, table_rva + j * entry_w, entry_w)
            if len(raw) < entry_w:
                break
            val, = struct.unpack(f"<{'Q' if entry_w == 8 else 'I'}", raw)
            if val == 0:
                break
            if val & flag:
                entries.append((iat_rva + j * entry_w, None, f"ordinal {val & 0xFFFF}"))
            else:
                hint_name = read_rva(exe, pe, (val & 0x7FFFFFFF) + 2, 256)
                name = hint_name.split(b"\0")[0].decode("latin-1")
                entries.append((iat_rva + j * entry_w, val & 0xFFFF, name))
            j += 1
        out.append((dll, iat_rva, entries))
        i += 1
    return out


def resolve_iat(exe: str, pe: dict, rva: int) -> str:
    """`dll!name` for an IAT slot RVA, or an explanation of what the slot is."""
    for dll, iat_rva, entries in imports(exe, pe):
        for slot, hint, name in entries:
            if slot == rva:
                return f"{dll}!{name}" + (f"  (hint {hint})" if hint is not None else "")
    return f"(no import descriptor names IAT slot exe+0x{rva:x})"


def main() -> int:
    ap = argparse.ArgumentParser(
        description="llvm-mc slice disassembly of the guest image, addressed by exe+RVA.")
    ap.add_argument("--exe", default=DEFAULT_EXE, help="guest PE image (opened read-only)")
    ap.add_argument("--mc", default=DEFAULT_MC, help="llvm-mc executable")
    ap.add_argument("--rva", help="start RVA (hex; the exe+0x... value from a trace)")
    ap.add_argument("--from", dest="from_", help="start RVA (same as --rva)")
    ap.add_argument("--to", help="end RVA, exclusive (hex)")
    ap.add_argument("--len", dest="length", type=px, help="byte count if --to is not given "
                        "(default 32)")
    ap.add_argument("--att", action="store_true", help="AT&T syntax instead of Intel")
    ap.add_argument("--no-annotate", action="store_true",
                    help="drop the '; -> exe+0x' branch-target comments")
    ap.add_argument("--title", default="", help="header line for saved listings")
    ap.add_argument("--sections", action="store_true",
                    help="print the whole section table and exit")
    ap.add_argument("--image-base", type=px, default=None,
                    help="override the image base used only for the VA column")
    a = ap.parse_args()

    if a.sections:
        pe = read_pe(a.exe)
        print(f"# {a.exe}")
        print(f"# image base 0x{pe['image_base']:x}  entry RVA 0x{pe['entry']:x}  "
              f"machine 0x{pe['machine']:x}  {pe['nsec']} sections")
        print(f"# {'name':<10}{'rva':<14}{'vsize':<14}{'raw':<14}{'rawsize':<14}chars")
        for s in pe["sections"]:
            print(f"# {s['name']:<10}{s['va']:<14x}{s['vsize']:<14x}{s['raw_ptr']:<14x}"
                  f"{s['raw_size']:<14x}0x{s['chars']:x}")
        return 0

    start_text = a.rva or a.from_
    if not start_text:
        ap.error("give --rva or --from")
    start = px(start_text)
    if a.to:
        end = px(a.to)
        if end <= start:
            ap.error("--to must be above --from/--rva")
        length = end - start
    else:
        length = a.length or 32
    if not 0 < length <= 1 << 22:
        ap.error("length must be 1 .. 4 MiB")

    pe = read_pe(a.exe)
    image_base = a.image_base if a.image_base is not None else pe["image_base"]
    chunks = cut(a.exe, pe, start, length)

    if a.title:
        print(f"### {a.title}")
    print(f"# exe     : {a.exe}")
    print(f"# llvm-mc : {a.mc}  (--triple=x86_64 --disassemble --hex --show-encoding"
          f"{' --output-asm-variant=1' if not a.att else ' --output-asm-variant=0'})")
    print(f"# PE      : machine 0x{pe['machine']:x}, image base 0x{pe['image_base']:x}, "
          f"entry RVA 0x{pe['entry']:x}, {pe['nsec']} sections")
    print(f"# slice   : exe+0x{start:x} .. exe+0x{start + length:x} "
          f"({length} bytes, shown as VA 0x{image_base + start:x})")
    for sec, off, data in chunks:
        print(f"#   section {sec['name']:<8} rva 0x{sec['va']:x} raw 0x{sec['raw_ptr']:x}"
              f"+0x{sec['raw_size']:x} chars 0x{sec['chars']:x}"
              f"  -> file 0x{off:x}, {len(data)} bytes")
    print()

    addr = start
    for sec, off, data in chunks:
        raw = llvm_mc_disassemble(data, a.mc, intel=not a.att)
        rows, consumed = renumber(raw, addr, image_base, annotate=not a.no_annotate)
        if len(chunks) > 1:
            print(f"--- exe+0x{addr:x} .. exe+0x{addr + len(data):x} "
                  f"({sec['name']}, file 0x{off:x}) ---")
        print("\n".join(rows))
        if consumed != len(data):
            print(f"{'':30}  ;; alignment note: llvm-mc output covered {consumed} of "
                  f"{len(data)} bytes; addresses are re-synced at exe+0x{addr + consumed:x}")
        addr += len(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
