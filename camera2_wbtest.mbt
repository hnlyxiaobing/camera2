// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs to `_test.mbt`.
//
// 本文件覆盖：全链路、状态机（未 open 拒绝 / 重复 close）、缓冲池耗尽与
// acquire→release 归还、可配置帧序列、三平面 stride 描述与非紧凑 padding、
// 回调注册/派发/注销后不再触发、#owned 闭包 set/clear 成对、错误映射、
// 解析校验，以及 **R4 marshal 层**并发/竞态/错误路径（多线程投递、
// 重入调用、乱序/满队列、关闭竞态、投递后释放）。
// 回调线程契约（ADR-0009，见 docs/DECISIONS.md「回调投递线程 → owner 线程 marshal」）：
// 投递线程（threaded 模式独立线程）只做浅拷贝入队、绝不执行 MoonBit 闭包；
// 闭包只由 owner 线程 `Camera::pump_marshal` 派发（断言回调线程 == owner 线程）。

///|
/// ---- 桌面 stub 测试替身控制（非 pub extern，仅测试期使用）----

///|
extern "C" fn stub_reset() -> Unit = "mb_camera2_stub_reset"

///|
extern "C" fn stub_fake_vm() -> JavaVMPtr = "mb_camera2_stub_fake_vm"

///|
extern "C" fn stub_set_open_status(st : Int32) -> Unit = "mb_camera2_stub_set_open_status"

///|
extern "C" fn stub_set_reader_status(st : Int32) -> Unit = "mb_camera2_stub_set_reader_status"

///|
extern "C" fn stub_set_preview_status(st : Int32) -> Unit = "mb_camera2_stub_set_preview_status"

///|
extern "C" fn stub_set_acquire_status(st : Int32) -> Unit = "mb_camera2_stub_set_acquire_status"

///|
extern "C" fn stub_set_unattached(flag : Int32) -> Unit = "mb_camera2_stub_set_unattached"

///|
extern "C" fn stub_set_threaded(flag : Int32) -> Unit = "mb_camera2_stub_set_threaded"

///|
extern "C" fn stub_set_frame_count(n : Int32) -> Unit = "mb_camera2_stub_set_frame_count"

///|
extern "C" fn stub_set_frame_interval_ms(ms : Int32) -> Unit = "mb_camera2_stub_set_frame_interval_ms"

///|
extern "C" fn stub_produce(reader : ImageReaderRaw) -> Int32 = "mb_camera2_stub_produce"

///|
extern "C" fn stub_callback_calls(reader : ImageReaderRaw) -> Int32 = "mb_camera2_stub_callback_calls"

///|
extern "C" fn stub_live_closures() -> Int32 = "mb_camera2_stub_live_closures"

///|
extern "C" fn stub_live_cameras() -> Int32 = "mb_camera2_stub_live_cameras"

///|
extern "C" fn stub_live_readers() -> Int32 = "mb_camera2_stub_live_readers"

///|
extern "C" fn stub_inflight(reader : ImageReaderRaw) -> Int32 = "mb_camera2_stub_inflight"

///|
extern "C" fn stub_pending(reader : ImageReaderRaw) -> Int32 = "mb_camera2_stub_pending"

///|
extern "C" fn stub_sleep(ms : Int32) -> Unit = "mb_camera2_stub_sleep"

///|
extern "C" fn stub_quiesce() -> Unit = "mb_camera2_stub_quiesce"

///|
extern "C" fn stub_marshal_pending(reader : ImageReaderRaw) -> Int32 = "mb_camera2_stub_marshal_pending"

///|
extern "C" fn stub_marshal_dropped(reader : ImageReaderRaw) -> Int32 = "mb_camera2_stub_marshal_dropped"

///|
extern "C" fn stub_marshal_pushed(reader : ImageReaderRaw) -> Int32 = "mb_camera2_stub_marshal_pushed"

///|
extern "C" fn stub_marshal_live_events() -> Int32 = "mb_camera2_stub_marshal_live_events"

///|
/// ---- 测试辅助 ----

///|
fn expect_camera_error(
  f : () -> Unit raise CameraError,
  what : String,
) -> CameraError raise Failure {
  try f() catch {
    err => err
  } noraise {
    _ => fail("\{what}: expected CameraError")
  }
}

///|
fn test_config(id : String, w : Int32, h : Int32, pool : Int32) -> CameraConfig {
  CameraConfig::{
    camera_id: id,
    size: FrameSize::{ width: w, height: h, },
    max_inflight_buffers: pool,
    rotation_degrees: 0,
    mirror_x: false,
  }
}

///|
/// stub 帧图案（与 stub/camera2_stub.c 的 sample_byte 一致）。
fn expected_sample(k : Int32, plane : Int32, x : Int32, y : Int32) -> Int32 {
  (k * 7 + x + y * 3 + plane * 64) & 255
}

///|
/// 按 stride 索引校验样本；行尾 padding 与 chroma 间隔字节必须为 0xEE。
fn check_samples(
  data : Bytes,
  k : Int32,
  plane : Int32,
  aw : Int32,
  ah : Int32,
  rs : Int32,
  px : Int32,
  what : String,
) -> Unit raise Failure {
  for row in 0..<ah {
    for x in 0..<aw {
      let got = data.at(row * rs + x * px).to_int()
      let want = expected_sample(k, plane, x, row)
      if got != want {
        fail("\{what}: sample(\{x},\{row}) = \{got}, want \{want}")
      }
    }
    if data.at(row * rs + rs - 1).to_int() != 0xEE {
      fail("\{what}: row \{row} tail padding != 0xEE")
    }
    if px == 2 && data.at(row * rs + 1).to_int() != 0xEE {
      fail("\{what}: row \{row} chroma gap != 0xEE")
    }
  }
}

///|
/// 校验一帧的维度、三平面 stride 描述、时间戳与像素图案。
fn check_frame(
  frame : YuvFrame,
  k : Int32,
  w : Int32,
  h : Int32,
  what : String,
) -> Unit raise Failure {
  if frame.width != w || frame.height != h {
    fail("\{what}: dims \{frame.width}x\{frame.height}, want \{w}x\{h}")
  }
  if frame.planes.length() != 3 {
    fail("\{what}: plane count \{frame.planes.length()}")
  }
  let y = frame.planes[0]
  let u = frame.planes[1]
  let v = frame.planes[2]
  let y_rs = w + 8
  let c_rs = w + 4
  if y.row_stride != y_rs || y.pixel_stride != 1 || y.data.length() != y_rs * h {
    fail("\{what}: Y descriptor")
  }
  if u.row_stride != c_rs ||
    u.pixel_stride != 2 ||
    u.data.length() != c_rs * (h / 2) {
    fail("\{what}: U descriptor")
  }
  if v.row_stride != c_rs ||
    v.pixel_stride != 2 ||
    v.data.length() != c_rs * (h / 2) {
    fail("\{what}: V descriptor")
  }
  let want_ts = (k + 1).to_uint64() * 33333333UL
  if frame.timestamp_ns != want_ts {
    fail("\{what}: timestamp \{frame.timestamp_ns}, want \{want_ts}")
  }
  check_samples(y.data, k, 0, w, h, y_rs, 1, what + " Y")
  check_samples(u.data, k, 1, w / 2, h / 2, c_rs, 2, what + " U")
  check_samples(v.data, k, 2, w / 2, h / 2, c_rs, 2, what + " V")
}

///|
/// 两段式裸 acquire（不 release），返回 (打包缓冲, 已写字节数)。
fn raw_acquire(
  reader : ImageReaderRaw,
) -> (FixedArray[Byte], Int32) raise Failure {
  let probe = FixedArray::make(64, b'\x00')
  let first = mb_camera2_acquire_frame(reader, probe, 64, 0)
  if first <= 0 {
    fail("raw_acquire: expected needed capacity, got \{first}")
  }
  let big = FixedArray::make(first, b'\x00')
  let second = mb_camera2_acquire_frame(reader, big, first, 0)
  if second != 0 {
    fail("raw_acquire: expected ok, got \{second}")
  }
  (big, first)
}

///|
fn write_i32_le(buf : FixedArray[Byte], off : Int32, v : Int32) -> Unit {
  let u = v.to_uint64()
  buf[off] = u.to_byte()
  buf[off + 1] = (u >> 8).to_byte()
  buf[off + 2] = (u >> 16).to_byte()
  buf[off + 3] = (u >> 24).to_byte()
}

///|
/// ---- 测试 ----

///|
test "enumerate_cameras returns fake device snapshot" {
  stub_reset()
  let vm = stub_fake_vm()
  let infos = enumerate_cameras(vm)
  assert_eq(infos.length(), 4)
  assert_eq(infos[0].id, "0")
  assert_true(infos[0].facing is Facing::Back)
  assert_true(infos[0].supports_yuv420888)
  assert_eq(infos[0].supported_sizes.length(), 3)
  assert_eq(infos[0].supported_sizes[0].width, 1280)
  assert_eq(infos[0].supported_sizes[0].height, 720)
  assert_eq(infos[1].id, "1")
  assert_true(infos[1].facing is Facing::Front)
  assert_eq(infos[2].id, "2")
  assert_true(infos[2].facing is Facing::External)
  assert_eq(infos[3].id, "3")
  assert_true(!infos[3].supports_yuv420888)
}

///|
test "full chain: enumerate -> open -> preview -> on_frame -> grab -> clear -> close" {
  stub_reset()
  let vm = stub_fake_vm()
  let infos = enumerate_cameras(vm)
  assert_eq(infos.length(), 4)
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  Camera::start_preview(cam) // 幂等：不重复建会话
  let hits : Array[Int32] = [0]
  let seen : Array[YuvFrame] = []
  Camera::on_frame(cam, fn(frame) {
    hits[0] = hits[0] + 1
    seen.push(frame)
  })
  assert_eq(stub_live_closures(), 1)
  assert_eq(stub_produce(cam.reader), 0) // 投递第 0 帧（浅拷贝入 marshal 队列）
  assert_eq(hits[0], 0) // 未 pump 前闭包不执行（投递线程不跑 MoonBit 闭包）
  assert_eq(Camera::pump_marshal(cam, 8), 1) // owner 线程 pump 派发
  assert_eq(hits[0], 1)
  assert_eq(seen.length(), 1)
  check_frame(seen[0], 0, 320, 240, "callback frame")
  assert_eq(stub_inflight(cam.reader), 0) // 回调路径不占缓冲池（投递侧浅拷贝）
  let frame = Camera::grab_yuv(cam, 100) // 同步路径自动产第 1 帧
  check_frame(frame, 1, 320, 240, "grabbed frame")
  assert_eq(stub_inflight(cam.reader), 0) // 每帧缓冲均归还
  Camera::clear_on_frame(cam)
  assert_eq(stub_live_closures(), 0)
  let before = hits[0]
  assert_eq(stub_produce(cam.reader), 0) // 注销后投递（无回调：入 pending）
  assert_eq(stub_callback_calls(cam.reader), 0) // C 侧不再派发（clear 已清零）
  assert_eq(Camera::pump_marshal(cam, 8), 0) // marshal 队列已空
  assert_eq(hits[0], before) // 注销后不再触发
  Camera::close(cam)
  assert_eq(stub_live_cameras(), 0)
  assert_eq(stub_live_readers(), 0)
  assert_eq(stub_live_closures(), 0)
}

///|
test "operations before open / after close are rejected; repeated close raises" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::close(cam)
  let e1 = expect_camera_error(
    () => Camera::start_preview(cam),
    "start after close",
  )
  assert_true(e1 is CameraError::AlreadyClosed)
  let e2 = expect_camera_error(
    () => Camera::grab_yuv(cam, 10) |> ignore,
    "grab after close",
  )
  assert_true(e2 is CameraError::AlreadyClosed)
  let e3 = expect_camera_error(
    () => Camera::on_frame(cam, fn(_) { () }),
    "on_frame after close",
  )
  assert_true(e3 is CameraError::AlreadyClosed)
  let e4 = expect_camera_error(
    () => Camera::clear_on_frame(cam),
    "clear after close",
  )
  assert_true(e4 is CameraError::AlreadyClosed)
  let e5 = expect_camera_error(() => Camera::close(cam), "repeated close")
  assert_true(e5 is CameraError::AlreadyClosed)
}

///|
test "grab_yuv without preview times out with BufferAcquireFailed" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  let e = expect_camera_error(
    () => Camera::grab_yuv(cam, 20) |> ignore,
    "grab before preview",
  )
  assert_true(e is CameraError::BufferAcquireFailed(20))
  Camera::close(cam)
}

///|
test "forced acquire failure maps to BufferAcquireFailed" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  stub_set_acquire_status(-6) // 注入瞬态取帧失败
  let e = expect_camera_error(
    () => Camera::grab_yuv(cam, 50) |> ignore,
    "forced acquire failure",
  )
  assert_true(e is CameraError::BufferAcquireFailed(-6))
  stub_set_acquire_status(0) // 恢复正常
  let frame = Camera::grab_yuv(cam, 50)
  check_frame(frame, 0, 320, 240, "recovered")
  Camera::close(cam)
}

///|
test "buffer pool exhaustion raises BufferPoolExhausted; release restores" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 1)) // 池上限 1
  Camera::start_preview(cam)
  // 显式投递一帧：pending 队列有 1 帧；裸 acquire 消费后归零（不 release）
  assert_eq(stub_produce(cam.reader), 0)
  assert_eq(stub_pending(cam.reader), 1)
  ignore(raw_acquire(cam.reader))
  assert_eq(stub_pending(cam.reader), 0)
  assert_eq(stub_inflight(cam.reader), 1)
  let e = expect_camera_error(
    () => Camera::grab_yuv(cam, 50) |> ignore,
    "pool exhausted",
  )
  assert_true(e is CameraError::BufferPoolExhausted(1))
  // 归还后恢复
  mb_camera2_release_frame(cam.reader)
  assert_eq(stub_inflight(cam.reader), 0)
  let frame = Camera::grab_yuv(cam, 50)
  check_frame(frame, 1, 320, 240, "after release")
  assert_eq(stub_inflight(cam.reader), 0)
  Camera::close(cam)
}

///|
test "frame budget bounds the frame sequence" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  stub_set_frame_count(2) // 只产 2 帧
  let f0 = Camera::grab_yuv(cam, 50)
  let f1 = Camera::grab_yuv(cam, 50)
  check_frame(f0, 0, 320, 240, "budget frame 0")
  check_frame(f1, 1, 320, 240, "budget frame 1")
  let e = expect_camera_error(
    () => Camera::grab_yuv(cam, 30) |> ignore,
    "budget exhausted",
  )
  assert_true(e is CameraError::BufferAcquireFailed(30))
  Camera::close(cam)
}

///|
test "three-plane stride descriptors and non-compact padding are correct" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  let frame = Camera::grab_yuv(cam, 100)
  check_frame(frame, 0, 320, 240, "strides")
  // 显式断言三平面 stride 描述
  assert_eq(frame.planes[0].row_stride, 328) // 320 + 8，非紧凑
  assert_eq(frame.planes[0].pixel_stride, 1)
  assert_eq(frame.planes[1].row_stride, 324) // 320 + 4，U/V 共享
  assert_eq(frame.planes[1].pixel_stride, 2)
  assert_eq(frame.planes[2].row_stride, 324)
  assert_eq(frame.planes[2].pixel_stride, 2)
  assert_eq(frame.planes[1].data.length(), 324 * 120)
  // U/V 描述共享但数据不同
  assert_true(frame.planes[1].data != frame.planes[2].data)
  // 非紧凑：行尾 padding 与 chroma 间隔字节均为 0xEE
  assert_eq(frame.planes[0].data.at(327).to_int(), 0xEE)
  assert_eq(frame.planes[1].data.at(1).to_int(), 0xEE)
  Camera::close(cam)
}

///|
test "callback is marshalled to the owner thread; delivery thread only enqueues" {
  stub_reset()
  stub_set_threaded(1) // 独立投递线程（模拟相机投递线程，只浅拷贝入队）
  stub_set_frame_interval_ms(5)
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  let calls : Array[Int32] = [0]
  let tids : Array[UInt64] = [0UL]
  Camera::on_frame(cam, fn(_f) {
    calls[0] = calls[0] + 1
    tids[0] = mb_camera2_current_thread_id()
  })
  Camera::start_preview(cam) // 投递线程开始入队
  for _ in 0..<30 {
    ignore(Camera::pump_marshal(cam, 8)) // owner 线程 pump 派发
    stub_sleep(10)
  }
  stub_quiesce()
  assert_true(calls[0] >= 1)
  // 闭包只在 owner（pump 调用线程）执行；投递线程绝不执行 MoonBit 闭包
  assert_eq(tids[0], mb_camera2_current_thread_id())
  Camera::clear_on_frame(cam)
  let before = calls[0]
  for _ in 0..<15 {
    ignore(Camera::pump_marshal(cam, 8)) // 注销后 pump 丢弃排水
    stub_sleep(10)
  }
  stub_quiesce()
  assert_eq(calls[0], before) // 注销后不再触发
  Camera::close(cam) // join 投递线程并释放
  assert_eq(stub_live_closures(), 0)
  assert_eq(stub_marshal_live_events(), 0) // 队列事件随 close 全部释放
}

///|
test "callback set/clear pairing owns and releases the closure" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  let seen1 : Array[Int32] = [0]
  let seen2 : Array[Int32] = [0]
  Camera::on_frame(cam, fn(_) { seen1[0] = seen1[0] + 1 })
  assert_eq(stub_live_closures(), 1)
  Camera::on_frame(cam, fn(_) { seen2[0] = seen2[0] + 1 }) // 重复注册：替换并释放旧闭包
  assert_eq(stub_live_closures(), 1)
  assert_eq(stub_produce(cam.reader), 0)
  assert_eq(Camera::pump_marshal(cam, 4), 1) // owner 线程 pump 派发
  assert_eq(seen1[0], 0) // 旧回调不再触发
  assert_eq(seen2[0], 1)
  assert_eq(stub_inflight(cam.reader), 0) // 回调路径不占缓冲池（投递侧浅拷贝）
  Camera::clear_on_frame(cam)
  assert_eq(stub_live_closures(), 0)
  Camera::clear_on_frame(cam) // 幂等 no-op
  assert_eq(stub_live_closures(), 0)
  Camera::on_frame(cam, fn(_) { seen1[0] = seen1[0] + 1 })
  assert_eq(stub_live_closures(), 1)
  Camera::close(cam) // 未 clear 直接 close：close 内注销并释放
  assert_eq(stub_live_closures(), 0)
}

///|
test "open error mapping covers permission/not-found/size/format/quirk/attached" {
  let vm = stub_fake_vm()
  stub_reset()
  stub_set_open_status(-2)
  let e1 = expect_camera_error(
    () => Camera::open(vm, test_config("0", 320, 240, 2)) |> ignore,
    "permission",
  )
  assert_true(e1 is CameraError::PermissionDenied(_))
  stub_reset()
  let e2 = expect_camera_error(
    () => Camera::open(vm, test_config("9", 64, 48, 2)) |> ignore,
    "not found",
  )
  assert_true(e2 is CameraError::CameraNotFound(_))
  stub_reset()
  let e3 = expect_camera_error(
    () => Camera::open(vm, test_config("0", 1000, 1000, 2)) |> ignore,
    "unsupported size",
  )
  assert_true(e3 is CameraError::UnsupportedSize(1000, 1000))
  stub_reset()
  let e4 = expect_camera_error(
    () => Camera::open(vm, test_config("3", 1920, 1080, 2)) |> ignore,
    "unsupported format",
  )
  assert_true(e4 is CameraError::UnsupportedFormat(_))
  stub_reset()
  stub_set_open_status(-9)
  let e5 = expect_camera_error(
    () => Camera::open(vm, test_config("0", 320, 240, 2)) |> ignore,
    "vendor quirk",
  )
  assert_true(e5 is CameraError::VendorQuirk(_))
  stub_reset()
  stub_set_unattached(1)
  let e6 = expect_camera_error(
    () => Camera::open(vm, test_config("0", 320, 240, 2)) |> ignore,
    "not attached",
  )
  assert_true(e6 is CameraError::JniThreadNotAttached(_))
  stub_reset()
  stub_set_open_status(-1)
  let e7 = expect_camera_error(
    () => Camera::open(vm, test_config("0", 320, 240, 2)) |> ignore,
    "open failed",
  )
  assert_true(e7 is CameraError::OpenFailed(-1, _))
  stub_reset()
  let e8 = expect_camera_error(
    () => Camera::open(vm, test_config("0", 0, 0, 2)) |> ignore,
    "zero size",
  )
  assert_true(e8 is CameraError::UnsupportedSize(0, 0))
  stub_reset()
  let e9 = expect_camera_error(
    () => Camera::open(vm, test_config("0", 320, 240, 0)) |> ignore,
    "bad pool",
  )
  assert_true(e9 is CameraError::OpenFailed(-13, _))
  stub_reset()
}

///|
test "failed create_reader releases camera handle in reverse order" {
  stub_reset()
  let vm = stub_fake_vm()
  stub_set_reader_status(-1)
  let e = expect_camera_error(
    () => Camera::open(vm, test_config("0", 320, 240, 2)) |> ignore,
    "reader failure",
  )
  assert_true(e is CameraError::OpenFailed(-1, _))
  assert_eq(stub_live_cameras(), 0) // 逆序释放：camera 句柄已归还
  assert_eq(stub_live_readers(), 0)
}

///|
test "start_preview failure maps to PreviewFailed" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  stub_set_preview_status(-10)
  let e1 = expect_camera_error(() => Camera::start_preview(cam), "preview -10")
  assert_true(e1 is CameraError::PreviewFailed(-10, _))
  stub_set_preview_status(-1)
  let e2 = expect_camera_error(() => Camera::start_preview(cam), "preview -1")
  assert_true(e2 is CameraError::PreviewFailed(-1, _))
  Camera::close(cam)
}

///|
test "opening the same device twice raises AlreadyOpen" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  let e = expect_camera_error(
    () => Camera::open(vm, test_config("0", 320, 240, 2)) |> ignore,
    "double open",
  )
  assert_true(e is CameraError::AlreadyOpen)
  assert_eq(stub_live_cameras(), 1) // 第二次 open 未泄漏
  Camera::close(cam)
}

///|
test "owner thread mismatch raises JniThreadNotAttached" {
  stub_reset()
  // 线程归属守卫（grab_yuv/start_preview/on_frame 均经此校验）
  let e = expect_camera_error(
    () => ensure_owner(123456UL),
    "wrong owner thread",
  )
  assert_true(e is CameraError::JniThreadNotAttached(_))
  ensure_owner(mb_camera2_current_thread_id()) // 正确线程通过
}

///|
test "status mapper covers unambiguous codes and site fallbacks" {
  match map_unambiguous(-2, "x", 4, 4) {
    Some(e) => assert_true(e is CameraError::PermissionDenied("x"))
    None => fail("map -2")
  }
  match map_unambiguous(-3, "x", 4, 4) {
    Some(e) => assert_true(e is CameraError::CameraNotFound("x"))
    None => fail("map -3")
  }
  match map_unambiguous(-4, "x", 4, 4) {
    Some(e) => assert_true(e is CameraError::UnsupportedSize(4, 4))
    None => fail("map -4")
  }
  match map_unambiguous(-5, "x", 4, 4) {
    Some(e) => assert_true(e is CameraError::UnsupportedFormat("x"))
    None => fail("map -5")
  }
  match map_unambiguous(-8, "x", 4, 4) {
    Some(e) => assert_true(e is CameraError::JniThreadNotAttached("x"))
    None => fail("map -8")
  }
  match map_unambiguous(-9, "x", 4, 4) {
    Some(e) => assert_true(e is CameraError::VendorQuirk("x"))
    None => fail("map -9")
  }
  match map_unambiguous(-14, "x", 4, 4) {
    Some(e) => assert_true(e is CameraError::AlreadyOpen)
    None => fail("map -14")
  }
  match map_unambiguous(-1, "x", 4, 4) {
    None => ()
    Some(_) => fail("map -1 should fall through to site mapping")
  }
  assert_true(open_error(-1, "c", 1, 2) is CameraError::OpenFailed(-1, "c"))
  assert_true(
    preview_error(-1, "c", 1, 2) is CameraError::PreviewFailed(-1, "c"),
  )
  assert_true(
    acquire_error(-11, 20, 3, "c", 1, 2) is CameraError::BufferAcquireFailed(20),
  )
  assert_true(
    acquire_error(-7, 20, 3, "c", 1, 2) is CameraError::BufferPoolExhausted(3),
  )
  assert_true(
    acquire_error(-6, 20, 3, "c", 1, 2) is CameraError::BufferAcquireFailed(-6),
  )
  assert_true(
    acquire_error(-1, 20, 3, "c", 1, 2) is CameraError::BufferAcquireFailed(-1),
  )
}

///|
test "parse_yuv_frame rejects malformed frame headers" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  let (buf, written) = raw_acquire(cam.reader)
  // 合法缓冲解析成功
  let frame = parse_yuv_frame(buf, written)
  check_frame(frame, 0, 320, 240, "valid parse")
  mb_camera2_release_frame(cam.reader)
  // 截断
  let e1 = expect_camera_error(
    () => parse_yuv_frame(buf, 10) |> ignore,
    "truncated",
  )
  assert_true(e1 is CameraError::UnsupportedFormat(_))
  // 非法维度
  write_i32_le(buf, 0, 0)
  let e2 = expect_camera_error(
    () => parse_yuv_frame(buf, written) |> ignore,
    "zero width",
  )
  assert_true(e2 is CameraError::UnsupportedFormat(_))
  write_i32_le(buf, 0, 320)
  // plane1 offset 越界
  write_i32_le(buf, 32, written + 100)
  let e3 = expect_camera_error(
    () => parse_yuv_frame(buf, written) |> ignore,
    "offset out of bounds",
  )
  assert_true(e3 is CameraError::UnsupportedFormat(_))
  write_i32_le(buf, 32, 64 + 328 * 240)
  // row_stride = 0
  write_i32_le(buf, 24, 0)
  let e4 = expect_camera_error(
    () => parse_yuv_frame(buf, written) |> ignore,
    "zero row_stride",
  )
  assert_true(e4 is CameraError::UnsupportedFormat(_))
  write_i32_le(buf, 24, 328)
  // row_stride 覆盖不了样本
  write_i32_le(buf, 28, 4) // Y pixel_stride = 4 → 行跨度 1277 > 328
  let e5 = expect_camera_error(
    () => parse_yuv_frame(buf, written) |> ignore,
    "stride too small",
  )
  assert_true(e5 is CameraError::UnsupportedFormat(_))
  Camera::close(cam)
}

///|
test "parse_camera_infos rejects malformed enumeration buffers" {
  stub_reset()
  let vm = stub_fake_vm()
  ignore(mb_camera2_init(vm)) // raw 调用前先建立 VM 会话
  let buf = FixedArray::make(8192, b'\x00')
  let written = mb_camera2_enumerate_raw(vm, buf, 8192)
  assert_true(written > 0)
  // 合法缓冲解析成功
  let infos = parse_camera_infos(buf, written)
  assert_eq(infos.length(), 4)
  // 截断
  let e1 = expect_camera_error(
    () => parse_camera_infos(buf, 6) |> ignore,
    "truncated enum",
  )
  assert_true(e1 is CameraError::UnsupportedFormat(_))
  // 非法 count
  write_i32_le(buf, 0, 999)
  let e2 = expect_camera_error(
    () => parse_camera_infos(buf, written) |> ignore,
    "bad count",
  )
  assert_true(e2 is CameraError::UnsupportedFormat(_))
  write_i32_le(buf, 0, 4)
  // 非法 facing（第一台：count(4) + id_len(4) + id"0"(1) = 偏移 9）
  write_i32_le(buf, 9, 7)
  let e3 = expect_camera_error(
    () => parse_camera_infos(buf, written) |> ignore,
    "bad facing",
  )
  assert_true(e3 is CameraError::UnsupportedFormat(_))
}

///|
/// ---- R4 marshal 层：并发 / 竞态 / 错误路径 ----

///|
test "marshal: pump dispatches queued frames on the owner thread in FIFO order" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  let tids : Array[UInt64] = []
  let seen : Array[YuvFrame] = []
  Camera::on_frame(cam, fn(f) {
    tids.push(mb_camera2_current_thread_id())
    seen.push(f)
  })
  assert_eq(stub_produce(cam.reader), 0) // 3 帧只入队
  assert_eq(stub_produce(cam.reader), 0)
  assert_eq(stub_produce(cam.reader), 0)
  assert_eq(stub_marshal_pending(cam.reader), 3)
  assert_eq(seen.length(), 0) // 未 pump 前闭包不执行
  assert_eq(Camera::pump_marshal(cam, 8), 3)
  assert_eq(seen.length(), 3)
  check_frame(seen[0], 0, 320, 240, "marshal frame 0")
  check_frame(seen[1], 1, 320, 240, "marshal frame 1")
  check_frame(seen[2], 2, 320, 240, "marshal frame 2")
  // FIFO = 线性化顺序：时间戳严格递增
  assert_true(seen[0].timestamp_ns < seen[1].timestamp_ns)
  assert_true(seen[1].timestamp_ns < seen[2].timestamp_ns)
  // 闭包全部在 owner（本测试线程）执行
  for t in tids {
    assert_eq(t, mb_camera2_current_thread_id())
  }
  assert_eq(Camera::pump_marshal(cam, 8), 0) // 队列已空
  Camera::close(cam)
  assert_eq(stub_marshal_live_events(), 0)
}

///|
test "marshal: multi-thread delivery is fully accounted (dispatched + dropped + queued)" {
  stub_reset()
  stub_set_threaded(1) // 投递线程只入队
  stub_set_frame_interval_ms(5)
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  let calls : Array[Int32] = [0]
  Camera::on_frame(cam, fn(_f) { calls[0] = calls[0] + 1 })
  stub_set_frame_count(20) // 投递预算恰好 20 帧（先设预算再开投递）
  Camera::start_preview(cam)
  let mut rounds = 0
  for _ in 0..<100 {
    ignore(Camera::pump_marshal(cam, 16))
    stub_sleep(5)
    rounds = rounds + 1
    if stub_marshal_pushed(cam.reader) >= 20 {
      break
    }
  }
  assert_true(rounds < 100) // 未打满等待上限（防挂死）
  ignore(Camera::pump_marshal(cam, 16)) // 排空
  let pushed = stub_marshal_pushed(cam.reader)
  let dropped = stub_marshal_dropped(cam.reader)
  assert_eq(pushed, 20) // 预算恰好 20，无多投
  assert_eq(stub_marshal_pending(cam.reader), 0) // 已排空
  // 每个事件有归属：派发 / 满队列丢弃 / 在队（此处为 0）
  assert_eq(calls[0] + dropped, 20)
  Camera::close(cam)
  assert_eq(stub_marshal_live_events(), 0)
  assert_eq(stub_live_closures(), 0)
}

///|
test "marshal: full queue drops oldest (keep-latest) and reports drops" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  let seen : Array[YuvFrame] = []
  Camera::on_frame(cam, fn(f) { seen.push(f) })
  for _ in 0..<13 { // 队列容量 8：13 = 8 在队 + 5 溢出
    assert_eq(stub_produce(cam.reader), 0)
  }
  assert_eq(stub_marshal_pending(cam.reader), 8) // 有界
  assert_eq(stub_marshal_dropped(cam.reader), 5) // 丢最旧 5 帧
  assert_eq(Camera::pump_marshal(cam, 16), 8)
  assert_eq(seen.length(), 8)
  // keep-latest：保留最新 8 帧（k=5..12），FIFO 派发
  check_frame(seen[0], 5, 320, 240, "drop-oldest first kept")
  check_frame(seen[7], 12, 320, 240, "drop-oldest last kept")
  for i in 1..<seen.length() {
    assert_true(seen[i].timestamp_ns > seen[i - 1].timestamp_ns)
  }
  Camera::close(cam)
  assert_eq(stub_marshal_live_events(), 0)
}

///|
test "marshal: reentrant pump raises MarshalReentrant; outer pump completes" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  let calls : Array[Int32] = [0]
  let reentrant : Array[CameraError] = []
  Camera::on_frame(cam, fn(_f) {
    calls[0] = calls[0] + 1
    if calls[0] == 1 {
      // 回调内重入 pump：必须以 CameraError 拒绝，且不 panic
      ignore(Camera::pump_marshal(cam, 8)) catch {
        e => reentrant.push(e)
      }
    }
  })
  assert_eq(stub_produce(cam.reader), 0)
  assert_eq(stub_produce(cam.reader), 0)
  assert_eq(stub_produce(cam.reader), 0)
  assert_eq(Camera::pump_marshal(cam, 8), 3) // 外层 pump 正常派发完
  assert_eq(calls[0], 3)
  assert_eq(reentrant.length(), 1) // 恰好拒绝一次，走 Error 枚举
  assert_true(reentrant[0] is CameraError::MarshalReentrant(_))
  Camera::close(cam)
  assert_eq(stub_marshal_live_events(), 0)
}

///|
test "marshal: clear/replace/grab inside callback are safe (deferred release)" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  let first : Array[Int32] = [0]
  let second : Array[Int32] = [0]
  Camera::on_frame(cam, fn(_f) {
    first[0] = first[0] + 1
    // 回调内重入同步取帧（递归锁）：不 panic 且缓冲归还
    ignore(Camera::grab_yuv(cam, 50)) catch {
      _ => ()
    }
    // 回调内替换注册：旧闭包正在执行，RC 由派发前 incref 保护
    Camera::on_frame(cam, fn(_g) { second[0] = second[0] + 1 }) catch {
      _ => ()
    }
    // 回调内注销（新回调被清）：释放成对、不泄漏
    Camera::clear_on_frame(cam) catch {
      _ => ()
    }
  })
  assert_eq(stub_produce(cam.reader), 0)
  assert_eq(stub_produce(cam.reader), 0)
  // 两事件均消费：第 1 个派发，第 2 个时注册已清 → 丢弃排水
  assert_eq(Camera::pump_marshal(cam, 8), 2)
  assert_eq(first[0], 1)
  assert_eq(second[0], 0)
  assert_eq(stub_live_closures(), 0) // 注销后无泄漏
  assert_eq(stub_inflight(cam.reader), 0) // 回调内 grab 的缓冲已归还
  Camera::close(cam)
  assert_eq(stub_live_closures(), 0)
  assert_eq(stub_marshal_live_events(), 0)
}

///|
test "marshal: close inside callback defers teardown and rejects later ops" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  let calls : Array[Int32] = [0]
  Camera::on_frame(cam, fn(_f) {
    calls[0] = calls[0] + 1
    Camera::close(cam) // 回调内 close：结构体释放延迟到 pump 收尾
     catch {
      _ => ()
    }
  })
  assert_eq(stub_produce(cam.reader), 0)
  assert_eq(stub_produce(cam.reader), 0) // 第 2 事件派发前会话已死，不再触发
  assert_eq(Camera::pump_marshal(cam, 8), 1) // 只消费 1 个（close 后停派发）
  assert_eq(calls[0], 1)
  // 延迟释放已在 pump 收尾完成：资源全部归零，无泄漏、无二次释放
  assert_eq(stub_live_cameras(), 0)
  assert_eq(stub_live_readers(), 0)
  assert_eq(stub_live_closures(), 0)
  assert_eq(stub_marshal_live_events(), 0)
  // 后续操作一律 AlreadyClosed（不 panic）
  let e1 = expect_camera_error(
    () => Camera::grab_yuv(cam, 10) |> ignore,
    "grab after in-callback close",
  )
  assert_true(e1 is CameraError::AlreadyClosed)
  let e2 = expect_camera_error(() => Camera::close(cam), "repeated close")
  assert_true(e2 is CameraError::AlreadyClosed)
  let e3 = expect_camera_error(
    () => Camera::pump_marshal(cam, 8) |> ignore,
    "pump after close",
  )
  assert_true(e3 is CameraError::AlreadyClosed)
}

///|
test "marshal: release after delivery frees queued events without dispatch" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  let calls : Array[Int32] = [0]
  Camera::on_frame(cam, fn(_f) { calls[0] = calls[0] + 1 })
  assert_eq(stub_produce(cam.reader), 0)
  assert_eq(stub_produce(cam.reader), 0)
  assert_eq(stub_produce(cam.reader), 0)
  assert_eq(stub_marshal_pending(cam.reader), 3) // 已投递未派发
  Camera::close(cam) // 投递后直接释放：队列事件全部释放
  assert_eq(calls[0], 0) // 从未派发
  assert_eq(stub_marshal_live_events(), 0) // 无泄漏
  assert_eq(stub_live_closures(), 0)
  // 第二段：clear 后 pump 丢弃排水（不派发）
  stub_reset()
  let cam2 = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam2)
  Camera::on_frame(cam2, fn(_f) { calls[0] = calls[0] + 1 })
  assert_eq(stub_produce(cam2.reader), 0)
  assert_eq(stub_produce(cam2.reader), 0)
  Camera::clear_on_frame(cam2)
  assert_eq(Camera::pump_marshal(cam2, 8), 2) // 事件被消费但丢弃（无回调）
  assert_eq(calls[0], 0) // 注销后不触发
  assert_eq(stub_marshal_pending(cam2.reader), 0)
  Camera::close(cam2)
  assert_eq(stub_marshal_live_events(), 0)
}

///|
test "marshal: pump error paths map to CameraError; marshal_next misuse is non-panicking" {
  stub_reset()
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  // max_events < 1：invalid arg 走 Error 枚举
  let e1 = expect_camera_error(
    () => Camera::pump_marshal(cam, 0) |> ignore,
    "pump with max_events=0",
  )
  assert_true(e1 is CameraError::OpenFailed(-13, _))
  let e2 = expect_camera_error(
    () => Camera::pump_marshal(cam, -3) |> ignore,
    "pump with negative max_events",
  )
  assert_true(e2 is CameraError::OpenFailed(-13, _))
  // marshal_next 非派发期间误用：负数返回，不 panic（白盒直调）
  let buf = FixedArray::make(64, b'\x00')
  assert_true(mb_camera2_marshal_next(cam.reader, buf, 64) < 0)
  // pump_error 映射覆盖
  assert_true(pump_error(-15, "c") is CameraError::MarshalReentrant("c"))
  assert_true(pump_error(-8, "c") is CameraError::JniThreadNotAttached("c"))
  assert_true(pump_error(-1, "c") is CameraError::OpenFailed(-1, "c"))
  // 空队列 pump：0 事件，不 panic
  assert_eq(Camera::pump_marshal(cam, 8), 0)
  Camera::close(cam)
}

///|
test "marshal: out-of-order concurrent pushes dispatch in linearized FIFO order" {
  stub_reset()
  stub_set_threaded(1) // 投递线程
  stub_set_frame_interval_ms(3)
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  let seen : Array[YuvFrame] = []
  Camera::on_frame(cam, fn(f) { seen.push(f) })
  Camera::start_preview(cam)
  // owner 线程也投递（与投递线程并发 push，乱序竞争入队）
  for _ in 0..<10 {
    assert_eq(stub_produce(cam.reader), 0)
    ignore(Camera::pump_marshal(cam, 4))
    stub_sleep(3)
  }
  stub_set_frame_count(0) // 停止一切再投递（确定性收尾）
  stub_quiesce()
  stub_sleep(10)
  ignore(Camera::pump_marshal(cam, 16)) // 排空
  assert_true(seen.length() >= 1)
  // 并发乱序投递被锁串行化：派发顺序 = 线性化入队顺序（时间戳严格递增）
  for i in 1..<seen.length() {
    assert_true(seen[i].timestamp_ns > seen[i - 1].timestamp_ns)
  }
  // 全部事件有归属：派发 + 丢弃 == 入队
  let pushed = stub_marshal_pushed(cam.reader)
  let dropped = stub_marshal_dropped(cam.reader)
  assert_true(pushed >= 10)
  assert_eq(stub_marshal_pending(cam.reader), 0)
  assert_eq(seen.length() + dropped, pushed)
  Camera::close(cam)
  assert_eq(stub_marshal_live_events(), 0)
}
