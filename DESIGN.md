# camera2 · 设计契约（DESIGN.md）

> Round-1.5 实现轮 + **冻结前 P0 整改（R2 准备轮）** ｜ 状态：MoonBit 层 API 全部实现（桌面 C stub 双路径）；无 Java 样板、无真实 JNI 调用、无设备取帧（留待 R2）

## 1. 分层位置与职责

L3 感知绑定层的**帧源 JNI 封装**。职责：相机生命周期 + 取 YUV_420_888 帧 + 帧回调。产出中性 `YuvFrame`，交给组合根按 Wire 适配到 `yuv`（ADR-0002）。

## 2. 模块边界 / 依赖方向 / 数据流

```
Java Camera2 / NDK camera2ndk
      ▲ JNI
mb_camera2_*  extern "C" shim（9 个，**包私有 ABI，非公共 API**；本轮为项目内桌面 stub）
      ▲
Camera::{open,start_preview,grab_yuv,on_frame,close}   ← 已实现（MoonBit 层公开 API）
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
| `CameraState` | **`Open` 单分支**（冻结前 P0 决策 5：删除未被实际代码路径使用的 `Closed`/`Opening`/`Previewing`/`Failed`，不补齐状态机） |
| `CameraError` | **`pub(all) suberror`**（决策 4 追认），12 个错误构造 |
| `FrameCallback = (YuvFrame) -> Unit` | MoonBit 侧回调类型别名 |
| `FrameSource` trait | `grab_yuv` / `close`，供组合根替换帧源；**方法集已冻结（决策 3 方案 A）：`grab_yuv(Self)` 无超时参数，超时策略由具体帧源实现自行定义** |

## 4. 错误模型

`CameraError`：`PermissionDenied`、`CameraNotFound`、`OpenFailed`、`PreviewFailed`、`UnsupportedSize`、`UnsupportedFormat`、`BufferAcquireFailed`、`BufferPoolExhausted`、`JniThreadNotAttached`、`AlreadyOpen`、`AlreadyClosed`、`VendorQuirk`。

全部 `raise CameraError`；`grab_yuv` 超时与缓冲耗尽分别可判，便于上层降级。

## 5. 资源生命周期

| 资源 | 获取 | 唯一释放点 | 规则 |
|---|---|---|---|
| camera + reader | `mb_camera2_open` / `mb_camera2_create_reader` | `Camera::close` | 只释放一次；失败时逆序释放 |
| Image 缓冲 | `mb_camera2_acquire_frame` | `mb_camera2_release_frame` | **读完必须归还**，否则池耗尽 |
| `#owned` 帧回调闭包 | `mb_camera2_set_frame_callback` | `mb_camera2_clear_frame_callback` / `close` | C 侧 `moonbit_decref`；成对注销 |
| `JavaVM*` | `mb_camera2_init` | 进程级 | 只缓存 VM，不缓存 JNIEnv |

`Camera::close` **不会二次释放，重复调用返回明确错误（`AlreadyClosed`）**；未 open / 已 close 的会话由会话存活守卫直接拒绝。

## 6. 线程 / 并发边界（ADR-0009，硬约束）

- `JNIEnvPtr` **只在当前线程有效**，禁止缓存、禁止跨线程传递、禁止出现在任何 MoonBit 值类型里；只缓存 `JavaVMPtr`。
- 原生线程回调前须 `AttachCurrentThread`，退出前 `DetachCurrentThread`；长期持有的 Java 对象用 `NewGlobalRef` / `DeleteGlobalRef`。
- **帧回调在相机投递线程触发**，`Camera.owner_thread_id` 记录 session owner；回调必须浅拷贝帧数据后 marshal 到 owner 线程，**不得**在回调内直接做 JNI 调用、阻塞或保存栈上指针。
- `Camera::open` 必须在 JNI session 的 owner 线程调用。
- `grab_yuv` 同步路径无回调线程问题，但仍须校验 session 线程归属。

## 7. 平台约束与外部依赖

- `preferred_target = "native"`（本轮调整）；Windows native 需 MSVC；LLVM 后端无 FFI。
- Android：Java Camera2 全版本；NDK `ACameraManager_*` / `AImageReader` 要求 **API 24+**；`AIMAGE_FORMAT_YUV_420_888` 三平面 Y/U/V，Y 的 pixelStride=1，U/V 共享 rowStride/pixelStride。
- 后续依赖：`ajni@0.3.6`、Java 样板、真实 JNI `native-stub` C 文件（**均未引入**，留待 R2）；
  本轮 shim 实现仅为项目内 `stub/camera2_stub.c` 桌面 stub，**未链接/下载任何外部库**。

## 8. 外部类型 / 句柄 / 回调签名 / 所有权规则

| 类别 | 声明 | 规则 |
|---|---|---|
| 外部类型 | 5 个 `#external pub type` | C `void*`；MoonBit 不引用计数；**永不跨模块传递** |
| 外部函数 | 9 个 `extern "C" fn mb_camera2_* = "…"`（**包私有，私有实现 ABI、非公共 API**；冻结前 P0 决策 6 移出公开 API） | 由 Java 侧 + `native-stub`（R2）或项目内桌面 stub（本轮）提供 |
| 回调签名 | `mb_camera2_set_frame_callback(reader, cb : FuncRef[(() -> Unit) -> Unit], closure : () -> Unit) -> Int` | `FuncRef` 必须**无捕获**；`closure` 用 `#owned(closure)`，C 侧长期持有，注销时 `moonbit_decref` |
| `#borrow` | `mb_camera2_open(camera_id)`、`mb_camera2_acquire_frame(dst)` | MoonBit 保留缓冲所有权，C 侧只读/填充，不 decref |
| 状态存放 | JavaVM / global ref / attach 状态 / per-thread data | 全部在 C shim 或 `#external` 句柄中，**不装进 MoonBit 闭包** |

> `#borrow(...)` / `#owned(...)` 写在函数声明**之前**的独立属性行（本机探针 P5 已验证）。官方默认语义正从 `#owned` 迁移到 `#borrow`，故全部显式标注。

## 9. 可替换性与实现细节不泄漏

上层只看到 `Camera` / `YuvFrame` / `FrameSource`；看不到 JNIEnv、ImageReader、Surface、厂商 quirk。换帧源不改 `yuv` / `pose` 的 API。

## 10. 测试策略

| 层次 | 内容 |
|---|---|
| 黑盒 | 设备取 720p YUV 帧（红米电视 + 外接 UVC）；`close` **不会二次释放，重复调用返回明确错误** |
| 白盒 | stride 非紧凑样本读取；缓冲池耗尽 / 超时注入；回调线程归属断言 |
| 错误路径 | 权限拒绝、设备不存在、尺寸/格式不支持、JNI 线程未 attach |
| 门禁 | 四道门禁统一口径：`moon check --deny-warn` / `moon build` / `moon test` / `moon fmt --check`（另加 `moon clean`），冻结前 P0 实测全绿 |

## 11. 验收标准（实现轮）

1. 目标设备取到 720p YUV 帧；2. 每帧缓冲均归还；3. 回调不跨线程触碰 JNI session；4. R4 `--deny-warn` 转绿。

## 12. 未解决问题 / 待验证假设

- **E1（P0）**：MoonBit 运行时在相机投递线程执行闭包的线程安全未实测。
- **E4（P1）**：ajni / android_runtimebinding 在 Windows 主机 + 红米电视的可用性。
- Q9：Camera1 / UVC 回退是否必需；Camera2 厂商差异范围。

## 13. 当前状态与 TODO

`camera2.mbt` / `internal.mbt` 已写入 5 个 `#external` 句柄、9 个**包私有** shim、值类型、
错误模型与全部 MoonBit 层 API 实现（状态守卫 / 错误映射 / YUV 解析校验）；公开 API 有 `///` 文档注释。
**冻结前 P0（R2 准备轮）已落实**：决策 3（`FrameSource` 方法集冻结、trait 层无超时参数）、
决策 4（`CameraError` 追认 `pub(all) suberror`）、决策 5（`CameraState` 收紧为 `Open`）、
决策 6（9 个 shim 移出公开 API）、决策 8（close 幂等措辞统一）。
**仍无** Java 样板、真实 JNI、设备取帧（R2 / open-questions E4）。

## References

`../docs/adr/ADR-0004`、`ADR-0007`、`ADR-0009` · `https://docs.oracle.com/en/java/javase/24/docs/specs/jni/invocation.html` · `https://mooncakes.io/docs/Nanaloveyuki/ajni` · NDK `NdkImage.h`
