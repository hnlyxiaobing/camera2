// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs to `_test.mbt`.
//
// 本文件覆盖：全链路、状态机（未 open 拒绝 / 重复 close）、缓冲池耗尽与
// acquire→release 归还、可配置帧序列、三平面 stride 描述与非紧凑 padding、
// 回调注册/触发/注销后不再触发、#owned 闭包 set/clear 成对、错误映射、
// 解析校验。回调线程约束按 ADR-0009：stub 可从独立投递线程调回调，
// MoonBit 侧断言投递线程 ≠ owner 线程（用户回调须自行 marshal 到 owner 线程）。

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
  assert_eq(stub_produce(cam.reader), 0) // 投递第 0 帧
  assert_eq(hits[0], 1)
  assert_eq(seen.length(), 1)
  check_frame(seen[0], 0, 320, 240, "callback frame")
  assert_eq(stub_inflight(cam.reader), 0) // 回调路径 acquire→release 已归还
  let frame = Camera::grab_yuv(cam, 100) // 同步路径自动产第 1 帧
  check_frame(frame, 1, 320, 240, "grabbed frame")
  assert_eq(stub_inflight(cam.reader), 0) // 每帧缓冲均归还
  Camera::clear_on_frame(cam)
  assert_eq(stub_live_closures(), 0)
  let before = hits[0]
  assert_eq(stub_produce(cam.reader), 0) // 注销后投递
  assert_eq(stub_callback_calls(cam.reader), 0) // C 侧不再派发（clear 已清零）
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
test "callback fires on delivery thread and stops after clear_on_frame" {
  stub_reset()
  stub_set_threaded(1) // 独立投递线程（模拟相机投递线程）
  stub_set_frame_interval_ms(5)
  let vm = stub_fake_vm()
  let cam = Camera::open(vm, test_config("0", 320, 240, 2))
  Camera::start_preview(cam)
  let calls : Array[Int32] = [0]
  let tids : Array[UInt64] = [0UL]
  Camera::on_frame(cam, fn(_f) {
    calls[0] = calls[0] + 1
    tids[0] = mb_camera2_current_thread_id()
  })
  stub_sleep(150)
  stub_quiesce() // 等投递排空（C 侧休眠，不动 MoonBit RC）
  assert_true(calls[0] >= 1)
  // ADR-0009：回调在投递线程触发，≠ owner 线程；用户回调须 marshal 到 owner 线程
  assert_true(tids[0] != mb_camera2_current_thread_id())
  Camera::clear_on_frame(cam)
  let before = calls[0]
  stub_sleep(120)
  stub_quiesce()
  assert_eq(calls[0], before) // 注销后不再触发
  Camera::close(cam) // join 投递线程并释放
  assert_eq(stub_live_closures(), 0)
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
  assert_eq(seen1[0], 0) // 旧回调不再触发
  assert_eq(seen2[0], 1)
  assert_eq(stub_inflight(cam.reader), 0) // 回调取帧后归还
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
