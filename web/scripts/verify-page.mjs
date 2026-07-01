import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const distDir = fileURLToPath(new URL('../dist', import.meta.url));

// Walk dist/ for every built .html page.
function htmlFiles(dir) {
  const out = [];
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) out.push(...htmlFiles(p));
    else if (ent.name.endsWith('.html')) out.push(p);
  }
  return out;
}

// SITE-WIDE forbidden strings — accuracy/legal landmines that are wrong on ANY
// page. Blanket "everything is local" claims (audio never leaves, but cleanup
// TEXT can go to the cloud provider you bring); Concord-as-wordmark; and the
// voiceprint "never a recording" overclaim (the shipped build has an optional,
// consent-gated enrollment-audio store — see the disclose-the-store copy).
const FORBIDDEN = [
  'Nothing leaves your Mac', 'Nothing leaves your device', '100% on-device',
  'On-device Concord', 'Everything runs on your Mac',
  'never a recording',
];

// Homepage-only required strings (CTA hooks, semantic h1, JSON-LD, the two
// load-bearing accuracy lines).
const REQUIRED_HOME = [
  'Your voice never leaves your Mac',          // audio privacy line
  'built on Concord',                          // attribution credit
  'application/ld+json',                       // JSON-LD preserved
  'data-goatcounter-click="download-hero"',    // hero CTA hook
  'data-goatcounter-click="download-get-parleq"', // final CTA hook
  '<h1',                                        // semantic headline present
];

let fail = 0;
const pages = htmlFiles(distDir);

// Forbidden strings: checked on EVERY page.
for (const file of pages) {
  const html = readFileSync(file, 'utf8');
  const rel = file.slice(distDir.length + 1);
  for (const s of FORBIDDEN) {
    if (html.includes(s)) { console.error(`FORBIDDEN present in ${rel}: "${s}"`); fail++; }
  }
  // Decorative flow/cluster SVGs must be aria-hidden, wherever they appear.
  const decorative = [...html.matchAll(/<svg[^>]*class="[^"]*(?:concord-flow|grape-cluster)[^"]*"[^>]*>/g)];
  for (const m of decorative) {
    if (!/aria-hidden="true"/.test(m[0])) { console.error(`Decorative SVG missing aria-hidden in ${rel}: ${m[0].slice(0,80)}`); fail++; }
  }
}

// Required strings: homepage only.
const home = readFileSync(join(distDir, 'index.html'), 'utf8');
for (const s of REQUIRED_HOME) {
  if (!home.includes(s)) { console.error(`REQUIRED missing on homepage: "${s}"`); fail++; }
}

console.log(fail ? `\n${fail} violation(s)` : `verify-page: OK (${pages.length} pages scanned)`);
process.exit(fail ? 1 : 0);
