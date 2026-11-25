#!/bin/bash
#
# netcfg 一键安装 / 卸载
#
#   curl -fsSL https://fastly.jsdelivr.net/gh/scenep/netcfg@main/install.sh | sudo bash
#
# 选项:
#   --ref REF        从哪个 git ref 取文件(默认本安装器对应的 tag v1.2.4; main=最新)
#   --prefix DIR     安装前缀, 默认 /usr/local (装到 DIR/bin/netcfg)
#   --from FILE      用本地 netcfg.sh 安装(离线/开发用, 不下载、不校验)
#   --base-url URL   自定义下载根, 默认 https://fastly.jsdelivr.net/gh
#   --run "ARGS"     安装后立即执行 netcfg ARGS, 如 --run "pin -y"
#   --no-verify      跳过 sha256 校验(不建议)
#   --uninstall      卸载
#   --version        显示安装器版本
#   -h, --help       帮助
#
set -euo pipefail

PROG="install.sh"
INSTALLER_VER="1.2.4"
GH_REPO="${NETCFG_GH_REPO:-scenep/netcfg}"
BASE_HOST="${NETCFG_CDN:-https://fastly.jsdelivr.net/gh}"
REF=""
PREFIX="/usr/local"
FROM_FILE=""
VERIFY=1
UNINSTALL=0
RUN=""

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install][错误] %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,20p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)       REF="${2:-}"; shift 2 ;;
    --prefix)    PREFIX="${2:-}"; shift 2 ;;
    --from)      FROM_FILE="${2:-}"; shift 2 ;;
    --base-url)  BASE_HOST="${2:-}"; shift 2 ;;
    --no-verify) VERIFY=0; shift ;;
    --run)       RUN="${2:-}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --version)   printf '%s %s\n' "$PROG" "$INSTALLER_VER"; exit 0 ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "未知参数: $1 (用 --help 查看)" ;;
  esac
done

[ -n "$PREFIX" ] || die "--prefix 不能为空"
BIN_DIR="${PREFIX%/}/bin"
TARGET="$BIN_DIR/netcfg"

if [ "$UNINSTALL" -eq 1 ]; then
  if [ -e "$TARGET" ]; then
    rm -f "$TARGET" 2>/dev/null || die "删除失败, 请用 sudo"
    log "已卸载: $TARGET"
  else
    log "未安装: $TARGET"
  fi
  exit 0
fi

if [ "${PREFIX%/}" = "/usr/local" ] && [ "$(id -u)" -ne 0 ]; then
  die "安装到 /usr/local 需要 root: 请用 sudo, 或 --prefix 指定可写目录"
fi

if [ -z "$REF" ]; then REF="v${INSTALLER_VER}"; fi
BASE_URL="${BASE_HOST%/}/${GH_REPO}@${REF}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/netcfg-install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

try_fetch() {
  local url="$BASE_URL/$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 --connect-timeout 10 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" "$url"
  else
    return 127
  fi
}

if [ -n "$FROM_FILE" ]; then
  [ -f "$FROM_FILE" ] || die "文件不存在: $FROM_FILE"
  cp "$FROM_FILE" "$TMP/netcfg.sh"
  log "使用本地文件: $FROM_FILE"
else
  log "下载 $BASE_URL/netcfg.sh"
  if ! try_fetch netcfg.sh "$TMP/netcfg.sh"; then
    if [ "$REF" != "main" ]; then
      log "ref=$REF 取不到, 回退 main"
      REF="main"
      BASE_URL="${BASE_HOST%/}/${GH_REPO}@${REF}"
      try_fetch netcfg.sh "$TMP/netcfg.sh" || die "下载失败(网络不通? 可换 --base-url 或 --from)"
    else
      die "下载失败(网络不通? 可换 --base-url 或 --from)"
    fi
  fi
  if [ "$VERIFY" -eq 1 ]; then
    if try_fetch SHA256SUMS "$TMP/SHA256SUMS"; then
      # CentOS 7 的 coreutils 8.22 不支持 --ignore-missing, 直接 -c
      ( cd "$TMP" && sha256sum -c SHA256SUMS ) || die "sha256 校验失败, 已中止安装"
      log "sha256 校验通过"
    else
      log "警告: 取不到 SHA256SUMS, 跳过校验(可用 --no-verify 显式跳过)"
    fi
  fi
fi

bash -n "$TMP/netcfg.sh" || die "下载到的 netcfg.sh 语法检查失败"
install -d "$BIN_DIR"
install -m 0755 "$TMP/netcfg.sh" "$TARGET"
NEWVER=$(bash "$TARGET" --version 2>/dev/null || echo "版本未知")
log "已安装: $TARGET  ($NEWVER)"

printf '\n用法:\n'
printf '  sudo netcfg show                                  # 看现状\n'
printf '  sudo netcfg pin                                   # 固化当前 IP/网关/DNS\n'
printf '  sudo netcfg set -4 192.168.1.10/24 -g 192.168.1.1 -d "223.5.5.5 8.8.8.8" -n\n'
printf '  sudo netcfg --detach set -4 192.168.1.10/24 -g 192.168.1.1 -d 223.5.5.5 -y\n'
printf '  sudo netcfg rollback                              # 回滚\n'
printf '  netcfg selftest                                   # 自测(不改本机网络)\n'
if [ "${PREFIX%/}" != "/usr/local" ]; then
  printf '\n提示: %s 不在默认 PATH, 请 export PATH="%s:$PATH"\n' "$BIN_DIR" "$BIN_DIR"
fi

if [ -n "$RUN" ]; then
  log "安装完成, 继续执行: netcfg $RUN"
  # 有意做单词拆分, 让 --run "pin -y" 能带参数
  # shellcheck disable=SC2086
  set -- $RUN
  exec "$TARGET" "$@"
fi
