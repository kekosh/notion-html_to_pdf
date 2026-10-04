# notion-html_to_pdf

Notionから「サブページを含める」形式でHTMLエクスポートしたファイル群を、1つのまとまった高品質なPDFドキュメントに変換・結合するMac用ツールです（Ruby製）。

---

## 主な特徴

- 🧩 **ZIP直接対応**: NotionからダウンロードしたZIPファイルを解凍せずにそのまま指定可能（解凍済みフォルダにも対応）
- 📅 **日付プレフィックス付与**: 出力されるPDFファイル名の先頭に実行日（`yyyymmdd_`）を自動付与
- 🔖 **PDFブックマーク（目次）対応**: 閲覧ソフト（Preview/Acrobat等）のサイドバー目次（アウトライン）を自動生成
- 📑 **目次ページの生成オプション**: `--toc` を指定することで、先頭にクリック可能な目次ページ（階層インデント付き）を追加可能（デフォルトは生成なし）
- 🔗 **内部リンク維持**: サブページへのリンクをPDF内の該当ページへジャンプするアンカーリンクに自動変換
- 🖼️ **画像・アセット完全表示**: カバー画像、アイコン、埋め込み画像、図のローカルパスを自動解決
- 📂 **トグルの自動展開**: Notionのトグルリスト（`<details>`）を印刷用に自動展開し、内容の抜け漏れを防止
- 🖨️ **Notion純正デザインの再現**: NotionのスタイルシートとA4印刷用レイアウト（適切な改ページ制御）を融合

---

## 使い方

### 方法1: ターミナルからコマンド実行（おすすめ）

シンボリックリンクを設定しているため、任意のディレクトリから `notion-html_to_pdf` コマンドで実行できます：

```bash
# 基本的な使い方（元のファイルと同じ場所に「yyyymmdd_元の名前.pdf」が出力されます・余白あり）
notion-html_to_pdf /path/to/NotionExport.zip

# ページの余白なしで作成する場合
notion-html_to_pdf /path/to/NotionExport.zip --no-margin

# 余白サイズを任意に指定する場合（例: 10mm）
notion-html_to_pdf /path/to/NotionExport.zip --margin 10mm

# 先頭に目次ページを含めたい場合
  /path/to/NotionExport.zip --toc

# 生成後にMacのプレビューで自動表示する場合
notion-html_to_pdf /path/to/NotionExport.zip --open

# 出力先を指定する場合
notion-html_to_pdf /path/to/NotionExport.zip -o ~/Desktop/MyDocument.pdf
```

引数を省略して `notion-html_to_pdf` のみ実行した場合は、ファイルのドラッグ＆ドロップおよび余白の有無を選択するプロンプトが表示されます。

### 方法2: Finderからダブルクリックで実行

1. Finderで [notion-html_to_pdf.command](file:///Users/kekosh/tools/notion-html_to_pdf/notion-html_to_pdf.command) をダブルクリックします。
2. ターミナル画面が開いたら、Notionからエクスポートした **ZIPファイル または フォルダ** をドラッグ＆ドロップして **Enter** を押します。
3. ページの余白の有無（1: 余白あり / 2: 余白なし）を選択します（Enterで標準の余白あり）。
4. 処理完了後、自動的にプレビュー（Preview.app）でPDFが開きます。

---

## オプション一覧

```
使用法: notion-html_to_pdf [オプション] [入力ファイルまたはフォルダ]

オプション:
    -o, --output OUTPUT              出力先PDFファイルパス
        --toc                        先頭の目次ページを生成する (デフォルト: 生成しない)
        --no-toc                     先頭の目次ページを生成しない
        --no-margin                  ページの余白なし（0mm）で作成する
        --margin [SIZE]              ページの余白の有無またはサイズを指定 (例: none, 0, normal, 10mm 等 / デフォルト: normal)
        --keep-toggles-closed        トグルリストを自動展開せず閉じたままにする
        --chrome-path PATH           Google Chrome の実行ファイルパスを手動指定
        --open                       PDF生成後にプレビュー（Preview.app）で開く
    -h, --help                       ヘルプメッセージを表示
```

---

## ファイル構成

- [notion-html_to_pdf.rb](file:///Users/kekosh/tools/notion-html_to_pdf/notion-html_to_pdf.rb): 変換エンジンのスクリプト本体
- [notion-html_to_pdf.command](file:///Users/kekosh/tools/notion-html_to_pdf/notion-html_to_pdf.command): Finder用ランチャー
- コマンドシンボリックリンク: `/Users/kekosh/.local/bin/notion-html_to_pdf` （PATH設定済み）
