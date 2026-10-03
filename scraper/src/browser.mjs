import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { parsePage } from './page-parser.mjs';
import { parseActorPage } from './actor-parser.mjs';
import { parseCompanyPage } from './company-parser.mjs';
import { TaskError, sleep, retryAfter } from './util.mjs';

export class Browser {
  constructor(config) { this.config = config; this.sequence = 0; this.pending = new Map(); this.handlers = new Set(); this.buffer = Buffer.alloc(0); this.closed = false; }
  async start() {
    if (this.child && !this.failure) return;
    if (!this.config.browserExecutable) throw new TaskError('browser', '找不到 Chromium，请设置 BROWSER_EXECUTABLE');
    await mkdir(path.join(this.config.dataDir, 'browser-profile'), { recursive: true });
    this.failure = null; this.closed = false; this.stderr = ''; this.buffer = Buffer.alloc(0);
    this.child = spawn(this.config.browserExecutable, [
      ...(this.config.headed ? [] : ['--headless=new']), ...(this.config.noSandbox ? ['--no-sandbox'] : []),
      '--remote-debugging-pipe', `--user-data-dir=${path.join(this.config.dataDir, 'browser-profile')}`,
      '--no-first-run', '--no-default-browser-check', '--disable-background-networking', 'about:blank',
    ], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: !this.config.headed });
    const fail = error => { this.failure = error; for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(error); } this.pending.clear(); };
    this.child.on('error', error => fail(new TaskError('browser', error.message)));
    this.child.on('exit', code => fail(new TaskError('browser', `浏览器退出 ${code}: ${this.stderr.slice(-2000)}`)));
    this.child.stderr.on('data', bytes => { this.stderr = (this.stderr + bytes.toString()).slice(-6000); });
    this.child.stdio[3].on('error', fail);
    this.child.stdio[4].on('data', bytes => {
      this.buffer = Buffer.concat([this.buffer, bytes]);
      let end;
      while ((end = this.buffer.indexOf(0)) >= 0) {
        const raw = this.buffer.subarray(0, end).toString(); this.buffer = this.buffer.subarray(end + 1);
        if (!raw) continue;
        let message; try { message = JSON.parse(raw); } catch { continue; }
        if (message.id) {
          const p = this.pending.get(message.id); if (!p) continue;
          this.pending.delete(message.id); clearTimeout(p.timer);
          message.error ? p.reject(new TaskError('browser', message.error.message)) : p.resolve(message.result);
        } else for (const fn of this.handlers) fn(message);
      }
    });
    this.version = await this.send('Browser.getVersion');
    const { targetId } = await this.send('Target.createTarget', { url: 'about:blank' }); this.targetId = targetId;
    const { sessionId } = await this.send('Target.attachToTarget', { targetId, flatten: true }); this.sessionId = sessionId;
    await this.send('Page.enable', {}, sessionId);
    await this.send('Network.enable', {}, sessionId);
    // Metadata lives in the document. Covers are downloaded separately with a
    // delay; do not let all preview images, fonts and videos download at once.
    await this.send('Fetch.enable', { patterns: ['Image', 'Media', 'Font'].map(resourceType => ({ resourceType, requestStage: 'Request' })) }, sessionId);
    this.fetchHandler = event => {
      if (event.sessionId === this.sessionId && event.method === 'Fetch.requestPaused') this.send('Fetch.failRequest', { requestId: event.params.requestId, errorReason: 'Aborted' }, this.sessionId).catch(() => {});
    };
    this.handlers.add(this.fetchHandler);
  }
  send(method, params = {}, sessionId) {
    if (this.failure) return Promise.reject(this.failure);
    return new Promise((resolve, reject) => {
      const id = ++this.sequence;
      const timer = setTimeout(() => { this.pending.delete(id); reject(new TaskError('browser', `浏览器操作超时: ${method}`)); }, 45000);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + '\0');
    });
  }
  async evaluate(expression) {
    const result = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, this.sessionId);
    if (result.exceptionDetails) throw new TaskError('parse', '页面解析执行失败');
    return result.result.value;
  }
  allowedHosts(site) { return site === 'whatsav' ? ['whatsav.net', 'whatsavh.cc', ...this.config.extraWhatsavHosts] : ['cn.javd.me', 'javd.me']; }
  assertUrl(site, url) {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' || parsed.port || parsed.username || parsed.password || !this.allowedHosts(site).includes(parsed.hostname)) throw new TaskError('redirect', `出现未配置的跳转域名：${parsed.hostname}`);
  }
  async page(site, url, kind, expected, signal) {
    await this.start(); this.assertUrl(site, url);
    let latestResponse = null, badRedirect = null;
    const { frameTree } = await this.send('Page.getFrameTree', {}, this.sessionId);
    const frameId = frameTree.frame.id;
    const listener = event => {
      if (event.sessionId !== this.sessionId) return;
      if (event.method === 'Network.responseReceived' && event.params.type === 'Document' && event.params.frameId === frameId) latestResponse = event.params.response;
      if (event.method === 'Page.frameNavigated' && !event.params.frame.parentId) {
        try { this.assertUrl(site, event.params.frame.url); }
        catch (error) { badRedirect = error; this.send('Page.stopLoading', {}, this.sessionId).catch(() => {}); }
      }
    };
    this.handlers.add(listener);
    const stop = () => this.send('Page.stopLoading', {}, this.sessionId).catch(() => {});
    signal?.addEventListener('abort', stop, { once: true });
    try {
      if (signal?.aborted) throw new TaskError('cancelled', '任务已暂停');
      const nav = await this.send('Page.navigate', { url }, this.sessionId);
      if (nav.errorText) throw new TaskError('network', `页面连接失败: ${nav.errorText}`);
      const started = Date.now(); let parsed, currentUrl;
      do {
        await sleep(2000, signal);
        if (badRedirect) throw badRedirect;
        currentUrl = await this.evaluate('location.href');
        this.assertUrl(site, currentUrl);
        const parser=kind==='company'?parseCompanyPage:kind.startsWith('actor')?parseActorPage:parsePage;
        parsed = await this.evaluate(`(${parser.toString()})(${JSON.stringify({ site, kind, expected, baseUrl: currentUrl })})`);
        if (parsed.ready && !parsed.blocked && !parsed.routing && Date.now() - started >= 5000) break;
      } while (Date.now() - started < this.config.pageWaitSeconds * 1000);
      const status = latestResponse?.status || 0;
      const after = Object.entries(latestResponse?.headers || {}).find(([k]) => k.toLowerCase() === 'retry-after')?.[1];
      if (status === 429) throw new TaskError('limited', '网站限流，任务已等待冷却', { until: retryAfter(after) || Date.now() + 3600000 });
      if (status === 403 || parsed?.blocked) throw new TaskError('blocked', '网站要求验证，已暂停该来源');
      if (status === 404) throw new TaskError('not_found', '网站没有该页面');
      if (status >= 500 || status === 0) throw new TaskError('network', `网站响应异常：${status}`);
      if (parsed?.routing) throw new TaskError('redirect', '网站跳转未完成，需重新验证访问方式');
      if (!parsed?.ready) throw new TaskError('parse', '页面未出现预期资料结构，已记录待检查');
      if (parsed.mismatch) throw new TaskError('review', `详情番号不匹配：${(parsed.foundCodes || []).join(', ')}`);
      if (parsed.paginationError) throw new TaskError('parse', '分页结构或当前页码异常，已停止继续翻页');
      if(kind.startsWith('actor')&&Number(new URL(url).searchParams.get('page')||1)!==parsed.currentPage)throw new TaskError('parse','演员页面跳转丢失页码，已停止翻页');
      if (parsed.metadata) {
        parsed.metadata.source.url = currentUrl;
        parsed.metadata.source.fetchedAt = new Date().toISOString();
      }
      return parsed;
    } finally {
      signal?.removeEventListener('abort', stop); this.handlers.delete(listener);
      await this.send('Page.navigate', { url: 'about:blank' }, this.sessionId).catch(() => {});
    }
  }
  async lookup(site, code, signal) {
    const query = code.startsWith('FC2-PPV-') && site === 'javd' ? code.replace('FC2-PPV-', 'FC2-') : code;
    const url = site === 'whatsav' ? `https://whatsav.net/zh/search?q=${encodeURIComponent(query)}` : `https://cn.javd.me/search?q=${encodeURIComponent(query)}`;
    return this.page(site, url, 'search', code, signal);
  }
  async close() {
    this.handlers.delete(this.fetchHandler);
    if (!this.child?.pid || this.child.exitCode !== null || this.child.signalCode !== null) return;
    const timer = setTimeout(() => this.child.kill(), 5000); timer.unref();
    try { await this.send('Browser.close'); } catch {}
    if (this.child.exitCode === null && this.child.signalCode === null) await new Promise(resolve => this.child.once('exit', resolve));
    clearTimeout(timer); this.closed = true;
  }
}
