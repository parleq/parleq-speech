import { readFileSync } from 'node:fs';
const html = readFileSync(new URL('../dist/index.html', import.meta.url), 'utf8');
const FORBIDDEN = [
  'Nothing leaves your Mac', 'Nothing leaves your device', '100% on-device',
  'On-device Concord', 'Everything runs on your Mac',
];
const REQUIRED = [
  'Your voice never leaves your Mac',          // audio privacy line
  'built on Concord',                          // attribution credit
  'application/ld+json',                       // JSON-LD preserved
  'data-goatcounter-click="download-hero"',    // hero CTA hook
  'data-goatcounter-click="download-get-parleq"', // final CTA hook
  '<h1',                                        // semantic headline present
];
let fail = 0;
for (const s of FORBIDDEN) if (html.includes(s)) { console.error(`FORBIDDEN present: "${s}"`); fail++; }
for (const s of REQUIRED) if (!html.includes(s)) { console.error(`REQUIRED missing: "${s}"`); fail++; }
// Decorative flow/cluster SVGs must be aria-hidden: every <svg class="...flow|cluster..."> carries aria-hidden.
const decorative = [...html.matchAll(/<svg[^>]*class="[^"]*(?:concord-flow|grape-cluster)[^"]*"[^>]*>/g)];
for (const m of decorative) if (!/aria-hidden="true"/.test(m[0])) { console.error(`Decorative SVG missing aria-hidden: ${m[0].slice(0,80)}`); fail++; }
console.log(fail ? `\n${fail} violation(s)` : 'verify-page: OK');
process.exit(fail ? 1 : 0);
