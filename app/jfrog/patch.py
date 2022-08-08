#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Patch Java .class files inside one or more JARs:
  1) find LDC/LDC_W loading a specified String constant;
  2) scan upward in the same method for the nearest IFNE within N instructions;
  3) invert IFNE (0x9A) to IFEQ (0x99).
"""

import argparse
import os
import struct
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from typing import Any, List, Optional, Sequence, Tuple, Union

U1 = struct.Struct(">B")
U2 = struct.Struct(">H")
U4 = struct.Struct(">I")

IFNE = 0x9A
IFEQ = 0x99
LDC = 0x12
LDC_W = 0x13


class ClassParseError(Exception):
    pass


@dataclass(frozen=True)
class Instruction:
    pc: int
    opcode: int
    length: int


@dataclass
class PatchHit:
    jar_entry: str
    class_name: str
    method_name: str
    method_desc: str
    ldc_pc: int
    ifne_pc: int


def u1(data: Union[bytes, bytearray], off: int) -> int:
    return data[off]


def u2(data: Union[bytes, bytearray], off: int) -> int:
    return U2.unpack_from(data, off)[0]


def u4(data: Union[bytes, bytearray], off: int) -> int:
    return U4.unpack_from(data, off)[0]


def require(data: Union[bytes, bytearray], off: int, n: int, what: str) -> None:
    if off < 0 or off + n > len(data):
        raise ClassParseError(f"truncated class while reading {what} at offset {off}")


def read_u1(data: Union[bytes, bytearray], off: int) -> Tuple[int, int]:
    require(data, off, 1, "u1")
    return data[off], off + 1


def read_u2(data: Union[bytes, bytearray], off: int) -> Tuple[int, int]:
    require(data, off, 2, "u2")
    return u2(data, off), off + 2


def read_u4(data: Union[bytes, bytearray], off: int) -> Tuple[int, int]:
    require(data, off, 4, "u4")
    return u4(data, off), off + 4


def cp_utf8(cp: List[Optional[Tuple[Any, ...]]], idx: int) -> str:
    if idx <= 0 or idx >= len(cp):
        raise ClassParseError(f"bad constant-pool index {idx}")
    ent = cp[idx]
    if not ent or ent[0] != "Utf8":
        raise ClassParseError(f"constant-pool index {idx} is not Utf8")
    return ent[1]


def cp_class_name(cp: List[Optional[Tuple[Any, ...]]], idx: int) -> str:
    ent = cp[idx]
    if not ent or ent[0] != "Class":
        return f"<bad-class-{idx}>"
    return cp_utf8(cp, ent[1]).replace("/", ".")


def cp_ldc_string(cp: List[Optional[Tuple[Any, ...]]], idx: int) -> Optional[str]:
    if idx <= 0 or idx >= len(cp):
        return None
    ent = cp[idx]
    if not ent:
        return None
    # LDC of a Java string constant uses CONSTANT_String, which points to Utf8.
    if ent[0] == "String":
        try:
            return cp_utf8(cp, ent[1])
        except ClassParseError:
            return None
    return None


def parse_constant_pool(data: Union[bytes, bytearray], off: int) -> Tuple[List[Optional[Tuple[Any, ...]]], int]:
    cp_count, off = read_u2(data, off)
    cp: List[Optional[Tuple[Any, ...]]] = [None] * cp_count
    i = 1
    while i < cp_count:
        tag, off = read_u1(data, off)
        if tag == 1:  # Utf8
            n, off = read_u2(data, off)
            require(data, off, n, "CONSTANT_Utf8 bytes")
            raw = bytes(data[off:off + n])
            off += n
            # Java uses "modified UTF-8". For ordinary strings this works fine;
            # surrogate/NUL edge cases fall back to replacement rather than crashing.
            try:
                s = raw.decode("utf-8")
            except UnicodeDecodeError:
                s = raw.decode("utf-8", errors="replace")
            cp[i] = ("Utf8", s)
        elif tag == 3:  # Integer
            val, off = read_u4(data, off)
            cp[i] = ("Integer", val)
        elif tag == 4:  # Float
            val, off = read_u4(data, off)
            cp[i] = ("Float", val)
        elif tag == 5:  # Long, takes two cp slots
            hi, off = read_u4(data, off)
            lo, off = read_u4(data, off)
            cp[i] = ("Long", (hi << 32) | lo)
            i += 1
        elif tag == 6:  # Double, takes two cp slots
            hi, off = read_u4(data, off)
            lo, off = read_u4(data, off)
            cp[i] = ("Double", (hi << 32) | lo)
            i += 1
        elif tag == 7:  # Class
            name_index, off = read_u2(data, off)
            cp[i] = ("Class", name_index)
        elif tag == 8:  # String
            string_index, off = read_u2(data, off)
            cp[i] = ("String", string_index)
        elif tag in (9, 10, 11):  # Field/Method/InterfaceMethod ref
            a, off = read_u2(data, off)
            b, off = read_u2(data, off)
            cp[i] = ("Ref", tag, a, b)
        elif tag == 12:  # NameAndType
            a, off = read_u2(data, off)
            b, off = read_u2(data, off)
            cp[i] = ("NameAndType", a, b)
        elif tag == 15:  # MethodHandle
            kind, off = read_u1(data, off)
            ref, off = read_u2(data, off)
            cp[i] = ("MethodHandle", kind, ref)
        elif tag == 16:  # MethodType
            desc, off = read_u2(data, off)
            cp[i] = ("MethodType", desc)
        elif tag == 17:  # Dynamic
            a, off = read_u2(data, off)
            b, off = read_u2(data, off)
            cp[i] = ("Dynamic", a, b)
        elif tag == 18:  # InvokeDynamic
            a, off = read_u2(data, off)
            b, off = read_u2(data, off)
            cp[i] = ("InvokeDynamic", a, b)
        elif tag == 19:  # Module
            a, off = read_u2(data, off)
            cp[i] = ("Module", a)
        elif tag == 20:  # Package
            a, off = read_u2(data, off)
            cp[i] = ("Package", a)
        else:
            raise ClassParseError(f"unsupported constant-pool tag {tag} at cp index {i}")
        i += 1
    return cp, off


# Fixed instruction lengths. Variable-length opcodes are handled separately.
FIXED_LEN = [1] * 256
for op in (0x10, 0x12, 0x15, 0x16, 0x17, 0x18, 0x19, 0x36, 0x37, 0x38, 0x39, 0x3A, 0xA9, 0xBC):
    FIXED_LEN[op] = 2
for op in (0x11, 0x13, 0x14, 0x84, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xBB, 0xBD, 0xC0, 0xC1):
    FIXED_LEN[op] = 3
for op in range(0x99, 0xA9):
    FIXED_LEN[op] = 3
for op in (0xC6, 0xC7):
    FIXED_LEN[op] = 3
FIXED_LEN[0xB9] = 5  # invokeinterface
FIXED_LEN[0xBA] = 5  # invokedynamic
FIXED_LEN[0xC5] = 4  # multianewarray
FIXED_LEN[0xC8] = 5  # goto_w
FIXED_LEN[0xC9] = 5  # jsr_w


def parse_instructions(code: Union[bytes, bytearray]) -> List[Instruction]:
    out: List[Instruction] = []
    pc = 0
    n = len(code)
    while pc < n:
        opcode = code[pc]
        if opcode == 0xAA:  # tableswitch
            pad = (4 - ((pc + 1) & 3)) & 3
            base = pc + 1 + pad
            if base + 12 > n:
                raise ClassParseError(f"truncated tableswitch at pc {pc}")
            low = struct.unpack_from(">i", code, base + 4)[0]
            high = struct.unpack_from(">i", code, base + 8)[0]
            count = high - low + 1
            if count < 0:
                raise ClassParseError(f"bad tableswitch range at pc {pc}")
            length = 1 + pad + 12 + 4 * count
        elif opcode == 0xAB:  # lookupswitch
            pad = (4 - ((pc + 1) & 3)) & 3
            base = pc + 1 + pad
            if base + 8 > n:
                raise ClassParseError(f"truncated lookupswitch at pc {pc}")
            npairs = struct.unpack_from(">i", code, base + 4)[0]
            if npairs < 0:
                raise ClassParseError(f"bad lookupswitch npairs at pc {pc}")
            length = 1 + pad + 8 + 8 * npairs
        elif opcode == 0xC4:  # wide
            if pc + 1 >= n:
                raise ClassParseError(f"truncated wide at pc {pc}")
            next_op = code[pc + 1]
            length = 6 if next_op == 0x84 else 4
        else:
            length = FIXED_LEN[opcode]
        if length <= 0 or pc + length > n:
            raise ClassParseError(f"bad/truncated opcode 0x{opcode:02x} at pc {pc}")
        out.append(Instruction(pc, opcode, length))
        pc += length
    if pc != n:
        raise ClassParseError("instruction parsing did not end on code boundary")
    return out


def skip_attributes(data: Union[bytes, bytearray], off: int, cp: List[Optional[Tuple[Any, ...]]]) -> int:
    attrs_count, off = read_u2(data, off)
    for _ in range(attrs_count):
        _name_index, off = read_u2(data, off)
        attr_len, off = read_u4(data, off)
        require(data, off, attr_len, "attribute body")
        off += attr_len
    return off


def skip_members(data: Union[bytes, bytearray], off: int, cp: List[Optional[Tuple[Any, ...]]]) -> int:
    count, off = read_u2(data, off)
    for _ in range(count):
        require(data, off, 6, "member header")
        off += 6  # access_flags, name_index, descriptor_index
        off = skip_attributes(data, off, cp)
    return off


def patch_code(
    out: bytearray,
    code_start: int,
    code_len: int,
    cp: List[Optional[Tuple[Any, ...]]],
    target: str,
    max_up: int,
    jar_entry: str,
    class_name: str,
    method_name: str,
    method_desc: str,
    dry_run: bool,
) -> List[PatchHit]:
    code = out[code_start:code_start + code_len]
    insns = parse_instructions(code)
    hits: List[PatchHit] = []
    patched_abs_offsets = set()

    for idx, ins in enumerate(insns):
        cstr: Optional[str] = None
        if ins.opcode == LDC:
            if ins.pc + 1 < code_len:
                cstr = cp_ldc_string(cp, code[ins.pc + 1])
        elif ins.opcode == LDC_W:
            if ins.pc + 2 < code_len:
                cp_index = (code[ins.pc + 1] << 8) | code[ins.pc + 2]
                cstr = cp_ldc_string(cp, cp_index)

        if cstr != target:
            continue

        first = max(0, idx - max_up)
        for j in range(idx - 1, first - 1, -1):
            prev = insns[j]
            if prev.opcode == IFNE:
                abs_off = code_start + prev.pc
                if abs_off not in patched_abs_offsets:
                    if not dry_run:
                        out[abs_off] = IFEQ
                    patched_abs_offsets.add(abs_off)
                    hits.append(PatchHit(jar_entry, class_name, method_name, method_desc, ins.pc, prev.pc))
                break

    return hits


def patch_class(
    class_bytes: bytes,
    jar_entry: str,
    target: str,
    max_up: int,
    dry_run: bool,
) -> Tuple[bytes, List[PatchHit]]:
    out = bytearray(class_bytes)
    off = 0
    magic, off = read_u4(out, off)
    if magic != 0xCAFEBABE:
        raise ClassParseError("not a .class file")
    _minor, off = read_u2(out, off)
    _major, off = read_u2(out, off)
    cp, off = parse_constant_pool(out, off)

    require(out, off, 6, "class header")
    _access_flags, off = read_u2(out, off)
    this_class, off = read_u2(out, off)
    _super_class, off = read_u2(out, off)
    class_name = cp_class_name(cp, this_class)

    interfaces_count, off = read_u2(out, off)
    require(out, off, 2 * interfaces_count, "interfaces")
    off += 2 * interfaces_count

    off = skip_members(out, off, cp)  # fields

    methods_count, off = read_u2(out, off)
    all_hits: List[PatchHit] = []
    for _ in range(methods_count):
        require(out, off, 8, "method header")
        _access_flags, off = read_u2(out, off)
        name_index, off = read_u2(out, off)
        desc_index, off = read_u2(out, off)
        method_name = cp_utf8(cp, name_index)
        method_desc = cp_utf8(cp, desc_index)
        attrs_count, off = read_u2(out, off)
        for _attr_i in range(attrs_count):
            attr_name_index, off = read_u2(out, off)
            attr_len, off = read_u4(out, off)
            attr_name = cp_utf8(cp, attr_name_index)
            attr_start = off
            require(out, attr_start, attr_len, f"method attribute {attr_name}")
            if attr_name == "Code":
                # Code_attribute: u2 max_stack, u2 max_locals, u4 code_length, u1 code[]
                require(out, attr_start, 8, "Code header")
                code_len = u4(out, attr_start + 4)
                code_start = attr_start + 8
                require(out, code_start, code_len, "Code bytes")
                hits = patch_code(
                    out,
                    code_start,
                    code_len,
                    cp,
                    target,
                    max_up,
                    jar_entry,
                    class_name,
                    method_name,
                    method_desc,
                    dry_run,
                )
                all_hits.extend(hits)
            off = attr_start + attr_len

    # Skip class-level attributes to validate structure enough.
    off = skip_attributes(out, off, cp)
    if off != len(out):
        raise ClassParseError(f"class parse ended at {off}, file length is {len(out)}")

    return bytes(out), all_hits


def is_signature_file(name: str) -> bool:
    upper = name.upper()
    if not upper.startswith("META-INF/"):
        return False
    base = upper.rsplit("/", 1)[-1]
    return base.endswith((".SF", ".RSA", ".DSA", ".EC"))


def output_path_for(jar_path: str, output_dir: Optional[str]) -> str:
    base_dir = output_dir if output_dir else os.path.dirname(os.path.abspath(jar_path))
    stem = os.path.basename(jar_path)
    if stem.lower().endswith(".jar"):
        out_name = stem[:-4] + ".patched.jar"
    else:
        out_name = stem + ".patched.jar"
    return os.path.join(base_dir, out_name)


def clone_zipinfo(zi: zipfile.ZipInfo) -> zipfile.ZipInfo:
    new = zipfile.ZipInfo(zi.filename, zi.date_time)
    new.comment = zi.comment
    new.extra = zi.extra
    new.internal_attr = zi.internal_attr
    new.external_attr = zi.external_attr
    new.create_system = zi.create_system
    new.compress_type = zi.compress_type
    # Preserve UTF-8 flag and other harmless flags. Encryption is not supported by writestr.
    new.flag_bits = zi.flag_bits & ~0x1
    return new


def process_jar(
    jar_path: str,
    target: str,
    max_up: int,
    out_path: str,
    dry_run: bool,
    strip_signatures: bool,
    verbose: bool,
) -> List[PatchHit]:
    all_hits: List[PatchHit] = []
    parse_errors: List[str] = []
    stripped: List[str] = []

    with zipfile.ZipFile(jar_path, "r") as zin:
        infos = zin.infolist()
        if dry_run:
            for zi in infos:
                if not zi.filename.endswith(".class"):
                    continue
                data = zin.read(zi)
                try:
                    _new_data, hits = patch_class(data, zi.filename, target, max_up, dry_run=True)
                    all_hits.extend(hits)
                except ClassParseError as e:
                    parse_errors.append(f"{zi.filename}: {e}")
            if verbose and parse_errors:
                print(f"[warn] {jar_path}: {len(parse_errors)} class parse error(s)", file=sys.stderr)
                for line in parse_errors[:20]:
                    print(f"       {line}", file=sys.stderr)
            return all_hits

        out_dir = os.path.dirname(os.path.abspath(out_path)) or "."
        os.makedirs(out_dir, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(prefix=".patch-", suffix=".jar", dir=out_dir)
        os.close(fd)
        try:
            with zipfile.ZipFile(tmp_path, "w") as zout:
                zout.comment = zin.comment
                for zi in infos:
                    data = zin.read(zi)
                    if strip_signatures and is_signature_file(zi.filename):
                        stripped.append(zi.filename)
                        continue
                    if zi.filename.endswith(".class"):
                        try:
                            data, hits = patch_class(data, zi.filename, target, max_up, dry_run=False)
                            all_hits.extend(hits)
                        except ClassParseError as e:
                            parse_errors.append(f"{zi.filename}: {e}")
                    zout.writestr(clone_zipinfo(zi), data)
            os.replace(tmp_path, out_path)
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

    if verbose and parse_errors:
        print(f"[warn] {jar_path}: {len(parse_errors)} class parse error(s)", file=sys.stderr)
        for line in parse_errors[:20]:
            print(f"       {line}", file=sys.stderr)
    if verbose and stripped:
        print(f"[info] {jar_path}: stripped {len(stripped)} signature file(s)", file=sys.stderr)
    return all_hits


def print_hits(jar_path: str, hits: Sequence[PatchHit], dry_run: bool) -> None:
    action = "would patch" if dry_run else "patched"
    if not hits:
        print(f"[MISS] {jar_path}: no matching LDC followed by IFNE within the scan window")
        return
    print(f"[OK] {jar_path}: {action} {len(hits)} IFNE instruction(s)")
    for h in hits:
        print(
            f"  - {h.jar_entry} :: {h.class_name}.{h.method_name}{h.method_desc} "
            f"LDC@{h.ldc_pc}  IFNE@{h.ifne_pc} -> IFEQ"
        )


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description="Patch JARs: find LDC of a target string and invert nearest previous IFNE to IFEQ."
    )
    ap.add_argument("jars", nargs="+", help="input .jar file(s); pass your two JARs here")
    ap.add_argument("-s", "--string", default="License verification failed", help="target string loaded by LDC/LDC_W")
    ap.add_argument("-n", "--max-up", type=int, default=10, help="max number of instructions to scan upward")
    ap.add_argument("-o", "--output-dir", help="directory for *.patched.jar output")
    ap.add_argument("--in-place", action="store_true", help="replace original JAR in place")
    ap.add_argument("--dry-run", action="store_true", help="only report matches; do not write output")
    ap.add_argument("--strip-signatures", action="store_true", help="remove META-INF/*.SF/*.RSA/*.DSA/*.EC from output JAR")
    ap.add_argument("-q", "--quiet", action="store_true", help="less diagnostic output")
    args = ap.parse_args(argv)

    if args.max_up < 1:
        ap.error("--max-up must be >= 1")

    exit_code = 0
    for jar_path in args.jars:
        if not os.path.isfile(jar_path):
            print(f"[ERR] not a file: {jar_path}", file=sys.stderr)
            exit_code = 2
            continue

        if args.dry_run:
            out_path = ""
        elif args.in_place:
            out_path = os.path.abspath(jar_path)
        else:
            out_path = output_path_for(jar_path, args.output_dir)

        try:
            if args.in_place and not args.dry_run:
                tmp_out = os.path.abspath(jar_path) + ".patched.tmp"
                hits = process_jar(
                    jar_path,
                    args.string,
                    args.max_up,
                    tmp_out,
                    dry_run=False,
                    strip_signatures=args.strip_signatures,
                    verbose=not args.quiet,
                )
                os.replace(tmp_out, jar_path)
            else:
                hits = process_jar(
                    jar_path,
                    args.string,
                    args.max_up,
                    out_path,
                    dry_run=args.dry_run,
                    strip_signatures=args.strip_signatures,
                    verbose=not args.quiet,
                )

            print_hits(jar_path, hits, args.dry_run)
            if not args.dry_run and not args.in_place:
                print(f"[OUT] {out_path}")
        except zipfile.BadZipFile as e:
            print(f"[ERR] {jar_path}: bad zip/jar: {e}", file=sys.stderr)
            exit_code = 1
        except Exception as e:
            print(f"[ERR] {jar_path}: {e}", file=sys.stderr)
            exit_code = 1

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
