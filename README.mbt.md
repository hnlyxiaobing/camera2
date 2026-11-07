# hnlyxiaobing/camera2

> **R1.5 实现轮（2026-11-07）**：全部导出接口已实现，`moon build` / `moon test` 全绿（21 测试，`0068` 清零）。
> **桌面 stub**：`stub/camera2_stub.c` 模拟 JavaVM/ImageReader/相机会话（假设备枚举、可配置帧序列、缓冲池耗尽、独立投递线程回调）；真实 JNI / ajni@0.3.6 / 设备取帧（红米电视 720p YUV）留待 R2（open-questions E4）。

Camera2 / JNI 平台绑定；`JNIEnv*` 线程局部、回调状态下沉 C 侧（ADR-0009）。`preferred_target = "native"`（ADR-0007）。

完整文档见同目录 `README.md`、`DESIGN.md`、`API.md`；总体架构与决策见 `../docs/architecture.md`、`../docs/adr/`。

**当前状态：实现轮完成（桌面 stub），等待 R2 真实 JNI 对接。**
