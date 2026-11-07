#!/usr/bin/env bash
# Builds native/build/d3d9.dll (PE32 i386) with the x86_64 mingw toolchain in freestanding mode (no CRT/libgcc).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
cat > build/k32.def <<'EOF'
LIBRARY kernel32.dll
EXPORTS
LoadLibraryA@4
GetProcAddress@8
GetSystemDirectoryA@8
GetModuleFileNameA@12
GetModuleHandleA@4
GetCommandLineA@0
CreateFileA@28
WriteFile@20
ReadFile@20
GetFileSize@8
CloseHandle@4
FlushFileBuffers@4
VirtualProtect@16
QueryPerformanceCounter@4
QueryPerformanceFrequency@4
GetTickCount@0
OutputDebugStringA@4
EOF
cat > build/u32.def <<'EOF'
LIBRARY user32.dll
EXPORTS
MessageBoxA@16
EOF
dlltool -m i386 --as-flags=--32 -k -d build/k32.def -l build/libk32.a
dlltool -m i386 --as-flags=--32 -k -d build/u32.def -l build/libu32.a
CFLAGS="-m32 -O2 -std=gnu11 -ffreestanding -fno-builtin -fno-stack-protector -fno-asynchronous-unwind-tables -mno-stack-arg-probe -fno-ident -Wall -Wextra -Wno-unused-parameter -march=i686 -mfpmath=387"
objs=()
for f in src/*.c; do
  o="build/$(basename "${f%.c}").o"
  gcc $CFLAGS -c "$f" -o "$o"
  objs+=("$o")
done
ld -m i386pe --shared -e _DllMain@12 --kill-at --enable-stdcall-fixup -o build/d3d9.dll "${objs[@]}" build/libk32.a build/libu32.a
objdump -p build/d3d9.dll | grep -E "Magic|DLL Name|Direct3DCreate9|\[" | head -40
echo built native/build/d3d9.dll
