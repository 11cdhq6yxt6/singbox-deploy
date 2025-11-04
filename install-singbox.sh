#!/usr/bin/env sh
# Enhanced sing-box SS2022 installer (Alpine + Debian/Ubuntu + generic)
# Compatible with ash (BusyBox), dash, bash.
# Save as install-singbox.sh and run as root: bash install-singbox.sh

# --- basic safe flags (try pipefail, else fall back) ---
if (set -o pipefail) >/dev/null 2>&1; then
    set -euo pipefail
else
    set -eu
fi

# --- colors ---
COLOR_INFO='\033[1;34m'
COLOR_WARN='\033[1;33m'
COLOR_ERR='\033[1;31m'
COLOR_RST='\033[0m'

info() { printf "${COLOR_INFO}[INFO]${COLOR_RST} %s\n" "$*"; }
warn() { printf "${COLOR_WARN}[WARN]${COLOR_RST} %s\n" "$*"; }
err()  { printf "${COLOR_ERR}[ERR]${COLOR_RST} %s\n" "$*" >&2; }

# --- detect OS ---
OS=""
PKG_MANAGER=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    ID_LC=$(printf "%s" "${ID:-}" | tr '[:upper:]' '[:lower:]')
    ID_LIKE_LC=$(printf "%s" "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')
else
    ID_LC=""
    ID_LIKE_LC=""
fi

case "${ID_LC} ${ID_LIKE_LC}" in
  *alpine*)
    OS="alpine"; PKG_MANAGER="apk" ;;
  *debian*|*ubuntu*)
    OS="debian"; PKG_MANAGER="apt" ;;
  *centos*|*rhel*|*fedora*)
    OS="rhel"; PKG_MANAGER="dnf" ;; # try dnf/yum later
  *)
    OS="unknown"; PKG_MANAGER=""
    ;;
esac

info "检测到系统: ${OS}"

# --- helpers ---
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

safe_mkdir() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
    fi
}

# --- install basic deps ---
install_packages() {
    # packages to ensure: curl, ca-certificates, tar, gzip, openssl, sed, awk
    info "安装/检查依赖（curl, ca-certificates, tar, gzip, openssl）"
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache ca-certificates curl tar gzip openssl bash coreutils || {
            warn "apk 安装某些包失败，请手动安装后重试"
        }
    elif [ "$OS" = "debian" ]; then
        apt-get update -y || true
        apt-get install -y ca-certificates curl tar gzip openssl || {
            warn "apt-get 安装某些包失败，请手动安装后重试"
        }
    elif [ "$OS" = "rhel" ]; then
        if command_exists dnf; then
            dnf install -y ca-certificates curl tar gzip openssl || warn "dnf 安装失败"
        else
            yum install -y ca-certificates curl tar gzip openssl || warn "yum 安装失败"
        fi
    else
        warn "未识别包管理器，尝试继续（请确保 curl/tar/openssl 可用）"
    fi
}

# --- detect arch ---
detect_arch() {
    UNAME_M=$(uname -m)
    case "$UNAME_M" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv7) ARCH="armv7" ;;
        i686|i386) ARCH="386" ;;
        *) ARCH="amd64"; warn "未识别架构 ${UNAME_M}，将尝试使用 amd64";;
    esac
    info "检测到架构: $ARCH ($UNAME_M)"
}

# --- generate random port (10000-60000) ---
generate_random_port() {
    # try shuf
    if command_exists shuf; then
        shuf -i 10000-60000 -n 1
        return
    fi
    # try openssl random
    if command_exists openssl; then
        hex=$(openssl rand -hex 2 2>/dev/null || true)
        if [ -n "$hex" ]; then
            val=$((0x$hex))
            echo $((10000 + val % 50001))
            return
        fi
    fi
    # try python3
    if command_exists python3; then
        python3 - <<'PY'
import random,sys
print(random.randint(10000,60000))
PY
        return
    fi
    # fallback to shell RANDOM if present
    if [ -n "${RANDOM-}" ]; then
        echo $((10000 + RANDOM % 50001))
        return
    fi
    # final fallback: use timestamp
    echo $((10000 + $(date +%s) % 50001))
}

# --- generate PSK (Base64) ---
generate_psk() {
    KEY_BYTES=16
    # prefer user-specified env var
    if [ -n "${USER_PWD:-}" ]; then
        PSK="$USER_PWD"
        return
    fi
    # sing-box generate rand
    if command_exists sing-box; then
        PSK=$(sing-box generate rand --base64 "$KEY_BYTES" 2>/dev/null | tr -d '\n' || true)
    fi
    if [ -z "${PSK:-}" ] && command_exists openssl; then
        PSK=$(openssl rand -base64 "$KEY_BYTES" | tr -d '\n')
    fi
    if [ -z "${PSK:-}" ] && command_exists python3; then
        PSK=$(python3 - <<PY
import base64,os,sys
print(base64.b64encode(os.urandom($KEY_BYTES)).decode())
PY
)
    fi
    if [ -z "${PSK:-}" ]; then
        # fallback short random
        PSK="psk-$(date +%s)"
        warn "无法使用 openssl/python3/sing-box 生成随机，使用弱 PSK: $PSK"
    fi
}

# --- get public IP ---
get_public_ip() {
    for url in "https://ipinfo.io/ip" "https://ipv4.icanhazip.com" "https://ifconfig.co/ip" "https://api.ipify.org"; do
        if command_exists curl; then
            ip=$(curl -s --max-time 5 "$url" || true)
        elif command_exists wget; then
            ip=$(wget -qO- --timeout=5 "$url" || true)
        else
            ip=""
        fi
        if [ -n "$ip" ]; then
            printf "%s" "$ip" | tr -d '[:space:]'
            return 0
        fi
    done
    return 1
}

# --- fetch latest sing-box release tag via GitHub API ---
get_latest_release() {
    API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    if command_exists curl; then
        raw=$(curl -sL "$API_URL" || true)
    elif command_exists wget; then
        raw=$(wget -qO- "$API_URL" || true)
    else
        raw=""
    fi
    if [ -z "$raw" ]; then
        warn "无法查询 GitHub API（网络/工具问题），将使用内置默认版本 (latest)"
        LATEST=""
    else
        # parse "tag_name": "v1.2.3"
        LATEST=$(printf "%s" "$raw" | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')
    fi
    # if empty, LATEST stays empty (we'll try to find asset listing fallback)
    printf "%s" "$LATEST"
}

# --- download and install sing-box ---
install_singbox_binary() {
    detect_arch
    LATEST_TAG=$(get_latest_release)
    # If LATEST_TAG empty, we'll try "latest" as path; GitHub supports /latest URL redirect
    if [ -n "$LATEST_TAG" ]; then
        VER="$LATEST_TAG"
    else
        VER="latest"
    fi

    # determine asset name
    case "$ARCH" in
        amd64) ASSET_ARCH="amd64" ;;
        arm64) ASSET_ARCH="arm64" ;;
        armv7) ASSET_ARCH="armv7" ;;
        386)   ASSET_ARCH="386" ;;
        *)     ASSET_ARCH="amd64" ;;
    esac

    # Try several possible tarball name patterns (some releases may vary)
    try_urls() {
        # prefer v<ver> path when we have concrete version
        if [ "$VER" != "latest" ]; then
            echo "https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ASSET_ARCH}.tar.gz"
            echo "https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-linux-${ASSET_ARCH}.tar.gz"
        fi
        # fallback to latest redirect
        echo "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-${ASSET_ARCH}.tar.gz"
        echo "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-${VER}-linux-${ASSET_ARCH}.tar.gz"
    }

    TMPDIR=$(mktemp -d 2>/dev/null || mkdir -p /tmp && mktemp -d -t sbx.XXXX)
    cd "$TMPDIR" || exit 1

    downloaded=""
    for url in $(try_urls); do
        info "尝试下载: $url"
        if command_exists curl; then
            curl -fsSL -o singbox.tar.gz "$url" 2>/dev/null || { warn "下载失败: $url"; rm -f singbox.tar.gz; continue; }
        elif command_exists wget; then
            wget -qO singbox.tar.gz "$url" || { warn "下载失败: $url"; rm -f singbox.tar.gz; continue; }
        else
            err "没有 curl 或 wget，无法下载 sing-box 二进制"
            return 1
        fi
        # try list the tar to verify
        if tar -tzf singbox.tar.gz >/dev/null 2>&1; then
            downloaded=1
            break
        else
            warn "下载的文件不是有效 tar.gz，尝试下一个 URL"
            rm -f singbox.tar.gz
        fi
    done

    if [ -z "${downloaded:-}" ]; then
        err "无法从 GitHub 下载 sing-box 二进制，请检查网络或手动安装"
        return 1
    fi

    tar -xzf singbox.tar.gz || { err "解压失败"; return 1; }

    # find the sing-box binary inside extracted folder
    BINPATH=$(find . -type f -name sing-box -perm -111 | head -n1 || true)
    if [ -z "$BINPATH" ]; then
        # maybe binary at root
        if [ -f "./sing-box" ]; then
            BINPATH="./sing-box"
        else
            err "在压缩包中未找到 sing-box 可执行文件"
            return 1
        fi
    fi

    install -m 755 "$BINPATH" /usr/bin/sing-box || {
        # try /usr/local/bin
        install -m 755 "$BINPATH" /usr/local/bin/sing-box || { err "安装 sing-box 到 /usr/bin 失败"; return 1; }
        SB_PATH="/usr/local/bin/sing-box"
    }
    SB_PATH=${SB_PATH:-/usr/bin/sing-box}
    info "sing-box 安装成功: $SB_PATH"

    # cleanup
    cd /tmp || true
    rm -rf "$TMPDIR"
    return 0
}

# --- create service ---
create_service() {
    # $1 = path to sing-box binary (optional, default /usr/bin/sing-box)
    SB=${1:-/usr/bin/sing-box}
    if [ ! -x "$SB" ]; then
        err "sing-box 可执行文件不存在或不可执行: $SB"
        return 1
    fi

    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"
        info "生成 OpenRC 服务：$SERVICE_PATH"
        cat > "$SERVICE_PATH" <<'EOF'
#!/sbin/openrc-run
command=/usr/bin/sing-box
command_args="run -c /etc/sing-box/config.json"
pidfile=/run/sing-box.pid
name=sing-box
description="Sing-box Shadowsocks Server"

depend() {
    need net
}
EOF
        chmod +x "$SERVICE_PATH"
        # add to default runlevel and start
        if command_exists rc-update; then
            rc-update add sing-box default || true
        fi
        if command_exists rc-service; then
            rc-service sing-box start || warn "尝试启动 sing-box 服务失败，请手动运行 rc-service sing-box start"
        fi
        info "OpenRC 服务已创建"
    else
        # create systemd unit
        if command_exists systemctl; then
            SERVICE_PATH="/etc/systemd/system/sing-box.service"
            info "生成 systemd 单元: $SERVICE_PATH"
            cat > "$SERVICE_PATH" <<UNIT
[Unit]
Description=Sing-box Shadowsocks Server
After=network.target

[Service]
ExecStart=$SB run -c /etc/sing-box/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
            systemctl daemon-reload || true
            systemctl enable --now sing-box || warn "systemd 启动/启用失败，请手动运行 systemctl start sing-box"
            info "systemd 服务已创建（或尝试启动）"
        else
            warn "未检测到 systemctl，跳过 systemd 服务创建，请手动创建或直接运行: $SB run -c /etc/sing-box/config.json"
        fi
    fi
}

# --- write sing-box config for SS2022 inbound ---
write_config() {
    CONFIG_PATH="/etc/sing-box/config.json"
    safe_mkdir "$(dirname "$CONFIG_PATH")"

    # method and PSK
    METHOD="2022-blake3-aes-128-gcm"

    cat > "$CONFIG_PATH" <<EOF
{
  "log": {"level":"info"},
  "inbounds":[
    {
      "type":"shadowsocks",
      "listen":"::",
      "listen_port":$PORT,
      "method":"$METHOD",
      "password":"$PSK",
      "tag":"ss2022-in"
    }
  ],
  "outbounds":[
    {"type":"direct","tag":"direct-out"}
  ]
}
EOF
    info "配置写入: $CONFIG_PATH"
}

# --- generate SS links ---
make_ss_links() {
    HOST="$1"
    TAG="singbox-ss2022"
    USERINFO="${METHOD}:${PSK}"

    # Try python for encoding
    if command_exists python3; then
        ENC_USERINFO=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$USERINFO")
        BASE64_USERINFO=$(python3 -c "import base64,sys; s=sys.argv[1].encode(); print(base64.b64encode(s).decode())" "$USERINFO")
    else
        # fallback: urlencode minimal (replace space), base64 via openssl if available
        ENC_USERINFO=$(printf "%s" "$USERINFO" | sed -e 's/ /%20/g')
        if command_exists openssl; then
            BASE64_USERINFO=$(printf "%s" "$USERINFO" | openssl base64 -A)
        else
            BASE64_USERINFO=$(printf "%s" "$USERINFO" | base64 | tr -d '\n' 2>/dev/null || printf "%s" "$USERINFO")
        fi
    fi

    SS_SIP002="ss://${ENC_USERINFO}@${HOST}:${PORT}#${TAG}"
    SS_BASE64="ss://${BASE64_USERINFO}@${HOST}:${PORT}#${TAG}"

    printf "%s\n%s\n" "$SS_SIP002" "$SS_BASE64"
}

# --- main flow ---
main() {
    # prompt port & password (if interactive)
    if [ -t 0 ]; then
        printf "请输入端口（留空则随机 10000-60000）: "
        read USER_PORT || true
    else
        USER_PORT=""
    fi

    if [ -n "${USER_PORT:-}" ]; then
        case "$USER_PORT" in
            *[!0-9]*)
                err "端口必须为数字"; exit 1 ;;
            *) PORT="$USER_PORT" ;;
        esac
    else
        PORT=$(generate_random_port)
        info "使用随机端口: $PORT"
    fi

    # prompt password (optional)
    if [ -t 0 ]; then
        printf "请输入密码（留空则自动生成 Base64 PSK）: "
        read USER_PWD || true
    else
        USER_PWD=""
    fi

    install_packages

    # install sing-box binary
    if ! command_exists sing-box; then
        install_singbox_binary || { err "安装 sing-box 失败"; exit 1; }
    else
        info "检测到已有 sing-box: $(command -v sing-box)"
    fi

    # generate PSK
    generate_psk

    # write config
    write_config

    # create service
    create_service "$(command -v sing-box || echo /usr/bin/sing-box)"

    # get public ip
    PUB_IP=$(get_public_ip || true)
    if [ -z "$PUB_IP" ]; then
        warn "无法自动获取公网 IP，请使用服务器公网 IP 手动替换"
        PUB_IP="YOUR_SERVER_IP"
    else
        info "检测到公网 IP: $PUB_IP"
    fi

    # generate links
    info ""
    info "==================== 生成的 ss 链接 ===================="
    make_ss_links "$PUB_IP" | sed -e 's/^/    /'
    info "======================================================="
    info "部署完成 ✅"
    info "端口: $PORT"
    info "PSK: $PSK"
    info "配置文件: /etc/sing-box/config.json"
    info "服务路径: ${SERVICE_PATH:-手动启动}"
    info "若需要卸载，请删除二进制 /usr/bin/sing-box、配置目录 /etc/sing-box 以及服务文件"
}

# run
main "$@"
