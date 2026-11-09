# hnlyxiaobing/camera2

> **实现完成（2026-11-07，桌面 stub 阶段）**：全部导出接口已实现，`moon build` / `moon test` 全绿（21 测试，`0068` 清零）。
> **API 冻结前整改**：`FrameSource` 方法集冻结（`grab_yuv(Self)`，trait 层无超时参数）· `CameraError` 追认 `pub(all) suberror` · `CameraState` 收紧为 `Open` · 9 个 `mb_camera2_*` shim 包私有化（私有实现 ABI，非公共 API）· `close` 措辞统一「不会二次释放，重复调用返回明确错误」；门禁全绿。
> **桌面 stub**：`stub/camera2_stub.c` 模拟 JavaVM/ImageReader/相机会话（假设备枚举、可配置帧序列、缓冲池耗尽、19 个测试替身、独立投递线程回调）；真实 JNI / ajni@0.3.6 / 设备取帧（红米电视 720p YUV）留待后续真实对接阶段（ajni 真机可用性未实证）。

Camera2 / JNI 平台绑定；`JNIEnv*` 线程局部、回调状态下沉 C 侧（线程与所有权设计见 `docs/DECISIONS.md`）。`preferred_target = "native"`（理由见 `docs/DECISIONS.md`）。

完整文档见项目根目录与 `docs/` 目录：`README.md`、`docs/DESIGN.md`、`docs/API.md`、`docs/DECISIONS.md`（设计契约与设计决策均在本仓库内）。

**当前状态：实现完成（桌面 stub），等待真实 JNI 对接。**
