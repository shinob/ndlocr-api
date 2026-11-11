# NDLOCR-Lite API

[NDLOCR-Lite](https://github.com/ndl-lab/ndlocr-lite)（国立国会図書館ラボ公開・CC BY 4.0）を使用した
画像・PDFのOCR処理を行うWeb APIサービスです。ファイルのアップロード、OCR処理、結果の取得を
シンプルなREST APIで提供します。[easyocr-api](../easyocr-api) と同じアーキテクチャ・APIの上で、
OCRエンジンをNDLOCR-Liteに差し替えています。

## 特徴

- 📝 **日本語OCR特化**: NDL資料（古典籍・古い雑誌等）の縦書き・横書きに対応
- 🖥️ **GPU不要**: ONNX Runtimeによる軽量CPU推論
- 🗂️ **レイアウト解析**: 本文・キャプション・柱・ノンブル等のレイアウト種別を判定
- 📄 **PDF対応**: PDFファイルを自動的に画像に変換してOCR処理
- 🔄 **非同期処理**: ファイルアップロード後、バックグラウンドでOCR処理
- 📊 **結果可視化**: テキスト検出位置を矩形で囲んだ画像を生成
- 📈 **構造化データ**: 検出テキスト、位置情報、信頼度、縦書き判定、レイアウト種別をCSV形式で出力
- 🌐 **Web API**: FastAPIベースのRESTful API
- 🔧 **簡単セットアップ**: ワンコマンドでセットアップ・起動

## システム構成

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   File Upload   │───▶│   API Server    │───▶│ OCR Processor   │
│                 │    │  (FastAPI)      │    │ (NDLOCR-Lite)   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                │                        │
                                ▼                        ▼
                       ┌─────────────────┐    ┌─────────────────┐
                       │   File Store    │    │    Results      │
                       │ (images/uploads)│    │ (process/result)│
                       └─────────────────┘    └─────────────────┘
```

APIサーバーとOCRワーカーは別プロセスで動作し、`images/`ディレクトリをファイルシステムキューとして
やり取りします（メッセージブローカーなし）。詳細は `project.md` / `CLAUDE.md` を参照してください。

## クイックスタート

### 1. セットアップ

```bash
# 自動セットアップ（NDLOCR-Liteの取得 + 依存関係インストール + 初期化）
./setup.sh setup
```

初回セットアップ時に `extern/ndlocr-lite`（NDLOCR-Lite本体、モデル込みで約150MB）を
GitHubからクローンします。ネットワーク接続が必要です。

### 2. サービス起動

```bash
# OCRプロセッサ + APIサーバーを起動
./setup.sh start

# サービス状態確認
./setup.sh status
```

OCRプロセッサはONNXモデルを起動時に一度だけ読み込むため、起動完了まで数十秒かかることがあります。

### 3. API使用

```bash
# ファイルアップロード
curl -X POST "http://localhost:8000/upload" \
  -F "file=@sample.jpg" \
  -F "email=user@example.com"

# 処理状況確認
curl "http://localhost:8000/status/20260821_141324_abcd1234_sample.jpg"

# 結果取得
curl "http://localhost:8000/result/20260821_141324_abcd1234_sample.jpg"
```

## ディレクトリ構造

```
ndlocr-api/
├── README.md              # このファイル
├── project.md             # プロジェクト仕様書（easyocr-api版との差分）
├── CLAUDE.md              # Claude Code向けガイド
├── requirements.txt       # Python依存関係（APIサーバー側）
├── setup.sh               # セットアップスクリプト
├── run.sh                 # API_PORT=3000での起動ショートカット
├── ocr_processor.py       # NDLOCR-Lite常駐ワーカー
├── api_server.py          # Web APIサーバー
├── images/                # OCR処理待ちファイル
├── process/               # 処理済み画像（矩形描画済み）
├── result/                # OCR結果CSV
├── uploads/                # アップロード一時保存
├── fonts/                  # 結果描画用の日本語フォント（自動DL・gitignore対象）
├── extern/ndlocr-lite/      # NDLOCR-Lite本体（`setup.sh install`でクローン・gitignore対象）
├── logs/
└── venv/                    # Python仮想環境
```

## API エンドポイント

### 📤 ファイルアップロード
```http
POST /upload
Content-Type: multipart/form-data

Parameters:
- file: 画像ファイル（jpg, jpeg, png, bmp, tiff, jp2, webp）または PDFファイル
- email: メールアドレス（オプション、保存のみで通知機能なし）
```

### 📊 処理状況確認
```http
GET /status/{filename}

Response:
{
  "filename": "20260821_141324_abcd1234_sample.jpg",
  "status": "completed",
  "has_processed_image": true,
  "has_result_csv": true
}
```

### 📋 結果取得
```http
GET /result/{filename}?result_type=both

Parameters:
- result_type: "image" | "text" | "both"

Response:
{
  "filename": "sample.jpg",
  "processed_image": "..._processed_sample.png",
  "ocr_results": [
    {
      "text": "...",
      "confidence": "0.987",
      "x1": "10", "y1": "20", "x2": "300", "y2": "45",
      "is_vertical": "False",
      "class_name": "line_main"
    }
  ],
  "result_csv": "..._result_sample.csv"
}
```

### 📥 ファイルダウンロード
```http
GET /download/image/{image_filename}  # 処理済み画像
GET /download/csv/{csv_filename}      # 結果CSV
```

## setup.sh コマンド

| コマンド | 説明 |
|---------|------|
| `./setup.sh install` | NDLOCR-Liteの取得（`extern/`）+ 依存関係インストール |
| `./setup.sh init` | ディレクトリ初期化 |
| `./setup.sh setup` | `install` + `init`（初回セットアップ） |
| `./setup.sh start` | サービス起動 |
| `./setup.sh stop` | サービス停止 |
| `./setup.sh restart` | サービス再起動 |
| `./setup.sh status` | サービス状態確認 |
| `./setup.sh test` | テスト用画像でOCR実行 |
| `./setup.sh clean` | 一時ファイル削除 |
| `./setup.sh autostart-enable` | OS起動時の自動起動を有効化（systemd ユーザーサービス + linger） |
| `./setup.sh autostart-disable` | 自動起動を無効化してサービス停止 |
| `./setup.sh help` | ヘルプ表示 |

### 自動起動（systemd）

```bash
API_PORT=3001 ./setup.sh autostart-enable   # ポート・待受（API_HOST）は有効化時の値でユニットに固定される
systemctl --user status 'ndlocr-api*'       # 状態確認
systemctl --user restart ndlocr-api.target  # 再起動（自動起動中は ./setup.sh start/stop/restart は使用不可）
```

ユニットは `~/.config/systemd/user/ndlocr-api*.{service,target}` に生成され、異常終了時は5秒後に自動再起動されます。
ログは従来どおり `logs/*.log` に追記されます。ポートを変える場合は新しい `API_PORT` で `autostart-enable` を再実行してください。

## 個別起動方法

```bash
# NDLOCR-Liteワーカーのみ起動
python ocr_processor.py

# APIサーバーのみ起動
python api_server.py
python api_server.py --port 9000
python api_server.py --host 127.0.0.1 --port 9000
```

## 対応ファイル形式

### 画像ファイル
- JPEG (.jpg, .jpeg) / PNG (.png) / BMP (.bmp) / TIFF (.tiff, マルチページ対応) / WebP (.webp)
- JPEG2000 (.jp2) — NDLデジタルコレクションで使われる形式

### PDFファイル
- PDF (.pdf) - 自動的にページごとの画像に変換してOCR処理

## システム要件

### Python
- Python 3.10 以上（NDLOCR-Liteの要件）
- pip3

### システム依存関係
- **Ubuntu/Debian**: `poppler-utils`, `libglib2.0-0`, `libgl1`, `git`
- **macOS**: `poppler` (Homebrew経由)

### ハードウェア
- GPU不要（CPU推論、ONNX Runtime）。`ocr_processor.py`は起動時にモデルを読み込むため
  多少のメモリ（1GB程度）を消費する。

## トラブルシューティング

### よくある問題

1. **`extern/ndlocr-lite`が見つからないというエラー**
   ```bash
   ./setup.sh install
   ```

2. **`poppler-utils`が見つからない**
   ```bash
   sudo apt-get install poppler-utils   # Ubuntu/Debian
   brew install poppler                 # macOS
   ```

3. **ポートが使用中**
   ```bash
   python api_server.py --port 9000
   ```

### ログ確認

```bash
tail -f logs/ocr_processor.log
tail -f logs/api_server.log
```

## ライセンス・クレジット

このリポジトリ自体は MIT License です。

OCRエンジンとして [NDLOCR-Lite](https://github.com/ndl-lab/ndlocr-lite)（国立国会図書館ラボ、
**CC BY 4.0**）を利用しています。再配布時はNDLOCR-Liteのクレジット表記を残してください。

## 参考

- [NDLOCR-Lite](https://github.com/ndl-lab/ndlocr-lite) — 国立国会図書館ラボ
- [NDLOCR-Liteの使い方 | NDLラボ](https://lab.ndl.go.jp/data_set/ndlocrlite-usage/)
- [FastAPI](https://fastapi.tiangolo.com/)
- [easyocr-api](../easyocr-api) — 本プロジェクトの元になったEasyOCR版
