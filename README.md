# hnlyxiaobing/camera2

**Android Camera2 的 JNI 封装 —— 权限、打开、预览 Surface、ImageReader 取 YUV 与关闭的完整相机生命周期。**

> 状态：**实现完成（2026-11-07，桌面 stub 阶段）**。全部导出接口已实现，`moon build` / `moon test` 全绿（21 测试，`0068` 清零）。本阶段自带**桌面 C stub**（`stub/camera2_stub.c`）模拟 JavaVM/ImageReader/相机会话；**真实 JNI / Java 样板 / ajni / 设备取帧留待后续真实对接阶段**（ajni 在 Windows 主机 + 目标设备真机的可用性未实证，见「风险与待验证」）。
> **API 冻结前整改已落实**：`FrameSource` 方法集冻结（`grab_yuv(Self)`，trait 层无超时参数，超时策略由具体帧源实现自行定义）· `CameraError` 追认 `pub(all) suberror` · `CameraState` 收紧为 `Open` 单分支 · 9 个 `mb_camera2_*` shim 移出公开 API（包私有，私有实现 ABI）· `close` 幂等措辞统一为「不会二次释放，重复调用返回明确错误」。门禁 `moon clean` / `moon check --deny-warn` / `moon build` / `moon test` / `moon fmt --check` 全绿。
> `preferred_target` 已由 `wasm` 改为 `native`（唯一配置改动，理由见 `DECISIONS.md`「preferred_target 由 wasm 改为 native」）。

## 定位与为什么存在

生态检索复核（2026-11-06）：`camera2` 命中全为 2D 游戏相机误报。Camera2 是平台 Java API（NDK camera2ndk 需 API 24+），2026-11-06 检索 mooncakes.io 无 Android 取帧绑定（`justjavac/camera@0.1.3`(MIT) 是桌面 native 摄像头发现，不能替代 Android 取帧），故走 **FFI-JNI 封装**。本库是感知闭环的**可替换帧源**，产出中性 `YuvFrame`。

**关键设计（JNI 线程亲和性与回调所有权，完整决策见 `DECISIONS.md`）**：JNI 线程亲和性决定 `JNIEnv*` 绝不进入 MoonBit 值类型；`JavaVM*` 只在 C 侧缓存；帧回调在相机投递线程触发，必须 marshal 到 owner 线程；`FuncRef` 只能无捕获，回调状态（global ref / attach 状态）下沉到 C shim。因此「胶水 C 文件极薄」的说法应修正为「**薄在 ABI 转发，厚在生命周期与线程编排**」。

## 能力范围 / 非目标

- **做**：进程级 JNI 初始化、相机打开、ImageReader(YUV_420_888) 创建、重复预览请求、同步取帧、帧回调注册/注销、缓冲归还、关闭释放、相机能力枚举。
- **不做**：推理、渲染、YUV→RGB 转换、权限 UI、Camera2 厂商 quirk 自动修复、视频编码、Surface 渲染。
- 相机是**可替换帧源**：`pose` / `yuv` 不依赖本库，组合根可换成本地图片 / RTSP / 桌面摄像头（见 `DECISIONS.md`「可替换帧源设计（FrameSource trait）」）。

## 公开接口（速览）

`Camera::{open, start_preview, grab_yuv, on_frame, clear_on_frame, close}`、`enumerate_cameras`。外部句柄与 shim 清单见 `API.md`。

## 依赖

- **零外部依赖**；独立 `moon.mod`，`moon check --deny-warn` 独立通过。shim 实现仅为**项目内** `stub/camera2_stub.c` 桌面 stub（9 个 `mb_camera2_*` 为包私有 ABI，非公共 API），**未链接/下载任何外部库**。
- 后续阶段：`Nanaloveyuki/ajni@0.3.6`（Apache-2.0，双向 checked JNI + Android host bridge）、Java 侧约 200 行 Camera2 样板、真实 `native-stub` C 文件。**均未引入**——`ajni` 为 0.x 且作者自述 "Windows/macOS desktop ABI support is not claimed"，需按依赖门槛（用途/许可/维护/平台/风险）评估后再引入（见 `DECISIONS.md`「ajni 只作设计参照，真实 JNI 样板排后」）。

## 风险与待验证

- 平台：`preferred_target = "native"`；Android API 24+（NDK camera2ndk）或 Java Camera2 + ajni。
- 许可：本仓库 Apache-2.0；`ajni` Apache-2.0；Android SDK / NDK 二进制**不可再分发**（SDK License 3.4）。
- 风险：各厂商 Camera2 实现差异（部分 TV 只有 Camera1/UVC）；权限与后台限制；ImageReader 缓冲池耗尽；`AIMAGE_FORMAT_YUV_420_888` 三平面必须按 `row_stride`/`pixel_stride` 读取，不能假设紧凑布局。
- `[待验证假设]` **ajni 真机可用性**：ajni 在 Windows 主机 + 目标设备真机（红米电视 Android 9 / armeabi-v7a）未实证（作者仅对部分平台实证，桌面 ABI 不承诺）。
- `[待验证假设]` **回调线程安全**：相机投递线程执行 MoonBit 闭包的线程安全（GC、引用计数、重入）未实测。
- `[待验证假设]` **Camera1/UVC 回退必要性**：部分 TV 设备只有 Camera1，是否需要 Camera1/UVC 回退未实测；Camera2 厂商差异范围待一次能力探测确认。

## 测试与验收

- **测试策略**：设备取 720p YUV 帧；缓冲池耗尽 / 超时注入；回调线程归属断言（不得在回调内直接 JNI）；权限拒绝 / 设备不存在 / 尺寸不支持路径；`moon test --enable-coverage`。
- **验收标准**（实现阶段）：在红米电视与外接 UVC 摄像头上取到 720p YUV 帧；`close` **不会二次释放，重复调用返回明确错误（`AlreadyClosed`）**；每帧都被归还。
- **桌面 stub 实测（2026-11-07）**：`moon build` ✅ / `moon test` ✅ 21/21（全链路、状态机、池耗尽、回调 set/clear 成对、stride 描述、错误映射、解析校验）；设备取帧验收留待真实对接阶段。

## 当前状态 / 已有产物

| 项 | 状态 |
|---|---|
| `camera2.mbt` + `internal.mbt`：5 个 `#external` 句柄、9 个**包私有** `extern "C"` shim（私有实现 ABI，非公共 API）、公开 API ×7 全部实现（状态守卫 / 错误映射 / YUV 校验） | ✅ |
| `stub/camera2_stub.c` 桌面 stub（假设备枚举、可配置帧序列、缓冲池、`#owned` 闭包成对持有/释放、投递线程回调；19 个测试替身可注入池耗尽/超时/线程错配） | ✅ |
| `camera2_wbtest.mbt` / `camera2_test.mbt` 测试 ×21（黑盒不直接调用 shim） | ✅ |
| `pkg.generated.mbti` API 快照（工具链在 `moon check` / `moon build` 时自动同步至整改后公开面：9 个 shim 移除、`CameraState` 收紧为 `Open`） | ✅ |
| `moon clean` / `moon check --deny-warn` / `moon build` / `moon test` / `moon fmt --check` | ✅ 全绿（0068 清零） |
| Java Camera2 样板 / 真实 JNI / ajni 依赖 / 设备取帧 | ❌ 未做（排后续真实对接阶段；ajni 真机可用性未实证） |

## 开发顺序说明

`camera2` 不排在感知链的最前：最小验证场景（本地图片 + Mock 后端）不需要真实相机即可在桌面验证上层；相机是可替换帧源，不是 `pose` 的前置（见 `DECISIONS.md`「开发排序：相机不是姿态门面的前置」）。

## 文档索引

`DESIGN.md`（设计契约）· `API.md`（公开 API 与内部 ABI）· `DECISIONS.md`（设计决策记录：线程与所有权 / native 目标 / 可替换帧源 / 依赖门槛）
