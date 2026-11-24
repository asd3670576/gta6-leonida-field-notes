"""Wrap the MSVC-only switches in runtime/CMakeLists.txt in a compiler genex.

Why: that file passes MSVC spellings to ~180 targets unconditionally, e.g.
  runtime/CMakeLists.txt:135  target_compile_options(gta6rt PRIVATE /W4 /permissive- /utf-8)
  runtime/CMakeLists.txt:147  target_link_options(gta6rt PRIVATE /OPT:NOREF ${GTA6RT_HOST_BASE} /STACK:${GTA6RT_STACK})
GCC reads `/W4` as an input file name and stops. Shadowing target_compile_options
from a toolchain file does not work either: CMake 4.5 has no underscore escape for
that command, so the shadow recursed into itself.

This rewrites only the option-bearing command lines, and only tokens that start
with `/` followed by a letter, so paths (`Source/Task`), comments and URLs are
untouched. Idempotent: an already-wrapped token is left alone.
"""
import re
import sys
from pathlib import Path

TARGET = Path(sys.argv[1] if len(sys.argv) > 1 else r"H:\leonida\Leonida-continued\runtime\CMakeLists.txt")

# Lines we touch: the three option commands.
LINE_RE = re.compile(r"^\s*(target_compile_options|target_link_options|add_compile_options)\b")
# A MSVC-style switch: /W4 /EHsc /utf-8 /OPT:NOREF /STACK:8388608 /BASE:0x1... /GS- /bigobj /EHa /FIXED
# /DYNAMICBASE:NO /NODEFAULTLIB /ENTRY:Name /INCREMENTAL:NO /DEBUG /Zi /SUBSYSTEM:CONSOLE
SWITCH_RE = re.compile(r"(?<![\w>/\\$])(/[A-Za-z][A-Za-z0-9:._+-]*)")
WRAPPED_RE = re.compile(r"\$<\$<CXX_COMPILER_ID:MSVC>:/")

lines = TARGET.read_text(encoding="utf-8").splitlines(keepends=True)
changed = 0
tokens = 0
for i, line in enumerate(lines):
    if not LINE_RE.match(line):
        continue
    # Second pass first: a switch whose value is a CMake variable was wrapped
    # only up to the `$`, which left the value outside the generator expression
    # (`$<$<CXX_COMPILER_ID:MSVC>:/STACK>:${GTA6RT_STACK}` expands to a bare
    # `8388608` for GCC, and the linker reads it as an input file). Same for a
    # whole option that is a variable, ${GTA6RT_HOST_BASE} = /BASE:0x10000000000.
    def fixup(text: str) -> tuple[str, int]:
        n = 0

        def close_var(m):
            nonlocal n
            n += 1
            return "$<$<CXX_COMPILER_ID:MSVC>:%s:${%s}>" % (m.group(1), m.group(2))

        def wrap_var(m):
            nonlocal n
            n += 1
            return "$<$<CXX_COMPILER_ID:MSVC>:${%s}>" % m.group(1)

        # The switch's colon can land on either side of the closing `>`:
        #   $<$<CXX_COMPILER_ID:MSVC>:/STACK:>${GTA6RT_STACK}   (colon inside)
        #   $<$<CXX_COMPILER_ID:MSVC>:/STACK>:${GTA6RT_STACK}   (colon outside)
        # Both expand to a bare `8388608` for GCC, which the linker then reads as
        # an input file ("cannot find 8388608").
        text = re.sub(r"\$<\$<CXX_COMPILER_ID:MSVC>:/([A-Za-z0-9._+-]*):?>\$\{([A-Za-z0-9_]+)\}",
                      close_var, text)
        text = re.sub(r"(?<![\w}>])\$\{(GTA6RT_HOST_BASE)\}", wrap_var, text)
        return text, n

    new, n = fixup(line)
    if n:
        lines[i] = new
        changed += 1
        tokens += n
        continue
    if WRAPPED_RE.search(line):
        continue  # already patched
    new, n = SWITCH_RE.subn(lambda m: "$<$<CXX_COMPILER_ID:MSVC>:%s>" % m.group(1), line)
    if n:
        lines[i] = new
        changed += 1
        tokens += n

TARGET.write_text("".join(lines), encoding="utf-8")
print(f"{TARGET.name}: wrapped {tokens} MSVC-only switches across {changed} lines")
