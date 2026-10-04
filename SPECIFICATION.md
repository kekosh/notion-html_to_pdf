# notion-html_to_pdf 仕様詳細書 (Specification)

## 1. 概要 (Overview)

### 1.1 目的
`notion-html_to_pdf` は、Notionから「HTML形式（サブページを含める）」でエクスポートされたZIPアーカイブまたはフォルダを解析し、Notion本来のデザインを忠実に再現した単一の高品質なA4版PDFドキュメントを生成するmacOS/Linux向けのコマンドラインツール（Ruby製）です。

### 1.2 背景と解決する課題
Notion純正のPDFエクスポート機能やブラウザ印刷では以下の課題が存在します：
- サブページを含めると階層構造ごとに個別のHTMLファイルに分離され、1つのドキュメントとして結合されない。
- 改ページ位置で見出しと本文、コールアウトと画像が泣き別れ（orphaned）を起こしやすい。
- トグルリスト（`<details>`）が閉じた状態のまま印刷され、情報が欠落する。
- 内部リンクが外部リンク扱いやローカルの相対パス切れとなり、PDF内でジャンプできない。
- サブページごとの巨大なカバー画像やデフォルトアイコン（🪙等）により、ページ数や余白が不必要に肥大化する。

本ツールはこれらの課題を自動解決し、階層構造の走査、DOM構造の最適化、印刷用CSSの動的注入、およびHeadless Chromeを活用したPDFレンダリングを統合的に実行します。

---

## 2. システム要件と前提条件 (System Requirements)

### 2.1 動作環境
- **対応OS**: macOS（推奨・最適化済み）、Linux
- **実行ランタイム**: Ruby 2.6 以上

### 2.2 外部依存ソフトウェア
| ソフトウェア / コマンド | 必須 / 任意 | 用途 | 補足 |
| :--- | :---: | :--- | :--- |
| **Google Chrome** (または Chromium / Canary / Brave) | **必須** | PDFレンダリングエンジン | `--headless=new` オプション対応バージョン |
| **sips** | 任意 (macOS標準) | 画像寸法（幅・高さ）の取得 | コールアウト内の改ページ予測計算に使用 |
| **unzip** | 任意 (OS標準) | ZIPアーカイブの展開 | `rubyzip` gem が未インストールの際にフォールバック利用 |

### 2.3 Rubyライブラリ (Gem) 依存性
本ツールは外部gemなし（Ruby標準ライブラリのみ）でも動作するように二重のフォールバック機構を備えています。

| Gem名 | 優先度 | 役割 | 未インストール時のフォールバック |
| :--- | :---: | :--- | :--- |
| **nokogiri** | 推奨 | HTMLパーシング、DOMツリー走査・属性操作 | 正規表現によるテキスト置換 |
| **rubyzip** | 推奨 | ZIPファイルの安全なインメモリ展開 | システムの `unzip -q` コマンド |

---

## 3. 入出力仕様 (Input & Output Specification)

### 3.1 入力仕様
- **対応入力形式**:
  1. Notionからエクスポートした `.zip` ファイル（解凍不要）
  2. 上記を展開したディレクトリ（フォルダ）
- **前提条件**:
  - Notionの「エクスポート」機能で、エクスポート形式に **「HTML」**、サブページを含めるに **「すべて」** または **「サブページを含める」** を選択してダウンロードされたデータ構造であること。

### 3.2 出力仕様
- **出力形式**: PDF形式（ISO 32000-1準拠、PDFバージョン1.4〜1.7相当）
- **出力先パスの決定規則**:
  1. `-o, --output` オプションでパスが明示された場合：
     - 指定されたファイル名に日付プレフィックス（`yyyymmdd_`）が付与されていない場合、自動的に付与して保存。
  2. パス未指定（デフォルト）の場合：
     - 入力元ファイル/フォルダと同じディレクトリ内に `yyyymmdd_<元ファイル名/元フォルダ名>.pdf` として保存。
- **PDFメタデータ / 目次構造**:
  - PDFアウトライン（PDF Bookmarks）: 各ページのタイトルおよび見出し（H1〜H4）が閲覧ソフトのアウトラインツリーとして埋め込まれます。

---

## 4. アーキテクチャと処理パイプライン (Architecture & Processing Pipeline)

```
[入力: ZIP / フォルダ]
         │
         ▼
 1. 展開と一時ディレクトリ生成 (Temp Directory)
         │
         ▼
 2. HTML探索 & メタデータ抽出 (NFC正規化, タイトル, ID, リンク, CSS)
         │
         ▼
 3. ページ階層ソート (Root検出 ──> 深さ優先探索 DFS)
         │
         ▼
 4. DOM変換 & 最適化
    ├── 画像/メディアパスの絶対 file:// URI 化
    ├── 内部リンクをアンカー (#page-{id}) 化
    ├── サブページカバー/不要アイコンの除去
    ├── トグルリスト (<details>) の強制オープン
    ├── コールアウト高さ推定 & 泣き別れ防止/分割
    └── 改ページマーカー ([改ページ], [pagebreak] 等) の置換
         │
         ▼
 5. 目次ページ (TOC) 生成 (※オプション指定時)
         │
         ▼
 6. マスターHTML結合 (_merged_notion_master.html)
    └── 統合スタイルシート (Notion CSS + @import + 印刷最適化CSS) 注入
         │
         ▼
 7. Headless Chrome による PDF 出力 (--print-to-pdf)
         │
         ▼
 8. クリーンアップ & プレビュー起動 (--open)
```

### 4.1 パイプライン詳細

#### Step 1: 入力パスの正規化とZIP展開
- ターミナルからドラッグ＆ドロップされた際に付与されるエスケープ文字（`\ ` やエスケープ括弧）、両端のクォートを除去し、`File.expand_path` で絶対パス化。
- ZIPファイルの場合、`Dir.mktmpdir('notion_pdf_')` で安全な一時ディレクトリを作成し展開。処理完了後は `ensure` 節で確実に削除。

#### Step 2: HTML探索とメタデータのパース
- 対象ディレクトリ内のすべての `*.html` を走査（macOSのメタファイル `._*` や前回生成時の一時ファイル `_merged_*` は自動除外）。
- macOS特有の濁点・半濁点の文字化け（NFD問題）を回避するため、全ファイルパスを Unicode正規化形式C (`unicode_normalize(:nfc)`) で統一。
- 各HTMLから以下のメタデータを抽出：
  - **タイトル**: `h1.page-title` → `<title>` → ファイル名（Notionが付与する末尾32文字のUUIDハッシュを除去）。
  - **ページID**: `<article id="...">` 属性から抽出（無ければサニタイズされたファイル名）。
  - **子ページリンク**: `figure.link-to-page a[href]`, `.link-to-page a[href]`、および単独の `<p>` 内のページ導線リンク。
  - **CSSスタイル**: 各HTMLヘッダー内の `<style>` タグ内容を抽出。

#### Step 3: 階層構造の再構築と順序付け (DFS)
- 最も浅いパス深度（Path depth）にあるファイルを **ルートページ（親ページ）** として特定。
- ルートページからリンクされた子ページを **深さ優先探索（DFS: Depth-First Search）** で再帰的に走査し、階層深度（depth）を付与しながら順序付き配列に格納。
- ページ内にリンクが存在しなかった孤立HTMLファイルについても、ディレクトリ階層の深さ順にソートして末尾へ安全に結合。

#### Step 4: DOM変換とNotionコンテンツ最適化
各ページに対して以下の変換処理を施します：
1. **サブページヘッダ画像の制御 (`--subpage-covers`)**:
   - デフォルト（非表示）の場合、サブページ（depth > 0）の `img.page-cover-image`、ヘッダーアイコン（`.page-header-icon`）、および絵文字アイコン（🪙等）を除去し、余白を詰める。
2. **トグルリストの自動展開 (`open_toggles`)**:
   - `<details>` タグすべてに `open=""` 属性を付与。PDF出力時に隠蔽されている情報が失われないように展開。
3. **ローカルアセットパスの絶対URI化**:
   - `<img>`, `<video>`, `<audio>`, `<source>` の `src` 属性、およびインラインスタイルの `url(...)` に含まれる相対パスを、解決済みのローカル絶対URI (`file:///...`) に変換。
4. **内部リンクのPDF内アンカー化**:
   - エクスポートファイル間の相対リンク (`href="child.html"`) を、結合ドキュメント内のアンカーリンク (`href="#page-{id}"`) に書き換え。
5. **改ページマーカーの変換**:
   - Notionの段落で記述された改ページマーカー（例: `[改ページ]`, `[pagebreak]`, `---pagebreak---`, `<pagebreak>`）を検知し、強制改ページ用DIVタグ `<div class="force-page-break"></div>` に置換。
6. **コールアウト（Callout）の泣き別れ防止 & 分割処理**:
   - コールアウト内部の文字数と画像サイズから高さを事前推定（`estimate_callout_height`）。
   - コールアウトが1ページ（約650pt）内に収まる場合は `.callout-atomic` クラスを付与し、途中で改ページされないようにブロック。
   - 1ページを超える巨大なコールアウトの場合は、内部の画像ブロック（`figure`）ごとに複数の `<aside class="callout callout-atomic">` に分割し、改ページ時のレイアウト崩れ・アイコン重複を防止。

#### Step 5: 目次 (Table of Contents) の生成 (`--toc`)
- オプション有効時、先頭にクリック可能な目次ページ（階層に応じたインデント幅: `depth * 24px`、親=📘 / 子=📄 アイコン）を自動挿入。

#### Step 6: 統合マスターHTMLの組み立て
- 各HTMLから抽出された `@import` ルールを最上部にまとめ、Notion標準CSS、印刷最適化CSS（後述）、および全ページのセクションDIVを1つのHTMLファイル（`_merged_notion_master.html`）に集約。

#### Step 7: Headless ChromeによるPDFレンダリング
- 以下の引数を指定してHeadless Chromeを実行：
  ```bash
  Google\ Chrome \
    --headless=new \
    --disable-gpu \
    --allow-file-access-from-files \
    --no-pdf-header-footer \
    --generate-pdf-document-outline \
    --print-to-pdf=/path/to/output.pdf \
    _merged_notion_master.html
  ```
- `--allow-file-access-from-files`: ローカル画像・フォントの読み込みを許可。
- `--no-pdf-header-footer`: Chrome標準の不要なURL/日付ヘッダーを無効化（CSSの `@page` ルールで制御するため）。
- `--generate-pdf-document-outline`: 見出しタグ（H1〜H6）からPDF標準のアウトライン（ブックマーク目次）を生成。

---

## 5. 印刷・レイアウトCSS仕様 (Print Layout CSS Specification)

### 5.1 改ページ制御 (Page Break Rules)
| 対象要素 | 適用CSS | 目的 |
| :--- | :--- | :--- |
| 各ページコンテナ (`.notion-page-container`) | `break-before: page !important;` (先頭コンテナ除く) | サブページごとに必ず新しいページから開始 |
| 見出し (`h1`, `h2`, `h3`, `h4`, `summary`) | `break-after: avoid !important;` | 見出し直後での改ページ（見出しの孤立）を防止 |
| 構造ブロック (`figure`, `tr`, `pre`, `code`, `blockquote`) | `break-inside: avoid !important;` | コードブロック、表の行、画像の途中分断を防止 |
| テーブル (`table`) | `break-inside: auto;` / `thead { display: table-header-group; }` | 複数ページにまたがる表でヘッダー行を次ページ先頭に再表示 |
| アトミックコールアウト (`.callout-atomic`) | `break-inside: avoid !important;` | コールアウトボックス枠の分断を防止 |
| 強制改ページ (`.force-page-break`) | `break-before: page !important; height: 0; margin: 0;` | ユーザーの意図した位置での確実な改ページ |

### 5.2 余白設定プリセット (Margin Settings)
A4サイズ（210mm × 297mm）を基準としたマージン定義：

| 設定モード | コマンドライン引数 | `@page { margin: ... }` | 特徴・用途 |
| :--- | :--- | :--- | :--- |
| **標準 (あり)** [デフォルト] | （指定なし） / `--margin normal` | `18mm 16mm 18mm 16mm` | 読みやすさを重視した標準的な文書スタイル |
| **コンパクト (なし)** | `--no-margin` / `--margin none` | `12mm 10mm 12mm 10mm` | 情報密度を高め、ページ数を節約するレイアウト |
| **完全ゼロ** | `--margin zero` | `0` | 端まで画像を広げるプレゼン資料等の用途 |
| **カスタム値** | `--margin 10mm` / `--margin 15mm 20mm` | 渡された文字列をそのままCSS値に適用 | ユーザー任意のCSS余白指定 |

### 5.3 ヘッダー・フッター仕様 (Headers & Footers)
CSS Paged Media Module Level 3 のマージンボックスを利用してレンダリングされます：

- **ヘッダー (`@top-right` / `@top-left`)**:
  - デフォルト表示位置: 右上 (`@top-right`)
  - 内容: 出力PDFファイル名（または `--header-text` で指定した文字列）
  - スタイル: フォントサイズ 8.5pt, カラー `#666666`, システムフォント
  - 配置制御: `--header-left` により左上 (`@top-left`) に切り替え可能
- **フッター (`@bottom-center`)**:
  - 表示位置: 中央下 (`@bottom-center`)
  - 内容: `- counter(page) -`（例: `- 1 -`, `- 2 -`）
  - スタイル: フォントサイズ 9pt, カラー `#555555`

---

## 6. 改ページ記法仕様 (Custom Page Break Syntax)

Notion本文中で改ページを行いたい場合、独立した1段落（ブロック）として以下のいずれかを記述することで、PDF生成時に自動で不可視化され、改ページが発生します。

### 対応する記法パターン（大文字小文字不問）
- `[改ページ]`
- `[pagebreak]`
- `[pb]`
- `---pagebreak---` （ハイフン3つ以上）
- `===pagebreak===` （イコール3つ以上）
- `<pagebreak>`
- コードブロック（`<code>`）で囲まれた上記表記

---

## 7. コマンドライン・インターフェース仕様 (CLI Specification)

### 7.1 コマンド書式
```bash
./notion-html_to_pdf.rb [オプション] [入力ファイルまたはフォルダ]
```

### 7.2 引数およびオプション一覧
| オプション | 型 / 引数 | デフォルト値 | 説明 |
| :--- | :---: | :---: | :--- |
| `-o, --output` | 文字列 (Path) | 自動生成 | 出力先PDFファイルパスを指定。 |
| `--toc` | なし | 無効 | 先頭にクリック可能な目次ページ（階層インデント付き）を生成。 |
| `--no-toc` | なし | 有効 | 目次ページを生成しない。 |
| `--no-margin` | なし | - | ページの余白なし（コンパクト: 上下12mm / 左右10mm）で作成。 |
| `--margin` | 文字列 | `normal` | 余白サイズまたはプリセット名を指定 (`normal`, `none`, `zero`, `10mm` 等)。 |
| `--subpage-covers` | なし | 無効 | サブページのヘッダ画像（カバー画像）を表示する。 |
| `--no-subpage-covers` | なし | 有効 | サブページのヘッダ画像を非表示にする。 |
| `--no-header-footer` | なし | - | ヘッダーおよびフッターの両方を非表示にする。 |
| `--no-header` | なし | - | ヘッダー（ファイル名）のみ非表示にする。 |
| `--no-footer` | なし | - | フッター（ページ番号）のみ非表示にする。 |
| `--header-text` | 文字列 | PDF名 | ヘッダーに表示する文字列を上書き指定。 |
| `--header-left` | なし | 右寄せ | ヘッダーのファイル名を左寄せで配置する。 |
| `--keep-toggles-closed` | なし | - | トグルリストを自動展開せず、閉じた状態のまま印刷する。 |
| `--chrome-path` | 文字列 (Path) | 自動検出 | 使用するGoogle Chrome / Chromiumの実行バイナリパスを手動指定。 |
| `--open` | なし | 無効 | PDF生成完了後、macOS標準のプレビュー（Preview.app）で自動表示。 |
| `-h, --help` | なし | - | ヘルプメッセージを表示して終了。 |

### 7.3 対話モード (Interactive Mode)
引数を指定せずに `notion-html_to_pdf.rb` を実行した場合、標準入力（STDIN）を通じて以下の対話プロンプトが表示されます：
1. **対象パス入力**: ファイルやフォルダのドラッグ＆ドロップ受け付け
2. **余白選択**:
   - `[1]` 余白あり (標準: 上下18mm / 左右16mm)
   - `[2]` 余白なし (コンパクト: 上下12mm / 左右10mm)
3. **サブページヘッダ画像の表示選択**:
   - `[1]` 非表示 (標準)
   - `[2]` 表示する

### 7.4 GUIランチャー (`notion-html_to_pdf.command`) 仕様
macOSのFinderからダブルクリックで実行可能なシェルスクリプトです。
- ダブルクリック時にターミナルを自動起動。
- 対話プロンプトでファイル、余白、カバー画像有無を入力。
- `--open` オプション付きでRubyスクリプトを呼び出し、生成後にPreview.appで即座にプレビュー表示。
- 処理終了後にキー入力を待機し、ターミナルウィンドウが勝手に閉じるのを防止。

---

## 8. エラーハンドリングと例外仕様 (Error Handling)

| エラー状況 | 発生箇所 | 処理内容・通知メッセージ | 終了コード |
| :--- | :--- | :--- | :---: |
| 対象ファイル/フォルダが存在しない | `convert` 初期処理 | `指定されたファイルまたはフォルダが存在しません: <PATH>` | 1 |
| Chrome実行バイナリが見つからない | `find_chrome` | `Google Chrome が見つかりませんでした。/Applications/Google Chrome.app がインストールされていることを確認してください。` | 1 |
| 対象内にHTMLファイルが1件も存在しない | HTMLファイル走査 | `フォルダ内にHTMLファイルが見つかりませんでした: <PATH>` | 1 |
| ZIP展開失敗 | `extract_zip` | `ZIP解凍に失敗しました: <PATH>` | 1 |
| ChromeによるPDF出力の失敗 | Chromeプロセス実行 | `ChromeのPDF出力処理でエラーが発生しました: <標準エラー出力内容>` | 1 |
| PDFファイルが生成されていない | 出力確認 | `PDFファイルが生成されませんでした。` | 1 |
| 未指定・空入力 | CLI引数パース | `入力が指定されていません。終了します。` | 1 |

---

## 9. Chromeバイナリ探索ロジック (Chrome Detection)

システム上で利用可能なブラウザを以下の優先順位で自動検索します：
1. `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
2. `/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary`
3. `/Applications/Chromium.app/Contents/MacOS/Chromium`
4. `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser`
5. `which google-chrome`
6. `which google-chrome-stable`
7. `which chromium`
8. `which chromium-browser`
※見つからない場合は `--chrome-path` オプションで任意の実行ファイルパスを指定可能。
