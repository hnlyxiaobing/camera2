# camera2 业界对标与迭代开发文档

> 建立：2026-11-16 ｜ 状态：待开发 ｜ 适用仓库：本仓库（独立自包含）
> 配套文档：[2026-11-16-test-system-design.md](2026-11-16-test-system-design.md)（验收测试 ID `T-W*-*` 出自该文档）
> 本文所有「现状」结论均为 2026-11-16 对本仓库源码的实测核对（五门禁本机实跑全绿：
> `moon check --deny-warn` / `moon build` / `moon test` 31/31 / `moon fmt --check` / `moon info` 快照无 diff），非转述历史文档。
> 证据三级标注：[已知常识] / [需联网核实] / [仅据本项目文档]；对标结论另标检索时点与渠道。

## 0. 现状基线（实测核对，开发前必读）

### 0.1 能力点清单（P1，以 README + `pkg.generated.mbti` 为基准）

| # | 能力点 | 公开 API |
|---|---|---|
| F1 | 相机枚举与能力快照 | `enumerate_cameras(JavaVMPtr) -> Array[CameraInfo]` |
| F2 | 打开相机（配置预检、失败逆序释放、owner 线程绑定、重复 open 拒绝） | `Camera::open` |
| F3 | 幂等预览 | `Camera::start_preview` |
| F4 | 同步取帧（两段式 acquire/无条件 release、超时与池耗尽分判、stride 保真） | `Camera::grab_yuv` |
| F5 | 帧回调注册/注销（`#owned` 闭包成对、替换释放旧闭包） | `Camera::on_frame` / `Camera::clear_on_frame` |
| F6 | E1/R4 marshal 层（有界队列 8 keep-latest、owner 线程派发、重入拒绝、关闭竞态延迟释放） | `Camera::pump_marshal` |
| F7 | 幂等关闭（`AlreadyClosed`、C 侧唯一释放点、先注销回调再释放） | `Camera::close` |
| F8 | 可替换帧源契约（冻结 trait，包外可实现） | `pub(open) trait FrameSource` |
| F9 | 显式错误模型（13 变体）+ 畸形输入 fail-closed 解析 | `CameraError`（内部 `parse_yuv_frame`/`parse_camera_infos`） |
| F10 | 桌面 stub 全链路可测（池耗尽/超时/线程错配/threaded 投递注入） | `stub/camera2_stub.c` 测试替身控制符号 |
| F11 | 中性帧值类型（stride 描述、时间戳、无 format 字段） | `YuvFrame`/`YuvPlane`/`FrameSize`/`CameraConfig`/`CameraInfo`/`Facing`/`CameraState` |
| F12 | 私有 C ABI 契约（真实对接零改动预留） | `stub/camera2_abi.h`（15 shim：9 核心 + 2 marshal + 4 internal） |

**非目标清单（现状声明）**：不执行真实 JNI（桌面 stub 阶段，E4 解禁后对接）；不引入 `ajni@0.3.6` / `justjavac/camera`；不做 Camera1/UVC 回退（Q9 已裁决：不需要，见 W7 裁决记录）；不感知 `yuv`/`pose` 类型；不做推理/渲染/YUV→RGB 转换/权限 UI；仅 `native` 目标（`extern "C"` 在 wasm 后端不受支持）；`pump_marshal` 不阻塞等待新帧（纯排水）。

### 0.2 B# 基线事实表（P4 强制门禁产出）

| # | 事实（已实现/缺口/漂移） | 证据位置 |
|---|---|---|
| B1 | 公开 API 面与 README §3 索引一致：9 pub fn（含 `CameraError::to_repr`）、6 struct、2 enum、1 suberror（13 变体）、5 `#external` 类型、1 别名、1 open trait | `pkg.generated.mbti` L9–111 vs `README.md` §3 |
| B2 | 15 个包私有 shim 实存（核心 9 + marshal 2 + internal 4），与 abi.h 一致；**漂移**：`camera2.mbt` L159 注释仍写「9 个 `mb_camera2_*`」；历史申报口径「9 个包私有 shim」同样滞后（README 的 15 正确） | `camera2.mbt` L167–251（11 声明）、`internal.mbt` L15–38（4 声明）、`stub/camera2_abi.h` L72–95 |
| B3 | 枚举两段容量 8192→65536（-12 重试一次）；解析 fail-closed：count≤64、id_len≤255、facing∈{0,1,2}、size_count≤64、维度>0，越界即 `UnsupportedFormat` | `camera2.mbt` `enumerate_cameras` L452–474、`internal.mbt` `parse_camera_infos` L240–310 |
| B4 | open 预检（size>0、pool≥1）先于任何 C 调用；reader 失败逆序释放 camera 句柄，测试断言 `live_cameras==0` | `camera2.mbt` `Camera::open` L267–324；wbtest "failed create_reader releases camera handle" |
| B5 | start_preview 幂等：C 侧 `previewing` 标志，不重复建会话/线程 | `stub/camera2_stub.c` L690–699；wbtest "full chain"（双击 start_preview） |
| B6 | grab_yuv 两段式 acquire + `errdefer` 无条件 release；-11→`BufferAcquireFailed(timeout_ms)`、-7→`BufferPoolExhausted(pool)` 可判；`first==0` 分支为死路径（needed 恒 >64，防御性保留） | `internal.mbt` `Camera::acquire_frame_value` L316–349；wbtest 超时/池耗尽/强制失败 3 例 |
| B7 | 帧解析 fail-closed：written≥64、维度∈(0,16384]、off≥64、len>0、off+len≤written、rs>0、ps≥1、stride 覆盖全样本（`need = rs*(ph-1) + (pw-1)*ps + 1`），违例抛 `UnsupportedFormat` | `internal.mbt` `parse_yuv_frame` L187–236；wbtest "parse_yuv_frame rejects malformed"（5 类畸形） |
| B8 | `#owned` 闭包成对：set 替换 decref 旧闭包、失败路径 decref（P1 回归）、clear 幂等、close 先注销再释放；`live_closures` 全程观测 | `stub/camera2_stub.c` L785–846/L862–870；wbtest "callback set/clear pairing"、"on_frame failure path releases owned closure" |
| B9 | marshal 队列 `MAX_MARSHAL=8`，满丢最旧（keep-latest）+ `mq_dropped` 计数；seq 锁内单调，FIFO=线性化顺序 | `stub/camera2_stub.c` L161/L359–381；wbtest "full queue drops oldest"（13→8 在队+5 丢弃） |
| B10 | pump：`max_events<1`→`OpenFailed(-13)`；派发期重入→-15→`MarshalReentrant`；无回调丢弃排水；回调内 close 经 `close_pending` 延迟释放、pump 收尾 teardown | `camera2.mbt` L405–421、`stub/camera2_stub.c` L995–1065；wbtest marshal 9 例 |
| B11 | close 幂等：`closed=1` 逻辑判死（含延迟释放窗口）→ `ensure_session` 拒绝为 `AlreadyClosed`，不二次触碰 `mb_camera2_close`；跨线程 close 被 `ensure_owner` 拒绝 | `camera2.mbt` L442–447、`internal.mbt` L163–180、`stub/camera2_stub.c` L857–864/L916–924 |
| B12 | `CameraState` 单分支 `Open`；存活裁决由 C 侧会话注册表完成，不依赖 state 字段分支 | `camera2.mbt` L46–48/L104–110、`stub/camera2_stub.c` `mb_camera2_session_alive` |
| B13 | `FrameSource` 冻结（grab_yuv 无超时参数、close 不二次释放），包外实现有黑盒测试（FileSource 替身） | `camera2.mbt` L150–153；`camera2_test.mbt` L73–138 |
| B14 | 线程契约：只缓存 `JavaVM*`（`g_vm`），状态码 TLS；`ensure_owner` 比对线程 id；threaded 投递线程只入队、绝不执行 MoonBit 闭包（测试断言回调线程==owner） | `stub/camera2_stub.c` L207–224/L446–466；wbtest "callback is marshalled to the owner thread" |
| B15 | 测试 31 条（白盒 28 + 黑盒 3），`moon test` 实测 31/31，**零 `#skip`**；历史申报口径「30 个测试」滞后（README 31/31 正确） | 2026-11-16 本机 `moon test` 输出；`camera2_wbtest.mbt`/`camera2_test.mbt` 逐条清点 |
| B16 | 五门禁本机（Windows/MSVC x86_64）全绿；CI ubuntu-latest 路径在 ci.yml 中自标「[仍需实测]」，云上实跑证据缺失 | 2026-11-16 本机实跑；`.github/workflows/ci.yml` L57–58 |
| B17 | **漂移（引用实存性）**：`docs/DECISIONS.md` 被 4 个 .mbt 文件引用 8 处、`docs/DESIGN.md §15` 被 abi.h 引用 1 处、`docs/API.md` 被 ci.yml Gate 5 报错文案引用 1 处——`docs/` 为空目录，三者均不存在 | Grep 全仓 + 目录实测（2026-11-16） |
| B18 | **漂移**：ci.yml 注释引用 `pkg.generated.mbti.r1`（R1 基线存档）实不存在；`cmd/main/pkg.generated.mbti` 实存且纳入 Gate 5 diff 范围 | `.github/workflows/ci.yml` L16–17/L123；Test-Path 实测 |
| B19 | **漂移（注释滞后于代码）**：stub.c 3 处注释（L11、L874、L989）与 wbtest L862 声称「派发前 moonbit_incref」；实际代码为 **borrow 调用约定**（L1038–1044 `cb(closure)` 不消费引用，全文件无任何 `moonbit_incref` 调用），与 R5 修正后的泵内注释一致 | Grep `moonbit_incref` 仅命中注释；`stub/camera2_stub.c` L1038–1051 |
| B20 | **缺口（惰性字段）**：`CameraConfig.rotation_degrees`/`mirror_x` 全仓只有声明与 0/false 赋值，无任何读取点；帧不做旋转/镜像，也无逐帧方向元数据；rotation 取值无校验 | Grep 全仓（仅 struct 声明 + test_config + cmd/main 赋值） |
| B21 | `YuvFrame` 无 `format` 字段，README §6 已声明组合根须显式选 `Yuv420888`——文档与代码一致 | `pkg.generated.mbti` L91–96；`README.md` §6 |
| B22 | **缺口（fail-open 冒烟）**：`cmd/main` 捕获错误后仅打印 `camera2 smoke FAILED`，进程退出码仍为 0，CI/脚本无法按退出码判失败 | `cmd/main/main.mbt` L32–34 |
| B23 | 零第三方依赖（moon.mod 无 import；moon.pkg 仅 `core/encoding/utf8` + native-stub）；`preferred_target=native`；Apache-2.0 | `moon.mod`、`moon.pkg` |
| B24 | **缺口（可观测性）**：marshal 丢弃/入队计数仅测试替身符号可观测（`mb_camera2_stub_marshal_*`），公开 API 无入口；队列容量 8 为编译期常量不可配 | `stub/camera2_stub.c` L161/L1284–1312；mbti 无对应 pub fn |
| B25 | **缺口（异步设备事件）**：Camera2 `onDisconnected`/`onError` 语义未建模；设备错误只在下次同步调用时浮现，无事件查询通道 | `stub/camera2_stub.c` 全文无设备事件注入点；mbti 无对应 pub fn |
| B26 | 测试卫生约束：`stub_reset` 不 join threaded 会话（仅兜底释放非线程化泄漏），测试必须先 close——stub 限制而非产品缺陷 | `stub/camera2_stub.c` L1108–1142 |
| B27 | **缺口（发布元数据）**：`moon.mod` `description=""`、`keywords=[]` | `moon.mod` L22/L26 |

**对历史口径的修正**（显式承认）：
1. 历史申报口径「9 个包私有 shim」→ 实测 **15**（9 核心 + 2 marshal + 4 internal）；`camera2.mbt` L159 注释同滞后（B2）。
2. 历史申报口径「30 个测试全绿」→ 实测 **31/31**（B15）。
3. 注释宣称的「派发前 incref」所有权协议 → 实际为 **borrow 约定**（R5 已修正代码，注释未同步）（B19）。
4. 注释/CI 引用的 `docs/DECISIONS.md`、`docs/DESIGN.md`、`docs/API.md`、`pkg.generated.mbti.r1` 均不存在（B17/B18）——与历史教训「ASSETS.md 引用漂移」同类。

## 1. 硬约束（每个工作包都必须满足）

1. **API 冻结**：`pkg.generated.mbti` 为冻结基线，只允许纯加法（新 pub fn / 新 struct / 新 enum）。禁止给既有 `pub(all)` struct（`Camera`/`CameraConfig`/`CameraInfo`/`YuvFrame`/`YuvPlane`/`FrameSize`）加字段；禁止新增 `CameraError` 变体（13 变体冻结；破坏性需求须 ADR + 用户裁决 + CHANGELOG + 主版本四件例外）。校验失败用**值字段**（Bool/状态报告）表达；解析失败复用 `UnsupportedFormat`；会话/线程守卫复用 `AlreadyClosed`/`JniThreadNotAttached`。语义变更走**新函数新类型防火墙**，旧 API 语义永不改变。
2. **加法三件套**：快照随源码同提交且 diff 纯加法 + `docs/CHANGELOG.md` 登记 + CI 快照门禁（Gate 5）绿。
3. **依赖不动**：当前零第三方依赖（B23）；不 fork 不升级；`ajni@0.3.6` 仅在 W7-B 备选路径启用时以钉死版本引入（五门槛审查 + 用户批准）。C ABI 形态约束：shim 为一次性同步调用 + 两段式容量探测（正数返回=所需容量不消费），扩展设计不得改为流式/回调式 C 接口。
4. **许可红线**：第三方 APK/.so/模型/真实相机样本不入库；真机差分只允许「仓库外本地路径 + SHA-256 登记 + 显式 SKIPPED」；入库测试资产用确定性生成器自产（现有 stub 像素图案即自产，B6/B7）。Android SDK License 3.4 不可再分发。
5. **五门禁**：`moon check --deny-warn` / `moon build` / `moon test` / `moon fmt --check` / `moon info` + 快照 diff 全绿才可合入；`#skip`/SKIPPED/退出码 78 不得写成通过。
6. **边界不变量**：非目标清单（§0.1）持续有效；新增裁决见 §2.3。被钩/投递线程从不执行 MoonBit 闭包是设计不变量；`JNIEnv*` 线程局部不缓存；`FuncRef` 只接受无捕获闭包。
7. **文档自包含**：本仓库 docs/ 不引用、链接或假定可访问工作区其他目录；跨库事务只声明归属。

## 2. 业界对标（P2）与边界裁决（P3）

### 2.1 对标候选与功能覆盖对比表

检索时点：2026-11-16；渠道：Web 搜索 + GitHub/PyPI/官方文档页直读。mooncakes.io 为 SPA 站点，registry 搜索接口未能直接穷举——「MoonBit 生态未见同类」结论限定为：**MoonBit 语言 + Android Camera2 取帧绑定 + 本次检索渠道与时点**，不冒充已穷举 registry。

| 能力（行=F#） | 本模块 camera2 | NDK camera2ndk（C，平台 API） | CameraX ImageAnalysis（JVM/Kotlin） | react-native-vision-camera（JS/TS 桥） | nokhwa（Rust，桌面） | camera4kivy（Python） |
|---|---|---|---|---|---|---|
| F1 枚举+能力快照 | ✅ id/facing/sizes/yuv 支持（深度有限，B20/B25 相关） | ✅ ACameraManager_getCameraIdList + characteristics 全量 | ✅ CameraSelector/设备能力查询 | ✅ useCameraDevices | ✅ Query/Query-Device（桌面设备） | ✅ camera_id 选择（能力快照浅） |
| F2/F3 打开+预览 | ✅ 同步 open/幂等 preview | ✅ ACameraManager_openCamera + session | ✅ bindToLifecycle 自动管理 | ✅ Camera isActive | ✅ Camera::new + open_stream | ✅ connect_camera |
| F4 同步取帧（stride 保真） | ✅ 纯值 YuvFrame，acquire→release 自动 | ✅ AImageReader_acquireNextImage（借用，须手动 delete） | ⚠ ImageProxy 借用式，须 close() | ⚠ Frame 为 JSI HostObject 借用 | ✅ frame()  owned Buffer | ⚠ analyze_pixels 回调式 |
| F5/F6 回调+线程 marshal | ✅ owner 线程 pump 派发、重入拒绝、keep-latest 8、丢弃计数（内部） | ⚠ AImageReader listener 在调用方线程，无 marshal | ✅ setAnalyzer(executor) + STRATEGY_KEEP_ONLY_LATEST | ✅ Frame Processor worklet 独立 JS runtime | ✅ output-threaded 回调 | ✅ 逐帧 analyze（主线程隔离有限） |
| F7 幂等关闭/资源安全 | ✅ AlreadyClosed + 唯一释放点 + 延迟释放防 UAF | ⚠ 手动 close，重复释放未定义 | ✅ lifecycle 自动 unbind | ✅ 组件卸载自动 | ✅ Drop 语义 | ✅ disconnect_camera |
| F8 可替换帧源契约 | ✅ 冻结 pub(open) trait | ❌ | ❌（用例绑定相机） | ❌ | ⚠ backends 可换但无统一 trait | ⚠ provider 可换 |
| F9 显式错误模型+畸形 fail-closed | ✅ 13 变体 + 解析校验 | ⚠ camera_status 枚举，无帧校验 | ✅ CameraX 异常体系 | ✅ 错误事件 | ✅ Result | ⚠ 有限 |
| F10 桌面 stub 全链路可测 | ✅ 故障注入（池耗尽/超时/线程错配/threaded） | ❌ 需真机/模拟器 | ❌ 需设备（Robolectric 有限） | ❌ 需设备 | ✅ 桌面即真环境 | ⚠ 桌面 provider 非 Android 语义 |
| F11 逐帧方向元数据 | ❌ 惰性 config 字段（B20） | ✅ sensor orientation characteristics | ✅ imageInfo.rotationDegrees | ✅ frame orientation | ⚠ 有限 | ✅ 旋转处理 |
| F12 相机控制（对焦/曝光/变焦） | ❌（裁决为非目标，§2.3） | ✅ CaptureRequest 全量 | ✅ CameraControl | ✅ 部分 | ⚠ 平台相关 | ⚠ 手势变焦/点按对焦 |

证据等级：camera2ndk API 形态 [已知常识，2026-11-16 检索佐证：Android 官方迁移文档/NDK 示例]；CameraX ImageAnalysis 背压/executor/rotationDegrees [已知常识，官方文档 2026-11-10 更新页直读]；vision-camera Frame Processors/JSI/YUV [需联网核实：社区文档与 GitHub 镜像页，2026-11-16]；nokhwa 后端矩阵（V4L2/MSMF/AVFoundation/OpenCV/WASM，**无 Android 后端**）[已知常识，GitHub README 直读]；camera4kivy CameraX provider/analyze_pixels [需联网核实：PyPI 项目页直读]；`ajni@0.3.6`（Apache-2.0，通用 JNI 双向运行时 + Android host，API 24+，回调 owner 线程语义、外部线程拒绝）[已知常识，GitHub README 直读]；`justjavac/camera@0.1.3`（MIT，桌面摄像头，不能替代 Android 取帧）[仅据本项目文档，本次检索未直接命中该包页，需联网核实]。

**最接近对标**：
1. **NDK camera2ndk**（重叠度最高：C ABI、YUV_420_888、stride、ImageReader 池语义）——本模块 shim 层即其语义的桌面替身；差异在本模块把帧升格为**纯值**并自动归还缓冲。
2. **CameraX ImageAnalysis**（产品形态最接近：背压 keep-latest、executor 线程、方向元数据）——差异在本模块闭包**只在 owner 线程**执行（pull 式 pump，确定性可测），CameraX 分析器在任意 executor 线程。
3. **ajni**（同语言最近邻：MoonBit JNI 桥，回调所有权/线程拒绝语义同源）——非相机库，是 W7-B 备选宿主桥而非竞品（首选路径为 camera2ndk，见 W7 裁决记录）。

**差异化判断**：本模块 = 「纯值帧 + owner 线程 marshal + 桌面 stub 全链路故障注入 + 冻结可替换帧源契约 + 零依赖」的组合；调研时点与渠道内未见 MoonBit 语言下同等组合的 Android Camera2 绑定库（限定见上）。

**缺失能力清单**：
- 已声明非目标：真实 JNI/真机（E4）、Camera1/UVC 回退（Q9 已裁决：不需要）、YUV→RGB、权限 UI、wasm 目标。
- 真缺口：逐帧方向元数据与 config 校验（B20）、marshal 可观测性（B24）、异步设备事件（B25）、枚举能力快照深度（B3 仅 4 字段）、冒烟退出码 fail-open（B22）、发布元数据（B27）、Linux CI 实证（B16）、文档/注释漂移（B2/B17/B18/B19）。

### 2.2 本质职责与边界判据（P3）

**本质职责（一句话）**：把 Android 相机帧变成 owner 线程可安全消费的 MoonBit 纯值——不可约简为三件事：①帧字节的忠实搬运（stride/像素/时间戳保真）；②线程与所有权安全（JNIEnv 亲和、闭包成对、marshal 派发）；③生命周期资源安全（句柄配对、fail-closed、不二次释放）。

**边界判据**：一个能力是否直接服务于「把帧忠实、安全地送到 owner 线程消费者手中」？是→界内；否→界外（归属声明）。

### 2.3 灰区裁决清单

| 灰区 | 裁决 | 落地 |
|---|---|---|
| `rotation_degrees`/`mirror_x` 惰性字段（B20） | **界内**（方向元数据属帧忠实性）：保留冻结字段，新增值化校验与方向查询函数；**像素旋转本身界外**（属 yuv/转换层），`applied` 恒 false 并成恒等式 | W3 |
| marshal 丢弃/容量可观测性（B24） | **界内**（消费者对队列行为的知情权属线程/资源安全）：加法 stats API；容量 8 维持编译期常量，可配置化声明为非目标（未来如需走新 open 变体，另裁决） | W4 |
| 设备断连/异步错误（B25） | **界内**（fail-closed 生命周期）：加法**轮询**事件查询（新 enum 值类型），不新增回调通道、不新增错误变体 | W6 |
| 枚举能力快照深度 | **界内**（枚举是声明能力）：加法 detailed 枚举新类型，不改 `CameraInfo` | W5 |
| 相机控制（对焦/曝光/变焦/火炬）、拍照/录像 | **界外**：本库是帧源不是相机控制器；归属应用层/CameraX 类库。**新增非目标声明** | W1（README 同步） |
| 与 ajni 的关系 | 维持零依赖 + 同符号 ABI 预留；真实对接首选纯 C camera2ndk（零新依赖），ajni 降为条件备选（五门槛 + 钉死 + 批准） | W7（已裁决 2026-11-16） |
| `YuvFrame` 无 format 字段 vs `yuv::YuvFrame` | 维持中性值类型 + 组合根显式选 `Yuv420888`（B21）；不加字段（冻结），如需格式标记走新类型防火墙 | 无代码变更，W1 文档固化 |
| 冒烟退出码 fail-open（B22） | **界内**（验证契约属 fail-closed）：失败非零退出；输出行格式不变 | W2 |

## 3. 工作包总览

| 包 | 名称 | 优先级 | 规模 | API 影响 | 对应缺口(B#) |
|---|---|---|---|---|---|
| W1 | 漂移清理与决策文档自包含 | P0 | S | 无 | B2/B17/B18/B19 |
| W2 | 冒烟退出码 fail-closed + 发布元数据 | P0 | S | 无（cmd/main 非冻结 API） | B22/B27 |
| W3 | 配置值化校验 + 帧方向元数据（防火墙） | P1 | M | 加法：2 struct + 2 fn | B20 |
| W4 | marshal 队列可观测性 | P1 | M | 加法：1 struct + 1 fn + 1 私有 shim | B24 |
| W5 | 详细枚举能力快照 | P2 | M | 加法：1 struct + 1 fn + 1 私有 shim | B3（深度） |
| W6 | 设备事件轮询通道 | P2 | M | 加法：1 enum + 1 fn + 1 私有 shim + stub 注入点 | B25 |
| W7 | 真实对接（E4；已裁决：camera2ndk 首选、ajni 备选） | P3 | XL | 无（同符号 ABI 替换 stub 实现） | B16/B23（E4） |
| W8 | Linux 平台实证（CI + pthread 路径） | P2 | S | 无 | B16 |

## 4. 工作包详细设计

### W1 漂移清理与决策文档自包含（P0/S）

**目标**：消灭 B2/B17/B18/B19 四类漂移，使注释/CI 引用的文件全部实存，决策记录落回本仓库。
**非目标**：不改任何 API/行为；不重写历史文档。
**新增 API**：无。
**实现要点**：
- 新建 `docs/DECISIONS.md`：自包含记录「JNI 线程亲和性与回调所有权」「回调投递线程 → owner 线程 marshal」「可替换帧源设计」「CameraState 收紧」「borrow 调用约定（R5）」五项决策（内容从现有注释与 abi.h 契约整理，不引用仓库外文件）。
- 新建 `docs/API.md`：加法性变更登记簿（初始条目 = 冻结基线 13 错误变体 + 现有 pub 面），满足 ci.yml Gate 5 报错文案的指向。
- `stub/camera2_abi.h` L8：`docs/DESIGN.md §15` → 改指 `docs/DECISIONS.md`（真实对接设计节）。
- `camera2.mbt` L159：「9 个」→「15 个（9 核心 + 2 marshal + 4 internal）」。
- `stub/camera2_stub.c` L11/L874/L989 与 `camera2_wbtest.mbt` L862：incref 措辞 → borrow 约定（与 L1038–1044 泵内注释一致）。
- `.github/workflows/ci.yml` L16–17：删除对不存在的 `pkg.generated.mbti.r1` 的引用（或改为「历史基线存档如存在则不在 diff 范围」的条件措辞）。
- `README.md`：非目标节追加「不做相机参数控制（对焦/曝光/变焦）、不做拍照/录像」（§2.3 裁决）；§6 风险节引用 W8 待实证项。
**验收**：T-W1-1（引用实存性扫描：全仓 grep `docs/` 引用逐一 Test-Path 通过）；T-W1-2（五门禁全绿、mbti 零 diff）；T-W1-3（incref 措辞扫描零命中）。

### W2 冒烟退出码 fail-closed + 发布元数据（P0/S）

**目标**：`cmd/main` 失败路径非零退出（B22）；补齐 moon.mod 发布元数据（B27）。
**非目标**：不改输出行格式（`camera2 smoke: …` / `camera2 smoke OK` / `camera2 smoke FAILED` 契约冻结）；不把冒烟示例升格为 CLI 产品。
**新增 API**：无（cmd/main 为示例包，非冻结公开面）。
**实现要点**：catch 分支打印 FAILED 后以非零码退出（MoonBit native 侧经既有 C 运行时退出约定或新增包私有 `mb_camera2_stub_exit` 测试替身符号——优先用 core 可用能力，避免新 shim）；`moon.mod` 填 `description`（一句话定位）与 `keywords`（camera2/android/jni/yuv/frame-source）。
**验收**：T-W2-1（正常路径退出码 0 + 三行输出契约不变）；T-W2-2（注入 open 失败 → 退出码非 0 + FAILED 行）；T-W2-3（五门禁全绿）。

### W3 配置值化校验 + 帧方向元数据（P1/M）

**目标**：B20 惰性字段值化——提供不改旧语义的校验报告与方向查询。
**非目标**：不做像素旋转/镜像（界外，§2.3）；不改 `Camera::open` 对 rotation 的既有接受行为（防火墙）；不给 `CameraConfig`/`YuvFrame` 加字段。
**新增 API（mbti 草案，纯加法）**：

```text
pub(all) struct ConfigReport {
  size_ok : Bool
  pool_ok : Bool
  rotation_ok : Bool      // rotation_degrees ∈ {0,90,180,270}
  mirror_ok : Bool        // 恒 true（Bool 字段无非法值，保留对称性）
}
pub fn validate_camera_config(CameraConfig) -> ConfigReport

pub(all) struct FrameOrientation {
  rotation_degrees : Int32
  mirror_x : Bool
  applied : Bool          // 恒 false：本库不做像素旋转（恒等式 I6）
}
pub fn Camera::frame_orientation(Self) -> FrameOrientation raise CameraError
```

**实现要点**：`validate_camera_config` 纯函数、无错误抛出（校验失败值化）；`frame_orientation` 经 `ensure_session`/`ensure_owner` 守卫（复用 `AlreadyClosed`/`JniThreadNotAttached`），从 `self.config` 读取并置 `applied:false`。落点 `camera2.mbt` 新块。
**验收**：T-W3-1（合法/非法 rotation 各值报告正确）；T-W3-2（方向查询返回 config 原值且 applied==false）；T-W3-3（close 后查询抛 AlreadyClosed、错线程抛 JniThreadNotAttached）；T-W3-4（快照 diff 纯加法 + 旧 API 行为零变化回归）。

### W4 marshal 队列可观测性（P1/M）

**目标**：B24——公开 API 暴露队列记账，使消费者可判定丢帧。
**非目标**：不改队列容量/背压策略；不新增错误变体；不把测试替身符号升格为公开 API。
**新增 API（mbti 草案，纯加法）**：

```text
pub(all) struct MarshalStats {
  pending : Int32         // 在队 + 暂存
  dropped : Int32         // 满队列累计丢弃
  pushed : Int32          // 累计入队（含丢弃）
}
pub fn Camera::marshal_stats(Self) -> MarshalStats raise CameraError
```

**实现要点**：新私有 shim `mb_camera2_marshal_stats(reader, dst FixedArray[Byte]) -> Int32`（小端 3×i32，`#borrow(dst)`；沿用两段式不需要——定长 12 字节一次取走）；abi.h 追加声明（私有 ABI 加法，真实 native-stub 未来实现同符号）；stub 从 `mq_len/staged_valid/mq_dropped/mq_seq` 读取（锁内）；MoonBit 侧守卫后解析，解析失败复用 `UnsupportedFormat`。恒等式 I7：`pushed == dispatched + dropped + pending`（dispatched 由调用方累计 pump 返回值）。
**验收**：T-W4-1（13 投递 → pending 8/dropped 5/pushed 13）；T-W4-2（pump 后记账恒等式成立）；T-W4-3（close 后抛 AlreadyClosed）；T-W4-4（快照纯加法 + 五门禁）。

### W5 详细枚举能力快照（P2/M）

**目标**：枚举深度对齐 camera2ndk characteristics 的最小实用子集（B3 深度缺口）。
**非目标**：不改 `CameraInfo`/`enumerate_cameras`；不建模厂商扩展全量。
**新增 API（mbti 草案，纯加法）**：

```text
pub(all) struct CameraInfoDetailed {
  id : String
  facing : Facing
  supported_sizes : Array[FrameSize]
  supports_yuv420888 : Bool
  sensor_orientation_degrees : Int32
  supports_flash : Bool
}
pub fn enumerate_cameras_detailed(JavaVMPtr) -> Array[CameraInfoDetailed] raise CameraError
```

**实现要点**：新私有 shim `mb_camera2_enumerate_detailed_raw`（打包格式 = 现有枚举格式 + 每台追加 2×i32，小端；容量策略沿用 8192→65536 两段）；stub 假设备表追加两列（确定性常量）；解析 fail-closed 复用 `UnsupportedFormat`，边界校验与 `parse_camera_infos` 同构。
**验收**：T-W5-1（4 台设备详细快照逐字段断言）；T-W5-2（畸形缓冲 5 类拒绝）；T-W5-3（旧 `enumerate_cameras` 输出零变化）；T-W5-4（快照纯加法 + 五门禁）。

### W6 设备事件轮询通道（P2/M）

**目标**：B25——以轮询值类型建模 Camera2 `onDisconnected`/`onError`，不引入新回调线程复杂度。
**非目标**：不新增错误变体；不做异步推送；不改变既有同步调用错误映射。
**新增 API（mbti 草案，纯加法）**：

```text
pub(all) enum DeviceEvent {
  NoEvent
  Disconnected(String)
  DeviceError(Int32, String)
}
pub fn Camera::device_event(Self) -> DeviceEvent raise CameraError
```

**实现要点**：新私有 shim `mb_camera2_device_event(reader, dst, capacity) -> Int32`（打包：i32 kind + i32 code + i32 msg_len + msg 字节；消费式读取，读后清空）；stub  reader 增加事件槽 + 测试注入符号 `mb_camera2_stub_set_device_event`；守卫复用 `ensure_session`/`ensure_owner`；`DeviceEvent` 是**值类型 enum**（非 suberror），不触碰错误变体冻结。
**验收**：T-W6-1（注入断连/错误 → 轮询得到对应变体且二次轮询 NoEvent）；T-W6-2（无事件恒 NoEvent）；T-W6-3（close 后抛 AlreadyClosed）；T-W6-4（快照纯加法 + 五门禁）。

### W7 真实对接（E4，P3/XL，**已裁决 2026-11-16**）

**目标**：以真实 native-stub 实现同一批 `mb_camera2_*` 符号，MoonBit 侧 extern 零改动，目标设备 720p YUV 真机取帧。
**非目标**：不改公开 API；不做 Camera1/UVC 回退（Q9 随本包一并裁决，见下）。

**第一性原理裁决记录（2026-11-16，用户授权）**：
- **必要**：本库的价值终点是「真实 Android 相机帧 → owner 线程纯值」。stub 合成图案不含人体语义，只能验证管线正确性、不能验证感知有效性（下游姿态推理对合成帧无有意义输出）；绑定的正确性最终由真实宿主定义，stub 是手段不是目的。真实对接是闭合真实帧价值的唯一路径，不可永久搁置。
- **不紧急**：W7 不是当前 stub 阶段任何交付物的前置；其前置链（E3：MoonBit→NDK `.so` 可加载性；E4：宿主桥/设备可用性）全部未实证，且降级路径（桌面 stub）恒绿。裁决维持 P3/M4，前置证据齐备前不解禁 E4。
- **路径重组（手段服务于本质）**：JNI/Java 是手段不是目的。**首选 W7-A = 纯 C camera2ndk（API 24+）实现同批符号**：零新依赖、无 Java 样板、无第三方桥可用性风险；shim 语义本就是其桌面替身（§2.1 重叠度最高对标）；AImageReader 回调线程同样非 owner，marshal 设计不变量原样保留（且 E1 获得真实非 owner 线程证据）。`JavaVMPtr` 参数保留兼容（init 缓存、取帧不使用），公开 API 零可观察变化；`JniThreadNotAttached` 在首选路径不触发（变体仍冻结，stub 继续覆盖）。**备选 W7-B = ajni@0.3.6 + Java Camera2**：仅当 W7-A 遇设备级障碍（目标设备 camera2ndk 不可用/关键 characteristics 缺失）时启用，须五门槛审查 + 版本钉死 + 用户批准 + CHANGELOG。
- **Q9 合并裁决：不需要 Camera1/UVC 回退代码**。①Camera1 自 API 21 起已弃用（官方相机库选择文档 2026-10-21 更新页仍推荐 CameraX/Camera2）[已知常识，2026-11-16 联网核实]；LEGACY 硬件级别仍由 Camera2 本身服务（能力子集），不构成回退 Camera1 的理由；第二套 ABI 面（NV21 预览回调、无 ImageReader、不同线程模型）会使冻结面与测试矩阵翻倍。**永久非目标**；如未来需要 pre-API-21 帧源，属组合根级 `FrameSource` open trait 的另一实现，不是本库变更。②UVC 已在 Camera2 语义之内：AOSP External Camera Provider 把 UVC 摄像头经标准 Camera2 API 暴露，硬件级别 EXTERNAL（API 28 起 Java 客户端 API 含 EXTERNAL）[已知常识，AOSP 官方文档 2026-11-16 联网核实]；本库 stub 已预留 `Facing::External`。设备侧前提（usb.host/内核 UVC/external provider/格式白名单）是**探测项不是代码项**，并入 M7-1 探测清单；若探测失败（目标设备无相机且未启用 external provider），属设备选型/帧源问题，替代为手机帧源或组合根级另一 FrameSource 实现，本库保持冻结。

**降级方案**：维持桌面 stub（现状全部门禁与测试不受影响）。
**里程碑（T-W7-1…3 重映射）**：
- M7-1（探测 + 加载）：设备探测清单——枚举相机/硬件级别（LEGACY/LIMITED/FULL/EXTERNAL）/EXTERNAL 存在性/YUV_420_888@720p 可用性/API level/camera2ndk 可用性；E3 最小实验——MoonBit + C hello stub 经 NDK 交叉编译产出可加载 `.so` 并在设备加载一次。止损：任一项失败即记 fail-closed 缺口，W7 维持 deferred，不动依赖。
- M7-2（编译差分）：W7-A camera2ndk native-stub 双 ABI（arm64-v8a/x86_64）编译门禁 + 同符号 stub/real 契约差分（桌面可测部分）。止损：NDK 编译链不可复现即停。
- M7-3（真机差分）：真机 720p YUV 取帧差分（R runner：仓库外样本 + SHA-256 登记 + 显式 SKIPPED 纪律）。止损：真机不可得则结论记「编译通过、运行时 deferred」，不得写成通过。
- W7-B（条件备选）：若启用，先桌面 JVM 冒烟（ajni invocation，`-Xcheck:jni`）再上设备；止损：ajni 桌面路径不可用即停。
**验收**：T-W7-1…T-W7-3 对应各里程碑；每里程碑独立过五门禁 + 证据登记。

### W8 Linux 平台实证（P2/S）

**目标**：B16——ci.yml ubuntu 路径与 stub pthread 分支（递归锁/线程 id/nanosleep）取得实跑证据；顺带覆盖 README §6「E1 原始 pthread 实验未实测」的设计目的。
**非目标**：不改 CI 结构；不新增门禁。
**实现要点**：在 Linux（WSL/容器或 GitHub Actions 实跑）执行五门禁 + threaded 测试子集；把结果（日期/环境/计数）登记进 `docs/CHANGELOG.md` 与 README §6；ci.yml 的「[仍需实测]」注释随证据更新。
**验收**：T-W8-1（Linux 五门禁全绿证据：命令+日期+31/31 计数）；T-W8-2（threaded marshal 测试在 pthread 路径通过）；T-W8-3（README 风险节同步）。

## 5. 里程碑与合入顺序

```text
M0（第 1 日）  W1 漂移清理（零风险文档）
M1             W2 冒烟 fail-closed + 元数据（验证安全缺口）
M2             W3 方向元数据、W4 marshal 可观测（高价值低成本）
M3             W5 详细枚举、W6 设备事件、W8 Linux 实证
M4（E4 解禁后） W7 真实对接（已裁决：camera2ndk 首选；M7-1 探测/加载→M7-2 编译差分→M7-3 真机差分）
```

排序判据：先零风险文档、再安全缺口、再高价值低成本、最后安全敏感大工程；每包独立提交、独立过五门禁。W3–W6 相互无依赖，可并行。

## 6. 簿记与变更管理

- `docs/CHANGELOG.md`（W1 建立）：每包登记「日期/工作包/新增 pub 声明/快照 diff 结论/测试增量」。
- `docs/API.md`（W1 建立）：加法性变更 ledger，与 ci.yml Gate 5 文案对齐。
- README API 索引随 `moon info` 快照同步（禁手编 mbti）。
- 破坏性需求一律走四件例外流程（ADR + 用户裁决 + CHANGELOG + 主版本）。

## 7. 完成定义（DoD，逐包勾选）

- [ ] 新增 API 与 mbti 草案一致（偏差回写本文）
- [ ] 快照 diff 纯加法，CHANGELOG 已登记
- [ ] T-W*-* 验收全绿；#skip 显式标注原因（当前基线零 #skip，B15）
- [ ] 五门禁全绿；冒烟输出行契约零意外漂移
- [ ] 畸形语料无 panic（新增解析路径进截断扫描，见测试系统设计 §4）
- [ ] 零新第三方依赖（W7-B 备选除外，须五门槛）；零许可不明二进制入库
- [ ] README 能力/非目标同步；本文状态行更新「已交付+日期」

## 8. 风险登记

| 风险 | 等级 | 缓解 |
|---|---|---|
| 目标设备 camera2ndk/EXTERNAL 可用性未实证（W7 前置） | 高 | M7-1 设备探测 + E3 最小加载先行止损；降级维持 stub；ajni 仅作 W7-B 备选且须五门槛 |
| 新私有 shim 扩大 ABI 面，真实对接成本上升 | 中 | W4/W5/W6 各仅 1 个定长打包 shim，abi.h 同步登记；真实 native-stub 按符号清单实现 |
| Linux pthread 路径与 Windows 语义偏差 | 中 | W8 实证；递归锁/线程 id 已按平台分支实现（B14），测试断言平台无关 |
| 方向元数据被误解为「已做像素旋转」 | 中 | `applied` 恒 false 恒等式（I6）+ README 显式声明 + W3 验收断言 |
| 文档漂移复发 | 低 | W1 后引用实存性扫描（T-W1-1）纳入 L5 元契约门禁 |
| stub_reset 线程卫生约束被新测试违反 | 低 | 测试系统设计 §10 维护规则：threaded 测试必须先 close 再 reset（B26） |