///|
/// camera2 桌面冒烟入口：链接并跑通公开 API 全链路（enumerate→open→
/// start_preview→grab_yuv→close），使 `moon build` 真实校验 shim ABI。
/// 桌面 stub 环境用假 JavaVM 句柄；R2 由 ajni host bridge 提供真实 `JavaVM*`。
/// Run with `moon run cmd/main` from the project root.

///|
/// 桌面 stub 假 JavaVM 句柄（符号由 stub/camera2_stub.c 提供）。
extern "C" fn stub_fake_vm() -> @camera2.JavaVMPtr = "mb_camera2_stub_fake_vm"

///|
fn main {
  let vm = stub_fake_vm()
  try {
    let infos = @camera2.enumerate_cameras(vm)
    println("camera2 smoke: \{infos.length()} cameras")
    let config = @camera2.CameraConfig::{
      camera_id: "0",
      size: @camera2.FrameSize::{ width: 640, height: 480, },
      max_inflight_buffers: 2,
      rotation_degrees: 0,
      mirror_x: false,
    }
    let cam = @camera2.Camera::open(vm, config)
    @camera2.Camera::start_preview(cam)
    let frame = @camera2.Camera::grab_yuv(cam, 1000)
    println(
      "camera2 smoke: frame \{frame.width}x\{frame.height}, \{frame.planes.length()} planes",
    )
    @camera2.Camera::close(cam)
    println("camera2 smoke OK")
  } catch {
    _ => println("camera2 smoke FAILED")
  }
}
