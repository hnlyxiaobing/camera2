// Blackbox tests run against the package's public API. Use `@camera2` to import.
// Prefer high-level behaviors over implementation details.
// Run `moon test` to execute and `moon test --update` to refresh snapshots.
//
// 覆盖：YuvFrame/YuvPlane 值类型构造与 stride 描述、包外构造 CameraError、
// 包外实现 FrameSource（可替换帧源设计：文件帧源替身，见 docs/DECISIONS.md）。

///|
fn b_bytes(vals : Array[Int32]) -> Bytes {
  Bytes::makei(vals.length(), i => vals[i].to_byte())
}

///|
fn expect_pub_error(
  f : () -> Unit raise @camera2.CameraError,
  what : String,
) -> @camera2.CameraError raise Failure {
  try f() catch {
    err => err
  } noraise {
    _ => fail("\{what}: expected CameraError")
  }
}

///|
test "YuvFrame and YuvPlane value construction preserves stride descriptors" {
  let y = @camera2.YuvPlane::{
    data: b_bytes([1, 2, 3, 4]),
    row_stride: 2,
    pixel_stride: 1,
  }
  let u = @camera2.YuvPlane::{
    data: b_bytes([5, 6]),
    row_stride: 2,
    pixel_stride: 2,
  }
  let v = @camera2.YuvPlane::{
    data: b_bytes([7, 8]),
    row_stride: 2,
    pixel_stride: 2,
  }
  let frame = @camera2.YuvFrame::{
    width: 2,
    height: 2,
    planes: [y, u, v],
    timestamp_ns: 42UL,
  }
  assert_eq(frame.width, 2)
  assert_eq(frame.height, 2)
  assert_eq(frame.timestamp_ns, 42UL)
  assert_eq(frame.planes.length(), 3)
  assert_eq(frame.planes[0].row_stride, 2)
  assert_eq(frame.planes[0].pixel_stride, 1)
  assert_eq(frame.planes[1].pixel_stride, 2)
  assert_eq(frame.planes[2].row_stride, 2)
  assert_eq(frame.planes[2].pixel_stride, 2)
  assert_eq(frame.planes[0].data.at(3).to_int(), 4)
}

///|
test "CameraError can be constructed and matched outside the package" {
  let e : @camera2.CameraError = @camera2.CameraError::OpenFailed(-3, "x")
  assert_true(e is @camera2.CameraError::OpenFailed(-3, "x"))
  assert_true(
    @camera2.CameraError::AlreadyClosed is @camera2.CameraError::AlreadyClosed,
  )
  let e2 = @camera2.CameraError::BufferPoolExhausted(2)
  assert_true(e2 is @camera2.CameraError::BufferPoolExhausted(2))
}

///|
/// 包外实现 FrameSource：文件帧源替身（组合根可替换帧源，见 docs/DECISIONS.md）。
struct FileSource {
  frames : Array[@camera2.YuvFrame]
  cursor : Array[Int32]
  closed : Array[Bool]
}

///|
impl @camera2.FrameSource for FileSource with fn grab_yuv(self) {
  if self.closed[0] {
    raise @camera2.CameraError::AlreadyClosed
  }
  let i = self.cursor[0]
  if i >= self.frames.length() {
    raise @camera2.CameraError::CameraNotFound("file frame source exhausted")
  }
  self.cursor[0] = i + 1
  self.frames[i]
}

///|
impl @camera2.FrameSource for FileSource with fn close(self) {
  if self.closed[0] {
    raise @camera2.CameraError::AlreadyClosed
  }
  self.closed[0] = true
}

///|
extend FileSource with @camera2.FrameSource::{grab_yuv, close}

///|
test "FrameSource can be implemented outside the package" {
  let y = @camera2.YuvPlane::{
    data: b_bytes([9]),
    row_stride: 1,
    pixel_stride: 1,
  }
  let u = @camera2.YuvPlane::{
    data: b_bytes([8]),
    row_stride: 1,
    pixel_stride: 1,
  }
  let v = @camera2.YuvPlane::{
    data: b_bytes([7]),
    row_stride: 1,
    pixel_stride: 1,
  }
  let frame = @camera2.YuvFrame::{
    width: 1,
    height: 1,
    planes: [y, u, v],
    timestamp_ns: 0UL,
  }
  let src = FileSource::{ frames: [frame], cursor: [0], closed: [false], }
  let got = src.grab_yuv()
  assert_eq(got.width, 1)
  assert_eq(got.planes[0].data.at(0).to_int(), 9)
  // 帧耗尽后可判错误
  let e1 = expect_pub_error(() => src.grab_yuv() |> ignore, "exhausted")
  assert_true(e1 is @camera2.CameraError::CameraNotFound(_))
  src.close()
  let e2 = expect_pub_error(() => src.close(), "repeated close")
  assert_true(e2 is @camera2.CameraError::AlreadyClosed)
  let e3 = expect_pub_error(() => src.grab_yuv() |> ignore, "grab after close")
  assert_true(e3 is @camera2.CameraError::AlreadyClosed)
}
