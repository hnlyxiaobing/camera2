/*
 * camera2 desktop stub —— Java Camera2 / JNI 的桌面替身（桌面 stub 阶段）。
 *
 * ⚠ 桌面 stub，真实 JNI / ajni@0.3.6 / 设备取帧（红米电视 720p YUV）留待后续
 *   真实对接阶段——ajni 在 Windows 主机 + 目标设备真机的可用性未实证。本文件只模拟：
 *   - JavaVM 缓存（mb_camera2_init）与线程局部 JNIEnv 约定（unattached 注入点）；
 *   - 假设备枚举（4 台：id 0/1/2/3，含一台不支持 YUV_420_888）；
 *   - 相机会话句柄 + ImageReader 缓冲池（max_buffers 张在飞即耗尽）；
 *   - 可配置帧序列（帧预算、投递间隔、确定性像素图案、非紧凑 stride）；
 *   - 帧回调二元组 (FuncRef + #owned closure)：保存、成对持有/释放，
 *     注销/替换/关闭时 moonbit_decref；每次调用前 moonbit_incref（callee 按
 *     owned 约定在作用域末 decref 一次）；
 *   - 回调可从独立投递线程触发（threaded 模式），模拟相机投递线程语义。
 *
 * C ABI（MoonBit native/C 后端，见 MoonBit FFI 文档）：
 *   Int -> int32_t, UInt64 -> uint64_t, Unit -> void,
 *   Bytes / FixedArray[Byte] -> uint8_t*（长度取自 MoonBit 数组头）,
 *   #external -> void*,
 *   FuncRef[(() -> Unit) -> Unit] -> void (*)(void*),
 *   () -> Unit（闭包）-> void*（MoonBit 对象，RC 由 C 侧管理）。
 *
 * 打包帧格式（mb_camera2_acquire_frame 填充「3 段 plane + stride 头」，小端）：
 *   [0..4)   width  i32        [4..8)  height i32
 *   [8..16)  timestamp_ns u64
 *   [16..32) plane0 { data_offset i32, data_length i32, row_stride i32, pixel_stride i32 }
 *   [32..48) plane1 同上       [48..64) plane2 同上
 *   [64..)   3 段平面字节（依次排列）
 * 帧几何（由 reader 的 width/height 决定）：
 *   Y : rows=h   row_stride=w+8 pixel_stride=1
 *   U/V: rows=h/2 row_stride=w+4 pixel_stride=2（U/V 共享 rowStride/pixelStride）
 * 像素图案（帧序号 k，样本 (x,y)，平面 p=0/1/2）：(k*7 + x + y*3 + p*64) & 0xFF
 * 非样本字节（行尾 padding / chroma 间隔字节）恒为 0xEE。
 *
 * 状态码（mb_camera2_last_status 同步暴露，线程局部）：
 *   0 ok, -1 failed, -2 permission, -3 not found, -4 unsupported size,
 *   -5 unsupported format, -6 acquire failed, -7 pool exhausted,
 *   -8 JNI thread not attached, -9 vendor quirk, -10 preview failed,
 *   -11 timeout, -12 capacity too small, -13 invalid arg, -14 already open。
 * mb_camera2_acquire_frame 返回约定：0 成功；负数为状态码；正数为所需缓冲容量
 * （capacity 不足时不消费帧，调用方按返回值重试）。
 */
#include "moonbit.h"

#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#endif

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

#define FRAME_HEADER_SIZE 64
#define MAX_SESSIONS 64
#define MAX_PENDING 32
#define MAX_DEVICES 4

/* ---------------- 递归锁（回调可重入 acquire） ---------------- */
#ifdef _WIN32
static CRITICAL_SECTION g_lock;
static INIT_ONCE g_lock_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK lock_init_cb(PINIT_ONCE once, PVOID param, PVOID *ctx) {
  (void)once;
  (void)param;
  (void)ctx;
  InitializeCriticalSection(&g_lock);
  return TRUE;
}
static void lock(void) {
  InitOnceExecuteOnce(&g_lock_once, lock_init_cb, NULL, NULL);
  EnterCriticalSection(&g_lock);
}
static void unlock(void) { LeaveCriticalSection(&g_lock); }
static void sleep_ms(int32_t ms) {
  if (ms > 0) {
    Sleep((DWORD)ms);
  }
}
typedef HANDLE thread_handle_t;
typedef DWORD thread_ret_t;
#define THREAD_CALL WINAPI
#else
static pthread_mutex_t g_lock;
static pthread_once_t g_lock_once = PTHREAD_ONCE_INIT;
static void lock_init_cb(void) {
  pthread_mutexattr_t attr;
  pthread_mutexattr_init(&attr);
  pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
  pthread_mutex_init(&g_lock, &attr);
  pthread_mutexattr_destroy(&attr);
}
static void lock(void) {
  pthread_once(&g_lock_once, lock_init_cb);
  pthread_mutex_lock(&g_lock);
}
static void unlock(void) { pthread_mutex_unlock(&g_lock); }
static void sleep_ms(int32_t ms) {
  if (ms > 0) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
  }
}
typedef pthread_t thread_handle_t;
typedef void *thread_ret_t;
#define THREAD_CALL
#endif

static void set_status(int32_t st);
static int32_t g_dispatching = 0;

/* ---------------- 假设备表 ---------------- */
typedef struct {
  const char *id;
  int32_t facing; /* 0=Front 1=Back 2=External */
  int32_t supports_yuv;
  int32_t size_count;
  int32_t sizes[4][2];
} device_t;

static const device_t g_devices[MAX_DEVICES] = {
    {"0", 1, 1, 3, {{1280, 720}, {640, 480}, {320, 240}}},
    {"1", 0, 1, 1, {{640, 480}, {0, 0}, {0, 0}, {0, 0}}},
    {"2", 2, 1, 2, {{1280, 720}, {640, 480}, {0, 0}, {0, 0}}},
    {"3", 1, 0, 1, {{1920, 1080}, {0, 0}, {0, 0}, {0, 0}}},
};

/* ---------------- 会话对象 ---------------- */
typedef struct {
  int32_t magic;
  char id[16];
  int32_t width;
  int32_t height;
  int32_t max_buffers;
} cam_t;

typedef struct {
  int32_t magic;
  cam_t *cam;
  int32_t width;
  int32_t height;
  int32_t max_buffers;
  int32_t in_flight;
  int32_t previewing;
  int32_t pending[MAX_PENDING];
  int32_t pending_head;
  int32_t pending_len;
  int64_t produced;
  int64_t budget; /* -1 = 无限 */
  void (*cb)(void *);
  void *closure;
  int32_t callback_calls;
  int32_t stop_thread;
  thread_handle_t thread;
  int32_t thread_started;
} reader_t;

#define MAGIC_CAM 0x43414D32
#define MAGIC_RD 0x52444232

static cam_t *g_cams[MAX_SESSIONS];
static reader_t *g_readers[MAX_SESSIONS];
static int32_t g_live_cams = 0;
static int32_t g_live_readers = 0;
static int32_t g_live_closures = 0;

/* ---------------- 全局配置 / 注入点 ---------------- */
static void *g_vm = NULL;
static int32_t g_open_status = ST_OK;
static int32_t g_reader_status = ST_OK;
static int32_t g_preview_status = ST_OK;
static int32_t g_acquire_status = ST_OK;
static int32_t g_unattached = 0;
static int32_t g_threaded = 0;
static int64_t g_frame_interval_ms = 10;
static int g_fake_vm_marker = 0;

#ifdef _MSC_VER
#define MB_TLS __declspec(thread)
#else
#define MB_TLS __thread
#endif
static MB_TLS int32_t g_last_status = ST_OK;

static void set_status(int32_t st) { g_last_status = st; }

static int32_t cam_registered(void *p) {
  int32_t i;
  for (i = 0; i < MAX_SESSIONS; i++) {
    if (g_cams[i] == p && p != NULL) {
      return 1;
    }
  }
  return 0;
}

static int32_t reader_registered(void *p) {
  int32_t i;
  for (i = 0; i < MAX_SESSIONS; i++) {
    if (g_readers[i] == p && p != NULL) {
      return 1;
    }
  }
  return 0;
}

static cam_t *lookup_cam(void *p) {
  return cam_registered(p) ? (cam_t *)p : NULL;
}

static reader_t *lookup_reader(void *p) {
  return reader_registered(p) ? (reader_t *)p : NULL;
}

/* ---------------- 字节读写（小端） ---------------- */
static void w32(uint8_t *p, int32_t off, int32_t v) {
  uint32_t u = (uint32_t)v;
  p[off] = (uint8_t)(u & 0xFF);
  p[off + 1] = (uint8_t)((u >> 8) & 0xFF);
  p[off + 2] = (uint8_t)((u >> 16) & 0xFF);
  p[off + 3] = (uint8_t)((u >> 24) & 0xFF);
}

static void w64(uint8_t *p, int32_t off, uint64_t v) {
  int32_t i;
  for (i = 0; i < 8; i++) {
    p[off + i] = (uint8_t)((v >> (8 * i)) & 0xFF);
  }
}

/* ---------------- 帧几何与填充 ---------------- */
static int32_t frame_y_rows(const reader_t *r) { return r->height; }
static int32_t frame_y_rs(const reader_t *r) { return r->width + 8; }
static int32_t frame_c_rows(const reader_t *r) { return r->height / 2; }
static int32_t frame_c_rs(const reader_t *r) { return r->width + 4; }

static int32_t frame_needed(const reader_t *r) {
  int32_t y_len = frame_y_rs(r) * frame_y_rows(r);
  int32_t c_len = frame_c_rs(r) * frame_c_rows(r);
  return FRAME_HEADER_SIZE + y_len + 2 * c_len;
}

static uint8_t sample_byte(int32_t k, int32_t plane, int32_t x, int32_t y) {
  return (uint8_t)(((k * 7 + x + y * 3 + plane * 64) & 0xFF));
}

static void fill_plane(uint8_t *dst, int32_t rows, int32_t rs, int32_t px,
                       int32_t active_w, int32_t k, int32_t plane) {
  int32_t row, x, col;
  memset(dst, 0xEE, (size_t)(rows * rs));
  for (row = 0; row < rows; row++) {
    for (x = 0; x < active_w; x++) {
      col = x * px;
      dst[row * rs + col] = sample_byte(k, plane, x, row);
    }
  }
}

static void fill_frame(uint8_t *out, const reader_t *r, int32_t k) {
  int32_t w = r->width;
  int32_t h = r->height;
  int32_t y_rs = frame_y_rs(r);
  int32_t y_rows = frame_y_rows(r);
  int32_t c_rs = frame_c_rs(r);
  int32_t c_rows = frame_c_rows(r);
  int32_t y_len = y_rs * y_rows;
  int32_t c_len = c_rs * c_rows;
  uint8_t *yp = out + FRAME_HEADER_SIZE;
  uint8_t *up = yp + y_len;
  uint8_t *vp = up + c_len;

  w32(out, 0, w);
  w32(out, 4, h);
  w64(out, 8, (uint64_t)(k + 1) * 33333333ULL);
  w32(out, 16, FRAME_HEADER_SIZE);
  w32(out, 20, y_len);
  w32(out, 24, y_rs);
  w32(out, 28, 1);
  w32(out, 32, FRAME_HEADER_SIZE + y_len);
  w32(out, 36, c_len);
  w32(out, 40, c_rs);
  w32(out, 44, 2);
  w32(out, 48, FRAME_HEADER_SIZE + y_len + c_len);
  w32(out, 52, c_len);
  w32(out, 56, c_rs);
  w32(out, 60, 2);

  fill_plane(yp, y_rows, y_rs, 1, w, k, 0);
  fill_plane(up, c_rows, c_rs, 2, w / 2, k, 1);
  fill_plane(vp, c_rows, c_rs, 2, w / 2, k, 2);
}

/* ---------------- 回调分发（持递归锁调用） ---------------- */
static void dispatch_locked(reader_t *r) {
  void (*cb)(void *);
  void *closure;
  if (r->cb == NULL || r->closure == NULL) {
    return;
  }
  cb = r->cb;
  closure = r->closure;
  /* owned 调用约定：callee 在作用域末 decref 一次，调用前须 incref。 */
  moonbit_incref(closure);
  r->callback_calls++;
  g_dispatching++;
  cb(closure);
  g_dispatching--;
}

/* ---------------- 帧生产 ---------------- */
static int32_t produce_locked(reader_t *r, int32_t dispatch) {
  int32_t k;
  if (r->budget == 0) {
    return ST_ACQUIRE_FAILED;
  }
  if (r->budget > 0) {
    r->budget--;
  }
  k = (int32_t)r->produced;
  r->produced++;
  if (r->pending_len == MAX_PENDING) {
    /* 队列满：丢最旧（acquireLatest 语义） */
    r->pending_head = (r->pending_head + 1) % MAX_PENDING;
    r->pending_len--;
  }
  r->pending[(r->pending_head + r->pending_len) % MAX_PENDING] = k;
  r->pending_len++;
  if (dispatch) {
    dispatch_locked(r);
  }
  return ST_OK;
}

static int32_t dequeue_locked(reader_t *r) {
  int32_t k;
  k = r->pending[r->pending_head];
  r->pending_head = (r->pending_head + 1) % MAX_PENDING;
  r->pending_len--;
  return k;
}

/* ---------------- 投递线程（threaded 模式） ---------------- */
static thread_ret_t THREAD_CALL producer_main(void *arg) {
  reader_t *r = (reader_t *)arg;
  for (;;) {
    int32_t stop;
    sleep_ms((int32_t)g_frame_interval_ms);
    lock();
    stop = r->stop_thread;
    if (!stop && r->pending_len == 0) {
      produce_locked(r, 1);
    }
    unlock();
    if (stop) {
      break;
    }
  }
#ifdef _WIN32
  return 0;
#else
  return NULL;
#endif
}

static void start_thread_locked(reader_t *r) {
#ifdef _WIN32
  r->thread = CreateThread(NULL, 0, producer_main, r, 0, NULL);
  r->thread_started = (r->thread != NULL);
#else
  r->thread_started = (pthread_create(&r->thread, NULL, producer_main, r) == 0);
#endif
}

static void join_thread(reader_t *r) {
  if (!r->thread_started) {
    return;
  }
#ifdef _WIN32
  WaitForSingleObject(r->thread, INFINITE);
  CloseHandle(r->thread);
#else
  pthread_join(r->thread, NULL);
#endif
  r->thread_started = 0;
}

/* ================= 9 个 shim ================= */

int32_t mb_camera2_init(void *vm) {
  int32_t st = ST_OK;
  lock();
  if (g_unattached) {
    st = ST_NOT_ATTACHED;
  } else if (vm == NULL) {
    st = ST_INVALID_ARG;
  } else if (g_vm == NULL) {
    g_vm = vm;
  } else if (g_vm != vm) {
    st = ST_INVALID_ARG;
  }
  set_status(st);
  unlock();
  return st;
}

void *mb_camera2_open(uint8_t *camera_id, int32_t width, int32_t height,
                      int32_t max_buffers) {
  cam_t *cam;
  char id[16];
  int32_t id_len;
  int32_t i;
  int32_t slot = -1;
  int32_t st = ST_OK;

  id_len = Moonbit_array_length(camera_id);
  if (id_len > 15) {
    id_len = 15;
  }
  for (i = 0; i < id_len; i++) {
    id[i] = (char)camera_id[i];
  }
  id[id_len] = '\0';

  lock();
  if (g_unattached) {
    st = ST_NOT_ATTACHED;
    goto done;
  }
  if (g_open_status != ST_OK) {
    st = g_open_status;
    goto done;
  }
  if (g_vm == NULL) {
    st = ST_FAILED;
    goto done;
  }
  if (width <= 0 || height <= 0 || max_buffers < 1) {
    st = ST_INVALID_ARG;
    goto done;
  }
  for (i = 0; i < MAX_DEVICES; i++) {
    if (strcmp(g_devices[i].id, id) == 0) {
      break;
    }
  }
  if (i == MAX_DEVICES) {
    st = ST_NOT_FOUND;
    goto done;
  }
  if (!g_devices[i].supports_yuv) {
    st = ST_UNSUPPORTED_FORMAT;
    goto done;
  }
  {
    int32_t s;
    int32_t ok = 0;
    for (s = 0; s < g_devices[i].size_count; s++) {
      if (g_devices[i].sizes[s][0] == width &&
          g_devices[i].sizes[s][1] == height) {
        ok = 1;
        break;
      }
    }
    if (!ok) {
      st = ST_UNSUPPORTED_SIZE;
      goto done;
    }
  }
  {
    int32_t c;
    for (c = 0; c < MAX_SESSIONS; c++) {
      if (g_cams[c] != NULL && strcmp(g_cams[c]->id, id) == 0) {
        st = ST_ALREADY_OPEN;
        goto done;
      }
    }
  }
  for (i = 0; i < MAX_SESSIONS; i++) {
    if (g_cams[i] == NULL) {
      slot = i;
      break;
    }
  }
  if (slot < 0) {
    st = ST_FAILED;
    goto done;
  }
  cam = (cam_t *)libc_malloc(sizeof(cam_t));
  memset(cam, 0, sizeof(cam_t));
  cam->magic = MAGIC_CAM;
  memcpy(cam->id, id, strlen(id) + 1);
  cam->width = width;
  cam->height = height;
  cam->max_buffers = max_buffers;
  g_cams[slot] = cam;
  g_live_cams++;
  set_status(ST_OK);
  unlock();
  return cam;

done:
  set_status(st);
  unlock();
  return NULL;
}

void *mb_camera2_create_reader(void *camera, int32_t width, int32_t height,
                               int32_t max_buffers) {
  reader_t *r;
  cam_t *cam;
  int32_t i;
  int32_t st = ST_OK;

  lock();
  cam = lookup_cam(camera);
  if (g_unattached) {
    st = ST_NOT_ATTACHED;
    goto done;
  }
  if (g_reader_status != ST_OK) {
    st = g_reader_status;
    goto done;
  }
  if (cam == NULL) {
    st = ST_INVALID_ARG;
    goto done;
  }
  if (width != cam->width || height != cam->height) {
    st = ST_UNSUPPORTED_SIZE;
    goto done;
  }
  for (i = 0; i < MAX_SESSIONS; i++) {
    if (g_readers[i] == NULL) {
      break;
    }
  }
  if (i == MAX_SESSIONS) {
    st = ST_FAILED;
    goto done;
  }
  r = (reader_t *)libc_malloc(sizeof(reader_t));
  memset(r, 0, sizeof(reader_t));
  r->magic = MAGIC_RD;
  r->cam = cam;
  r->width = width;
  r->height = height;
  r->max_buffers = max_buffers;
  r->budget = -1;
  g_readers[i] = r;
  g_live_readers++;
  set_status(ST_OK);
  unlock();
  return r;

done:
  set_status(st);
  unlock();
  return NULL;
}

int32_t mb_camera2_start_preview(void *camera, void *reader) {
  int32_t st = ST_OK;
  reader_t *r;

  lock();
  r = lookup_reader(reader);
  if (g_unattached) {
    st = ST_NOT_ATTACHED;
    goto done;
  }
  if (!lookup_cam(camera) || r == NULL) {
    st = ST_FAILED;
    goto done;
  }
  if (g_preview_status != ST_OK) {
    st = g_preview_status;
    goto done;
  }
  if (!r->previewing) {
    r->previewing = 1;
    if (g_threaded) {
      start_thread_locked(r);
    }
  }
  /* 重复调用幂等：不重复建会话/线程 */
  set_status(ST_OK);
  unlock();
  return ST_OK;

done:
  set_status(st);
  unlock();
  return st;
}

int32_t mb_camera2_acquire_frame(void *reader, uint8_t *dst, int32_t capacity,
                                 int32_t timeout_ms) {
  reader_t *r;
  int32_t needed;
  int32_t waited = 0;
  int32_t k;

  lock();
  r = lookup_reader(reader);
  if (g_unattached) {
    set_status(ST_NOT_ATTACHED);
    unlock();
    return ST_NOT_ATTACHED;
  }
  if (r == NULL) {
    set_status(ST_FAILED);
    unlock();
    return ST_FAILED;
  }
  if (g_acquire_status != ST_OK) {
    set_status(g_acquire_status);
    unlock();
    return g_acquire_status;
  }
  needed = frame_needed(r);
  if (capacity < needed) {
    /* 不消费帧；正数 = 所需容量 */
    set_status(ST_OK);
    unlock();
    return needed;
  }
  if (r->in_flight >= r->max_buffers) {
    set_status(ST_POOL_EXHAUSTED);
    unlock();
    return ST_POOL_EXHAUSTED;
  }
  if (!g_threaded && r->previewing && r->pending_len == 0) {
    /* 同步模式：按需产帧（不派发回调，保证确定性） */
    produce_locked(r, 0);
  }
  while (r->pending_len == 0 && waited < timeout_ms) {
    unlock();
    sleep_ms(1);
    lock();
    r = lookup_reader(reader);
    if (r == NULL) {
      set_status(ST_FAILED);
      unlock();
      return ST_FAILED;
    }
    waited++;
    if (!g_threaded && r->previewing && r->pending_len == 0) {
      produce_locked(r, 0);
    }
  }
  if (r->pending_len == 0) {
    set_status(ST_TIMEOUT);
    unlock();
    return ST_TIMEOUT;
  }
  k = dequeue_locked(r);
  r->in_flight++;
  fill_frame(dst, r, k);
  set_status(ST_OK);
  unlock();
  return ST_OK;
}

void mb_camera2_release_frame(void *reader) {
  reader_t *r;
  lock();
  r = lookup_reader(reader);
  if (r != NULL && r->in_flight > 0) {
    r->in_flight--;
  }
  unlock();
}

int32_t mb_camera2_set_frame_callback(void *reader, void (*cb)(void *),
                                      void *closure) {
  reader_t *r;
  int32_t st = ST_OK;
  void *old = NULL;

  lock();
  r = lookup_reader(reader);
  if (g_unattached) {
    st = ST_NOT_ATTACHED;
    goto done;
  }
  if (r == NULL) {
    st = ST_FAILED;
    goto done;
  }
  if (cb == NULL || closure == NULL) {
    st = ST_INVALID_ARG;
    goto done;
  }
  if (r->closure != NULL) {
    /* 重复 set：替换并释放旧的 #owned 闭包 */
    old = r->closure;
    g_live_closures--;
  }
  r->cb = cb;
  r->closure = closure;
  g_live_closures++;
  set_status(ST_OK);
  unlock();
  if (old != NULL) {
    moonbit_decref(old);
  }
  return ST_OK;

done:
  set_status(st);
  unlock();
  return st;
}

void mb_camera2_clear_frame_callback(void *reader) {
  reader_t *r;
  void *old = NULL;

  lock();
  r = lookup_reader(reader);
  if (r != NULL && r->closure != NULL) {
    old = r->closure;
    r->cb = NULL;
    r->closure = NULL;
    r->callback_calls = 0;
    g_live_closures--;
  }
  unlock();
  if (old != NULL) {
    moonbit_decref(old);
  }
}

void mb_camera2_close(void *camera, void *reader) {
  reader_t *r;
  cam_t *cam;
  void *old = NULL;
  int32_t i;

  lock();
  r = lookup_reader(reader);
  cam = lookup_cam(camera);
  if (r != NULL) {
    r->stop_thread = 1;
    if (r->closure != NULL) {
      old = r->closure;
      r->cb = NULL;
      r->closure = NULL;
      g_live_closures--;
    }
  }
  unlock();

  /* 线程退出后再释放（join 不能持锁） */
  if (r != NULL) {
    join_thread(r);
  }

  lock();
  if (r != NULL) {
    for (i = 0; i < MAX_SESSIONS; i++) {
      if (g_readers[i] == r) {
        g_readers[i] = NULL;
      }
    }
    g_live_readers--;
    r->magic = 0;
    libc_free(r);
  }
  if (cam != NULL) {
    for (i = 0; i < MAX_SESSIONS; i++) {
      if (g_cams[i] == cam) {
        g_cams[i] = NULL;
      }
    }
    g_live_cams--;
    cam->magic = 0;
    libc_free(cam);
  }
  unlock();

  if (old != NULL) {
    moonbit_decref(old);
  }
}

/* ================= 内部扩展（非 pub，测试/映射用） ================= */

int32_t mb_camera2_last_status(void) { return g_last_status; }

uint64_t mb_camera2_current_thread_id(void) {
#ifdef _WIN32
  return (uint64_t)GetCurrentThreadId();
#else
  return (uint64_t)(uintptr_t)pthread_self();
#endif
}

int32_t mb_camera2_session_alive(void *camera, void *reader) {
  int32_t ok;
  lock();
  ok = cam_registered(camera) && reader_registered(reader);
  unlock();
  return ok ? 1 : 0;
}

/* 打包枚举（小端）：
 * i32 count; per camera: i32 id_len, id bytes, i32 facing,
 * i32 supports_yuv, i32 size_count, size_count * {i32 w, i32 h} */
int32_t mb_camera2_enumerate_raw(void *vm, uint8_t *dst, int32_t capacity) {
  int32_t needed = 4;
  int32_t off;
  int32_t i;
  int32_t s;
  int32_t st = ST_OK;

  lock();
  if (g_unattached) {
    st = ST_NOT_ATTACHED;
    goto done;
  }
  if (vm == NULL || g_vm != vm) {
    st = ST_INVALID_ARG;
    goto done;
  }
  for (i = 0; i < MAX_DEVICES; i++) {
    needed += 16 + (int32_t)strlen(g_devices[i].id) +
              g_devices[i].size_count * 8;
  }
  if (capacity < needed) {
    st = ST_CAPACITY;
    goto done;
  }
  off = 0;
  w32(dst, off, MAX_DEVICES);
  off += 4;
  for (i = 0; i < MAX_DEVICES; i++) {
    int32_t id_len = (int32_t)strlen(g_devices[i].id);
    w32(dst, off, id_len);
    off += 4;
    memcpy(dst + off, g_devices[i].id, (size_t)id_len);
    off += id_len;
    w32(dst, off, g_devices[i].facing);
    off += 4;
    w32(dst, off, g_devices[i].supports_yuv);
    off += 4;
    w32(dst, off, g_devices[i].size_count);
    off += 4;
    for (s = 0; s < g_devices[i].size_count; s++) {
      w32(dst, off, g_devices[i].sizes[s][0]);
      off += 4;
      w32(dst, off, g_devices[i].sizes[s][1]);
      off += 4;
    }
  }
  set_status(ST_OK);
  unlock();
  return off;

done:
  set_status(st);
  unlock();
  return st;
}

/* ================= 桌面 stub 测试替身控制 ================= */

void mb_camera2_stub_reset(void) {
  int32_t i;
  lock();
  for (i = 0; i < MAX_SESSIONS; i++) {
    if (g_readers[i] != NULL) {
      /* 测试应先 close；这里兜底释放未线程化的泄漏会话 */
      if (!g_readers[i]->thread_started) {
        if (g_readers[i]->closure != NULL) {
          moonbit_decref(g_readers[i]->closure);
          g_live_closures--;
        }
        libc_free(g_readers[i]);
      }
      g_readers[i] = NULL;
    }
    if (g_cams[i] != NULL) {
      libc_free(g_cams[i]);
      g_cams[i] = NULL;
    }
  }
  g_live_cams = 0;
  g_live_readers = 0;
  g_live_closures = 0;
  g_vm = NULL;
  g_open_status = ST_OK;
  g_reader_status = ST_OK;
  g_preview_status = ST_OK;
  g_acquire_status = ST_OK;
  g_unattached = 0;
  g_threaded = 0;
  g_frame_interval_ms = 10;
  set_status(ST_OK);
  unlock();
}

void *mb_camera2_stub_fake_vm(void) { return (void *)&g_fake_vm_marker; }

void mb_camera2_stub_set_open_status(int32_t st) {
  lock();
  g_open_status = st;
  unlock();
}

void mb_camera2_stub_set_reader_status(int32_t st) {
  lock();
  g_reader_status = st;
  unlock();
}

void mb_camera2_stub_set_preview_status(int32_t st) {
  lock();
  g_preview_status = st;
  unlock();
}

void mb_camera2_stub_set_acquire_status(int32_t st) {
  lock();
  g_acquire_status = st;
  unlock();
}

void mb_camera2_stub_set_unattached(int32_t flag) {
  lock();
  g_unattached = flag;
  unlock();
}

void mb_camera2_stub_set_threaded(int32_t flag) {
  lock();
  g_threaded = flag;
  unlock();
}

void mb_camera2_stub_set_frame_count(int32_t n) {
  int32_t i;
  lock();
  for (i = 0; i < MAX_SESSIONS; i++) {
    if (g_readers[i] != NULL) {
      g_readers[i]->budget = (n < 0) ? -1 : n;
    }
  }
  unlock();
}

void mb_camera2_stub_set_frame_interval_ms(int32_t ms) {
  lock();
  g_frame_interval_ms = (ms < 0) ? 0 : ms;
  unlock();
}

int32_t mb_camera2_stub_produce(void *reader) {
  reader_t *r;
  int32_t st;
  lock();
  r = lookup_reader(reader);
  if (r == NULL) {
    st = ST_FAILED;
  } else {
    st = produce_locked(r, 1);
  }
  set_status(st);
  unlock();
  return st;
}

int32_t mb_camera2_stub_callback_calls(void *reader) {
  reader_t *r;
  int32_t n;
  lock();
  r = lookup_reader(reader);
  n = (r != NULL) ? r->callback_calls : -1;
  unlock();
  return n;
}

int32_t mb_camera2_stub_live_closures(void) {
  int32_t n;
  lock();
  n = g_live_closures;
  unlock();
  return n;
}

int32_t mb_camera2_stub_live_cameras(void) {
  int32_t n;
  lock();
  n = g_live_cams;
  unlock();
  return n;
}

int32_t mb_camera2_stub_live_readers(void) {
  int32_t n;
  lock();
  n = g_live_readers;
  unlock();
  return n;
}

int32_t mb_camera2_stub_inflight(void *reader) {
  reader_t *r;
  int32_t n;
  lock();
  r = lookup_reader(reader);
  n = (r != NULL) ? r->in_flight : -1;
  unlock();
  return n;
}

int32_t mb_camera2_stub_pending(void *reader) {
  reader_t *r;
  int32_t n;
  lock();
  r = lookup_reader(reader);
  n = (r != NULL) ? r->pending_len : -1;
  unlock();
  return n;
}

void mb_camera2_stub_sleep(int32_t ms) { sleep_ms(ms); }

void mb_camera2_stub_quiesce(void) {
  for (;;) {
    int32_t busy;
    lock();
    busy = g_dispatching;
    unlock();
    if (!busy) {
      return;
    }
    sleep_ms(1);
  }
}
