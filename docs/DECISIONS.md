# camera2 · 设计决策记录（DECISIONS.md）

> 本文件记录本库的设计决策，已改写为自足条目，按「背景 → 决策 → 理由 → 后果」
> 记录本库的关键设计取舍。条目内**不引用仓库外的任何文件**；事实依据为公开规范、官方文档与本机实测。

## 1. JNI 线程亲和性与回调所有权

### 背景

Oracle JNI 规范（Java SE 24，第 5 章）`[事实]`：

- `JNIEnv*` **只在当前线程有效**，不可缓存、不可跨线程共享；只缓存 `JavaVM*`。
- 原生线程须 `AttachCurrentThread` 取得自己的 `JNIEnv`，退出前 `DetachCurrentThread`；「A thread cannot detach itself if there are Java methods on the call stack」。
- 局部引用仅本次 native 调用、当前线程有效；跨线程长期持有对象须 `NewGlobalRef` / `DeleteGlobalRef`。
- 原生线程裸 `FindClass` 会退回系统 classloader，找不到应用类。

`ajni@0.3.6` 的契约与之一致：`Cache JavaVM, never JNIEnv`、`Raw JNIEnv*/jobject/Java attachment remain C-owned`、`Public objects retain global references`、`Arrays copy regions, never pin Java memory across a callback`；其 event handler 明确 "process-wide, **non-thread-safe**, require main-thread registration/removal/dispatch"。

同时 `[事实]`：

- Camera2 的 `ImageReader` 帧回调在**相机投递线程**触发；`AIMAGE_FORMAT_YUV_420_888` 三平面按 `rowStride/pixelStride` 读取，不可假设紧凑布局。
- MoonBit `FuncRef[T]` 只能是**无捕获**闭包（捕获变量报 E4151）；C 后端映射函数指针。带捕获状态的回调须表示为「函数 + 环境对象」二元组。

三者叠加的硬冲突：回调需要的 `JavaVM*` / global ref / attach 状态**不能**装进 MoonBit 闭包，而回调又发生在与 JNI session owner 不同的线程上。

### 决策

1. **只缓存 `JavaVM*`**：声明 `#external pub type JavaVMPtr` 与 `mb_camera2_init(vm)`；`JNIEnvPtr` 被明确标注"线程局部、禁止缓存、禁止跨模块传递"，且**不出现在任何 MoonBit 值类型里**。
2. **回调状态下沉 C 侧**：帧回调的 JavaVM、global ref、attach 状态、per-thread data 全部保存在 C shim 或 `#external` 句柄中；MoonBit 侧只提供 `FuncRef` 无捕获适配器 + 一个 `#owned` 闭包。
3. **回调签名固定为二元组**：`extern "C" fn ...(cb : FuncRef[(() -> Unit) -> Unit], closure : () -> Unit)`，并用 `#owned(closure)` 标注——C 侧长期持有闭包，注销时由 shim 执行 `moonbit_decref`。成对提供 `set_*_callback` / `clear_*_callback`。
4. **marshal 到 owner 线程**：帧回调内**禁止**直接调用 JNI、禁止阻塞、禁止跨线程保存栈上指针；必须浅拷贝数据后投递到 owner 线程。`Camera` 记录 `owner_thread_id`，`API.md` 与 `DESIGN.md` 明确写出该约束。
5. **缓冲所有权**：`acquire_frame` 用 `#borrow(dst)`（MoonBit 持有缓冲），读完必须 `release_frame` 归还，否则缓冲池耗尽；错误模型里保留 `BufferPoolExhausted` / `JniThreadNotAttached`。
6. **每个 API 在文档注释里写明线程约束**，而不是只写在总体文档里——保证实现者按签名即可看到边界。

### 理由

被替代方案：

1. 用 MoonBit 闭包捕获 JavaVM 句柄——**否决**：`FuncRef` 禁止捕获，跨线程 `JNIEnv` 非法。
2. 在回调线程直接 `AttachCurrentThread` 并立即调 Java——**否决**：ajni handler 非线程安全，且 detach 与 Java 栈冲突。
3. 把 `JNIEnv` 存进 `Camera` 结构体——**否决**：`JNIEnv` 线程局部，缓存即 bug。

### 后果

**正面**：把 JNI 与 MoonBit 运行时的两个最危险约束显式编码进类型与所有权标注；回调不会因跨线程 JNIEnv 或悬空闭包崩溃；`#borrow`/`#owned` 全部显式标注，规避官方"默认语义正在从 owned 迁移到 borrow"的升级风险。

**负面**：C shim 不再"极薄"——它必须承担线程 attach、global ref、闭包引用计数与 marshal。「胶水 C 文件极薄」的说法应修正为「**胶水薄在 ABI 转发，厚在生命周期与线程编排**」，这会增加实现与测试成本。

## 2. preferred_target 由 wasm 改为 native

### 背景

骨架初始 `preferred_target = "wasm"`。本机探针实测（2026-11-06）：在 wasm 目标下写 `extern "C" fn` 会报 `E4156 extern "C" is unsupported in wasm backend`；把 `preferred_target` 改为 `native` 后 `moon check` 通过。官方约束 `[事实]`：Windows native 后端需 MSVC `cl.exe`/`clang-cl.exe`，MinGW 不支持；LLVM 后端不支持 FFI。

### 决策

`../moon.mod` 的 `preferred_target` 从 `"wasm"` 改为 `"native"`。**这是唯一配置改动**，不改目录结构、不改 `../moon.pkg`、不改其它字段。理由：本库的价值就是外部 C ABI，wasm 目标下无法表达其接口。`moon check` 生成的 API 快照 `../pkg.generated.mbti` 保留在版本库中作为评审依据。

### 理由

被替代方案：

1. 保持 wasm 并在本库不写 `extern "C"`——**否决**：无法表达外部接口，违背"FFI/JNI 项目只声明外部接口与句柄"的定位。
2. 用 `supported_targets = "native"` 而不改 `preferred_target`——**否决**：wasm 检查会直接跳过该包，声明根本不被校验。

### 后果

`extern "C"` / `#external` / `#borrow` / `#owned` / `FuncRef` 声明得以被真实编译器检查；`moon check --deny-warn` 通过（`0068 declaration_unimplemented` 已随实现清零）；`moon build` / `moon test` 在 Windows + MSVC 下真实编译、链接、运行。`preferred_target` 会影响 `moon run` / `moon build` 的默认后端，CI 与该设置保持一致。

## 3. 可替换帧源设计（FrameSource trait）

### 背景

感知链是「取帧 → 姿态推理 → 渲染」，相机只是帧来源之一。若把相机写成上层的硬前置，会：① 逼迫桌面验证依赖真实设备；② 让换帧源（本地图片 / RTSP / 桌面摄像头）变成改上层 API；③ 在「门面持有 trait、后端实现 trait」的布局下制造双向依赖循环。另要求不泄漏实现细节（JNIEnv、ImageReader、Surface、厂商 quirk）。

### 决策

- `camera2` 只暴露 `Camera` / `YuvFrame` / `FrameSource`，**不 import `yuv` / `pose`，也不被它们 import**；上层通过组合根把 `YuvFrame` 按纯值契约（Wire 值）适配到 `yuv`。
- `FrameSource` trait **方法集冻结**：`grab_yuv(Self) -> YuvFrame raise CameraError`、`close(Self) -> Unit raise CameraError`；trait 层**不提供超时参数**，超时策略由具体帧源实现自行定义（`Camera::grab_yuv(self, timeout_ms)` 自带超时；文件帧源可无限等待）。冻结后给 trait 方法增删参数即破坏性变更。
- `CameraError` 为 `pub(all) suberror`：组合根替换帧源需要在包外构造/抛出错误。
- `close` 语义统一：**不会二次释放，重复调用返回明确错误**（本库 `Camera` 实现返回 `AlreadyClosed`）。

### 理由

trait object 调用的一次间接跳转对 5–15 fps 的体感预算可忽略；换帧源不改 `yuv` / `pose` 的 API；冻结方法集使破坏性变更的界限明确。被替代方案：

1. 上层直接 import 本库并 if/else 分发帧源——**否决**：绑定死、泄漏实现细节。
2. trait 层带超时参数——**否决**：文件帧源等实现被迫伪造超时语义。

### 后果

`pose` / `yuv` 可用 Mock / 文件帧源做纯 MoonBit 桌面验证，无需设备；组合根多一个薄适配器文件；`YuvFrame` 与 `yuv::YuvFrame` 结构一致但各自定义，结构漂移风险靠 API 快照（`../pkg.generated.mbti`）与组合根测试守住。

## 4. ajni 只作设计参照，真实 JNI 样板排后

### 背景

mooncakes.io 上存在 `Nanaloveyuki/ajni@0.3.6`（Apache-2.0，双向 checked JNI + Android host bridge），它已把 JNIEnv 线程亲和性、global ref、native 线程 attach 编码进契约，重复实现风险极高。但它是 **0.x**，要求特定 NDK / SDK / MoonBit 版本，作者自述 "Windows/macOS desktop ABI support is not claimed"，仅特定平台有实证。依赖引入须同时满足五条门槛：**用途**（解决哪层哪能力、现有模块无法更小代价覆盖）、**许可**（SPDX 核验、与 Apache-2.0 兼容、静态链接/再分发义务列明）、**维护**（版本、owner、build_status、是否 legacy manifest）、**平台**（supported_targets 与目标后端一致、不破坏独立 `moon check`）、**风险**（登记待验证项、给出替代方案与移除成本）。

### 决策

- 当前**零外部依赖**：9 个 `mb_camera2_*` shim 由项目内 `../stub/camera2_stub.c` 桌面 stub 提供，**未链接/下载任何外部库**。
- `ajni@0.3.6` 只作**设计参照**：本库线程边界（见 §1）借鉴其契约，但不引入依赖。
- Java 侧约 200 行 Camera2 样板、真实 `native-stub` C 文件、`ajni` 依赖均排在**后续真实 JNI 对接阶段**；引入前须过五条门槛评估并完成真机实证。

### 理由

ajni 为 0.x 无稳定承诺、桌面 ABI 不承诺、目标平台组合（Windows 主机 + Android 9 / armeabi-v7a 目标设备）未实证；而桌面 stub 足以让 21 个测试在无设备环境全绿。被替代方案：

1. 现在就引入 ajni——**否决**：引入网络/版本耦合，且真机可用性未实证。
2. 现在自研完整 JNI 样板——**否决**：工作量前置，且无设备可验证。

### 后果

仓库保持独立 `moon check` / `moon test`；9 个 `mb_camera2_*` shim 的符号名与签名即真实对接 ABI，后续对接无需改 ABI；真实对接的工作量后移但未消失。平台/许可注意：Android SDK / NDK 二进制受 SDK License 3.4 约束**不可再分发**；ajni 为 Apache-2.0，与本仓库兼容。

## 5. 跨模块契约与组合根适配

### 背景

若把「取帧 → 推理」链按字面实现成编译期依赖（`camera2` → `yuv` → `pose`），会出现双向依赖循环，且把中间模块变成中心节点。

### 决策

跨模块只传**纯值**（Wire 契约：Frame / Rgb / Blob / Tensor / Handle 五类，均为 `{ width, height, format, Bytes, timestamp }` 一类纯值）；各模块**自带同构值类型**、零互相 import；由**组合根**（App 工程里的适配代码）负责 ① 用纯值在模块间构造目标类型 ② 注入后端实现 ③ 编排生命周期 ④ 把下层错误映射为上层诊断。

### 理由

消除依赖循环；`pose` 可用 Mock 后端做纯 MoonBit 单测；上层 API 完全稳定；换后端只需新增一个组合根适配器。

### 后果

组合根需要少量显式适配代码；`YuvFrame` 等同构值类型在两个模块里各定义一次，存在结构漂移风险——靠 API 快照对比与组合根测试守住。

## 6. 开发排序：相机不是姿态门面的前置

### 背景

早期规划把相机列为感知闭环的最先置项，但最小验证场景（本地图片 + Mock 后端）即可在桌面验证「取帧 → 推理」链路，不需要真实相机。

### 决策

`camera2` 不排在最前：本地图片 + Mock 后端先验证上层链路；相机作为**可替换帧源**随后接入。

### 理由

相机是可替换帧源（见 §3），不是 `pose` 的前置；避免桌面验证被设备、权限与厂商差异阻塞。被替代方案「先做相机再做门面」的风险是组合根需一段帧适配代码——已由 §5 的 Wire 适配覆盖。

### 后果

桌面阶段即可产出可验证证据；相机接入只需组合根换注入实现，上层 API 不变。

## 7. API 冻结前的公开面整改（已落实）

冻结前对公开面做了以下收敛，冻结后恢复即为破坏性变更：

1. **`FrameSource` 方法集冻结**（见 §3）：`grab_yuv(Self)` / `close(Self)`，trait 层无超时参数。
2. **`CameraError` 追认 `pub(all) suberror`**（见 §3）：包外可构造/匹配/抛出；初版起即如此，冻结前正式追认。
3. **`CameraState` 收紧为 `Open` 单分支**：删除未被实际代码路径使用的 `Closed` / `Opening` / `Previewing` / `Failed`，不补齐状态机；`Camera::open` 是唯一写入点，句柄存活裁决在 C 侧会话注册表。属允许的「删除死接口」类公开面变化。
4. **9 个 `mb_camera2_*` shim 移出公开 API**：改为包私有，作为私有实现 ABI；实现与内部调用全部保留，符号名与签名不变。
5. **`close` 幂等措辞统一**为「不会二次释放，重复调用返回明确错误」。

## 参考（公开规范 / 官方文档）

- Oracle JNI 规范（Java SE 24，Invocation API / 第 5 章）：<https://docs.oracle.com/en/java/javase/24/docs/specs/jni/invocation.html>
- MoonBit FFI 文档（`#external`、`extern "C"`、`#borrow`/`#owned`、`FuncRef`）：<https://docs.moonbitlang.com/en/latest/language/ffi.html>
- `ajni`（0.3.6）包文档：<https://mooncakes.io/docs/Nanaloveyuki/ajni>
- Android NDK 媒体接口（`AImageReader` / `NdkImage.h`，camera2ndk API 24+）：<https://developer.android.google.cn/ndk/reference/group/media>
