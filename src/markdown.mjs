// Turns a model's Markdown reply into a small tree the interface can draw.
// Nothing here produces HTML: the tree holds only text, so a reply can never inject markup.

const FENCE = /^ {0,3}(```+|~~~+)\s*([\w+#.-]*)\s*$/;
const HEADING = /^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$/;
const RULE = /^ {0,3}([-*_])(?:\s*\1){2,}\s*$/;
const ITEM = /^(\s*)(?:([-*+])|(\d{1,9})[.)])\s+(.*)$/;
const QUOTE = /^ {0,3}>\s?(.*)$/;
const DIVIDER = /^\s*\|?\s*:?-{1,}:?\s*(?:\|\s*:?-{1,}:?\s*)*\|?\s*$/;
const INLINE = /(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)|\*\*(?=\S)([\s\S]+?\S)\*\*|__(?=\S)([\s\S]+?\S)__(?!\w)|~~(?=\S)([\s\S]+?\S)~~|\*(?=[^\s*])([^*]*?[^\s*])\*(?!\*)|(?<![\w_])_(?=[^\s_])([^_]*?[^\s_])_(?![\w_])|\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/;

const cells = line => line.trim().replace(/^\|/, '').replace(/\|$/, '').split(/(?<!\\)\|/).map(cell => cell.trim().replace(/\\\|/g, '|'));

function nest(entries, depth = 0) {
  const list = {type: 'list', ordered: entries[0].ordered, start: entries[0].number, items: []};
  const base = entries[0].indent;
  let deeper = [];
  const close = () => {if (deeper.length) list.items.at(-1).list = nest(deeper, depth + 1); deeper = [];};
  for (const entry of entries) {
    if (list.items.length && entry.indent > base + 1 && depth < 4) deeper.push(entry);
    else {close(); list.items.push({children: inline(entry.text)});}
  }
  close();
  return list;
}

export function inline(text) {
  const out = [];
  let rest = String(text);
  while (rest) {
    const found = INLINE.exec(rest);
    if (!found) break;
    if (found.index) out.push({type: 'text', text: rest.slice(0, found.index)});
    if (found[1]) out.push({type: 'code', text: found[2].trim() || found[2]});
    else if (found[3] !== undefined || found[4] !== undefined) out.push({type: 'strong', children: inline(found[3] ?? found[4])});
    else if (found[5] !== undefined) out.push({type: 'strike', children: inline(found[5])});
    else if (found[6] !== undefined || found[7] !== undefined) out.push({type: 'em', children: inline(found[6] ?? found[7])});
    else out.push({type: 'link', text: found[8], href: found[9]});
    rest = rest.slice(found.index + found[0].length);
  }
  if (rest) out.push({type: 'text', text: rest});
  return out;
}

export function parse(source) {
  const lines = String(source ?? '').replace(/\r\n?/g, '\n').split('\n');
  const blocks = [];
  let para = [];
  const flush = () => {if (para.length) blocks.push({type: 'paragraph', children: inline(para.join('\n'))}); para = [];};
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const fence = FENCE.exec(line);
    if (fence) {
      // A fence with no closing line is a reply still being written: show what has arrived.
      flush();
      const body = [];
      for (i++; i < lines.length && !(lines[i].trim().startsWith(fence[1]) && /^[`~]+$/.test(lines[i].trim())); i++) body.push(lines[i]);
      blocks.push({type: 'code', lang: fence[2], text: body.join('\n')});
      continue;
    }
    if (!line.trim()) {flush(); continue;}
    const heading = HEADING.exec(line);
    if (heading) {flush(); blocks.push({type: 'heading', level: heading[1].length, children: inline(heading[2])}); continue;}
    if (RULE.test(line)) {flush(); blocks.push({type: 'rule'}); continue;}
    if (line.includes('|') && i + 1 < lines.length && lines[i + 1].includes('-') && DIVIDER.test(lines[i + 1]) && cells(line).length === cells(lines[i + 1]).length) {
      flush();
      const head = cells(line), rows = [];
      for (i += 2; i < lines.length && lines[i].trim() && lines[i].includes('|'); i++) rows.push(head.map((_, column) => inline(cells(lines[i])[column] ?? '')));
      i--;
      blocks.push({type: 'table', head: head.map(inline), rows});
      continue;
    }
    const item = ITEM.exec(line);
    if (item) {
      flush();
      const entries = [];
      for (; i < lines.length; i++) {
        const next = ITEM.exec(lines[i]);
        const indent = next ? next[1].replace(/\t/g, '    ').length : 0;
        // A deeper item of either kind nests; one at the first item's depth must be the same kind.
        if (next && (!entries.length || indent > entries[0].indent + 1 || (next[3] !== undefined) === entries[0].ordered)) {entries.push({indent, ordered: next[3] !== undefined, number: Number(next[3] || 1), text: next[4]}); continue;}
        // Wrapped lines belong to the item above them.
        if (!next && entries.length && lines[i].trim() && /^\s+/.test(lines[i]) && !FENCE.test(lines[i])) {entries.at(-1).text += '\n' + lines[i].trim(); continue;}
        break;
      }
      i--;
      blocks.push(nest(entries));
      continue;
    }
    const quote = QUOTE.exec(line);
    if (quote) {
      flush();
      const body = [];
      for (; i < lines.length && QUOTE.test(lines[i]); i++) body.push(QUOTE.exec(lines[i])[1]);
      i--;
      blocks.push({type: 'quote', children: parse(body.join('\n'))});
      continue;
    }
    para.push(line);
  }
  flush();
  return blocks;
}
