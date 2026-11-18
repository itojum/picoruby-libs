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

      def fetch_text(url)
        @calls << url
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
    PicoRubyLibs::Resolver.new(fake_io_class.new(files), cdn: cdn, **options)
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

    describe 'import map' do
      subject(:r) do
        resolver(
          { "#{cdn}mylib@2.0.0/package.json" => { 'name' => 'mylib', 'version' => '2.0.0', 'main' => 'lib/mylib.rb' } },
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

      it 'maps a name to a file inside an npm package' do
        expect(r.resolve('sub').url).to eq "#{cdn}other@1/lib/sub.rb"
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

    it "raises when a library's file cannot be loaded" do
      expander = described_class.new(resolver(libraries(nil, '')))
      expect { expander.expand("require 'a'") }.to raise_error(PicoRubyLibs::Error, /failed to load/)
    end
  end
end
