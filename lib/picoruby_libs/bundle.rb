# picoruby-libs bundle: expands the requires of a script ahead of time.
#
#   picoruby-libs bundle app.rb -o app.bundle.rb
#
# The result needs neither the loader nor a CDN at run time: load it with
#   <script type="text/ruby" src="app.bundle.rb"></script>
#
# It runs the loader's own Resolver and Expander (loader.rb) on CRuby, with
# FileIO doing the network and file work. The packages it resolves and the
# integrity of every file it fetches are written to a lockfile, which later
# runs reuse and check.

require 'digest'
require 'json'
require 'net/http'
require 'openssl'
require 'optparse'
require 'uri'

PICORUBY_LIBS_NO_BOOT = true unless defined?(PICORUBY_LIBS_NO_BOOT)
require_relative '../../loader'

module PicoRubyLibs
  module Bundle
    LOCKFILE_VERSION = 1
    DEFAULT_LOCKFILE = 'picoruby-libs.lock.json'

    # The resolver's IO on CRuby: http(s) URLs through Net::HTTP, file URLs
    # from the disk. `page` is the URL relative import-map entries resolve
    # against (the import map file, or the current directory).
    class FileIO
      MAX_REDIRECTS = 5

      def initialize(page)
        @page = page
      end

      # nil when the file is not there or the server cannot serve it (an
      # error response, or a network failure), so the resolver tries the
      # next CDN. The reasons are kept in `failures`.
      def fetch_text(url)
        uri = URI(url)
        case uri.scheme
        when 'file'
          path = URI.decode_uri_component(uri.path)  # keeps a literal "+"
          File.file?(path) ? File.read(path, encoding: 'UTF-8') : nil
        when 'http', 'https'
          begin
            http_get(uri)
          rescue SystemCallError, IOError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError => e
            failures << "GET #{uri}: #{e.message}"
            nil
          end
        else
          raise Error, "cannot fetch #{url}"
        end
      end

      def failures
        @failures ||= []
      end

      # The package.json fields the resolver reads, like BrowserIO#fetch_json.
      def fetch_json(url)
        text = fetch_text(url)
        return nil if text.nil?
        pkg = JSON.parse(text)
        picoruby = pkg['picoruby'].is_a?(Hash) ? pkg['picoruby']['main'] : pkg['picoruby']
        { 'name' => pkg['name'], 'version' => pkg['version'], 'main' => pkg['main'], 'picoruby' => picoruby }
      rescue JSON::ParserError => e
        raise Error, "invalid package.json at #{url}: #{e.message}"
      end

      # Like `new URL(path, base)`: characters a URL cannot hold (spaces
      # and non-ASCII) are percent-encoded; "+", "%" and "#" are kept.
      def absolute_url(path, base = nil)
        URI.join(base || @page, URI::RFC2396_PARSER.escape(path, /[^\x21-\x7e]/)).to_s
      end

      private

      def http_get(uri, redirects = 0)
        res = Net::HTTP.get_response(uri)
        case res
        when Net::HTTPSuccess
          res.body.to_s.dup.force_encoding('UTF-8')
        when Net::HTTPRedirection
          raise Error, "too many redirects for #{uri}" if redirects >= MAX_REDIRECTS
          http_get(URI.join(uri.to_s, res['location']), redirects + 1)
        when Net::HTTPNotFound
          nil
        else
          failures << "GET #{uri}: #{res.code} #{res.message}"
          nil
        end
      end
    end

    def self.integrity(text)
      'sha384-' + [Digest::SHA384.digest(text)].pack('m0')
    end

    # The lockfile as a Hash:
    #   "requires":  { npm name => { "import" => import-map value or nil,
    #                            "id" => ..., "url" => ... } or
    #                          { "import" => ..., "library" => false } }
    #   "integrity": { url => "sha384-..." }
    class Lock
      attr_reader :requires, :integrity

      def self.read(path)
        return new unless path && File.exist?(path)
        data = JSON.parse(File.read(path))
        unless data['lockfileVersion'] == LOCKFILE_VERSION
          raise Error, "#{path}: unsupported lockfileVersion #{data['lockfileVersion'].inspect}"
        end
        new(data['requires'] || {}, data['integrity'] || {})
      rescue JSON::ParserError => e
        raise Error, "#{path}: invalid JSON: #{e.message}"
      end

      def initialize(requires = {}, integrity = {})
        @requires = requires
        @integrity = integrity
      end

      def to_h
        {
          'lockfileVersion' => LOCKFILE_VERSION,
          'requires' => @requires.sort.to_h,
          'integrity' => @integrity.sort.to_h,
        }
      end

      def to_json
        JSON.pretty_generate(to_h) + "\n"
      end

      def ==(other)
        other.is_a?(Lock) && to_h == other.to_h
      end
    end

    # Wraps the loader's Resolver: a name in the lock (with the same
    # import-map value) is taken from it without asking npm, and every
    # resolution and fetched library file is recorded in a new Lock.
    # Files under `local` (the app's directory) are the app's own and are not
    # locked.
    class LockingResolver
      attr_reader :lock

      def initialize(resolver, old_lock, imports:, local:, frozen: false)
        @resolver = resolver
        @old = old_lock
        @imports = imports
        @local = local
        @frozen = frozen
        @lock = Lock.new
        @io = IntegrityIO.new(resolver.io, self)
        # Locked libraries pin their packages, so a path into one of them
        # that is not locked yet resolves to the same release.
        @old.requires.each do |name, entry|
          next unless entry['url'] && entry['import'] == (@imports.key?(name) ? @imports[name] : nil)
          @resolver.pin_url(entry['url'])
        end
      end

      attr_reader :io

      def resolve(name)
        import = @imports.key?(name) ? @imports[name] : nil
        # Answered without npm: built-ins, names mapped to false, paths, and
        # names mapped to a URL (resolved against the import map where it is
        # now, so a moved checkout still works). Nothing to lock.
        return @resolver.resolve(name) unless @resolver.npm_name?(name)

        entry = @old.requires[name]
        if entry && entry['import'] == import
          @lock.requires[name] = entry
          # With the mirrors the current CDNs give it, so a reused entry can
          # still fall back.
          return entry['library'] == false ? nil : @resolver.library(entry['id'], entry['url'])
        end
        # Checked before resolving, so --frozen never asks npm.
        if @frozen
          why = entry ? 'its import-map value changed since the lockfile was written' : 'it is not in the lockfile'
          raise Error, "cannot resolve #{name} with --frozen: #{why} (run without --frozen to update it)"
        end

        lib = @resolver.resolve(name)
        @lock.requires[name] =
          if lib
            { 'import' => import, 'id' => lib.id, 'url' => lib.url }
          else
            { 'import' => import, 'library' => false }
          end
        lib
      end

      def resolve_relative(name, base)
        @resolver.resolve_relative(name, base)
      end

      def inlined(lib)
        @resolver.inlined(lib)
      end

      def new_script
        @resolver.new_script
      end

      # Called by IntegrityIO before fetching: with --frozen, a file outside
      # the app's directory must already be in the lockfile.
      def before_fetch(url)
        return if local?(url) || !@frozen || locked_integrity(url)
        raise Error, "cannot fetch #{url} with --frozen: it is not in the lockfile (run without --frozen to add it)"
      end

      # Called by IntegrityIO for every fetched file.
      def check(url, text)
        return if local?(url)
        actual = PicoRubyLibs::Bundle.integrity(text)
        expected = locked_integrity(url)
        if expected && expected != actual
          raise Error, "integrity mismatch for #{url}: the lockfile has #{expected}, the file is #{actual}"
        end
        @lock.integrity[url] = actual
      end

      private

      def local?(url)
        url.start_with?(@local)
      end

      # The locked hash of `url`, or of the same file on another CDN: a file
      # fetched from a mirror is locked under the mirror's URL.
      def locked_integrity(url)
        same = @resolver.same_files(url).find { |u| @old.integrity.key?(u) }
        same && @old.integrity[same]
      end
    end

    # Passes fetched text through LockingResolver#check.
    class IntegrityIO
      def initialize(io, checker)
        @io = io
        @checker = checker
      end

      def fetch_text(url)
        @checker.before_fetch(url)
        text = @io.fetch_text(url)
        @checker.check(url, text) unless text.nil?
        text
      end

      # Files are read one at a time here, so there is nothing to start early.
      def prefetch(_urls); end

      def fetch_json(url)
        @io.fetch_json(url)
      end

      def absolute_url(path, base = nil)
        @io.absolute_url(path, base)
      end
    end

    def self.file_url(path)
      'file://' + File.expand_path(path).split('/').map { |s| URI.encode_www_form_component(s).gsub('+', '%20') }.join('/')
    end

    # Expands `input` (a path) and returns [code, Lock].
    #   importmap: path of an import map JSON file ({ "imports": ..., "cdn": ... })
    #   lock:      the Lock from an earlier run (Lock.new to resolve everything)
    #   frozen:    raise instead of resolving anything not in `lock`
    def self.bundle(input, importmap: nil, cdn: nil, lock: Lock.new, frozen: false, io: nil)
      map = {}
      if importmap
        begin
          map = JSON.parse(File.read(importmap))
        rescue JSON::ParserError => e
          raise Error, "#{importmap}: invalid JSON: #{e.message}"
        end
        raise Error, "#{importmap}: expected a JSON object" unless map.is_a?(Hash)
      end
      imports = map['imports'] || {}
      page = file_url(importmap || File.join(Dir.pwd, 'index.html'))
      io ||= FileIO.new(page)

      app_url = file_url(input)
      local = app_url[0..app_url.rindex('/')]
      resolver = Resolver.new(io, imports: imports, cdn: cdn || map['cdn'])
      locking = LockingResolver.new(resolver, lock, imports: imports, local: local, frozen: frozen)
      code = File.read(input, encoding: 'UTF-8')
      expanded = Expander.new(locking).expand_script(code, app_url, input)
      [expanded, locking.lock]
    end

    USAGE = <<~TEXT
      Usage: picoruby-libs bundle APP.rb [-o OUT.rb] [options]

      Expands the require / require_relative lines of APP.rb the way loader.rb
      does in the browser, so the result runs as a plain text/ruby script
      without the loader or a CDN.
    TEXT

    def self.run(argv, out: $stdout, err: $stderr)
      command = argv.shift
      unless command == 'bundle'
        err.puts USAGE
        return command.nil? || %w[-h --help help].include?(command) ? 0 : 1
      end

      options = { lock: :default }
      parser = OptionParser.new do |o|
        o.banner = USAGE
        o.on('-o', '--output FILE', 'Write the result to FILE (default: standard output)') { |v| options[:output] = v }
        o.on('--importmap FILE', 'Import map JSON ({ "imports": ..., "cdn": ... }); relative URLs in it are relative to FILE') { |v| options[:importmap] = v }
        o.on('--cdn URL', 'npm CDN (default: the import map\'s "cdn", or jsDelivr)') { |v| options[:cdn] = v }
        o.on('--lockfile FILE', "Lockfile (default: #{DEFAULT_LOCKFILE} next to APP.rb)") { |v| options[:lock] = v }
        o.on('--no-lockfile', 'Neither read nor write a lockfile') { options[:lock] = nil }
        o.on('--frozen', 'Fail instead of resolving or fetching anything the lockfile does not have') { options[:frozen] = true }
        o.on('--update', 'Ignore the lockfile and resolve everything again (it is rewritten)') { options[:update] = true }
      end
      args = parser.parse(argv)
      if args.size != 1
        err.puts parser.help
        return 1
      end
      input = args[0]
      lock_path = options[:lock] == :default ? File.join(File.dirname(input), DEFAULT_LOCKFILE) : options[:lock]
      raise Error, '--frozen and --update cannot be used together' if options[:frozen] && options[:update]
      raise Error, '--frozen needs a lockfile' if options[:frozen] && !(lock_path && File.exist?(lock_path))

      old = options[:update] ? Lock.new : Lock.read(lock_path)
      code, lock = bundle(input, importmap: options[:importmap], cdn: options[:cdn], lock: old, frozen: options[:frozen])
      header = "# Bundled from #{File.basename(input)} by picoruby-libs. Do not edit; run `picoruby-libs bundle` again.\n"
      text = header + code.sub(/\n*\z/, "\n")
      if options[:output]
        File.write(options[:output], text)
      else
        out.write(text)
      end
      # --update rewrites the lockfile without reading it (it may be invalid).
      if lock_path && !options[:frozen] && (options[:update] || !File.exist?(lock_path) || lock != Lock.read(lock_path))
        File.write(lock_path, lock.to_json)
      end
      0
    rescue Error, OptionParser::ParseError, SystemCallError => e
      err.puts "picoruby-libs: #{e.message}"
      1
    end
  end
end
