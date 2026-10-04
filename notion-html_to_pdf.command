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
    echo "  [1] 余白あり (標準: 上下18mm / 左右16mm)"
    echo "  [2] 余白なし (コンパクト: 上下12mm / 左右10mm)"
    read -r -p "▶ 選択 (デフォルト: 1): " MARGIN_CHOICE
    echo ""
    echo "サブページのヘッダ画像（カバー画像）を選択してください："
    echo "  [1] 非表示 (標準)"
    echo "  [2] 表示する"
    read -r -p "▶ 選択 (デフォルト: 1): " COVER_CHOICE
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

COVER_OPT=""
if [ "$COVER_CHOICE" = "2" ] || [ "$COVER_CHOICE" = "yes" ]; then
    COVER_OPT="--subpage-covers"
fi

ruby "$RUBY_SCRIPT" "$TARGET" $MARGIN_OPT $COVER_OPT --open

echo ""
echo "キーを押すとこのウィンドウを閉じます..."
read -n 1 -s
