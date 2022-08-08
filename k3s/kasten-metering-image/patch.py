#!/usr/bin/env python3
"""
Patch metering-server: reverse the conditional jump after
VerifyPKCS1v15 call inside VerifyKastenSignature,
making signature verification always pass.
"""

import struct
import sys
from elftools.elf.elffile import ELFFile
from capstone import Cs, CS_ARCH_X86, CS_MODE_64

TARGET_FUNC_SUBSTR = "VerifyKastenSignature"
TARGET_CALL_SUBSTR = "VerifyPKCS1v15"
CONDITIONAL_JUMPS = {"je", "jne", "jz", "jnz"}


def log(msg):
    print(f"[INFO] {msg}")


def error(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(1)


def vaddr_to_file_offset(elf, vaddr):
    for seg in elf.iter_segments():
        if seg["p_type"] == "PT_LOAD":
            seg_start = seg["p_vaddr"]
            seg_end = seg_start + seg["p_filesz"]
            if seg_start <= vaddr < seg_end:
                return vaddr - seg_start + seg["p_offset"]
    error(f"virtual address 0x{vaddr:x} not found in any LOAD segment")


def main():
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} <input_binary> <output_binary>")
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2]

    with open(input_path, "rb") as f:
        elf = ELFFile(f)
        symtab = elf.get_section_by_name(".symtab")
        if symtab is None:
            error(".symtab section not found, binary may be stripped")

        # 模糊匹配函数符号
        func_name = None
        func_addr = None
        func_size = 0
        for sym in symtab.iter_symbols():
            if TARGET_FUNC_SUBSTR in sym.name:
                func_name = sym.name
                func_addr = sym["st_value"]
                func_size = sym["st_size"]
                break

        if func_addr is None:
            error(f"no symbol containing '{TARGET_FUNC_SUBSTR}' found in binary")
        if func_size == 0:
            error(f"{func_name} has size 0")

        log(f"found function: {func_name} at 0x{func_addr:x}, size {func_size} bytes")

        # 收集所有包含 VerifyPKCS1v15 的符号地址
        target_addrs = set()
        for sym in symtab.iter_symbols():
            if TARGET_CALL_SUBSTR in sym.name:
                target_addrs.add(sym["st_value"])
                log(f"  call target: {sym.name} at 0x{sym['st_value']:x}")

        if not target_addrs:
            error(f"no symbol containing '{TARGET_CALL_SUBSTR}' found in binary")

        # 读取函数范围的机器码
        code_section = elf.get_section_by_name(".text")
        if code_section is None:
            error(".text section not found")

        text_offset = code_section["sh_addr"]
        offset_in_section = func_addr - text_offset
        code = code_section.data()[offset_in_section : offset_in_section + func_size]

    # 反汇编（仅用于 mnemonic 和 size，不用 detail）
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    instructions = list(md.disasm(code, func_addr))

    # 找 call rel32 (E8 xx xx xx xx) 目标匹配 VerifyPKCS1v15
    call_idx = None
    for i, insn in enumerate(instructions):
        if insn.mnemonic != "call":
            continue
        insn_offset = insn.address - func_addr
        raw = code[insn_offset : insn_offset + insn.size]
        if raw[0] == 0xE8 and insn.size == 5:
            rel32 = struct.unpack("<i", raw[1:5])[0]
            target = insn.address + insn.size + rel32
            if target in target_addrs:
                call_idx = i
                break

    if call_idx is None:
        error(f"call to *{TARGET_CALL_SUBSTR}* not found within {func_name}")

    log(f"found call at 0x{instructions[call_idx].address:x}")

    # 在 call 后 10 条指令内找第一个条件跳转
    jump_insn = None
    for i in range(call_idx + 1, min(call_idx + 11, len(instructions))):
        if instructions[i].mnemonic in CONDITIONAL_JUMPS:
            jump_insn = instructions[i]
            break

    if jump_insn is None:
        error("conditional jump after call not found")

    log(f"found {jump_insn.mnemonic} at 0x{jump_insn.address:x}, {jump_insn.size} bytes")

    # 读取跳转指令的原始字节
    with open(input_path, "rb") as f:
        elf = ELFFile(f)
        file_offset = vaddr_to_file_offset(elf, jump_insn.address)
        f.seek(file_offset)
        original = bytearray(f.read(jump_insn.size))

    # 反转条件跳转
    patched = bytearray(original)
    if jump_insn.size == 2:
        # 短跳转: 74(je/jz) <-> 75(jne/jnz)
        if patched[0] == 0x74:
            patched[0] = 0x75
        elif patched[0] == 0x75:
            patched[0] = 0x74
        else:
            error(f"unexpected short jump opcode 0x{patched[0]:02x}")
    elif jump_insn.size == 6:
        # 近跳转: 0F 84 <-> 0F 85
        if patched[0] == 0x0F and patched[1] == 0x84:
            patched[1] = 0x85
        elif patched[0] == 0x0F and patched[1] == 0x85:
            patched[1] = 0x84
        else:
            error(f"unexpected near jump opcode 0x{patched[0]:02x} 0x{patched[1]:02x}")
    else:
        error(f"unexpected jump instruction size: {jump_insn.size}")

    log(f"reversing jump: {jump_insn.mnemonic} at 0x{jump_insn.address:x}")
    log(f"  original: {original.hex()}")
    log(f"  patched:  {patched.hex()}")

    # 写 patch
    with open(input_path, "rb") as f:
        content = bytearray(f.read())

    content[file_offset : file_offset + jump_insn.size] = patched

    with open(output_path, "wb") as f:
        f.write(content)

    assert content[file_offset : file_offset + jump_insn.size] == patched
    log(f"patch verified at 0x{jump_insn.address:x}")


if __name__ == "__main__":
    main()
