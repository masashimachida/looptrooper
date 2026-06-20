#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gh-token ── GitHub 認証トークンを stdout に1行で出す（唯一の認証ソース）。
#   2モードを自動判別し、どちらでも「有効なトークン」を供給する:
#     1) GitHub App  : GITHUB_APP_ID ＋ 秘密鍵（FILE か B64）があれば
#                      installation token を発行（有効1時間。キャッシュして使い回す）。
#     2) 静的 token  : 上が無く GH_TOKEN があればそれをそのまま返す（PAT / machine user）。
#
#   利用箇所:
#     - git の credential helper（`--git` で username/password 形式を出力）
#     - PATH 上の gh ラッパー（/usr/local/bin/gh が GH_TOKEN にこの出力を入れて実 gh を exec）
#
#   ※stdout はトークン専用。診断は全て stderr へ。
# ─────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh

CACHE="$LOOP_DIR/.loop/.gh-token"          # "<exp_epoch> <token>"（mode 600）
INST_CACHE="$LOOP_DIR/.loop/.gh-installation-id"
BUFFER=60                                   # 失効この秒数前に再発行

err() { printf '%s\n' "gh-token: $*" >&2; }

# ── 出力ヘルパ: 素のトークン or git credential 形式 ──
emit() {
  local tok="$1"
  if [ "${1:-}" = "" ]; then return 1; fi
  if [ "${MODE:-}" = "git" ]; then
    printf 'username=x-access-token\npassword=%s\n' "$tok"
  else
    printf '%s\n' "$tok"
  fi
}

MODE="token"
[ "${1:-}" = "--git" ] && MODE="git"

# ── App モード判定 ──────────────────────────────────────────
if [ -n "${GITHUB_APP_ID:-}" ] && { [ -n "${GITHUB_APP_PRIVATE_KEY_FILE:-}" ] || [ -n "${GITHUB_APP_PRIVATE_KEY_B64:-}" ]; }; then

  # キャッシュが生きていれば即返す（API を叩かない）
  if [ -f "$CACHE" ]; then
    read -r exp tok < "$CACHE" || true
    if [ -n "${exp:-}" ] && [ -n "${tok:-}" ] && [ "$(date +%s)" -lt "$((exp - BUFFER))" ]; then
      emit "$tok"; exit 0
    fi
  fi

  command -v openssl >/dev/null 2>&1 || { err "openssl が必要です"; exit 1; }

  # 秘密鍵を用意（B64 はテンポラリへ展開。FILE 優先）
  keyfile="" tmpkey=""
  if [ -n "${GITHUB_APP_PRIVATE_KEY_FILE:-}" ]; then
    keyfile="$GITHUB_APP_PRIVATE_KEY_FILE"
  else
    tmpkey="$(mktemp)"; chmod 600 "$tmpkey"
    printf '%s' "$GITHUB_APP_PRIVATE_KEY_B64" | base64 -d > "$tmpkey" 2>/dev/null \
      || { err "GITHUB_APP_PRIVATE_KEY_B64 を base64 デコードできません"; rm -f "$tmpkey"; exit 1; }
    keyfile="$tmpkey"
  fi
  [ -r "$keyfile" ] || { err "秘密鍵を読めません: $keyfile"; [ -n "$tmpkey" ] && rm -f "$tmpkey"; exit 1; }

  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

  # JWT（RS256, exp は最大10分。iss は App ID）
  now=$(date +%s)
  header='{"alg":"RS256","typ":"JWT"}'
  payload="{\"iat\":$((now-60)),\"exp\":$((now+540)),\"iss\":\"$GITHUB_APP_ID\"}"
  unsigned="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
  sig=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$keyfile" -binary | b64url)
  jwt="$unsigned.$sig"
  [ -n "$tmpkey" ] && rm -f "$tmpkey"

  api() { curl -sS -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
              -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

  # installation id: 明示指定 > キャッシュ > 対象 repo から解決
  inst="${GITHUB_APP_INSTALLATION_ID:-}"
  [ -z "$inst" ] && [ -f "$INST_CACHE" ] && inst="$(cat "$INST_CACHE" 2>/dev/null || true)"
  if [ -z "$inst" ]; then
    # clone 前でも引けるよう TARGET_REPO_URL から slug を割り出す
    slug=$(printf '%s' "${TARGET_REPO_URL:-}" | sed -E 's#.*github\.com[:/]##; s#\.git$##')
    [ -n "$slug" ] || { err "installation id を解決できません（TARGET_REPO_URL 未設定）"; exit 1; }
    inst=$(api "https://api.github.com/repos/$slug/installation" | jq -r '.id // empty')
    [ -n "$inst" ] || { err "App が repo '$slug' に install されていない可能性があります"; exit 1; }
    printf '%s' "$inst" > "$INST_CACHE"
  fi

  resp=$(api -X POST "https://api.github.com/app/installations/$inst/access_tokens")
  tok=$(jq -r '.token // empty' <<<"$resp")
  exp_iso=$(jq -r '.expires_at // empty' <<<"$resp")
  [ -n "$tok" ] || { err "installation token を取得できません: $(jq -r '.message // .' <<<"$resp" 2>/dev/null)"; exit 1; }

  exp_epoch=$(date -d "$exp_iso" +%s 2>/dev/null || echo $(( $(date +%s) + 3000 )))
  ( umask 177; printf '%s %s\n' "$exp_epoch" "$tok" > "$CACHE" )   # mode 600 で保存
  emit "$tok"; exit 0
fi

# ── 静的トークンモード（PAT / machine user）────────────────
if [ -n "${GH_TOKEN:-}" ]; then
  emit "$GH_TOKEN"; exit 0
fi

err "認証情報がありません。.env に GITHUB_APP_ID(+鍵) か GH_TOKEN を設定してください。"
exit 1
