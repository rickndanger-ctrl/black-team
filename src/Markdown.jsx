import React, {useMemo} from 'react';
import {parse} from './markdown.mjs';

// Links are shown with their address and are not clickable: the desktop window never
// leaves the app, and a reply should not be able to send anyone anywhere unseen.
const spans = nodes => nodes.map((node, index) => {
  if (node.type === 'code') return <code key={index}>{node.text}</code>;
  if (node.type === 'strong') return <strong key={index}>{spans(node.children)}</strong>;
  if (node.type === 'em') return <em key={index}>{spans(node.children)}</em>;
  if (node.type === 'strike') return <s key={index}>{spans(node.children)}</s>;
  if (node.type === 'link') return <span className="md-link" key={index}>{node.text}{node.text !== node.href && <small> ({node.href})</small>}</span>;
  return <React.Fragment key={index}>{node.text}</React.Fragment>;
});

const list = (node, key) => React.createElement(node.ordered ? 'ol' : 'ul', {key, start: node.ordered && node.start !== 1 ? node.start : undefined}, node.items.map((item, at) => <li key={at}>{spans(item.children)}{item.list && list(item.list)}</li>));

const blocks = nodes => nodes.map((node, index) => {
  if (node.type === 'heading') return React.createElement(`h${Math.min(6, node.level + 2)}`, {key: index, className: `md-h md-h${node.level}`}, spans(node.children));
  if (node.type === 'code') return <pre key={index} className="md-code" data-lang={node.lang || undefined}><code>{node.text}</code></pre>;
  if (node.type === 'rule') return <hr key={index}/>;
  if (node.type === 'quote') return <blockquote key={index}>{blocks(node.children)}</blockquote>;
  if (node.type === 'list') return list(node, index);
  if (node.type === 'table') return <div className="md-table" key={index}><table><thead><tr>{node.head.map((cell, at) => <th key={at}>{spans(cell)}</th>)}</tr></thead><tbody>{node.rows.map((row, at) => <tr key={at}>{row.map((cell, column) => <td key={column}>{spans(cell)}</td>)}</tr>)}</tbody></table></div>;
  return <p key={index}>{spans(node.children)}</p>;
});

export default function Markdown({text}) {
  const tree = useMemo(() => parse(text), [text]);
  return <div className="message-body md">{blocks(tree)}</div>;
}
