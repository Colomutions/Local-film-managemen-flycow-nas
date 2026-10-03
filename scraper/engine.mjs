import path from 'node:path';
import { readFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { Browser } from './src/browser.mjs';
import { downloadImage, existingAsset } from './src/output.mjs';
import { atomicWrite, TaskError, sleep } from './src/util.mjs';
import { requireCode } from './src/catalog.mjs';
import { relationshipRecords } from './src/relationships.mjs';

export class ScrapeEngine {
  constructor(dataDir, { browser, download = downloadImage } = {}) {
    this.config = {
      dataDir, browserExecutable: process.env.BROWSER_EXECUTABLE || '/usr/bin/chromium',
      noSandbox: process.env.APP_CHROMIUM_NO_SANDBOX === '1', headed: false,
      pageWaitSeconds: 20, extraWhatsavHosts: [],
      imageHosts: ['awsimgsrc.dmm.co.jp', 'pics.dmm.co.jp', 'image.mgstage.com', 'image-optimizer.osusume.dmm.co.jp'],
    };
    this.browser = browser || new Browser(this.config);
    this.download = download;
    this.state = { nextAt: 0, until: 0, blocked: null };
  }
  async init() {
    await mkdir(this.config.dataDir, { recursive: true });
    try { this.state = JSON.parse(await readFile(path.join(this.config.dataDir, 'pacing.json'), 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  async saveState() { await atomicWrite(path.join(this.config.dataDir, 'pacing.json'), JSON.stringify(this.state)); }
  async pace(signal) {
    if (this.state.blocked) throw new TaskError('blocked', this.state.blocked);
    const until = Math.max(this.state.nextAt || 0, this.state.until || 0);
    if (this.state.until > Date.now()) throw new TaskError('limited', 'WhatsAV 正在冷却', { until: this.state.until });
    await sleep(Math.max(0, until - Date.now()), signal);
    this.state.nextAt = Date.now() + (this.min + Math.random() * (this.max - this.min)) * 1000;
    await this.saveState();
  }
  async page(url, kind, expected, signal) {
    await this.pace(signal);
    return this.browser.page('whatsav', url, kind, expected, signal);
  }
  async asset(url, referer, signal) {
    if (!url) return null;
    const key = createHash('sha256').update(url).digest('hex');
    const manifest = path.join(this.config.dataDir, 'assets', `${key}.json`);
    try {
      const previous = JSON.parse(await readFile(manifest, 'utf8'));
      if (await existingAsset(path.join(this.config.dataDir, 'assets'), previous)) return { ...previous, file: `assets/${previous.file}` };
    } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    const image = await this.download(url, { config: this.config, limiter: s => this.pace(s), signal, referer, userAgent: this.browser.version?.userAgent });
    if (image.bytes.length > 10 * 1024 * 1024) throw new TaskError('image', '图片超过幕境 10 MiB 限制');
    const file = `${image.sha256}.${image.extension}`;
    const result = { file, sha256: image.sha256, sourceUrl: url, mimeType: { jpg: 'image/jpeg', png: 'image/png', webp: 'image/webp' }[image.extension] };
    await atomicWrite(path.join(this.config.dataDir, 'assets', file), image.bytes);
    await atomicWrite(manifest, JSON.stringify(result));
    return { ...result, file: `assets/${file}` };
  }
  async execute(input, signal) {
    if (input.type === 'resumeSource') { this.state.blocked = null; await this.saveState(); return { until: this.state.until }; }
    this.min = input.minIntervalSeconds ?? 15; this.max = input.maxIntervalSeconds ?? 25;
    if (![this.min, this.max].every(n => Number.isFinite(n) && n >= 1 && n <= 3600) || this.max < this.min) throw new TaskError('invalid', '请求间隔须为 1～3600 秒');
    const gallery = input.galleryLimit ?? 0;
    if (!Number.isInteger(gallery) || gallery < 0 || gallery > 20) throw new TaskError('invalid', '预览图数量须为 0～20');
    const identity = [input.type, input.code || input.url];
    const key = createHash('sha256').update(JSON.stringify(identity)).digest('hex');
    const cache = path.join(this.config.dataDir, 'results', `${key}.json`);
    let result;
    try { result = JSON.parse(await readFile(cache, 'utf8')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    try {
      if (!result || (input.refresh && result.generation !== input.generation)) {
        if (input.type === 'movie') {
          const code = requireCode(input.code);
          await this.pace(signal);
          const search = await this.browser.lookup('whatsav', code, signal);
          if (!search.candidates?.length) throw new TaskError('not_found', 'WhatsAV 未找到该番号');
          if (search.candidates.length !== 1) throw new TaskError('review', '多个来源影片匹配该番号，需要核对');
          const detail = await this.page(search.candidates[0], 'detail', code, signal);
          if (detail.metadata?.code !== code) throw new TaskError('review', '来源影片番号不一致');
          result = { metadata: detail.metadata, entities: relationshipRecords(detail.metadata) };
        } else if (input.type === 'ranking') {
          const url = new URL(input.url);
          if (url.pathname !== '/zh/actors' || url.searchParams.get('sort') !== 'video_count_desc') throw new TaskError('invalid', '演员排名必须按网站作品数排序');
          result = await this.page(input.url, 'actor-list', null, signal);
          if (!result.sorted || !result.items?.length) throw new TaskError('parse', '网站没有返回作品数排名');
        } else if (input.type === 'actor') {
          const id = new URL(input.url).pathname.match(/^\/zh\/actor\/([a-zA-Z0-9]+)$/)?.[1];
          if (!id) throw new TaskError('invalid', '演员来源链接无效');
          result = await this.page(input.url, 'actor-detail', id, signal);
        } else if (input.type === 'company') {
          const match = new URL(input.url).pathname.match(/^\/zh\/(maker|label|distributor)\/([a-zA-Z0-9_-]+)$/);
          if (!match) throw new TaskError('invalid', '厂商来源链接无效');
          result = await this.page(input.url, 'company', `${match[1]}:${match[2]}`, signal);
        } else throw new TaskError('invalid', '不支持的采集任务');
        result = { ...result, fetchedAt: new Date().toISOString(), generation: input.generation, assets: {} };
        await atomicWrite(cache, JSON.stringify(result));
      }
      const wanted = input.type === 'movie' && input.movieImages !== false
        ? [...(input.galleryOnly ? [] : [['poster', result.metadata.artwork.poster], ['cover', result.metadata.artwork.cover]]), ...(result.metadata.artwork.gallery || []).slice(0, gallery).map((url, i) => [`gallery-${i + 1}`, url])]
        : input.type === 'actor' && !input.identityOnly ? [['avatar', result.profile.avatarUrl]]
        : input.type === 'company' ? [['logo', result.profile.logoUrl]] : [];
      result.warnings = [];
      for (const [kind, url] of wanted) {
        if (!url) continue;
        try { result.assets[kind] = await this.asset(url, result.metadata?.source.url || result.profile?.source.url, signal); }
        catch (error) {
          if (signal?.aborted || ['limited', 'blocked', 'redirect'].includes(error.code) || error.until) throw error;
          result.warnings.push(`${kind}: ${error.message}`);
        }
        await atomicWrite(cache, JSON.stringify(result));
      }
      return result;
    } catch (error) {
      if (error.code === 'limited' || error.until) this.state.until = Math.max(this.state.until || 0, error.until || Date.now() + 3600000);
      else if (['blocked', 'redirect', 'parse'].includes(error.code)) this.state.blocked = error.message;
      await this.saveState();
      if (error.code === 'browser') { await this.browser.close(); this.browser = new Browser(this.config); }
      throw error;
    }
  }
  async close() { await this.browser.close(); }
}
