import { createHash } from 'node:crypto';

// Source namespaces stay separate: a maker and a label may share a name or ID.
export function relationshipRecords(metadata) {
  const defaultSource = metadata.source?.name || 'unknown';
  const organizations = metadata.organizations ?? [
    ...(metadata.studio ? [{ name: metadata.studio, role: 'maker' }] : []),
    ...(metadata.label ? [{ name: metadata.label, role: 'label' }] : []),
  ];
  const records = [];
  for (const [kind, values] of [['actor', metadata.actors || []], ['company', organizations]]) {
    for (const value of values) {
      const source=value.source||defaultSource;
      const name = String(value.name || '').trim(); if (!name) continue;
      const role = kind === 'actor' ? 'cast' : ['maker', 'label', 'distributor'].includes(value.role) ? value.role : 'unknown';
      let namespace = null, sourceId = null;
      try {
        const url = new URL(value.url);
        const parts = url.pathname.split('/').filter(Boolean);
        if (/^(zh|cn|en|ja)$/.test(parts[0])) parts.shift();
        if (parts.length === 2 && /^(actor|actress|star|maker|label|distributor)$/.test(parts[0])) [namespace, sourceId] = parts;
      } catch { /* Name-only data stays provisional, scoped to this movie. */ }
      const provisional = !sourceId;
      const key = provisional ? [source, kind, metadata.code, role, name.normalize('NFKC')] : [source, kind, namespace, sourceId];
      const id = `${kind}_${createHash('sha256').update(JSON.stringify(key)).digest('hex').slice(0, 32)}`;
      records.push({ id, kind, name, source, namespace, sourceId, url: value.url || null, provisional, gender: value.gender || 'unknown', role });
    }
  }
  return records;
}
