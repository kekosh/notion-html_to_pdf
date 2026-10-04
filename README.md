# notion-html_to_pdf

Notionから「サブページを含める」形式でHTMLエクスポートしたファイル群を、1つのまとまった高品質なPDFドキュメントに変換・結合するMac用ツールです（Ruby製）。

---

## 主な特徴

- 🧩 **ZIP直接対応**: NotionからダウンロードしたZIPファイルを解凍せずにそのまま指定可能（解凍済みフォルダにも対応）
- 📅 **日付プレフィックス付与**: 出力されるPDFファイル名の先頭に実行日（`yyyymmdd_`）を自動付与（すでに付与済みの場合は二重付与を自動防止）
- 🔖 **PDFブックマーク（目次）対応**: 閲覧ソフト（Preview/Acrobat等）のサイドバー目次（アウトライン）を自動生成
- 📑 **目次ページの生成オプション**: `--toc` を指定することで、先頭にクリック可能な目次ページ（階層インデント付き）を追加可能（デフォルトは生成なし）
- 🔗 **内部リンク維持**: サブページへのリンクをPDF内の該当ページへジャンプするアンカーリンクに自動変換
- 🖼️ **画像・アセット完全表示**: カバー画像、アイコン、埋め込み画像、図のローカルパスを自動解決
- 📂 **トグルの自動展開**: Notionのトグルリスト（`<details>`）を印刷用に自動展開し、内容の抜け漏れを防止
- 📄 **ヘッダー・フッター付与**: ヘッダーにファイル名（右上）、フッターにページ番号（中央 ` - No - ` 形式、例: ` - 1 - `）を自動出力（※要 Google Chrome 131 以降）
- ✂️ **任意の改ページ指定**: Notion上で `[改ページ]` または `[pagebreak]` と書くだけで意図した箇所で強制改ページ可能
- 🖨️ **Notion純正デザインの再現**: NotionのスタイルシートとA4印刷用レイアウト（適切な改ページ制御）を融合

---

## 意図的に改ページさせたい場合

Notion内で「ここから新しいページに送りたい」という箇所がある場合は、以下のいずれかの方法を利用できます：

1. **サブページとして分割する（推奨）**
   - Notion上で別ページ（サブページ）として作成すると、PDF化時に自動的に新しいページから開始されます。
2. **改ページマーカーを記載する**
   - ページ内の改ページしたい位置に、単独の段落で以下のように入力します：
     - `[改ページ]` または `[pagebreak]`（小文字・大文字どちらでも可）
     - `---pagebreak---` または `<pagebreak>`
   - PDF生成時にこのテキストは非表示となり、その位置で確実に次のページへ改ページされます。

## 使い方

### 方法1: ターミナルからスクリプト実行

本リポジトリのスクリプトを直接、または `ruby` コマンドで実行します：

```bash
# 基本的な使い方（元のファイルと同じ場所に「yyyymmdd_元の名前.pdf」が出力されます・余白あり）
./notion-html_to_pdf.rb /path/to/NotionExport.zip

# ページの余白なし（コンパクト）で作成する場合
./notion-html_to_pdf.rb /path/to/NotionExport.zip --no-margin

# 余白サイズを任意に指定する場合（例: 10mm）
./notion-html_to_pdf.rb /path/to/NotionExport.zip --margin 10mm

# 先頭に目次ページを含めたい場合
./notion-html_to_pdf.rb /path/to/NotionExport.zip --toc

# サブページのヘッダ画像を表示する場合（デフォルトは非表示）
./notion-html_to_pdf.rb /path/to/NotionExport.zip --subpage-covers

# 生成後にMacのプレビューで自動表示する場合
./notion-html_to_pdf.rb /path/to/NotionExport.zip --open

# 出力先を指定する場合
./notion-html_to_pdf.rb /path/to/NotionExport.zip -o ~/Desktop/MyDocument.pdf
```

引数を省略して `./notion-html_to_pdf.rb` のみ実行した場合は、ファイルのドラッグ＆ドロップ、余白の有無、サブページのヘッダ画像の表示/非表示を選択するプロンプトが表示されます。


### 方法2: Finderからダブルクリックで実行

1. Finderで `notion-html_to_pdf.command` をダブルクリックします。
2. ターミナル画面が開いたら、Notionからエクスポートした **ZIPファイル または フォルダ** をドラッグ＆ドロップして **Enter** を押します。
3. ページの余白の有無（1: 余白あり(標準) / 2: 余白なし(コンパクト)）を選択します（Enterで標準の余白あり）。
4. サブページのヘッダ画像の表示/非表示（1: 非表示 / 2: 表示）を選択します（Enterで標準の非表示）。
5. 処理完了後、自動的にプレビュー（Preview.app）でPDFが開きます。

---

## オプション一覧

```
使用法: notion-html_to_pdf.rb [オプション] [入力ファイルまたはフォルダ]

オプション:
    -o, --output OUTPUT              出力先PDFファイルパス
        --toc                        先頭の目次ページを生成する (デフォルト: 生成しない)
        --no-toc                     先頭の目次ページを生成しない
        --no-margin                  ページの余白なし（コンパクト: 上下12mm/左右10mm）で作成する
        --margin [SIZE]              ページの余白の有無またはサイズを指定 (例: none, normal, 10mm 等 / デフォルト: normal)
        --subpage-covers             サブページのヘッダ画像を表示する (デフォルト: 非表示)
        --no-subpage-covers          サブページのヘッダ画像を非表示にする
        --no-header-footer           ヘッダー（ファイル名）およびフッター（ページ番号）を表示しない
        --no-header                  ヘッダー（ファイル名）を表示しない
        --no-footer                  フッター（ページ番号）を表示しない
        --header-text TEXT           ヘッダーに表示するファイル名・テキストを指定 (デフォルト: 出力PDFファイル名)
        --header-left                ヘッダーのファイル名を左寄せで配置する (デフォルト: 右寄せ)
        --keep-toggles-closed        トグルリストを自動展開せず閉じたままにする
        --chrome-path PATH           Google Chrome の実行ファイルパスを手動指定
        --open                       PDF生成後にプレビュー（Preview.app）で開く
    -h, --help                       ヘルプメッセージを表示
```

---

## ファイル構成

- [notion-html_to_pdf.rb](notion-html_to_pdf.rb): 変換エンジンのスクリプト本体
- [notion-html_to_pdf.command](notion-html_to_pdf.command): Finder用ランチャー
- [SPECIFICATION.md](SPECIFICATION.md): 詳細仕様書
