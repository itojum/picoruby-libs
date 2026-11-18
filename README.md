# picoruby-libs

`require` PicoRuby libraries published on npm from [PicoRuby.wasm](https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-wasm) scripts in the browser. The loader itself is written in Ruby and runs on PicoRuby.wasm.

```html
<!-- Pin versions (e.g. picoruby-libs@0.1.0) for anything you publish -->
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
- Relative requires (`require './x'`) are left as they are. Bundle a program split into files into one script before loading it.

## Publishing a library

A library is an npm package that names its Ruby entry file in `package.json`:

```json
{
  "name": "mylib",
  "picoruby": "lib/mylib.rb"
}
```

`"picoruby": { "main": "lib/mylib.rb" }` works too. Without the field, a `"main"` that ends in `.rb` is used.

The entry file must be a single Ruby script. A library split into files can bundle itself at publish time, or require its other files as separate libraries.

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

Releases are made with [release-please](https://github.com/googleapis/release-please) from [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `feat!:` / `BREAKING CHANGE:` for breaking changes).

1. Merge PRs into `main` with **squash merge**, using a Conventional Commits PR title (it becomes the commit message and the changelog entry).
2. Every push to `main` runs the **Release** workflow, which opens or updates a release PR with the version bump and `CHANGELOG.md`.
3. Merge the release PR. The same workflow creates the tag and the GitHub Release, then runs the specs and publishes the package to npm with provenance.

To publish the version in `package.json` again without a new release (for example after a failed publish), run the **Release** workflow by hand from the Actions tab with **publish** checked.

The workflow uses only the default `GITHUB_TOKEN`; no personal access token is needed. Because of that, CI does not run on release PRs (GitHub does not start workflows for events made with `GITHUB_TOKEN`), but the publish job runs the specs before publishing.

Setup, once per repository:

- In **Settings → Actions → General → Workflow permissions**, check **Allow GitHub Actions to create and approve pull requests**, so release-please can open release PRs.
- npm trusted publishing is configured on a package that already exists, so publish the first version by hand (`npm publish --access public`), then add this repository's `release.yml` as a trusted publisher in the package settings on npmjs.com.

## License

MIT
