#!/bin/bash
# Notion to PDF Exporter Launcher (macOS)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUBY_SCRIPT="$SCRIPT_DIR/notion-html_to_pdf.rb"

echo "=========================================================="
echo "          Notion to PDF Exporter (単一PDF結合ツール)        "
echo "=========================================================="
echo ""

if [ -n "$1" ]; then
    TARGET="$1"
else
    echo "Notionからエクスポートした ZIPファイル または フォルダ を"
    echo "このウィンドウにドラッグ＆ドロップして、Enterキーを押してください："
    echo ""
    read -r -p "▶ 対象: " TARGET
    echo ""
    echo "ページの余白を選択してください："
    echo "  [1] 余白あり (標準)"
    echo "  [2] 余白なし"
    read -r -p "▶ 選択 (デフォルト: 1): " MARGIN_CHOICE
    echo ""
fi

if [ -z "$TARGET" ]; then
    echo "入力がありませんでした。終了します。"
    exit 1
fi

MARGIN_OPT=""
if [ "$MARGIN_CHOICE" = "2" ] || [ "$MARGIN_CHOICE" = "no" ]; then
    MARGIN_OPT="--no-margin"
fi

ruby "$RUBY_SCRIPT" "$TARGET" $MARGIN_OPT --open

echo ""
echo "キーを押すとこのウィンドウを閉じます..."
read -n 1 -s
