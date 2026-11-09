///|
/// 内部 shim 与解析辅助（非 pub；公开 API 见 `camera2.mbt`）。
///
/// 状态码约定（与 `stub/camera2_stub.c` 一致，C 侧返回 / `mb_camera2_last_status`）：
/// 0 ok、-1 failed、-2 permission、-3 not found、-4 unsupported size、
/// -5 unsupported format、-6 acquire failed、-7 pool exhausted、
/// -8 JNI thread not attached、-9 vendor quirk、-10 preview failed、
/// -11 timeout、-12 capacity、-13 invalid arg、-14 already open、
/// -15 reentrant pump（marshal 层重入）。
/// `mb_camera2_acquire_frame` / `mb_camera2_marshal_next` 另约定：
/// 正数返回值 = 所需缓冲容量（不消费帧）。

///|
/// 最近一次 C shim 调用的线程局部状态码（句柄类 shim 失败时判别错误类别）。
extern "C" fn mb_camera2_last_status() -> Int32 = "mb_camera2_last_status"

///|
/// 当前线程 id；用于 `Camera.owner_thread_id` 归属校验（线程约束见
/// docs/DECISIONS.md「JNI 线程亲和性与回调所有权」）。
extern "C" fn mb_camera2_current_thread_id() -> UInt64 = "mb_camera2_current_thread_id"

///|
/// 会话存活探测：camera + reader 均已注册返回 1，否则 0（状态机判定依据）。
extern "C" fn mb_camera2_session_alive(
  camera : CameraHandleRaw,
  reader : ImageReaderRaw,
) -> Int32 = "mb_camera2_session_alive"

///|
/// 打包枚举（小端）：i32 count；每台：i32 id_len、id 字节、i32 facing、
/// i32 supports_yuv、i32 size_count、size_count × {i32 w, i32 h}。
/// 返回写入字节数；负数为状态码（-12 = 容量不足）。
#borrow(dst)
extern "C" fn mb_camera2_enumerate_raw(
  vm : JavaVMPtr,
  dst : FixedArray[Byte],
  capacity : Int32,
) -> Int32 = "mb_camera2_enumerate_raw"

///|
/// 小端读取 4 字节为无符号 32 位位型。
fn read_u32_le(buf : FixedArray[Byte], off : Int32) -> UInt64 {
  let b0 = buf[off].to_uint64()
  let b1 = buf[off + 1].to_uint64() << 8
  let b2 = buf[off + 2].to_uint64() << 16
  let b3 = buf[off + 3].to_uint64() << 24
  b0 | b1 | b2 | b3
}

///|
/// 小端读取 4 字节为 Int（截断 32 位位型）。
fn read_i32_le(buf : FixedArray[Byte], off : Int32) -> Int32 {
  read_u32_le(buf, off).to_int()
}

///|
/// 小端读取 8 字节为 UInt64。
fn read_u64_le(buf : FixedArray[Byte], off : Int32) -> UInt64 {
  let lo = read_u32_le(buf, off)
  let hi = read_u32_le(buf, off + 4) << 32
  lo | hi
}

///|
/// C status → CameraError 映射（无歧义部分）。
/// 调用点相关的构造（OpenFailed/PreviewFailed/BufferAcquireFailed/
/// BufferPoolExhausted）由各 open_error/preview_error/acquire_error 补齐。
fn map_unambiguous(
  status : Int32,
  ctx : String,
  width : Int32,
  height : Int32,
) -> CameraError? {
  if status == -2 {
    Some(CameraError::PermissionDenied(ctx))
  } else if status == -3 {
    Some(CameraError::CameraNotFound(ctx))
  } else if status == -4 {
    Some(CameraError::UnsupportedSize(width, height))
  } else if status == -5 {
    Some(CameraError::UnsupportedFormat(ctx))
  } else if status == -8 {
    Some(CameraError::JniThreadNotAttached(ctx))
  } else if status == -9 {
    Some(CameraError::VendorQuirk(ctx))
  } else if status == -14 {
    Some(CameraError::AlreadyOpen)
  } else {
    None
  }
}

///|
/// open / set_callback / enumerate 站点的兜底映射。
fn open_error(
  status : Int32,
  ctx : String,
  width : Int32,
  height : Int32,
) -> CameraError {
  match map_unambiguous(status, ctx, width, height) {
    Some(e) => e
    None => CameraError::OpenFailed(status, ctx)
  }
}

///|
/// start_preview 站点的兜底映射。
fn preview_error(
  status : Int32,
  ctx : String,
  width : Int32,
  height : Int32,
) -> CameraError {
  match map_unambiguous(status, ctx, width, height) {
    Some(e) => e
    None => CameraError::PreviewFailed(status, ctx)
  }
}

///|
/// acquire 站点映射：超时 → BufferAcquireFailed(timeout_ms)，
/// 缓冲池耗尽 → BufferPoolExhausted(max_inflight_buffers)，其余 → BufferAcquireFailed(status)。
fn acquire_error(
  status : Int32,
  timeout_ms : Int32,
  max_inflight_buffers : Int32,
  ctx : String,
  width : Int32,
  height : Int32,
) -> CameraError {
  match map_unambiguous(status, ctx, width, height) {
    Some(e) => e
    None =>
      if status == -11 {
        CameraError::BufferAcquireFailed(timeout_ms)
      } else if status == -7 {
        CameraError::BufferPoolExhausted(max_inflight_buffers)
      } else if status == -6 {
        CameraError::BufferAcquireFailed(-6)
      } else {
        CameraError::BufferAcquireFailed(status)
      }
  }
}

///|
/// pump_marshal 站点映射：-15 重入 → `MarshalReentrant`，
/// 其余沿用无歧义映射，兜底 `OpenFailed(status, ctx)`。
fn pump_error(status : Int32, ctx : String) -> CameraError {
  if status == -15 {
    CameraError::MarshalReentrant(ctx)
  } else {
    match map_unambiguous(status, ctx, 0, 0) {
      Some(e) => e
      None => CameraError::OpenFailed(status, ctx)
    }
  }
}

///|
/// 状态机守卫：会话未存活（未 open / 已 close）一律拒绝操作。
fn ensure_session(
  camera : CameraHandleRaw,
  reader : ImageReaderRaw,
) -> Unit raise CameraError {
  if mb_camera2_session_alive(camera, reader) != 1 {
    raise CameraError::AlreadyClosed
  }
}

///|
/// 线程归属守卫（JNI 线程约束，见 docs/DECISIONS.md）：非 owner 线程视为 JNI 会话未附着。
fn ensure_owner(owner_thread_id : UInt64) -> Unit raise CameraError {
  if mb_camera2_current_thread_id() != owner_thread_id {
    raise CameraError::JniThreadNotAttached(
      "current thread is not the camera session owner thread",
    )
  }
}

///|
/// 解析「3 段 plane + stride 头」打包帧并做完整性校验（YUV_420_888）：
/// 三平面、正维度（上限 16384 防溢出）、offset/length 不越界、
/// row_stride/pixel_stride 能覆盖对应平面的全部样本。校验失败抛
/// `UnsupportedFormat`，绝不静默产出错误帧。
fn parse_yuv_frame(
  buf : FixedArray[Byte],
  written : Int32,
) -> YuvFrame raise CameraError {
  if written < 64 {
    raise CameraError::UnsupportedFormat(
      "malformed YUV frame: truncated header",
    )
  }
  let width = read_i32_le(buf, 0)
  let height = read_i32_le(buf, 4)
  let timestamp_ns = read_u64_le(buf, 8)
  if width <= 0 || height <= 0 || width > 16384 || height > 16384 {
    raise CameraError::UnsupportedFormat("malformed YUV frame: bad dimensions")
  }
  let planes : Array[YuvPlane] = []
  for p in 0..<3 {
    let base = 16 + p * 16
    let off = read_i32_le(buf, base)
    let len = read_i32_le(buf, base + 4)
    let rs = read_i32_le(buf, base + 8)
    let ps = read_i32_le(buf, base + 12)
    if off < 64 || len <= 0 || len > written || off > written - len {
      raise CameraError::UnsupportedFormat(
        "malformed YUV frame: plane out of bounds",
      )
    }
    if rs <= 0 || ps < 1 {
      raise CameraError::UnsupportedFormat(
        "malformed YUV frame: invalid stride",
      )
    }
    // YUV_420_888：plane0 为全分辨率，plane1/2 为半分辨率。
    let (pw, ph) = if p == 0 {
      (width, height)
    } else {
      ((width + 1) / 2, (height + 1) / 2)
    }
    let row_span = (pw - 1) * ps + 1
    let need = rs * (ph - 1) + row_span
    if rs < row_span || len < need {
      raise CameraError::UnsupportedFormat(
        "malformed YUV frame: stride too small",
      )
    }
    let data = Bytes::makei(len, i => buf[off + i])
    planes.push(YuvPlane::{ data, row_stride: rs, pixel_stride: ps, })
  }
  YuvFrame::{ width, height, planes, timestamp_ns, }
}

///|
/// 解析打包枚举为 `CameraInfo` 快照；边界/取值非法抛 `UnsupportedFormat`。
fn parse_camera_infos(
  buf : FixedArray[Byte],
  written : Int32,
) -> Array[CameraInfo] raise CameraError {
  if written < 4 {
    raise CameraError::UnsupportedFormat("malformed camera enumeration buffer")
  }
  let count = read_i32_le(buf, 0)
  if count < 0 || count > 64 {
    raise CameraError::UnsupportedFormat("malformed camera enumeration buffer")
  }
  let out : Array[CameraInfo] = []
  let mut cur = 4
  for _ in 0..<count {
    if cur + 4 > written {
      raise CameraError::UnsupportedFormat(
        "malformed camera enumeration buffer",
      )
    }
    let id_len = read_i32_le(buf, cur)
    cur = cur + 4
    if id_len < 0 || id_len > 255 || cur + id_len + 12 > written {
      raise CameraError::UnsupportedFormat(
        "malformed camera enumeration buffer",
      )
    }
    let id = @utf8.decode_lossy(
      Bytes::makei(id_len, i => buf[cur + i]).exact_view(),
    )
    cur = cur + id_len
    let facing_i = read_i32_le(buf, cur)
    let supports = read_i32_le(buf, cur + 4)
    let size_count = read_i32_le(buf, cur + 8)
    cur = cur + 12
    if size_count < 0 || size_count > 64 || cur + size_count * 8 > written {
      raise CameraError::UnsupportedFormat(
        "malformed camera enumeration buffer",
      )
    }
    let facing = if facing_i == 0 {
      Facing::Front
    } else if facing_i == 1 {
      Facing::Back
    } else if facing_i == 2 {
      Facing::External
    } else {
      raise CameraError::UnsupportedFormat(
        "malformed camera enumeration buffer",
      )
    }
    let sizes : Array[FrameSize] = []
    for _ in 0..<size_count {
      let w = read_i32_le(buf, cur)
      let h = read_i32_le(buf, cur + 4)
      cur = cur + 8
      if w <= 0 || h <= 0 {
        raise CameraError::UnsupportedFormat(
          "malformed camera enumeration buffer",
        )
      }
      sizes.push(FrameSize::{ width: w, height: h, })
    }
    out.push(CameraInfo::{
      id,
      facing,
      supported_sizes: sizes,
      supports_yuv420888: supports != 0,
    })
  }
  out
}

///|
/// 同步取一帧纯值：两段式 acquire（先探容量、按正数返回值扩容），
/// 解析后**无条件 release** 归还缓冲（每帧 acquire→release 语义）。
/// 解析失败经 `errdefer` 归还后抛出。不做状态/线程守卫（回调 thunk 在投递线程复用）。
fn Camera::acquire_frame_value(
  self : Camera,
  timeout_ms : Int32,
) -> YuvFrame raise CameraError {
  let width = self.config.size.width
  let height = self.config.size.height
  let pool = self.config.max_inflight_buffers
  let probe = FixedArray::make(64, b'\x00')
  let first = mb_camera2_acquire_frame(self.reader, probe, 64, timeout_ms)
  let buf = if first > 0 {
    FixedArray::make(first, b'\x00')
  } else if first == 0 {
    probe
  } else {
    raise acquire_error(
      first, timeout_ms, pool, "Camera::grab_yuv", width, height,
    )
  }
  let written = if first > 0 {
    let second = mb_camera2_acquire_frame(self.reader, buf, first, timeout_ms)
    if second != 0 {
      raise acquire_error(
        second, timeout_ms, pool, "Camera::grab_yuv", width, height,
      )
    }
    first
  } else {
    64
  }
  errdefer mb_camera2_release_frame(self.reader)
  let frame = parse_yuv_frame(buf, written)
  mb_camera2_release_frame(self.reader)
  frame
}

///|
/// 从 marshal 暂存槽拉取一帧纯值（两段式：先探容量、再按需取走并解析）。
/// 仅在 `pump_marshal` 派发期间有效（thunk 内调用）；无暂存事件、
/// 误用（非派发期间）或解析失败一律返回 `None`，**绝不 panic**——
/// 解析失败的事件已被消费，不会卡住队列。
fn take_marshal_frame(reader : ImageReaderRaw) -> YuvFrame? {
  try {
    let probe = FixedArray::make(64, b'\x00')
    let first = mb_camera2_marshal_next(reader, probe, 64)
    if first <= 0 {
      None
    } else {
      let buf = FixedArray::make(first, b'\x00')
      let second = mb_camera2_marshal_next(reader, buf, first)
      if second != 0 {
        None
      } else {
        Some(parse_yuv_frame(buf, first))
      }
    }
  } catch {
    _ => None
  }
}
