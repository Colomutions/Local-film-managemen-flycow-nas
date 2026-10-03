import { randomBytes } from 'node:crypto';
import { mkdir, rename, writeFile, rm } from 'node:fs/promises';
import path from 'node:path';

export class TaskError extends Error {
  constructor(code, message, extra = {}) { super(message); this.code = code; Object.assign(this, extra); }
}
export const sleep = (ms, signal) => new Promise((resolve, reject) => {
  if (signal?.aborted) return reject(new TaskError('cancelled', '任务已暂停'));
  const abort = () => { clearTimeout(timer); reject(new TaskError('cancelled', '任务已暂停')); };
  const timer = setTimeout(() => { signal?.removeEventListener('abort', abort); resolve(); }, ms);
  signal?.addEventListener('abort', abort, { once: true });
});
export const contained = (root, candidate) => { const rel = path.relative(root, candidate); return rel === '' || (!rel.startsWith('..' + path.sep) && rel !== '..' && !path.isAbsolute(rel)); };
export async function atomicWrite(file, content) {
  await mkdir(path.dirname(file), { recursive: true });
  const temporary = `${file}.${randomBytes(5).toString('hex')}.tmp`;
  try { await writeFile(temporary, content); await rename(temporary, file); }
  finally { await rm(temporary, { force: true }).catch(() => {}); }
}
export function retryAfter(value, now = Date.now()) {
  if (!value) return null;
  const seconds = Number(value);
  const date = Number.isFinite(seconds) ? now + Math.max(0, seconds) * 1000 : Date.parse(value);
  return Number.isFinite(date) ? date : null;
}
export function log(event, fields = {}) { console.log(JSON.stringify({ time: new Date().toISOString(), event, ...fields })); }
