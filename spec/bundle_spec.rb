require 'json'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/picoruby_libs/bundle'

RSpec.describe PicoRubyLibs::Bundle do
  # The E2E fixtures double as a CDN on disk: npm/<name>@<version>/...
  let(:npm_dir) { File.expand_path('../e2e/fixtures/npm', __dir__) }
  let(:cdn) { PicoRubyLibs::Bundle.file_url(npm_dir) + '/' }
  let(:dir) { Dir.mktmpdir('picoruby-libs-bundle') }
  let(:app) { File.join(dir, 'app.rb') }
  let(:lockfile) { File.join(dir, 'picoruby-libs.lock.json') }
  let(:importmap) { File.join(dir, 'importmap.json') }
  # Copies of the CDN go outside the app's directory: files under it are the
  # app's own and are not locked.
  let(:copy) { File.join(Dir.mktmpdir('picoruby-libs-cdn'), 'npm') }

  after { FileUtils.rm_rf([dir, File.dirname(copy)]) }

  def write_importmap(imports)
    File.write(importmap, JSON.generate('cdn' => cdn, 'imports' => imports))
  end

  def run(*args)
    out = StringIO.new
    err = StringIO.new
    status = PicoRubyLibs::Bundle.run(args, out: out, err: err)
    [status, out.string, err.string]
  end

  before do
    write_importmap('greeter' => 'npm:greeter@1.0.0', 'shout' => 'npm:shout@2.0.0')
    File.write(app, "require 'greeter'\nrequire 'json'\nrequire_relative 'lib/helper'\nputs Greeter.greet(Helper::NAME)\n")
    FileUtils.mkdir_p(File.join(dir, 'lib'))
    File.write(File.join(dir, 'lib', 'helper.rb'), "module Helper\n  NAME = 'bundle'\nend\n")
  end

  it 'inlines libraries, their dependencies and require_relative files, and leaves built-ins' do
    status, out, err = run('bundle', app, '--importmap', importmap)
    expect([status, err]).to eq([0, ''])
    expect(out).to start_with('# Bundled from app.rb by picoruby-libs.')
    expect(out).to include("module Shout\n", "VERSION = '1.0.0'", "module Greeter\n", "NAME = 'bundle'")
    expect(out).to include("require 'json'\n", "require 'js'\n")
    expect(out).not_to match(/^require 'greeter'/)
    expect(out.index('module Shout')).to be < out.index('def self.greet')
    expect(out).to end_with("puts Greeter.greet(Helper::NAME)\n")
  end

  it 'writes the output file and a lockfile with the resolved URLs and integrity of library files' do
    status, = run('bundle', app, '--importmap', importmap, '-o', File.join(dir, 'app.bundle.rb'))
    expect(status).to eq(0)
    expect(File.read(File.join(dir, 'app.bundle.rb'))).to include('module Greeter')

    lock = JSON.parse(File.read(lockfile))
    expect(lock['lockfileVersion']).to eq(1)
    expect(lock['requires']).to eq(
      'greeter' => { 'import' => 'npm:greeter@1.0.0', 'id' => 'greeter', 'url' => "#{cdn}greeter@1.0.0/lib/greeter.rb" },
      'shout' => { 'import' => 'npm:shout@2.0.0', 'id' => 'shout', 'url' => "#{cdn}shout@2.0.0/shout.rb" },
    )
    expect(lock['integrity'].keys).to contain_exactly(
      "#{cdn}greeter@1.0.0/lib/greeter.rb",
      "#{cdn}greeter@1.0.0/lib/greeter/version.rb",
      "#{cdn}shout@2.0.0/shout.rb",
    )
    expect(lock['integrity'].values).to all(match(%r{\Asha384-[A-Za-z0-9+/]+=*\z}))
  end

  context 'with a lockfile' do
    before { run('bundle', app, '--importmap', importmap) }

    let(:counting_io) do
      Class.new(PicoRubyLibs::Bundle::FileIO) do
        attr_reader :json_calls

        def fetch_json(url)
          (@json_calls ||= []) << url
          super
        end
      end.new(PicoRubyLibs::Bundle.file_url(importmap))
    end

    it 'takes locked names from it without reading package.json' do
      lock = PicoRubyLibs::Bundle::Lock.read(lockfile)
      code, new_lock = PicoRubyLibs::Bundle.bundle(app, importmap: importmap, lock: lock, io: counting_io)
      expect(code).to include('module Greeter')
      expect(counting_io.json_calls).to be_nil
      expect(new_lock).to eq(lock)
    end

    it 'resolves a name again when its import-map value changed' do
      # A CDN copy that also serves greeter@1 (a version range on a real CDN).
      FileUtils.cp_r(npm_dir, copy)
      FileUtils.cp_r(File.join(copy, 'greeter@1.0.0'), File.join(copy, 'greeter@1'))
      write_importmap('greeter' => 'npm:greeter@1', 'shout' => 'npm:shout@2.0.0')
      lock = PicoRubyLibs::Bundle::Lock.read(lockfile)
      _, new_lock = PicoRubyLibs::Bundle.bundle(app, importmap: importmap, cdn: PicoRubyLibs::Bundle.file_url(copy) + '/',
                                                     lock: lock, io: counting_io)
      expect(counting_io.json_calls).to include(a_string_ending_with('greeter@1/package.json'))
      expect(new_lock.requires['greeter']['import']).to eq('npm:greeter@1')
    end

    it 'fails when a locked file changed' do
      FileUtils.cp_r(npm_dir, copy)
      lock = JSON.parse(File.read(lockfile))
      lock = JSON.parse(JSON.generate(lock).gsub(cdn, PicoRubyLibs::Bundle.file_url(copy) + '/'))
      File.write(lockfile, JSON.generate(lock))
      File.write(File.join(copy, 'shout@2.0.0', 'shout.rb'), "module Shout; end # changed\n")

      status, out, err = run('bundle', app, '--importmap', importmap)
      expect(status).to eq(1)
      expect(out).to eq('')
      expect(err).to include('integrity mismatch for', 'shout@2.0.0/shout.rb', "from require 'shout'")
    end

    it 'with --frozen, fails on an npm require that is not locked, without asking npm' do
      before_lock = File.read(lockfile)
      File.write(app, "require 'other'\n" + File.read(app))
      write_importmap('greeter' => 'npm:greeter@1.0.0', 'shout' => 'npm:shout@2.0.0', 'other' => 'npm:other@1')
      lock = PicoRubyLibs::Bundle::Lock.read(lockfile)
      expect {
        PicoRubyLibs::Bundle.bundle(app, importmap: importmap, lock: lock, frozen: true, io: counting_io)
      }.to raise_error(PicoRubyLibs::Error, /cannot resolve other with --frozen: it is not in the lockfile/)
      expect(counting_io.json_calls).to be_nil

      status, _, err = run('bundle', app, '--importmap', importmap, '--frozen')
      expect(status).to eq(1)
      expect(err).to include('cannot resolve other with --frozen')
      expect(File.read(lockfile)).to eq(before_lock)
    end

    it 'with --frozen, fails on a changed import-map value without asking npm' do
      write_importmap('greeter' => 'npm:greeter@2', 'shout' => 'npm:shout@2.0.0')
      lock = PicoRubyLibs::Bundle::Lock.read(lockfile)
      expect {
        PicoRubyLibs::Bundle.bundle(app, importmap: importmap, lock: lock, frozen: true, io: counting_io)
      }.to raise_error(PicoRubyLibs::Error, /greeter with --frozen: its import-map value changed/)
      expect(counting_io.json_calls).to be_nil
    end

    it 'with --frozen, does not fetch a library file that has no integrity in the lockfile' do
      data = JSON.parse(File.read(lockfile))
      missing = "#{cdn}greeter@1.0.0/lib/greeter/version.rb"
      data['integrity'].delete(missing)
      File.write(lockfile, JSON.generate(data))
      fetched = []
      io = Class.new(PicoRubyLibs::Bundle::FileIO) do
        define_method(:fetch_text) { |url| fetched << url; super(url) }
      end.new(PicoRubyLibs::Bundle.file_url(importmap))
      expect {
        PicoRubyLibs::Bundle.bundle(app, importmap: importmap, lock: PicoRubyLibs::Bundle::Lock.read(lockfile),
                                         frozen: true, io: io)
      }.to raise_error(PicoRubyLibs::Error, /cannot fetch #{Regexp.escape(missing)} with --frozen/)
      expect(fetched).not_to include(missing)
    end

    it 'with --frozen, succeeds when everything is locked' do
      status, out, = run('bundle', app, '--importmap', importmap, '--frozen')
      expect(status).to eq(0)
      expect(out).to include('module Greeter')
    end

    it 'with --update, replaces a lockfile it cannot read' do
      File.write(lockfile, '{ not json')
      status, out, err = run('bundle', app, '--importmap', importmap, '--update')
      expect([status, err]).to eq([0, ''])
      expect(out).to include('module Greeter')
      expect(JSON.parse(File.read(lockfile))['requires'].keys).to eq(%w[greeter shout])
    end

    it 'with --update, resolves everything again' do
      File.write(lockfile, JSON.generate('lockfileVersion' => 1, 'requires' => {
        'greeter' => { 'import' => 'npm:greeter@1.0.0', 'id' => 'greeter', 'url' => 'file:///nowhere/greeter.rb' },
      }, 'integrity' => {}))
      status, out, = run('bundle', app, '--importmap', importmap, '--update')
      expect(status).to eq(0)
      expect(out).to include('module Greeter')
      expect(JSON.parse(File.read(lockfile))['requires']['greeter']['url']).to eq("#{cdn}greeter@1.0.0/lib/greeter.rb")
    end
  end

  it 'resolves names mapped to a relative URL where the import map is now, and does not lock them' do
    write_importmap('greeter' => 'npm:greeter@1.0.0', 'shout' => 'npm:shout@2.0.0', 'local' => './vendor/local.rb')
    FileUtils.mkdir_p(File.join(dir, 'vendor'))
    File.write(File.join(dir, 'vendor', 'local.rb'), "module Local; end\n")
    File.write(app, "require 'local'\n" + File.read(app))
    expect(run('bundle', app, '--importmap', importmap)[0]).to eq(0)
    expect(JSON.parse(File.read(lockfile))['requires'].keys).to eq(%w[greeter shout])

    # The same app in another directory (a moved checkout) with --frozen.
    moved = Dir.mktmpdir('picoruby-libs-moved')
    begin
      FileUtils.cp_r(File.join(dir, '.'), moved)
      FileUtils.rm_rf(dir)
      status, out, err = run('bundle', File.join(moved, 'app.rb'), '--importmap', File.join(moved, 'importmap.json'), '--frozen')
      expect([status, err]).to eq([0, ''])
      expect(out).to include("(#{PicoRubyLibs::Bundle.file_url(moved)}/vendor/local.rb)")
    ensure
      FileUtils.rm_rf(moved)
    end
  end

  it 'does not write a lockfile with --no-lockfile' do
    expect(run('bundle', app, '--importmap', importmap, '--no-lockfile')[0]).to eq(0)
    expect(File.exist?(lockfile)).to be(false)
  end

  it 'reports a missing library with the require chain' do
    write_importmap('greeter' => 'npm:greeter@9.9.9')
    status, _, err = run('bundle', app, '--importmap', importmap)
    expect(status).to eq(1)
    expect(err).to include('npm package not found: greeter@9.9.9', "from require 'greeter' at #{app}:1")
  end

  it 'prints usage for an unknown command' do
    status, _, err = run('build', app)
    expect(status).to eq(1)
    expect(err).to include('Usage: picoruby-libs bundle')
  end
end
