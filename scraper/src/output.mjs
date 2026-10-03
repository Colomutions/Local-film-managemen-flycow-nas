import path from 'node:path';
import { readFile, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { TaskError, atomicWrite, retryAfter } from './util.mjs';
import { requireCode } from './catalog.mjs';

export function imageExtension(bytes) {
  if (bytes.length < 32) return null;
  if (bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return 'jpg';
  if (bytes.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) return 'png';
  if (bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP') return 'webp';
  return null;
}
export const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function privateAddress(address) {
  const a = address.toLowerCase();
  if (a.includes(':')) return a === '::' || a === '::1' || /^(fc|fd|fe[89ab])/.test(a) || a.startsWith('::ffff:');
  const p = a.split('.').map(Number);
  return p[0] === 0 || p[0] === 10 || p[0] === 127 || p[0] >= 224 || (p[0] === 169 && p[1] === 254) || (p[0] === 172 && p[1] >= 16 && p[1] <= 31) || (p[0] === 192 && p[1] === 168) || (p[0] === 100 && p[1] >= 64 && p[1] <= 127);
}
export async function downloadImage(url, { config, limiter, signal, referer, userAgent }) {
  let current = url;
  for (let redirect = 0; redirect <= 4; redirect++) {
    const u = new URL(current);
    if (u.protocol !== 'https:' || u.port || u.username || u.password || !config.imageHosts.includes(u.hostname)) throw new TaskError('image', `图片域名未配置：${u.hostname}`);
    const addresses = await lookup(u.hostname, { all: true });
    if (!addresses.length || addresses.some(a => privateAddress(a.address))) throw new TaskError('image', '图片地址解析到非公开网络');
    await limiter(signal);
    const response = await fetch(current, { redirect: 'manual', headers: { 'User-Agent': userAgent || 'NAS-Movie-Metadata/0.1', Referer: referer, Accept: 'image/webp,image/png,image/jpeg' }, signal: AbortSignal.any([AbortSignal.timeout(45000), ...(signal ? [signal] : [])]) });
    if ([301,302,303,307,308].includes(response.status)) {
      const location = response.headers.get('location'); await response.body?.cancel();
      if (!location) throw new TaskError('image', '图片跳转缺少目标地址');
      current = new URL(location, current).href; continue;
    }
    if (response.status === 429) { await response.body?.cancel(); throw new TaskError('image', '图片服务器限流', { until: retryAfter(response.headers.get('retry-after')) || Date.now() + 3600000 }); }
    if (!response.ok) { await response.body?.cancel(); throw new TaskError('image', `图片下载返回 HTTP ${response.status}`); }
    const maxBytes = 20 * 1024 * 1024;
    if (Number(response.headers.get('content-length')) > maxBytes) { await response.body?.cancel(); throw new TaskError('image', '图片超过 20 MiB'); }
    const chunks = []; let length = 0;
    for await (const chunk of response.body) { length += chunk.length; if (length > maxBytes) throw new TaskError('image', '图片超过 20 MiB'); chunks.push(chunk); }
    const bytes = Buffer.concat(chunks);
    const extension = imageExtension(bytes);
    if (!extension) throw new TaskError('image', '下载内容不是支持的 JPEG、PNG 或 WebP 图片');
    return { bytes, extension, sha256: hash(bytes) };
  }
  throw new TaskError('image', '图片跳转次数过多');
}

const xml = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' }[c]));
export function nfo(metadata) {
  const lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<movie>'];
  const add = (tag, value) => { if (value !== null && value !== undefined && value !== '') lines.push(`  <${tag}>${xml(value)}</${tag}>`); };
  add('title', metadata.title); add('originaltitle', metadata.originalTitle || metadata.sourceTitle);
  add('num', metadata.code); add('plot', metadata.summary); add('studio', metadata.studio); add('label', metadata.label); add('series', metadata.series); add('director', metadata.director);
  add('premiered', metadata.releaseDate); add('releasedate', metadata.releaseDate);
  if (metadata.runtimeSeconds) add('runtime', Math.round(metadata.runtimeSeconds / 60));
  add('website', metadata.source?.url); add('poster', metadata.assets?.poster?.file); add('fanart', metadata.assets?.cover?.file);
  for (const actor of metadata.actors || []) lines.push(`  <actor><name>${xml(actor.name)}</name><type>${xml(actor.gender || 'unknown')}</type></actor>`);
  for (const tag of metadata.tags || []) add('tag', tag);
  lines.push('</movie>'); return lines.join('\n') + '\n';
}
export const movieDirectory = (config, code) => path.join(config.dataDir, 'metadata', requireCode(code));
export async function persistMovie(config, metadata, files) {
  const dir = movieDirectory(config, metadata.code);
  await atomicWrite(path.join(dir, 'movie.json'), JSON.stringify(metadata, null, 2) + '\n');
  await atomicWrite(path.join(dir, `${metadata.code}.nfo`), nfo(metadata));
  await atomicWrite(path.join(dir, 'files.json'), JSON.stringify(files, null, 2) + '\n');
}
export async function existingAsset(dir, asset) {
  if (!asset || !/^[a-z0-9_-]+\.(jpg|png|webp)$/.test(asset.file || '')) return false;
  try { const info = await stat(path.join(dir, asset.file)); if (info.size > 20 * 1024 * 1024) return false; return hash(await readFile(path.join(dir, asset.file))) === asset.sha256; } catch { return false; }
}
