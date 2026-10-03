import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { ScrapeEngine } from '../engine.mjs';
import { TaskError } from '../src/util.mjs';
import { relationshipRecords } from '../src/relationships.mjs';

const bytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=', 'base64');
async function harness(t, overrides = {}) {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'mujing-scraper-'));
  t.after(() => rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 }));
  const calls = [];
  const browser = {
    async lookup(site, code) { calls.push(['search', code]); return { candidates: [`https://whatsav.net/zh/video/1`] }; },
    async page(site, url, kind, expected) {
      calls.push([kind, url]);
      if (kind === 'detail') return { metadata: { code: expected, title: '影片资料', source: { name: 'whatsav', url }, actors: [{ name: '同一演员', url: 'https://whatsav.net/zh/actor/7' }], organizations: [{ name: '制作商', role: 'maker', url: 'https://whatsav.net/zh/maker/3' }], artwork: { poster: 'https://pics.dmm.co.jp/poster.jpg', cover: 'https://pics.dmm.co.jp/poster.jpg', gallery: [] } } };
      if (kind === 'actor-list') return { ready: true, sorted: true, items: [{ name: '演员', url: 'https://whatsav.net/zh/actor/7' }], nextUrl: null };
      if (kind === 'actor-detail') return { profile: { name: '演员', source: { name: 'whatsav', id: expected, url }, avatarUrl: null }, works: [{ sourceId: '1', code: 'ABC-001' }], nextUrl: `${url}?page=2` };
      if (kind === 'company') return { profile: { name: '制作商', source: { name: 'whatsav', url }, logoUrl: null, foundedDate: null } };
    },
    async close() {}, ...overrides,
  };
  let downloads = 0;
  const engine = new ScrapeEngine(dir, { browser, download: async () => { downloads++; return { bytes, extension: 'png', sha256: createHash('sha256').update(bytes).digest('hex') }; } });
  await engine.init();
  // 离线测试只跳过真实等待，网络与时间持久化另有独立断言。
  engine.pace = async () => {};
  return { engine, dir, calls, downloads: () => downloads };
}

test('影片缓存复用、同图复用、强制更新以及多影片演员身份稳定', async t => {
  const h = await harness(t);
  const a = await h.engine.execute({ type: 'movie', code: 'ABC-001' });
  assert.equal(h.downloads(), 1);
  assert.equal(a.assets.poster.file, a.assets.cover.file);
  await h.engine.execute({ type: 'movie', code: 'ABC-001' });
  assert.equal(h.calls.filter(c => c[0] === 'search').length, 1);
  await h.engine.execute({ type: 'movie', code: 'ABC-001', refresh: true, generation: 'force-1' });
  await h.engine.execute({ type: 'movie', code: 'ABC-001', refresh: true, generation: 'force-1' });
  assert.equal(h.calls.filter(c => c[0] === 'search').length, 2);
  const b = await h.engine.execute({ type: 'movie', code: 'ABC-002', movieImages: false });
  assert.equal(a.entities[0].id, b.entities[0].id);
  assert.deepEqual(b.assets, {});
  assert.equal(a.entities[1].role, 'maker');
});

test('演员一次请求只读取一页，排名拒绝非作品数量排序', async t => {
  const h = await harness(t);
  const profile = await h.engine.execute({ type: 'actor', url: 'https://whatsav.net/zh/actor/7' });
  assert.equal(h.calls.length, 1);
  assert.match(profile.nextUrl, /page=2/);
  await assert.rejects(h.engine.execute({ type: 'ranking', url: 'https://whatsav.net/zh/actors?sort=name' }), /作品数/);
  const ranked = await h.engine.execute({ type: 'ranking', url: 'https://whatsav.net/zh/actors?sort=video_count_desc' });
  assert.equal(ranked.items.length, 1);
});

test('限流持久化，恢复来源不会取消服务器冷却', async t => {
  const until = Date.now() + 60000;
  const h = await harness(t, { async lookup() { throw new TaskError('limited', '冷却', { until }); } });
  await assert.rejects(h.engine.execute({ type: 'movie', code: 'ABC-001' }), /冷却/);
  const state = JSON.parse(await readFile(path.join(h.dir, 'pacing.json'), 'utf8'));
  assert.equal(state.until, until);
  await h.engine.execute({ type: 'resumeSource' });
  assert.equal(h.engine.state.until, until);
});

test('缺失图片可重试且不重复搜索，未知厂商字段保持空白', async t => {
  const h = await harness(t);
  const download = h.engine.download;
  h.engine.download = async () => { throw new TaskError('image', '图片暂不可用'); };
  const partial = await h.engine.execute({ type: 'movie', code: 'ABC-001' });
  assert.equal(partial.warnings.length, 2);
  h.engine.download = download;
  const complete = await h.engine.execute({ type: 'movie', code: 'ABC-001' });
  assert.deepEqual(complete.warnings, []);
  assert.equal(h.calls.filter(c => c[0] === 'search').length, 1);
  const company = await h.engine.execute({ type: 'company', url: 'https://whatsav.net/zh/maker/3' });
  assert.equal(company.profile.foundedDate, null);
});

test('域名跳转不改变实体身份，制作商与同名厂牌分开', () => {
  const make = host => relationshipRecords({ code: 'ABC-001', source: { name: 'whatsav' }, organizations: [
    { name: '同名', role: 'maker', url: `https://${host}/zh/maker/1` },
    { name: '同名', role: 'label', url: `https://${host}/zh/label/1` },
  ] });
  const a = make('whatsav.net'), b = make('whatsavh.cc');
  assert.notEqual(a[0].id, a[1].id);
  assert.deepEqual(a.map(e => e.id), b.map(e => e.id));
});

test('补关联只下载截图，读取演员异名不下载头像', async t => {
  const h = await harness(t, { async page(site, url, kind, code) {
    if (kind === 'actor-detail') return { profile: { name: '新艺名', aliases: ['旧艺名'], avatarUrl: 'https://pics.dmm.co.jp/avatar.jpg', source: { url } } };
    return { metadata: { code, source: { name: 'whatsav', url }, actors: [], organizations: [],
      artwork: { poster: 'https://pics.dmm.co.jp/poster.jpg', cover: 'https://pics.dmm.co.jp/cover.jpg', gallery: ['https://pics.dmm.co.jp/shot.jpg'] } } };
  } });
  const movie = await h.engine.execute({ type: 'movie', code: 'ABC-001', movieImages: true, galleryOnly: true, galleryLimit: 20 });
  assert.deepEqual(Object.keys(movie.assets), ['gallery-1']);
  assert.equal(h.downloads(), 1);
  const actor = await h.engine.execute({ type: 'actor', url: 'https://whatsav.net/zh/actor/7', identityOnly: true });
  assert.deepEqual(actor.profile.aliases, ['旧艺名']);
  assert.equal(h.downloads(), 1);
});
