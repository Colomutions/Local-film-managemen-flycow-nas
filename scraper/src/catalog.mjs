import path from 'node:path';

const IGNORED = new Set(['H', 'X', 'HEVC', 'AVC', 'FHD', 'UHD', 'MP', 'CD', 'DISC', 'PART']);
export const VIDEO_EXTENSIONS = new Set(['.mp4', '.mkv', '.avi', '.m4v', '.mov', '.wmv', '.ts', '.m2ts', '.webm', '.flv', '.rmvb']);

export function catalogNumbers(value) {
  const input = String(value).normalize('NFKC').toUpperCase();
  const found = [];
  const fc2 = /(?<![A-Z0-9])FC2[\s_-]*(?:PPV[\s_-]*)?(\d{5,10})(?!\d)/g;
  for (const match of input.matchAll(fc2)) found.push(`FC2-PPV-${match[1]}`);
  const rest = input.replace(fc2, ' ');
  for (const match of rest.matchAll(/(?<![A-Z0-9])([A-Z]{2,12})[\s_-]?(\d{2,7})(?!\d)/g)) {
    if (!IGNORED.has(match[1])) found.push(`${match[1]}-${match[2]}`);
  }
  return [...new Set(found)];
}

export function identifyFile(relativePath) {
  const portable = relativePath.replaceAll('\\', '/');
  const name = path.posix.basename(portable);
  const stem = name.slice(0, name.length - path.posix.extname(name).length);
  const fromFile = catalogNumbers(stem);
  const fromFolder = catalogNumbers(path.posix.basename(path.posix.dirname(portable)));
  if (fromFile.length > 1 || fromFolder.length > 1) return { code: null, issue: 'multiple_numbers', candidates: [...new Set([...fromFile, ...fromFolder])] };
  if (fromFile.length && fromFolder.length && fromFile[0] !== fromFolder[0]) return { code: null, issue: 'folder_filename_conflict', candidates: [...fromFile, ...fromFolder] };
  const code = fromFile[0] || fromFolder[0];
  if (!code) return { code: null, issue: 'number_not_found', candidates: [] };
  // Only the prefix and its first number identify a movie. Trailing -1/-01/-ABC
  // are retained as file information and never create another movie record.
  return { code, issue: null, candidates: [code] };
}

export function requireCode(value) {
  const codes = catalogNumbers(value);
  if (codes.length !== 1 || codes[0] !== value) throw new Error('番号格式无效');
  return value;
}

export const fileOrder = (a, b) => a.relativePath.localeCompare(b.relativePath, 'en', { numeric: true, sensitivity: 'base' });
