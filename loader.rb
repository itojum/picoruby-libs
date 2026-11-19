# picoruby-libs loader
#
# Lets Ruby scripts on a page `require` PicoRuby libraries published on npm.
#
#   <script type="text/ruby" src="https://cdn.jsdelivr.net/npm/picoruby-libs/loader.rb"></script>
#   <script type="text/ruby-app">
#     require 'mylib'
#     MyLib.hello
#   </script>
#   <script src="https://cdn.jsdelivr.net/npm/@picoruby/wasm-wasi@latest/dist/init.iife.js"></script>
#
# PicoRuby.wasm starts with an empty virtual file system, and a file run with
# `load` stops silently at its first `await`. So the loader does not load
# libraries at runtime: it reads each `text/ruby-app` script, replaces every
# `require 'name'` line of a library with the library's code, and starts the
# result as one PicoRuby task, where `await` works. `require_relative 'x'` is
# expanded the same way, with x.rb fetched relative to the requiring file.
#
# A library is an npm package whose package.json names its Ruby entry file in
# a "picoruby" field (or a "main" ending in .rb).
#
# The code below runs on PicoRuby.wasm and on CRuby (for the tests), so it
# keeps to what both support. PicoRuby.wasm's Regexp is JavaScript's RegExp:
# no \A / \z, and no $1 (use the MatchData).

module PicoRubyLibs
  DEFAULT_CDN = 'https://cdn.jsdelivr.net/npm/'

  # Libraries compiled into PicoRuby.wasm. Their require is left for PicoRuby
  # without asking npm. Anything else is looked up on npm and left as it is
  # when no package declares itself a PicoRuby library, so this list only
  # saves requests. scripts/check-builtins.mjs compares it with the latest
  # @picoruby/wasm-wasi (the "Builtins" workflow runs it weekly).
  BUILTINS = %w[
    js json time math base64 base16 yaml jwt machine sandbox picorubyvm
    funicular markdown drb sqlite3 indexeddb midibase task
    uri env rng crc pack marshal mbedtls io io/console dir data eval
    metaprog method objectspace binding sprintf compiler require mruby
    error dfu array-ext hash-ext kernel-ext numeric-ext object-ext
    proc-ext string-ext toplevel-ext
  ]

  # `require 'x'` / `require('x')` / `require "x"` (or `require_relative`) as
  # a whole statement on one line, with an optional trailing comment.
  REQUIRE_LINE = /^([ \t]*)require(_relative)?[ \t]*\(?[ \t]*['"]([^'"]+)['"][ \t]*\)?[ \t]*(#.*)?$/

  class Require
    attr_reader :index, :indent, :name

    def initialize(index, indent, name, relative = false)
      @index = index
      @indent = indent
      @name = name
      @relative = relative
    end

    def relative?
      @relative
    end
  end

  class Library
    attr_reader :id, :url

    def initialize(id, url)
      @id = id
      @url = url
    end

    def ==(other)
      other.is_a?(Library) && id == other.id && url == other.url
    end
  end

  class Error < StandardError; end

  # ------------------------------------------------------------------ parsing

  # A call of require / require_relative with a string literal anywhere in a
  # line, for finding the ones REQUIRE_LINE does not take (`require 'a' if x`,
  # `require 'a'; require 'b'`).
  REQUIRE_CALL = /(^|[^A-Za-z0-9_.:@$])require(_relative)?[ \t]*\(?[ \t]*['"]([^'"]+)['"]/

  # The start of a heredoc at the beginning of a string: `<<~ID`, `<<-ID`, or
  # `<<ID`, with the identifier optionally quoted.
  # A quoted identifier may hold any character but its quote.
  HEREDOC_START = /^<<([~-]?)(?:(["'`])(.*?)\2|([A-Za-z_][A-Za-z0-9_]*))/

  # Returns a Require for each require line in `code`.
  def self.find_requires(code)
    found = []
    each_code_line(code) do |line, i|
      m = line.match(REQUIRE_LINE)
      found << Require.new(i, m[1], m[3], m[2] == '_relative') if m
    end
    found
  end

  # [[index, name, relative], ...] for the require calls in `code` that are
  # not a whole require line, so are left for PicoRuby. Calls after a `#`
  # that starts a comment are skipped.
  def self.find_other_requires(code)
    found = []
    each_code_line(code) do |line, i|
      next if line.match(REQUIRE_LINE)
      hash = comment_start(line)
      rest = line
      offset = 0
      while (m = rest.match(REQUIRE_CALL))
        at = offset + rest.index(m[0])
        break if hash && hash < at
        found << [i, m[3], m[2] == '_relative']
        offset = at + m[0].length
        rest = line[offset..-1]
      end
    end
    found
  end

  # The index of the `#` that starts a comment in `line` (not `#{`), or nil.
  # A `#` inside a string is taken for a comment too.
  def self.comment_start(line)
    pos = 0
    while (h = line.index('#', pos))
      return h unless line[h + 1] == '{'
      pos = h + 1
    end
    nil
  end

  # The indentation of the least indented code line (not blank, not a
  # comment). A script written in the page is often indented as a whole;
  # its top level is at this indentation.
  def self.top_indent(code)
    top = nil
    each_code_line(code) do |line, _i|
      next if line.strip.empty? || line.strip.start_with?('#')
      indent = line.match(/^[ \t]*/)[0]
      top = indent if top.nil? || indent.length < top.length
    end
    top || ''
  end

  # Yields each line of `code` that is Ruby code, with its index: skips
  # =begin/=end comments and the bodies of heredocs, and stops at __END__.
  # Other multi-line strings (%q{...}, '...') are not tracked.
  def self.each_code_line(code)
    in_comment = false
    heredocs = [] # [[identifier, indentable], ...] still to be closed
    code.split("\n").each_with_index do |line, i|
      line = line[0..-2] if line.end_with?("\r") # CRLF source
      unless heredocs.empty?
        id, indentable = heredocs[0]
        # Only leading blanks may precede the terminator of <<~ / <<-.
        heredocs.shift if (indentable ? line.sub(/^[ \t]+/, '') : line) == id
        next
      end
      if in_comment
        in_comment = false if line.start_with?('=end')
        next
      end
      if line.start_with?('=begin')
        in_comment = true
        next
      end
      break if line.strip == '__END__' && line.start_with?('__END__')
      yield line, i
      heredocs.concat(heredoc_starts(line))
    end
  end

  # [[identifier, indentable], ...] for the heredocs `line` opens, in order.
  # This is a heuristic lexer, not a Ruby parser: it steps over strings,
  # regexps and percent literals that close on the line (looking into their
  # #{...}), stops at a comment or at a literal that does not close, and
  # takes `<<` for a shift where a value precedes it (`n <<X` after a
  # number, a closing bracket, or an identifier with no blank before `<<`).
  # A bare `<<ID` also needs an upper-case identifier (`list << item`).
  def self.heredoc_starts(line)
    starts = []
    scan_code(line, 0, starts, false)
    starts
  end

  # Keywords after which an expression starts, so `return<<~EOS` and
  # `when /x/` read as literals.
  EXPRESSION_KEYWORDS = %w[
    return when if unless elsif while until and or not then do else in yield
    case puts print p raise
  ]

  # Scans code in `line` from `pos`, adding the heredocs it opens to
  # `starts`. In an interpolation (`interp`), returns the index after the
  # `}` that closes it; otherwise, or when the line ends first, nil.
  def self.scan_code(line, pos, starts, interp)
    kind = :op    # what precedes: :op (start, operator), :ident or :value
    spaced = true # whether a blank follows it
    braces = 0
    while pos < line.length
      c = line[pos]
      if c == ' ' || c == "\t"
        spaced = true
        pos += 1
        next
      end
      after = nil # the index after a literal that closes on this line
      if c == '#'
        return nil
      elsif c == '"' || c == '`'
        after = literal_end(line, pos + 1, c, nil, starts, true)
      elsif c == "'"
        after = literal_end(line, pos + 1, c, nil, starts, false)
      elsif c == '?' && expression_start?(kind, spaced, line[pos + 1]) && char_literal_end(line, pos)
        after = char_literal_end(line, pos) # ?# / ?" / ?\n
      elsif c == '/' && expression_start?(kind, spaced, line[pos + 1])
        after = literal_end(line, pos + 1, '/', nil, starts, true)
      elsif c == '%' && (m = line[pos..-1].match(PERCENT_START)) && expression_start?(kind, spaced, line[pos + 1])
        open = m[0][-1]
        close = PAIRS[open]
        after = literal_end(line, pos + m[0].length, close || open, close ? open : nil,
                            starts, !%w[q w i s].include?(m[1]))
      elsif c == '<' && line[pos + 1] == '<'
        m = line[pos..-1].match(HEREDOC_START)
        quoted = !m.nil? && !m[2].to_s.empty?
        id = m && (quoted ? m[3].to_s : m[4])
        if m && expression_start?(kind, spaced, line[pos + 2]) &&
           (!m[1].empty? || quoted || id == id.upcase)
          starts << [id, !m[1].empty?]
          after = pos + m[0].length
        else
          pos += 2
          kind = :op
          spaced = false
          next
        end
      elsif c.match(/^[A-Za-z0-9_]$/)
        word_end = pos
        word_end += 1 while word_end < line.length && line[word_end].match(/^[A-Za-z0-9_]$/)
        word_end += 1 if word_end < line.length && '?!'.include?(line[word_end])
        word = line[pos...word_end]
        kind = if '0123456789'.include?(c) || word == 'class' # `class <<ENV`
                 :value
               elsif EXPRESSION_KEYWORDS.include?(word)
                 :op
               else
                 :ident
               end
        spaced = false
        pos = word_end
        next
      elsif c == '{'
        braces += 1
        kind = :op
        spaced = false
        pos += 1
        next
      elsif c == '}'
        return pos + 1 if interp && braces == 0
        braces -= 1
        after = pos + 1
      elsif ')]'.include?(c)
        after = pos + 1
      else
        kind = :op
        spaced = false
        pos += 1
        next
      end
      return nil if after.nil?
      kind = :value
      spaced = false
      pos = after
    end
    nil
  end

  # The index after a character literal (`?a`, `?\\n`) at `pos`, or nil when
  # the `?` is not one (a ternary's `?`, or `?ab`).
  def self.char_literal_end(line, pos)
    c = line[pos + 1]
    return nil if c.nil? || c == ' ' || c == "\t"
    after = c == '\\' ? pos + 3 : pos + 2
    return nil if after > line.length
    nxt = line[after]
    return nil if !nxt.nil? && nxt.match(/^[A-Za-z0-9_]$/) && c.match(/^[A-Za-z0-9_]$/)
    after
  end

  # A percent literal's opening: `%q(`, `%w[`, `%r{`, ... or a bare `%`
  # with any delimiter but `=` (`x %= 2`).
  PERCENT_START = /^%([qQwWiIrsx]?)[^A-Za-z0-9 \t=]/
  PAIRS = { '(' => ')', '[' => ']', '{' => '}', '<' => '>' }

  # Whether a literal (or a heredoc) can start at a token whose next
  # character is `nxt`, after a token of `kind`. After an identifier it is
  # an argument only with a blank before it and none after (`puts <<~X`,
  # `foo /x/`); otherwise it is an operator (`a / b`, `n<<X`, `x % 2`).
  def self.expression_start?(kind, spaced, nxt)
    return true if kind == :op
    return false if kind == :value
    spaced && !nxt.nil? && nxt != ' ' && nxt != "\t" && nxt != '='
  end

  # The index after the `close` that ends a literal whose body starts at
  # `from`, or nil when it does not end on this line. `open` (for bracket
  # delimiters) nests. With `interp`, the code in #{...} is scanned for
  # heredocs, so quotes inside it do not end the literal.
  def self.literal_end(line, from, close, open, starts, interp)
    depth = 0
    i = from
    while i < line.length
      c = line[i]
      if c == '\\'
        i += 2
        next
      end
      if interp && c == '#' && line[i + 1] == '{'
        i = scan_code(line, i + 2, starts, true)
        return nil if i.nil?
        next
      end
      if c == close
        return i + 1 if depth == 0
        depth -= 1
      elsif open && c == open
        depth += 1
      end
      i += 1
    end
    nil
  end

  # "mylib" / "mylib@1.2.3" / "@scope/pkg@1" -> [name, version or nil]
  def self.parse_spec(spec)
    at = spec.rindex('@')
    return [spec, nil] if at.nil? || at == 0
    [spec[0, at], spec[(at + 1)..-1]]
  end

  # "@scope/pkg@1/lib/x.rb" -> ["@scope/pkg@1", "lib/x.rb"]
  def self.split_npm_path(spec)
    segments = spec.split('/')
    n = spec.start_with?('@') ? 2 : 1
    [segments[0, n].join('/'), (segments[n..-1] || []).join('/')]
  end

  # The Ruby entry file named by a package.json (a Hash).
  def self.ruby_entry(pkg)
    entry = pkg['picoruby']
    entry = entry['main'] if entry.is_a?(Hash)
    return entry if entry.is_a?(String) && !entry.empty?
    main = pkg['main']
    return main if main.is_a?(String) && main.end_with?('.rb')
    nil
  end

  # ---------------------------------------------------------------- resolving

  # Turns require names into Libraries. `io` does the network work:
  #   io.fetch_text(url)    -> String, or nil when not found
  #   io.fetch_json(url)    -> Hash, or nil when not found
  #   io.absolute_url(path, base = nil)
  #                         -> URL of `path` relative to `base`, or to the
  #                            page when `base` is nil
  class Resolver
    attr_reader :io

    def initialize(io, imports: {}, cdn: nil, builtins: BUILTINS)
      @io = io
      @imports = imports
      @cdn = cdn || DEFAULT_CDN
      @builtins = builtins
      @cache = {}
    end

    # A Library, or nil when `name` is left to PicoRuby: a built-in, a
    # relative path, or an npm package that is not a PicoRuby library.
    def resolve(name)
      @cache[name] = resolve_uncached(name) unless @cache.key?(name)
      @cache[name]
    end

    # The Library of `require_relative name` in the file at `base` (a URL, or
    # nil for a script written in the page). ".rb" is added when the last
    # path component has no extension.
    def resolve_relative(name, base)
      last = name.split('/').last || ''
      dot = last.rindex('.')
      path = dot && dot > 0 ? name : name + '.rb'
      url = @io.absolute_url(path, base)
      Library.new(url, url)
    end

    private

    def resolve_uncached(name)
      if @imports.key?(name)
        mapped = @imports[name]
        return nil if mapped.nil? || mapped == false
        return resolve_npm(mapped[4..-1], name, true) if mapped.start_with?('npm:')
        url = @io.absolute_url(mapped)
        return Library.new(url, url)
      end
      return nil if name.start_with?('.') || name.start_with?('/')
      return nil if @builtins.include?(name)
      resolve_npm(name, name, false)
    end

    # strict: raise instead of returning nil when it is not a library.
    def resolve_npm(spec, require_name, strict)
      pkg_spec, path = PicoRubyLibs.split_npm_path(spec)
      name, version = PicoRubyLibs.parse_spec(pkg_spec)
      base = @cdn + name + (version ? "@#{version}" : '') + '/'
      unless path.empty?
        url = base + path
        return Library.new(url, url)
      end

      pkg = @io.fetch_json(base + 'package.json')
      if pkg.nil?
        raise Error, "npm package not found: #{spec} (for require '#{require_name}')" if strict
        return nil
      end
      entry = PicoRubyLibs.ruby_entry(pkg)
      if entry.nil?
        raise Error, "#{spec} is not a PicoRuby library (no \"picoruby\" field in package.json)" if strict
        return nil
      end
      # Pin to the version package.json reports, so "latest" resolves once and
      # every file of the library comes from the same release.
      entry = entry.sub(/^\.?\//, '')
      Library.new(pkg['name'], "#{@cdn}#{pkg['name']}@#{pkg['version']}/#{entry}")
    end
  end

  # ---------------------------------------------------------------- expanding

  # Rewrites the scripts. Each script gets its own copy of every library it
  # requires, inlined at its first require in that script; later requires of
  # it in the same script are dropped. Scripts run as separate tasks that can
  # interleave at an `await`, so a library inlined only into an earlier script
  # might not be defined yet when a later one uses it. Requires inside a
  # library are expanded the same way, so a library can depend on another one
  # by requiring it. Fetched files are cached, so each is fetched once.
  class Expander
    # Messages about requires left for PicoRuby that likely name a library,
    # e.g. `require 'mylib' if x`. Each starts with "file:line: ".
    attr_reader :warnings

    def initialize(resolver)
      @resolver = resolver
      @loaded = {}
      @sources = {}
      @warnings = []
    end

    # `bases` are the URLs `require_relative` resolves against, one per code
    # (nil for a script written in the page).
    def expand_all(codes, bases = [])
      out = []
      codes.each_with_index do |code, i|
        out << expand_script(code, bases[i], bases[i] || "script ##{i + 1}")
      end
      out
    end

    # Expands one text/ruby-app script, inlining every library it requires
    # whether or not an earlier script has it too, and yields the result (to
    # start it). `where` names the script in error messages.
    def expand_script(code, base = nil, where = nil)
      @loaded = {}
      out = expand(code, base, where)
      yield out if block_given?
      out
    end

    # A failed require raises an Error whose message ends with a
    # "from require 'name' at file:line" line for each require that led to it.
    def expand(code, base = nil, where = nil)
      where ||= base || 'script'
      # The file being expanded counts as loaded, so a circular
      # require_relative back to it (e.g. from a script's own src) is dropped.
      @loaded[base] = true if base
      warn_other_requires(code, base, where)
      requires = PicoRubyLibs.find_requires(code)
      return code if requires.empty?
      top = PicoRubyLibs.top_indent(code).length

      lines = code.split("\n")
      out = []
      nxt = 0
      requires.each do |req|
        out.concat(lines[nxt...req.index])
        nxt = req.index + 1
        line = lines[req.index]
        indented = false
        begin
          lib = req.relative? ? @resolver.resolve_relative(req.name, base) : @resolver.resolve(req.name)
          if lib.nil?
            out << line
          elsif req.indent.length > top
            indented = true
          elsif @loaded[lib.id]
            out << "#{req.indent}# #{line.strip}  # already loaded by picoruby-libs"
          else
            # Marked before expanding its body, so a circular require is
            # dropped like Ruby's require does for a file that is loading.
            @loaded[lib.id] = true
            body = expand(source(lib.url), lib.url)
            out << "# --- picoruby-libs: #{req.name} (#{lib.url}) ---"
            out << body.sub(/\n+$/, '')
            out << "# --- end #{req.name} ---"
          end
        rescue => e
          kind = req.relative? ? 'require_relative' : 'require'
          raise Error, "#{e.message}\n  from #{kind} '#{req.name}' at #{where}:#{req.index + 1}"
        end
        # An indented require is likely inside a def or class, where the
        # inlined code would break (def) or land in another namespace
        # (class). Refused even when the library is already loaded, so the
        # outcome does not depend on the order of the requires.
        if indented
          raise Error, "#{where}:#{req.index + 1}: #{line.strip} is indented. " +
                       'picoruby-libs inlines a library where its require is written, ' +
                       'so move the require to the top level'
        end
      end
      out.concat(lines[nxt..-1] || [])
      out.join("\n")
    end

    private

    # A require_relative always names a file to inline; a require is checked
    # with the resolver, so built-ins and non-library packages pass quietly.
    def warn_other_requires(code, base, where)
      PicoRubyLibs.find_other_requires(code).each do |found|
        index, name, relative = found
        next unless relative || @resolver.resolve(name)
        call = relative ? "require_relative '#{name}'" : "require '#{name}'"
        @warnings << "#{where}:#{index + 1}: #{call} was not expanded, so PicoRuby " +
                     'will raise LoadError. picoruby-libs only expands a require ' +
                     'that is a whole statement on its own line'
      end
    end

    def source(url)
      @sources[url] ||= begin
        text = @resolver.io.fetch_text(url)
        raise Error, "failed to load #{url}" if text.nil?
        text
      end
    end
  end

  # ------------------------------------------------------------------ browser

  APP_SCRIPT = 'script[type="text/ruby-app"]'
  IMPORT_MAP = 'script[type="text/ruby-importmap"]'

  # JavaScript that reads `names` from window.__picoruby_libs_<name> into
  # local constants, deletes those globals, and returns the value of `body`
  # (an expression that uses the constants).
  def self.js_with_args(names, body)
    reads = names.map { |n| "#{n} = window.__picoruby_libs_#{n}" }.join(', ')
    deletes = names.map { |n| "delete window.__picoruby_libs_#{n};" }.join(' ')
    "(() => { const #{reads}; #{deletes} return (#{body}); })()"
  end

  # The file name PicoRuby reports in errors for the `n`th (1-based)
  # text/ruby-app script on the page: the last segment of the `src` URL's
  # path, without query or fragment, or `inline-n.rb` for an inline script.
  def self.script_filename(src, n)
    path = src.split('#').first.to_s.split('?').first.to_s
    name = path[-1] == '/' ? '' : path.split('/').last.to_s
    if name.empty?
      src.empty? ? "inline-#{n}.rb" : "script-#{n}.rb"
    else
      name
    end
  end

  # The message for the `index`th (1-based, Integer or String) text/ruby-importmap script that
  # failed to parse. `id` is the script's id attribute ('' when it has none).
  def self.import_map_error(index, id, message)
    where = "text/ruby-importmap ##{index}"
    where += " (id=\"#{id}\")" unless id.empty?
    "#{where}: invalid JSON: #{message}"
  end

  # Network and DOM access through PicoRuby.wasm's JS bridge.
  class BrowserIO
    def fetch_text(url)
      eval_with({ 'arg' => url }, 'fetch(arg).then(r => r.ok ? r.text() : null)').await
    end

    # Only the package.json fields the resolver reads, as a Hash.
    def fetch_json(url)
      pkg = eval_with({ 'arg' => url }, <<~JS).await
        fetch(arg)
          .then(r => r.ok ? r.json() : null)
          .then(p => p && {
            name: p.name, version: p.version, main: p.main,
            picoruby: (p.picoruby && typeof p.picoruby === 'object') ? p.picoruby.main : p.picoruby
          })
      JS
      return nil if pkg.nil?
      { 'name' => pkg[:name], 'version' => pkg[:version], 'main' => pkg[:main], 'picoruby' => pkg[:picoruby] }
    end

    def absolute_url(path, base = nil)
      eval_with({ 'arg' => path, 'base' => base }, 'new URL(arg, base || document.baseURI).href')
    end

    # [imports Hash, cdn or nil] from every text/ruby-importmap script.
    # Raises Error naming the script when one is not a JSON object.
    def import_map
      map = JS.eval(<<~JS)
        (() => {
          const map = { imports: {}, cdn: null, error: null };
          const els = document.querySelectorAll('#{IMPORT_MAP}');
          for (let i = 0; i < els.length; i++) {
            const el = els[i];
            let json;
            try {
              json = JSON.parse(el.textContent || '{}');
            } catch (e) {
              return { error: { index: String(i + 1), id: el.id, message: String(e.message) } };
            }
            if (json === null || typeof json !== 'object' || Array.isArray(json)) {
              return { error: { index: String(i + 1), id: el.id, message: 'expected a JSON object' } };
            }
            Object.assign(map.imports, json.imports || {});
            if (json.cdn) map.cdn = json.cdn;
          }
          map.entries = Object.entries(map.imports);
          return map;
        })()
      JS
      error = map[:error]
      unless error.nil?
        raise Error, PicoRubyLibs.import_map_error(error[:index].to_s, error[:id].to_s, error[:message].to_s)
      end
      imports = {}
      map[:entries].to_a.each { |pair| imports[pair[0]] = pair[1] }
      [imports, map[:cdn]]
    end

    # [[code, filename, URL or nil]] for each text/ruby-app script, in
    # order. The URL (the `src`, made absolute by the DOM) is the base of the
    # script's require_relative. The code is nil when the src cannot be
    # fetched.
    def app_scripts
      n = 0
      JS.document.querySelectorAll(APP_SCRIPT).to_a.map do |el|
        n += 1
        src = el[:src].to_s
        name = PicoRubyLibs.script_filename(src, n)
        if src.empty?
          [el[:textContent].to_s, name, nil]
        else
          # A rejected fetch (network or CORS error) raises at the await.
          # Return nil so only this script is skipped.
          code = begin
            fetch_text(src)
          rescue => e
            nil
          end
          [code, name, src]
        end
      end
    end

    # Shows `message` as a warning in the browser console.
    def warn(message)
      eval_with({ 'arg' => "picoruby-libs: #{message}" }, 'console.warn(arg)')
    end

    # Starts `code` as a new PicoRuby task, as init.iife.js does for a
    # text/ruby script.
    def create_task(code, filename)
      eval_with({ 'arg' => code, 'file' => filename }, <<~JS)
        file
          ? picorubyModule.ccall('picorb_create_task_with_filename', 'number', ['string', 'string'], [arg, file])
          : picorubyModule.ccall('picorb_create_task', 'number', ['string'], [arg])
      JS
    end

    def report_error(message)
      eval_with({ 'arg' => message }, 'console.error(arg)')
    end

    private

    # Evaluates `body` with `args` ({ name => value }) passed through
    # window.__picoruby_libs_<name>, which are removed before `body` runs so
    # no value (such as a whole expanded script) stays on `window`.
    def eval_with(args, body)
      args.each { |name, value| JS.global[('__picoruby_libs_' + name).to_sym] = value }
      JS.eval(PicoRubyLibs.js_with_args(args.keys, body))
    end

    # Dispatches a CustomEvent named `type` on document, with `detail` (a
    # String or nil).
    def dispatch_event(type, detail = nil)
      JS.global[:__picoruby_libs_arg] = type
      JS.global[:__picoruby_libs_detail] = detail
      JS.eval(<<~JS)
        document.dispatchEvent(new CustomEvent(window.__picoruby_libs_arg,
                                               { detail: window.__picoruby_libs_detail }))
      JS
    end
  end

  READY_EVENT = 'picoruby-libs:ready'
  ERROR_EVENT = 'picoruby-libs:error'

  # Expands and starts each text/ruby-app script in document order. A script
  # that fails to expand is reported and skipped; the others still start.
  # Each failure is sent to console.error and dispatched on document as a
  # picoruby-libs:error event whose detail is the message. When every script
  # has been started or skipped, picoruby-libs:ready is dispatched, once.
  def self.boot(io = BrowserIO.new)
    start_scripts(io)
    io.dispatch_event(READY_EVENT)
  end

  def self.report(io, message)
    io.report_error(message)
    io.dispatch_event(ERROR_EVENT, message)
  end

  def self.start_scripts(io)
    begin
      imports, cdn = io.import_map
      scripts = io.app_scripts
    rescue => e
      report(io, "picoruby-libs: no script was started: #{e.message}")
      return
    end
    expander = Expander.new(Resolver.new(io, imports: imports, cdn: cdn))
    scripts.each_with_index do |script, i|
      code, filename, url = script
      label = "script ##{i + 1}" + (filename ? " (#{filename})" : '')
      begin
        raise Error, "failed to load #{url}" if code.nil?
        expander.expand_script(code, url, url || "script ##{i + 1}") { |expanded| io.create_task(expanded, filename) }
      rescue => e
        report(io, "picoruby-libs: #{label} was not started: #{e.message}")
      end
      expander.warnings.each { |w| io.warn(w) }
      expander.warnings.clear
    end
  end
end

# The tests define PICORUBY_LIBS_NO_BOOT to load the code without booting.
unless defined?(PICORUBY_LIBS_NO_BOOT)
  require 'js'
  PicoRubyLibs.boot
end
