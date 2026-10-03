import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Browser } from '../src/browser.mjs';
import { parseCompanyPage } from '../src/company-parser.mjs';
import { parseActorPage } from '../src/actor-parser.mjs';
import { parsePage } from '../src/page-parser.mjs';

test('离线 Chromium DOM 验证：厂商身份、缺失字段、排名、影片关系', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'mujing-dom-'));
  const browser = new Browser({ dataDir: dir, browserExecutable: process.env.BROWSER_EXECUTABLE || (process.platform === 'win32' ? 'C:/Program Files/Google/Chrome/Application/chrome.exe' : '/usr/bin/chromium'), extraWhatsavHosts: [], noSandbox: process.platform !== 'win32' });
  try {
    await browser.start();
    await browser.send('Network.setBlockedURLs', { urls: ['*'] }, browser.sessionId);
    const parse = (fn, input) => browser.evaluate(`(${fn.toString()})(${JSON.stringify(input)})`);
    const companyHtml = `<main><section><h1>测试制作商</h1><dl><dt>国家/地区</dt><dd>日本</dd><dt>成立日期</dt><dd>2001-01-02</dd></dl><p data-description>来源简介</p></section></main><script type="application/ld+json">{"@type":"Organization","name":"WhatsAV","url":"https://whatsav.net","foundingDate":"1999","logo":"https://whatsav.net/site-logo.png"}</script>`;
    const company = await parse(parseCompanyPage, { expected: 'maker:123', baseUrl: 'https://whatsav.net/zh/maker/123', html: companyHtml });
    assert.equal(company.ready, true);
    assert.equal(company.profile.countryRegion, '日本');
    assert.equal(company.profile.foundedDate, '2001-01-02');
    assert.equal(company.profile.logoUrl, null);
    assert.equal(company.profile.summary, '来源简介');
    const sparse = await parse(parseCompanyPage, { expected: 'label:1', baseUrl: 'https://whatsavh.cc/zh/label/1', html: '<main><section><h1>厂牌</h1></section></main>' });
    assert.equal(sparse.profile.foundedDate, null);
    assert.equal(sparse.profile.source.namespace, 'label');
    const mismatch = await parse(parseCompanyPage, { expected: 'maker:wrong', baseUrl: 'https://whatsav.net/zh/maker/123', html: companyHtml });
    assert.equal(mismatch.mismatch, true);
    const blocked = await parse(parseCompanyPage, { expected: 'maker:123', baseUrl: 'https://whatsav.net/zh/maker/123', html: '<title>Just a moment</title><main>Verify you are human</main>' });
    assert.equal(blocked.blocked, true);
    const ranked = await parse(parseActorPage, { kind: 'actor-list', baseUrl: 'https://whatsav.net/zh/actors?sort=video_count_desc', html: `<main><select name="sort"><option selected value="video_count_desc">最多影片</option></select><a href="/zh/actor/1"><p>演员一</p><span>4.0k 部影片</span></a><a class="pagination-control" href="?sort=video_count_desc&page=2">下一页</a></main>` });
    assert.equal(ranked.sorted, true); assert.equal(ranked.items[0].videoCount, 4000); assert.match(ranked.nextUrl, /page=2/);
    const movie = await parse(parsePage, { site: 'whatsav', kind: 'detail', expected: 'ABC-001', baseUrl: 'https://whatsav.net/zh/video/1', html: `<h1>ABC-001 标题</h1><script type="application/ld+json">{"@type":"VideoObject","name":"ABC-001 原标题","publisher":{"name":"WhatsAV"},"uploadDate":"2026-10-03"}</script><dl><div><dt>制作商</dt><dd><a href="/zh/maker/1">同名</a></dd></div><div><dt>厂牌</dt><dd><a href="/zh/label/1">同名</a></dd></div></dl>` });
    assert.deepEqual(movie.metadata.organizations.map(o => o.role), ['maker', 'label']);
    assert.equal(movie.metadata.releaseDate, null); assert.equal(movie.metadata.uploadDate, '2026-10-03');
  } finally { await browser.close(); await rm(dir, { recursive: true, force: true }); }
});
