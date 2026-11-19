#!/usr/bin/env node
// Checks that PicoRubyLibs::BUILTINS in loader.rb lists exactly the
// libraries compiled into PicoRuby.wasm.
//
//   node scripts/check-builtins.mjs                 # @picoruby/wasm-wasi@latest
//   node scripts/check-builtins.mjs --version 4.0.5 # or a dist-tag such as head
//
// PicoRuby keeps the require names of its compiled-in gems in a C array,
// `prebuilt_gems`, and `Kernel#extern(name)` returns false for exactly those
// names (nil for anything else). The array is not reachable from Ruby, so the
// script collects every string in picoruby.wasm that could be a require name,
// runs PicoRuby.wasm in headless Chromium and asks `extern` about each one.
//
// Exits 1 when the lists differ, printing the names to add and remove.

import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { chromium } from 'playwright';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const PACKAGE = '@picoruby/wasm-wasi';
const ORIGIN = 'http://picoruby-libs.test';
const TIMEOUT_MS = 60_000;

const { values: args } = parseArgs({
  options: { version: { type: 'string', default: 'latest' } },
});

// "latest" / "head" / "4.0.5" -> "4.0.5". A pinned version keeps jsDelivr's
// cache of a dist-tag out of the way.
async function resolveVersion(spec) {
  const res = await fetch(`https://registry.npmjs.org/${PACKAGE}/${encodeURIComponent(spec)}`);
  if (!res.ok) throw new Error(`${PACKAGE}@${spec} not found on npm (${res.status})`);
  return (await res.json()).version;
}

// Every NUL-terminated ASCII string in the binary, and each of its suffixes
// (the linker merges a string literal into the tail of a longer one), that
// looks like a require name.
function candidateNames(wasm) {
  const names = new Set();
  let start = -1;
  for (let i = 0; i < wasm.length; i++) {
    const byte = wasm[i];
    if (byte >= 0x20 && byte < 0x7f) {
      if (start < 0) start = i;
      continue;
    }
    if (byte === 0 && start >= 0) {
      const text = wasm.toString('latin1', start, i);
      for (let j = 0; j < text.length; j++) {
        const name = text.slice(j);
        if (/^[a-z][a-z0-9_\-\/]{0,63}$/.test(name)) names.add(name);
      }
    }
    start = -1;
  }
  return [...names].sort();
}

// The names among `candidates` that PicoRuby.wasm reports as built in.
async function probeBuiltins(dist, candidates) {
  // The names go through JS: a literal of thousands of words is too big for
  // PicoRuby's compiler.
  const ruby = `
    require 'js'
    if respond_to?(:extern, true)
      found = []
      JS.global[:__picoruby_libs_candidates].to_s.split(' ').each do |name|
        found << name if extern(name) == false
      end
      puts "PICORUBY_LIBS_BUILTINS=" + found.join(' ')
    else
      puts "PICORUBY_LIBS_ERROR=Kernel#extern is missing; PicoRuby's require changed"
    end
  `;
  const html = `<!DOCTYPE html>
<script type="text/ruby">${ruby}</script>
<script src="${dist}init.iife.js"></script>`;

  const browser = await chromium.launch();
  let timer;
  try {
    const page = await browser.newPage();
    await page.addInitScript((names) => { window.__picoruby_libs_candidates = names; }, candidates.join(' '));
    const result = new Promise((resolve, reject) => {
      page.on('console', (msg) => {
        const text = msg.text();
        if (text.startsWith('PICORUBY_LIBS_BUILTINS=')) {
          resolve(text.slice('PICORUBY_LIBS_BUILTINS='.length).split(' ').filter(Boolean));
        } else if (text.startsWith('PICORUBY_LIBS_ERROR=')) {
          reject(new Error(text.slice('PICORUBY_LIBS_ERROR='.length)));
        } else if (msg.type() === 'error') {
          reject(new Error(`PicoRuby.wasm: ${text}`));
        }
      });
      page.on('pageerror', (err) => reject(err));
      timer = setTimeout(() => reject(new Error(`PicoRuby.wasm did not answer in ${TIMEOUT_MS / 1000}s`)), TIMEOUT_MS);
    });
    await page.route(`${ORIGIN}/`, (route) => route.fulfill({ contentType: 'text/html', body: html }));
    await page.goto(`${ORIGIN}/`);
    return await result;
  } finally {
    clearTimeout(timer);
    await browser.close();
  }
}

function loaderBuiltins() {
  const out = execFileSync('ruby', [
    '-e',
    'PICORUBY_LIBS_NO_BOOT = true; require_relative ARGV[0]; puts PicoRubyLibs::BUILTINS',
    join(ROOT, 'loader.rb'),
  ], { encoding: 'utf8' });
  return out.split('\n').filter(Boolean);
}

const version = await resolveVersion(args.version);
const dist = `https://cdn.jsdelivr.net/npm/${PACKAGE}@${version}/dist/`;
console.log(`Checking BUILTINS against ${PACKAGE}@${version}`);

const res = await fetch(`${dist}picoruby.wasm`);
if (!res.ok) throw new Error(`failed to fetch ${dist}picoruby.wasm (${res.status})`);
const candidates = candidateNames(Buffer.from(await res.arrayBuffer()));
const actual = await probeBuiltins(dist, candidates);
if (!actual.includes('js')) {
  throw new Error(`the probe found no "js" among ${actual.length} built-ins; it is broken, not the list`);
}

const listed = loaderBuiltins();
const missing = actual.filter((name) => !listed.includes(name)).sort();
const extra = listed.filter((name) => !actual.includes(name)).sort();

console.log(`PicoRuby.wasm ${version} has ${actual.length} built-in libraries: ${[...actual].sort().join(' ')}`);
if (missing.length === 0 && extra.length === 0) {
  console.log('BUILTINS matches.');
  process.exit(0);
}

const annotate = process.env.GITHUB_ACTIONS === 'true';
if (missing.length > 0) {
  const message = `Built into PicoRuby.wasm ${version} but missing from BUILTINS (each require of these asks npm): ${missing.join(' ')}`;
  console.log(annotate ? `::error file=loader.rb::${message}` : message);
}
if (extra.length > 0) {
  const message = `In BUILTINS but not built into PicoRuby.wasm ${version} (a library of that name on npm is never loaded): ${extra.join(' ')}`;
  console.log(annotate ? `::error file=loader.rb::${message}` : message);
}
process.exit(1);
