# hnlyxiaobing/camera2

**Android Camera2 的 JNI 封装 —— 权限、打开、预览 Surface、ImageReader 取 YUV 与关闭的完整相机生命周期。**

> 状态：**R1.5 实现轮完成（2026-11-07）**。全部导出接口已实现，`moon build` / `moon test` 全绿（21 测试，`0068` 清零）。本轮自带**桌面 C stub**（`stub/camera2_stub.c`）模拟 JavaVM/ImageReader/相机会话；**真实 JNI / Java 样板 / ajni / 设备取帧留待 R2**（open-questions E4）。
> `preferred_target` 本轮由 `wasm` 改为 `native`（唯一配置改动，理由见 ADR-0007）。

## 定位与为什么存在

路线图「拼图三」复核（2026-11-06）：`camera2` 命中全为 2D 游戏相机误报；`justjavac/camera@0.1.3`(MIT) 是**桌面 native 摄像头发现**，不能替代 Android 取帧。Camera2 是平台 Java API（或 NDK camera2ndk，API 24+），只能走 **FFI-JNI 封装**（`docs/capability-matrix.md` #13）。本库是感知闭环的**可替换帧源**，产出中性 `YuvFrame`。

**本轮关键设计（ADR-0009）**：JNI 线程亲和性决定 `JNIEnv*` 绝不进入 MoonBit 值类型；`JavaVM*` 只在 C 侧缓存；帧回调在相机投递线程触发，必须 marshal 到 owner 线程；`FuncRef` 只能无捕获，回调状态（global ref / attach 状态）下沉到 C shim。因此报告所说「胶水 C 文件极薄」应修正为「**薄在 ABI 转发，厚在生命周期与线程编排**」。

## 能力范围 / 非目标

- **做**：进程级 JNI 初始化、相机打开、ImageReader(YUV_420_888) 创建、重复预览请求、同步取帧、帧回调注册/注销、缓冲归还、关闭释放、相机能力枚举。
- **不做**：推理、渲染、YUV→RGB 转换、权限 UI、Camera2 厂商 quirk 自动修复、视频编码、Surface 渲染。
- 相机是**可替换帧源**：`pose` / `yuv` 不依赖本库，组合根可换成本地图片 / RTSP / 桌面摄像头（ADR-0004）。

## 公开接口（速览）

`Camera::{open, start_preview, grab_yuv, on_frame, clear_on_frame, close}`、`enumerate_cameras`。外部句柄与 shim 清单见 `API.md`。

## 依赖

- **本轮零依赖、零 shim 实现**；独立 `moon.mod`，`moon check` 独立通过。
- 后续轮：`Nanaloveyuki/ajni@0.3.6`（Apache-2.0，双向 checked JNI + Android host bridge）、Java 侧约 200 行 Camera2 样板、`native-stub` C 文件。**本轮未引入**——`ajni` 为 0.x 且作者自述 "Windows/macOS desktop ABI support is not claimed"，需按 ADR-0010 门槛评估。

## 平台与许可风险

- 平台：`preferred_target = "native"`；Android API 24+（NDK camera2ndk）或 Java Camera2 + ajni。
- 许可：本仓库 Apache-2.0；`ajni` Apache-2.0；Android SDK / NDK 二进制**不可再分发**（SDK License 3.4）。
- 风险：各厂商 Camera2 实现差异（部分 TV 只有 Camera1/UVC）；权限与后台限制；ImageReader 缓冲池耗尽；Android 9 / 32 位设备的 Camera1 回退（Q9 待验证）；`AIMAGE_FORMAT_YUV_420_888` 三平面必须按 `row_stride`/`pixel_stride` 读取，不能假设紧凑布局。
- `[待验证假设]` ajni 在 Windows 主机 + 红米电视（Android 9 / armeabi-v7a）的可用性（E4）。

## 测试与验收

- **测试策略**：设备取 720p YUV 帧；缓冲池耗尽 / 超时注入；回调线程归属断言（不得在回调内直接 JNI）；权限拒绝 / 设备不存在 / 尺寸不支持路径；`moon test --enable-coverage`。
- **验收标准**（实现轮）：在红米电视与外接 UVC 摄像头上取到 720p YUV 帧；`close` 幂等；每帧都被归还。
- **R1.5 实测（桌面 stub）**：`moon build` ✅ / `moon test` ✅ 21/21（全链路、状态机、池耗尽、回调 set/clear 成对、stride 描述、错误映射、解析校验）；设备取帧验收留待 R2。

## 当前状态 / 本轮产物

| 项 | 状态 |
|---|---|
| `camera2.mbt` + `internal.mbt`：5 个 `#external` 句柄、9 个 `extern "C"` shim、公开 API ×7 全部实现（状态机 / 错误映射 / YUV 校验） | ✅ |
| `stub/camera2_stub.c` 桌面 stub（假设备枚举、可配置帧序列、缓冲池、`#owned` 闭包成对持有/释放、投递线程回调） | ✅ |
| `camera2_wbtest.mbt` / `camera2_test.mbt` 测试 ×21 | ✅ |
| `pkg.generated.mbti` API 快照（与 API.md 一致；可见性纠错 2 处见报告） | ✅ |
| `moon build` / `moon test` / `moon fmt --check` / `moon check` | ✅ 全绿（0068 清零） |
| Java Camera2 样板 / 真实 JNI / ajni 依赖 / 设备取帧 | ❌ R2（open-questions E4） |

## 本轮顺序说明

`camera2` 从原报告 M1 的"感知闭环必备"位置**后移到 W1**：MVL-S 不需要真实相机，本地图片 + Mock 后端即可在桌面验证；相机是可替换帧源，不是 `pose` 的前置（ADR-0005 O2）。

## 文档索引

`DESIGN.md` · `API.md` · `../docs/architecture.md` §4/§5 · `../docs/adr/ADR-0004`、`ADR-0007`、`ADR-0009`
