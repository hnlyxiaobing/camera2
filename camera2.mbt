///|
/// Android Camera2 的 JNI 封装契约（实现轮）。
///
/// 本文件：外部句柄声明、`extern "C"` shim 签名、中性帧值类型、公开 API 实现。
/// 内部解析/映射辅助见 `internal.mbt`；`stub/camera2_stub.c` 为**桌面 stub**——
/// 真实 JNI / ajni@0.3.6 / 设备取帧（红米电视 720p YUV）留待后续真实对接阶段
/// （ajni 在 Windows 主机 + 目标设备真机的可用性未实证）。
///
/// 线程与所有权总则（JNI 硬约束，完整决策见 docs/DECISIONS.md
/// 「JNI 线程亲和性与回调所有权」「回调投递线程 → owner 线程 marshal」）：
/// - `JNIEnvPtr` 是线程局部的，禁止缓存、禁止跨线程传递；只缓存 `JavaVMPtr`。
/// - 原生线程回调前必须 `AttachCurrentThread`，退出前 `DetachCurrentThread`。
/// - 跨回调长期持有的 Java 对象必须用 `NewGlobalRef` / `DeleteGlobalRef` 管理。
/// - 帧回调经 **marshal 层**（R4）投递：投递线程只浅拷贝帧数据入队
///   （C 侧有界 marshal 队列），**绝不执行 MoonBit 闭包**；闭包只由
///   owner 线程 `Camera::pump_marshal` 同步派发。回调内禁止直接触碰
///   JNI session、禁止阻塞、禁止保存栈上指针。
/// - `CameraHandleRaw` / `ImageReaderRaw` 为 C 侧 `void*`，由 `mb_camera2_close` 释放一次。
/// 平台约束：仅 `native` 目标；Android API 24+（NDK camera2ndk）或 Java Camera2 + ajni。

///|
#external
pub type JavaVMPtr

///|
#external
pub type JNIEnvPtr

///|
#external
pub type JObjectRef

///|
#external
pub type CameraHandleRaw

///|
#external
pub type ImageReaderRaw

///|
/// 相机状态机（**API 冻结前收紧**：删除未被实际代码路径使用的
/// `Closed` / `Opening` / `Previewing` / `Failed` 分支，只保留实际构造的
/// `Open`——`Camera::open` 是唯一写入点，`state` 由 C 侧会话注册表裁决存活，
/// 不补齐状态机）。
pub(all) enum CameraState {
  Open
}

///|
/// 预览尺寸。
pub(all) struct FrameSize {
  width : Int32
  height : Int32
}

///|
/// YUV_420_888 单平面描述，保留 `row_stride` / `pixel_stride`，不做隐式假设。
pub(all) struct YuvPlane {
  data : Bytes
  row_stride : Int32
  pixel_stride : Int32
}

///|
/// 相机帧的中性值类型（与 `yuv::YuvFrame` 结构一致，由组合根适配）。
pub(all) struct YuvFrame {
  width : Int32
  height : Int32
  planes : Array[YuvPlane]
  timestamp_ns : UInt64
}

///|
/// 相机元数据摘要（不含厂商扩展）。
pub(all) struct CameraInfo {
  id : String
  facing : Facing
  supported_sizes : Array[FrameSize]
  supports_yuv420888 : Bool
}

///|
pub(all) enum Facing {
  Front
  Back
  External
}

///|
/// 打开配置。
pub(all) struct CameraConfig {
  camera_id : String
  size : FrameSize
  max_inflight_buffers : Int32
  rotation_degrees : Int32
  mirror_x : Bool
}

///|
/// MoonBit 侧相机包装值；`handle` 为 C 侧裸指针。
/// `state` 为打开状态快照（API 冻结前收紧后仅 `Open`）；重复 open/close 的存活
/// 裁决由 C 侧会话注册表（`ensure_session`）完成，不依赖该字段的分支。
pub(all) struct Camera {
  handle : CameraHandleRaw
  reader : ImageReaderRaw
  config : CameraConfig
  state : CameraState
  owner_thread_id : UInt64
}

///|
/// 相机错误模型（**API 冻结前追认**：`pub(all) suberror`——
/// 组合根可替换帧源需在包外构造/抛出，见 docs/DECISIONS.md「可替换帧源设计」）。
/// `MarshalReentrant`（R4）：派发期间重入 `Camera::pump_marshal` 被拒绝。
#derive(Debug)
pub(all) suberror CameraError {
  PermissionDenied(String)
  CameraNotFound(String)
  OpenFailed(Int32, String)
  PreviewFailed(Int32, String)
  UnsupportedSize(Int32, Int32)
  UnsupportedFormat(String)
  BufferAcquireFailed(Int32)
  BufferPoolExhausted(Int32)
  JniThreadNotAttached(String)
  MarshalReentrant(String)
  AlreadyOpen
  AlreadyClosed
  VendorQuirk(String)
}

///|
pub extend CameraError with Debug::{to_repr}

///|
/// 帧回调的 MoonBit 侧类型（可捕获闭包；跨 C 边界时由 shim 用 `FuncRef` + closure 传递）。
pub type FrameCallback = (YuvFrame) -> Unit

///|
/// 帧源契约；`pose` / `yuv` 不依赖本库，组合根决定是否注入相机或文件帧源。
/// `pub(open)`：供包外实现（文件帧源 / RTSP / 桌面摄像头），可替换帧源设计
/// 见 docs/DECISIONS.md「可替换帧源设计」。
///
/// **方法集已冻结（API 冻结前冻结）**：
/// - `grab_yuv(Self) -> YuvFrame raise CameraError` —— **接口层不提供超时参数**；
///   超时策略由具体帧源实现自行定义（如 `Camera::grab_yuv(self, timeout_ms)`、
///   文件帧源可无限等待）。冻结后给 trait 方法加参数即破坏性变更。
/// - `close(Self) -> Unit raise CameraError` —— **不会二次释放，重复调用返回明确错误**。
pub(open) trait FrameSource {
  fn grab_yuv(Self) -> YuvFrame raise CameraError
  fn close(Self) -> Unit raise CameraError
}

///|
/// ---- 外部 C shim 声明（**包私有，非公共 API**；API 冻结前移出公开面）----
/// 符号由 `stub/camera2_stub.c`（桌面 stub，当前阶段）提供；
/// 后续真实对接阶段由 Java 侧 + 真实 JNI `native-stub` 提供同名符号。
/// 可见性：9 个 `mb_camera2_*` 均为**私有实现 ABI**（不再出现在公开快照），
/// MoonBit 层只经 `Camera::{open,start_preview,grab_yuv,on_frame,clear_on_frame,close}`
/// 与 `enumerate_cameras` 调用；符号名与签名不变，真实对接无需改 ABI。
/// ABI：Int→int32_t、UInt64→uint64_t、Unit→void、Bytes/FixedArray[Byte]→uint8_t*、
/// #external→void*、FuncRef→函数指针、`() -> Unit` 闭包→MoonBit 对象指针。

///|
/// 进程级初始化：缓存 `JavaVM*`，不缓存 `JNIEnv*`。必须在任何 open 之前调用一次。
extern "C" fn mb_camera2_init(vm : JavaVMPtr) -> Int32 = "mb_camera2_init"

///|
/// 打开相机；`camera_id` 为 `#borrow`，C 侧只读取。
#borrow(camera_id)
extern "C" fn mb_camera2_open(
  camera_id : Bytes,
  width : Int32,
  height : Int32,
  max_buffers : Int32,
) -> CameraHandleRaw = "mb_camera2_open"

///|
/// 创建 ImageReader（YUV_420_888），返回独立句柄。
extern "C" fn mb_camera2_create_reader(
  camera : CameraHandleRaw,
  width : Int32,
  height : Int32,
  max_buffers : Int32,
) -> ImageReaderRaw = "mb_camera2_create_reader"

///|
/// 启动重复预览请求。
extern "C" fn mb_camera2_start_preview(
  camera : CameraHandleRaw,
  reader : ImageReaderRaw,
) -> Int32 = "mb_camera2_start_preview"

///|
/// 同步取一帧；`dst` 由 C 侧填充为「3 段 plane + stride 头」的原始缓冲。
/// `#borrow` 表示 MoonBit 保留缓冲所有权，C 侧不 decref。
#borrow(dst)
extern "C" fn mb_camera2_acquire_frame(
  reader : ImageReaderRaw,
  dst : FixedArray[Byte],
  capacity : Int32,
  timeout_ms : Int32,
) -> Int32 = "mb_camera2_acquire_frame"

///|
/// 归还 Image 缓冲。必须在读取完 plane 字节后调用，否则缓冲池耗尽。
extern "C" fn mb_camera2_release_frame(reader : ImageReaderRaw) -> Unit = "mb_camera2_release_frame"

///|
/// 注册帧回调。`closure` 为 `#owned`：C 侧长期持有 MoonBit 闭包，
/// 注销时须由 shim 执行 `moonbit_decref`；`cb` 为无捕获 `FuncRef` 适配器。
/// **闭包只由 owner 线程 `mb_camera2_marshal_pump` 派发**（R4 marshal 层）；
/// 投递线程只做浅拷贝入队，绝不执行闭包。
#owned(closure)
extern "C" fn mb_camera2_set_frame_callback(
  reader : ImageReaderRaw,
  cb : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int32 = "mb_camera2_set_frame_callback"

///|
/// 注销帧回调并释放 `#owned` 持有的闭包。
extern "C" fn mb_camera2_clear_frame_callback(reader : ImageReaderRaw) -> Unit = "mb_camera2_clear_frame_callback"

///|
/// owner 线程 pump：同步派发 marshal 队列中已投递的帧事件（每事件恰好
/// 调用一次已注册闭包；无注册回调时事件丢弃排水）。返回消费事件数；
/// -15 = 派发期间重入（映射 `CameraError::MarshalReentrant`）。
extern "C" fn mb_camera2_marshal_pump(
  reader : ImageReaderRaw,
  max_events : Int32,
) -> Int32 = "mb_camera2_marshal_pump"

///|
/// 派发期间由被调闭包拉取暂存事件（两段式：容量不足返回所需容量不消费；
/// 足够则拷贝并消费）。`#borrow(dst)`：MoonBit 保留缓冲所有权。
#borrow(dst)
extern "C" fn mb_camera2_marshal_next(
  reader : ImageReaderRaw,
  dst : FixedArray[Byte],
  capacity : Int32,
) -> Int32 = "mb_camera2_marshal_next"

///|
/// 关闭并释放 reader + camera 句柄（C 侧唯一释放点，且只能调用一次；
/// MoonBit 层保证重复 close 不会二次调用本函数，见 `Camera::close`）。
extern "C" fn mb_camera2_close(
  camera : CameraHandleRaw,
  reader : ImageReaderRaw,
) -> Unit = "mb_camera2_close"

///|
/// ---- MoonBit 侧公开 API（全部已实现）----

///|
/// 打开相机并进入 `Open` 状态。
///
/// - 获取资源：camera 句柄 + ImageReader 句柄；失败时逆序释放（reader 失败先还 camera）。
/// - 错误：权限、设备不存在、尺寸/格式不支持、JNI 线程未 attach、会话占用均以
///   `CameraError` 传播（C status → CameraError 映射，见 `internal.mbt`）。
/// - 线程：必须在 JNI session 的 owner 线程调用；`Camera` 绑定到 `owner_thread_id`。
/// - 状态机：句柄存活状态由 C 侧会话注册表裁决（本值类型字段不可变）。
/// - 非目标：不做推理、不做渲染、不做 YUV→RGB 转换、不实现权限 UI。
/// - 桌面 stub：真实 Java Camera2 样板 / ajni host bridge / 权限流程留待后续真实
///   对接阶段（ajni 真机可用性未实证）。
pub fn Camera::open(
  vm : JavaVMPtr,
  config : CameraConfig,
) -> Camera raise CameraError {
  let width = config.size.width
  let height = config.size.height
  if width <= 0 || height <= 0 {
    raise CameraError::UnsupportedSize(width, height)
  }
  if config.max_inflight_buffers < 1 {
    raise CameraError::OpenFailed(
      -13, "Camera::open: max_inflight_buffers must be >= 1",
    )
  }
  let init_status = mb_camera2_init(vm)
  if init_status != 0 {
    raise open_error(
      init_status, "Camera::open: mb_camera2_init", width, height,
    )
  }
  let id_bytes = @utf8.encode(config.camera_id)
  let handle = mb_camera2_open(
    id_bytes,
    width,
    height,
    config.max_inflight_buffers,
  )
  let open_status = mb_camera2_last_status()
  if open_status != 0 {
    raise open_error(
      open_status,
      "Camera::open: " + config.camera_id,
      width,
      height,
    )
  }
  let reader = mb_camera2_create_reader(
    handle,
    width,
    height,
    config.max_inflight_buffers,
  )
  let reader_status = mb_camera2_last_status()
  if reader_status != 0 {
    // 失败逆序释放：归还已取得的 camera 句柄（reader 为空）。
    mb_camera2_close(handle, reader)
    raise open_error(
      reader_status, "Camera::open: mb_camera2_create_reader", width, height,
    )
  }
  Camera::{
    handle,
    reader,
    config,
    state: CameraState::Open,
    owner_thread_id: mb_camera2_current_thread_id(),
  }
}

///|
/// 启动预览（重复请求）；幂等，重复调用返回成功但不重复建会话。
/// 线程：owner 线程；会话未存活（未 open / 已 close）拒绝操作。
pub fn Camera::start_preview(self : Camera) -> Unit raise CameraError {
  ensure_session(self.handle, self.reader)
  ensure_owner(self.owner_thread_id)
  let status = mb_camera2_start_preview(self.handle, self.reader)
  if status != 0 {
    raise preview_error(
      status,
      "Camera::start_preview: mb_camera2_start_preview",
      self.config.size.width,
      self.config.size.height,
    )
  }
}

///|
/// 同步取一帧 YUV_420_888；返回纯值，缓冲已归还给 ImageReader（每帧 acquire→release）。
/// 超时抛 `BufferAcquireFailed(timeout_ms)`，缓冲池在飞数耗尽抛
/// `BufferPoolExhausted(max_inflight_buffers)`，二者可判。
/// 线程：owner 线程；会话未存活拒绝操作。
pub fn Camera::grab_yuv(
  self : Camera,
  timeout_ms : Int32,
) -> YuvFrame raise CameraError {
  ensure_session(self.handle, self.reader)
  ensure_owner(self.owner_thread_id)
  Camera::acquire_frame_value(self, timeout_ms)
}

///|
/// 注册帧回调（**R4 marshal 语义**）：投递线程只把浅拷贝帧事件入 C 侧有界
/// marshal 队列，**闭包不在投递线程执行**；须由 owner 线程调用
/// `Camera::pump_marshal` 同步派发——每消费一个事件回调恰好执行一次。
///
/// - 跨 C 边界拆为 `FuncRef` 无捕获适配器 + `#owned` 闭包二元组（回调所有权设计
///   见 docs/DECISIONS.md「JNI 线程亲和性与回调所有权」）；
///   C 侧长期持有闭包，注销/替换/关闭时 `moonbit_decref`，成对不泄漏。
/// - 每次派发时 thunk 经 `mb_camera2_marshal_next` 拉取暂存帧事件、解析为纯值
///   `YuvFrame` 再调用 `cb`；解析失败则本次不调用 `cb`（事件仍被消费，不卡队列）。
/// - 回调内**禁止阻塞**、禁止长时间占用 owner 线程；可安全重入
///   `grab_yuv` / `on_frame` / `clear_on_frame` / `close`（释放竞态由 C 侧
///   延迟释放收敛），**不可**重入 `pump_marshal`（`MarshalReentrant`）。
/// - 线程：注册须在 owner 线程；会话未存活拒绝操作。
pub fn Camera::on_frame(
  self : Camera,
  cb : FrameCallback,
) -> Unit raise CameraError {
  ensure_session(self.handle, self.reader)
  ensure_owner(self.owner_thread_id)
  let reader = self.reader
  let thunk : () -> Unit = fn() {
    match take_marshal_frame(reader) {
      Some(frame) => cb(frame)
      None => ()
    }
  }
  let status = mb_camera2_set_frame_callback(self.reader, fn(f) { f() }, thunk)
  if status != 0 {
    raise open_error(
      status,
      "Camera::on_frame: mb_camera2_set_frame_callback",
      self.config.size.width,
      self.config.size.height,
    )
  }
}

///|
/// owner 线程 pump：同步派发 marshal 队列中已投递的帧回调，返回本次消费的
/// 事件数（每事件恰好调用一次已注册回调；无注册回调时事件丢弃排水）。
///
/// - 队列有界（C 侧满丢最旧并计数），出队顺序 = 线性化入队顺序；
///   投递线程与 owner 线程的乱序并发投递在 C 侧锁内串行化。
/// - 错误：会话未存活 `AlreadyClosed`；非 owner 线程 `JniThreadNotAttached`；
///   派发期间重入 `MarshalReentrant`；`max_events < 1` 为 `OpenFailed(-13, _)`。
/// - 线程：**只在 owner 线程调用**（与 JNI session 同线程，闭包同线程执行）。
/// - 非目标：不阻塞等待新帧（纯排水语义，配合调用方循环/事件驱动使用）。
pub fn Camera::pump_marshal(
  self : Camera,
  max_events : Int32,
) -> Int32 raise CameraError {
  ensure_session(self.handle, self.reader)
  ensure_owner(self.owner_thread_id)
  if max_events < 1 {
    raise CameraError::OpenFailed(
      -13, "Camera::pump_marshal: max_events must be >= 1",
    )
  }
  let count = mb_camera2_marshal_pump(self.reader, max_events)
  if count < 0 {
    raise pump_error(count, "Camera::pump_marshal")
  }
  count
}

///|
/// 注销帧回调并释放 `#owned` 持有的闭包（幂等；未注册时为 no-op）。
/// 注销后不再触发。线程：owner 线程；会话未存活拒绝操作。
pub fn Camera::clear_on_frame(self : Camera) -> Unit raise CameraError {
  ensure_session(self.handle, self.reader)
  ensure_owner(self.owner_thread_id)
  mb_camera2_clear_frame_callback(self.reader)
}

///|
/// 关闭相机并释放全部 C 句柄（C 侧唯一释放点）：
/// 先注销回调（释放 `#owned` 闭包），再释放 reader + camera。
/// **不会二次释放，重复调用返回明确错误（`AlreadyClosed`）**——
/// 已关闭（或未 open）的会话再调 `close` 由会话存活守卫直接拒绝，
/// 不会再次触碰 `mb_camera2_close`。
/// 线程：owner 线程（跨线程 close 拒绝为 `JniThreadNotAttached`，
/// 杜绝 close 与 pump 派发的跨线程竞态）；派发期间（回调内）close
/// 合法，结构体释放延迟到本次 pump 收尾（防 UAF）。close 后 marshal
/// 队列中未派发事件全部释放、不再触发回调。
pub fn Camera::close(self : Camera) -> Unit raise CameraError {
  ensure_session(self.handle, self.reader)
  ensure_owner(self.owner_thread_id)
  mb_camera2_clear_frame_callback(self.reader)
  mb_camera2_close(self.handle, self.reader)
}

///|
/// 枚举可用相机（只读快照，不打开设备）。
/// 线程：须在 JNI 会话已附着的线程调用；未附着抛 `JniThreadNotAttached`。
pub fn enumerate_cameras(vm : JavaVMPtr) -> Array[CameraInfo] raise CameraError {
  let init_status = mb_camera2_init(vm)
  if init_status != 0 {
    raise open_error(init_status, "enumerate_cameras: mb_camera2_init", 0, 0)
  }
  let capacity = 8192
  let dst = FixedArray::make(capacity, b'\x00')
  let ret = mb_camera2_enumerate_raw(vm, dst, capacity)
  if ret == -12 {
    let big = FixedArray::make(65536, b'\x00')
    let ret2 = mb_camera2_enumerate_raw(vm, big, 65536)
    if ret2 < 0 {
      raise open_error(
        ret2, "enumerate_cameras: mb_camera2_enumerate_raw", 0, 0,
      )
    }
    parse_camera_infos(big, ret2)
  } else if ret < 0 {
    raise open_error(ret, "enumerate_cameras: mb_camera2_enumerate_raw", 0, 0)
  } else {
    parse_camera_infos(dst, ret)
  }
}
