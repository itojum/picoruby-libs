require 'uri'
PICORUBY_LIBS_NO_BOOT = true
require_relative '../loader'

RSpec.describe PicoRubyLibs do
  def cdn = 'https://cdn.test/npm/'

  # Serves { url => body } tables in place of the network. A Hash body is a
  # package.json.
  let(:fake_io_class) do
    Class.new do
      attr_reader :calls

      def initialize(files)
        @files = files
        @calls = []
      end

      # A file's hash is served at "<url>#sri"; a fetch with another
      # integrity fails like the browser's does.
      def fetch_text(url, integrity = nil)
        @calls << url
        return nil if integrity && @files["#{url}#sri"] != integrity
        @files[url]
      end

      def fetch_json(url)
        @calls << url
        @files[url]
      end

      def absolute_url(path, base = nil)
        return URI.join(base, path).to_s if base
        'https://site.test/game/' + path.sub(%r{^\./}, '')
      end
    end
  end

  def resolver(files, **options)
    PicoRubyLibs::Resolver.new(fake_io_class.new(files), **{ cdn: cdn }.merge(options))
  end

  def package(name, version, fields)
    { "#{cdn}#{name}/package.json" => { 'name' => name, 'version' => version }.merge(fields) }
  end

  describe '.find_requires' do
    it 'finds whole-line requires and skips comments, strings and __END__' do
      code = [
        "require 'mylib'",
        '  require "js"   # comment',
        "require('foo')",
        "x = 1 # require 'not_this'",
        "puts \"require 'nor_this'\"",
        '=begin',
        "require 'commented'",
        '=end',
        "require './local'",
        '__END__',
        "require 'after_end'",
      ].join("\n")

      found = described_class.find_requires(code).map { |r| [r.index, r.name] }
      expect(found).to eq [[0, 'mylib'], [1, 'js'], [2, 'foo'], [8, './local']]
    end

    it 'skips the bodies of heredocs' do
      code = [
        'HELP = <<~TXT',
        "  require 'in_squiggly'",
        'TXT',
        "require 'a'",
        "x = <<-'EOS'",
        "require 'in_dash'",
        '  EOS',
        'y = <<RAW',
        "require 'in_bare'",
        '  RAW',
        "require 'still_in_bare'",
        'RAW',
        "require 'b'",
        'foo(<<~ONE, <<~"TWO")',
        "  require 'in_one'",
        'ONE',
        "  require 'in_two'",
        'TWO',
        "require 'c'",
      ].join("\n")

      found = described_class.find_requires(code).map(&:name)
      expect(found).to eq %w[a b c]
    end

    it 'does not take a shift, a string or a comment for a heredoc' do
      code = [
        'list <<item',
        'class << self',
        '# see <<~EOS',
        'x = 1 # see <<~EOS',
        'puts "<<~EOS"',
        "puts 'a <<-EOS', `<<EOS`",
        'n = 1 <<BITS',
        'n = (m) <<BITS',
        'n = m<<BITS',
        "require 'a'",
        'EOS',
        'BITS',
      ].join("\n")
      expect(described_class.find_requires(code).map(&:name)).to eq ['a']
    end

    it 'closes an indentable heredoc only on a terminator without trailing blanks' do
      code = "h = <<~EOS\nEOS \nrequire 'literal'\n  EOS\nrequire 'a'"
      expect(described_class.find_requires(code).map(&:name)).to eq ['a']
    end

    it 'steps over regexps and percent literals' do
      code = [
        'x = /<<~EOS/',
        'y = %q{<<~EOS}',
        'w = %w[<<~EOS a]',
        'z = a / 2 + c / 3 <<X',
        "require 'a'",
        'puts %q{#}, <<~EOS',
        "require 'in_heredoc'",
        'EOS',
        'q = n % m',
        "require 'b'",
      ].join("\n")
      expect(described_class.find_requires(code).map(&:name)).to eq %w[a b]
    end

    it 'takes << after an identifier ending in a digit for a heredoc' do
      code = "log2 <<~EOS\nrequire 'in_heredoc'\nEOS\nn = 2 <<X\nrequire 'a'"
      expect(described_class.find_requires(code).map(&:name)).to eq ['a']
    end

    it 'reads quoted delimiters, interpolation, keywords and percent delimiters' do
      code = [
        "help = <<~'END-TEXT'", "require 'l1'", 'END-TEXT',
        'text = "#{<<~EOS}"', "require 'l2'", 'EOS',
        'puts "#{h["#"]}", <<~EOS', "require 'l3'", 'EOS',
        'def help', 'return<<~EOS', "require 'l4'", 'EOS', 'end',
        's = %$<<~EOS$',
        't = %(#{<<~EOS})', "require 'l6'", 'EOS',
        "u = %q(\#{<<~EOS})",
        'puts %:#:, <<~EOS', "require 'l5'", 'EOS',
        'x %= 2',
        'class <<ENV',
        "require 'real'",
        'end',
      ].join("\n")
      expect(described_class.find_requires(code).map(&:name)).to eq ['real']
    end

    it 'reads CRLF source' do
      code = "h = <<~EOS\r\ntext\r\nEOS\r\nrequire 'real'\r\n"
      expect(described_class.find_requires(code).map(&:name)).to eq ['real']
    end

    it 'finds heredocs after a string or as a method argument' do
      code = "puts 'x', <<~A\nrequire 'in_a'\nA\nputs <<B\nrequire 'in_b'\nB\nrequire 'c'"
      expect(described_class.find_requires(code).map(&:name)).to eq ['c']
    end

    it 'finds require_relative lines and marks them relative' do
      code = "require_relative 'a'\n  require_relative('../b.rb') # c\nrequire 'c'"
      found = described_class.find_requires(code).map { |r| [r.index, r.name, r.relative?] }
      expect(found).to eq [[0, 'a', true], [1, '../b.rb', true], [2, 'c', false]]
    end
  end

  describe '.parse_spec' do
    it 'splits a package name and version' do
      expect(described_class.parse_spec('mylib')).to eq ['mylib', nil]
      expect(described_class.parse_spec('mylib@1.2.3')).to eq ['mylib', '1.2.3']
    end

    it 'keeps the @ of a scoped package' do
      expect(described_class.parse_spec('@a/b@1')).to eq ['@a/b', '1']
      expect(described_class.parse_spec('@a/b')).to eq ['@a/b', nil]
    end
  end

  describe '.script_filename' do
    it 'names an inline script by its position on the page' do
      expect(described_class.script_filename('', 1)).to eq 'inline-1.rb'
      expect(described_class.script_filename('', 3)).to eq 'inline-3.rb'
    end

    it 'takes the last segment of the src path, without query or fragment' do
      expect(described_class.script_filename('https://site.test/game/app.rb', 1)).to eq 'app.rb'
      expect(described_class.script_filename('https://site.test/game/app.rb?v=2', 1)).to eq 'app.rb'
      expect(described_class.script_filename('https://site.test/game/app.rb#main', 1)).to eq 'app.rb'
      expect(described_class.script_filename('https://site.test/game/app.rb?a=b/c#d/e', 1)).to eq 'app.rb'
    end

    it 'falls back to the position when the path ends in a slash' do
      expect(described_class.script_filename('https://site.test/game/?v=2', 2)).to eq 'script-2.rb'
    end
  end

  describe '.import_map_error' do
    it 'names the import map by its position and id, with the original error' do
      expect(described_class.import_map_error(2, 'libs', 'Unexpected token }'))
        .to eq 'text/ruby-importmap #2 (id="libs"): invalid JSON: Unexpected token }'
    end

    it 'leaves out the id when the script has none' do
      expect(described_class.import_map_error('1', '', 'expected a JSON object'))
        .to eq 'text/ruby-importmap #1: invalid JSON: expected a JSON object'
    end
  end

  describe PicoRubyLibs::Resolver do
    it 'resolves the "picoruby" field, pinned to the version package.json reports' do
      r = resolver(package('mylib', '1.2.3', 'picoruby' => 'lib/mylib.rb'))
      expect(r.resolve('mylib')).to eq PicoRubyLibs::Library.new('mylib', "#{cdn}mylib@1.2.3/lib/mylib.rb")
    end

    it 'accepts the "picoruby" field as an object with "main"' do
      r = resolver(package('mylib', '1.0.0', 'picoruby' => { 'main' => './x.rb' }))
      expect(r.resolve('mylib').url).to eq "#{cdn}mylib@1.0.0/x.rb"
    end

    it 'falls back to a "main" ending in .rb' do
      r = resolver(package('mylib', '2.0.0', 'main' => 'lib/mylib.rb'))
      expect(r.resolve('mylib').url).to eq "#{cdn}mylib@2.0.0/lib/mylib.rb"
    end

    it 'leaves built-ins, relative paths and non-PicoRuby packages to PicoRuby' do
      r = resolver(package('leftpad', '1.0.0', 'main' => 'index.js'))

      expect(r.resolve('js')).to be_nil
      expect(r.resolve('./x')).to be_nil
      expect(r.resolve('leftpad')).to be_nil
      expect(r.resolve('nothing-here')).to be_nil
      expect(r.io.calls).to all(satisfy { |url| !url.include?('/js/') })
    end

    describe 'a path inside a package' do
      it 'is pinned to the version package.json reports' do
        r = resolver(package('mylib', '1.2.3', 'picoruby' => 'lib/mylib.rb'))
        lib = r.resolve('mylib/lib/extra.rb')
        expect(lib).to eq PicoRubyLibs::Library.new("#{cdn}mylib@1.2.3/lib/extra.rb", "#{cdn}mylib@1.2.3/lib/extra.rb")
      end

      it 'uses the same release as the package entry, fetching package.json once' do
        r = resolver(package('mylib', '1.2.3', 'picoruby' => 'lib/mylib.rb'))
        r.resolve('mylib')
        expect(r.resolve('mylib/lib/extra.rb').url).to eq "#{cdn}mylib@1.2.3/lib/extra.rb"
        expect(r.io.calls.count { |url| url.end_with?('package.json') }).to eq 1
      end

      it 'is left to PicoRuby when the package is missing or not a PicoRuby library' do
        r = resolver(package('leftpad', '1.0.0', 'main' => 'index.js'))
        expect(r.resolve('leftpad/x.rb')).to be_nil
        expect(r.resolve('nothing-here/x.rb')).to be_nil
      end
    end

    describe 'several CDNs' do
      let(:mirror) { 'https://mirror.test/npm/' }
      let(:files) do
        {
          "#{mirror}mylib/package.json" => { 'name' => 'mylib', 'version' => '1.2.3', 'picoruby' => 'lib/mylib.rb' },
          "#{mirror}mylib@1.2.3/lib/mylib.rb" => "require_relative 'part'\nM = P",
          "#{mirror}mylib@1.2.3/lib/part.rb" => 'P = 1',
        }
      end

      it 'takes the package from the first CDN that has it, with the others as mirrors' do
        r = resolver(files, cdn: [cdn, 'https://mirror.test/npm'])
        expect(r.resolve('mylib').url).to eq "#{mirror}mylib@1.2.3/lib/mylib.rb"
        expect(r.resolve('mylib').mirrors).to eq ["#{cdn}mylib@1.2.3/lib/mylib.rb"]
        expect(r.io.calls).to eq ["#{cdn}mylib/package.json", "#{mirror}mylib/package.json"]
      end

      it 'fetches a file from the next CDN when the first cannot serve it' do
        files["#{cdn}mylib/package.json"] = files["#{mirror}mylib/package.json"]
        r = resolver(files, cdn: [cdn, mirror])
        out = PicoRubyLibs::Expander.new(r).expand("require 'mylib'")
        expect(out.index('P = 1')).to be < out.index('M = P')
        expect(r.io.calls).to include("#{cdn}mylib@1.2.3/lib/part.rb", "#{mirror}mylib@1.2.3/lib/part.rb")
      end

      it 'accepts a single CDN given as a String' do
        r = resolver(files, cdn: mirror)
        expect(r.resolve('mylib').mirrors).to eq []
      end
    end

    describe 'import map' do
      subject(:r) do
        resolver(
          {
            "#{cdn}mylib@2.0.0/package.json" => { 'name' => 'mylib', 'version' => '2.0.0', 'main' => 'lib/mylib.rb' },
            "#{cdn}other@1/package.json" => { 'name' => 'other', 'version' => '1.4.0' },
          },
          imports: {
            'mylib' => 'npm:mylib@2.0.0',
            'local' => './vendor/local.rb',
            'sub' => 'npm:other@1/lib/sub.rb',
            'skipme' => false,
            'bad' => 'npm:missing',
          },
        )
      end

      it 'pins an npm version' do
        expect(r.resolve('mylib').url).to eq "#{cdn}mylib@2.0.0/lib/mylib.rb"
      end

      it 'maps a name to a URL relative to the page' do
        expect(r.resolve('local').url).to eq 'https://site.test/game/vendor/local.rb'
      end

      it 'maps a name to a file inside an npm package, pinned to the version package.json reports' do
        expect(r.resolve('sub').url).to eq "#{cdn}other@1.4.0/lib/sub.rb"
      end

      it 'pins a path inside a package to the version the import map gives the package' do
        expect(r.resolve('mylib/lib/extra.rb').url).to eq "#{cdn}mylib@2.0.0/lib/extra.rb"
      end

      it 'keeps an unversioned package entry on the release a path already pinned' do
        files = {
          "#{cdn}pkg@1/package.json" => { 'name' => 'pkg', 'version' => '1.4.0', 'picoruby' => 'lib/pkg.rb' },
          "#{cdn}pkg/package.json" => { 'name' => 'pkg', 'version' => '2.0.0', 'picoruby' => 'lib/pkg.rb' },
        }
        r = resolver(files, imports: { 'sub' => 'npm:pkg@1/lib/sub.rb' })
        expect(r.resolve('sub').url).to eq "#{cdn}pkg@1.4.0/lib/sub.rb"
        expect(r.resolve('pkg').url).to eq "#{cdn}pkg@1.4.0/lib/pkg.rb"
        expect(r.resolve('pkg/lib/extra.rb').url).to eq "#{cdn}pkg@1.4.0/lib/extra.rb"
      end

      it 'pins an unversioned path to the version the import map gives its package, over an earlier pin' do
        files = {
          "#{cdn}pkg@1/package.json" => { 'name' => 'pkg', 'version' => '1.0.0', 'picoruby' => 'lib/pkg.rb' },
          "#{cdn}pkg@2/package.json" => { 'name' => 'pkg', 'version' => '2.0.0', 'picoruby' => 'lib/pkg.rb' },
        }
        r = resolver(files, imports: { 'sub' => 'npm:pkg@1/lib/sub.rb', 'pkg' => 'npm:pkg@2' })
        expect(r.resolve('sub').url).to eq "#{cdn}pkg@1.0.0/lib/sub.rb"
        expect(r.resolve('pkg').url).to eq "#{cdn}pkg@2.0.0/lib/pkg.rb"
        expect(r.resolve('pkg/lib/extra.rb').url).to eq "#{cdn}pkg@2.0.0/lib/extra.rb"
      end

      it 'leaves a name mapped to false to PicoRuby' do
        expect(r.resolve('skipme')).to be_nil
      end

      it 'raises when an npm: entry does not exist' do
        expect { r.resolve('bad') }.to raise_error(PicoRubyLibs::Error, /not found/)
      end
    end
  end

  describe PicoRubyLibs::Expander do
    def libraries(a_body, b_body)
      package('a', '1.0.0', 'picoruby' => 'a.rb')
        .merge(package('b', '1.0.0', 'picoruby' => 'b.rb'))
        .merge("#{cdn}a@1.0.0/a.rb" => a_body, "#{cdn}b@1.0.0/b.rb" => b_body)
    end

    context 'with a library that requires another one' do
      let(:expanded) do
        files = libraries("require 'js'\nrequire 'b'\nA = 1\n", "B = 2\n")
        described_class.new(resolver(files)).expand_all(["require 'a'\nputs A + B", "  require 'b'\nputs B"])
      end
      let(:first) { expanded[0] }
      let(:second) { expanded[1] }

      it 'keeps requires of built-ins' do
        expect(first).to include("require 'js'")
      end

      it 'inlines the dependency before the library, and the library before its user' do
        expect(first.index('B = 2')).to be < first.index('A = 1')
        expect(first.index('A = 1')).to be < first.index('puts A + B')
      end

      it 'inlines each library once, at its first require in document order' do
        expect(second).not_to match(/^\s*require 'b'/)
        expect(second).not_to include('B = 2')
        expect(second).to end_with('puts B')
      end
    end

    it 'drops a circular require like Ruby does' do
      out = described_class.new(resolver(libraries("require 'b'", "require 'a'"))).expand("require 'a'")
      expect(out).to include('already loaded')
    end

    describe 'require_relative' do
      let(:files) do
        {
          'https://site.test/game/src/main.rb' => "require_relative 'lib/util'\nputs U",
          'https://site.test/game/src/lib/util.rb' => "require_relative '../const.rb'\nU = C + 1",
          'https://site.test/game/src/const.rb' => "require_relative 'lib/util'\nC = 1",
          'https://site.test/game/top.rb' => 'T = 1',
          'https://site.test/game/src/back.rb' => "require_relative '../main'\nBACK = 1",
          "#{cdn}a@1.0.0/a.rb" => "require_relative 'parts/x'\nA = X",
          "#{cdn}a@1.0.0/parts/x.rb" => 'X = 1',
        }.merge(package('a', '1.0.0', 'picoruby' => 'a.rb'))
      end
      let(:expander) { described_class.new(resolver(files)) }

      it "resolves against the requiring file's URL, recursively, inlining each file once" do
        out = expander.expand("require_relative 'lib/util'\nputs U", 'https://site.test/game/src/main.rb')
        expect(out.index('C = 1')).to be < out.index('U = C + 1')
        expect(out.index('U = C + 1')).to be < out.index('puts U')
        expect(out).to include('already loaded')
      end

      it 'resolves against the page in a script written in the page' do
        expect(expander.expand_all(["require_relative './top'"])[0]).to include('T = 1')
      end

      it 'resolves inside an npm library against its file URL' do
        out = expander.expand("require 'a'")
        expect(out.index('X = 1')).to be < out.index('A = X')
      end

      it "drops a circular require_relative back to the script's own src" do
        out = expander.expand_all(["require_relative 'src/back'\nMAIN = 1"], ['https://site.test/game/main.rb'])[0]
        expect(out.scan('MAIN = 1').size).to eq 1
        expect(out).to include('already loaded')
      end

      it 'keeps an explicit extension and adds .rb only when there is none' do
        r = resolver({})
        base = 'https://site.test/game/main.rb'
        expect(r.resolve_relative('parts/helper.ruby', base).url).to eq 'https://site.test/game/parts/helper.ruby'
        expect(r.resolve_relative('parts/helper.rb', base).url).to eq 'https://site.test/game/parts/helper.rb'
        expect(r.resolve_relative('../v1.2/x', base).url).to eq 'https://site.test/v1.2/x.rb'
        expect(r.resolve_relative('./x', base).url).to eq 'https://site.test/game/x.rb'
      end

      it 'raises when the file does not exist' do
        expect { expander.expand("require_relative 'nope'") }
          .to raise_error(PicoRubyLibs::Error, %r{failed to load https://site.test/game/nope.rb})
      end
    end

    it 'inlines an npm entry file once when it is also required by path or require_relative' do
      files = package('a', '1.0.0', 'picoruby' => 'lib/a.rb').merge(
        "#{cdn}a@1.0.0/lib/a.rb" => 'A = 1',
        "#{cdn}a@1.0.0/lib/b.rb" => "require_relative 'a'\nB = 1",
      )
      out = described_class.new(resolver(files))
                           .expand("require 'a'\nrequire 'a/lib/a.rb'\nrequire 'a/lib/./a.rb'\nrequire 'a/lib/b.rb'")
      expect(out.scan('A = 1').size).to eq 1
      expect(out).to include('B = 1')
    end

    describe 'integrity' do
      let(:files) do
        package('a', '1.0.0', 'picoruby' => 'a.rb').merge(
          "#{cdn}a@1.0.0/a.rb" => 'A = 1',
          "#{cdn}a@1.0.0/a.rb#sri" => 'sha384-good',
          'https://mirror.test/npm/a@1.0.0/a.rb' => 'A = 1',
          'https://mirror.test/npm/a@1.0.0/a.rb#sri' => 'sha384-good',
        )
      end

      def expand(files, hashes, **options)
        described_class.new(resolver(files, integrity: hashes, **options)).expand("require 'a'")
      end

      it 'fetches a file with the hash the import map gives its URL' do
        expect(expand(files, { "#{cdn}a@1.0.0/a.rb" => 'sha384-good' })).to include('A = 1')
      end

      it 'raises when the file does not match its hash' do
        expect { expand(files, { "#{cdn}a@1.0.0/a.rb" => 'sha384-bad' }) }
          .to raise_error(PicoRubyLibs::Error, /does not match its integrity sha384-bad/)
      end

      it 'checks a mirror against the hash given for any of its URLs' do
        files.delete("#{cdn}a@1.0.0/a.rb")
        hashes = { 'https://mirror.test/npm/a@1.0.0/a.rb' => 'sha384-good' }
        expect(expand(files, hashes, cdn: [cdn, 'https://mirror.test/npm/'])).to include('A = 1')
      end

      it 'fetches files without a hash as before' do
        expect(expand(files, {})).to include('A = 1')
      end
    end

    it 'inlines one release of a package even when its entry is first reached by path' do
      files = {
        "#{cdn}pkg@1.0.0/package.json" => { 'name' => 'pkg', 'version' => '1.0.0', 'picoruby' => 'lib/pkg.rb' },
        "#{cdn}pkg@2.0.0/package.json" => { 'name' => 'pkg', 'version' => '2.0.0', 'picoruby' => 'lib/pkg.rb' },
        "#{cdn}pkg@1.0.0/lib/pkg.rb" => 'V = 1',
        "#{cdn}pkg@2.0.0/lib/pkg.rb" => 'V = 2',
      }
      r = resolver(files, imports: { 'p1' => 'npm:pkg@1.0.0/lib/pkg.rb', 'one' => 'npm:pkg@1.0.0', 'two' => 'npm:pkg@2.0.0' })
      out = described_class.new(r).expand("require 'p1'\nrequire 'one'\nrequire 'two'")
      expect(out).to include('V = 1')
      expect(out).not_to include('V = 2')
    end

    it "raises when a library's file cannot be loaded" do
      expander = described_class.new(resolver(libraries(nil, '')))
      expect { expander.expand("require 'a'") }.to raise_error(PicoRubyLibs::Error, /failed to load/)
    end

    it 'names each require that led to a failure, with its file and line' do
      expander = described_class.new(resolver(libraries("require 'js'\nrequire 'b'", nil)))
      expect { expander.expand("x = 1\nrequire 'a'", nil, 'script #1') }.to raise_error(
        PicoRubyLibs::Error,
        "failed to load #{cdn}b@1.0.0/b.rb\n" \
        "  from require 'b' at #{cdn}a@1.0.0/a.rb:2\n" \
        "  from require 'a' at script #1:2",
      )
    end
  end

  describe '.boot' do
    # Stands in for BrowserIO: scripts are [code, filename, url] and the
    # started tasks and reported errors are recorded.
    let(:boot_io_class) do
      Class.new(fake_io_class) do
        attr_reader :tasks, :errors

        def initialize(files, scripts, imports: {}, cdn: nil)
          super(files)
          @scripts = scripts
          @imports = imports
          @cdn = cdn
          @tasks = []
          @errors = []
        end

        def import_map = [@imports, @cdn]
        def app_scripts = @scripts
        def create_task(code, filename) = @tasks << [code, filename]
        def report_error(message) = @errors << message
      end
    end

    let(:files) do
      package('a', '1.0.0', 'picoruby' => 'a.rb')
        .merge(package('b', '1.0.0', 'picoruby' => 'b.rb'))
        .merge("#{cdn}a@1.0.0/a.rb" => 'A = 1', "#{cdn}b@1.0.0/b.rb" => "require 'gone'\nB = 1")
        .merge(package('gone', '1.0.0', 'picoruby' => 'gone.rb'))
    end

    def boot(scripts)
      io = boot_io_class.new(files, scripts, cdn: cdn)
      described_class.boot(io)
      io
    end

    it 'starts each script as its own task' do
      io = boot([["require 'a'\nputs A", nil, nil], ['puts 2', 'two.rb', 'https://site.test/two.rb']])
      expect(io.tasks.map(&:last)).to eq [nil, 'two.rb']
      expect(io.tasks[0][0]).to include('A = 1')
      expect(io.errors).to be_empty
    end

    it 'skips only the script that fails, and reports where it failed' do
      io = boot([['puts 1', nil, nil], ["\nrequire 'b'", 'main.rb', 'https://site.test/main.rb'], ['puts 3', nil, nil]])
      expect(io.tasks.map(&:first)).to eq ['puts 1', 'puts 3']
      expect(io.errors.size).to eq 1
      expect(io.errors[0]).to start_with('picoruby-libs: script #2 (main.rb) was not started: ')
      expect(io.errors[0]).to include("failed to load #{cdn}gone@1.0.0/gone.rb")
      expect(io.errors[0]).to include("from require 'gone' at #{cdn}b@1.0.0/b.rb:1")
      expect(io.errors[0]).to include("from require 'b' at https://site.test/main.rb:2")
    end

    it "inlines in a later script the libraries a failed script had marked as loaded" do
      io = boot([["require 'a'\nrequire 'b'", nil, nil], ["require 'a'\nputs A", nil, nil]])
      expect(io.errors[0]).to include("from require 'b' at script #1:2")
      expect(io.tasks.size).to eq 1
      expect(io.tasks[0][0]).to include('A = 1')
    end

    it 'inlines into a later script the libraries of a script whose task could not be created' do
      io = boot_io_class.new(files, [["require 'a'\nputs 1", nil, nil], ["require 'a'\nputs 2", nil, nil]], cdn: cdn)
      def io.create_task(code, filename)
        raise 'no task' if code.end_with?('puts 1')
        super
      end
      described_class.boot(io)
      expect(io.errors[0]).to include('script #1 was not started: no task')
      expect(io.tasks.size).to eq 1
      expect(io.tasks[0][0]).to include('A = 1')
    end

    it 'reports a script whose src cannot be fetched and starts the others' do
      io = boot([[nil, 'missing.rb', 'https://site.test/missing.rb'], ['puts 2', nil, nil]])
      expect(io.errors).to eq ['picoruby-libs: script #1 (missing.rb) was not started: failed to load https://site.test/missing.rb']
      expect(io.tasks.map(&:first)).to eq ['puts 2']
    end
  end
end
