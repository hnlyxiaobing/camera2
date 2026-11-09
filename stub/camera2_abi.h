/*
 * camera2_abi.h —— mb_camera2_* shim ABI 接口预留（R4）。
 *
 * 本头文件是**桌面 stub 与后续真实 JNI native-stub 共用**的 C ABI 契约：
 * - 当前实现：stub/camera2_stub.c（桌面 stub，模拟 Java Camera2 / JNI 语义）；
 * - 后续真实对接（E4 解禁后的 P1）：真实 JNI native-stub C 文件**实现同一批符号**，
 *   MoonBit 侧 extern 声明零改动（符号名 / 签名 / 状态码不变）。
 * 真实 Java Camera2 样板与 ajni@0.3.6 host bridge 的设计见 docs/DESIGN.md §15。
 *
 * ABI（MoonBit native/C 后端，见 MoonBit FFI 文档）：
 *   Int -> int32_t, UInt64 -> uint64_t, Unit -> void,
 *   Bytes / FixedArray[Byte] -> uint8_t*（长度取自 MoonBit 数组头）,
 *   #external 句柄 -> void*,
 *   FuncRef[(() -> Unit) -> Unit] -> void (*)(void*),
 *   () -> Unit（闭包）-> void*（MoonBit 对象，RC 由 C 侧管理）。
 *
 * 线程角色（ADR-0009）：
 *   - owner 线程 = 创建 JNI session 的线程（Camera.owner_thread_id）：
 *     所有 MoonBit 闭包**只在 owner 线程执行**（经 mb_camera2_marshal_pump）。
 *   - 投递线程 = 相机/ImageReader 回调线程（threaded stub 的独立线程）：
 *     只做**浅拷贝入队**（marshal_push），绝不执行 MoonBit 闭包、绝不触碰 JNI session。
 *
 * 回调 marshal 队列契约（R4）：
 *   - 每 reader 一个有界 FIFO（MAX_MARSHAL），事件 = 打包帧 malloc 副本 + 单调 seq；
 *     满则丢最旧（keep-latest）并计数 mq_dropped；出队顺序 = 线性化入队顺序。
 *   - mb_camera2_marshal_pump：owner 线程同步派发，每事件恰好调用一次已注册
 *     二元组 (cb, closure)；无注册回调时事件被丢弃（保证队列有界排水）。
 *   - mb_camera2_marshal_next：**仅在派发期间**（dispatch_depth > 0）由被调闭包
 *     拉取暂存事件；两段式（容量不足返回所需容量、不消费；足够则拷贝并消费）。
 *   - 重入：派发期间再次 pump 返回 ST_REENTRANT(-15)，由 MoonBit 映射
 *     CameraError::MarshalReentrant。
 *   - 关闭竞态：派发期间 close 延迟释放结构体（close_pending），pump 收尾统一拆除；
 *     close 后 queued/staged 事件全部释放，不再派发。
 *
 * 打包帧格式（mb_camera2_acquire_frame 填充 / marshal 事件载荷，小端）：
 *   [0..4)   width  i32        [4..8)  height i32
 *   [8..16)  timestamp_ns u64
 *   [16..32) plane0 { data_offset i32, data_length i32, row_stride i32, pixel_stride i32 }
 *   [32..48) plane1 同上       [48..64) plane2 同上
 *   [64..)   3 段平面字节（依次排列）
 *
 * 状态码：
 *   0 ok, -1 failed, -2 permission, -3 not found, -4 unsupported size,
 *   -5 unsupported format, -6 acquire failed, -7 pool exhausted,
 *   -8 JNI thread not attached, -9 vendor quirk, -10 preview failed,
 *   -11 timeout, -12 capacity too small, -13 invalid arg, -14 already open,
 *   -15 reentrant pump（marshal 层）。
 */
#ifndef CAMERA2_ABI_H
#define CAMERA2_ABI_H

#include <stdint.h>

/* ---------------- 状态码 ---------------- */
#define ST_OK 0
#define ST_FAILED (-1)
#define ST_PERMISSION (-2)
#define ST_NOT_FOUND (-3)
#define ST_UNSUPPORTED_SIZE (-4)
#define ST_UNSUPPORTED_FORMAT (-5)
#define ST_ACQUIRE_FAILED (-6)
#define ST_POOL_EXHAUSTED (-7)
#define ST_NOT_ATTACHED (-8)
#define ST_VENDOR_QUIRK (-9)
#define ST_PREVIEW_FAILED (-10)
#define ST_TIMEOUT (-11)
#define ST_CAPACITY (-12)
#define ST_INVALID_ARG (-13)
#define ST_ALREADY_OPEN (-14)
#define ST_REENTRANT (-15)

/* ---------------- 会话生命周期（9 个核心 shim） ---------------- */
int32_t mb_camera2_init(void *vm);
void *mb_camera2_open(uint8_t *camera_id, int32_t width, int32_t height,
                      int32_t max_buffers);
void *mb_camera2_create_reader(void *camera, int32_t width, int32_t height,
                               int32_t max_buffers);
int32_t mb_camera2_start_preview(void *camera, void *reader);
int32_t mb_camera2_acquire_frame(void *reader, uint8_t *dst, int32_t capacity,
                                 int32_t timeout_ms);
void mb_camera2_release_frame(void *reader);
int32_t mb_camera2_set_frame_callback(void *reader, void (*cb)(void *),
                                      void *closure);
void mb_camera2_clear_frame_callback(void *reader);
void mb_camera2_close(void *camera, void *reader);

/* ---------------- 回调 marshal 层（R4，ADR-0009） ---------------- */
int32_t mb_camera2_marshal_pump(void *reader, int32_t max_events);
int32_t mb_camera2_marshal_next(void *reader, uint8_t *dst, int32_t capacity);

/* ---------------- 内部 shim（状态 / 线程 / 枚举） ---------------- */
int32_t mb_camera2_last_status(void);
uint64_t mb_camera2_current_thread_id(void);
int32_t mb_camera2_session_alive(void *camera, void *reader);
int32_t mb_camera2_enumerate_raw(void *vm, uint8_t *dst, int32_t capacity);

/* ---------------- 桌面 stub 测试替身控制（非真实 ABI） ---------------- */
void mb_camera2_stub_reset(void);
void *mb_camera2_stub_fake_vm(void);
void mb_camera2_stub_set_open_status(int32_t st);
void mb_camera2_stub_set_reader_status(int32_t st);
void mb_camera2_stub_set_preview_status(int32_t st);
void mb_camera2_stub_set_acquire_status(int32_t st);
void mb_camera2_stub_set_unattached(int32_t flag);
void mb_camera2_stub_set_threaded(int32_t flag);
void mb_camera2_stub_set_frame_count(int32_t n);
void mb_camera2_stub_set_frame_interval_ms(int32_t ms);
int32_t mb_camera2_stub_produce(void *reader);
int32_t mb_camera2_stub_callback_calls(void *reader);
int32_t mb_camera2_stub_live_closures(void);
int32_t mb_camera2_stub_live_cameras(void);
int32_t mb_camera2_stub_live_readers(void);
int32_t mb_camera2_stub_inflight(void *reader);
int32_t mb_camera2_stub_pending(void *reader);
void mb_camera2_stub_sleep(int32_t ms);
void mb_camera2_stub_quiesce(void);
int32_t mb_camera2_stub_marshal_pending(void *reader);
int32_t mb_camera2_stub_marshal_dropped(void *reader);
int32_t mb_camera2_stub_marshal_pushed(void *reader);
int32_t mb_camera2_stub_marshal_live_events(void);

#endif /* CAMERA2_ABI_H */
