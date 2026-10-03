// Self-contained: executes inside Chromium, also against an inert DOMParser in tests.
export function parsePage({ site, kind, expected, baseUrl, html = null }) {
  const doc = html === null ? document : new DOMParser().parseFromString(html, 'text/html');
  const clean = value => String(value || '').replace(/\s+/g, ' ').trim();
  const text = node => clean(node?.textContent);
  const absolute = value => { if (!value) return null; try { const u = new URL(value, baseUrl); return /^https?:$/.test(u.protocol) ? u.href : null; } catch { return null; } };
  const codes = value => {
    let input = String(value || '').normalize('NFKC').toUpperCase();
    const results = [];
    const fc2 = /(?<![A-Z0-9])FC2[\s_-]*(?:PPV[\s_-]*)?(\d{5,10})(?!\d)/g;
    for (const m of input.matchAll(fc2)) results.push(`FC2-PPV-${m[1]}`);
    input = input.replace(fc2, ' ');
    for (const m of input.matchAll(/(?<![A-Z0-9])([A-Z]{2,12})[\s_-]?(\d{2,7})(?!\d)/g)) results.push(`${m[1]}-${m[2]}`);
    return [...new Set(results)];
  };
  const body = text(doc.body);
  const blocked = /just a moment|verify you are human|正在进行安全验证|请验证您是真人|确认您是真人|checking your browser/i.test(doc.title + ' ' + body.slice(0, 1000)) || !!doc.querySelector('#challenge-running,#challenge-stage');
  const routing = !!doc.querySelector('meta[name="routing-data"]') || /跳转提示/.test(doc.title);
  if (blocked || routing) return { blocked, routing, ready: false };
  const detailPath = site === 'whatsav' ? '/zh/video/' : '/movie/';
  if (kind === 'search') {
    const candidates = [...doc.querySelectorAll('a[href]')].map(a => ({ href: absolute(a.getAttribute('href')), codes: codes(text(a) + ' ' + a.getAttribute('href')) }))
      .filter(x => x.href && new URL(x.href).pathname.startsWith(detailPath) && x.codes.includes(expected));
    const byPath = new Map();
    for (const c of candidates) { const u = new URL(c.href); byPath.set(u.pathname, u.origin + u.pathname); }
    return { ready: body.length > 100 && !!doc.querySelector(site === 'whatsav' ? 'input[name="q"]' : '#searchKeyword'), candidates: [...byPath.values()], blocked: false, routing: false };
  }
  const structured = [...doc.querySelectorAll('script[type="application/ld+json"]')].flatMap(el => {
    try { const obj = JSON.parse(el.textContent); return Array.isArray(obj) ? obj : obj['@graph'] || [obj]; } catch { return []; }
  });
  const ld = structured.find(x => ['Movie', 'VideoObject'].includes(x['@type']));
  const heading = text(doc.querySelector(site === 'javd' ? '.section.movie h1' : 'h1'));
  if (!ld || !heading) return { ready: false, blocked: false, routing: false };
  const foundCodes = codes(heading);
  if (!foundCodes.includes(expected)) return { ready: true, mismatch: true, foundCodes };
  const empty = value => /^(暂无资料|暂无|未知|N\/A|-)$/i.test(value) ? null : value || null;
  const fields = {};
  if (site === 'whatsav') {
    for (const dt of doc.querySelectorAll('dl dt')) fields[text(dt)] = dt.parentElement.querySelector('dd');
  } else {
    for (const row of doc.querySelectorAll('.profile.movie .details > div')) {
      if (row.children.length >= 2) fields[text(row.children[0])] = row.children[1];
    }
  }
  const field = name => empty(text(fields[name]));
  const linkObjects = element => [...(element?.querySelectorAll('a[href]') || [])].map(a => ({ name: text(a), url: absolute(a.getAttribute('href')) })).filter(a => a.name);
  const organizations = [];
  for (const [role, names] of [['maker', ['制作商', '片商']], ['label', ['厂牌']], ['distributor', ['发行商']]]) {
    const label = names.find(name => field(name));
    if (!label) continue;
    const links = linkObjects(fields[label]);
    for (const company of links.length ? links : [{ name: field(label), url: null }]) organizations.push({ ...company, role, sourceId: company.url ? new URL(company.url).pathname.split('/').filter(Boolean).at(-1) : null });
  }
  if (!organizations.some(o => o.role === 'maker') && ld.productionCompany?.name) organizations.push({ name: clean(ld.productionCompany.name), url: absolute(ld.productionCompany.url), role: 'maker' });
  let actors;
  if (site === 'javd') actors = [...linkObjects(fields['女优']).map(a => ({ ...a, gender: 'female' })), ...linkObjects(fields['男优']).map(a => ({ ...a, gender: 'male' }))];
  else actors = (Array.isArray(ld.actor) ? ld.actor : ld.actor ? [ld.actor] : []).map(a => ({ name: clean(a.name), url: absolute(a.url), gender: 'unknown' })).filter(a => a.name);
  actors = actors.map(actor => ({ ...actor, sourceId: actor.url ? new URL(actor.url).pathname.split('/').filter(Boolean).at(-1) : null }));
  const rawImages = ld.thumbnailUrl || ld.image || [];
  const images = (Array.isArray(rawImages) ? rawImages : [rawImages]).map(i => absolute(typeof i === 'string' ? i : i?.url || i?.contentUrl)).filter(Boolean);
  const uniqueImages = [...new Set(images)];
  const cover = uniqueImages.find(u => /pl\.(jpg|png|webp)(\?|$)/i.test(u)) || uniqueImages[0] || null;
  const poster = uniqueImages.find(u => /ps\.(jpg|png|webp)(\?|$)/i.test(u)) || cover;
  const duration = /^P(?:(\d+)D)?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$/.exec(ld.duration || '');
  const seconds = duration ? Number(duration[1] || 0) * 86400 + Number(duration[2] || 0) * 3600 + Number(duration[3] || 0) * 60 + Number(duration[4] || 0) : null;
  const withoutCode = value => {
    const s = clean(value);
    return codes(s.split(/\s/)[0]).includes(expected) ? s.replace(/^\S+\s*/, '') : s;
  };
  const genres = Array.isArray(ld.genre) ? ld.genre : [];
  const tags = site === 'javd' ? linkObjects(fields['标签']).map(a => a.name) : genres.map(clean);
  // JAVD's JSON-LD description is a site description, not a supplied plot.
  const summaryNode = doc.querySelector('[data-description],.video-description');
  const summary = summaryNode ? clean(summaryNode.textContent) : null;
  return {
    ready: true, blocked: false, routing: false, mismatch: false,
    metadata: {
      code: expected, title: withoutCode(heading), sourceTitle: withoutCode(ld.name),
      originalTitle: site === 'javd' ? clean(ld.name) : field('原名') || field('原文标题'),
      summary, siteDescription: clean(ld.description) || null,
      releaseDate: site === 'javd' ? ld.datePublished || field('发行时间') : field('发行日期') || field('发行时间'),
      uploadDate: site === 'whatsav' ? ld.uploadDate || field('上线日期') : null,
      runtimeSeconds: seconds,
      studio: field('制作商') || field('片商') || clean(ld.productionCompany?.name) || null,
      label: field('厂牌'), series: field('系列'),
      director: field('导演') || clean(ld.director?.name) || null,
      actors, organizations, tags, artwork: { cover, poster, gallery: uniqueImages.filter(u => u !== cover && u !== poster) },
      source: { name: site, url: baseUrl, id: new URL(baseUrl).pathname.split('/').filter(Boolean)[site === 'javd' ? 1 : 2] || null },
    },
  };
}
