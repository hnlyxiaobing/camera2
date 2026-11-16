# camera2 · Camera2 JNI 取帧

> 独立发布单元 ｜ L3 感知绑定 ｜ `preferred_target = native` ｜ Apache-2.0
> 状态：`moon test` **31/31** 通过（2026-11-11 本机实测）；本文件是本仓库**唯一**说明文档。
> 公开 API 以 `pkg.generated.mbti` 为准（由 `moon info` 生成，禁手工编辑）；加法性变更须登记簿记 + 快照审阅 + 快照门禁。

## 1. 定位与边界

把 Android Camera2 的帧封装成可替换的 `YuvFrame`，并把回调安全送回 owner 线程。

**能力**

- `Camera::{open,start_preview,grab_yuv,on_frame,clear_on_frame,pump_marshal,close}` 与 `enumerate_cameras`
- 15 个包私有 `mb_camera2_*` C shim（9 核心 + 2 marshal + 4 internal），桌面 native-stub 可全链路测试
- E1 回调 marshal 层：投递线程浅拷贝入有界队列（容量 8，keep-latest），owner 线程 `pump_marshal` 派发，重入抛 `MarshalReentrant`
- `FrameSource` 契约冻结，`CameraState` 收紧为单分支 `Open`，`close` 幂等

**非目标**

- 不执行真实 JNI 调用（当前为桌面 stub）；不引入 `ajni@0.3.6` / `justjavac/camera`
- 不做 Camera1 / UVC 回退；不感知 `yuv` / `pose` 类型

## 2. 关键设计决策（本仓库自足记录）

- 只缓存 `JavaVM*` 不缓存 `JNIEnv*`（线程局部）；`FuncRef` 只接受无捕获闭包，`#owned` 闭包在 detach/close 成对 decref。
- 被钩/投递线程**从不**执行 MoonBit 闭包，这是设计不变量而非待验证假设。
- `preferred_target = native`（`extern "C"` 在 wasm 后端不受支持）。
- 相机是可替换帧源，不是 `pose` 的前置条件。

## 3. 公开 API 索引（自动抽取 `pkg.generated.mbti` 的 `pub` 声明行；完整字段见快照）

```text
pub fn enumerate_cameras(JavaVMPtr) -> Array[CameraInfo] raise CameraError
pub(all) suberror CameraError {
pub(all) struct Camera {
pub fn Camera::clear_on_frame(Self) -> Unit raise CameraError
pub fn Camera::close(Self) -> Unit raise CameraError
pub fn Camera::grab_yuv(Self, Int32) -> YuvFrame raise CameraError
pub fn Camera::on_frame(Self, (YuvFrame) -> Unit) -> Unit raise CameraError
pub fn Camera::open(JavaVMPtr, CameraConfig) -> Self raise CameraError
pub fn Camera::pump_marshal(Self, Int32) -> Int32 raise CameraError
pub fn Camera::start_preview(Self) -> Unit raise CameraError
pub(all) struct CameraConfig {
pub(all) struct CameraInfo {
pub(all) enum CameraState {
pub(all) enum Facing {
pub(all) struct FrameSize {
pub(all) struct YuvFrame {
pub(all) struct YuvPlane {
pub(open) trait FrameSource {
```

## 4. 依赖、平台与许可

零第三方依赖（仅 core + `native-stub: stub/camera2_stub.c`）；`preferred_target = native`；Apache-2.0；Android SDK License 3.4 不可再分发。

## 5. 命令行与验证

- 本库无独立 CLI；`cmd/main` 为冒烟全链路示例。
- 复验：`moon clean` → `moon check --deny-warn` → `moon build` → `moon test` → `moon fmt --check` → `moon info` 后检查 `pkg.generated.mbti` 无意外 diff。
- 本仓库为独立 Git 仓库，文档与 CI 均自包含，不依赖工作区其他目录。

## 6. 风险与未决

- E1 原始 Linux pthread 直调实验在本机 Windows 未实测；本地已用并发/重入/关闭竞态白盒测试替代其设计目的。
- E4：`ajni` 在目标设备的 JNI 真机调用尚未实证；Q9（Camera1/UVC 回退必要性）未探测。
- `camera2::YuvFrame` 无 `format` 字段、`yuv::YuvFrame` 有，组合根须显式选 `Yuv420888`。

