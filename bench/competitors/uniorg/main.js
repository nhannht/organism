// uniorg side of the bench protocol (see bench/README.md):
//   node main.js <file.org> <warmup> <min-time-seconds>
// prints one ns-per-iteration line per measured parse; the orchestrator does the stats.

import { readFileSync } from 'node:fs';
import { parse } from 'uniorg-parse/lib/parser.js';

const [file, warmupArg, minTimeArg] = process.argv.slice(2);
if (!file || !warmupArg || !minTimeArg) {
  console.error('usage: node main.js <file.org> <warmup> <min-time-seconds>');
  process.exit(1);
}
const src = readFileSync(file, 'utf8');
// A JIT needs more warmup than an AOT binary; the floor keeps the protocol's warmup
// parameter honest without letting V8's cold tiers pollute the samples.
const warmup = Math.max(parseInt(warmupArg, 10), 20);
const minTime = parseFloat(minTimeArg);

let sink = 0;
for (let i = 0; i < warmup; i++) sink += parse(src).children.length;

let t0 = process.hrtime.bigint();
sink += parse(src).children.length;
const est = Number(process.hrtime.bigint() - t0) / 1e9;
const iters = Math.min(20000, Math.max(5, Math.floor(minTime / Math.max(est, 1e-9))));

for (let i = 0; i < iters; i++) {
  const t = process.hrtime.bigint();
  const doc = parse(src);
  sink += doc.children.length;
  console.log(Number(process.hrtime.bigint() - t).toString());
}
console.error(`sink=${sink}`);
