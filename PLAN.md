# Indra OCR + Sarashina2.2-OCR Workbench — 実装計画

Indra OCR 1.1（`indra-ocr` v1.1.2）と Sarashina2.2-OCR をローカルで使い分ける個人用アプリ。
既存の `indra-ocr-viewer` を土台に、**単発のPDF/画像プレビュー**と**大量バッチ処理**を追加する。

- Indra OCR: 高速・多言語・行座標あり → 大量処理と下書き
- Sarashina2.2-OCR: 日本語/英語の高品質Markdown・縦書き・表・数式 → 仕上げと構造解析

---

## 0. 結論（要約）

| 項目 | 決定 |
|---|---|
| 形態 | ローカルWebアプリ（`http://127.0.0.1:8765`）。既存ビューアをフォークして拡張 |
| サーバー | Python 標準ライブラリ `ThreadingHTTPServer` を維持（オフライン完結） |
| フロント | 既存の埋め込みHTML/JSを `web/` に分離。CDNフォント廃止・日本語UI |
| エンジン | `OCREngine` 抽象化。Indra（ONNX/CPU）と Sarashina（MLX/Apple GPU）を切替 |
| Indra実行 | プレビューはプロセス内 `OrtOCR`、バッチは `spawn` プロセスプール（1ページ=1タスク） |
| Sarashina実行 | 専用の常駐サブプロセス（MLX 4bit、1ページずつ生成、ストリーミング・中断可） |
| 状態管理 | SQLite（WAL）にジョブ・ファイル・ページ・エンジンを保存。再起動後も再開可能 |
| 出力 | ページ単位JSON（常時）＋ md / txt / jsonl、ZIP、manifest |
| Python | **3.13**（uv で固定）。3.14 は上流の検証範囲外なので使わない |
| モデル | Indra 約76MB / Sarashina MLX 4bit 約2.8GB。初回取得、ローカル指定可 |
| 配布 | 自分専用。127.0.0.1 バインド、認証なし、モデル再配布なし |

工数見込み: **約11.5人日**（M0〜M5。Sarashina の検証スパイクを含む）。

---

## 1. 前提・環境

確認済みの環境:

- macOS (darwin) / Apple Silicon **M5** / 10 CPU cores / **RAM 24GB** / 空き 123GB
- Python 3.14.8（Homebrew）→ **3.13 を別途用意する**
- Node.js 26（フロントのビルドは不要にするため未使用）
- `uv` / Docker は未導入
- `indra-ocr` は未インストール、PyPI 最新は 1.1.2

### 1.1 Indra OCR 1.1

- Python 3.10 以上、macOS は Apple Silicon のみ公式検証（3.10〜3.13）
- モデル: 既定 約76MB、`--math` は追加。ONNX Runtime、PyTorch 不要、GPU 不要
- バッチは「1ページ=1プロセス・1スレッド」で全コアを使う設計
- `convert_many` は macOS の `spawn` のため `if __name__ == "__main__":` が必須
- 出力: 行boxes・信頼度・レイアウトブロック・読み順・Markdown・JSON
- 80+言語。ただし複雑な表、手書き、古いスキャンは弱い

### 1.2 Sarashina2.2-OCR

- SB Intuitions 製。**約3.9Bパラメータ**（SigLIP2 Vision + Sarashina2.2-3B-Instruct）
- **日本語・英語のみ**。韓国語・中国語は不可
- 強み: 縦書き、自然な読み順、表をHTML、数式をLaTeX、図をbbox（0〜1000の正規化座標）で出力
- 弱み: ヘッダ/フッタ、古いスキャンの数式。1ページ7〜20秒（クラウドGPU環境の例）
- ライセンス: **MIT**（モデル重み・同梱コードは一部Apache-2.0表記）
- 公式実行: `transformers==4.57.1` + PyTorch、`device_map="cuda"`、BF16 約7.8GB
- CPUのみでも動くが1ページ数分〜数十分 → **実用上はGPU必須**
- Apple Silicon 向け **MLX 4bit 版**が公開済み: `tokimoa/sarashina2.2-ocr-mlx-4bit`
  - 約2.8GB、M4 Max で約2.8秒/ページ、bf16 と同速でメモリ約1/3
  - `mlx-vlm==0.6.6` + 同梱のカスタムモデルクラスを import して使う
  - 15枚の日本語画像で bf16 版と業務指標 15/15 一致（公開者の検証）

このMacでの想定:

| | Indra OCR | Sarashina (MLX 4bit) |
|---|---|---|
| モデルサイズ | 76MB | 2.8GB |
| 実行デバイス | CPU 10コア | Apple GPU (Metal/MLX) |
| 1ページ速度 | 約0.2〜0.4秒 | 約3〜6秒（要実測） |
| メモリ | ワーカーあたり最大1.5GB | 約2.8GB + 生成バッファ |
| 100ページ | 約30秒〜1分 | 約5〜10分 |

### 1.3 セットアップ（M0 / M0.5 で実施）

```bash
cd /Users/rikuhonda/Documents/Project/OpenCode/OCR

brew install uv python@3.13
uv venv --python 3.13

# Indra
uv pip install "indra-ocr==1.1.2"

# Sarashina（MLX 4bit）
uv pip install "mlx-vlm==0.6.6" transformers==4.57.1 torch torchvision \
  pillow protobuf sentencepiece accelerate huggingface_hub

# モデル取得（リビジョンを固定）
uv run huggingface-cli download tokimoa/sarashina2.2-ocr-mlx-4bit \
  --revision <commit-hash> \
  --local-dir "$HOME/Library/Application Support/indra-workbench/models/sarashina-mlx-4bit"
```

依存衝突が出た場合（`transformers` のピンが合わない等）は、
**Sarashina 専用の venv を別に作り、サイドカーとして起動**する（後述のフォールバック）。

モデルをオフライン固定する場合:

```bash
export INDRA_OCR_MODEL_DIR="$HOME/Library/Application Support/indra-workbench/models/indra"
export SARASHINA_MODEL_DIR="$HOME/Library/Application Support/indra-workbench/models/sarashina-mlx-4bit"
```

---

## 2. スコープ

### やること

1. 既存ビューアの全機能を維持（行・ブロック・読み順のオーバーレイ、Markdown/JSON/信頼度、処理時間）
2. 単発変換の強化（ローカルパス直接オープン、複数ページ、検索、コピー、エクスポート）
3. **エンジン切替**（Indra / Sarashina / 比較）と、エンジンごとのUI最適化
4. バッチ処理（ファイル/フォルダ追加、キュー、進捗、一時停止・再開・中止、失敗のみ再試行）
5. バッチ結果ブラウザ（保存済みJSON＋オンデマンド画像描画で再OCRなし）
6. 日本語UI、オフライン動作、設定の永続化
7. 再起動後のジョブ復元、出力のZIP/manifest

### やらないこと（v1）

- 複数ユーザー・認証・リモート公開
- クラウド同期、Datalab API 連携
- Sarashina の多言語対応（モデルが日英のみ）
- 手書き向けの独自後処理、LLM補正
- 2エンジンの出力を自動でアラインメントする「ハイブリッド合成」
- Windows/Linux の配布パッケージ化（動作はするが保証しない）
- モデルの再配布、Tauri/Electron 化

### 既存ビューアの制約（修正対象）

| 制約 | 対応 |
|---|---|
| アップロードを一括でメモリに読む | チャンクでディスクへストリーム保存 |
| 保持ドキュメントが5件、メモリ保持 | ディスク保存＋LRU、ジョブ配下で管理 |
| 既定 `max-pages=20` | 既定は全ページ、UIで上限指定 |
| バッチ・エクスポート・検索なし | 追加 |
| Google Fonts をCDNから読む | システムフォントに変更（オフライン） |
| UIが英語のみ | 日本語化 |
| 1ページずつ4スレッドで直列 | プレビューは維持、バッチは別プロセスプール |
| Indra 専用のページJSON | `engine` と `figures` を持つ共通スキーマに拡張 |

---

## 3. アーキテクチャ

```
┌──────────────────────────────────────────────────────────────┐
│ Browser (Safari/Chrome)                                      │
│  index.html / app.js / batch.js  ── fetch + SSE              │
└───────────────┬──────────────────────────────────────────────┘
                │ 127.0.0.1:8765
┌───────────────▼──────────────────────────────────────────────┐
│ indra_workbench.server (stdlib ThreadingHTTPServer)          │
│  ├─ EngineRegistry : indra / sarashina の能力・状態           │
│  ├─ PreviewService : ページ単位の変換（エンジン別）            │
│  ├─ JobManager     : 1ジョブ実行、SQLite更新、SSE配信          │
│  ├─ Renderer       : PDFページを都度描画（結果ブラウザ用）      │
│  └─ Exporter       : md/txt/jsonl/zip/manifest                │
└───────┬───────────────────────────────┬───────────────────────┘
        │                               │
┌───────▼────────┐        ┌─────────────▼─────────────────────┐
│ SQLite (WAL)   │        │ Indra pool (ProcessPoolExecutor)   │
│ jobs/files/    │        │  worker.py × N, 1ページ=1タスク     │
│ pages/settings │        │  OrtOCR, 1 thread/worker           │
└────────────────┘        └────────────────────────────────────┘
                          ┌────────────────────────────────────┐
                          │ Sarashina worker (常駐サブプロセス)  │
                          │  MLX 4bit + AutoProcessor          │
                          │  Pipe: token stream / cancel       │
                          └────────────────────────────────────┘
```

### 3.1 エンジン抽象化

```python
class OCREngine(Protocol):
    name: str                      # "indra" | "sarashina"
    capabilities: EngineCaps       # lines, blocks, figures, math, vertical, streaming
    def warmup(self) -> None: ...
    def convert_page(self, job: PageJob) -> Iterator[PageEvent]: ...
    def unload(self) -> None: ...
```

- `PageJob`: 画像（JPEG bytes）またはPDFパス、ページ番号、dpi、オプション
- `PageEvent`: `token`（Sarashinaのストリーミング）/ `done`（PageRecord）/ `error`
- **共通 PageRecord**:
  ```json
  {
    "engine": "indra|sarashina",
    "page": 0,
    "source": "ocr|text|hybrid|vlm",
    "markdown": "...",
    "text": "...",
    "lines": [{"box":[x0,y0,x1,y1],"text":"...","conf":0.98}],
    "blocks": [{"label":"Table","bbox":[...],"text":"..."}],
    "figures": [{"bbox":[x0,y0,x1,y1]}],
    "rotation": 0, "skew": 0.0, "vertical": false,
    "note": "...", "timings": {"total_ms": 1234}
  }
  ```
- Indra は `lines` / `blocks` / 信頼度を返す。Sarashina は `markdown` / `figures` のみ
  （`lines` は空、信頼度なし）。UIは capability に応じて表示を切り替える。

### 3.2 Sarashina ワーカー

- サーバー本体とは**別プロセス**。モデルロード（数秒〜十数秒）でHTTPを止めない
- 初回リクエスト時に遅延ロード。設定で起動時プリロードも可
- 1リクエストずつ処理（MLX 4bit を1インスタンスだけ保持）。バッチも直列
- 通信: `multiprocessing.Pipe`（spawn）。送信はページJPEG（数百KB）
- 生成: `mlx-vlm` のカスタムモデルクラスを import し、トークンループで実行
  - `temperature=0`、`repetition_penalty=1.2`、`max_new_tokens=6000`（モデル推奨）
  - ループ内でキャンセルフラグを確認 → **中断可能**
  - 生成トークンを親へストリーム → SSEでUIに表示
- 出力後処理:
  - Markdownをそのまま保持
  - `<bbox>[(x1,y1),(x2,y2)]</bbox>`（0〜1000）を抽出し、ページ実座標へ変換
  - 表（HTML）・数式（LaTeX）はそのまま
- アイドル10分でアンロード（設定可）。手動アンロードボタンも用意
- **フォールバック**: MLX が動かない/品質不足なら公式 BF16 + PyTorch MPS。
  MPSでも動かない場合はCUDA機（別PC）を想定したサイドカー構成にする

### 3.3 設計上の要点

- **プレビューとバッチの共存**: Sarashina ロード中は Indra ワーカーを
  `min(4, cpu_count-1)` に制限（メモリ 2.8GB + 生成バッファを考慮）。
  未ロード時は `min(6, cpu_count-1, RAM/1.5GB)`。
- **1ページ=1タスク（Indra）**: ページ単位の進捗・中断・再開のため、
  `Converter.pdf_page()` をワーカー内で使う（上流が内部で使う経路と同じ）。
- **上流内部APIへの依存**: `indra-ocr==1.1.2` に固定。アップグレード時は
  スモークテスト（ページ単位API・boxes座標・markdown一致）を必須にする。
- **画像は保存しない**: 結果ブラウザは保存済みJSONのboxesを使い、PDFページを
  オンデマンド描画して重ねる。ページ画像の大量保存を避ける。
- **出力は常にページJSON**: 表示形式に関係なく `data/pages.jsonl` を書く。
  中断・再開・結果表示の基礎データになる。
- **1ジョブ=1エンジン**: 混在指定はエンジンごとにジョブを分割する。
  スケジューラが単純になり、速度見積りも正確になる。

---

## 4. エンジンの使い分け

| 用途 | 推奨 |
|---|---|
| 大量の英語・多言語PDFを素早く下書き | **Indra** |
| 行ごとの座標・信頼度が欲しい | **Indra** |
| 日本語の縦書き・新聞・官公庁資料 | **Sarashina** |
| 複雑な表をHTMLで保持したい | **Sarashina** |
| 数式をLaTeXで取りたい | **Sarashina**（Indraは `--math`） |
| 図・グラフの位置も欲しい | **Sarashina**（図bbox） |
| 韓国語・中国語・アラビア語など | **Indra** |
| 手書き | どちらも苦手（Indraの方が速い） |
| 1000ページ級のバッチ | **Indra**（Sarashinaは1ページ3〜6秒） |

### 自動選択（auto）のルール（v1）

ファイル単位で判定し、UIに理由を表示する:

1. PDFのテキスト層のスクリプトが日本語 → Sarashina
2. 画像のみで、ファイル名/ユーザー指定が日本語資料 → Sarashina
3. それ以外 → Indra
4. 判定できない場合は Indra（速い方に倒す）

ページ単位の自動判定はv2。まずは「ジョブ全体で指定」「ファイル単位で上書き」の2段階。

### 比較モード

- 現在ページを両エンジンで処理し、Markdownを左右に並べる
- 処理時間・文字数・表/数式の有無を表示（CERの自動採点はしない）
- 「このページはSarashinaが良い」と判断したら、そのファイルだけ再実行

---

## 5. 機能要件

### 5.1 単発プレビュー

- [ ] PDF / PNG / JPEG / TIFF（マルチフレーム）/ BMP / WebP をドラッグ&ドロップ
- [ ] ローカルパスを直接指定して開く（大容量PDFをアップロードしない）
- [ ] ページ送り（サムネイル一覧、前後、ページ番号入力、キーボード ←/→）
- [ ] エンジン選択（Indra / Sarashina / 比較）と能力バッジ
- [ ] Indra: 行 / ブロック / ラベル / 読み順 / 信頼度のオーバーレイ
- [ ] Sarashina: 図bboxのオーバーレイ、Markdownのストリーミング表示
- [ ] タブ: Preview / Markdown / 行一覧 / JSON /（IndraのみTesseract比較）
- [ ] 信頼度フィルタ（Indra）、テキスト検索
- [ ] オプション: mode、math、furniture、image_ocr、dpi、max_pages、password
- [ ] Sarashinaオプション: 最大トークン数、dpi、モデルのロード/アンロード
- [ ] オプションセットの保存（「標準」「日本語・高品質」「数式」「OCR強制」）
- [ ] 現在ページ / 全文を Markdown・テキスト・JSON でコピー/保存
- [ ] 処理時間の内訳表示（Indraはステージ別、Sarashinaはロード/生成/秒）

### 5.2 バッチ処理

- [ ] 入力追加: ファイル複数選択、フォルダ選択、**サーバー側パス入力**（フォルダ再帰）
- [ ] 入力一覧: ファイル名、サイズ、ページ数、状態、所要時間、エラー
- [ ] ジョブオプション: エンジン、出力形式（md/txt/jsonl/全部）、出力先、dpi、
      mode、math、furniture、image_ocr、max_pages、コア数、パスワード、上書き/スキップ
- [ ] 進捗: 全体ページ数、完了/失敗、ページ/秒、ETA、現在処理中のファイル
- [ ] 制御: 開始、一時停止、再開、中止、失敗ファイルのみ再試行
- [ ] 1ジョブずつ実行、追加ジョブはキューで待機
- [ ] サーバー再起動時: `running` → `paused` に補正し、再開可能
- [ ] 出力: 入力の相対パスを保って保存。同名衝突は連番。manifest.csv/json
- [ ] 完了後: 結果を開く、ZIPで書き出す、出力フォルダをFinderで開く
- [ ] 失敗しても停止せず継続（暗号化PDF、破損ファイル、未対応形式）
- [ ] Sarashinaジョブは「1ページ約3〜6秒」を開始前に見積り表示

### 5.3 バッチ結果ブラウザ

- [ ] ファイルツリー＋ページ一覧（エンジンバッジ付き）
- [ ] 保存済みJSONからMarkdown・行・boxesを表示（再OCRしない）
- [ ] ページ画像はPDFから都度描画。boxesはジョブ時のdpiでスケール
- [ ] SarashinaはMarkdown＋図bboxのみ（行・信頼度は非表示）
- [ ] 全文検索（SQLite FTS5、任意）
- [ ] 個別ページ/ファイルの再実行（エンジン・オプションを変えて）

### 5.4 運用

- [ ] エンジン状態: Indra（取得済み/未取得）、Sarashina（未取得/ロード中/準備完了）
- [ ] モデルの取得・事前ダウンロード・アンロード・ディスク使用量
- [ ] 設定: ポート、既定ワーカー数、既定出力先、既定エンジン、言語
- [ ] ログ閲覧（直近N件、ジョブ単位）
- [ ] 履歴の削除（DBのみ / 出力も削除）
- [ ] `run.command`（ダブルクリック起動）とブラウザ自動オープン

---

## 6. 画面構成

```
┌──────────────────────────────────────────────────────────────┐
│ Indra OCR + Sarashina Workbench  [単発][バッチ][結果][設定]   │
│ エンジン: (●) Indra  ( ) Sarashina  ( ) 比較   ● Sarashina 準備完了 │
├──────────────────────────────────────────────────────────────┤
│ 単発:                                                        │
│  ┌──────────────┬─────────────────────────────────────────┐  │
│  │ ページ       │  [Preview][Markdown][行][JSON]           │  │
│  │ サムネイル   │  画像 + boxes / 図bbox                   │  │
│  │              │  行クリックで該当テキストをハイライト     │  │
│  └──────────────┴─────────────────────────────────────────┘  │
│  mode / math / dpi / 上限 / 最大トークン        [再実行]      │
├──────────────────────────────────────────────────────────────┤
│ バッチ:                                                      │
│  エンジン: [Indra ▼]  推定: 3,000ページ / 約2分              │
│  [ファイル追加] [フォルダ追加] [パス入力]  出力先: ...        │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ 状態 | ファイル | ページ | 進捗 | 時間 | エラー      │    │
│  └──────────────────────────────────────────────────────┘    │
│  ▓▓▓▓▓▓░░░░ 1,240 / 3,000 ページ  8.2 pages/s  残り 3:34     │
│  [開始] [一時停止] [中止] [失敗を再試行]                      │
└──────────────────────────────────────────────────────────────┘
```

- 単発とバッチはタブ切替。バッチ実行中も単発は使える（リソース上限内）。
- 進捗はSSE。切断時はポーリングにフォールバック。
- Sarashina は生成中にMarkdownが流れるように表示（体感待ち時間を短縮）。
- 色は既存ビューアの oklch パレットを踏襲。ダークモードは `prefers-color-scheme`。

---

## 7. データモデル（SQLite）

保存先: `~/Library/Application Support/indra-workbench/workbench.db`（WAL）

```sql
CREATE TABLE jobs (
  id           TEXT PRIMARY KEY,       -- uuid
  name         TEXT NOT NULL,
  engine       TEXT NOT NULL,          -- indra|sarashina
  state        TEXT NOT NULL,          -- queued|running|paused|done|failed|cancelled
  options      TEXT NOT NULL,          -- JSON
  out_dir      TEXT NOT NULL,
  created_at   TEXT NOT NULL,
  started_at   TEXT,
  finished_at  TEXT,
  total_files  INTEGER DEFAULT 0,
  total_pages  INTEGER DEFAULT 0,
  done_pages   INTEGER DEFAULT 0,
  failed_pages INTEGER DEFAULT 0,
  error        TEXT
);

CREATE TABLE files (
  id         INTEGER PRIMARY KEY,
  job_id     TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  path       TEXT NOT NULL,            -- 元ファイルの絶対パス（またはアップロード先）
  rel_path   TEXT NOT NULL,            -- 出力時の相対パス
  engine     TEXT NOT NULL,            -- ファイル単位の上書き
  pages      INTEGER DEFAULT 0,
  done_pages INTEGER DEFAULT 0,
  state      TEXT NOT NULL,            -- pending|running|done|failed|skipped
  error      TEXT
);

CREATE TABLE pages (
  job_id   TEXT NOT NULL,
  file_id  INTEGER NOT NULL,
  page_no  INTEGER NOT NULL,
  engine   TEXT NOT NULL,
  state    TEXT NOT NULL,              -- pending|done|failed
  source   TEXT,                       -- text|ocr|hybrid|vlm
  ms       REAL,
  error    TEXT,
  PRIMARY KEY (job_id, file_id, page_no)
);

CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE INDEX pages_state ON pages(job_id, state);
```

- ページ行は1万件でも軽量。完了時に集計を更新。
- ページ本文はDBに入れず `data/pages.jsonl` に追記（1行1ページ、boxes/figures含む）。
- Sarashina のページは `lines` が空、`figures` と `markdown` が入る。
- ジョブ削除時は `out_dir` を消すか確認する。

### 出力レイアウト

```
<job out_dir>/
├── manifest.json
├── manifest.csv
├── data/
│   ├── pages.jsonl          # 全ページの boxes/lines/figures/markdown/timings
│   └── files.jsonl          # ファイル単位の結果・エラー
└── out/
    └── <入力の相対パス>/<stem>.md   # 選択形式に応じて .txt/.jsonl
```

---

## 8. API

既存の `/upload` `/page` は互換のまま残し、`/api/*` を追加する。

| Method | Path | 内容 |
|---|---|---|
| GET | `/api/info` | バージョン、CPU/RAM、エンジン状態、既定値 |
| GET | `/api/engines` | 各エンジンの能力・モデルサイズ・速度見積り |
| POST | `/api/engines/sarashina/load` | モデルをロード（進捗はSSE） |
| POST | `/api/engines/sarashina/unload` | モデルを解放 |
| POST | `/api/documents` | アップロード（ストリーム保存）→ `{id, pages}` |
| POST | `/api/documents/open` | `{path}` を直接開く → `{id, pages}` |
| POST | `/api/page` | `{doc, n, engine, opts}` → ページJSON（SarashinaはSSEでも可） |
| GET | `/api/render` | `{doc, n, dpi}` → JPEG（結果ブラウザ用） |
| POST | `/api/jobs` | `{name, inputs[], engine, options, out_dir}` → ジョブ作成 |
| GET | `/api/jobs` | 一覧（状態・進捗） |
| GET | `/api/jobs/{id}` | 詳細＋ファイル一覧 |
| GET | `/api/jobs/{id}/files/{fid}/pages/{n}` | 保存済みページJSON |
| POST | `/api/jobs/{id}/pause` | 一時停止 |
| POST | `/api/jobs/{id}/resume` | 再開 |
| POST | `/api/jobs/{id}/cancel` | 中止 |
| POST | `/api/jobs/{id}/retry` | 失敗のみ再試行 |
| POST | `/api/jobs/{id}/export` | ZIP作成（非同期） |
| GET | `/api/events` | SSE（job/file/page/token イベント） |
| GET | `/api/settings` / PUT | 設定 |
| POST | `/api/models/preload` | モデル取得＋ウォームアップ |

- すべて `127.0.0.1` のみ。`Origin` ヘッダを検査し、他サイトからのPOSTを拒否。
- パス指定は許可ルート（ホーム、`/Volumes`、`/tmp` 相当）に限定し、
  `realpath` でシンボリックリンク脱出を防ぐ。
- SSE は `ThreadingHTTPServer` のスレッドで実装。25ms〜100ms に間引いて配信。
- Sarashina の `/api/page` は `text/event-stream` を返し、`token` → `done` を送る。

---

## 9. バッチ処理フロー

1. **Plan**: 入力パス検証 → PDFは `pypdfium2` でページ数取得 → 重複除去 →
   エンジン決定（ジョブ指定/ファイル上書き/auto）→ DBに `pending` を一括INSERT。
2. **Start**: エンジンごとのレーンを起動。
   - Indra: `ProcessPoolExecutor(spawn)`、initializer で `indra_ocr.load(threads=1, ...)`
   - Sarashina: 常駐ワーカーをロード（未ロードなら）し、1ページずつ投入
3. **Run**:
   - Indra: pendingページを `as_completed` で投入。ワーカーは
     `conv.pdf_page(path, doc, n)` または画像の `conv.convert` を実行し、
     画像を含まない辞書を返す。
   - Sarashina: 親がページをJPEG化して送信。ワーカーがトークンをストリーム。
4. **Persist**: 親が `pages.jsonl` に追記、`pages` を done に更新、
   ファイル完了時に `.md`/`.txt`/`.jsonl` を書き出し、SSE通知。
5. **Pause**: 新規投入を停止。実行中タスクは完了させる。プール/ワーカーは保持。
6. **Cancel**: Indraは `cancel_futures=True`、Sarashinaはキャンセルフラグ。
   実行中ページの完了を待って状態を cancelled に。
7. **Resume**: pending/failed を再投入。ページJSONは追記済みなので重複をスキップ。
8. **Finish**: manifest 生成、集計、プール終了。ZIP要求があれば生成。

### メモリ・CPU

- Indra ワーカーあたり最大約1.5GB。Sarashina ロード中は Indra を最大4ワーカー。
- 実RAMの50%を超えないよう `JobManager` が起動時にクランプ。
- Sarashina は同時1ページ。MLX の生成バッファを含めて約3.5GBを見込む。
- 巨大スキャン（100MP超）はIndraが自動でdpiを下げる。Sarashinaは
  `max_pixels=2,458,624` に自動縮小されるため、細かい文字は劣化する（UIに注記）。
- バッチ中のプレビューは1スレッド。`OrtOCR` のキャッシュは最大2種類。

---

## 10. ディレクトリ構成

```
OCR/
├── PLAN.md
├── pyproject.toml              # requires-python=">=3.13,<3.14"
├── uv.lock
├── .python-version             # 3.13
├── README.md
├── run.command                 # ダブルクリック起動
├── scripts/
│   ├── setup.sh
│   ├── smoke.sh                # モデル取得＋サンプル変換の確認
│   └── sarashina_smoke.py      # MLX 4bit の単ページ検証
├── src/indra_workbench/
│   ├── __init__.py
│   ├── __main__.py             # python -m indra_workbench
│   ├── server.py               # ルーティング、静的配信、SSE
│   ├── engines/
│   │   ├── base.py             # OCREngine, PageJob, PageRecord
│   │   ├── indra.py            # viewer.py の Engine を移植
│   │   └── sarashina.py        # ワーカー起動・プロトコル・後処理
│   ├── sarashina_worker.py     # spawn安全な独立プロセス
│   ├── preview.py              # 単発プレビュー統括
│   ├── render.py               # PDF/画像ページ描画
│   ├── jobs.py                 # JobManager、状態機械、レーン
│   ├── worker.py               # Indra用のspawn安全な関数
│   ├── db.py                   # スキーマ、マイグレーション
│   ├── export.py               # md/txt/jsonl/zip/manifest
│   ├── paths.py                # 許可ルート検証、相対パス生成
│   ├── config.py               # 設定、既定値
│   └── web/
│       ├── index.html
│       ├── app.js              # 単発
│       ├── batch.js            # バッチ
│       ├── style.css
│       └── md.js               # Markdownレンダラ（エスケープ維持）
├── tests/
│   ├── fixtures/               # サンプルPDF/画像（自作または上流サンプル）
│   ├── test_db.py
│   ├── test_paths.py
│   ├── test_batch.py           # pause/resume/cancel/retry
│   ├── test_worker.py          # Indraの1ページ出力がCLIと一致
│   └── test_sarashina.py       # 出力パース、figure bbox、キャンセル
└── data/                       # 実行時（gitignore）
```

`viewer.py` は Apache-2.0。移植部分には上流の著作権表示とコミットハッシュを残す。
Sarashina のモデルコードは MIT/Apache-2.0。`trust_remote_code` を使うため、
**モデルのリビジョンを固定**し、コードを確認した上で同梱またはローカルコピーから読む。

---

## 11. マイルストーン

| # | 内容 | 完了条件 | 工数 |
|---|---|---|---|
| **M0** | 環境構築（Indra） | Python 3.13 で `indra-ocr` と viewer が起動。サンプル1ページの出力を保存 | 0.5日 |
| **M0.5** | **Sarashina 検証スパイク** | MLX 4bit で日本語3ページ（横書き・縦書き・表）を変換。時間・RAM・品質を記録。bf16/MPS との比較 | 1日 |
| **M1** | フォーク＋単発強化（Indra） | ローカルパスでPDFを開ける。日本語UI。オフライン。Markdown/JSON保存 | 1.5日 |
| **M2** | エンジン抽象化＋Sarashina 統合 | 単発でエンジン切替。Sarashinaのストリーミング・キャンセル・アンロード。figure bbox表示 | 2日 |
| **M3** | バッチ基盤 | SQLite、JobManager、Indraプール、Sarashinaレーン。pause/resume/cancel/retry | 3日 |
| **M4** | バッチUI＋結果ブラウザ | フォルダ投入、進捗SSE、失敗継続、結果表示（再OCRなし）、ZIP/manifest | 2日 |
| **M5** | 仕上げ | 復元、設定、ログ、比較モード、`run.command`、README、テスト | 1.5日 |

### 進め方

1. M0: `uv` + Python 3.13 + Indra の速度・メモリを実測。
2. **M0.5 を最優先**: Sarashina がこのMacで実用速度で動くかを確認する。
   ここが不合格なら、Sarashina は「CUDA機サイドカー」または「バッチ専用・夜間実行」に方針変更。
3. M1: viewer を移植し、まず Indra で「パス指定オープン」「保存」を実装。
4. M2: エンジン抽象化。Sarashina ワーカーを単発に接続。
5. M3: DBとバッチをUIなしでCLI検証。
6. M4: UIを載せる。SSEが重ければポーリングに切替。
7. M5: 中断→再起動→再開のテストを必ず通す。

---

## 12. テスト計画

### 自動テスト

- [ ] `test_worker`: Indraの1ページ `lines/blocks/markdown` が `indra-ocr --format json` と一致
- [ ] `test_batch`: 3ファイル×10ページで、完了ページ数・出力ファイル数・manifest を検証
- [ ] `test_batch`: 50%で pause → resume して全ページ完了。重複出力なし
- [ ] `test_batch`: cancel 後にプール/ワーカーが残らない（プロセスリークなし）
- [ ] `test_batch`: 壊れたPDF/暗号化PDFを混ぜても他ファイルが完了
- [ ] `test_db`: 再起動復元（running→paused）、失敗のみ retry
- [ ] `test_paths`: `..`、シンボリックリンク、許可外パスを拒否
- [ ] `test_export`: 日本語ファイル名、空白、同名衝突、深い階層
- [ ] `test_sarashina`: 固定画像のMarkdownが安定（temperature=0）、figure bboxの変換
- [ ] `test_sarashina`: 生成中のキャンセルが3秒以内に効く
- [ ] `test_sarashina`: モデル未ロード時に明確なエラーを返す

### 手動・性能

- [ ] 100ページPDF×10ファイル（1,000ページ）でIndraのメモリが増え続けない
- [ ] 10,000ページ投入でDBと `pages.jsonl` が破綻しない（1行1ページ）
- [ ] 日本語・英語・アラビア語・縦書き中国語の各サンプルで表示崩れなし
- [ ] Sarashina: 縦書き・表・数式の3ページで、目視で実用品質
- [ ] Sarashina: 連続20ページでメモリが増え続けない（MLXキャッシュ対策）
- [ ] Safari と Chrome で動作。オフライン（機内モード）で全機能が動く
- [ ] 10コアでの実測をREADMEに記録
  - 目標: Indra dpi200・mathなしで 5 pages/s 以上
  - 目標: Sarashina MLX 4bit で 0.2 pages/s 以上（1ページ5秒以内）

### 回帰確認（上流アップグレード時）

- [ ] `indra_ocr.load` / `Converter.pdf_page` のシグネチャ
- [ ] `Page.lines/blocks/markdown/timings` の形
- [ ] 座標系（回転・deskew後のboxes）と `MAX_SIDE` スケーリング
- [ ] `mlx-vlm` と Sarashina カスタムモデルクラスの互換性
- [ ] `transformers` / `AutoProcessor` のバージョン互換性

---

## 13. リスクと対策

| リスク | 影響 | 対策 |
|---|---|---|
| Python 3.14 で onnxruntime が不安定 | 起動不可 | 3.13 を uv で固定。`requires-python` で拒否 |
| MLX 4bit が M5 で動かない | Sarashina 使用不可 | M0.5 で最優先検証。公式 BF16 + MPS、CUDAサイドカーの順にフォールバック |
| `transformers` の依存衝突 | 同一venvで共存不可 | Sarashina専用venvのサイドカーに分離（M0.5で判断） |
| 4bit量子化で品質劣化 | 出力が崩れる | bf16版と15ページ比較。劣化が大きければbf16/MPSを使用 |
| Sarashina が1ページ3〜6秒 | 大量バッチに不向き | エンジン選択UIに速度見積り。1000ページはIndraを推奨 |
| 24GB RAMでIndraとSarashinaが競合 | スワップ/停止 | Sarashinaロード中はIndra 4ワーカー。RAM50%上限。アンロード機能 |
| `trust_remote_code` の安全性 | 任意コード実行 | リビジョン固定、コード確認、ローカルコピーから読む |
| モデルが2.5MPに縮小 | 密な縦書き・新聞で小さい文字が落ちる | dpi/前処理を調整。必要なら分割OCRをv2で検討 |
| Sarashinaは行boxesなし | 既存UIの行オーバーレイが使えない | capabilityで表示切替。図bboxとMarkdownのみ表示 |
| 図bboxの形式が変わる | パース失敗 | 正規表現を寛容に。失敗時はMarkdownのみ表示しログ |
| 上流Indraの内部API変更 | アップグレード時に破損 | 1.1.2 固定＋回帰テスト。代替は `convert_many` |
| macOS `spawn` でワーカーが再帰起動 | バッチ停止 | ワーカーを独立モジュールのトップレベル関数に。`__main__` ガード |
| 大量PDFのメモリ/DB肥大 | 応答低下 | パス指定を推奨。ストリーム保存。ページJSONは追記 |
| 手書き・複雑な表の精度 | 期待外れ | 精度の限界をUIに明記。エンジン比較機能を提供 |
| ローカルサーバーのパス悪用 | ファイル読み出し | 127.0.0.1、Origin検査、許可ルート、realpath検証 |

---

## 14. ライセンス

- **Indra OCR**
  - コード: Apache-2.0
  - モデル重み: modified OpenRAIL-M
    - 研究・個人利用・資金/収益2,000万ドル未満のスタートアップは無償
    - Datalab API と競合する用途は不可
- **Sarashina2.2-OCR**
  - モデル重み: **MIT**（商用利用可）
  - 同梱コード: 一部 Apache-2.0 表記
  - MLX 4bit 変換: MIT（元モデル準拠）
- 本アプリは**自分専用**とし、モデルとアプリの再配布はしない。
  上流コードの移植部分には LICENSE と出典を明記する。
- Sarashina を将来配布する場合も MIT なので問題ないが、
  `trust_remote_code` のコードとモデルの出所をREADMEに記載する。

---

## 15. 未決事項（実装前に確認）

1. **既定エンジン**: Indra（速い）を推奨。Sarashinaはジョブ/ページ単位で選択。
2. **Sarashinaの実行方式**: MLX 4bit（推奨・2.8GB）か、公式BF16 + MPS（7.8GB）か。
   → M0.5 の実測で決定。
3. **依存分離**: 同一venvか、Sarashina専用venvのサイドカーか。→ M0.5 で決定。
4. 既定の出力先: `~/Documents/Indra OCR Output` でよいか
5. 既定ワーカー数: Indra 6 / Sarashinaロード中 4 でよいか
6. ページJSONを常時保存するか → 推奨: 常時（再開・結果表示が速い）
7. 比較モードをv1に入れるか、v1.5に回すか
8. 全文検索（FTS5）をv1に入れるか、v2に回すか
