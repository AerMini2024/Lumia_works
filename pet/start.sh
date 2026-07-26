#!/usr/bin/env bash
# Lumia 桌宠统一启动脚本（Ubuntu）
#
# 用法:
#   bash start.sh            前台启动（默认，日志打印到终端）
#   bash start.sh start      后台启动（nohup 到 nohup.log，先杀旧实例）
#   bash start.sh stop       停止正在运行的桌宠
#   bash start.sh status     查看进程与日志尾部
#   bash start.sh restart    等价于 stop + start
#
# 可选环境变量:
#   PIP_INDEX_URL   指定 pip 镜像源（测试机建议清华源）
#   LUMIA_DEBUG=1   附加 --debug 输出 DEBUG 日志（后台模式默认开启）
set -euo pipefail

# 无论从何处调用都定位到脚本所在目录（桌宠根目录）
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$PROJECT_ROOT/.venv"
PY="$VENV/bin/python"
NOHUP_LOG="$PROJECT_ROOT/nohup.log"
APP_LOG="$HOME/.local/share/lumia-pet/logs/lumia.log"
cd "$PROJECT_ROOT"

info() { echo -e "\033[32m[start.sh]\033[0m $*"; }
warn() { echo -e "\033[33m[start.sh]\033[0m $*"; }
fail() { echo -e "\033[31m[start.sh]\033[0m $*"; exit 1; }

# --- 子命令：停止 / 状态 ---

stop_pet() {
    if pkill -f 'main\.py' 2>/dev/null; then
        info "已停止桌宠"
    else
        warn "未发现运行中的桌宠"
    fi
}

show_status() {
    echo "=== 进程 ==="
    pgrep -af 'main\.py' || echo "<未运行>"
    echo "=== 应用日志尾部 ==="
    tail -n 20 "$APP_LOG" 2>/dev/null || echo "<无日志>"
}

# --- 环境准备（venv / 依赖 / 系统库 / 素材 / 会话）---

prepare_env() {
    # 1. python3 与 venv 模块
    command -v python3 >/dev/null 2>&1 || fail "未找到 python3，请执行: sudo apt install python3"
    python3 -c "import venv" 2>/dev/null || fail "缺少 venv 模块，请执行: sudo apt install python3-venv"

    # 2. 虚拟环境 + 依赖（依赖齐全则跳过 pip，加速二次启动）
    if [ ! -x "$PY" ]; then
        info "创建虚拟环境 $VENV ..."
        python3 -m venv "$VENV"
    fi
    if "$PY" -c "import PyQt6, PIL" 2>/dev/null; then
        info "依赖已就绪，跳过安装"
    else
        info "安装 Python 依赖 ..."
        "$VENV/bin/pip" install --disable-pip-version-check -q -r requirements.txt \
            || fail "pip 安装失败。网络不佳可设置: export PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple"
    fi

    # 3. PyQt6 依赖的 libxcb-cursor0；缺失时免 root 下载解压到项目 .libs
    if ! ldconfig -p 2>/dev/null | grep -q "libxcb-cursor.so.0"; then
        local libdir="$PROJECT_ROOT/.libs"
        local sofile
        sofile=$(ls "$libdir"/usr/lib/*/libxcb-cursor.so.0 2>/dev/null | head -1 || true)
        if [ -z "$sofile" ]; then
            warn "系统缺少 libxcb-cursor0，尝试免 root 获取到 $libdir ..."
            mkdir -p "$libdir"
            ( cd "$libdir" && apt-get download libxcb-cursor0 2>/dev/null \
                && dpkg -x libxcb-cursor0_*.deb . && rm -f libxcb-cursor0_*.deb ) \
                || warn "免 root 获取失败，如报 xcb 错误请执行: sudo apt install libxcb-cursor0"
            sofile=$(ls "$libdir"/usr/lib/*/libxcb-cursor.so.0 2>/dev/null | head -1 || true)
        fi
        if [ -n "$sofile" ]; then
            export LD_LIBRARY_PATH="$(dirname "$sofile")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            info "已加载项目级 libxcb-cursor0: $sofile"
        fi
    fi

    # 4. 素材缺失时自动生成
    if [ ! -f "assets/sprites/meta.json" ]; then
        info "素材未生成，运行贴图管线 ..."
        "$PY" scripts/build_cat_sprites.py
    fi

    # 5. Wayland 会话走 XWayland（main.py 内也有兜底）
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        export QT_QPA_PLATFORM=xcb
        info "Wayland 会话：已设置 QT_QPA_PLATFORM=xcb"
    fi
}

# --- 主流程 ---

ACTION="${1:-run}"
case "$ACTION" in
    stop)
        stop_pet
        exit 0
        ;;
    status)
        show_status
        exit 0
        ;;
    restart)
        stop_pet
        sleep 1
        ;&  # 贯穿到 start
    start)
        prepare_env
        pkill -f 'main\.py' 2>/dev/null && { info "已清理旧实例"; sleep 1; } || true
        info "后台启动 Lumia 桌宠 ..."
        nohup "$PY" main.py --debug > "$NOHUP_LOG" 2>&1 &
        sleep 6
        info "nohup.log 尾部："
        tail -n 25 "$NOHUP_LOG" 2>/dev/null || true
        ;;
    run)
        prepare_env
        # 前台运行；LUMIA_DEBUG=1 时附加 --debug
        DEBUG_FLAG=""
        [ "${LUMIA_DEBUG:-0}" = "1" ] && DEBUG_FLAG="--debug"
        info "前台启动 Lumia 桌宠 ..."
        exec "$PY" main.py $DEBUG_FLAG
        ;;
    *)
        fail "未知命令: $ACTION（可用: run|start|stop|status|restart）"
        ;;
esac
