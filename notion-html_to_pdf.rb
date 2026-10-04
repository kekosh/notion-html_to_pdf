#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Notion to PDF Exporter (Ruby版)
# NotionからHTML形式でエクスポートされたページ群（サブページ含む）を、
# 目次付き・リンク保持・デザイン再現の単一PDFに結合するツール。
# ==============================================================================

require 'optparse'
require 'fileutils'
require 'tmpdir'
require 'uri'
require 'pathname'
require 'open3'

# Nokogiri が利用可能かチェック（無ければ正規表現フォールバック）
begin
  require 'nokogiri'
  HAVE_NOKOGIRI = true
rescue LoadError
  HAVE_NOKOGIRI = false
end

# rubyzip が利用可能かチェック（無ければ system 'unzip' フォールバック）
begin
  require 'zip'
  HAVE_RUBYZIP = true
rescue LoadError
  HAVE_RUBYZIP = false
end

module NotionToPdf
  module_function

  def find_chrome
    candidates = [
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
      '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
      `which google-chrome 2>/dev/null`.strip,
      `which google-chrome-stable 2>/dev/null`.strip,
      `which chromium 2>/dev/null`.strip,
      `which chromium-browser 2>/dev/null`.strip
    ]
    candidates.find { |c| !c.nil? && !c.empty? && File.exist?(c) && File.executable?(c) }
  end

  def clean_terminal_path(raw)
    return '' if raw.nil?

    p = raw.strip
    if (p.start_with?('"') && p.end_with?('"')) || (p.start_with?("'") && p.end_with?("'"))
      p = p[1..-2]
    end
    # ドラッグ＆ドロップ時のバックスラッシュエスケープを解除
    p = p.gsub(/\\ /, ' ').gsub(/\\\(/, '(').gsub(/\\\)/, ')')
    File.expand_path(p)
  end

  def to_file_uri(abs_path)
    'file://' + URI::DEFAULT_PARSER.escape(File.expand_path(abs_path))
  end

  def extract_zip(zip_path, target_dir)
    if HAVE_RUBYZIP
      Zip::File.open(zip_path) do |zip_file|
        zip_file.each do |entry|
          fpath = File.join(target_dir, entry.name)
          FileUtils.mkdir_p(File.dirname(fpath))
          zip_file.extract(entry, fpath) unless File.exist?(fpath)
        end
      end
    else
      system('unzip', '-q', zip_path, '-d', target_dir) || raise("ZIP解凍に失敗しました: #{zip_path}")
    end
  end

  def extract_title(html_content, fallback_name)
    if HAVE_NOKOGIRI
      doc = Nokogiri::HTML(html_content, nil, 'UTF-8')
      t = doc.at_css('h1.page-title')&.text&.strip
      return t if t && !t.empty?

      t = doc.at_css('title')&.text&.strip
      return t if t && !t.empty?
    else
      if html_content =~ %r{<h1[^>]*class=["'][^"']*page-title[^"']*["'][^>]*>(.*?)</h1>}im
        t = Regexp.last_match(1).gsub(/<[^>]+>/, '').strip
        return t unless t.empty?
      end
      if html_content =~ %r{<title>(.*?)</title>}im
        t = Regexp.last_match(1).gsub(/<[^>]+>/, '').strip
        return t unless t.empty?
      end
    end

    # Notionの末尾32文字の16進ハッシュを除去したファイル名
    clean_name = fallback_name.sub(/\s+[0-9a-fA-F]{32}$/, '').strip
    clean_name.empty? ? fallback_name : clean_name
  end

  def extract_page_id(html_content, fallback_id)
    if html_content =~ /<article[^>]*id=["']([^"']+)["']/i
      Regexp.last_match(1)
    else
      fallback_id.gsub(/[^a-zA-Z0-9_-]/, '_')
    end
  end

  def extract_internal_links(html_content, file_dir)
    links = []
    if HAVE_NOKOGIRI
      doc = Nokogiri::HTML(html_content, nil, 'UTF-8')
      doc.css('a[href]').each do |a|
        href = a['href']
        next if href.nil? || href.start_with?('#', 'http://', 'https://', 'mailto:')

        clean_href = href.split('?').first.split('#').first
        next unless clean_href.downcase.end_with?('.html')

        unquoted = URI::DEFAULT_PARSER.unescape(clean_href)
        abs_target = File.expand_path(File.join(file_dir, unquoted))
        links << abs_target
      end
    else
      html_content.scan(/<a\b[^>]*\bhref=["']([^"'#]+\.html)(?:#[^"']*)?["']/i) do |match|
        raw_href = match.first
        unquoted = URI::DEFAULT_PARSER.unescape(raw_href)
        abs_target = File.expand_path(File.join(file_dir, unquoted))
        links << abs_target
      end
    end
    links.uniq
  end

  def extract_styles(html_content)
    if HAVE_NOKOGIRI
      doc = Nokogiri::HTML(html_content, nil, 'UTF-8')
      doc.css('style').map(&:inner_html)
    else
      styles = []
      html_content.scan(/<style\b[^>]*>(.*?)<\/style>/im) do |m|
        styles << m.first
      end
      styles
    end
  end

  def get_image_size(path)
    return nil unless path && File.exist?(path)

    bytes = (File.binread(path, 32) rescue nil)
    if bytes
      if bytes[0, 8] == "\x89PNG\r\n\x1a\n".b
        return bytes[16, 8].unpack("N2")
      elsif bytes.start_with?("GIF87a".b, "GIF89a".b)
        return bytes[6, 4].unpack("v2")
      end
    end

    # sips を用いた JPEG / WebP 等の寸法取得フォールバック (macOS)
    out = `sips -g pixelWidth -g pixelHeight "#{path}" 2>/dev/null`
    w = out[/pixelWidth:\s*(\d+)/, 1]&.to_i
    h = out[/pixelHeight:\s*(\d+)/, 1]&.to_i
    return [w, h] if w && h && w > 0 && h > 0

    nil
  rescue StandardError
    nil
  end

  def get_callout_figures(callout)
    figs = callout.css('figure').to_a
    callout.css('img:not(.icon):not(.notion-static-icon)').each do |img|
      figs << img unless img.ancestors('figure').any?
    end
    figs
  end

  def estimate_figure_height(fig, page_dir)
    img = fig.name == 'img' ? fig : fig.at_css('img')
    return 250.0 unless img

    src = img['src']
    return 250.0 unless src

    file_path = if src.start_with?('file://')
                  URI::DEFAULT_PARSER.unescape(src.sub(%r{^file://}, ''))
                elsif !src.start_with?('http://', 'https://', 'data:')
                  clean_src = src.split('?').first.split('#').first
                  File.expand_path(File.join(page_dir, URI::DEFAULT_PARSER.unescape(clean_src)))
                end

    w_px, h_px = get_image_size(file_path) if file_path
    if w_px && h_px && w_px > 0 && h_px > 0
      content_w = 400.0 # コールアウト内の印刷コンテンツ幅 (pt)
      disp_h = content_w * (h_px.to_f / w_px.to_f)
      caption = fig.at_css('figcaption')
      caption_h = caption ? 25.0 : 0.0
      [disp_h + caption_h + 15.0, 650.0].min
    else
      250.0
    end
  end

  def estimate_callout_height(callout, page_dir)
    h = 40.0 # 上下パディングとマージン
    body = callout.at_css('> div:last-child') || callout
    figs = get_callout_figures(body)
    figs.each { |f| h += estimate_figure_height(f, page_dir) }

    body.css('p, h1, h2, h3, h4, h5, h6, li').each do |el|
      next if el.ancestors('figure').any?

      text = el.text.strip
      next if text.empty?

      lines = [(text.length / 35.0).ceil, text.lines.count, 1].max
      line_h = el.name =~ /^h/ ? 28.0 : 20.0
      h += lines * line_h
    end
    h
  end

  def convert(input_path, output_pdf: nil, include_toc: false, margin: true, open_toggles: true, show_subpage_covers: false, chrome_path: nil, auto_open: false)
    input_path = clean_terminal_path(input_path)
    raise "指定されたファイルまたはフォルダが存在しません: #{input_path}" unless File.exist?(input_path)

    chrome_bin = chrome_path || find_chrome
    if chrome_bin.nil? || !File.exist?(chrome_bin)
      raise "Google Chrome が見つかりませんでした。\n/Applications/Google Chrome.app がインストールされていることを確認してください。"
    end

    temp_dir = nil
    begin
      if File.file?(input_path) && input_path.downcase.end_with?('.zip')
        temp_dir = Dir.mktmpdir('notion_pdf_')
        puts "📦 ZIPファイルを展開中: #{File.basename(input_path)}"
        extract_zip(input_path, temp_dir)
        source_dir = temp_dir
        base_name = File.basename(input_path, '.*')
        out_dir = File.dirname(input_path)
      elsif File.directory?(input_path)
        source_dir = input_path
        base_name = File.basename(input_path.chomp('/'))
        out_dir = File.dirname(input_path.chomp('/'))
      else
        raise 'NotionエクスポートのZIPファイルまたはフォルダを指定してください。'
      end

      date_prefix = Time.now.strftime('%Y%m%d_')
      if output_pdf
        cleaned_out = clean_terminal_path(output_pdf)
        out_dirname = File.dirname(cleaned_out)
        out_basename = File.basename(cleaned_out)
        final_basename = out_basename.start_with?(date_prefix) ? out_basename : "#{date_prefix}#{out_basename}"
        output_pdf = File.join(out_dirname, final_basename)
      else
        output_pdf = File.join(out_dir, "#{date_prefix}#{base_name}.pdf")
      end

      # HTMLファイルを収集
      all_html_files = Dir.glob(File.join(source_dir, '**', '*.html')).reject do |f|
        bn = File.basename(f)
        bn.start_with?('._') || bn.start_with?('_merged_')
      end.map { |f| File.expand_path(f) }

      raise "フォルダ内にHTMLファイルが見つかりませんでした: #{input_path}" if all_html_files.empty?

      puts "📄 対象HTMLファイル: #{all_html_files.size} 件"

      # 各ページのメタデータを解析
      pages = {}
      all_html_files.each do |hpath|
        content = File.read(hpath, encoding: 'UTF-8', invalid: :replace, undef: :replace, replace: '')
        file_stem = File.basename(hpath, '.*')
        file_dir = File.dirname(hpath)

        title = extract_title(content, file_stem)
        pid = extract_page_id(content, file_stem)
        links = extract_internal_links(content, file_dir)
        styles = extract_styles(content)

        pages[hpath] = {
          path: hpath,
          title: title,
          id: pid,
          links: links,
          raw_content: content,
          styles: styles
        }
      end

      # ルートページの特定（パスの深さが最も浅いもの）
      sorted_by_depth = all_html_files.sort_by do |p|
        rel = Pathname.new(p).relative_path_from(Pathname.new(source_dir)).to_s
        [rel.split(File::SEPARATOR).size, p]
      end
      root_path = sorted_by_depth.first

      # 深さ優先探索（DFS）でページを階層順に並び替え
      ordered_pages = []
      visited = {}

      traverse = lambda do |p, depth|
        return if visited[p] || !pages.key?(p)

        visited[p] = true
        info = pages[p]
        info[:depth] = depth
        ordered_pages << info

        info[:links].each do |child|
          traverse.call(child, depth + 1)
        end
      end

      traverse.call(root_path, 0)

      # リンクで辿れなかった残りのHTMLファイルも階層順に追加
      sorted_by_depth.each do |p|
        next if visited[p] || !pages.key?(p)

        rel = Pathname.new(p).relative_path_from(Pathname.new(source_dir)).to_s
        depth = [1, rel.split(File::SEPARATOR).size - 1].max
        pages[p][:depth] = depth
        ordered_pages << pages[p]
        visited[p] = true
      end

      puts "\n📚 結合構成一覧:"
      ordered_pages.each do |p|
        indent = '  ' * p[:depth]
        icon = p[:depth].zero? ? '📘 ' : '📄 '
        puts "  #{indent}#{icon}#{p[:title]}"
      end
      puts ''

      # スタイルの抽出（Notion標準スタイルを維持）
      all_styles = []
      ordered_pages.each do |p|
        if p[:styles] && !p[:styles].empty?
          all_styles.concat(p[:styles])
          break
        end
      end

      # @import ルールを抽出してスタイルシートの最上部に配置
      imports = []
      other_rules = []
      all_styles.each do |st|
        st.scan(/@import\s+url\([^)]+\)[^;]*;?/i) do |imp|
          clean_imp = imp.strip
          clean_imp += ';' unless clean_imp.end_with?(';')
          imports << clean_imp
        end
        no_import = st.gsub(/@import\s+url\([^)]+\)[^;]*;?/i, '')
        no_page = no_import.gsub(/@page\s*\{[^}]*\}/mi, '')
        other_rules << no_page
      end

      clean_base_css = other_rules.join("\n")
      import_css = imports.uniq.join("\n")

      # 余白設定の判定
      margin_css = case margin
                   when false, nil, 'none', '0', 'no', '0mm'
                     '12mm 10mm 12mm 10mm'
                   when true, 'normal', 'default', 'yes'
                     '18mm 16mm 18mm 16mm'
                   when 'zero', 'absolute-zero'
                     '0'
                   else
                     margin.to_s
                   end

      margin_desc = case margin_css
                    when '12mm 10mm 12mm 10mm'
                      'なし (コンパクト: 上下12mm / 左右10mm)'
                    when '18mm 16mm 18mm 16mm'
                      'あり (標準: 上下18mm / 左右16mm)'
                    when '0'
                      '完全ゼロ (0mm)'
                    else
                      margin_css
                    end
      puts "📐 余白設定: #{margin_desc}"
      puts "🖼️  サブページヘッダ画像: #{show_subpage_covers ? '表示' : '非表示 (デフォルト)'}"

      # PDF印刷用最適化CSS
      print_opt_css = <<~CSS
        @page {
          size: A4;
          margin: #{margin_css};
        }
        @media print {
          body {
            -webkit-print-color-adjust: exact !important;
            print-color-adjust: exact !important;
            background-color: #ffffff !important;
          }
          .notion-page-container {
            break-before: page !important;
            page-break-before: always !important;
          }
          .notion-page-container:first-of-type {
            break-before: auto !important;
            page-break-before: auto !important;
          }

          /* 1. 見出しの泣き別れ防止 & 余白の最適化 */
          h1, h2, h3, h4, summary, .chapter-header {
            break-after: avoid !important;
            page-break-after: avoid !important;
          }

          /* ページ先頭やコンテナ先頭の見出し上余白を除去 */
          .page-body > h1:first-child,
          .page-body > h2:first-child,
          .page-body > h3:first-child,
          .page-body > h4:first-child,
          header + .page-body > h1:first-child,
          header + .page-body > h2:first-child,
          header + .page-body > h3:first-child {
            margin-top: 0 !important;
          }

          /* トグル内部の見出しリセット */
          summary h1,
          summary h2,
          summary h3,
          summary h4 {
            margin-top: 0 !important;
            margin-bottom: 0 !important;
          }

          /* コールアウト内部の見出しリセット */
          .callout h1,
          .callout h2,
          .callout h3,
          .callout h4 {
            margin-top: 0 !important;
            margin-bottom: 0.3rem !important;
          }

          /* 背景色付き見出しのパディングと角丸 */
          h1[class*="block-color-"],
          h2[class*="block-color-"],
          h3[class*="block-color-"],
          h4[class*="block-color-"] {
            padding: 0.15em 0.35em !important;
            border-radius: 3px !important;
          }

          /* ページリンク（サブページ導線）ブロックの余白・デザイン統一 */
          figure.link-to-page,
          .link-to-page {
            margin: 0.18em 0 !important;
            padding: 0 !important;
            font-weight: 500 !important;
          }
          figure.link-to-page + figure.link-to-page,
          .link-to-page + .link-to-page {
            margin-top: 0.12em !important;
          }

          /* 空のページ説明文のマージンを除去し、タイトル下の余白を適正化 */
          p.page-description:empty {
            margin: 0 !important;
            display: none !important;
          }
          .page-description {
            margin-top: 0.2em !important;
            margin-bottom: 0.6em !important;
          }
          .page-title {
            margin-bottom: 0.4em !important;
          }

          /* 2. コンテンツブロックの分断防止と改ページ制御 */
          figure,
          figure.image,
          tr,
          pre, code, blockquote, .collection-content, .board-card {
            break-inside: avoid !important;
            page-break-inside: avoid !important;
          }
          table {
            break-inside: auto !important;
            page-break-inside: auto !important;
          }
          thead {
            display: table-header-group !important;
          }

          /* 3. 画像のサイズ設定 */
          img {
            max-width: 100% !important;
            max-height: 100vh !important;
            width: auto !important;
            height: auto !important;
            object-fit: contain;
            break-inside: avoid !important;
            page-break-inside: avoid !important;
          }
          img.page-cover-image {
            width: 100% !important;
            height: auto !important;
            max-height: 30vh !important;
            object-fit: contain !important;
            object-position: center !important;
          }
          .page-header-icon img {
            max-width: none !important;
            max-height: none !important;
            object-fit: contain;
          }

          /* 4. 明示的改ページ */
          .chapter-section,
          .force-page-break {
            break-before: page !important;
            page-break-before: always !important;
          }

          /* 5. コールアウトの改ページ対応およびアイコンとテキストの上下・左右のズレ解消 */
          .callout,
          aside.callout,
          aside {
            display: flex !important;
            flex-direction: row !important;
            align-items: flex-start !important;
            white-space: normal !important;
            border-radius: 10px !important;
            padding: 1rem !important;
            -webkit-box-decoration-break: clone !important;
            box-decoration-break: clone !important;
            break-inside: auto !important;
            page-break-inside: auto !important;
            margin-top: 1rem !important;
            margin-bottom: 1rem !important;
          }
          /* 連続するコールアウトの間隔を詰める */
          .callout + .callout,
          aside.callout + aside.callout,
          aside + aside {
            margin-top: 0.5rem !important;
          }
          /* コールアウト内部要素（段落・画像等）の余白適正化 */
          .callout figure,
          .callout figure.image {
            margin-top: 0.4rem !important;
            margin-bottom: 0.2rem !important;
          }
          /* アイコン付きコールアウトのアイコン領域（直後に本文divがある1つ目のdiv） */
          .callout > div:first-child:not(:last-child) {
            display: flex !important;
            align-items: center !important;
            justify-content: center !important;
            width: 1.5rem !important;
            height: 1.5rem !important;
            min-width: 1.5rem !important;
            max-width: 1.5rem !important;
            margin-right: 10px !important;
            margin-top: 2px !important;
            flex-shrink: 0 !important;
            line-height: 1 !important;
          }
          .callout > div:first-child:not(:last-child) .icon {
            display: flex !important;
            align-items: center !important;
            justify-content: center !important;
            width: 100% !important;
            height: 100% !important;
            margin-right: 0 !important;
            vertical-align: middle !important;
            line-height: 1 !important;
            font-size: 1.25rem !important;
          }
          .callout > div:first-child:not(:last-child) .icon[data-emoji]::before {
            display: block !important;
            line-height: 1 !important;
            text-align: center !important;
          }
          .callout > div:first-child:not(:last-child) img,
          .callout .icon img,
          .callout img.icon,
          .callout img.notion-static-icon {
            width: 1.25rem !important;
            height: 1.25rem !important;
            max-width: 1.25rem !important;
            max-height: 1.25rem !important;
            object-fit: contain !important;
          }
          /* コールアウト本文領域（最後のdiv、またはアイコン無しの唯一のdiv） */
          .callout > div:last-child {
            flex: 1 1 auto !important;
            width: 100% !important;
            min-width: 0 !important;
            line-height: 1.5 !important;
            white-space: normal !important;
          }
          .callout > div:only-child {
            width: 100% !important;
            max-width: 100% !important;
            margin-right: 0 !important;
            margin-top: 0 !important;
          }
          .callout > div:last-child p {
            white-space: pre-wrap !important;
            margin: 0 !important;
          }
          .callout > div:last-child > :first-child {
            margin-top: 0 !important;
          }
          .callout > div:last-child > :last-child {
            margin-bottom: 0 !important;
          }

          /* 6. コールアウト内のテキストと直下の画像のセット化（改ページ泣き別れ防止） */
          .callout.callout-atomic,
          .callout-figure-pair {
            break-inside: avoid !important;
            page-break-inside: avoid !important;
          }
          .callout p:has(+ figure),
          .callout p:has(+ .image) {
            break-after: avoid !important;
            page-break-after: avoid !important;
          }

          details {
            display: block !important;
          }
          details[open] summary ~ * {
            display: block !important;
          }
        }
        body, .notion-page-container, article.page, header {
          white-space: normal !important;
          margin-top: 0 !important;
          padding-top: 0 !important;
        }
        .page-body {
          white-space: normal !important;
        }
        .page-body p,
        .page-body li {
          white-space: pre-wrap;
        }
        .page-cover-image {
          margin-top: 0 !important;
          padding-top: 0 !important;
        }
        .notion-page-container.subpage.no-cover .page-cover-image,
        .notion-page-container.subpage.no-cover img.page-cover-image {
          display: none !important;
        }
        .notion-page-container.subpage.no-cover .page-header-icon-with-cover,
        .notion-page-container.subpage.no-cover .page-header-icon {
          margin-top: 0 !important;
          top: 0 !important;
        }
        .notion-page-container.subpage.no-cover header {
          margin-top: 0 !important;
          padding-top: 0 !important;
        }
        body {
          margin: 0 !important;
          padding: 0 !important;
        }
        article.page {
          max-width: 100% !important;
          padding: 0 !important;
          margin: 0 0 20px 0 !important;
        }
        .toc-container {
          padding: 10px 0 30px 0;
          break-after: page;
          page-break-after: always;
        }
        .toc-title {
          font-size: 2em;
          font-weight: 700;
          margin-bottom: 20px;
          border-bottom: 2px solid #e0e0e0;
          padding-bottom: 8px;
        }
        .toc-list {
          list-style: none;
          padding-left: 0;
          line-height: 1.8;
          font-size: 15px;
        }
        .toc-item {
          margin: 4px 0;
        }
        .toc-item a {
          color: #206095;
          text-decoration: none;
        }
        .toc-item a:hover {
          text-decoration: underline;
        }
      CSS

      merged_sections = []

      # 目次 (TOC) 生成
      if include_toc && ordered_pages.size > 1
        toc_items = ordered_pages.map do |p|
          margin_left = p[:depth] * 24
          prefix = p[:depth].zero? ? '📘 ' : '📄 '
          <<~HTML
            <li class="toc-item" style="margin-left: #{margin_left}px;">
              #{prefix}<a href="#page-#{p[:id]}">#{p[:title]}</a>
            </li>
          HTML
        end

        toc_html = <<~HTML
          <div class="notion-page-container toc-container" id="notion-table-of-contents">
            <article class="page sans">
              <header><h1 class="page-title">📑 目次</h1></header>
              <div class="page-body">
                <ul class="toc-list">
                  #{toc_items.join("\n")}
                </ul>
              </div>
            </article>
          </div>
        HTML
        merged_sections << toc_html
      end

      # 内部リンク書き換え用ルックアップ
      path_to_id = ordered_pages.each_with_object({}) { |p, h| h[p[:path]] = p[:id] }

      # 各ページ内容の結合・整形
      ordered_pages.each do |p|
        content = p[:raw_content]
        page_dir = File.dirname(p[:path])
        is_subpage = p[:depth] > 0
        hide_cover = is_subpage && !show_subpage_covers

        if HAVE_NOKOGIRI
          doc = Nokogiri::HTML.fragment(content)
          article = doc.at_css('article') || doc.at_css('body') || doc

          # サブページのヘッダ画像を除去
          if hide_cover
            article.css('img.page-cover-image, .page-cover-image').remove
            article.css('.page-header-icon-with-cover').each do |el|
              el['class'] = el['class'].gsub(/\bpage-header-icon-with-cover\b/, '').strip
            end
          end

          # トグルを展開
          if open_toggles
            article.css('details').each { |d| d['open'] = '' }
          end

          # 画像・メディアの src を絶対 file:// URI に解決
          article.css('img, video, audio, source').each do |el|
            src = el['src']
            next if src.nil? || src.start_with?('http://', 'https://', 'data:', 'file://', '//')

            clean_src = src.split('?').first.split('#').first
            unquoted = URI::DEFAULT_PARSER.unescape(clean_src)
            abs_asset = File.expand_path(File.join(page_dir, unquoted))
            el['src'] = to_file_uri(abs_asset) if File.exist?(abs_asset)
          end

          # インラインスタイルの url(...) を解決
          article.css('[style]').each do |el|
            style = el['style']
            next unless style =~ /url\(/i

            new_style = style.gsub(/url\((["']?)([^"')\s]+)(["']?\))/i) do
              prefix = "url(#{Regexp.last_match(1)}"
              raw_url = Regexp.last_match(2)
              suffix = "#{Regexp.last_match(3)})"
              if raw_url.start_with?('http://', 'https://', 'data:', 'file://', '//')
                Regexp.last_match(0)
              else
                clean_url = raw_url.split('?').first.split('#').first
                unquoted = URI::DEFAULT_PARSER.unescape(clean_url)
                abs_asset = File.expand_path(File.join(page_dir, unquoted))
                File.exist?(abs_asset) ? "#{prefix}#{to_file_uri(abs_asset)}#{suffix}" : Regexp.last_match(0)
              end
            end
            el['style'] = new_style
          end

          # ページ間リンクをアンカーリンク (#page-xxx) に書き換え
          article.css('a[href]').each do |a|
            href = a['href']
            next if href.nil? || href.start_with?('#', 'http://', 'https://', 'mailto:')

            clean_href = href.split('#').first
            unquoted = URI::DEFAULT_PARSER.unescape(clean_href)
            abs_target = File.expand_path(File.join(page_dir, unquoted))

            if path_to_id.key?(abs_target)
              a['href'] = "#page-#{path_to_id[abs_target]}"
            elsif File.exist?(abs_target)
              a['href'] = to_file_uri(abs_target)
            end
          end

          # 単独のページリンクやメンションを含む段落 <p> を figure.link-to-page に正規化
          article.css('p').each do |p_node|
            link = p_node.at_css('> a')
            next unless link

            non_link_text = p_node.children.reject { |c| c == link }.map(&:text).join.strip
            if non_link_text.empty? && (link['data-notion-page-id'] || link.at_css('.icon'))
              p_node.name = 'figure'
              classes = (p_node['class'] || '').split
              classes << 'link-to-page' unless classes.include?('link-to-page')
              p_node['class'] = classes.join(' ')
            end
          end

          # コールアウト内のテキストと画像のセット化・分割処理
          # コールアウト全体が1ページで表示できる場合は分割せず維持
          # 複数ページに渡る場合のみ画像単位でコールアウトを分割
          article.css('.callout').to_a.each do |callout|
            figures = get_callout_figures(callout)
            next if figures.empty?

            est_h = estimate_callout_height(callout, page_dir)

            if est_h <= 650.0 || figures.size <= 1
              # コールアウト全体が1ページで表示できる、または画像が1件のみの場合は分割しない
              classes = (callout['class'] || '').split
              classes << 'callout-atomic' unless classes.include?('callout-atomic')
              callout['class'] = classes.join(' ')
            else
              # 複数ページに渡って表示される場合は画像ごとにコールアウト自体を分割
              icon_div = callout.at_css('> div:first-child:not(:last-child)')
              body_div = callout.element_children.last
              next unless body_div

              children = body_div.element_children.to_a
              segments = []
              current_segment = []

              children.each do |child|
                current_segment << child
                if child.name == 'figure' || child.at_css('img:not(.icon):not(.notion-static-icon)')
                  segments << current_segment
                  current_segment = []
                end
              end

              if !current_segment.empty?
                if segments.empty?
                  segments << current_segment
                else
                  segments.last.concat(current_segment)
                end
              end

              next if segments.size <= 1

              # 各セグメントから独立したコールアウトを生成
              new_callouts = segments.each_with_index.map do |seg, idx|
                new_aside = Nokogiri::XML::Node.new('aside', doc)
                callout.attributes.each do |attr_name, attr_val|
                  new_aside[attr_name] = attr_val.value
                end
                classes = (new_aside['class'] || '').split
                classes << 'callout-atomic' unless classes.include?('callout-atomic')
                new_aside['class'] = classes.join(' ')

                # 1つ目の分割コールアウトには元のアイコンを含める
                new_aside.add_child(icon_div.dup) if idx.zero? && icon_div

                new_body = Nokogiri::XML::Node.new('div', doc)
                body_div.attributes.each do |attr_name, attr_val|
                  new_body[attr_name] = attr_val.value
                end
                seg.each { |el| new_body.add_child(el) }
                new_aside.add_child(new_body)

                new_aside
              end

              new_callouts.each { |nc| callout.add_previous_sibling(nc) }
              callout.remove
            end
          end

          body_html = article.to_html
        else
          # Nokogiri がない場合の正規表現フォールバック
          body_html = if content =~ %r{(<article\b[^>]*>.*?</article>)}im
                        Regexp.last_match(1)
                      elsif content =~ %r{<body\b[^>]*>(.*?)</body>}im
                        Regexp.last_match(1)
                      else
                        content
                      end

          # サブページのヘッダ画像を除去
          if hide_cover
            body_html = body_html.gsub(%r{<img\b[^>]*class=["'][^"']*page-cover-image[^"']*["'][^>]*>}i, '')
            body_html = body_html.gsub(/\bpage-header-icon-with-cover\b/, '')
          end

          if open_toggles
            body_html = body_html.gsub(/<details(?![^>]*\bopen\b)/i, '<details open=""')
          end

          # src の解決
          body_html = body_html.gsub(/(\bsrc=["'])([^"'\s>]+)(["'])/i) do
            attr = Regexp.last_match(1)
            raw_url = Regexp.last_match(2)
            quote = Regexp.last_match(3)
            if raw_url.start_with?('http://', 'https://', 'data:', 'file://', '//')
              Regexp.last_match(0)
            else
              clean_url = raw_url.split('?').first.split('#').first
              unquoted = URI::DEFAULT_PARSER.unescape(clean_url)
              abs_asset = File.expand_path(File.join(page_dir, unquoted))
              File.exist?(abs_asset) ? "#{attr}#{to_file_uri(abs_asset)}#{quote}" : Regexp.last_match(0)
            end
          end

          # url(...) の解決
          body_html = body_html.gsub(/(\burl\(["']?)([^"')\s]+)(["']?\))/i) do
            prefix = Regexp.last_match(1)
            raw_url = Regexp.last_match(2)
            suffix = Regexp.last_match(3)
            if raw_url.start_with?('http://', 'https://', 'data:', 'file://', '//')
              Regexp.last_match(0)
            else
              clean_url = raw_url.split('?').first.split('#').first
              unquoted = URI::DEFAULT_PARSER.unescape(clean_url)
              abs_asset = File.expand_path(File.join(page_dir, unquoted))
              File.exist?(abs_asset) ? "#{prefix}#{to_file_uri(abs_asset)}#{suffix}" : Regexp.last_match(0)
            end
          end

          # a href の書き換え
          body_html = body_html.gsub(/(<a\b[^>]*\bhref=["'])([^"']+)(["'])/i) do
            prefix = Regexp.last_match(1)
            raw_url = Regexp.last_match(2)
            suffix = Regexp.last_match(3)
            if raw_url.start_with?('#', 'http://', 'https://', 'mailto:')
              Regexp.last_match(0)
            else
              clean_url = raw_url.split('#').first
              unquoted = URI::DEFAULT_PARSER.unescape(clean_url)
              abs_target = File.expand_path(File.join(page_dir, unquoted))
              if path_to_id.key?(abs_target)
                "#{prefix}#page-#{path_to_id[abs_target]}#{suffix}"
              elsif File.exist?(abs_target)
                "#{prefix}#{to_file_uri(abs_target)}#{suffix}"
              else
                Regexp.last_match(0)
              end
            end
          end
        end

        unless HAVE_NOKOGIRI
          # 単独のページリンク段落を figure.link-to-page に正規化
          body_html = body_html.gsub(%r{<p\b([^>]*)>\s*(<a\b[^>]*(?:data-notion-page-id|class=["'][^"']*icon)[^>]*>.*?</a>)\s*</p>}im) do
            attrs = Regexp.last_match(1)
            link_content = Regexp.last_match(2)
            clean_attrs = attrs.gsub(/\bclass=["'][^"']*["']/i, '')
            %(<figure class="link-to-page"#{clean_attrs}>#{link_content}</figure>)
          end

          # コールアウト内のテキストと直下の画像をセット化・分割
          body_html = body_html.gsub(%r{(<aside\b([^>]*)class=["']([^"']*callout[^"']*)["']([^>]*)>)(.*?)(</aside>)}m) do
            full_aside = Regexp.last_match(0)
            before_class = Regexp.last_match(2)
            classes = Regexp.last_match(3)
            after_class = Regexp.last_match(4)
            c_body = Regexp.last_match(5)
            c_close = Regexp.last_match(6)

            fig_count = c_body.scan(/<figure\b/i).size
            text_chars = c_body.gsub(/<[^>]+>/, '').strip.length
            est_h = 40.0 + (fig_count * 250.0) + ((text_chars / 35.0) * 20.0)

            if est_h <= 650.0 || fig_count <= 1
              classes_with_atomic = "#{classes} callout-atomic"
              %(<aside #{before_class}class="#{classes_with_atomic}"#{after_class}>#{c_body}#{c_close})
            else
              # 複数ページに渡る場合は2つ目以降の画像ごとにコールアウトを分割
              pairs = c_body.split(/(?<=<\/figure>)/i)
              new_callouts = pairs.map.with_index do |part, idx|
                part_trimmed = part.strip
                next nil if part_trimmed.empty?

                content = if idx.zero?
                            part_trimmed
                          else
                            part_trimmed.sub(%r{<div\b[^>]*class=["'][^"']*icon[^"']*["'][^>]*>.*?</div>}im, '')
                          end
                %(<aside #{before_class}class="#{classes} callout-atomic"#{after_class}>#{content}#{c_close})
              end.compact
              new_callouts.empty? ? full_aside : new_callouts.join("\n")
            end
          end
        end

        # コールアウト内の不要なタグ間改行（white-space: pre-wrap 下で空白行化するもの）を除去
        body_html = body_html.gsub(/(<aside\b[^>]*class=["'][^"']*callout[^"']*["'][^>]*>.*?<\/aside>)/m) do |callout_chunk|
          callout_chunk.gsub(/(<div\b[^>]*>)\s*\n\s*(<[a-z0-9]+)/i, '\1\2')
                       .gsub(/(<\/[a-z0-9]+>)\s*\n\s*(<div\b)/i, '\1\2')
        end

        container_classes = ['notion-page-container']
        container_classes << 'subpage' if is_subpage
        container_classes << 'no-cover' if hide_cover

        section_html = %(<div class="#{container_classes.join(' ')}" id="page-#{p[:id]}">#{body_html}</div>)
        merged_sections << section_html
      end

      # マスターHTMLの生成
      master_html = <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>#{ordered_pages.first[:title]}</title>
          <style>
            #{import_css}
            #{clean_base_css}
            #{print_opt_css}
          </style>
        </head>
        <body class="sans">
          #{merged_sections.join("\n")}
        </body>
        </html>
      HTML

      master_html_path = File.join(source_dir, '_merged_notion_master.html')
      File.write(master_html_path, master_html, encoding: 'UTF-8')

      puts '🖨️  PDFを作成中...'
      puts "   出力先: #{output_pdf}"

      cmd = [
        chrome_bin,
        '--headless=new',
        '--disable-gpu',
        '--allow-file-access-from-files',
        '--no-pdf-header-footer',
        '--generate-pdf-document-outline',
        "--print-to-pdf=#{output_pdf}",
        master_html_path
      ]

      stdout, stderr, status = Open3.capture3(*cmd)
      unless status.success?
        raise "ChromeのPDF出力処理でエラーが発生しました:\n#{stderr}"
      end

      raise 'PDFファイルが生成されませんでした。' unless File.exist?(output_pdf)

      size_kb = File.size(output_pdf) / 1024.0
      puts "\n✨ 完了しました！"
      puts "   📄 生成PDF: #{output_pdf}"
      puts "   📦 ファイルサイズ: #{format('%.1f', size_kb)} KB\n\n"

      system('open', output_pdf) if auto_open
      output_pdf
    ensure
      FileUtils.remove_entry(temp_dir) if temp_dir && File.exist?(temp_dir)
    end
  end
end

# CLI実行用エントリーポイント
if __FILE__ == $PROGRAM_NAME
  options = {
    include_toc: false,
    margin: true,
    open_toggles: true,
    show_subpage_covers: false,
    auto_open: false,
    chrome_path: nil,
    output_pdf: nil
  }

  parser = OptionParser.new do |opts|
    opts.banner = '使用法: notion-html_to_pdf.rb [オプション] [入力ファイルまたはフォルダ]'
    opts.separator ''
    opts.separator 'Notion HTMLエクスポート（サブページ含む）を1つの高品質PDFに結合します。'
    opts.separator ''
    opts.separator 'オプション:'

    opts.on('-o', '--output OUTPUT', '出力先PDFファイルパス') do |v|
      options[:output_pdf] = v
    end

    opts.on('--toc', '先頭の目次ページを生成する (デフォルト: 生成しない)') do
      options[:include_toc] = true
    end

    opts.on('--no-toc', '先頭の目次ページを生成しない') do
      options[:include_toc] = false
    end

    opts.on('--no-margin', 'ページの余白なし（コンパクト: 上下12mm/左右10mm）で作成する') do
      options[:margin] = false
    end

    opts.on('--margin [SIZE]', 'ページの余白の有無またはサイズを指定 (例: none, normal, 10mm 等 / デフォルト: normal)') do |v|
      options[:margin] = (v.nil? || v.empty?) ? true : v
    end

    opts.on('--subpage-covers', 'サブページのヘッダ画像を表示する (デフォルト: 非表示)') do
      options[:show_subpage_covers] = true
    end

    opts.on('--no-subpage-covers', 'サブページのヘッダ画像を非表示にする') do
      options[:show_subpage_covers] = false
    end

    opts.on('--keep-toggles-closed', 'トグルリストを自動展開せず閉じたままにする') do
      options[:open_toggles] = false
    end

    opts.on('--chrome-path PATH', 'Google Chrome の実行ファイルパスを手動指定') do |v|
      options[:chrome_path] = v
    end

    opts.on('--open', 'PDF生成後にプレビュー（Preview.app）で開く') do
      options[:auto_open] = true
    end

    opts.on('-h', '--help', 'ヘルプメッセージを表示') do
      puts opts
      exit 0
    end
  end

  parser.parse!

  input_path = ARGV.shift
  if input_path.nil? || input_path.strip.empty?
    puts '=' * 60
    puts ' Notion to PDF Exporter '
    puts '=' * 60
    print 'NotionエクスポートのZIPファイルまたはフォルダをドラッグ＆ドロップしてください: '
    input_path = $stdin.gets&.strip

    if input_path && !input_path.empty?
      print 'ページの余白を設定しますか？ [1: 余白あり(標準) / 2: 余白なし(コンパクト)] (デフォルト: 1): '
      margin_choice = $stdin.gets&.strip
      if margin_choice == '2' || margin_choice&.downcase == 'no'
        options[:margin] = false
      end

      print 'サブページのヘッダ画像を表示しますか？ [1: 非表示(標準) / 2: 表示] (デフォルト: 1): '
      cover_choice = $stdin.gets&.strip
      if cover_choice == '2' || cover_choice&.downcase == 'yes'
        options[:show_subpage_covers] = true
      end
    end
  end

  if input_path.nil? || input_path.empty?
    warn '入力が指定されていません。終了します。'
    exit 1
  end

  begin
    NotionToPdf.convert(
      input_path,
      output_pdf: options[:output_pdf],
      include_toc: options[:include_toc],
      margin: options[:margin],
      open_toggles: options[:open_toggles],
      show_subpage_covers: options[:show_subpage_covers],
      chrome_path: options[:chrome_path],
      auto_open: options[:auto_open]
    )
  rescue StandardError => e
    warn "\n❌ エラーが発生しました: #{e.message}"
    exit 1
  end
end
