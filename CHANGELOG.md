# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A `require` / `require_relative` the loader does not expand because it is not a whole statement on its own line (`require 'a' if x`, `require 'a'; require 'b'`) now prints a warning with the file and line in the browser console, when it names a library or a file. Built-ins and npm packages that are not PicoRuby libraries are not reported. ([#19](https://github.com/itojum/picoruby-libs/issues/19))

### Changed

- An indented `require` / `require_relative` of a library (one the loader would inline, not a built-in) now raises `PicoRubyLibs::Error` naming the file and line, instead of inlining the library inside a `def` (a SyntaxError) or a `class` (another namespace). Move it to the top level. A script indented as a whole (as inline scripts usually are) is measured from its least indented line. ([#15](https://github.com/itojum/picoruby-libs/issues/15))

### Fixed

- A `require` line inside a heredoc (`<<~ID`, `<<-ID`, `<<ID`, quoted or not) is no longer expanded. Other multi-line strings are still not tracked; see Limitations in the README. ([#14](https://github.com/itojum/picoruby-libs/issues/14))

## [0.2.0] - 2026-11-19

### Added

- `require_relative 'x'` is expanded like a library `require`: the loader fetches `x.rb` and inlines it before the script runs. ([#8](https://github.com/itojum/picoruby-libs/pull/8))
  - The path is resolved against the URL of the file that contains the line: the `src` of a `text/ruby-app` script, the URL of a library file, or the page for an inline script.
  - `.rb` is appended when the name has no extension; an explicit extension is kept.
  - Each file is inlined once per URL. Circular requires are dropped.
  - Known limitation: npm entry files are tracked by package name and `require_relative` files by URL, so a file loaded both through `require 'pkg'` and through `require_relative` is inlined twice and its top-level code runs twice.
  - A file that cannot be fetched raises `PicoRubyLibs::Error`.
  - It also works inside npm libraries, so a library can ship as several files.

### Changed

- Releasing: the published version is now the `version` in `package.json`, and the release tag must match it (`0.2.0` → `v0.2.0`). ([#7](https://github.com/itojum/picoruby-libs/pull/7))
- Releasing: prereleases (e.g. `0.3.0-rc.1`) are published under the `next` dist-tag and leave `latest` alone. ([#6](https://github.com/itojum/picoruby-libs/pull/6))

### Security

- The publish workflow reads the ref name from `GITHUB_REF_NAME` instead of interpolating it into the script. ([#5](https://github.com/itojum/picoruby-libs/pull/5))

## [0.1.0] - 2026-11-18

### Added

- First release: `loader.rb` lets `text/ruby-app` scripts on PicoRuby.wasm `require` libraries published on npm, with version pinning and source mapping through `text/ruby-importmap`.

[Unreleased]: https://github.com/itojum/picoruby-libs/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/itojum/picoruby-libs/releases/tag/v0.2.0
[0.1.0]: https://www.npmjs.com/package/picoruby-libs/v/0.1.0
