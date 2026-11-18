# picoruby-libs

`require` PicoRuby libraries published on npm from [PicoRuby.wasm](https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-wasm) scripts in the browser. The loader itself is written in Ruby and runs on PicoRuby.wasm.

```html
<!-- Pin versions (e.g. picoruby-libs@0.2.0) for anything you publish -->
<script type="text/ruby" src="https://cdn.jsdelivr.net/npm/picoruby-libs@latest/loader.rb"></script>

<script type="text/ruby-app">
  require 'mylib'

  MyLib.hello
</script>

<script src="https://cdn.jsdelivr.net/npm/@picoruby/wasm-wasi@latest/dist/init.iife.js"></script>
```

Write your code in `text/ruby-app` scripts (inline or with `src`), not `text/ruby`: PicoRuby.wasm starts every `text/ruby` script at once, before its requires could be resolved. The loader starts the `text/ruby-app` scripts itself.

## How it works

PicoRuby.wasm starts with an empty virtual file system, so `require 'mylib'` cannot find anything in the browser. Running a fetched file with `load` is not an option either: a file being loaded stops silently at its first `await` (`fetch`, a timer, a Promise, …).

So the loader resolves requires before your code starts:

1. PicoRuby.wasm runs `loader.rb` as an ordinary `text/ruby` script.
2. The loader reads every `<script type="text/ruby-app">` on the page.
3. For each line that is a whole `require 'name'` statement, it looks the name up on npm (through jsDelivr) and fetches the package's Ruby entry file.
4. It inlines the library in place of the `require` line and starts each script as one PicoRuby task, in document order. The library runs in the same task as the code that needs it, so `await` works.

Rules:

- Each library is inlined once, at its first `require` in document order. Later requires of it are dropped, and so is a circular one, as in Ruby.
- Requires inside a library are expanded the same way, so a library depends on another by requiring it.
- A name that is not a PicoRuby library is left in the script for PicoRuby to handle. This is how built-ins like `require 'js'` keep working. Known built-ins are not looked up on npm at all.
- Relative requires (`require './x'`) are left as they are. Use `require_relative` instead.

## require_relative

PicoRuby.wasm has no `require_relative`, but the loader expands it like `require`, so code ported from ruby.wasm or CRuby that is split into files keeps working:

```ruby
# game.rb, loaded with <script type="text/ruby-app" src="game.rb">
require_relative 'lib/player'   # fetches lib/player.rb next to game.rb
```

- The path is resolved against the URL of the file that contains the line: the `src` of a `text/ruby-app` script, the URL of a library file, or the page for a script written in the page.
- `.rb` is added when the name has no extension.
- Each file is inlined once, at its first require, as with `require`. A file that cannot be fetched is an error.
- It works inside libraries too, so a library can be published as several files and `require_relative` them from its entry file.

## Publishing a library

A library is an npm package that names its Ruby entry file in `package.json`:

```json
{
  "name": "mylib",
  "picoruby": "lib/mylib.rb"
}
```

`"picoruby": { "main": "lib/mylib.rb" }` works too. Without the field, a `"main"` that ends in `.rb` is used.

The entry file can load the library's other files with `require_relative`.

`require 'name'` loads the npm package `name`. The version is resolved once from `package.json` and every file is then fetched from that exact version.

## Import map

Pin versions or map names to other sources with a `text/ruby-importmap` script:

```html
<script type="text/ruby-importmap">
{
  "imports": {
    "mylib": "npm:mylib@1.2.3",
    "local": "./vendor/local.rb",
    "other": "npm:@me/other@1/lib/other.rb",
    "set": false
  }
}
</script>
```

| Value | Meaning |
|-------|---------|
| `"npm:pkg"`, `"npm:pkg@ver"` | An npm package, resolved through its `package.json`. It must be a PicoRuby library. |
| `"npm:pkg@ver/path.rb"` | A file inside an npm package. |
| any other string | A URL, relative to the page. |
| `false` | Leave this require to PicoRuby. |

A top-level `"cdn"` key changes the npm CDN (default `https://cdn.jsdelivr.net/npm/`).

## Limitations

- Only `require` lines that are a whole statement are recognized. A require inside a method or `if` is still expanded where it is written, since the loader does not parse Ruby.
- Line numbers in error messages refer to the expanded script. Each library is wrapped in `# --- picoruby-libs: name (url) ---` comments.
- The loader starts tasks through `picorb_create_task`, the same PicoRuby.wasm function `init.iife.js` uses. It is not a documented API, so a PicoRuby.wasm release could change it. Pin the runtime version for anything you publish.

## Development

`loader.rb` runs on both PicoRuby.wasm and CRuby, so the specs run on CRuby with RSpec, with the network replaced by a fake. Keep to what PicoRuby supports: its `Regexp` is JavaScript's `RegExp`, so `\A`, `\z` and `$1` do not work.

```bash
bundle install
bundle exec rspec          # or: npm test
npm run serve              # serves examples/ at http://localhost:3000/examples/
```

## Releasing

The version is the `version` in `package.json`. Publishing a GitHub Release whose tag is that version publishes the package to npm.

1. Bump the version in `package.json` and move the `Unreleased` entries in `CHANGELOG.md` under that version, in a PR, and merge it:

   ```bash
   npm version minor --no-git-tag-version   # or patch / major, or edit package.json
   ```

2. Create a release on GitHub with a new tag `v` + that version (`0.2.0` → `v0.2.0`) on `main`. **Generate release notes** fills in the merged PRs.
3. When the release is published, the **Publish to npm** workflow checks that the tag matches `package.json`, runs the specs and publishes the package with provenance. A tag that does not match publishes nothing.

To publish a tag again (for example after a failed publish), run **Publish to npm** by hand from the Actions tab with that tag selected under **Use workflow from**.

Setup, once: npm trusted publishing is configured on a package that already exists, so publish the first version by hand (`npm publish --access public`), then add this repository's `publish.yml` as a trusted publisher in the package settings on npmjs.com.

## License

MIT
