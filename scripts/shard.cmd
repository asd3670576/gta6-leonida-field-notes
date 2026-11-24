@echo off
rem One rdna2spirv.py translation shard. Usage: shard.cmd <index>
setlocal
set PY=C:\Users\L.S\.dsh\dsh-runtimes\dsh-next-primary-runtime\dependencies\python\python.exe
set PATH=C:\Users\L.S\.dsh\dsh-runtimes\dsh-next-primary-runtime\dependencies\python;C:\Users\L.S\AppData\Local\miniforge3\envs\spirv\Library\bin;%PATH%
set LLVM_MC=C:\Users\L.S\AppData\Local\miniforge3\envs\llvm-tools\Library\bin\llvm-mc.exe
set LEONIDA_W64_EMULATE=1
cd /d H:\leonida\Leonida
"%PY%" -I tools\rdna2spirv.py "H:\leonida\work\shaders\dxbc\disasm" --out "H:\leonida\work\shaders\spirv" --shard %1/16 --no-asm --wave64-emulate > "H:\leonida\logs\shards\shard%1.log" 2>&1
endlocal
