# 0011 - The boot stop is the title asserting on GameInputCreate, not on console memory

**Date:** 2026-11-24. **Tree:** `ubiquitarianism/leonida` @ `ff8ce388`, with the runtime
built by us under MinGW (0008). **Host:** Windows 10 19045.3324, RTX 3080 20 GB.

This supersedes the reading in 0007. There the halt was described as a
"console memory-attribute wall"; the allocations it pointed at all succeed, which we
established by instrumenting our own build (xmem.cpp logs every XMemVirtualAlloc result
under `LEONIDA_XMEM_LOG`) and by decoding the guest instructions from the shipped
executable with `port/guest_disasm.py` (PE section table -> RVA -> llvm-mc).

# stop2: 停机点解码（guest 侧）+ host 侧对照

结论：**属于 (a) —— 一个 import 的返回值被判为失败**，点名 `GameInput.dll`（按序号 ordinal 1 导入）= **GameInputCreate**。
guest 拿到负的 HRESULT 就 `int3`；跳过 int3 后它读的那个 0x0 是自己清零、而 callee 没写的 out 参数。
**不是** 分配失败（7 次 XMemVirtualAlloc 全部成功），也不是平台检测 assert（没有任何 CPU/GPU 判断）。

## 1. +0x5925915 的前 20 条指令（停机函数 = exe+0x59258a0，是个 lazy-singleton 取回器）

```
exe+0x059258a0  push  rsi                     ; F(rcx) —— 0x592589f 之前全是 int3 填充 → 0x59258a0 是函数入口
exe+0x059258a1  sub   rsp, 48
exe+0x059258a5  mov   rax, [rip+0x418bdbc]    ; [rip] -> exe+0x9ab15e8   ← 那个全局对象指针（仅在内存里的区段）
exe+0x059258ac  test  rax, rax
exe+0x059258af  je    exe+0x59258b7           ; 全局为 0 → 走创建路径
exe+0x059258b1  add   rsp, 48 / pop rsi / ret ; 快路径：直接返回全局
exe+0x059258b7  lea   rcx, [rsp + 40]
exe+0x059258bc  mov   qword ptr [rcx], 0      ; ★ out 参数由 caller 自己清零（就是后面读到的那个 0）
exe+0x059258c3  call  exe+0x5f3fed0           ; ★★ 唯一喂给断言的 call（见 §2）
exe+0x059258c8  test  eax, eax                ; ★ 只看 eax（32 位）→ 这是 HRESULT 判定，不是指针判定
exe+0x059258ca  js    exe+0x5925915           ; ★ 符号位为 1（FAILED）→ 跳到 int3
exe+0x059258cc  mov   rsi, [rsp + 40]         ; 出参
exe+0x059258d1  mov   rcx, [rip+…]            ; [rip] -> exe+0x9ab15e8
exe+0x059258d8  cmp   rcx, rsi / je exe+0x5925903   ; 第二条到达 0x5925903 的路径
exe+0x059258dd  test  rsi, rsi / je exe+0x59258f2
exe+0x059258e2  mov   rax,[rsi] / mov rcx,rsi / call qword ptr [rax + 8]    ; 虚槽 1
exe+0x059258eb  mov   rcx, [rip+…]            ; [rip] -> exe+0x9ab15e8
exe+0x059258f2  test  rcx, rcx / jne exe+0x5925918
exe+0x059258f7  mov   [rip+…], rsi            ; 发布全局 exe+0x9ab15e8 = 新对象
exe+0x059258fe  mov   rsi, [rsp + 40]         ; ★ 再读一次 out 参数
exe+0x05925903  mov   rax, [rsi]              ; ★ 0xc0000005 read of 0x0：rsi = 0
exe+0x05925906  mov   rcx, rsi
exe+0x05925909  call  qword ptr [rax + 16]    ; 虚槽 2
exe+0x0592590c  mov   rax, [rip+…]            ; [rip] -> exe+0x9ab15e8 → 返回值
exe+0x05925913  jmp   exe+0x59258b1           ; 返回
exe+0x05925915  int3                          ; ★ 断言点：只有 0x59258ca 的 js 会到这里
exe+0x05925916  jmp   exe+0x59258cc           ; ★ LEONIDA_SKIP_INT3 后从这里回到出参读取
exe+0x05925918  mov   rax,[rcx] / call qword ptr [rax + 16] / jmp exe+0x59258f7
```
断言模式 = `call; test eax,eax; js → int3`（MSVC 对返回 HRESULT 的 import 的标准检查），**不是** `test reg,reg / jz / int3`，也不是 RtlDebug 宏。

## 2. 那个 call 的目标是 import，不是 exe 内静态函数

```
exe+0x05f3fed0  [ff 25 3a 40 85 00]  jmp  qword ptr [rip + 8732730]   ; [rip] -> exe+0x6793f10
exe+0x05f3fed6  int3 …（0x5f3fe90 起每个 6 字节 jmp + int3 填充 = 整片都是 import thunk）
```
`guest_disasm.py --resolve 6793f10`（新加的 RVA→导入名解析，读 PE 导入表：68 个模块 / 587 个 import）：

    exe+0x6793f10 (va 0x146793f10): GameInput.dll!ordinal 1     ; GameInput.dll 只有这一个 import

ordinal 1 ↔ GameInputCreate 的佐证（不是猜）：`runtime/test/fixtures/gameinput_host.cpp:3`（PC 的 title 也"按 ordinal 导入 GameInputCreate"）、
`runtime/shims/gameinput_abi.h:811` `HRESULT(WINAPI*)(IGameInput** gameInput)`（第一个参数就是 out 指针）、
`runtime/shims/gameinput.cpp:2728-2729` 注册名 `gameinput.dll!GameInputCreate` / `xgameruntime.dll!GameInputCreate`。

## 3. +0x5925903 读的是 rsi，rsi = 那个没被填的 out 参数

`mov rax, [rsi]`，rsi ← `mov rsi,[rsp+40]`（0x59258fe，以及 0x59258cc）。[rsp+40] 只在 **0x59258bc 被 guest 自己写 0**，
唯一可能写它的是 0x59258c3 的被调方 —— 即 `GameInputCreate(IGameInput** out)` 的 out 参数。
所以 0x0 的成因是 **callee 失败且没写出参**（因为 `test eax,eax; js` 已判定它返回 FAILED），而不是"上游别的 call 没填"。

## 4. 上一层 caller

`+0x5925831` 属于 exe+0x59257e0（A，`push rsi; sub rsp,64; mov rsi,rcx`；0x59257d8..df 是 int3 填充 → 0x59257e0 是入口）：

```
exe+0x059257e8  call exe+0x5925920 ; mov byte [rsi+1634],0 ; cmp dword [rsi+1464],3 / ja
exe+0x05925809  call exe+0x59259e0          ; rcx = rsi+1464, edx = 4
exe+0x0592580e  call exe+0x5925880 -> jmp exe+0x5925890: mov rax,[rip→exe+0x71b90a0]; ret   ; 取一个全局
exe+0x05925813  lea r9,[rsi+1360] ; lea r8,[rip→exe+0x2211c80]（那里是代码 push rsi/push rdi…→ 一个回调函数指针）
exe+0x05925821  mov rcx, rax ; mov rdx, rsi
exe+0x05925827  call exe+0x55dcd58          ; (全局对象, this, 回调, this+1360) → 注册
exe+0x0592582c  call exe+0x59258a0          ; ★ F：拿 IGameInput 单例（就是 §1 的停机函数）
exe+0x05925831  mov r10, [rax]              ; ★ 返回地址（栈帧里的 caller 帧）→ 取虚表
exe+0x0592586a  call  qword ptr [r10 + 72]  ; 虚槽 9：rdx=0, r8d=262144(0x40000), r9d=1,
            [rsp+32]=2, [rsp+40]=this, [rsp+48]=另一个回调 exe+0x2211cc0, [rsp+56]=this+1368
```
A 在初始化输入子系统：注册两个回调后向 GameInput 对象发起一次带 256 KB 读缓冲的调用（0x40000 / 1 / 2 是它的参数）。

`+0x2240e95` 属于 exe+0x2240e00 段（启动期子系统初始化，不是输入专有）：

```
exe+0x02240e5a  call exe+0x5b212e0 (rcx=rdi) ; mov rax,[rdi+96] ; test/je ; and rcx,-16 ; call rax   ; 装好对齐栈再调一个回调
exe+0x02240e73  lea rcx,[rip→exe+0x5c92e20]（代码地址，不是字符串）; mov edx,15; call exe+0x5c8fb30
exe+0x02240e84  mov rax,[rip→exe+0x9ab3020] ; lea rcx,[rip→exe+0x9ab3020] ; call qword ptr [rax+8]   ; 对一个全局 AddRef
exe+0x02240e95  call exe+0x3e4f050          ; ★ 返回地址：这一步进到上面的 A（输入初始化）
exe+0x02240e9a  lea rcx,[rip→exe+0x677c98f] ; ★ 该地址处是 .rdata 字符串池："americas."、"Americas."、"#as."、
                                             "BaseTs."、"StHostileTs."、"intervalMs."、"%s%u%s"、"MONTH"…
exe+0x02240ea1  call exe+0x2213940 (rcx="americas.")
```
即：0x2240e95 只是启动序列里"调用输入初始化，然后拿区域名 americas. 继续初始化"的一环，本身与停机无关。

## 5. host 侧对照（为什么 GameInputCreate 会 FAILED）

- `H:\leonida\logs\rt_configure.txt`：`-- GameInput shim not built (LEONIDA_SDL3=OFF)`；`H:\leonida\rt-build\CMakeCache.txt`：
  `LEONIDA_SDL3:BOOL=OFF`、`LEONIDA_SDL3_FETCH:BOOL=OFF` → gameinput.cpp 的 shim 根本没编进 gta6rt。
- `runtime/CMakeLists.txt:459-460`：没有 shim 时 "the loader binds GameInputCreate to **the host's GameInput.dll** or the unimplemented thunk"。
- 本次 dry-run 报告（`H:\leonida\logs\dryrun_ff8ce388.txt`，run 日志同文）：
  `game_scarlett_master.exe … shim=93 host=421 module=72 unimplemented=1`，且唯一的 unimplemented 是 `XCRDAPI.dll!DStorageGetFactory`。
  → GameInputCreate **没有**落到 unimplemented thunk（否则会计数，且 `registry.cpp:187` 会给它 `E_NOTIMPL`＝负的 HRESULT），
    它落在 **host=421 那一类**：绑定到本机 Windows 10 19045 的 GameInput.dll，由 host 返回了 FAILED 的 HRESULT。
  （case 不是问题：`registry.cpp:26/484/506` 一律小写化键名，`GameInput.dll` 与 `gameinput.dll` 等价。）
- XMem 侧与此无关：`runtime/shims/xmem.cpp:9-11` 与 `:380-386` 明说 attribute 字**不解析、只记录**（trace 里的
  `xmem_attributes` 事件来自 `:54-67`，在分配**之前**发出）；失败路径一律 `SetLastError + return nullptr`（`:390-418`、`:490`），
  返回类型是 `PVOID`，不可能产生 guest 判定的 `eax < 0`。`xmem.cpp:69-96` 那段"分配结果日志"是我们自己加的，
  正因为它显示 7/7 成功，才排除了 xmem。

## 6. 最小可验证改动（给 lead 排下一步）

1. 首选：重新 configure 打开 shim，再重编（`H:\leonida\build_only.cmd` 之前要先跑 configure）：
   `-DLEONIDA_SDL3=ON -DLEONIDA_SDL3_FETCH=ON`（`runtime/CMakeLists.txt:461-470`：FETCH 会下载并 hash 校验 SDL3-3.4.20），
   然后 `gta6rt --run … --trace <jsonl>`。预期 0x5925915 的 int3 与 0x5925903 的读 0 同时消失（out 参数被写、全局发布）。
2. 想先不下载 SDL3 的对照实验：在 `runtime/shims/registry.cpp` 的表里让 `gameinput.dll!GameInputCreate` 显式落到
   shim（或用一个不依赖 SDL3 的 stub 写 `*out` 并返回 S_OK），只需证明"断言由这个 import 决定"。注意这是本机验证，不是上游改法。
3. 诊断增强（可选）：dry-run 报告目前只有计数，把 exe 的 `host=` 绑定按 import 名列出来（尤其 `GameInput.dll!ordinal 1`），
   就能直接看到"绑到 host 还是 shim"，不必推。

## 附：工具

`H:\leonida\guest_disasm.py`（只读 package）：`--rva/--from/--to/--len [--att] [--no-annotate] [--sections] [--imports]
[--resolve <RVA>]`。llvm-mc 23.1.6 用 `--disassemble --hex --show-encoding --output-asm-variant=1`（`--disassembler-style`
在 LLVM 20+ 已移除）；它对 rel8/rel32 分支只打印 displacement（fixup 字节不在 encoding 列里），工具按 fixup 宽度补回指令长度，
并把分支/RIP 目标换算成 `exe+0x…`。清单：`H:\leonida\logs\guest_disasm_stop.txt`。
