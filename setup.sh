#!/bin/bash

# NDLOCR-Lite API Setup Script
# OCRプロセッサとAPIサーバーを簡単にセットアップ・実行するためのスクリプト

set -e  # エラーが発生した場合はスクリプトを終了

# 色の定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ログ出力関数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# プロジェクトディレクトリの確認
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

NDLOCR_LITE_REPO="https://github.com/ndl-lab/ndlocr-lite"
NDLOCR_LITE_DIR="$PROJECT_DIR/extern/ndlocr-lite"

log_info "NDLOCR-Lite API セットアップを開始します..."
log_info "プロジェクトディレクトリ: $PROJECT_DIR"

# ヘルプ表示
show_help() {
    echo "NDLOCR-Lite API Setup Script"
    echo ""
    echo "使用法:"
    echo "  ./setup.sh [command] [options]"
    echo "  API_PORT=3000 ./setup.sh start    # ポート指定"
    echo "  API_HOST=127.0.0.1 ./setup.sh start  # 待受アドレス指定"
    echo ""
    echo "コマンド:"
    echo "  install     - NDLOCR-Liteの取得 + 依存関係をインストール"
    echo "  init        - ディレクトリを初期化"
    echo "  start       - OCRプロセッサとAPIサーバーを起動"
    echo "  stop        - 実行中のサービスを停止"
    echo "  restart     - サービスを再起動"
    echo "  status      - サービスの状態を確認"
    echo "  setup       - インストールと初期化を実行"
    echo "  test        - テスト用画像でOCRを実行"
    echo "  clean       - 一時ファイルを削除"
    echo "  autostart-enable  - OS起動時の自動起動を有効化（systemd ユーザーサービス）"
    echo "  autostart-disable - 自動起動を無効化してサービスを停止"
    echo "  help        - このヘルプを表示"
    echo ""
    echo "例:"
    echo "  ./setup.sh setup              # 初回セットアップ"
    echo "  ./setup.sh start              # サービス起動（ポート8000）"
    echo "  API_PORT=8001 ./setup.sh start  # ポート8001で起動"
    echo "  API_HOST=dual ./setup.sh start  # IPv4/IPv6で待受（デフォルト）"
    echo "  ./setup.sh test               # テスト実行"
}

# Pythonの確認（NDLOCR-Liteの動作にはPython 3.10以上が必要）
check_python() {
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3が見つかりません。Python 3をインストールしてください。"
        exit 1
    fi

    PYTHON_VERSION=$(python3 --version | cut -d' ' -f2)
    log_info "Python バージョン: $PYTHON_VERSION"

    PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d'.' -f1)
    PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d'.' -f2)
    if [ "$PYTHON_MAJOR" -lt 3 ] || { [ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 10 ]; }; then
        log_error "NDLOCR-LiteにはPython 3.10以上が必要です（検出: $PYTHON_VERSION）。"
        exit 1
    fi

    if ! command -v pip3 &> /dev/null; then
        log_error "pip3が見つかりません。pipをインストールしてください。"
        exit 1
    fi
}

# システム依存関係の確認とインストール
install_system_dependencies() {
    log_info "システム依存関係を確認中..."

    # Ubuntu/Debian系の場合
    if command -v apt-get &> /dev/null; then
        # poppler-utilsの確認（PDF変換用）
        if ! dpkg -l | grep -q poppler-utils; then
            log_warning "poppler-utilsが見つかりません。インストールを試行します..."
            sudo apt-get update && sudo apt-get install -y poppler-utils
        fi

        # libgl1 / libglib2.0（OpenCV用、NDLOCR-Liteの内部推論処理が使用）
        if ! dpkg -l | grep -q libgl1; then
            log_warning "OpenCV用のライブラリをインストールします..."
            sudo apt-get install -y libglib2.0-0 libgl1
        fi

        if ! command -v git &> /dev/null; then
            log_warning "gitが見つかりません。インストールを試行します..."
            sudo apt-get install -y git
        fi

    # macOS（Homebrew）の場合
    elif command -v brew &> /dev/null; then
        if ! brew list poppler &> /dev/null; then
            log_warning "poppler が見つかりません。インストールを試行します..."
            brew install poppler
        fi

    else
        log_warning "パッケージマネージャーが見つかりません。手動でpoppler-utilsをインストールしてください。"
    fi
}

# NDLOCR-Lite本体（レイアウト検出・文字認識モデル一式）の取得
# リポジトリにONNXモデル（計150MB程度）が直接含まれているため、
# 自リポジトリには含めずextern/にクローンして参照する（fonts/と同様の運用）。
fetch_ndlocr_lite() {
    if [ -d "$NDLOCR_LITE_DIR" ]; then
        log_info "NDLOCR-Liteは既に取得済みです: $NDLOCR_LITE_DIR"
        return 0
    fi

    log_info "NDLOCR-Liteを取得中... ($NDLOCR_LITE_REPO)"
    mkdir -p "$PROJECT_DIR/extern"
    git clone --depth 1 "$NDLOCR_LITE_REPO" "$NDLOCR_LITE_DIR"
    log_success "NDLOCR-Liteの取得が完了しました"
}

# Python依存関係のインストール
install_python_dependencies() {
    log_info "Python依存関係をインストール中..."

    # 仮想環境の作成（オプション）
    if [ ! -d "venv" ]; then
        log_info "仮想環境を作成中..."
        python3 -m venv venv
    fi

    # 仮想環境のアクティベート
    source venv/bin/activate

    # 依存関係のインストール（APIサーバー側 + NDLOCR-Lite本体）
    pip install --upgrade pip
    pip install -r requirements.txt
    pip install -r "$NDLOCR_LITE_DIR/requirements.txt"

    log_success "Python依存関係のインストールが完了しました"
}

# ディレクトリの初期化
initialize_directories() {
    log_info "ディレクトリを初期化中..."

    # 必要なディレクトリを作成
    directories=("images" "process" "result" "uploads" "logs")
    for dir in "${directories[@]}"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            log_info "ディレクトリを作成: $dir"
        fi
    done

    # .gitkeepファイルの作成
    for dir in "${directories[@]}"; do
        touch "$dir/.gitkeep"
    done

    log_success "ディレクトリの初期化が完了しました"
}

# PIDファイルの管理
PID_DIR="$PROJECT_DIR/logs"
OCR_PID_FILE="$PID_DIR/ocr_processor.pid"
API_PID_FILE="$PID_DIR/api_server.pid"
API_IPV4_PID_FILE="$PID_DIR/api_server_ipv4.pid"
API_IPV6_PID_FILE="$PID_DIR/api_server_ipv6.pid"

# dual は IPv4/IPv6 用に API プロセスを1つずつ起動する
API_HOST="${API_HOST:-dual}"
API_PORT="${API_PORT:-8000}"

is_running() {
    local pid_file="$1"
    [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null
}

start_api_instance() {
    local label="$1"
    local host="$2"
    local pid_file="$3"
    local log_file="$4"

    if ! is_running "$pid_file"; then
        log_info "APIサーバー（$label）を起動中..."
        nohup python3 api_server.py --host "$host" --port "$API_PORT" > "$log_file" 2>&1 &
        echo $! > "$pid_file"
        log_success "APIサーバー（$label）が起動しました (PID: $(cat "$pid_file"))"
    else
        log_warning "APIサーバー（$label）は既に起動しています"
    fi
}

# サービスの起動
start_services() {
    log_info "サービスを起動中..."

    # 仮想環境のアクティベート
    if [ -d "venv" ]; then
        source venv/bin/activate
    fi

    # OCRプロセッサの起動
    if [ ! -f "$OCR_PID_FILE" ] || ! kill -0 $(cat "$OCR_PID_FILE" 2>/dev/null) 2>/dev/null; then
        log_info "OCRプロセッサを起動中（モデル読み込みに数十秒かかる場合があります）..."
        nohup python3 ocr_processor.py > logs/ocr_processor.log 2>&1 &
        echo $! > "$OCR_PID_FILE"
        log_success "OCRプロセッサが起動しました (PID: $(cat $OCR_PID_FILE))"
    else
        log_warning "OCRプロセッサは既に起動しています"
    fi

    # APIサーバーの起動
    if [ "$API_HOST" = "dual" ]; then
        start_api_instance "IPv4" "0.0.0.0" "$API_IPV4_PID_FILE" "logs/api_server_ipv4.log"
        start_api_instance "IPv6" "::" "$API_IPV6_PID_FILE" "logs/api_server_ipv6.log"
        log_info "IPv4 URL: http://127.0.0.1:$API_PORT"
        log_info "IPv6 URL: http://[::1]:$API_PORT"
    else
        start_api_instance "$API_HOST" "$API_HOST" "$API_PID_FILE" "logs/api_server.log"
        log_info "待受アドレス: $API_HOST:$API_PORT"
    fi
    log_info "Swagger UI: http://localhost:$API_PORT/docs"

    sleep 2
    show_status
}

# サービスの停止
stop_services() {
    log_info "サービスを停止中..."

    # OCRプロセッサの停止
    if [ -f "$OCR_PID_FILE" ] && kill -0 $(cat "$OCR_PID_FILE" 2>/dev/null) 2>/dev/null; then
        kill $(cat "$OCR_PID_FILE")
        rm -f "$OCR_PID_FILE"
        log_success "OCRプロセッサを停止しました"
    else
        log_warning "OCRプロセッサは起動していません"
    fi

    # APIサーバーの停止（旧形式のPIDファイルも対象にする）
    local api_stopped=false
    for pid_file in "$API_PID_FILE" "$API_IPV4_PID_FILE" "$API_IPV6_PID_FILE"; do
        if is_running "$pid_file"; then
            kill "$(cat "$pid_file")"
            api_stopped=true
        fi
        rm -f "$pid_file"
    done
    if [ "$api_stopped" = true ]; then
        log_success "APIサーバーを停止しました"
    else
        log_warning "APIサーバーは起動していません"
    fi
}

# サービスの状態確認
show_status() {
    log_info "サービスの状態を確認中..."

    # systemd 管理時はPIDファイルを使わないため、プロセス状態は autostart_status 側で表示する
    if autostart_active; then
        show_connectivity
        return
    fi

    # OCRプロセッサの状態
    if [ -f "$OCR_PID_FILE" ] && kill -0 $(cat "$OCR_PID_FILE" 2>/dev/null) 2>/dev/null; then
        log_success "OCRプロセッサ: 起動中 (PID: $(cat $OCR_PID_FILE))"
    else
        log_warning "OCRプロセッサ: 停止中"
    fi

    # APIサーバーの状態
    if is_running "$API_IPV4_PID_FILE"; then
        log_success "APIサーバー（IPv4）: 起動中 (PID: $(cat "$API_IPV4_PID_FILE"))"
    elif [ "$API_HOST" = "dual" ]; then
        log_warning "APIサーバー（IPv4）: 停止中"
    fi
    if is_running "$API_IPV6_PID_FILE"; then
        log_success "APIサーバー（IPv6）: 起動中 (PID: $(cat "$API_IPV6_PID_FILE"))"
    elif [ "$API_HOST" = "dual" ]; then
        log_warning "APIサーバー（IPv6）: 停止中"
    fi
    if is_running "$API_PID_FILE"; then
        log_success "APIサーバー: 起動中 (PID: $(cat "$API_PID_FILE"))"
    fi

    show_connectivity
}

# APIへの疎通確認
show_connectivity() {
    if command -v curl &> /dev/null; then
        if curl --noproxy "*" -4 -s "http://127.0.0.1:$API_PORT/" > /dev/null; then
            log_success "APIサーバーにIPv4で接続できます"
        else
            log_warning "APIサーバーにIPv4で接続できません"
        fi
        if curl --noproxy "*" -6 -g -s "http://[::1]:$API_PORT/" > /dev/null; then
            log_success "APIサーバーにIPv6で接続できます"
        else
            log_warning "APIサーバーにIPv6で接続できません"
        fi
    fi
}

# テスト用画像でOCRを実行
run_test() {
    log_info "テスト用画像でOCRを実行中..."

    # テスト用の画像を作成（簡単なテキスト画像）
    if command -v convert &> /dev/null; then
        convert -size 400x100 -background white -fill black -font Arial -pointsize 24 -gravity center label:"Hello World テスト" images/test_image.png
        log_info "テスト画像を作成: images/test_image.png"
    else
        log_warning "ImageMagickが見つかりません。手動でテスト画像をimagesフォルダに配置してください。"
        return 1
    fi

    # サービスが起動しているか確認
    if [ ! -f "$OCR_PID_FILE" ] || ! kill -0 $(cat "$OCR_PID_FILE" 2>/dev/null) 2>/dev/null; then
        log_warning "OCRプロセッサが起動していません。起動します..."
        start_services
        sleep 3
    fi

    # 処理完了まで待機（ファイル名にはtimestamp_uuid_のprefixが付与されるためglobで検索）
    log_info "OCR処理の完了を待機中..."
    for i in {1..30}; do
        processed_file=$(ls process/*_processed_test_image.png 2>/dev/null | head -1)
        result_file=$(ls result/*_result_test_image.csv 2>/dev/null | head -1)
        if [ -n "$processed_file" ] && [ -n "$result_file" ]; then
            log_success "OCR処理が完了しました！"
            log_info "処理済み画像: $processed_file"
            log_info "結果CSV: $result_file"

            log_info "検出されたテキスト:"
            cat "$result_file"
            return 0
        fi
        sleep 1
    done

    log_warning "OCR処理が完了しませんでした。ログを確認してください（logs/ocr_processor.log）。"
}

# ===== 自動起動（systemd ユーザーサービス） =====
# OS再起動後もログインなしで起動するよう、systemd --user のユニットを生成し linger を有効化する。
# ユニットはプロセスを直接管理する（PIDファイルは使わない）。異常終了時は自動で再起動される。
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SYSTEMD_TARGET="ndlocr-api.target"
SYSTEMD_OCR_UNIT="ndlocr-api-ocr.service"

autostart_active() {
    command -v systemctl &> /dev/null && systemctl --user is-active --quiet "$SYSTEMD_TARGET" 2>/dev/null
}

# $1: ユニット名, $2: 説明, $3: ExecStartの引数（venvのpythonに渡す）, $4: ログファイル名
write_service_unit() {
    cat > "$SYSTEMD_USER_DIR/$1" <<EOF
# setup.sh autostart-enable により自動生成（手動編集しないでください）
[Unit]
Description=$2
PartOf=$SYSTEMD_TARGET
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$PROJECT_DIR
Environment=PYTHONUNBUFFERED=1
ExecStart=$PROJECT_DIR/venv/bin/python $3
StandardOutput=append:$PROJECT_DIR/logs/$4
StandardError=inherit
Restart=on-failure
RestartSec=5

[Install]
WantedBy=$SYSTEMD_TARGET
EOF
}

autostart_enable() {
    if ! command -v systemctl &> /dev/null; then
        log_error "systemctl が見つかりません。systemd 環境でのみ利用できます。"
        exit 1
    fi
    if [ ! -x "$PROJECT_DIR/venv/bin/python" ]; then
        log_error "venv が見つかりません。先に ./setup.sh setup を実行してください。"
        exit 1
    fi
    if [ ! -d "$NDLOCR_LITE_DIR" ]; then
        log_error "NDLOCR-Lite が見つかりません。先に ./setup.sh install を実行してください。"
        exit 1
    fi
    initialize_directories

    # 手動起動中のプロセスがあるとポートが競合するため停止する
    if is_running "$OCR_PID_FILE" || is_running "$API_PID_FILE" || is_running "$API_IPV4_PID_FILE" || is_running "$API_IPV6_PID_FILE"; then
        log_info "手動起動中のサービスを停止し、systemd 管理に切り替えます..."
        stop_services
    fi

    mkdir -p "$SYSTEMD_USER_DIR"

    # 以前の設定（異なるAPI_HOST）で作られたAPIユニットを掃除
    systemctl --user disable --now "ndlocr-api-server"*.service 2>/dev/null || true
    rm -f "$SYSTEMD_USER_DIR"/ndlocr-api-server*.service

    write_service_unit "$SYSTEMD_OCR_UNIT" "NDLOCR-Lite OCR processor" \
        "ocr_processor.py" "ocr_processor.log"

    local units=("$SYSTEMD_OCR_UNIT")
    if [ "$API_HOST" = "dual" ]; then
        write_service_unit "ndlocr-api-server-ipv4.service" "NDLOCR-Lite API server (IPv4, port $API_PORT)" \
            "api_server.py --host 0.0.0.0 --port $API_PORT" "api_server_ipv4.log"
        write_service_unit "ndlocr-api-server-ipv6.service" "NDLOCR-Lite API server (IPv6, port $API_PORT)" \
            "api_server.py --host :: --port $API_PORT" "api_server_ipv6.log"
        units+=("ndlocr-api-server-ipv4.service" "ndlocr-api-server-ipv6.service")
    else
        write_service_unit "ndlocr-api-server.service" "NDLOCR-Lite API server ($API_HOST, port $API_PORT)" \
            "api_server.py --host $API_HOST --port $API_PORT" "api_server.log"
        units+=("ndlocr-api-server.service")
    fi

    cat > "$SYSTEMD_USER_DIR/$SYSTEMD_TARGET" <<EOF
# setup.sh autostart-enable により自動生成（手動編集しないでください）
[Unit]
Description=NDLOCR-Lite API (OCR processor + API server)

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable "${units[@]}" "$SYSTEMD_TARGET"
    systemctl --user restart "$SYSTEMD_TARGET"

    # linger: ログインしていなくても、OS起動時にユーザーのsystemdを起動する
    if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
        log_info "linger を有効化します（ログインなしでの起動に必要）..."
        if ! loginctl enable-linger "$USER" 2>/dev/null; then
            log_warning "linger の有効化に失敗しました。次を手動で実行してください: sudo loginctl enable-linger $USER"
        fi
    fi

    log_success "自動起動を有効化しました（ポート: $API_PORT, 待受: $API_HOST）"
    log_info "状態確認: systemctl --user status '$SYSTEMD_TARGET' 'ndlocr-api-*'"
    log_info "停止/起動: systemctl --user stop|start $SYSTEMD_TARGET"
    sleep 2
    autostart_status
}

autostart_disable() {
    if ! command -v systemctl &> /dev/null; then
        log_error "systemctl が見つかりません。"
        exit 1
    fi
    systemctl --user stop "$SYSTEMD_TARGET" 2>/dev/null || true
    systemctl --user disable "$SYSTEMD_TARGET" "$SYSTEMD_OCR_UNIT" "ndlocr-api-server"*.service 2>/dev/null || true
    rm -f "$SYSTEMD_USER_DIR/$SYSTEMD_TARGET" "$SYSTEMD_USER_DIR/$SYSTEMD_OCR_UNIT" "$SYSTEMD_USER_DIR"/ndlocr-api-server*.service
    systemctl --user daemon-reload
    log_success "自動起動を無効化し、サービスを停止しました"
    log_info "linger は他のユーザーサービスに影響するため変更していません（不要なら: loginctl disable-linger $USER）"
}

autostart_status() {
    systemctl --user --no-pager status "$SYSTEMD_TARGET" "$SYSTEMD_OCR_UNIT" "ndlocr-api-server*.service" 2>/dev/null | grep -E "^[●○×] |Active:" || true
    log_info "linger: $(loginctl show-user "$USER" -p Linger --value 2>/dev/null)"
}

# 一時ファイルの削除
clean_temp_files() {
    log_info "一時ファイルを削除中..."

    # 各ディレクトリの内容を削除（.gitkeepは保持）
    for dir in images process result uploads; do
        if [ -d "$dir" ]; then
            find "$dir" -type f ! -name '.gitkeep' -delete
            log_info "$dir ディレクトリをクリーンアップしました"
        fi
    done

    # ログファイルをクリーンアップ
    if [ -d "logs" ]; then
        find logs -name "*.log" -delete
        log_info "ログファイルをクリーンアップしました"
    fi

    log_success "クリーンアップが完了しました"
}

# メイン処理
case "${1:-help}" in
    "install")
        check_python
        install_system_dependencies
        fetch_ndlocr_lite
        install_python_dependencies
        ;;
    "init")
        initialize_directories
        ;;
    "start"|"stop"|"restart")
        if autostart_active; then
            log_warning "サービスは systemd（自動起動）で管理されています。"
            log_info "代わりに次を使用してください: systemctl --user $1 $SYSTEMD_TARGET"
            exit 1
        fi
        case "$1" in
            "start") start_services ;;
            "stop") stop_services ;;
            "restart") stop_services; sleep 2; start_services ;;
        esac
        ;;
    "status")
        if autostart_active; then
            log_info "systemd（自動起動）で管理されています"
            autostart_status
        fi
        show_status
        ;;
    "autostart-enable")
        autostart_enable
        ;;
    "autostart-disable")
        autostart_disable
        ;;
    "setup")
        check_python
        install_system_dependencies
        fetch_ndlocr_lite
        install_python_dependencies
        initialize_directories
        log_success "セットアップが完了しました！"
        log_info "サービスを開始するには: ./setup.sh start"
        ;;
    "test")
        run_test
        ;;
    "clean")
        clean_temp_files
        ;;
    "help"|*)
        show_help
        ;;
esac
