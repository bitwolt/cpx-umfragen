import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');

assert.match(html, /secure_hash/i, 'wrapper must pass a CPX secure_hash');
assert.match(html, /urlParams\.get\(["']secure_hash["']\)/, 'wrapper must read the signed hash from the parent iframe URL');
assert.match(html, /[0-9a-f]\{32\}|\^\[0-9a-f\]\{32\}\$/i, 'wrapper must validate an MD5 hex token shape');
assert.doesNotMatch(html, /\|\|\s*["']guest["']/, 'wrapper must not silently fall back to a guest CPX identity');
assert.match(html, /general_config[\s\S]*secure_hash\s*:/i, 'wrapper must bind the hash into CPX general_config');

console.log('cpx secure wrapper v1 contract: PASS');
