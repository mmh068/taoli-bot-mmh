#!/usr/bin/env bash
# 在全新 Ubuntu（x86_64）上一键安装 arb-bot 看板，并登记为 systemd 服务。
#
# 用法：先把本仓库放到机器上，然后：
#   sudo bash deploy/install-ubuntu-systemd.sh
#
# 会安装：编译依赖、Rust、Lighter 官方签名库、全部命令行程序，
# 然后把看板装到 /opt/arb-bot，数据目录 /var/lib/arb-bot，密钥 /etc/arb-bot.env。
#
# 常用参数：
#   --deps-only     只装系统依赖、Rust 和签名库，不编译、不改服务
#   --no-start      装好并 enable，但不立刻启动
#   --skip-build    不重新编译，使用仓库里已有的 target/release 成品
#   --uninstall     停服务并删程序（保留密钥和台账）
#   --purge         在 --uninstall 基础上再删密钥和数据（不可恢复）

set -euo pipefail

SIGNER_URL="https://github.com/elliottech/lighter-go/releases/download/v1.0.10/lighter-signer-linux-amd64.so"
SIGNER_SHA256="1022a277cbb8fb9647886a611bc02151ad28cdbc5a02f7ac6416faa2898be392"
SIGNER_PATH="/opt/lighter/lighter-signer-linux-amd64.so"
OPT_DIR="/opt/arb-bot"
DATA_DIR="/var/lib/arb-bot"
ENV_FILE="/etc/arb-bot.env"
SERVICE_NAME="arb-web"
SERVICE_DST="/etc/systemd/system/${SERVICE_NAME}.service"
BINS=(arb-web arb-scan arb-paper arb-live)

DEPS_ONLY=0
NO_START=0
SKIP_BUILD=0
UNINSTALL=0
PURGE=0

log() { printf '[arb-install] %s\n' "$*"; }
die() { printf '[arb-install] 错误：%s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --deps-only) DEPS_ONLY=1 ;;
    --no-start) NO_START=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --purge) UNINSTALL=1; PURGE=1 ;;
    *) die "未知参数：$1（--help 看用法）" ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVICE_SRC="${SCRIPT_DIR}/${SERVICE_NAME}.service"

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "请用 root 运行：sudo bash deploy/install-ubuntu-systemd.sh"
}

assert_platform() {
  [[ "$(uname -s)" == Linux ]] || die "只支持 Linux"
  local arch
  arch="$(uname -m)"
  [[ "$arch" == x86_64 || "$arch" == amd64 ]] || die "Lighter 签名库只有 x86_64，当前是 ${arch}"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) ;;
      *) log "警告：未识别的发行版 ${ID:-unknown}，按 Debian 系继续" ;;
    esac
  fi
}

build_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
    printf '%s\n' "$SUDO_USER"
  else
    printf 'root\n'
  fi
}

user_home() {
  getent passwd "$1" | cut -d: -f6
}

as_user() {
  local user="$1"
  shift
  if [[ "$user" == root ]]; then
    env "$@"
  else
    sudo -u "$user" -H "$@"
  fi
}

install_apt() {
  export DEBIAN_FRONTEND=noninteractive
  log "安装系统依赖"
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    build-essential \
    pkg-config \
    openssl \
    xz-utils \
    jq
}

install_rust() {
  local user="$1"
  local home cargo
  home="$(user_home "$user")"
  cargo="${home}/.cargo/bin/cargo"
  if [[ -x "$cargo" ]]; then
    log "Rust 已在 ${user} 下安装，跳过 rustup"
    return
  fi
  log "为 ${user} 安装 Rust（rustup，minimal）"
  as_user "$user" bash -lc "curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable"
}

install_signer() {
  mkdir -p /opt/lighter
  if [[ -f "$SIGNER_PATH" ]]; then
    local have
    have="$(sha256sum "$SIGNER_PATH" | awk '{print $1}')"
    if [[ "$have" == "$SIGNER_SHA256" ]]; then
      log "Lighter 签名库已存在且校验通过"
      return
    fi
    log "已有签名库哈希不符，重新下载"
  fi
  local tmp
  tmp="$(mktemp)"
  log "下载 Lighter 官方签名库 v1.0.10"
  curl -fsSL --retry 5 --retry-delay 2 -o "$tmp" "$SIGNER_URL"
  local got
  got="$(sha256sum "$tmp" | awk '{print $1}')"
  [[ "$got" == "$SIGNER_SHA256" ]] || die "签名库 SHA-256 不符（得到 ${got}）"
  install -m 0755 "$tmp" "$SIGNER_PATH"
  rm -f "$tmp"
  log "签名库已装到 ${SIGNER_PATH}"
}

ensure_user() {
  if ! getent passwd arb >/dev/null; then
    log "创建系统用户 arb"
    useradd --system --home "$OPT_DIR" --shell /usr/sbin/nologin arb
  fi
  install -d -o arb -g arb -m 0750 "$OPT_DIR" "$DATA_DIR"
}

mem_kb() {
  awk '/MemTotal:/ {print $2}' /proc/meminfo
}

build_bins() {
  local user="$1"
  [[ -f "${REPO_ROOT}/Cargo.toml" ]] || die "找不到仓库根目录：${REPO_ROOT}"
  local cargo_bin
  cargo_bin="$(user_home "$user")/.cargo/bin"
  if [[ "$SKIP_BUILD" -eq 1 ]]; then
    log "跳过编译，使用已有成品"
    local bin
    for bin in "${BINS[@]}"; do
      [[ -x "${REPO_ROOT}/target/release/${bin}" ]] || die "没有 ${REPO_ROOT}/target/release/${bin}，去掉 --skip-build 再跑"
    done
    return
  fi

  local kb
  local -a build_env
  build_env=(PATH="${cargo_bin}:${PATH}")
  kb="$(mem_kb)"
  if [[ -n "$kb" && "$kb" -lt 3500000 ]]; then
    log "内存约 $((kb / 1024)) MB，关闭 fat LTO 以免编译时内存不够"
    build_env+=(CARGO_PROFILE_RELEASE_LTO=off CARGO_PROFILE_RELEASE_CODEGEN_UNITS=4)
  fi

  log "编译 release 成品（约几分钟到十几分钟）"
  as_user "$user" env "${build_env[@]}" \
    bash -lc "cd $(printf '%q' "$REPO_ROOT") && cargo build --release --locked --workspace"

  local bin
  for bin in "${BINS[@]}"; do
    [[ -x "${REPO_ROOT}/target/release/${bin}" ]] || die "编译结束但没有 ${bin}"
  done
}

install_bins() {
  local bin
  for bin in "${BINS[@]}"; do
    install -m 0755 "${REPO_ROOT}/target/release/${bin}" "${OPT_DIR}/${bin}"
  done
  install -m 0755 "${SCRIPT_DIR}/arbctl.sh" "${OPT_DIR}/arbctl"
  ln -sfn "${OPT_DIR}/arbctl" /usr/local/sbin/arbctl
  chown -R arb:arb "$OPT_DIR"
  log "程序已装到 ${OPT_DIR}：${BINS[*]} arbctl"
}

write_env() {
  if [[ -f "$ENV_FILE" ]]; then
    log "已有 ${ENV_FILE}，不覆盖"
    if ! grep -q '^ARB_LIGHTER_SIGNER_LIB=' "$ENV_FILE"; then
      printf '\nARB_LIGHTER_SIGNER_LIB=%s\n' "$SIGNER_PATH" >>"$ENV_FILE"
      log "已补上 ARB_LIGHTER_SIGNER_LIB"
    fi
    chmod 0600 "$ENV_FILE"
    chown arb:arb "$ENV_FILE"
    return
  fi
  local token
  token="$(openssl rand -hex 24)"
  cat >"$ENV_FILE" <<EOF
# arb-bot systemd 环境（由 deploy/install-ubuntu-systemd.sh 生成）
# 权限必须是 0600。密钥只写在这一份文件里，改完执行：sudo arbctl restart
# 完整说明见仓库 .env.example。
#
# 标记：[必填] 现在就要填  [条件必填] 开启对应功能时再填  [选填] 有默认值

# =============================================================================
# 一、必填
# =============================================================================
# [必填] 看板交易令牌。页面右上角「令牌」填同一个值。
ARB_WEB_TOKEN=${token}

# [条件必填] 用 Lighter / Lighter RH 时需要。安装脚本已放好官方签名库。
ARB_LIGHTER_SIGNER_LIB=${SIGNER_PATH}

# =============================================================================
# 二、条件必填 — 要开实盘时再改
# =============================================================================
# [选填] off（默认，不连账户）/ readonly（只读）/ trade（真实下单）
ARB_WEB_LIVE=off
# [条件必填] ARB_WEB_LIVE=trade 时必须填（0.003 = 0.3%，上限 0.05）
# ARB_WEB_MARKET_SLIPPAGE=0.003

# [条件必填] 实盘至少配齐两家。用哪家填哪家，不要开提现权限。
# ARB_HL_PRIVATE_KEY=
# ARB_HL_ACCOUNT_ADDRESS=
# ARB_LIGHTER_RH_ACCOUNT_INDEX=
# ARB_LIGHTER_RH_API_KEY_INDEX=
# ARB_LIGHTER_RH_API_PRIVATE_KEY=
# ARB_ARCUS_ADDRESS=
# ARB_ARCUS_ACCOUNT_INDEX=0
# ARB_ARCUS_API_PRIVATE_KEY=

# =============================================================================
# Telegram / 告警推送（条件必填：两项同时填才会推）
# =============================================================================
# ARB_ALERT_TELEGRAM_TOKEN=
# ARB_ALERT_TELEGRAM_CHAT=
# [选填] 告警推到群时，另填你的用户 ID，否则 Telegram 菜单不可用
# ARB_TELEGRAM_ADMIN_ID=
# [选填] 只要推送、不要菜单：off
# ARB_TELEGRAM_COMMANDS=off
# ARB_ALERT_DISCORD_WEBHOOK=

# =============================================================================
# 三、选填
# =============================================================================
ARB_LIVE_VENUES=auto
ARB_LEDGER=arb-ledger.jsonl
ARB_LIVE_LEDGER=arb-live-ledger.jsonl
ARB_LIVE_JOURNAL_DIR=.
ARB_RH_SPREAD_DIR=rh-spread
ARB_WEB_RUN_STATE=arb-web.run.json
EOF
  chmod 0600 "$ENV_FILE"
  chown arb:arb "$ENV_FILE"
  log "已生成 ${ENV_FILE}（含看板令牌，未开实盘）"
}

install_service() {
  [[ -f "$SERVICE_SRC" ]] || die "找不到 ${SERVICE_SRC}"
  install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  if [[ "$NO_START" -eq 1 ]]; then
    log "已登记服务 ${SERVICE_NAME}，按 --no-start 不启动"
    return
  fi
  systemctl restart "$SERVICE_NAME"
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "服务已启动"
  else
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    die "服务没起来，看上面的 status 和：journalctl -u ${SERVICE_NAME} -e"
  fi
  if command -v curl >/dev/null; then
    if curl -fsS --max-time 8 http://127.0.0.1:8123/healthz >/dev/null; then
      log "健康检查通过：http://127.0.0.1:8123/"
    else
      log "服务在跑，但健康检查还没通过（首次拉行情可能要一会儿）"
    fi
  fi
}

do_uninstall() {
  log "卸载 systemd 服务"
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_DST" /usr/local/sbin/arbctl
  systemctl daemon-reload
  rm -rf "$OPT_DIR"
  if [[ "$PURGE" -eq 1 ]]; then
    log "按 --purge 删除 ${ENV_FILE} 与 ${DATA_DIR}"
    rm -f "$ENV_FILE"
    rm -rf "$DATA_DIR"
  else
    log "已保留 ${ENV_FILE} 与 ${DATA_DIR}（台账不要删）。彻底清掉请加 --purge"
  fi
  log "卸载完成"
}

print_done() {
  cat <<EOF

安装完成。

  看板：     http://127.0.0.1:8123/
  程序：     ${OPT_DIR}
  数据：     ${DATA_DIR}   （台账、价差历史；必须备份，不能删 jsonl）
  密钥：     ${ENV_FILE}   （0600，改完 sudo arbctl restart）
  签名库：   ${SIGNER_PATH}

常用命令：
  sudo arbctl status
  sudo arbctl logs
  sudo arbctl restart

默认不开实盘。要下单时编辑 ${ENV_FILE}，填交易所密钥，并把 ARB_WEB_LIVE 改成 trade（同时填 ARB_WEB_MARKET_SLIPPAGE）。
看板右上角「令牌」填 ${ENV_FILE} 里的 ARB_WEB_TOKEN。
EOF
}

main() {
  need_root
  assert_platform
  if [[ "$UNINSTALL" -eq 1 ]]; then
    do_uninstall
    exit 0
  fi
  [[ -f "$SERVICE_SRC" ]] || die "请从本仓库运行（找不到 deploy/${SERVICE_NAME}.service）"
  local user
  user="$(build_user)"
  install_apt
  install_rust "$user"
  install_signer
  if [[ "$DEPS_ONLY" -eq 1 ]]; then
    log "按 --deps-only 到此结束。Rust 用户：${user}；签名库：${SIGNER_PATH}"
    exit 0
  fi
  ensure_user
  build_bins "$user"
  install_bins
  write_env
  install_service
  print_done
}

main "$@"
