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
  # saves requests.
  BUILTINS = %w[
    js json time math base64 base16 yaml jwt machine sandbox picorubyvm
    funicular markdown drb sqlite3 indexeddb midibase task
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

  # `mirrors` are the same file on the other CDNs, tried in order when `url`
  # cannot be fetched.
  class Library
    attr_reader :id, :url, :mirrors

    def initialize(id, url, mirrors = [])
      @id = id
      @url = url
      @mirrors = mirrors
    end

    def ==(other)
      other.is_a?(Library) && id == other.id && url == other.url
    end
  end

  class Error < StandardError; end

  # ------------------------------------------------------------------ parsing

  # Returns a Require for each require line in `code`.
  def self.find_requires(code)
    found = []
    in_comment = false
    code.split("\n").each_with_index do |line, i|
      if in_comment
        in_comment = false if line.start_with?('=end')
        next
      end
      if line.start_with?('=begin')
        in_comment = true
        next
      end
      break if line.strip == '__END__' && line.start_with?('__END__')
      m = line.match(REQUIRE_LINE)
      found << Require.new(i, m[1], m[3], m[2] == '_relative') if m
    end
    found
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
  #   io.fetch_text(url, integrity = nil)
  #                         -> String, or nil when not found, unreachable or
  #                            not matching `integrity` (an SRI hash)
  #   io.fetch_json(url)    -> Hash, or nil when not found or unreachable
  #   io.absolute_url(path, base = nil)
  #                         -> URL of `path` relative to `base`, or to the
  #                            page when `base` is nil
  class Resolver
    attr_reader :io

    def initialize(io, imports: {}, cdn: nil, builtins: BUILTINS, integrity: {})
      @io = io
      @imports = imports
      @integrity = integrity || {}
      # `cdn` is one CDN or a list of them, tried in order.
      @cdns = (cdn.is_a?(Array) ? cdn : [cdn || DEFAULT_CDN]).map { |c| c.end_with?('/') ? c : c + '/' }
      @cdns = [DEFAULT_CDN] if @cdns.empty?
      @builtins = builtins
      @cache = {}
      @packages = {}
      @package_cdn = {}
      @pinned = {}
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
      library(url, url)
    end

    # The SRI hash the import map gives one of `urls`, or nil.
    def integrity(urls)
      url = urls.find { |u| @integrity.key?(u) }
      url ? @integrity[url] : nil
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
    #
    # Every file is fetched from the exact version package.json reports, so
    # "latest" resolves once and every file of a package comes from the same
    # release. A file inside a package ("pkg/lib/x.rb") is pinned the same
    # way.
    def resolve_npm(spec, require_name, strict)
      pkg_spec, path = PicoRubyLibs.split_npm_path(spec)
      name, version = PicoRubyLibs.parse_spec(pkg_spec)
      # Without a version, a path takes the version the import map gives the
      # package, so it matches the entry that mapping loads. Otherwise reuse
      # the release already pinned for the package, by its entry or by a
      # path, so require order cannot mix releases.
      version ||= mapped_version(name) unless path.empty?
      version ||= @pinned[name]
      pkg = package_json(name, version)
      if pkg.nil?
        raise Error, "npm package not found: #{spec} (for require '#{require_name}')" if strict
        return nil
      end
      entry = PicoRubyLibs.ruby_entry(pkg)
      # A file inside a package named in the import map is taken as it is; a
      # plain require of one must still be a PicoRuby library.
      if entry.nil? && (path.empty? || !strict)
        raise Error, "#{spec} is not a PicoRuby library (no \"picoruby\" field in package.json)" if strict
        return nil
      end
      @pinned[name] ||= pkg['version']
      # Resolved like a URL, so dot segments ("lib/./x.rb") cannot make one
      # file look like two.
      base = "#{@package_cdn["#{name}@#{pkg['version']}"]}#{pkg['name']}@#{pkg['version']}/"
      return library(pkg['name'], @io.absolute_url(entry.sub(/^\.?\//, ''), base)) if path.empty?
      url = @io.absolute_url(path, base)
      library(url, url)
    end

    # A Library whose mirrors are `url` on the other CDNs, when it is on one.
    def library(id, url)
      cdn = @cdns.find { |c| url.start_with?(c) }
      return Library.new(id, url) if cdn.nil?
      path = url[cdn.length..-1]
      Library.new(id, url, (@cdns - [cdn]).map { |c| c + path })
    end

    # package.json of `name` at `version` (nil: the latest), fetched once.
    # It is also kept under the exact version it reports, so a file pinned to
    # that version later needs no second request.
    def package_json(name, version)
      key = name + (version ? "@#{version}" : '')
      return @packages[key] if @packages.key?(key)
      pkg = nil
      @cdns.each do |cdn|
        pkg = @io.fetch_json("#{cdn}#{key}/package.json")
        next if pkg.nil?
        @package_cdn["#{name}@#{pkg['version']}"] = cdn
        break
      end
      @packages[key] = pkg
      @packages["#{name}@#{pkg['version']}"] ||= pkg if pkg
      pkg
    end

    # The version an import map entry "name": "npm:name@ver" gives `name`.
    def mapped_version(name)
      mapped = @imports[name]
      return nil unless mapped.is_a?(String) && mapped.start_with?('npm:')
      mapped_name, version = PicoRubyLibs.parse_spec(PicoRubyLibs.split_npm_path(mapped[4..-1])[0])
      mapped_name == name ? version : nil
    end
  end

  # ---------------------------------------------------------------- expanding

  # Rewrites the scripts in order. Each library is inlined once, at its first
  # require in document order; later requires of it are dropped. Requires
  # inside a library are expanded the same way, so a library can depend on
  # another one by requiring it.
  class Expander
    def initialize(resolver)
      @resolver = resolver
      @loaded = {}
      @sources = {}
    end

    # `bases` are the URLs `require_relative` resolves against, one per code
    # (nil for a script written in the page).
    def expand_all(codes, bases = [])
      out = []
      codes.each_with_index { |code, i| out << expand(code, bases[i]) }
      out
    end

    def expand(code, base = nil)
      # The file being expanded counts as loaded, so a circular
      # require_relative back to it (e.g. from a script's own src) is dropped.
      @loaded[base] = true if base
      requires = PicoRubyLibs.find_requires(code)
      return code if requires.empty?

      lines = code.split("\n")
      out = []
      nxt = 0
      requires.each do |req|
        out.concat(lines[nxt...req.index])
        nxt = req.index + 1
        line = lines[req.index]
        lib = req.relative? ? @resolver.resolve_relative(req.name, base) : @resolver.resolve(req.name)
        if lib.nil?
          out << line
        elsif @loaded[lib.id] || @loaded[lib.url]
          out << "#{req.indent}# #{line.strip}  # already loaded by picoruby-libs"
        else
          # Marked before expanding its body, so a circular require is
          # dropped like Ruby's require does for a file that is loading.
          # A file is marked by its URL too, so an npm entry file reached
          # again through require_relative or a path is not inlined twice.
          @loaded[lib.id] = true
          @loaded[lib.url] = true
          body = expand(source(lib), lib.url)
          out << "# --- picoruby-libs: #{req.name} (#{lib.url}) ---"
          out << body.sub(/\n+$/, '')
          out << "# --- end #{req.name} ---"
        end
      end
      out.concat(lines[nxt..-1] || [])
      out.join("\n")
    end

    private

    # The text of `lib`, from its URL or else from the first mirror that has
    # it.
    #
    # When the import map gives the file an integrity hash, the browser checks
    # the fetched file against it, and a file that does not match counts as
    # not fetched.
    def source(lib)
      @sources[lib.url] ||= begin
        urls = [lib.url] + lib.mirrors
        sri = @resolver.integrity(urls)
        text = nil
        urls.each do |url|
          text = sri ? @resolver.io.fetch_text(url, sri) : @resolver.io.fetch_text(url)
          break unless text.nil?
        end
        if text.nil?
          raise Error, "failed to load #{lib.url}" + (sri ? " (or it does not match its integrity #{sri})" : '')
        end
        text
      end
    end
  end

  # ------------------------------------------------------------------ browser

  APP_SCRIPT = 'script[type="text/ruby-app"]'
  IMPORT_MAP = 'script[type="text/ruby-importmap"]'

  # The message for the `index`th (1-based, Integer or String) text/ruby-importmap script that
  # failed to parse. `id` is the script's id attribute ('' when it has none).
  def self.import_map_error(index, id, message)
    where = "text/ruby-importmap ##{index}"
    where += " (id=\"#{id}\")" unless id.empty?
    "#{where}: invalid JSON: #{message}"
  end

  # Network and DOM access through PicoRuby.wasm's JS bridge.
  class BrowserIO
    # A fetch with `integrity` fails (nil) when the file does not match it.
    def fetch_text(url, integrity = nil)
      JS.global[:__picoruby_libs_arg] = url
      JS.global[:__picoruby_libs_integrity] = integrity
      JS.eval(<<~JS).await
        fetch(window.__picoruby_libs_arg,
              window.__picoruby_libs_integrity ? { integrity: window.__picoruby_libs_integrity } : {})
          .then(r => r.ok ? r.text() : null)
          .catch(() => null)
      JS
    end

    # Only the package.json fields the resolver reads, as a Hash.
    def fetch_json(url)
      JS.global[:__picoruby_libs_arg] = url
      pkg = JS.eval(<<~JS).await
        fetch(window.__picoruby_libs_arg)
          .then(r => r.ok ? r.json() : null)
          .then(p => p && {
            name: p.name, version: p.version, main: p.main,
            picoruby: (p.picoruby && typeof p.picoruby === 'object') ? p.picoruby.main : p.picoruby
          })
          .catch(() => null)
      JS
      return nil if pkg.nil?
      { 'name' => pkg[:name], 'version' => pkg[:version], 'main' => pkg[:main], 'picoruby' => pkg[:picoruby] }
    end

    def absolute_url(path, base = nil)
      JS.global[:__picoruby_libs_arg] = path
      JS.global[:__picoruby_libs_base] = base
      JS.eval('new URL(window.__picoruby_libs_arg, window.__picoruby_libs_base || document.baseURI).href')
    end

    # [imports Hash, CDN list or nil, integrity Hash] from every
    # text/ruby-importmap script. "cdn" is a URL or a list of them.
    # "integrity" maps file URLs to SRI hashes.
    # Raises Error naming the script when one is not a JSON object.
    def import_map
      map = JS.eval(<<~JS)
        (() => {
          const map = { imports: {}, cdns: [], integrity: {}, error: null };
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
            Object.assign(map.integrity, json.integrity || {});
            if (json.cdn) map.cdns = [].concat(json.cdn).map(String);
          }
          map.entries = Object.entries(map.imports);
          map.hashes = Object.entries(map.integrity);
          return map;
        })()
      JS
      error = map[:error]
      unless error.nil?
        raise Error, PicoRubyLibs.import_map_error(error[:index].to_s, error[:id].to_s, error[:message].to_s)
      end
      imports = {}
      map[:entries].to_a.each { |pair| imports[pair[0]] = pair[1] }
      cdns = map[:cdns].to_a.map { |c| c.to_s }
      integrity = {}
      map[:hashes].to_a.each { |pair| integrity[pair[0].to_s] = pair[1].to_s }
      [imports, cdns.empty? ? nil : cdns, integrity]
    end

    # [[code, filename or nil, URL or nil]] for each text/ruby-app script, in
    # order. The URL (the `src`, made absolute by the DOM) is the base of the
    # script's require_relative.
    def app_scripts
      JS.document.querySelectorAll(APP_SCRIPT).to_a.map do |el|
        src = el[:src].to_s
        if src.empty?
          [el[:textContent].to_s, nil, nil]
        else
          code = fetch_text(src)
          raise Error, "failed to load #{src}" if code.nil?
          [code, src.split('/').last, src]
        end
      end
    end

    # Starts `code` as a new PicoRuby task, as init.iife.js does for a
    # text/ruby script.
    def create_task(code, filename)
      JS.global[:__picoruby_libs_arg] = code
      JS.global[:__picoruby_libs_file] = filename
      JS.eval(<<~JS)
        window.__picoruby_libs_file
          ? picorubyModule.ccall('picorb_create_task_with_filename', 'number', ['string', 'string'],
                                 [window.__picoruby_libs_arg, window.__picoruby_libs_file])
          : picorubyModule.ccall('picorb_create_task', 'number', ['string'], [window.__picoruby_libs_arg])
      JS
    end
  end

  def self.boot(io = BrowserIO.new)
    imports, cdn, integrity = io.import_map
    scripts = io.app_scripts
    expanded = Expander.new(Resolver.new(io, imports: imports, cdn: cdn, integrity: integrity))
                       .expand_all(scripts.map { |s| s[0] }, scripts.map { |s| s[2] })
    expanded.each_with_index { |code, i| io.create_task(code, scripts[i][1]) }
  end
end

# The tests define PICORUBY_LIBS_NO_BOOT to load the code without booting.
unless defined?(PICORUBY_LIBS_NO_BOOT)
  require 'js'
  PicoRubyLibs.boot
end
