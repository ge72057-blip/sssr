#!/usr/bin/env bash
# 在 GitHub 的 Windows 机器上（MSYS2 / MINGW64 环境）运行。
# 产出两套：
#   out/win-x64/full/bin/ffmpeg.exe、ffprobe.exe   完整版单文件（含 x264、x265，GPL，静态链接，不依赖别的 dll）
#   out/win-x64/lgpl/bin/   LGPL 版（给软件用的就是这一套，不含 x264、x265）：
#                           av*.dll、sw*.dll + 依赖 dll（播放/预览在软件里直接调用）
#                           + ffmpeg.exe、ffprobe.exe（转换/压缩当独立程序运行，动态链接同一批 dll，体积只算一份）
set -u -o pipefail

FFVER="${FFMPEG_VERSION:-8.1.3}"
ROOT="$PWD/build/win-x64"
OUT="$PWD/out/win-x64"
J="$(nproc)"
mkdir -p "$ROOT" "$OUT/full/bin" "$OUT/lgpl/bin" "$OUT/logs"
REPORT="$OUT/dep-report.txt"
: > "$REPORT"

# shellcheck source=verify.sh
source "$(dirname "$0")/verify.sh"
# shellcheck source=netutil.sh
source "$(dirname "$0")/netutil.sh"

clone --depth 1 --branch "n$FFVER" https://github.com/FFmpeg/FFmpeg.git "$ROOT/ffmpeg" \
  || { echo "下载 FFmpeg n$FFVER 失败（版本号对不对？）"; exit 1; }

# ---- MSYS2 仓库里没有的三个库（vmaf、rist、chromaprint），从源码编，装进 /mingw64 ----
WSRC="$ROOT/wsrc"; mkdir -p "$WSRC"
wfetch() { # 网址 目录名 [备用网址...]（多轮重试 + 备用入口，见 netutil.sh）
  local url="$1" name="$2"; shift 2
  # shellcheck disable=SC2046
  dl_extract "$WSRC" "$name" $(gh_urls "$url") "$@"
}
wtry() { # 名字 函数：失败只记录，不中断
  local n="$1"; shift
  ( set -e; "$@" ) > "$OUT/logs/dep-$n.log" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then echo "OK    ${n}（源码编译）" | tee -a "$REPORT"
  else echo "FAIL  ${n}（日志 logs/dep-${n}.log）" | tee -a "$REPORT"; tail -n 20 "$OUT/logs/dep-$n.log"; fi
}
wdep_vmaf() {
  wfetch "https://github.com/Netflix/vmaf/archive/refs/tags/v3.0.0.tar.gz" vmaf
  cd "$WSRC/vmaf/libvmaf"
  meson setup _b --prefix=/mingw64 --libdir=lib --buildtype=release --default-library=static \
    -Denable_tests=false -Denable_docs=false -Dbuilt_in_models=true -Denable_float=true
  ninja -C _b install
}
wdep_librist() {
  wfetch "https://code.videolan.org/rist/librist/-/archive/v0.2.10/librist-v0.2.10.tar.gz" librist
  cd "$WSRC/librist"
  # mingw 的 winpthreads 已经提供了 clock_gettime，librist 自带的垫片又定义了一遍，冲突。把垫片里那个改成不对外的
  sed -i 's/^int clock_gettime(clockid_t clock_id, struct timespec \*tp)/static int rist_shim_clock_gettime(clockid_t clock_id, struct timespec *tp)/' contrib/time-shim.c
  meson setup _b --prefix=/mingw64 --libdir=lib --buildtype=release --default-library=static -Dbuilt_tools=false -Dtest=false
  ninja -C _b install
}
wdep_chromaprint() {
  wfetch "https://github.com/acoustid/chromaprint/releases/download/v1.5.1/chromaprint-1.5.1.tar.gz" chromaprint \
    "https://github.com/acoustid/chromaprint/archive/refs/tags/v1.5.1.tar.gz"
  wfetch "https://github.com/mborgerding/kissfft/archive/refs/heads/master.tar.gz" kissfft
  mkdir -p "$WSRC/kissfft/tools"; cp "$WSRC/kissfft/kiss_fftr.c" "$WSRC/kissfft/kiss_fftr.h" "$WSRC/kissfft/tools/"
  cd "$WSRC/chromaprint"
  cmake -S . -B _b -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/mingw64 -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TOOLS=OFF -DBUILD_TESTS=OFF -DFFT_LIB=kissfft -DKISSFFT_SOURCE_DIR="$WSRC/kissfft" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  cmake --build _b && cmake --install _b
}
wtry vmaf wdep_vmaf
wtry librist wdep_librist
wtry chromaprint wdep_chromaprint

# 两套都能用的库：清单和安卓共用 scripts/libflags.sh，保证功能一致
LIBDIR=/mingw64/lib; USE_MBEDTLS=0
# shellcheck source=libflags.sh
source "$(dirname "$0")/libflags.sh"

# Windows 专有的硬件加速（对界面来说和安卓的 MediaCodec 是同一个"硬件"开关）
HW=(--enable-d3d11va --enable-dxva2 --enable-mediafoundation --enable-schannel)
have ffnvcodec && HW+=(--enable-cuda --enable-cuvid --enable-nvenc --enable-nvdec --enable-ffnvcodec)
have vpl && HW+=(--enable-libvpl)
[ -f /mingw64/include/AMF/core/Factory.h ] && HW+=(--enable-amf)

COMMON=(--arch=x86_64 --target-os=mingw32 --extra-cflags=-DCHROMAPRINT_NODLL --extra-libs=-lstdc++ --disable-autodetect --disable-doc --disable-debug --disable-avdevice
        --enable-zlib --enable-bzlib --enable-lzma --enable-iconv --pkg-config-flags=--static)

ff_conf() { # 名字 额外参数...
  local name="$1"; shift
  rm -rf "$ROOT/ffb-$name"; mkdir -p "$ROOT/ffb-$name"; cd "$ROOT/ffb-$name" || return 1
  "$ROOT/ffmpeg/configure" --prefix="$ROOT/ffi-$name" "${COMMON[@]}" "${LIBFLAGS[@]}" "${HW[@]}" "$@" 2>&1 \
    | tee "$OUT/logs/configure-$name.txt"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || cp ffbuild/config.log "$OUT/logs/config-$name.log" 2>/dev/null
  return "$rc"
}

ff_build() { # 名字：编译并安装，日志存到 logs/make-名字.log，失败时在屏幕上显示最后 40 行
  local name="$1"
  ( make -C "$ROOT/ffb-$name" -j"$J" && make -C "$ROOT/ffb-$name" install ) > "$OUT/logs/make-$name.log" 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] || tail -n 40 "$OUT/logs/make-$name.log"
  return "$rc"
}

# ---- 完整版：优先做成单个 exe（全部静态链接）；静态链接配不通就改成"exe + 它依赖的 dll" ----
FULL_COMMON=(--enable-gpl --disable-shared --enable-static)
have x264 && FULL_COMMON+=(--enable-libx264)
have x265 && FULL_COMMON+=(--enable-libx265)
full_done=0
if ff_conf full "${FULL_COMMON[@]}" --extra-ldflags=-static --extra-libs="-lstdc++ -liconv -lm" && ff_build full; then
  full_done=1
  echo "OK    ffmpeg完整版（exe，静态单文件）" | tee -a "$REPORT"
else
  echo "静态单文件配置/编译失败，改用动态依赖（exe + dll）重试" | tee -a "$REPORT"
  if ff_conf full "${FULL_COMMON[@]}" --extra-libs="-liconv" && ff_build full; then
    full_done=1
    echo "OK    ffmpeg完整版（exe + 依赖 dll）" | tee -a "$REPORT"
  else
    echo "FAIL  ffmpeg完整版（exe）" | tee -a "$REPORT"
  fi
fi
if [ "$full_done" = 1 ]; then
  cp "$ROOT/ffi-full/bin/ffmpeg.exe" "$ROOT/ffi-full/bin/ffprobe.exe" "$OUT/full/bin/"
  for e in "$OUT"/full/bin/*.exe; do
    ldd "$e" | awk '/\/mingw64\/bin\//{print $3}'
  done | sort -u | while read -r f; do cp -n "$f" "$OUT/full/bin/"; done
  strip --strip-unneeded "$OUT"/full/bin/*.exe 2>/dev/null || true
fi

# ---- LGPL 版（给软件用的）：动态库 + 命令行程序（共用同一批 dll，体积只算一份）+ 它们依赖的 dll ----
# 上一版把命令行程序另外静态编了一份，编解码器等于装两遍；现在 ffmpeg.exe / ffprobe.exe 只有很小，
# 运行时直接用同文件夹里的 dll。
if ff_conf lgpl --disable-gpl --disable-nonfree --enable-shared --disable-static --extra-libs=-liconv \
   && ff_build lgpl; then
  cp "$ROOT"/ffi-lgpl/bin/*.dll "$OUT/lgpl/bin/"
  cp "$ROOT/ffi-lgpl/bin/ffmpeg.exe" "$ROOT/ffi-lgpl/bin/ffprobe.exe" "$OUT/lgpl/bin/"
  for d in "$OUT"/lgpl/bin/av*.dll "$OUT"/lgpl/bin/sw*.dll "$OUT"/lgpl/bin/ff*.exe; do
    ldd "$d" | awk '/\/mingw64\/bin\//{print $3}'
  done | sort -u | while read -r f; do cp -n "$f" "$OUT/lgpl/bin/"; done
  strip --strip-unneeded "$OUT"/lgpl/bin/*.dll "$OUT"/lgpl/bin/*.exe 2>/dev/null || true
  # 授权保险：configure 报告的授权必须是 LGPL，不是的话说明混进了 GPL 的东西，不能发布
  if grep -q '^License: LGPL' "$OUT/logs/configure-lgpl.txt"; then
    echo "OK    ffmpeg LGPL 版（dll + 命令行程序）：$(grep -m1 '^License:' "$OUT/logs/configure-lgpl.txt")" | tee -a "$REPORT"
  else
    echo "FAIL  LGPL 版授权不是 LGPL（$(grep -m1 '^License:' "$OUT/logs/configure-lgpl.txt")），已删除产物" | tee -a "$REPORT"
    rm -f "$OUT"/lgpl/bin/*
  fi
else
  echo "FAIL  ffmpeg LGPL 版" | tee -a "$REPORT"
fi

# 真的运行一次，核对"移植过去的软件要用到的编码器/滤镜"都在，且没有 x264/x265（这台 Windows 机器能直接跑 exe）
CLI="$OUT/lgpl/bin/ffmpeg.exe"
if [ -f "$CLI" ]; then
  if "$CLI" -hide_banner -version > "$OUT/logs/lgpl-version.txt" 2>&1; then
    echo "OK    LGPL 版命令行能正常启动：$(head -1 "$OUT/logs/lgpl-version.txt")" | tee -a "$REPORT"
    ENC="$("$CLI" -hide_banner -encoders 2>&1)"
    FLT="$("$CLI" -hide_banner -filters 2>&1)"
    for e in "${REQ_ENCODERS[@]}" h264_nvenc hevc_nvenc h264_qsv h264_amf h264_mf; do
      if echo "$ENC" | grep -qw "$e"; then echo "OK    编码器 $e" | tee -a "$REPORT"; else echo "MISS  编码器 $e（这一项缺失）" | tee -a "$REPORT"; fi
    done
    for f in "${REQ_FILTERS[@]}"; do
      if echo "$FLT" | grep -qw "$f"; then echo "OK    滤镜 $f" | tee -a "$REPORT"; else echo "MISS  滤镜 $f（这一项缺失）" | tee -a "$REPORT"; fi
    done
    for x in libx264 libx265; do
      if echo "$ENC" | grep -qw "$x"; then echo "FAIL  LGPL 版里混进了 $x（GPL），不能发布" | tee -a "$REPORT"; fi
    done
  else
    echo "FAIL  LGPL 版命令行启动失败（日志 logs/lgpl-version.txt）" | tee -a "$REPORT"
  fi
fi

for n in full lgpl; do
  { echo; echo "--- $n 启用的外部库 ---"; sed -n '/^External libraries:/,/^$/p' "$OUT/logs/configure-$n.txt" 2>/dev/null; } >> "$REPORT"
done

# 头文件：给"在应用里直接调用库"用（生成/核对 FFmpeg.AutoGen 之类的绑定）
[ -d "$ROOT/ffi-lgpl/include" ] && cp -r "$ROOT/ffi-lgpl/include" "$OUT/lgpl/include"

# 必需功能检查：对照要移植的 Python 软件实际需要的编码器/封装/滤镜/硬件编解码（清单见 scripts/verify.sh）
{
  echo; echo "--- 必需功能检查（对照 Python 软件的需求） ---"
  verify_windows "LGPL 版" "$OUT/logs/configure-lgpl.txt"
} >> "$REPORT"

# 构建信息：以后需要"和发布的二进制完全对应的源码"时用得上
{
  echo "构建时间：$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "目标：win-x64"
  echo "FFmpeg：n$FFVER（提交 $(git -C "$ROOT/ffmpeg" rev-parse HEAD 2>/dev/null)）"
  echo "编译器：$(gcc --version 2>/dev/null | head -1)"
  echo "各套授权："
  grep -H -m1 '^License:' "$OUT"/logs/configure-*.txt 2>/dev/null
} > "$OUT/build-info.txt"

# 体积：给软件用的这一套各文件多大（未压缩）
{
  echo; echo "--- 体积（给软件用的 lgpl/bin 这一套，未压缩） ---"
  ls -l "$OUT/lgpl/bin" 2>/dev/null | awk 'NR>1{printf "%10.1f MB  %s\n", $5/1048576, $9}' | sort -rn | head -15
  du -sh "$OUT/lgpl/bin" 2>/dev/null | awk '{print "合计 " $1}'
} >> "$REPORT"

cat "$REPORT"
if [ "$VERIFY_FAILS" -ne 0 ]; then
  echo "必需功能检查有 $VERIFY_FAILS 项没通过（见上面 MISS / FAIL），产物已上传但先不要使用。"
  exit 1
fi
