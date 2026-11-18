# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- A script that fails to expand (for example, because a library cannot be fetched) no longer stops every other script from starting. Each `text/ruby-app` script is expanded and started on its own; a failing one is skipped and reported with `console.error`. ([#21](https://github.com/itojum/picoruby-libs/issues/21))
  - The error names the script (`script #2 (main.rb)`) and, for each `require` / `require_relative` that led to the failure, its name, file and line.
  - A script whose `src` cannot be fetched is reported the same way instead of raising.
- A `text/ruby-importmap` script that is not valid JSON (or not a JSON object) raises `PicoRubyLibs::Error` naming the script by its position on the page and its `id`, with the parser's message, instead of the bare `JSON.parse` error. ([#22](https://github.com/itojum/picoruby-libs/issues/22))

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
