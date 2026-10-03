// Self-contained for CDP and offline DOMParser validation.
export function parseActorPage({kind,expected,baseUrl,html=null}) {
  const doc=html===null?document:new DOMParser().parseFromString(html,'text/html');
  const clean=v=>String(v||'').replace(/\s+/g,' ').trim(), text=n=>clean(n?.textContent);
  const absolute=v=>{try{const u=new URL(v,baseUrl);return v&&u.protocol==='https:'?u.href:null;}catch{return null;}};
  const body=text(doc.body), url=new URL(baseUrl), currentPage=Number(url.searchParams.get('page')||1);
  const blocked=/just a moment|verify you are human|正在进行安全验证|请验证您是真人/i.test(doc.title+' '+body.slice(0,1000))||!!doc.querySelector('#challenge-running,#challenge-stage');
  const routing=!!doc.querySelector('meta[name="routing-data"]')||/跳转提示/.test(doc.title);
  if(blocked||routing)return{ready:false,blocked,routing};
  const pageLinks=[...doc.querySelectorAll('a.pagination-control[href],a[rel=next][href]')].map(a=>absolute(a.getAttribute('href'))).filter(Boolean).map(v=>new URL(v)).filter(u=>u.pathname===url.pathname);
  const next=pageLinks.find(u=>Number(u.searchParams.get('page'))===currentPage+1);
  const later=pageLinks.some(u=>Number(u.searchParams.get('page'))>currentPage);
  const shownPage=Number(text(doc.querySelector('.pagination-control.is-current'))||currentPage);
  const paginationError=(later&&!next)||shownPage!==currentPage;
  const count=value=>{const match=clean(value).replace(/,/g,'').match(/([\d.]+)\s*(k|万)?/i);return match?Math.round(Number(match[1])*(match[2]?.toLowerCase()==='k'?1000:match[2]==='万'?10000:1)):null;};
  if(kind==='actor-list'){
    const items=[...doc.querySelectorAll('main a[href]')].flatMap(a=>{
      const href=absolute(a.getAttribute('href'));if(!href||!/^\/zh\/actor\/[a-zA-Z0-9]+$/.test(new URL(href).pathname))return[];
      const name=text(a.querySelector('p')), amount=text(a).match(/([\d.,]+\s*(?:k|万)?)\s*部影片/i);
      if(!name||!amount)return[];
      return[{name,url:href,sourceId:new URL(href).pathname.split('/').at(-1),videoCount:count(amount[1]),videoCountText:amount[1],avatarUrl:absolute(a.querySelector('img[data-entity-image]')?.getAttribute('src'))}];
    });
    const sorted=doc.querySelector('select[name=sort]')?.value==='video_count_desc'&&url.searchParams.get('sort')==='video_count_desc';
    return{ready:items.length>0,items,sorted,paginationError,nextUrl:next?.href||null,currentPage};
  }
  const structured=[...doc.querySelectorAll('script[type="application/ld+json"]')].flatMap(s=>{try{const d=JSON.parse(s.textContent);return Array.isArray(d)?d:d['@graph']||[d];}catch{return[];}});
  const person=structured.find(o=>o['@type']==='Person'),heading=doc.querySelector('main h1');
  const sourceId=url.pathname.match(/^\/zh\/actor\/([a-zA-Z0-9]+)$/)?.[1];
  if(sourceId!==expected || (person?.url&&new URL(person.url,baseUrl).pathname!==url.pathname))return{ready:true,mismatch:true,foundCodes:[sourceId||'不是演员详情页']};
  if(!person||!heading)return{ready:false};
  const header=heading.closest('section'),section=[...doc.querySelectorAll('main section')].find(s=>/^参演影片/.test(text(s.querySelector('h2'))));
  if(!section)return{ready:false};
  const fields={};for(const dt of header.querySelectorAll('dt'))fields[text(dt)]=text(dt.nextElementSibling);
  const summary=clean(person.description)||null;
  const aliasNode=[...header.querySelectorAll('p')].find(p=>/^别名[：:]/.test(text(p)));
  const aliases=[...new Set([...(Array.isArray(person.alternateName)?person.alternateName:person.alternateName?[person.alternateName]:[]),...(aliasNode?text(aliasNode).replace(/^别名[：:]\s*/,'').split('、'):[])].map(clean).filter(Boolean))];
  const birth=(fields['出生日期']||fields['生日']||person.birthDate||summary||'').match(/(?:生年月日は\s*|出生日期[：:]?\s*|生日[：:]?\s*|^)(\d{4})[-年/](\d{1,2})[-月/](\d{1,2})/);
  const height=(fields['身高']||summary||'').match(/(?:身長は\s*|身高[：:]?\s*|^)(\d{2,3})\s*cm/i);
  const measurements=(fields['三围']||summary||'').match(/B\s*(\d{2,3})\s*(?:cm)?\s*[-/・]\s*W\s*(\d{2,3})\s*(?:cm)?\s*[-/・]\s*H\s*(\d{2,3})/i);
  const birthplace=fields['出生地']||(summary||'').match(/(?:は|出生地[：:]\s*)([\p{Script=Han}々]{1,10}?(?:都|道|府|県))出身/u)?.[1]||null;
  const image=typeof person.image==='string'?person.image:person.image?.url;
  const avatarUrl=absolute(image||header.querySelector('img[data-entity-image]')?.getAttribute('src'));
  const works=[];let unresolved=0;
  for(const card of section.querySelectorAll('[data-entity-view="grid"] article')){
    const link=card.querySelector('a[href*="/zh/video/"]'),href=absolute(link?.getAttribute('href'));if(!href)continue;
    const number=text(card.querySelector('.font-mono')).normalize('NFKC').toUpperCase();
    let code=null,match;
    if((match=/^FC2[-_\s]*(?:PPV[-_\s]*)?(\d{5,10})$/.exec(number)))code=`FC2-PPV-${match[1]}`;
    else if((match=/^([A-Z]{2,12})[-_\s]?(\d{2,7})$/.exec(number)))code=`${match[1]}-${match[2]}`;
    if(!code)unresolved++;
    works.push({sourceId:new URL(href).pathname.split('/').at(-1),code,rawCode:number,url:href,title:text(card.querySelector('h3'))||null});
  }
  const totalText=text(section.querySelector('h2')).replace(/^参演影片\s*/,'');
  return{ready:works.length>0||count(totalText)===0,paginationError,currentPage,nextUrl:next?.href||null,works,unresolved,
    profile:{name:text(heading),aliases,summary,gender:person.gender?clean(person.gender):null,birthDate:birth?`${birth[1]}-${birth[2].padStart(2,'0')}-${birth[3].padStart(2,'0')}`:null,heightCm:height?Number(height[1]):null,birthplace,measurements:measurements?`${measurements[1]}-${measurements[2]}-${measurements[3]}`:null,rawFields:fields,avatarUrl,videoCount:count(totalText),videoCountText:totalText,source:{name:'whatsav',id:sourceId,url:baseUrl},extraction:{birthDate:birth?'explicit page text':null,heightCm:height?'explicit page text':null,measurements:measurements?'explicit page text':null}}
  };
}
