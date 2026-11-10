#!/usr/bin/env bash
# Windows 和安卓共用：对照"要移植过去的软件（Python 版多媒体处理栈）实际需要什么"，检查编出来的 ffmpeg 是不是都有。
# 数据来自 configure 末尾的汇总输出（"Enabled encoders:" 这类段落），所以安卓的可执行文件在这台机器上不能运行也一样能查。
# 缺了必需项会在 dep-report.txt 里写 MISS，并让整个任务变红（产物仍会上传），免得拿到手才发现少东西、要再编一次。

VERIFY_FAILS=0

# 取 configure 日志里某一段（"Enabled <段名>:" 到下一个空行）里的全部名字，每行一个
cfg_names() { # 日志 段名
  awk -v s="Enabled $2:" '$0==s{f=1;next} f&&/^$/{exit} f' "$1" | tr -s '[:space:]' '\n' | grep -v '^$'
}
cfg_has() { # 日志 段名 名字
  # configure 汇总里的名字是内部标识符：连字符一律写成下划线（libvpx-vp9 → libvpx_vp9），所以先把要找的名字也转一下
  cfg_names "$1" "$2" | grep -qx -- "${3//-/_}"
}
verify_has() { # 标签 日志 段名 名字...    这些都必须有
  local label="$1" log="$2" sec="$3"; shift 3
  local miss=() n
  [ -f "$log" ] || { echo "MISS  $label $sec：找不到 configure 日志 $log"; VERIFY_FAILS=$((VERIFY_FAILS+1)); return; }
  for n in "$@"; do cfg_has "$log" "$sec" "$n" || miss+=("$n"); done
  if [ "${#miss[@]}" -eq 0 ]; then echo "OK    $label $sec：必需的都有（$*）"
  else echo "MISS  $label $sec：缺 ${miss[*]}"; VERIFY_FAILS=$((VERIFY_FAILS+1)); fi
}
verify_absent() { # 标签 日志 段名 名字...   这些必须没有（GPL 的东西）
  local label="$1" log="$2" sec="$3"; shift 3
  local bad=() n
  for n in "$@"; do cfg_has "$log" "$sec" "$n" && bad+=("$n"); done
  if [ "${#bad[@]}" -eq 0 ]; then echo "OK    $label $sec：没有混进 $*"
  else echo "FAIL  $label $sec：混进了 ${bad[*]}（GPL，不能发布）"; VERIFY_FAILS=$((VERIFY_FAILS+1)); fi
}

# ---- 必需清单：来自 Python 软件 converter.py / 流2_0.py 实际用到的 + 它按文件后缀自动选用的 ----
# 视频 H.264 编码：Python 用 libx264(CPU) / h264_nvenc(GPU)。LGPL 版没有 libx264，
# CPU 改用 libopenh264；GPU：Windows 用 h264_nvenc，安卓用 h264_mediacodec（各自在下面的平台专有清单里）。
REQ_ENCODERS=(libopenh264 libvpx-vp9 libopus aac libmp3lame libvorbis flac
              pcm_s16le pcm_s24le pcm_s32le pcm_f32le
              mjpeg png bmp libwebp gif libaom-av1 exr targa mpeg4 srt ass webvtt)
REQ_DECODERS=(h264 hevc vp9 av1 libdav1d aac mp3 opus vorbis flac pcm_s16le png mjpeg webp gif)
REQ_MUXERS=(mp4 mov matroska webm avi mpegts image2 gif ico mp3 ipod wav flac ogg opus adts srt ass webvtt avif webp)
REQ_DEMUXERS=(concat mov matroska avi mpegts flv gif srt ass webvtt mp3 wav flac ogg aac image2)
# 注意：Python 里模糊水印用的 boxblur 是 GPL 滤镜，LGPL 版里没有（从你两端的滤镜清单里确认过）。
# avgblur（平均模糊 = 方框模糊）是 LGPL 的，移植时用它代替 boxblur。所以这里要求 avgblur，不要求 boxblur。
REQ_FILTERS=(scale crop transpose avgblur gblur rotate fps atempo setpts overlay pad split setsar
             subtitles ass palettegen paletteuse aresample)
GPL_ENCODERS=(libx264 libx265)

verify_common() { # 标签 configure日志
  verify_has "$1" "$2" encoders "${REQ_ENCODERS[@]}"
  verify_has "$1" "$2" decoders "${REQ_DECODERS[@]}"
  verify_has "$1" "$2" muxers   "${REQ_MUXERS[@]}"
  verify_has "$1" "$2" demuxers "${REQ_DEMUXERS[@]}"
  verify_has "$1" "$2" filters  "${REQ_FILTERS[@]}"
  verify_absent "$1" "$2" encoders "${GPL_ENCODERS[@]}"
}
verify_windows() { # 标签 日志：硬件编码（Python 的 GPU 模式 = h264_nvenc + -hwaccel cuda）以及 Windows 的其它硬件
  verify_common "$1" "$2"
  verify_has "$1" "$2" encoders h264_nvenc hevc_nvenc h264_qsv h264_amf h264_mf
  verify_has "$1" "$2" hwaccels h264_nvdec hevc_nvdec h264_d3d11va hevc_d3d11va h264_dxva2
}
verify_android() { # 标签 日志：安卓的硬件编解码 = MediaCodec
  verify_common "$1" "$2"
  verify_has "$1" "$2" encoders h264_mediacodec hevc_mediacodec
  verify_has "$1" "$2" decoders h264_mediacodec hevc_mediacodec
}
