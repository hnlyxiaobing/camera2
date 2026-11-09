# camera2 · 设计契约（DESIGN.md）

> 实现阶段 + **API 冻结前整改** + **R4 回调 marshal 层** ｜ 状态：MoonBit 层 API 全部实现（桌面 C stub 双路径）；无 Java 样板、无真实 JNI 调用、无设备取帧（排后续真实对接阶段，接口预留见 §15）

## 1. 分层位置与职责

L3 感知绑定层的**帧源 JNI 封装**。职责：相机生命周期 + 取 YUV_420_888 帧 + 帧回调（**marshal 派发**，见 §14）。产出中性 `YuvFrame`，交给组合根按 Wire 契约适配到 `yuv`（跨模块只传纯值、组合根适配，见 `DECISIONS.md`「跨模块契约与组合根适配」）。

## 2. 模块边界 / 依赖方向 / 数据流

```
Java Camera2 / NDK camera2ndk
      ▲ JNI
mb_camera2_*  extern "C" shim（15 个 `mb_camera2_*`，**包私有 ABI，非公共 API**；
      │         当前为项目内桌面 stub；完整契约见 stub/camera2_abi.h）
      ▲
Camera::{open,start_preview,grab_yuv,on_frame,pump_marshal,close}   ← 已实现（MoonBit 层公开 API）
      │
      ▼  camera2::YuvFrame
组合根 ──(Wire 适配)──► yuv::YuvFrame ──► pose
```

本库**不 import `yuv` / `pose`**；它们也不 import 本库。相机可替换为文件帧源 / RTSP / 桌面摄像头。

## 3. 核心数据结构

| 类型 | 作用 |
|---|---|
| `JavaVMPtr` / `JNIEnvPtr` / `JObjectRef` / `CameraHandleRaw` / `ImageReaderRaw` | `#external` 句柄；`JNIEnvPtr` **线程局部、禁止缓存** |
| `Camera { handle, reader, config, state, owner_thread_id }` | MoonBit 侧包装值，记录 owner 线程与状态机 |
| `YuvFrame` / `YuvPlane` | 中性帧值类型（含 row_stride / pixel_stride） |
| `CameraConfig` / `CameraInfo` / `FrameSize` / `Facing` | 打开配置与能力摘要 |
| `CameraState` | **`Open` 单分支**（API 冻结前收紧：删除未被实际代码路径使用的 `Closed`/`Opening`/`Previewing`/`Failed`，不补齐状态机） |
| `CameraError` | **`pub(all) suberror`**（API 冻结前追认，见 `DECISIONS.md`「可替换帧源设计」），13 个错误构造（R4 增 `MarshalReentrant`） |
| `FrameCallback = (YuvFrame) -> Unit` | MoonBit 侧回调类型别名 |
| `FrameSource` trait | `grab_yuv` / `close`，供组合根替换帧源；**方法集已冻结：`grab_yuv(Self)` 无超时参数，超时策略由具体帧源实现自行定义**（见 `DECISIONS.md`「可替换帧源设计」） |

## 4. 错误模型

`CameraError`：`PermissionDenied`、`CameraNotFound`、`OpenFailed`、`PreviewFailed`、`UnsupportedSize`、`UnsupportedFormat`、`BufferAcquireFailed`、`BufferPoolExhausted`、`JniThreadNotAttached`、`MarshalReentrant`（R4：派发期间重入 pump）、`AlreadyOpen`、`AlreadyClosed`、`VendorQuirk`。

全部 `raise CameraError`；`grab_yuv` 超时与缓冲耗尽分别可判，便于上层降级。畸形输入不 panic，错误一律走本枚举（marshal 层失败路径见 §14.5）。

## 5. 资源生命周期

| 资源 | 获取 | 唯一释放点 | 规则 |
|---|---|---|---|
| camera + reader | `mb_camera2_open` / `mb_camera2_create_reader` | `Camera::close` | 只释放一次；失败时逆序释放 |
| Image 缓冲 | `mb_camera2_acquire_frame` | `mb_camera2_release_frame` | **读完必须归还**，否则池耗尽 |
| `#owned` 帧回调闭包 | `mb_camera2_set_frame_callback` | `mb_camera2_clear_frame_callback` / `close` | C 侧 `moonbit_decref`；成对注销 |
| marshal 事件（帧副本） | 投递线程浅拷贝入队 | `pump_marshal` 消费 / `close` 释放 | 有界队列（8），满丢最旧；close 后未派发事件全部释放 |
| `JavaVM*` | `mb_camera2_init` | 进程级 | 只缓存 VM，不缓存 JNIEnv |

`Camera::close` **不会二次释放，重复调用返回明确错误（`AlreadyClosed`）**；未 open / 已 close 的会话由会话存活守卫直接拒绝。

## 6. 线程 / 并发边界（硬约束；完整决策见 `DECISIONS.md`「JNI 线程亲和性与回调所有权」「回调投递线程 → owner 线程 marshal」，机制设计见 §14）

- `JNIEnvPtr` **只在当前线程有效**，禁止缓存、禁止跨线程传递、禁止出现在任何 MoonBit 值类型里；只缓存 `JavaVMPtr`。
- 原生线程回调前须 `AttachCurrentThread`，退出前 `DetachCurrentThread`；长期持有的 Java 对象用 `NewGlobalRef` / `DeleteGlobalRef`。
- **两类线程角色**：**owner 线程**（JNI session owner，`Camera.owner_thread_id`）是唯一执行 MoonBit 闭包的线程；**投递线程**（相机/ImageReader 回调线程）只做浅拷贝入队，**绝不执行 MoonBit 闭包**、不触碰 JNI session、不阻塞。
- **帧回调经 marshal 层派发**：投递线程把浅拷贝帧事件入 C 侧有界队列；owner 线程 `Camera::pump_marshal` 同步派发（每事件恰好一次回调）。
- 全部会话 API（`open` / `start_preview` / `grab_yuv` / `on_frame` / `clear_on_frame` / `pump_marshal` / `close`）**限 owner 线程调用**（错线程 `JniThreadNotAttached`）；`grab_yuv` 同步路径无回调线程问题，但仍校验线程归属。

## 7. 平台约束与外部依赖

- `preferred_target = "native"`（由 `wasm` 调整，理由见 `DECISIONS.md`「preferred_target 由 wasm 改为 native」）；Windows native 需 MSVC；LLVM 后端无 FFI。
- Android：Java Camera2 全版本；NDK `ACameraManager_*` / `AImageReader` 要求 **API 24+**；`AIMAGE_FORMAT_YUV_420_888` 三平面 Y/U/V，Y 的 pixelStride=1，U/V 共享 rowStride/pixelStride。
- 后续依赖：`ajni@0.3.6`、Java 样板、真实 JNI `native-stub` C 文件（**均未引入**，排后续真实对接阶段，门槛见 `DECISIONS.md`「ajni 只作设计参照，真实 JNI 样板排后」）；
  当前 shim 实现仅为项目内 `stub/camera2_stub.c` 桌面 stub，**未链接/下载任何外部库**。

## 8. 外部类型 / 句柄 / 回调签名 / 所有权规则

| 类别 | 声明 | 规则 |
|---|---|---|
| 外部类型 | 5 个 `#external pub type` | C `void*`；MoonBit 不引用计数；**永不跨模块传递** |
| 外部函数 | 15 个 `extern "C" fn mb_camera2_* = "…"`（**包私有，私有实现 ABI、非公共 API**；API 冻结前移出公开 API；契约见 `stub/camera2_abi.h`） | 由 Java 侧 + `native-stub`（后续真实对接，§15）或项目内桌面 stub（当前）提供 |
| 回调签名 | `mb_camera2_set_frame_callback(reader, cb : FuncRef[(() -> Unit) -> Unit], closure : () -> Unit) -> Int` | `FuncRef` 必须**无捕获**；`closure` 用 `#owned(closure)`，C 侧长期持有，注销时 `moonbit_decref`；闭包只由 `mb_camera2_marshal_pump` 在 owner 线程派发 |
| `#borrow` | `mb_camera2_open(camera_id)`、`mb_camera2_acquire_frame(dst)`、`mb_camera2_marshal_next(dst)` | MoonBit 保留缓冲所有权，C 侧只读/填充，不 decref |
| 状态存放 | JavaVM / global ref / attach 状态 / per-thread data | 全部在 C shim 或 `#external` 句柄中，**不装进 MoonBit 闭包** |

> `#borrow(...)` / `#owned(...)` 写在函数声明**之前**的独立属性行（本机探针已验证）。官方默认语义正从 `#owned` 迁移到 `#borrow`，故全部显式标注。

## 9. 可替换性与实现细节不泄漏

上层只看到 `Camera` / `YuvFrame` / `FrameSource`；看不到 JNIEnv、ImageReader、Surface、厂商 quirk。换帧源不改 `yuv` / `pose` 的 API。

## 10. 测试策略

| 层次 | 内容 |
|---|---|
| 黑盒 | 设备取 720p YUV 帧（红米电视 + 外接 UVC）；`close` **不会二次释放，重复调用返回明确错误** |
| 白盒 | stride 非紧凑样本读取；缓冲池耗尽 / 超时注入；回调线程归属断言（闭包只在 owner 线程执行） |
| marshal 并发/竞态 | 多线程投递（投递线程 + owner 并发 push）、重入 pump / 回调内 clear/replace/grab/close、乱序投递 FIFO 线性化、满队列丢最旧、关闭竞态、投递后释放（§14） |
| 错误路径 | 权限拒绝、设备不存在、尺寸/格式不支持、JNI 线程未 attach、`MarshalReentrant`、`pump_marshal` 非法参数；畸形输入不 panic |
| 门禁 | 六道门禁统一口径：`moon clean` / `moon check --deny-warn` / `moon build` / `moon test` / `moon fmt --check` + `moon info` 快照 diff，实测全绿 |

## 11. 验收标准（实现轮）

1. 目标设备取到 720p YUV 帧；2. 每帧缓冲均归还；3. 回调不跨线程触碰 JNI session；4. `moon check --deny-warn` 转绿。

## 12. 未解决问题 / 待验证假设

- `[仍需实测]` **E1 回调线程安全**：MoonBit 运行时在外部线程（相机投递线程 / 被钩线程）执行闭包的线程安全（GC、引用计数、重入）**未实测**（Linux x86-64 pthread 口径，本机 Windows 无法执行）。R4 marshal 层已使本模块 MoonBit 闭包**不在投递线程执行**（设计性绕开，见 §14.6），但 E1 实验本身仍需按 §16 方案实测（`frida_gum_ffi` 等同样依赖该结论）。
- `[待验证假设]` **ajni 真机可用性**：`ajni@0.3.6`（0.x，作者自述 "Windows/macOS desktop ABI support is not claimed"）在 Windows 主机 + 红米电视（Android 9 / armeabi-v7a）的可用性未实证。
- `[待验证假设]` **Camera1 / UVC 回退必要性**：部分 TV 设备只有 Camera1，是否需要 Camera1 / UVC 回退未实测；Camera2 厂商差异范围待一次能力探测确认。

## 13. 当前状态与 TODO

`camera2.mbt` / `internal.mbt` 已写入 5 个 `#external` 句柄、15 个**包私有** shim、值类型、
错误模型与全部 MoonBit 层 API 实现（状态守卫 / 错误映射 / YUV 解析校验）；公开 API 有 `///` 文档注释。
**API 冻结前整改已落实**：`FrameSource` 方法集冻结（trait 层无超时参数）、
`CameraError` 追认 `pub(all) suberror`、`CameraState` 收紧为 `Open`、
shim 移出公开 API、close 幂等措辞统一（汇总见 `DECISIONS.md`「API 冻结前的公开面整改」）。
**R4 已落实**：回调 marshal 层（§14）——投递线程零 MoonBit、owner 线程 `pump_marshal` 派发、
有界队列 keep-latest、重入/关闭竞态收敛 C 侧；并发/竞态/错误路径白盒测试 30/30 全绿。
**仍无** Java 样板、真实 JNI、设备取帧（排后续真实对接阶段，接口预留见 §15；ajni 真机可用性未实证，见 §12）。

## 14. 回调 marshal 层设计（R4：投递线程 → owner 线程）

> ADR-0009「线程与回调所有权」Decision 4 的落地机制。实现 = `stub/camera2_stub.c` marshal
> 队列 + `mb_camera2_marshal_pump` / `mb_camera2_marshal_next` + `Camera::pump_marshal`
> + `Camera::on_frame` thunk；测试白盒清单见 `camera2_wbtest.mbt`。

### 14.1 线程角色

| 角色 | 职责 | 禁止 |
|---|---|---|
| **owner 线程**（JNI session owner，`Camera.owner_thread_id`） | 唯一执行 MoonBit 闭包的线程；`Camera::pump_marshal` 同步派发；全部会话 API 的合法调用线程 | — |
| **投递线程**（相机 / ImageReader 回调线程；threaded stub 独立线程） | 浅拷贝帧数据入 marshal 队列（纯 C）；置停止标志 | **执行 MoonBit 闭包**、触碰 JNI session、阻塞、保存栈上指针 |

C 侧全局递归锁把所有队列操作串行化；投递线程与 owner 线程的并发 push/pump 在锁内线性化。

### 14.2 队列与所有权转移

- 每 reader 一个**有界 FIFO**（`MAX_MARSHAL = 8`），事件 = {打包帧 malloc 副本, len, seq}；
  seq 在入队锁内单调分配（乱序并发 push 的线性化序号）。
- 所有权链：投递线程产帧 → **malloc 副本**（C 侧持有）→ 入队 → pump 出队为暂存槽
  （staged）→ thunk 经 `mb_camera2_marshal_next`（两段式，`#borrow(dst)`）拷入 MoonBit
  `FixedArray` → C 立即 free 副本 → `parse_yuv_frame` 构造纯值 `YuvFrame`。
  **MoonBit 值只在 owner 线程构造**，跨线程只传 C 内存。
- 满队列：**丢最旧（keep-latest）**+ `mq_dropped` 计数（可观测）；无注册回调时 pump
  丢弃排水（队列恒有界前进）。
- 帧路径互斥（stub 语义）：已注册回调时帧走 marshal 队列（模拟 ImageReader listener
  消费），不入 pending；未注册时入 pending 供 `grab_yuv` 同步消费——两路径确定性。

### 14.3 重入与乱序处理

- **乱序**：并发 push 在锁内线性化，出队 FIFO = 线性化顺序；派发序列时间戳严格递增
  （测试「out-of-order concurrent pushes dispatch in linearized FIFO order」断言）。
- **重入 pump**：`dispatch_depth > 0` 时再次 `pump_marshal` → -15 →
  `CameraError::MarshalReentrant`（拒绝交错派发；外层 pump 不受影响、继续派发完）。
- **回调内重入其它 API（安全支持）**：`grab_yuv`（递归锁）、`on_frame`（替换注册）、
  `clear_on_frame`、`close`。闭包 RC 由「派发前 `moonbit_incref` + callee owned 约定
  作用域末 decref」保护——替换/注销**正在执行**的闭包不会 use-after-free。
- **thunk 不消费**（解析失败 / 异常路径）：暂存事件被强制丢弃，队列保证前进（不卡死、
  不重复派发）；解析失败不调用回调（回调无错误通道，静默丢帧为既定语义）。

### 14.4 关闭 / 释放竞态

- `Camera::close` **限 owner 线程**（跨线程 close → `JniThreadNotAttached`）——从根上
  消除 close 与 pump 派发的跨线程竞态（两者同线程串行）。
- **派发期间 close（回调内 close）**：C 侧置 `closed=1`（`session_alive` 即刻判死）+
  `close_pending`；reader/cam 结构体**延迟到本次 pump 收尾**统一拆除（防闭包返回后
  UAF）。对 MoonBit 调用方语义即时生效：后续操作一律 `AlreadyClosed`。
- **投递后释放**：close 时 marshal 队列 / staged 事件全部 free（不派发、不泄漏）；
  `#owned` 闭包注销 / 替换 / 关闭时 `moonbit_decref`，成对不泄漏
  （`stub_marshal_live_events` / `stub_live_closures` 断言归零）。
- 重复 close：MoonBit `AlreadyClosed` 守卫 + C 层 `closed` 标记双保险，不会二次释放。

### 14.5 失败路径（全部可判，畸形输入不 panic）

| 场景 | 行为 | 错误 / 观测 |
|---|---|---|
| 会话未存活时 pump | 拒绝 | `AlreadyClosed` |
| 非 owner 线程 pump / close | 拒绝 | `JniThreadNotAttached` |
| 派发期间重入 pump | 拒绝 | `MarshalReentrant` |
| `max_events < 1` | 拒绝 | `OpenFailed(-13, _)` |
| 事件载荷畸形（解析失败） | 丢弃该事件、不调用回调、队列前进 | 不抛（回调无错误通道） |
| 满队列溢出 | 丢最旧 + 计数 | 不抛，`mq_dropped` 可观测 |
| push malloc 失败 | 该帧丢弃 | 不抛（投递侧无错误通道） |
| `marshal_next` 非派发期间误用 / 无暂存 | 负数返回 | 不 panic（内部契约，白盒测试覆盖） |

### 14.6 E1 缺口的处理口径

本层使 camera2 的 MoonBit 闭包**永远不在投递线程执行**（投递线程只跑纯 C），从而把
E1（MoonBit 运行时在外部线程执行闭包的线程安全）对本模块的暴露面**设计性绕开**；
本地 Windows native 并发测试已实测「闭包只在 owner 线程执行」的机制正确性。
**E1 实验本身（Linux x86-64 pthread 口径）未执行、[仍需实测]**，最小实验方案见 §16；
`frida_gum_ffi` 被钩线程回调同样应采用本 marshal 模式并等待 E1 结论。

## 15. 真实 JNI 对接接口预留（E4 解禁后 P1；本轮只做设计，不接设备/JNI）

### 15.1 真实 JNI native-stub C 文件

- **ABI 冻结**：`stub/camera2_abi.h` 即契约——真实 native-stub 实现同一批 `mb_camera2_*`
  符号（9 核心 + 2 marshal + 4 内部），MoonBit 侧 extern 声明**零改动**。
- 职责映射（与桌面 stub 同构）：`mb_camera2_init` 缓存 `JavaVM*`（只缓存 VM）；投递侧 =
  Java `ImageReader.OnImageAvailableListener` → JNI native 回调（投递线程）→ 按
  `rowStride/pixelStride` 逐平面**浅拷贝**为打包帧 → `marshal_push`（**不执行 MoonBit
  闭包**）；owner 线程 `pump_marshal` 派发语义不变。
- 生命周期：`NewGlobalRef` 持有 `CameraDevice` / `CameraCaptureSession` / `ImageReader` /
  `Surface` Java 对象；`mb_camera2_close` 逆序 `DeleteGlobalRef` + close；native 线程
  attach / detach 状态由 C 侧管理（ADR-0009 Decision 1/2）。
- 入库红线：真实 `.so` / devkit 不入库（ADR-0011 口径），本地链接 + SHA-256 +
  PROVENANCE 登记；`stub/camera2_stub.c` 保持可移植桌面回退。

### 15.2 Java Camera2 样板（约 200 行，设计预留）

- 类骨架 `Camera2Bridge`：静态 native 方法声明 + `CameraManager` 枚举 +
  `CameraDevice.StateCallback` 打开 + `CameraCaptureSession` 重复预览请求 +
  `ImageReader.newInstance(w, h, ImageFormat.YUV_420_888, maxImages)`。
- 线程：专用 `HandlerThread` 作相机回调线程（投递线程）；owner 线程 = 调用
  `Camera::open` 的 JNI 线程。`OnImageAvailableListener.onImageAvailable` 只做
  acquire → 浅拷贝 → `image.close()` → native push。
- 权限 / 生命周期：`CAMERA` 权限缺失返回 `ST_PERMISSION`（→ `PermissionDenied`）；
  Activity 生命周期 `onPause/onDestroy` 挂钩 `Camera::close`。

### 15.3 `ajni@0.3.6` host bridge（可选依赖，五条门槛评估后引入）

- 角色：host 侧 JavaVM 获取 / Attach 管理 + 类型安全 JNI 转发；其契约
  （`Cache JavaVM, never JNIEnv`、global ref 归 C 持有）与 ADR-0009 一致。
- 门槛（DECISIONS.md §4）：0.x 无稳定承诺、"Windows/macOS desktop ABI support is not
  claimed"、目标设备（Android 9 / armeabi-v7a）未实证——引入前须 E4 实机验证 +
  用途/许可/维护/平台/风险五条评估。
- 替代：不引 ajni、自写最小 JNI 胶水（工作量大、attach/global ref 易错）；
  本轮维持「ajni 只作设计参照」（DECISIONS.md §4）。

## 16. E1 最小实验方案（**[仍需实测]**，Linux x86-64 native 口径）

**目标**：验证 MoonBit 运行时（GC、引用计数、重入）在非 MoonBit 线程上执行无捕获
`FuncRef` 与 `#owned` 闭包的线程安全（`docs/open-questions.md` E1，P0）。

**环境**：Linux x86-64；`moon 0.1.20261104` / `moonc v0.10.20+65efd5b93`（`VERSION-LOCK.md`
口径）；`preferred_target = "native"`；GCC 或 Clang + pthread。

**步骤（最小可执行）**：

1. 一次性探针模块（不入 11 模块仓库）：`moon.mod` `preferred_target = "native"`，
   `moon.pkg` `native-stub` 指向 pthread C 文件（模式照抄 `stub/camera2_stub.c`）。
2. C 侧起 4 个 pthread，每个反复（≥ 10⁶ 次）调用两类目标：① 无捕获 `FuncRef` 适配器
   `fn(f) { f() }` + `#owned` 闭包（闭包内大量临时对象构造/丢弃以触发 GC 与 RC 操作）；
   ② 闭包内再调闭包（重入场景）。
3. 主线程并发 `set/clear/replace`（`moonbit_incref` / `moonbit_decref` 成对），制造
   RC 竞争（对应相机 on_frame/clear/close 竞态）。
4. 观测：ASan / TSan 数据竞争报告、valgrind、进程存活与结果一致性、退出后 RC 归零
   （无泄漏 / 无 double-free）。
5. 判定：无崩溃 + 无 sanitizer 报告 + RC 归零 = E1 通过；任一异常 = 固定复现步骤，
   回调设计维持 marshal（本模块现状即该回退形态）。

**本机（Windows）无法执行该口径**（Linux pthread + Linux native 运行时差异）；本机
等价覆盖仅为「闭包不在投递线程执行」的机制测试（§14.6，`moon test` 30/30），
**E1 实验整体 [仍需实测]**，登记于回报未决项。

## References

`DECISIONS.md`（本仓库设计决策记录） · `stub/camera2_abi.h`（shim ABI 契约） · `https://docs.oracle.com/en/java/javase/24/docs/specs/jni/invocation.html` · `https://mooncakes.io/docs/Nanaloveyuki/ajni` · NDK `NdkImage.h`
