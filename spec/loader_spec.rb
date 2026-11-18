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

      def absolute_url(path)
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

    it "raises when a library's file cannot be loaded" do
      expander = described_class.new(resolver(libraries(nil, '')))
      expect { expander.expand("require 'a'") }.to raise_error(PicoRubyLibs::Error, /failed to load/)
    end
  end
end
