import {test} from 'node:test';
import assert from 'node:assert/strict';
import {inline, parse} from '../src/markdown.mjs';

const plain = nodes => nodes.map(node => node.text ?? plain(node.children)).join('');

test('formats bold, italic, code and strike inside a line', () => {
  const nodes = inline('Ran **`count.py`** and it *worked*, ~~no~~ really: `1 2 3`.');
  assert.deepEqual(nodes.map(node => node.type), ['text', 'strong', 'text', 'em', 'text', 'strike', 'text', 'code', 'text']);
  assert.equal(nodes[1].children[0].type, 'code');
  assert.equal(plain(nodes), 'Ran count.py and it worked, no really: 1 2 3.');
});

test('leaves arithmetic, file names and code contents alone', () => {
  assert.equal(inline('2 * 3 * 4 and my_file_name.py and a_b').length, 1);
  assert.deepEqual(inline('use `**kwargs` here')[1], {type: 'code', text: '**kwargs'});
  assert.deepEqual(inline('``a ` b``')[0], {type: 'code', text: 'a ` b'});
});

test('keeps only web links, and keeps their address visible', () => {
  assert.deepEqual(inline('[docs](https://example.org/a)')[0], {type: 'link', text: 'docs', href: 'https://example.org/a'});
  assert.equal(inline('[x](javascript:alert(1))').some(node => node.type === 'link'), false);
});

test('reads headings, lists, quotes, rules and paragraphs as blocks', () => {
  const tree = parse('# Done\n\nHere is what changed:\n\n- **Modified** `a.py`\n  wrapped line\n  - nested\n- Ran it\n\n3. one\n4. two\n   - under two\n\n> noted\n\n---\nlast line\nsame paragraph');
  assert.deepEqual(tree.map(node => node.type), ['heading', 'paragraph', 'list', 'list', 'quote', 'rule', 'paragraph']);
  assert.equal(tree[2].ordered, false);
  assert.equal(tree[2].items.length, 2);
  assert.equal(plain(tree[2].items[0].list.items[0].children), 'nested');
  assert.match(plain(tree[2].items[0].children), /wrapped line/);
  assert.equal(tree[3].ordered, true);
  assert.equal(tree[3].start, 3);
  assert.equal(tree[3].items[1].list.ordered, false);
  assert.equal(tree[4].children[0].type, 'paragraph');
  assert.equal(plain(tree[6].children), 'last line\nsame paragraph');
});

test('keeps code blocks verbatim, including one still being written', () => {
  const tree = parse('Before\n```python\nprint("**not bold**")\n\n# not a heading\n```\nAfter\n```sh\nls -la');
  assert.deepEqual(tree.map(node => node.type), ['paragraph', 'code', 'paragraph', 'code']);
  assert.deepEqual(tree[1], {type: 'code', lang: 'python', text: 'print("**not bold**")\n\n# not a heading'});
  assert.deepEqual(tree[3], {type: 'code', lang: 'sh', text: 'ls -la'});
});

test('reads a table and pads short rows', () => {
  const tree = parse('| Name | Speed |\n|---|---:|\n| read | **49** |\n| write |\n\nafter');
  assert.equal(tree[0].type, 'table');
  assert.deepEqual(tree[0].head.map(plain), ['Name', 'Speed']);
  assert.deepEqual(tree[0].rows.map(row => row.map(plain)), [['read', '49'], ['write', '']]);
  assert.equal(tree[1].type, 'paragraph');
});

test('a line with a pipe but no divider stays a paragraph', () => {
  assert.equal(parse('a | b\nplain')[0].type, 'paragraph');
  assert.deepEqual(parse(''), []);
  assert.deepEqual(parse(null), []);
});
