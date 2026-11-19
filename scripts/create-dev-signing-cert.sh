#!/usr/bin/env bash
# 生成本机自用的「代码签名」自签名证书（Issue #121）。
#
# 为什么需要：
#   ad-hoc 签名（`codesign --sign -`）没有证书，TCC 记下的 designated requirement
#   是本次构建的 cdhash，每重建一次就变，屏幕录制等授权随之失效。用一张固定证书
#   签名之后，requirement 变成 `identifier ... and certificate leaf = H"..."`，
#   证书不变 → 重建后授权继续有效。
#
# 这个脚本只做「生成 + 导入登录钥匙串 + 导出可换机恢复的 .p12」；
# **「始终信任」必须由用户在钥匙串访问里点**（需要系统密码，脚本不替用户做），
# 具体步骤在脚本最后打印。
#
# 用法：
#   ./scripts/create-dev-signing-cert.sh                       # 生成（默认名 cmux Local Code Signing）
#   ./scripts/create-dev-signing-cert.sh --name "我的签名证书"
#   ./scripts/create-dev-signing-cert.sh --import <备份.p12>    # 换机恢复
#
# 备份默认写到 ~/.dev/private/cmux/signing/（本机私有目录、不进仓库）。
set -euo pipefail

DEFAULT_NAME="cmux Local Code Signing"
DEFAULT_BACKUP_DIR="${HOME}/.dev/private/cmux/signing"

NAME="$DEFAULT_NAME"
OUT=""
IMPORT_P12=""
PASSWORD="${CMUX_DEV_SIGNING_CERT_PASSWORD:-}"

usage() {
  cat <<'EOF'
Usage: ./scripts/create-dev-signing-cert.sh [options]

Options:
  --name <CN>        证书的 Common Name（默认 "cmux Local Code Signing"）
  --out <p12 path>   导出的 .p12 备份路径（默认 ~/.dev/private/cmux/signing/cmux-dev-signing.p12）
  --import <p12>     不生成新证书，改为导入已有备份（换机恢复）
  --password <pw>    配合 --import 使用的 p12 密码；省略时会交互式询问
  -h, --help         显示本帮助

生成完成后按脚本最后打印的步骤：① 在钥匙串访问里把证书设为「始终信任」；
② 设 CMUX_DEV_SIGN_IDENTITY；③ 重新授权一次屏幕录制。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      NAME="${2:-}"
      [[ -n "$NAME" ]] || { echo "error: --name 需要值" >&2; exit 1; }
      shift 2
      ;;
    --out)
      OUT="${2:-}"
      [[ -n "$OUT" ]] || { echo "error: --out 需要值" >&2; exit 1; }
      shift 2
      ;;
    --import)
      IMPORT_P12="${2:-}"
      [[ -n "$IMPORT_P12" ]] || { echo "error: --import 需要值" >&2; exit 1; }
      shift 2
      ;;
    --password)
      PASSWORD="${2:-}"
      [[ -n "$PASSWORD" ]] || { echo "error: --password 需要值" >&2; exit 1; }
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: 未知参数 $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

BACKUP_DIR="$(dirname "${OUT:-$DEFAULT_BACKUP_DIR/cmux-dev-signing.p12}")"
OUT="${OUT:-$BACKUP_DIR/cmux-dev-signing.p12}"
mkdir -p "$BACKUP_DIR"

LOGIN_KEYCHAIN="$(security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')"
[[ -n "$LOGIN_KEYCHAIN" ]] || { echo "error: 找不到登录钥匙串（security default-keychain 无输出）" >&2; exit 1; }

# 已存在同名证书时拒绝继续：重新生成会让证书哈希变化，TCC 授权要再失效一次。
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  cat >&2 <<EOF
error: 钥匙串里已经有一张名为 "$NAME" 的证书，拒绝覆盖。

重新生成会让证书哈希变化、屏幕录制等 TCC 授权再失效一次，所以这里不自动动手。
要重新生成的话：先在「钥匙串访问」里删掉旧证书（登录钥匙串 → 证书），或改个名字：
  ./scripts/create-dev-signing-cert.sh --name "cmux Local Code Signing 2"
EOF
  exit 1
fi

prompt_password() {
  if [[ -n "$PASSWORD" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "error: 需要 p12 密码，但当前不是交互终端；请用 --password 或 CMUX_DEV_SIGNING_CERT_PASSWORD 传入" >&2
    exit 1
  fi
  local first second
  read -r -s -p "给备份 p12 设一个密码（换机恢复时要用）: " first; echo
  read -r -s -p "再输一遍: " second; echo
  [[ "$first" == "$second" ]] || { echo "error: 两次输入不一致" >&2; exit 1; }
  [[ -n "$first" ]] || { echo "error: 密码不能为空" >&2; exit 1; }
  PASSWORD="$first"
}

export_p12() {
  local key="$1" cert="$2" out="$3"
  # LibreSSL（macOS 自带）默认只能读旧的 PBE 算法；先按上游实测可用的参数导出，
  # 失败再用 OpenSSL 3 的 -legacy（老算法集）。两条路径都产出现在能导回去的包。
  if openssl pkcs12 -export -inkey "$key" -in "$cert" -name "$NAME" -out "$out" \
      -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
      -passout "pass:$PASSWORD" 2>/dev/null; then
    return 0
  fi
  if openssl pkcs12 -export -legacy -inkey "$key" -in "$cert" -name "$NAME" -out "$out" \
      -passout "pass:$PASSWORD" 2>/dev/null; then
    return 0
  fi
  echo "error: 导出 .p12 失败（keypbe/certpbe 与 -legacy 两种写法都试过了）" >&2
  exit 1
}

if [[ -n "$IMPORT_P12" ]]; then
  [[ -f "$IMPORT_P12" ]] || { echo "error: 找不到 $IMPORT_P12" >&2; exit 1; }
  if [[ -z "$PASSWORD" ]]; then
    if [[ -t 0 ]]; then
      read -r -s -p "输入 $IMPORT_P12 的密码: " PASSWORD; echo
    else
      echo "error: 导入 .p12 需要密码；请用 --password 或 CMUX_DEV_SIGNING_CERT_PASSWORD 传入" >&2
      exit 1
    fi
  fi
  echo "==> 导入 $IMPORT_P12 到登录钥匙串（${LOGIN_KEYCHAIN}）"
  security import "$IMPORT_P12" -k "$LOGIN_KEYCHAIN" -P "$PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
  # 信任步骤要用到 PEM 证书；从 p12 里取一份放到备份目录旁边。
  CERT_PEM="$BACKUP_DIR/${NAME// /-}.cert.pem"
  if openssl pkcs12 -in "$IMPORT_P12" -clcerts -nokeys -passin "pass:$PASSWORD" -out "$CERT_PEM" 2>/dev/null; then
    chmod 644 "$CERT_PEM"
  else
    CERT_PEM=""
  fi
  OUT="$IMPORT_P12"
else
  prompt_password
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-signing-cert.XXXXXX")"
  trap 'rm -rf "$WORK_DIR"' EXIT

  echo "==> 生成自签名代码签名证书：$NAME"
  cat > "$WORK_DIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no

[ dn ]
CN = $NAME

[ codeSigning ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" \
    -config "$WORK_DIR/openssl.cnf" -extensions codeSigning

  echo "==> 导出备份：$OUT"
  export_p12 "$WORK_DIR/key.pem" "$WORK_DIR/cert.pem" "$OUT"
  chmod 600 "$OUT"
  PASSWORD_FILE="$BACKUP_DIR/$(basename "${OUT%.p12}").password"
  printf '%s\n' "$PASSWORD" > "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"

  CERT_PEM="$BACKUP_DIR/$(basename "${OUT%.p12}").cert.pem"
  cp "$WORK_DIR/cert.pem" "$CERT_PEM"
  chmod 644 "$CERT_PEM"

  echo "==> 导入登录钥匙串（${LOGIN_KEYCHAIN}）"
  security import "$OUT" -k "$LOGIN_KEYCHAIN" -P "$PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
fi

cat <<EOF

================ 还需要你手动做三步 ================

① 让系统「始终信任」这张证书（一次性，必须由你在钥匙串访问里点）：

   打开「钥匙串访问」→ 左侧选「登录」→「证书」→ 找到 "$NAME"
   → 双击 → 展开「信任」→「使用此证书时」选「始终信任」→ 关闭窗口，输入系统密码。

   或者用命令行（会提示输入管理员密码，效果相同）：
$(if [[ -n "${CERT_PEM:-}" ]]; then printf '   sudo security add-trusted-cert -d -r trustAsRoot -p codeSign -k /Library/Keychains/System.keychain "%s"\n' "$CERT_PEM"; else printf '   （先导出 PEM：security find-certificate -c "%s" -p > /tmp/cmux-cert.pem 再传给 add-trusted-cert）\n' "$NAME"; fi)

② 验证身份已经可用：

   security find-identity -v -p codesigning
   # 输出里应出现 "$NAME"，且计数不再是 0 valid identities found

③ 让构建用它（写进 ~/.zshrc 即可长期生效）：

   export CMUX_DEV_SIGN_IDENTITY="$NAME"

   然后重新构建一次（scripts/reload.sh / scripts/reloads.sh 都认这个变量），
   并**重新授权一次**屏幕录制等 TCC 权限（旧的 ad-hoc 记录认的是旧 cdhash）：
   tccutil reset ScreenCapture com.xhqing.cmux     # Release 版
   tccutil reset ScreenCapture com.cmuxterm.app    # 开发版（reload.sh 默认 bundle id 前缀）
   再打开 app，按系统提示重新授予。

备忘：
- 备份：p12 与密码文件在 ${BACKUP_DIR}/（本机私有目录，不进仓库）。
- 换机恢复：./scripts/create-dev-signing-cert.sh --import <备份.p12>，
  但「始终信任」是本机设置，换机后必须重做第 ① 步。
- 重新生成证书会让授权再失效一次；签名证书本身没有有效期问题（3650 天）。
- 自签名只解决开发机自用；对外分发仍然需要 Developer ID + 公证。
EOF
