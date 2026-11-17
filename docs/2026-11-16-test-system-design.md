# camera2 测试系统设计（第一性原理）

> 建立：2026-11-16 ｜ 状态：设计生效，随开发文档逐包落地 ｜ 适用仓库：本仓库（独立自包含）
> 配套文档：[2026-11-16-camera2-benchmark-dev-plan.md](2026-11-16-camera2-benchmark-dev-plan.md)（`T-W*-*` 验收 ID 一一对应；B# 现状证据出自该文档 §0.2）
> 基线实测（2026-11-16，Windows/MSVC x86_64）：`moon test` **31/31**（白盒 28 + 黑盒 3），**零 `#skip`**；五门禁全绿、mbti 快照无 diff。

## 1. 第一性原理：本库的正确性是什么

本库的数学形态：`(JavaVMPtr, CameraConfig, 帧事件流) → (中性 YuvFrame 纯值序列, owner 线程回调派发) | CameraError`，
约束条件为 JNI 线程亲和性与 C 句柄生命周期。正确性不可约简为以下断言（FFI 取帧模块裁剪：A6 为线程/所有权断言，A7 为跨 OS 平台等价；本库 `preferred_target=native`，无 wasm 等价义务）：

| # | 断言 | 含义 | 反例（测试必须抓住） |
|---|---|---|---|
| A1 | 帧忠实（寻址忠实） | 样本字节、stride 描述、时间戳与打包格式规范逐一对应；非样本字节不被误读为样本 | 行尾 padding 0xEE 被当作像素；U/V pixel_stride=2 被按 1 读；时间戳错位 |
| A2 | 完整性 fail-closed | 畸形帧/畸形枚举必抛 `UnsupportedFormat`；会话已死必拒绝；未校验≠通过 | 截断头被静默解析；off+len 越界帧被产出；close 后操作成功 |
| A3 | 边界纯净 | 只输出声明的中性值类型；不产出格式推断/颜色转换/下游语义；帧源可替换 | `YuvFrame` 被隐式当作 RGB；trait 实现被绑定到相机 |
| A4 | 输入安全 | 任意畸形输入不 panic/不越界；内存有界（marshal 8、pending 32、枚举 65536、维度 16384） | 畸形 count=999 导致巨量分配；stride 覆盖校验缺失导致 OOB 读 |
| A5 | 契约稳定 | mbti 快照纯加法；13 错误变体集合冻结；冒烟输出行格式不变；变更只加法 | 既有 struct 被加字段；新错误变体混入；快照意外 diff |
| A6 | 线程与所有权安全 | 闭包只在 owner 线程执行；投递线程只入队；`#owned` 成对不泄漏；不二次释放/不 UAF；重入 pump 被拒 | 投递线程跑 MoonBit 闭包；set 失败泄漏闭包；回调内 close 后 pump 触碰已释放结构体 |
| A7 | 平台等价（native 内跨 OS） | Windows/MSVC 与 Linux/pthread 同输入同输出同记账 | 递归锁语义差异导致回调内 grab 死锁；线程 id 口径不一致导致 owner 守卫误判 |

设计推论：A1/A2 → 性质测试 + 截断扫描；A2/A6 → 恒等式断言 + 错误簿记；A4 → 畸形语料 + 边界值矩阵；A5 → 快照/簿记门禁；A6 → 白盒并发测试 + 泄漏观测符号；A7 → Linux 实证 job（W8）；真机符合性 → 外部 oracle 层（E4 解禁后，许可约束下本地可选）。

## 2. 测试分层

```text
L0 单元与程序化 fixture（每个 pub fn 行为样例；现状 31 条）
L1 性质与变异（截断扫描/位翻转/边界值/固定种子变异；现状部分，待扩）
L2 受控黄金差分（stub 确定性像素图案 = 程序化黄金记录；现状 check_frame 体系）
L3 外部 oracle 差分（真机 Camera2/ndk 取帧对照；E4 门禁，解禁前显式 SKIPPED）
L4 冒烟场景 E2E（cmd/main 输出行 + 退出码矩阵；现状退出码 fail-open，W2 修复）
L5 元契约门禁（快照/错误簿记/引用实存性/变异自检）
R  真机样本本地 runner（仓库外路径 + SHA-256 门禁 + 显式 SKIPPED；W7 M7-3）
```

断言×层承载表：

| 断言 | 主承载层 | 辅助层 |
|---|---|---|
| A1 帧忠实 | L2（check_frame 逐样本） | L0（stride 描述断言）、L1（图案变形律） |
| A2 fail-closed | L0（畸形解析 5+3 类） | L1（截断扫描）、L5（错误簿记） |
| A3 边界纯净 | L0（黑盒 FileSource 替身） | L5（快照门禁） |
| A4 输入安全 | L1（边界值/变异） | L0（畸形用例）、L2（内存有界观测） |
| A5 契约稳定 | L5（快照 + 簿记） | L4（输出行契约） |
| A6 线程/所有权 | L0 白盒（marshal 9 例 + 泄漏观测） | L1（并发乱序）、L5（变异自检） |
| A7 平台等价 | W8 Linux 实证 job | L0 全量在 Linux 重跑 |

## 3. fixture 体系

| 类 | 形态 | 入库 | 许可 | 现状 |
|---|---|---|---|---|
| F-A 程序化构造 | 测试代码字节 builder（`write_i32_le` 篡改打包缓冲） | 是 | 随仓库 | 已有（wbtest 畸形帧/枚举用例） |
| F-B 受控文件 fixture | 无（本库不读文件；帧来自 stub 内存打包） | — | — | 不适用，登记为「无」 |
| F-C 生成器资产 | stub 确定性像素图案 `(k*7+x+y*3+p*64)&255` + 0xEE padding + 时间戳 `(k+1)*33333333` | 是（C 源码即生成器） | 自产 | 已有（`fill_frame`/`sample_byte`） |
| F-D 真机第三方样本 | 仓库外本地路径（真机 YUV dump） | 否（红线） | Android SDK License 3.4 不可再分发 | R runner（W7 M7-3，解禁前 SKIPPED） |

红线：F-D 永不入库；stub 图案常量（stride 增量 8/4、时间戳步长、0xEE）变更须同步 `check_frame`/`expected_sample` 黄金断言（防样本漂移假绿）。
builder 能力清单（现状 + 待扩）：
- 已有：合法打包帧（raw_acquire）、截断 written、零宽、plane offset 越界、零 row_stride、stride 覆盖不足、枚举截断/非法 count/非法 facing。
- 待扩（L1）：全前缀截断扫描、单 bit 翻转、负 len/负 off、ps=0、维度 16384±1、id_len 255±1、size_count 64±1、count 64±1、固定种子随机变异。

## 4. L1 性质与变异

- 变形律 P#：
  - P1 图案保真律：任意合法 (w,h,k)，逐样本 `data[row*rs+x*ps] == (k*7+x+y*3+p*64)&255`（现状 check_frame 覆盖 320×240；待扩多尺寸）。
  - P2 padding 不变性：行尾与 chroma 间隔字节恒 0xEE，不被读作样本（现状已断言）。
  - P3 幂等律：`start_preview` 双击、`clear_on_frame` 双调、`close` 双调（第二次必 `AlreadyClosed`）（现状已覆盖）。
  - P4 双通道一致律：同一帧序号 k 经 grab_yuv 与 marshal 回调两通道产出的帧逐字节一致（现状分别断言图案；待扩显式跨通道差分）。
  - P5 记账守恒律：`pushed == dispatched + dropped + pending`（现状白盒观测符号断言；W4 后升级为公开 API 断言 I7）。
  - P6 方向恒等律（W3 新增）：`frame_orientation.applied == false` 恒成立。
- 位翻转：打包帧头 width/height/off/len/rs/ps 各字段单 bit 翻转 → 必被 `UnsupportedFormat` 拒绝或产出仍满足 P1（不允许静默错误帧）；待建。
- 边界值矩阵：维度 {1, 2, 16384, 16385}、written {63, 64, 65}、off {63, 64, written-len, written-len+1}、pool {0, 1, 2}、max_events {0, -3, 1, 8, 16}、timeout {0, 负数, 20}（现状部分：0/负 max_events、pool 0/1、超时 20 已覆盖；其余待建）。
- 截断扫描：对合法打包帧与枚举缓冲的**全前缀**（0..written）逐一喂 `parse_yuv_frame`/`parse_camera_infos`，只允许 `UnsupportedFormat` 或合法解析，不允许 panic/挂起；结构边界点（64、各 plane off）必测。待建（W3–W6 新解析路径同规则入集）。
- 变异语料：固定种子（登记种子值）随机替换/插入/删除，每轮 ≥1000 变异体，断言同截断扫描。待建。

## 5. L3 oracle 矩阵 + R runner

| oracle | 差分对象 | 规范化口径 |
|---|---|---|
| 真机 Camera2（Java）/ camera2ndk（NDK）YUV_420_888 dump | 只比本库声明输出：width/height/三平面 row_stride/pixel_stride/样本字节/时间戳单调性 | 按 stride 索引取样本（不比 padding 布局差异）；时间戳只比单调递增，不比绝对值（时钟源不同） |
| ajni 桌面 JVM 冒烟（仅 W7-B 备选启用时；首选路径为 camera2ndk，见开发文档 W7 裁决记录） | JNI 调用序列合法性（`-Xcheck:jni`） | 不比帧内容，只比调用契约 |

纪律：oracle 缺失（E4 未解禁/无真机）→ 显式 SKIPPED + 原因（退出码 78 口径），不得写成通过；oracle 版本（Android API level/NDK 版本/ajni 版本）随结果登记。
R runner：样本路径 + 登记哈希 → 哈希不符拒绝执行 → 规范化差分 → 报告「本地已差分 + 哈希 + 日期」；入库 `#skip` 用例保留不删，真实结论永不进入通过计数。当前基线零 `#skip`（B15）；W7 引入的真机用例必须自带 SKIPPED 守卫。

## 6. 覆盖矩阵与错误簿记

### 6.1 能力×场景×安全 覆盖矩阵

现状列来自 P4 事实核查（B# 见开发文档 §0.2）；「✅」= 已有用例，「部分」= 有但不完备，「待建」= 无。

| ID | 能力/场景 | L0 | L1 | L2 | L3 | L4 | 现状(P4) | 缺口→W# |
|---|---|---|---|---|---|---|---|---|
| F1 | 枚举+能力快照 | ✅ | 部分（3 类畸形） | ✅（4 台黄金） | SKIPPED | ✅（冒烟首行） | B3 | 截断扫描→L1 扩建；深度→W5 |
| F2 | open 生命周期 | ✅（9 类错误映射+逆序释放） | 待建（config 边界矩阵） | — | SKIPPED | ✅ | B4 | W3（config 校验）|
| F3 | 幂等预览 | ✅ | 待建（P3 已覆盖双击） | — | SKIPPED | ✅ | B5 | — |
| F4 | 同步取帧 | ✅（超时/池耗尽/强制失败/预算） | 部分（畸形 5 类） | ✅（check_frame） | SKIPPED | ✅ | B6/B7 | 截断扫描/位翻转→L1 扩建 |
| F5 | 回调注册/注销 | ✅（成对/替换/失败路径） | — | — | SKIPPED | — | B8 | — |
| F6 | marshal 层 | ✅（9 例并发/重入/满队列/关闭竞态） | 部分（乱序并发） | ✅（FIFO 时间戳） | SKIPPED | — | B9/B10 | 公开记账→W4 |
| F7 | 幂等关闭 | ✅ | — | ✅（live_* 归零） | SKIPPED | ✅ | B11 | — |
| F8 | 可替换帧源 | ✅（黑盒 FileSource） | — | — | — | — | B13 | — |
| F9 | 错误模型+fail-closed | ✅（13/13 簿记见 §6.2） | 待建（变异） | — | — | — | B7/B15 | L1 扩建 |
| F10 | stub 故障注入 | ✅（全链路） | — | — | — | — | B14/B26 | 线程卫生规则→§10 |
| F11 | 中性值类型 | ✅（黑盒构造） | — | — | — | — | B21 | 方向元数据→W3 |
| F12 | ABI 契约 | ✅（build 链接校验） | — | — | — | — | B2 | 新 shim 登记→W4/W5/W6 |
| S1 | 预期场景端到端（enumerate→open→preview→grab→close） | ✅ | — | ✅ | SKIPPED | 部分（退出码 fail-open） | B22 | W2 |
| S2 | 实时流场景（threaded 投递→pump 循环→clear→close） | ✅ | 部分 | ✅ | SKIPPED | — | B14 | — |
| C1 | 投递线程不执行闭包 | ✅（tids 断言） | — | — | — | — | B14 | 变异自检→§8 |
| C2 | 资源零泄漏（closures/cameras/readers/events） | ✅（live_* 观测） | — | — | — | — | B8/B10 | — |
| C3 | 不二次释放/不 UAF | ✅（回调内 close + 延迟释放） | — | — | — | — | B10/B11 | 变异自检→§8 |
| C4 | 畸形输入不 panic | ✅（11 类） | 待建（≥1000 变异体） | — | — | — | B7 | L1 扩建 |
| C5 | 快照纯加法/错误变体冻结 | — | — | — | — | — | B1/B15 | L5 门禁→§8 |
| C6 | 跨 OS 语义等价 | — | — | — | — | — | B16（Linux 未实证） | W8 |

### 6.2 错误变体触发簿记（13/13 强制，现状全满足）

| 变体 | 触发 fixture（现状，显式断言变体名） | 新增触发（待建） |
|---|---|---|
| PermissionDenied(String) | open 注入 -2（wbtest "open error mapping"） | — |
| CameraNotFound(String) | open id "9"；黑盒 FileSource 耗尽 | — |
| OpenFailed(Int32,String) | open -1；reader -1；pool 0（-13）；pump max_events 0/-3（-13） | W4/W5/W6 守卫兜底路径沿用 |
| PreviewFailed(Int32,String) | preview -10 / -1 | — |
| UnsupportedSize(Int32,Int32) | open 1000×1000；open 0×0 | W3 报告值化（不抛错） |
| UnsupportedFormat(String) | open 设备 "3"；帧畸形 5 类；枚举畸形 3 类 | L1 截断/变异全量；W5 新解析 5 类 |
| BufferAcquireFailed(Int32) | 未预览超时 20；注入 -6；预算耗尽 30 | 边界 timeout 0/负数 |
| BufferPoolExhausted(Int32) | pool=1 裸 acquire 占满 | — |
| JniThreadNotAttached(String) | open unattached；ensure_owner(123456)；on_frame unattached；pump_error(-8) | W3/W4/W6 错线程守卫各 1 例 |
| MarshalReentrant(String) | 回调内重入 pump；pump_error(-15) | — |
| AlreadyOpen | 同设备双开 | — |
| AlreadyClosed | close 后 5 类操作；黑盒 FileSource 重复 close | W3/W4/W6 close 后查询各 1 例 |
| VendorQuirk(String) | open 注入 -9 | — |

门禁：本表与测试代码双向核对（L5），缺一即红；新增 API 只允许复用本表变体，新增变体即破坏性变更（四件例外流程）。

### 6.3 恒等式断言（语义契约，全路径成立）

- I1 记账守恒：`pushed == dispatched + dropped + pending`（现状白盒；W4 后公开 API 复验）。
- I2 资源归零：close 返回后 `live_cameras == live_readers == live_closures == marshal_live == 0`（现状多例）。
- I3 缓冲归还：每次 grab_yuv 返回/抛出后 `in_flight == 0`（现状；errdefer 路径含解析失败）。
- I4 线程归属：所有回调执行线程 id == owner 线程 id（现状 tids 断言）。
- I5 FIFO 线性化：派发序列时间戳严格递增（现状满队列/乱序并发例）。
- I6 方向未应用（W3）：`frame_orientation.applied == false` 恒成立。
- I7 公开记账（W4）：`marshal_stats` 满足 I1，且与白盒观测符号逐字段一致。
- I8 状态单分支：任何 `Camera` 构造点 `state == CameraState::Open`（唯一写入点 `Camera::open`）。
- I9 关闭幂等：第二次 close 必 `AlreadyClosed` 且 C 侧释放计数不增（现状 + C 层防御双保险）。
- I10 旧语义防火墙（W3–W6 每包）：新 API 合入前后，既有 31 条测试零修改全绿。

### 6.4 验收 ID 双向追溯（T-W*-* ↔ W# ↔ 矩阵缺口）

| 验收 ID（开发文档 §4 定义） | 工作包 | 矩阵缺口行 | 断言承载 |
|---|---|---|---|
| T-W1-1…3 | W1 漂移清理 | C5（引用实存性门禁） | A5 |
| T-W2-1…3 | W2 冒烟 fail-closed | S1 | A5/A2 |
| T-W3-1…4 | W3 方向元数据 | F2/F11 | A3/A5 + I6/I10 |
| T-W4-1…4 | W4 marshal 可观测 | F6 | A6 + I1/I7/I10 |
| T-W5-1…4 | W5 详细枚举 | F1 | A2/A4 + I10 |
| T-W6-1…4 | W6 设备事件 | F9（异步事件通道） | A2/A6 + I10 |
| T-W7-1…3 | W7 真实对接（已裁决：camera2ndk 首选；M7-1 探测/加载、M7-2 编译差分、M7-3 真机差分） | L3/R 层 | A1/A7（真机 oracle） |
| T-W8-1…3 | W8 Linux 实证 | C6 | A7 |

## 7. L4 冒烟场景 E2E

| 场景 | 命令序列 | 断言要点（退出码+输出） |
|---|---|---|
| 正常全链路 | `moon run cmd/main` | 退出码 0；输出含 `camera2 smoke: 4 cameras`、`camera2 smoke: frame 640x480, 3 planes`、`camera2 smoke OK` |
| 失败路径（W2 后） | 注入 open 失败后运行冒烟 | 退出码非 0；输出含 `camera2 smoke FAILED`（现状退出码 0 = fail-open 缺口，B22→W2） |

输出行契约冻结口径：上述三行前缀与格式即现有契约，变更即破坏；本库无独立 CLI、无子命令/选项（README §5），退出码矩阵仅 0/非 0 两档。落盘哈希不适用（冒烟无落盘）。

## 8. L5 元契约门禁

1. 快照门禁：`moon info` + `git diff --exit-code -- pkg.generated.mbti cmd/main/pkg.generated.mbti`（纯加法；现状 CI Gate 5 已挂）。
2. 错误簿记门禁：§6.2 与测试代码双向核对，缺一即红（脚本层，待建）。
3. 引用实存性门禁（W1 后）：全仓 `docs/*` 引用逐一存在性扫描（防 B17/B18 类漂移复发；脚本层，待建）。
4. 变异自检：注入 3 类缺陷——①跳过 `parse_yuv_frame` stride 覆盖校验；②放行 off+len 越界；③移除 `dispatch_depth` 重入守卫——套件必须变红后还原复绿（每类至少 1 条现有用例捕获；待建脚本）。
5. 计数纪律：`#skip` 不计通过；SKIPPED/退出码 78 单列；测试过滤串以 `*` 结尾防空转假绿。
6. 平台等价（W8）：Linux 实跑五门禁 + threaded 子集，证据登记日期/环境/计数；未实证前不得声称跨平台通过。

## 9. CI 集成与执行入口

五门禁不变（ci.yml five-gates job）；L0/L1/L2 挂 `moon test`；L3/L4 扩展/R/变异自检为脚本层可选 job，缺失显式 SKIPPED。
复验命令（本仓库自包含）：

```text
moon clean
moon check --deny-warn
moon build
moon test            # 基线 31/31；每包合入后计数递增并登记
moon fmt --check
moon info            # 随后 git diff --exit-code -- pkg.generated.mbti cmd/main/pkg.generated.mbti
moon run cmd/main    # 冒烟三行 + 退出码 0（W2 后失败路径非 0）
```

## 10. 维护规则与验收清单

1. 新增 pub API ⇒ 同提交附 L0 样例 + L1 性质 + 矩阵/簿记更新；无测试不合入。
2. 新增解析路径（W5/W6）⇒ 进截断扫描 fixture 集（全前缀 + 结构边界点）。
3. stub 图案常量变更 ⇒ `check_frame`/`expected_sample` 黄金断言同提交更新（防漂移假绿）。
4. threaded 测试必须先 `close` 再 `stub_reset`（B26 线程卫生约束）；新并发用例须带等待上限防挂死（现状 `rounds < 100` 模式）。
5. 每包合入 ⇒ 开发文档 DoD 勾选 + 矩阵现状刷新 + CHANGELOG 测试增量。
6. 「通过」须可复验：命令 + 日期 + 计数；SKIPPED 永远单列；真机结论在 E4 解禁前一律 deferred。

落地验收（逐层勾选）：
- [x] L0：31/31 基线全绿（2026-11-16 实测，零 #skip）
- [ ] L1：截断扫描/位翻转/边界矩阵/≥1000 变异体（待建，随 W3–W6 入集）
- [x] L2：check_frame 黄金体系（多尺寸扩展待建）
- [ ] L3：真机 oracle（W7 解禁（E4）前 SKIPPED，不得预写通过）
- [ ] L4：退出码矩阵（W2 交付后勾选）
- [ ] L5：簿记/引用实存性/变异自检脚本（W1 后逐项建）
- [ ] R：真机 runner（W7 M7-3）
- [ ] A7：Linux 实证（W8）