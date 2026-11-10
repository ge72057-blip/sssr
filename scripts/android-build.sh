#!/usr/bin/env bash
# 用法：bash scripts/android-build.sh android-arm64     （或 android-x86_64）
#
# 做三件事：
#   1) 把所有外部库（x264、x265、字幕、AV1……）从源码交叉编译成 Android 版
#   2) 编"完整版"：ffmpeg / ffprobe 可执行文件（含 x264、x265，GPL，只做对照测试，不要随软件发布）
#   3) 编"LGPL 版"（给软件用的就是这一套，out/<目标>/lgpl/<ABI>/）：
#        6 个分开的 .so（libavcodec.so 这类）+ 命令行程序 ffmpeg / ffprobe + libc++_shared.so
#      命令行程序动态链接同一批 .so，所以编解码器的体积只算一份。
#      播放/预览用 .so（在软件里直接调用），转换/压缩用 ffmpeg / ffprobe（当独立程序运行）。
#
# 每个外部库单独编，某一个失败不会拖垮整体——ffmpeg 只会启用"编成功了"的库，
# 成功/失败清单写在 out/<目标>/dep-report.txt 里。
set -u -o pipefail

TARGET="${1:?缺少参数：android-arm64 或 android-x86_64}"
FFVER="${FFMPEG_VERSION:-8.1.3}"
API=24                                   # 和 ZUI.Android.csproj 的最低版本 24 保持一致
NDK="${ANDROID_NDK_HOME:?没有找到 ANDROID_NDK_HOME}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
J="$(nproc)"

case "$TARGET" in
  android-arm64)  TRIPLE=aarch64-linux-android; ABI=arm64-v8a; ARCH=aarch64; MFAMILY=aarch64; MCPU=armv8-a; VPXTARGET=arm64-linux-gcc ;;
  android-x86_64) TRIPLE=x86_64-linux-android;  ABI=x86_64;    ARCH=x86_64;  MFAMILY=x86_64;  MCPU=x86_64;  VPXTARGET=x86_64-linux-gcc ;;
  *) echo "不认识的目标：$TARGET"; exit 1 ;;
esac

PLATFORM=android
PLAT_CFLAGS=""
ROOT="$PWD/build/$TARGET"
SRC="$ROOT/src"
PREFIX="$ROOT/prefix"
OUT="$PWD/out/$TARGET"
mkdir -p "$SRC" "$PREFIX/lib/pkgconfig" "$OUT/full/bin" "$OUT/lgpl/$ABI" "$OUT/logs"
REPORT="$OUT/dep-report.txt"
: > "$REPORT"

export CC="$TOOLCHAIN/bin/${TRIPLE}${API}-clang"
export CXX="$TOOLCHAIN/bin/${TRIPLE}${API}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export NM="$TOOLCHAIN/bin/llvm-nm"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export LD="$CC"
# 先确认 NDK 的编译器真的能用（上次就是 NDK 缓存坏了，clang 不见了，导致后面全部失败）
"$CC" --version >/dev/null 2>&1 || { echo "NDK 编译器不可用：$CC"; ls -la "$TOOLCHAIN/bin" | head -40; exit 1; }
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="-O2 -fPIC"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH

CMAKE_BASE=(
  -G Ninja
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_FIND_ROOT_PATH="$PREFIX"
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

cat > "$ROOT/meson-cross.txt" <<MESON
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'
[host_machine]
system = 'android'
cpu_family = '$MFAMILY'
cpu = '$MCPU'
endian = 'little'
[built-in options]
c_args = ['-O2', '-fPIC', '-I$PREFIX/include']
cpp_args = ['-O2', '-fPIC', '-I$PREFIX/include']
c_link_args = ['-L$PREFIX/lib']
cpp_link_args = ['-L$PREFIX/lib']
[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$PREFIX/lib/pkgconfig'
MESON

# 安卓没有独立的 librt / libpthread（都在系统库里），有些库的构建会硬写 -lrt / -lpthread，放两个空库顶替
rm -f "$PREFIX/lib/librt.a" "$PREFIX/lib/libpthread.a"
"$AR" rc "$PREFIX/lib/librt.a" 2>/dev/null || true
"$AR" rc "$PREFIX/lib/libpthread.a" 2>/dev/null || true
X264_CFG=(--cross-prefix="$TOOLCHAIN/bin/llvm-")
merge_static() { # 输出 输入...：把几个 .a 合成一个
  local o="$1"; shift
  { echo "CREATE $o"; for f in "$@"; do echo "ADDLIB $f"; done; echo SAVE; echo END; } | "$AR" -M
}
# shellcheck source=deps.sh
source "$(dirname "$0")/deps.sh"
run_deps

# 必需的外部库（Python 软件要用到的编码/字幕）没编出来就立刻停下：多半是 GitHub 下载失败，重新运行一次即可。
# 不然会花一个多小时编出一个缺 VP9 之类的 ffmpeg，最后才发现。（whisper / chromaprint / openjpeg 等可选的不在此列）
_missing=""
for _d in libvpx dav1d opus ogg vorbis lame freetype fribidi harfbuzz libass webp aom openh264; do
  grep -q "^FAIL  $_d" "$REPORT" && _missing="$_missing $_d"
done
if [ -n "$_missing" ]; then
  echo "必需的外部库没编出来：$_missing（见 logs/dep-*.log，多半是下载失败）。现在停下，重新运行即可。" | tee -a "$REPORT"
  exit 1
fi

# 这些库的 .pc 里写着 -lstdc++，Android 上不用，去掉（C++ 运行库在最后链接时静态带上）
# 安卓没有单独的 libpthread/librt（都在系统库里），.pc 里写了会导致链接失败，一并去掉
sed -i 's/-lstdc++//g; s/-lpthread//g; s/-lrt//g; s/-l-l:libunwind.a//g' "$PREFIX"/lib/pkgconfig/*.pc 2>/dev/null || true

# ---------------- 决定 ffmpeg 启用哪些库（只启用编成功的；清单和 Windows 共用 scripts/libflags.sh） ----------------
LIBDIR="$PREFIX/lib"; USE_MBEDTLS=1
# shellcheck source=libflags.sh
source "$(dirname "$0")/libflags.sh"
# 必须在任何 cd 之前载入（脚本是用相对路径启动的，cd 之后就找不到了）
# shellcheck source=verify.sh
source "$(dirname "$0")/verify.sh"

# ---------------- ffmpeg 源码 ----------------
rm -rf "$SRC/ffmpeg"
clone --depth 1 --branch "n$FFVER" https://github.com/FFmpeg/FFmpeg.git "$SRC/ffmpeg" || { echo "下载 FFmpeg n$FFVER 失败（版本号对不对？）"; exit 1; }
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

ff_conf() { # 名字 额外参数...
  local name="$1"; shift
  rm -rf "$ROOT/ffb-$name"; mkdir -p "$ROOT/ffb-$name"; cd "$ROOT/ffb-$name" || return 1
  "$SRC/ffmpeg/configure" --prefix="$ROOT/ffi-$name" \
    --enable-cross-compile --target-os=android --arch="$ARCH" \
    --cc="$CC" --cxx="$CXX" --ld="$CXX" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" --strip="$STRIP" \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --enable-pic --disable-autodetect --disable-doc --disable-debug --disable-avdevice --disable-symver \
    --enable-zlib --enable-jni --enable-mediacodec --extra-libs=-llog \
    --extra-cflags="-I$PREFIX/include -fPIC" \
    --extra-ldflags="-L$PREFIX/lib -static-libstdc++ -Wl,-z,max-page-size=16384" \
    "${LIBFLAGS[@]}" "$@" 2>&1 | tee "$OUT/logs/configure-$name.txt"
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

# C++ 运行库：各个 .so 和命令行程序都要用 libc++_shared.so，必须随软件一起安装，
# 所以每个产物目录里都附上一份（NDK 里的原文件，名字不能改），不用再手动去 NDK 里找。
LIBCXX="$TOOLCHAIN/sysroot/usr/lib/$TRIPLE/libc++_shared.so"
[ -f "$LIBCXX" ] || echo "警告：没找到 $LIBCXX"

# 命令行程序在手机上是被应用"当成独立程序启动"的，这时系统按"程序自己的 RUNPATH → 系统目录"的顺序找 libc++_shared.so。
# 手机系统目录里有一份不兼容的 libc++_shared.so（缺 std::ifstream 等符号），不设置的话会先找到它，启动时报
# "cannot locate symbol"。把 RUNPATH 设成"程序所在目录"（$ORIGIN），让它优先用随软件一起安装的那份。
fix_runpath() { # 文件...
  local f
  for f in "$@"; do
    patchelf --set-rpath '$ORIGIN' "$f" || echo "警告：设置 RUNPATH 失败：$f"
  done
}

# ---------------- 第一套：完整版可执行文件（GPL，含 x264/x265） ----------------
FULL=(--enable-gpl --disable-shared --enable-static)
have x264 && FULL+=(--enable-libx264)
have x265 && FULL+=(--enable-libx265)
if ff_conf full "${FULL[@]}" && ff_build full; then
  cp "$ROOT/ffi-full/bin/ffmpeg" "$ROOT/ffi-full/bin/ffprobe" "$OUT/full/bin/"
  "$STRIP" --strip-unneeded "$OUT/full/bin/ffmpeg" "$OUT/full/bin/ffprobe"
  fix_runpath "$OUT/full/bin/ffmpeg" "$OUT/full/bin/ffprobe"
  [ -f "$LIBCXX" ] && cp "$LIBCXX" "$OUT/full/bin/"
  echo "OK    ffmpeg完整版（可执行文件）" | tee -a "$REPORT"
else
  echo "FAIL  ffmpeg完整版（可执行文件）" | tee -a "$REPORT"
fi

# ---------------- 第二套：LGPL 版（给软件用的）：分开的 .so + 命令行程序，共用同一批 .so ----------------
# 上一版把"库"和"命令行"各编了一份完整的静态拷贝，两份编解码器加起来 170MB，太浪费。
# 现在命令行程序动态链接这批 .so（程序本身只有一两兆），播放和转换用的是同一份编解码器。
# MediaCodec 硬件编解码启用：库里（在软件内）靠 Java 虚拟机用；命令行是独立进程没有 Java 虚拟机，
# 靠 FFmpeg 的 NDK 方式（-ndk_codec 1）用。命令行里的硬件编码能否在真机上正常工作需要实测。
if ff_conf lgpl --disable-gpl --disable-nonfree --enable-shared --disable-static; then
  # 把"带版本号的库名"改成"不带版本号"，Android 打包才认（命令行程序链接时记下的也是这个名字）
  sed -i.bak -e 's|^SLIBNAME_WITH_MAJOR=.*|SLIBNAME_WITH_MAJOR=$(SLIBNAME)|' \
             -e 's|^SLIB_INSTALL_NAME=.*|SLIB_INSTALL_NAME=$(SLIBNAME)|' \
             -e 's|^SLIB_INSTALL_LINKS=.*|SLIB_INSTALL_LINKS=|' "$ROOT/ffb-lgpl/ffbuild/config.mak"
  if ff_build lgpl \
     && ls "$ROOT/ffi-lgpl/lib/libavcodec.so" >/dev/null 2>&1 \
     && [ -x "$ROOT/ffi-lgpl/bin/ffmpeg" ] && [ -x "$ROOT/ffi-lgpl/bin/ffprobe" ]; then
    D="$OUT/lgpl/$ABI"
    cp "$ROOT"/ffi-lgpl/lib/lib{avutil,swresample,swscale,avcodec,avformat,avfilter}.so "$D/"
    cp "$ROOT/ffi-lgpl/bin/ffmpeg" "$ROOT/ffi-lgpl/bin/ffprobe" "$D/"
    "$STRIP" --strip-unneeded "$D"/*.so "$D/ffmpeg" "$D/ffprobe"
    [ -f "$LIBCXX" ] && cp "$LIBCXX" "$D/"
    # 每个文件都设成"先在自己所在目录找依赖"：命令行程序是独立进程启动的，
    # 它依赖的 libavcodec.so 又依赖 libavutil.so 这些，都得在同一个目录里找到
    fix_runpath "$D"/lib{avutil,swresample,swscale,avcodec,avformat,avfilter}.so "$D/ffmpeg" "$D/ffprobe"
    # 授权保险：configure 报告的授权必须是 LGPL，不是的话说明混进了 GPL 的东西，不能发布
    if grep -q '^License: LGPL' "$OUT/logs/configure-lgpl.txt"; then
      echo "OK    LGPL 版（分开的 .so + 命令行程序）：$(grep -m1 '^License:' "$OUT/logs/configure-lgpl.txt")" | tee -a "$REPORT"
    else
      echo "FAIL  LGPL 版授权不是 LGPL（$(grep -m1 '^License:' "$OUT/logs/configure-lgpl.txt")），已删除产物" | tee -a "$REPORT"
      rm -f "$D"/*
    fi
  else
    echo "FAIL  LGPL 版 编译/改名" | tee -a "$REPORT"
  fi
else
  echo "FAIL  LGPL 版 配置" | tee -a "$REPORT"
fi

# ---------------- 汇总：两套各启用了哪些外部库 ----------------
for n in full lgpl; do
  { echo; echo "--- $n 启用的外部库 ---"; sed -n '/^External libraries:/,/^$/p' "$OUT/logs/configure-$n.txt" 2>/dev/null; } >> "$REPORT"
done

# 头文件：给"在应用里直接调用库"用（生成/核对 FFmpeg.AutoGen 之类的绑定）
[ -d "$ROOT/ffi-lgpl/include" ] && cp -r "$ROOT/ffi-lgpl/include" "$OUT/lgpl/include"

# 必需功能检查：对照要移植的 Python 软件实际需要的编码器/封装/滤镜/硬件编解码（清单见 scripts/verify.sh）
{
  echo; echo "--- 必需功能检查（对照 Python 软件的需求） ---"
  verify_android "LGPL 版" "$OUT/logs/configure-lgpl.txt"
} >> "$REPORT"

# 构建信息：以后需要"和发布的二进制完全对应的源码"时用得上
{
  echo "构建时间：$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "目标：$TARGET（API $API）"
  echo "FFmpeg：n$FFVER（提交 $(git -C "$SRC/ffmpeg" rev-parse HEAD 2>/dev/null)）"
  echo "NDK：$(grep -m1 Pkg.Revision "$NDK/source.properties" 2>/dev/null)"
  echo "各套授权："
  grep -H -m1 '^License:' "$OUT"/logs/configure-*.txt 2>/dev/null
} > "$OUT/build-info.txt"

# 动态依赖检查：每个产物依赖哪些别的库、RUNPATH 是什么。
# 命令行程序的 NEEDED 里如果出现 libc++_shared.so，就必须和它放在同一个目录（已经附带了）；
# 其它不是安卓公开库（libc/libm/libdl/libz/liblog/libandroid/libmediandk）的依赖都是问题，一眼能看出来。
{
  echo; echo "--- 动态依赖检查（NEEDED / RUNPATH） ---"
  for f in "$OUT"/full/bin/ffmpeg "$OUT"/full/bin/ffprobe "$OUT"/lgpl/"$ABI"/*; do
    [ -f "$f" ] || continue
    echo "[${f#"$OUT"/}]"
    "$TOOLCHAIN/bin/llvm-readelf" -d "$f" 2>/dev/null | grep -E 'NEEDED|RUNPATH|RPATH|SONAME' | sed 's/^ *0x[0-9a-f]* *//'
    # 依赖名字带版本号（libavcodec.so.62 这种）的话，安卓打包后找不到，必须是不带版本号的
    if "$TOOLCHAIN/bin/llvm-readelf" -d "$f" 2>/dev/null | grep NEEDED | grep -qE '\.so\.[0-9]'; then
      echo "FAIL  ${f#"$OUT"/} 的依赖里有带版本号的库名（上面 NEEDED 里 .so.数字 的那几行）"
      VERIFY_FAILS=$((VERIFY_FAILS+1))
    fi
  done
} >> "$REPORT"

# 体积：给软件用的这一套各文件多大（未压缩；安装包里会再压缩一些）
{
  echo; echo "--- 体积（给软件用的 lgpl/$ABI 这一套，未压缩） ---"
  ls -l "$OUT/lgpl/$ABI" 2>/dev/null | awk 'NR>1{printf "%10.1f MB  %s\n", $5/1048576, $9}'
  du -sh "$OUT/lgpl/$ABI" 2>/dev/null | awk '{print "合计 " $1}'
} >> "$REPORT"
cat "$REPORT"
if [ "$VERIFY_FAILS" -ne 0 ]; then
  echo "必需功能检查有 $VERIFY_FAILS 项没通过（见上面 MISS / FAIL），产物已上传但先不要使用。"
  exit 1
fi
