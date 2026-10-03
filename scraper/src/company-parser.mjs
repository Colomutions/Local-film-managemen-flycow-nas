// 在浏览器中执行，只提取厂商页面明确提供的档案字段。
export function parseCompanyPage({ expected, baseUrl, html = null }) {
  const doc = html === null ? document : new DOMParser().parseFromString(html, 'text/html');
  const text = node => String(node?.textContent || '').replace(/\s+/g, ' ').trim();
  const body = text(doc.body);
  if (/just a moment|verify you are human|正在进行安全验证|请验证您是真人/i.test(doc.title + body.slice(0, 1000)) || doc.querySelector('#challenge-running,#challenge-stage')) return { ready: false, blocked: true };
  if (doc.querySelector('meta[name="routing-data"]')) return { ready: false, routing: true };
  const url = new URL(baseUrl), identity = url.pathname.match(/^\/zh\/(maker|label|distributor)\/([a-zA-Z0-9_-]+)$/);
  if (!identity || `${identity[1]}:${identity[2]}` !== expected) return { ready: true, mismatch: true, foundCodes: [url.pathname] };
  const heading = doc.querySelector('main h1');
  if (!heading) return { ready: false };
  const section = heading.closest('section') || heading.parentElement;
  const data = [...doc.querySelectorAll('script[type="application/ld+json"]')].flatMap(el => {
    try { const item = JSON.parse(el.textContent); return Array.isArray(item) ? item : item['@graph'] || [item]; } catch { return []; }
  });
  const organization = data.find(item => ['Organization', 'Corporation'].includes(item['@type']) && item.url && new URL(item.url, baseUrl).pathname === url.pathname) || {};
  const fields = {};
  for (const dt of section.querySelectorAll('dt')) fields[text(dt).replace(/[：:]$/, '')] = text(dt.nextElementSibling);
  const optional = value => value && !/^(未知|暂无资料|暂无|N\/A|-)$/i.test(value) ? value : null;
  const absolute = value => { try { const result = new URL(value, baseUrl); return value && result.protocol === 'https:' ? result.href : null; } catch { return null; } };
  const logo = typeof organization.logo === 'string' ? organization.logo : organization.logo?.url;
  const name = text(heading);
  return { ready: !!name, profile: {
    name, originalName: optional(fields['原名']),
    summary: optional(fields['简介'] || organization.description || text(section.querySelector('[data-description]'))),
    countryRegion: optional(fields['国家/地区'] || fields['国家'] || fields['地区'] || organization.address?.addressCountry),
    foundedDate: optional(fields['成立日期'] || fields['成立时间'] || organization.foundingDate),
    logoUrl: absolute(logo || section.querySelector('img[data-entity-image]')?.getAttribute('src')),
    source: { name: 'whatsav', namespace: identity[1], id: identity[2], url: baseUrl }, rawFields: fields,
  } };
}
