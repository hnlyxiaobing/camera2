# camera2 · 公开 API（API.md）

> **冻结前 P0 整改后（R2 准备轮）**。`preferred_target = "native"`，错误传播统一 `raise CameraError`。
> MoonBit 侧 API **全部已实现**（桌面 C stub 双路径），无 `declare` 残留、无 `0068` 告警。
> 快照 `pkg.generated.mbti` 已由工具链（`rr_moon_pkg`）在 `moon check` / `moon build` 时**自动同步**为
> 本轮 P0 后公开面（9 个 `mb_camera2_*` shim 消失、`CameraState` 收紧为 `Open` 等）；
> 本子代理**未运行 `moon info`**，最终快照审阅由主控统一执行。

## 外部句柄（`#external` = C `void*`）

| 句柄 | 约束 | 释放点 |
|---|---|---|
| `JavaVMPtr` | 进程级可缓存 | 不释放 |
| `JNIEnvPtr` | **线程局部，禁止缓存 / 跨线程传递 / 放入 MoonBit 值类型** | 不释放 |
| `JObjectRef` | 长期持有须 `NewGlobalRef` | `DeleteGlobalRef`（C 侧） |
| `CameraHandleRaw` | C 侧相机句柄 | `Camera::close` |
| `ImageReaderRaw` | C 侧 reader 句柄 | `Camera::close` |

## 外部 C shim（9 个 · **私有实现 ABI，非公共 API**）

> **冻结前 P0 决策 6**：9 个 `mb_camera2_*` 全部改为**包私有**，不再出现在公开 API / 快照；
> 实现与内部调用（`Camera::{open,start_preview,grab_yuv,on_frame,clear_on_frame,close}`、
> `enumerate_cameras`）全部保留，符号名与签名不变，R2 真实 JNI 对接无需改 ABI。
> 黑盒测试不直接调用 shim；直接调用的白盒用例留在 `camera2_wbtest.mbt`。
> 下表仅作**内部 ABI 文档**，不构成公共 API 承诺。

| shim（包私有） | 所有权 / 回调 | 语义 |
|---|---|---|
| `mb_camera2_init(vm : JavaVMPtr) -> Int32` | — | 缓存 JavaVM，不缓存 JNIEnv；open 前调用一次 |
| `mb_camera2_open(camera_id : Bytes, width : Int32, height : Int32, max_buffers : Int32) -> CameraHandleRaw` | `#borrow(camera_id)` | 打开相机 |
| `mb_camera2_create_reader(camera, width : Int32, height : Int32, max_buffers : Int32) -> ImageReaderRaw` | — | 创建 YUV_420_888 reader |
| `mb_camera2_start_preview(camera, reader) -> Int32` | — | 重复预览请求 |
| `mb_camera2_acquire_frame(reader, dst : FixedArray[Byte], capacity : Int32, timeout_ms : Int32) -> Int32` | `#borrow(dst)` | C 侧填充「3 段 plane + stride 头」 |
| `mb_camera2_release_frame(reader) -> Unit` | — | **读完必须调用** |
| `mb_camera2_set_frame_callback(reader, cb : FuncRef[(() -> Unit) -> Unit], closure : () -> Unit) -> Int32` | `#owned(closure)` | `FuncRef` 无捕获；C 侧长期持有闭包 |
| `mb_camera2_clear_frame_callback(reader) -> Unit` | — | 注销并 `moonbit_decref` |
| `mb_camera2_close(camera, reader) -> Unit` | — | **C 侧唯一释放点**，仅由 `Camera::close` 调用一次（重复 close 被 MoonBit 层拒绝，不会二次释放） |

## 值类型 / 错误 / 契约

`Camera` · `CameraState` · `CameraConfig` · `CameraInfo` · `FrameSize` · `Facing` · `YuvFrame` · `YuvPlane` · `CameraError`（**`pub(all) suberror`**，12 个构造）· `FrameCallback` · `FrameSource`(trait)。

- **决策 4（追认）**：`CameraError` 为 `pub(all) suberror`——包外可构造/匹配/抛出
  （组合根替换帧源需要，ADR-0004）。R1 起即如此，冻结前正式追认，冻结后改回 `pub` 即破坏性变更。
- **决策 5（收紧）**：`CameraState` 删除未被实际代码路径使用的 `Closed` / `Opening` /
  `Previewing` / `Failed` 分支，收紧为实际使用的 **`Open`**（`Camera::open` 是唯一写入点；
  存活裁决在 C 侧会话注册表）。属允许的「删除死接口」类公开面变化，冻结后恢复分支即破坏性变更。

### `FrameSource` 方法集（**已冻结 · 决策 3 方案 A**）

```moonbit
pub(open) trait FrameSource {
  fn grab_yuv(Self) -> YuvFrame raise CameraError   // 无超时参数
  fn close(Self) -> Unit raise CameraError
}
```

- **方法集已冻结**：`grab_yuv(Self)` / `close(Self)`，签名如上。
- **超时语义**：接口层**不提供超时参数**，超时策略由**具体帧源实现自行定义**
  （`Camera::grab_yuv(self, timeout_ms)` 自带超时；文件帧源可无超时等待）。
  冻结后给 trait 方法增删参数即破坏性变更。
- `close` 语义：**不会二次释放，重复调用返回明确错误**（实现自行定义具体错误，
  本库 `Camera` 实现返回 `AlreadyClosed`）。

## MoonBit 侧公开 API（全部已实现）

| 签名 | 参数与所有权 | 返回 / 错误 | 资源与线程约束 | TODO |
|---|---|---|---|---|
| `Camera::open(vm : JavaVMPtr, config : CameraConfig) -> Camera raise CameraError` | `vm` 进程级句柄；`config` 只读 | `Camera`（含 `owner_thread_id`） / `CameraError` | **必须在 JNI session owner 线程**；失败逆序释放句柄 | Java 样板、ajni host bridge、权限流程、缓冲池 |
| `Camera::start_preview(self) -> Unit raise CameraError` | `self` 只读 | `Unit` / `PreviewFailed` | owner 线程；幂等 | 重复请求会话 |
| `Camera::grab_yuv(self, timeout_ms : Int32) -> YuvFrame raise CameraError` | `self` 只读 | 纯值帧（缓冲已归还） / `BufferAcquireFailed`、`BufferPoolExhausted` | 同步路径；仍需校验线程归属；`timeout_ms` 为**具体帧源自行定义的超时策略**（trait `FrameSource::grab_yuv` 层无超时参数） | stride 解析、超时、缓冲归还 |
| `Camera::on_frame(self, cb : FrameCallback) -> Unit raise CameraError` | `cb` 为可捕获闭包，跨 C 边界时拆成 FuncRef + `#owned closure` | `Unit` | **回调在相机投递线程**；必须浅拷贝帧并 marshal 到 owner 线程；禁止回调内 JNI | C 侧 attach/global ref/marshal |
| `Camera::clear_on_frame(self) -> Unit raise CameraError` | `self` 只读 | `Unit` | 注销并释放 `#owned` 闭包 | — |
| `Camera::close(self) -> Unit raise CameraError` | 消耗释放责任 | `Unit` / `AlreadyClosed` | **不会二次释放，重复调用返回明确错误（`AlreadyClosed`）**；注销回调 + 释放 reader/camera | — |
| `enumerate_cameras(vm : JavaVMPtr) -> Array[CameraInfo] raise CameraError` | `vm` 只读 | 能力快照（不打开设备） | owner 线程 | 厂商 quirk 标注、Camera1/UVC 回退探测 |

## 非目标

推理、渲染、YUV→RGB、权限 UI、视频编码、Surface 渲染、厂商 quirk 自动修复。

## 状态与已知阻塞

**冻结前 P0 整改（R2 准备轮）实跑**：`moon clean` / `moon check --deny-warn` / `moon build` /
`moon test`（21 测试全过）/ `moon fmt --check` 全部 exit 0（桌面 C stub 环境）。
真实 JNI / Java 样板 / ajni / 设备取帧留待 **R2**（open-questions E4）；本轮保持项目内 C stub 双路径，
未链接/下载任何外部库。API 快照：`pkg.generated.mbti`（工具链已自动同步至本轮 P0 后公开面，待主控终审）。
