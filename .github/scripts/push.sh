#!/usr/bin/env bash
# =============================================================================
# 将 images.txt 中列出的镜像转存到阿里云容器镜像服务（ACR）
#
# 与上游实现的差异：
#   1. 逐条处理：单个镜像失败不再中断整批（上游依赖 bash -e，第一个失败就全挂）；
#   2. 结束有汇总（控制台 + GitHub Step Summary），一眼能看出哪几条失败；
#   3. Secrets 缺失、登录失败时给出明确原因，不再只丢一行 docker 报错；
#   4. 密码改用 --password-stdin 传递，不再出现在命令行/进程列表里；
#   5. 兼容 CRLF 清单文件，避免 Windows 下编辑引入 \r 导致 invalid reference format。
#
# 退出码：0 = 全部成功；1 = 有镜像失败或前置检查不通过。
# =============================================================================
set -uo pipefail   # 刻意不加 -e：本脚本要逐条容错，失败统一在结尾汇总

cd "$(dirname "$0")/../.." || exit 1

IMAGES_FILE="${IMAGES_FILE:-images.txt}"
failed=()
succeeded=0

err()  { printf '::error::%s\n' "$*" >&2; }
warn() { printf '::warning::%s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

# ----------------------------------------------------------------- 解析工具
# 取镜像引用：行的最后一个字段（跳过 --platform=xxx 这类前置参数）
image_ref()  { awk '{print $NF}' <<<"$1"; }
# 去掉 @sha256:... 摘要
strip_digest() { printf '%s' "${1%%@*}"; }
# 取「镜像名:tag」，例如 kasmweb/nginx:1.25.3
name_tag()   { awk -F'/' '{print $NF}' <<<"$1"; }
# 取命名空间；docker.io/nginx 这种两段式把 docker.io 也当命名空间（沿用原有命名规则）
namespace_of() { awk -F'/' '{if (NF==3) print $2; else if (NF==2) print $1; else print ""}' <<<"$1"; }
# 取不带 tag 的纯镜像名
base_name()  { awk -F':' '{print $1}' <<<"$1"; }
# 取 --platform 参数值，例如 linux/arm64
platform_of() { awk -F'--platform[ =]' '{if (NF>1) print $2}' <<<"$1" | awk '{print $1}'; }

# ----------------------------------------------------------------- 前置校验
info "=============================================================="
info "工作目录：$(pwd)"
info "镜像清单：$IMAGES_FILE"
info "=============================================================="

if [[ ! -f "$IMAGES_FILE" ]]; then
    err "找不到清单文件 $IMAGES_FILE"
    exit 1
fi

missing=()
for key in ALIYUN_REGISTRY ALIYUN_NAME_SPACE ALIYUN_REGISTRY_USER ALIYUN_REGISTRY_PASSWORD; do
    [[ -n "${!key:-}" ]] || missing+=("$key")
done
if (( ${#missing[@]} > 0 )); then
    err "以下 Secrets 缺失或为空：${missing[*]}"
    err "请到 Settings -> Secrets and variables -> Actions 补齐后重跑。"
    exit 1
fi

# ----------------------------------------------------------------- 读取清单
# 去掉 BOM / CRLF / 首尾空白，跳过空行与 # 注释
mapfile -t lines < <(
    sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$IMAGES_FILE" \
        | grep -v -e '^$' -e '^#'
)

if (( ${#lines[@]} == 0 )); then
    warn "$IMAGES_FILE 里没有有效镜像，什么也不做。"
    exit 0
fi
info "共读到 ${#lines[@]} 条镜像待处理"

# ------------------------------------------------- 预处理：判断镜像是否重名
declare -A first_ns=()
declare -A duplicate=()
for line in "${lines[@]}"; do
    ref=$(strip_digest "$(image_ref "$line")")
    img_name=$(base_name "$(name_tag "$ref")")
    ns=$(namespace_of "$ref")
    ns="${ns}_"                     # 空命名空间也补一个下划线，避免空值影响比较
    if [[ -n "${first_ns[$img_name]:-}" ]]; then
        # 同名镜像出现了第二个命名空间，双方都要加前缀区分
        if [[ "${first_ns[$img_name]}" != "$ns" ]]; then
            duplicate[$img_name]=1
        fi
    else
        first_ns[$img_name]=$ns
    fi
done

# ------------------------------------------------------------------- 登录
info ""
info "登录 $ALIYUN_REGISTRY ..."
login_ok=0
for attempt in 1 2 3; do
    if printf '%s' "$ALIYUN_REGISTRY_PASSWORD" \
        | docker login "$ALIYUN_REGISTRY" --username "$ALIYUN_REGISTRY_USER" --password-stdin; then
        login_ok=1
        break
    fi
    warn "第 ${attempt} 次登录失败，5 秒后重试"
    sleep 5
done

if (( login_ok == 0 )); then
    err "登录 $ALIYUN_REGISTRY 失败，整批中止。常见原因："
    err "  1) ALIYUN_REGISTRY / ALIYUN_REGISTRY_USER / ALIYUN_REGISTRY_PASSWORD 配错或被重置；"
    err "  2) 阿里云容器镜像服务「个人实例」被冻结或释放（长期不使用会被冻结，需到控制台重新启用）；"
    err "  3) Runner 网络无法访问 $ALIYUN_REGISTRY。"
    exit 1
fi
info "登录成功"

# ------------------------------------------------------------------- 主流程
# 拉取重试：Docker Hub 偶发限流/抖动时给一次机会
pull_with_retry() {
    local feed_line=$1 attempt
    for attempt in 1 2; do
        # shellcheck disable=SC2086  # 需要按空格拆分，第二段可能带 --platform=xxx
        if docker pull $feed_line; then
            return 0
        fi
        warn "拉取失败（第 ${attempt} 次）：$feed_line"
        (( attempt < 2 )) && sleep 5
    done
    return 1
}

idx=0
for line in "${lines[@]}"; do
    idx=$((idx + 1))
    info ""
    info "--------------------------------------------------------------"
    info "[$idx/${#lines[@]}] $line"

    if ! pull_with_retry "$line"; then
        err "[$idx] 拉取失败：$line"
        failed+=("$line（拉取失败）")
        continue
    fi

    # 架构前缀：--platform=linux/arm64 -> linux_arm64_
    platform=$(platform_of "$line")
    if [[ -z "$platform" ]]; then
        platform_prefix=""
    else
        platform_prefix="${platform//\//_}_"
    fi

    # 目标名沿用上游规则：平台前缀 + (重名时的)命名空间前缀 + 镜像名:tag
    src_ref=$(image_ref "$line")
    src_name_tag=$(name_tag "$src_ref")          # 可能带 @sha256
    src_name=$(base_name "$src_name_tag")
    clean_name_tag="${src_name_tag%%@*}"         # 去掉摘要，保留 tag

    ns=$(namespace_of "$(strip_digest "$src_ref")")
    ns_prefix=""
    if [[ -n "${duplicate[$src_name]:-}" && -n "$ns" ]]; then
        ns_prefix="${ns}_"
    fi

    new_image="$ALIYUN_REGISTRY/$ALIYUN_NAME_SPACE/${platform_prefix}${ns_prefix}${clean_name_tag}"

    info "  -> $new_image"
    if ! docker tag "$src_ref" "$new_image"; then
        err "[$idx] 打 tag 失败：$src_ref -> $new_image"
        failed+=("$line（打 tag 失败）")
        continue
    fi

    if ! docker push "$new_image"; then
        err "[$idx] 推送失败：$new_image"
        failed+=("$line（推送失败）")
        continue
    fi

    succeeded=$((succeeded + 1))
    info "[$idx] 推送成功：$new_image"

    # 及时清理，避免大镜像把磁盘吃满；清理失败不影响结果
    docker rmi "$new_image" >/dev/null 2>&1 || true
    docker rmi "$src_ref"  >/dev/null 2>&1 || true
done

# ------------------------------------------------------------------- 汇总
info ""
info "=============================================================="
info "完成：成功 ${succeeded} / 失败 ${#failed[@]} / 共 ${#lines[@]}"
for item in "${failed[@]:-}"; do
    [[ -n "$item" ]] && info "  ✗ $item"
done
info "=============================================================="

# 写到 GitHub Actions 运行摘要页面，方便不翻日志就能看到结果
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## 镜像转存结果"
        echo ""
        echo "成功 **${succeeded}** / 失败 **${#failed[@]}** / 共 **${#lines[@]}**"
        echo ""
        if (( ${#failed[@]} > 0 )); then
            echo "| 失败的镜像 |"
            echo "| --- |"
            for item in "${failed[@]}"; do
                echo "| \`${item}\` |"
            done
        fi
    } >> "$GITHUB_STEP_SUMMARY"
fi

if (( ${#failed[@]} > 0 )); then
    err "有 ${#failed[@]} 个镜像未完成，见上方汇总。"
    exit 1
fi

docker system prune -f >/dev/null 2>&1 || true
info "全部镜像转存完成"
exit 0
