import readline from 'node:readline';
import path from 'node:path';
import { ScrapeEngine } from './engine.mjs';

const engine = new ScrapeEngine(path.resolve(process.argv[2] || './data/scraper'));
await engine.init();
const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
let active = null, closing = false;
const send = value => process.stdout.write(JSON.stringify(value) + '\n');
const close = async () => {
  if (closing) return; closing = true;
  active?.controller.abort();
  await active?.promise;
  await engine.close();
  lines.close();
};
lines.on('line', line => {
  let input;
  try { if (line.length > 65536) throw new Error(); input = JSON.parse(line); }
  catch { send({ id: null, error: { code: 'invalid', message: '无效的采集请求' } }); return; }
  if (input.type === 'cancel') { active?.controller.abort(); return; }
  if (input.type === 'close') { void close(); return; }
  if (closing || active) { send({ id: input.id, error: { code: 'busy', message: '采集器正在处理任务' } }); return; }
  const controller = new AbortController();
  const promise = engine.execute(input, controller.signal)
    .then(result => send({ id: input.id, result }))
    .catch(error => send({ id: input.id, error: { code: controller.signal.aborted ? 'cancelled' : error.code || 'network', message: /^[A-Z_]+$/.test(error.code || '') ? '采集器读写失败，请检查 NAS 数据目录权限和可用空间' : error.message, until: error.until } }))
    .finally(() => { active = null; });
  active = { controller, promise };
});
lines.on('close', () => { void close(); });
process.on('SIGTERM', () => { void close(); });
process.on('SIGINT', () => { void close(); });
send({ ready: true });
