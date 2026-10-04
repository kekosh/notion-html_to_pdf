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
      base_css = ''
      ordered_pages.each do |p|
        if p[:styles] && !p[:styles].empty?
          base_css = p[:styles].join("\n")
          break
        end
      end
      # Notion標準CSSに含まれる @page { margin: 1in; } を除去してカスタム余白設定と衝突しないようにする
      clean_base_css = base_css.gsub(/@page\s*\{[^}]*\}/mi, '')

      # 余白設定の判定
      margin_css = case margin
                   when false, nil, 'none', '0', 'no', '0mm'
                     '0'
                   when true, 'normal', 'default', 'yes'
                     '18mm 16mm 18mm 16mm'
                   else
                     margin.to_s
                   end

      margin_desc = (margin_css == '0') ? 'なし (0mm)' : margin_css
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

          /* 1. 見出しの泣き別れ防止 */
          h1, h2, h3, h4, summary, .chapter-header {
            break-after: avoid !important;
            page-break-after: avoid !important;
          }

          /* 2. コンテンツブロックの分断防止 */
          .callout,
          aside,
          figure.image,
          tr,
          pre, code, blockquote, figure, .collection-content, .board-card {
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

          /* 3. 画像の最大高さ制限による押し出し防止 */
          img {
            max-width: 100% !important;
            max-height: 42vh !important;
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
          .page-header-icon img, img.icon {
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

    opts.on('--no-margin', 'ページの余白なし（0mm）で作成する') do
      options[:margin] = false
    end

    opts.on('--margin [SIZE]', 'ページの余白の有無またはサイズを指定 (例: none, 0, normal, 10mm 等 / デフォルト: normal)') do |v|
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
      print 'ページの余白を設定しますか？ [1: 余白あり(標準) / 2: 余白なし] (デフォルト: 1): '
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
