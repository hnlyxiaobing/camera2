# camera2 · 公开 API（API.md）

> 与 `pkg.generated.mbti` 一致。`declare` 函数**无实现**（预期 `0068`）；`extern "C"` 只有声明。
> `preferred_target = "native"`。错误传播统一 `raise CameraError`。

## 外部句柄（`#external` = C `void*`）

| 句柄 | 约束 | 释放点 |
|---|---|---|
| `JavaVMPtr` | 进程级可缓存 | 不释放 |
| `JNIEnvPtr` | **线程局部，禁止缓存 / 跨线程传递 / 放入 MoonBit 值类型** | 不释放 |
| `JObjectRef` | 长期持有须 `NewGlobalRef` | `DeleteGlobalRef`（C 侧） |
| `CameraHandleRaw` | C 侧相机句柄 | `Camera::close` |
| `ImageReaderRaw` | C 侧 reader 句柄 | `Camera::close` |

## 外部 C shim 声明（9 个）

| shim | 所有权 / 回调 | 语义 |
|---|---|---|
| `mb_camera2_init(vm : JavaVMPtr) -> Int` | — | 缓存 JavaVM，不缓存 JNIEnv；open 前调用一次 |
| `mb_camera2_open(camera_id : Bytes, width, height, max_buffers) -> CameraHandleRaw` | `#borrow(camera_id)` | 打开相机 |
| `mb_camera2_create_reader(camera, width, height, max_buffers) -> ImageReaderRaw` | — | 创建 YUV_420_888 reader |
| `mb_camera2_start_preview(camera, reader) -> Int` | — | 重复预览请求 |
| `mb_camera2_acquire_frame(reader, dst : FixedArray[Byte], capacity, timeout_ms) -> Int` | `#borrow(dst)` | C 侧填充「3 段 plane + stride 头」 |
| `mb_camera2_release_frame(reader) -> Unit` | — | **读完必须调用** |
| `mb_camera2_set_frame_callback(reader, cb : FuncRef[(() -> Unit) -> Unit], closure : () -> Unit) -> Int` | `#owned(closure)` | `FuncRef` 无捕获；C 侧长期持有闭包 |
| `mb_camera2_clear_frame_callback(reader) -> Unit` | — | 注销并 `moonbit_decref` |
| `mb_camera2_close(camera, reader) -> Unit` | — | **唯一释放点**，且只能一次 |

## 值类型 / 错误 / 契约

`Camera` · `CameraState` · `CameraConfig` · `CameraInfo` · `FrameSize` · `Facing` · `YuvFrame` · `YuvPlane` · `CameraError`（`pub suberror`，12 个构造）· `FrameCallback` · `FrameSource`(trait)。

## MoonBit 侧公开 API（全部 `declare`）

| 签名 | 参数与所有权 | 返回 / 错误 | 资源与线程约束 | TODO |
|---|---|---|---|---|
| `Camera::open(vm : JavaVMPtr, config : CameraConfig) -> Camera raise CameraError` | `vm` 进程级句柄；`config` 只读 | `Camera`（含 `owner_thread_id`） / `CameraError` | **必须在 JNI session owner 线程**；失败逆序释放句柄 | Java 样板、ajni host bridge、权限流程、缓冲池 |
| `Camera::start_preview(self) -> Unit raise CameraError` | `self` 只读 | `Unit` / `PreviewFailed` | owner 线程；幂等 | 重复请求会话 |
| `Camera::grab_yuv(self, timeout_ms : Int) -> YuvFrame raise CameraError` | `self` 只读 | 纯值帧（缓冲已归还） / `BufferAcquireFailed`、`BufferPoolExhausted` | 同步路径；仍需校验线程归属 | stride 解析、超时、缓冲归还 |
| `Camera::on_frame(self, cb : FrameCallback) -> Unit raise CameraError` | `cb` 为可捕获闭包，跨 C 边界时拆成 FuncRef + `#owned closure` | `Unit` | **回调在相机投递线程**；必须浅拷贝帧并 marshal 到 owner 线程；禁止回调内 JNI | C 侧 attach/global ref/marshal |
| `Camera::clear_on_frame(self) -> Unit raise CameraError` | `self` 只读 | `Unit` | 注销并释放 `#owned` 闭包 | — |
| `Camera::close(self) -> Unit raise CameraError` | 消耗释放责任 | `Unit` / `AlreadyClosed` | 幂等；注销回调 + 释放 reader/camera | — |
| `enumerate_cameras(vm : JavaVMPtr) -> Array[CameraInfo] raise CameraError` | `vm` 只读 | 能力快照（不打开设备） | owner 线程 | 厂商 quirk 标注、Camera1/UVC 回退探测 |

## 非目标

推理、渲染、YUV→RGB、权限 UI、视频编码、Surface 渲染、厂商 quirk 自动修复。

## 状态与已知阻塞

`moon check`：✅ 0 error，7 × `0068`。`moon build` / `moon test`：❌ **预期链接期失败**（shim 未实现）。API 快照：`pkg.generated.mbti`。
