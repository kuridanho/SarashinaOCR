# Sarashina OCR

Sarashina2.2-OCR を Apple Silicon Mac 上でローカル実行する、日本語 UI のネイティブ macOS アプリです。画像・PDF の取り込みから Markdown のプレビュー、図の切り出し、書き出しまでを 1 つの画面で行えます。

- **完全ローカル**: 推論も描画もこの Mac の中で完結します。OCR 結果や画像は送信しません。
- **MLX 4bit 専用**: `tokimoa/sarashina2.2-ocr-mlx-4bit`（約 2.98 GB、MIT）を固定リビジョンで利用します。
- **ネイティブ UI**: SwiftUI + PDFKit / Vision / Core Image。推論は Python 3.12 のサイドカー（`mlx-vlm`）に分離しています。
- **オフライン**: 初回のモデルダウンロード以降はネットワーク不要です。

> 本リポジトリは仕様書 `sarashina-ocr-macos-spec.md` v0.5（MLX のみ）に基づく個人利用向け実装です。PyTorch / MPS 版は実装・配布に含めていません。

## 必要環境

| 項目 | 要件 |
|---|---|
| Mac | Apple Silicon（M1 以降）。8 GB 機は非対応、16 GB 以上を推奨 |
| OS | macOS 14 Sonoma 以降 |
| ビルド | Xcode 26 以降 / Swift 6.4（Swift Package Manager） |
| Python | 3.12（Homebrew の `python@3.12` を想定） |
| 空き容量 | モデル 2.98 GB + 作業用 |

実測（M5 / 24 GB、高精度プリセット）: 初回トークンまで約 7 秒、約 35–47 tok/s、ピークメモリ約 4.4 GB。

## セットアップ

```bash
# 1. Python 3.12 を準備
brew install python@3.12

# 2. 推論エンジンの venv を作成（mlx-vlm / transformers / torch など）
./scripts/setup-engine.sh

# 3. モデルを取得（アプリ内ダウンロードでも可）
./scripts/fetch_model.sh

# 4. アプリをビルド
./scripts/build-app.sh release
open dist/SarashinaOCR.app
```

開発中は `./scripts/build-app.sh debug` で短時間にビルドできます。アプリはリポジトリ内の `.venv`、`engine/`、`models/` を自動的に探索します。

モデルをアプリ内で取得する場合は、初回起動時のセットアップ画面から「ダウンロードを開始」を選んでください。保存先は `~/Library/Application Support/SarashinaOCR/models/sarashina2.2-ocr/<revision>` です。ダウンロードは一時停止・再開に対応し、各ファイルを SHA-256 で検証します。既にモデルフォルダがある場合は「フォルダからインポート…」で取り込めます。

### 環境変数（開発・上級者向け）

| 変数 | 用途 |
|---|---|
| `SARASHINA_MODEL_DIR` | モデルディレクトリを明示 |
| `SARASHINA_ENGINE_PYTHON` | サイドカーの Python 実行ファイル |
| `SARASHINA_ENGINE_DIR` | `ocr_engine` を含むディレクトリ |
| `SARASHINA_DEV_LOG=1` | エンジンのログを stderr に表示（debug ビルド） |
| `SARASHINA_DEV_AUTORUN=1` | 起動引数のファイルを取り込み後、自動で OCR（debug ビルド） |

例:

```bash
SARASHINA_DEV_LOG=1 SARASHINA_DEV_AUTORUN=1 \
  ./dist/SarashinaOCR.app/Contents/MacOS/SarashinaOCR examples/sample1.png
```

## 使い方

1. 画像（PNG / JPEG / HEIC / TIFF）または PDF をウィンドウへドロップ、`⌘O`、`⌘V` のいずれかで取り込みます。
2. 左のライブラリで文書を選び、`⌘R` で OCR を開始します。
3. 右ペインで Markdown プレビュー / 生テキスト / 図ギャラリーを切り替えます。
4. `⌘C` で Markdown をコピー、`⌘E` で書き出します。

PDF は 200 dpi でページごとにラスタライズされ、ページ単位で結果を保存します。図の bbox は処理後画像に対する正規化座標（0–1000、左上原点）で保持し、切り出し画像は `assets/pNNN/fig-NNN.png` に保存します。

### ショートカット

| 操作 | キー |
|---|---|
| 取り込み | `⌘O` |
| クリップボードから貼付 | `⌘V` |
| OCR 実行 / 停止 | `⌘R` / `⌘.` |
| 書き出し | `⌘E` |
| Markdown をコピー | `⌘C` |
| 全ページをコピー | `⇧⌘C` |
| 前 / 次のページ | `⌘←` / `⌘→` |
| 文字サイズ | `⌘+` / `⌘-` / `⌘0` |
| 設定 | `⌘,` |

## 構成

```text
SarashinaOCR.app (SwiftUI)
  ├─ ImportService       画像/PDF 取り込み、クリップボード
  ├─ PreprocessService   Vision 書類検出、Core Image 台形補正、PDF ラスタライズ
  ├─ EngineClient        Python サイドカーとの JSON Lines RPC
  ├─ DocumentStore       SQLite（documents / pages / results / figures）
  ├─ MarkdownWebView     markdown-it + KaTeX + DOMPurify（同梱）
  ├─ ExportService       Markdown + assets / プレーンテキスト / JSON
  └─ ModelManager        モデル DL・再開・SHA-256 検証・手動インポート

engine/ocr_engine (Python 3.12 / MLX)
  ├─ RPC ループ（hello / ping / load / unload / ocr / cancel / shutdown）
  ├─ MLX バックエンド（自前の greedy decode、repetition penalty 1.2）
  ├─ 前処理（smart_resize、最大 2,458,624 px）
  └─ 後処理（bbox 切り出し、Markdown サニタイズ、警告）
```

データは `~/Library/Application Support/SarashinaOCR/` に保存されます。

- `db.sqlite`: 文書・ページ・結果・図のメタデータ
- `documents/<id>/source.*`: 原本
- `documents/<id>/page-*.png`: 補正後画像
- `documents/<id>/assets/pNNN/`: 切り出した図

## テスト

```bash
# Python エンジン（モックバックエンドを含む）
PYTHONPATH=engine .venv/bin/python -m pytest engine/tests -q

# 実モデルでのスモークテスト
PYTHONPATH=engine .venv/bin/python -m ocr_engine.cli \
  --backend mlx \
  --model-dir models/sarashina2.2-ocr-mlx-4bit \
  --image examples/sample1.png \
  --out out/sample1 --preset high

# Swift のビルド
cd app && swift build

# Swift のテスト（8 件）
./scripts/test-app.sh
```

`swift test` を直接実行すると、macOS のファイルプロバイダが `~/Documents` 配下のバンドルに付ける Finder 情報（`com.apple.FinderInfo`）のため、テストバンドルの ad-hoc 署名に失敗することがあります。`scripts/test-app.sh` はビルド生成物を `~/Library/Caches/SarashinaOCR-build` に置き、この問題を回避します。`scripts/build-app.sh` も同じ場所を使い、署名前に xattr を除去します。

## 既知の制限

- 4 隅の手動調整は「4隅」ボタンから行えます。自動検出に失敗した場合の初期値は全画面です。
- PDF / DOCX 書き出しは未実装です（v1.1 スコープ）。Markdown + assets、プレーンテキスト、JSON を書き出せます。
- 複数文書のバッチキュー、全文検索（FTS5）は v1.1 スコープです。
- `scripts/build-app.sh` は開発機向けの `.app` を作ります。Python ランタイムを同梱した配布用 DMG の生成は未自動化で、現在はリポジトリ内の `.venv` / `engine` を参照します。別の Mac へ配る場合は python-build-standalone と site-packages の同梱（仕様 §9.3）が必要です。
- モデルの初回ダウンロード時のみ通信します。OCR 実行時は `HF_HUB_OFFLINE=1` / `TRANSFORMERS_OFFLINE=1` を設定しています。

## ライセンス

- アプリ本体: MIT
- Sarashina2.2-OCR: SB Intuitions、MIT License
- MLX 4bit 変換: [tokimoa/sarashina2.2-ocr-mlx-4bit](https://huggingface.co/tokimoa/sarashina2.2-ocr-mlx-4bit)
- markdown-it: MIT / KaTeX: MIT / DOMPurify: Apache-2.0 OR MPL-2.0

モデルカード: [sbintuitions/sarashina2.2-ocr](https://huggingface.co/sbintuitions/sarashina2.2-ocr)
