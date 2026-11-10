#!/usr/bin/env bash
# 网络下载小工具（Windows / 安卓 / iOS 共用）。
#
# 为什么要这样：GitHub 偶尔整体返回 502/503/504，一次能持续好几分钟。原来 curl 重试 5 次加起来只等 31 秒，
# 下载失败的外部库会被悄悄跳过，编出来的 ffmpeg 就缺东西——上一次 x86_64 就是 libvpx 没下下来，等于没有 VP9。
# 现在：多轮重试（每轮等得更久，最长约 7 分钟）+ 换备用入口（codeload.github.com），下载下来还检查压缩包完整。

# 命令失败就等一会儿重试：retry 命令 参数...
retry() {
  local n
  for n in 1 2 3 4 5 6; do
    "$@" && return 0
    echo "命令失败（第 $n 轮）：$*；等 $((n * 20)) 秒后重试" >&2
    sleep $((n * 20))
  done
  return 1
}

# git clone 重试：参数和 git clone 一样（最后一个参数是目标目录）；失败就清掉半成品重来
clone() {
  local dest="${!#}" n
  for n in 1 2 3 4 5 6; do
    rm -rf "$dest"
    git clone "$@" && return 0
    echo "git clone 失败（第 $n 轮）：$dest；等 $((n * 20)) 秒后重试" >&2
    sleep $((n * 20))
  done
  return 1
}

# 下载并解压：dl_extract 目标根目录 目录名 网址 [备用网址...]
dl_extract() {
  local root="$1" name="$2"; shift 2
  local f="$root/$name.dl" u n
  mkdir -p "$root"
  for n in 1 2 3 4 5 6; do
    for u in "$@"; do
      if curl -fL --retry 2 --retry-all-errors --connect-timeout 30 -o "$f" "$u" && tar -tf "$f" > /dev/null 2>&1; then
        rm -rf "$root/$name" && mkdir -p "$root/$name" \
          && tar -xf "$f" --strip-components=1 -C "$root/$name" && return 0
      fi
    done
    echo "下载 $name 失败（第 $n 轮）；等 $((n * 20)) 秒后重试" >&2
    sleep $((n * 20))
  done
  return 1
}

# GitHub 的 /archive/ 下载地址还有另一个入口 codeload.github.com，主入口返回 5xx 时它常常还能用。
# gh_urls 网址  →  输出"网址 备用网址"（不是 GitHub 压缩包地址就原样输出）
gh_urls() {
  local url="$1" rest repo ref
  case "$url" in
    https://github.com/*/archive/refs/tags/*.tar.gz)
      rest="${url#https://github.com/}"; repo="${rest%%/archive/*}"; ref="${rest##*/archive/refs/tags/}"
      echo "$url https://codeload.github.com/$repo/tar.gz/refs/tags/${ref%.tar.gz}" ;;
    https://github.com/*/archive/refs/heads/*.tar.gz)
      rest="${url#https://github.com/}"; repo="${rest%%/archive/*}"; ref="${rest##*/archive/refs/heads/}"
      echo "$url https://codeload.github.com/$repo/tar.gz/refs/heads/${ref%.tar.gz}" ;;
    *) echo "$url" ;;
  esac
}
