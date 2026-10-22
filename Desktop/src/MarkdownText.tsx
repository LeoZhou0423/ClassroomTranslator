import { Fragment, type ReactNode } from 'react';
import { parseBlocks } from './markdown';

/** Inline markdown: **bold**, *italic* / _italic_, `code`. */
function renderInline(text: string, keyPrefix: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  const pattern = /(\*\*[^*]+\*\*|\*[^*]+\*|_[^_]+_|`[^`]+`)/g;
  let last = 0;
  let match: RegExpExecArray | null;
  let index = 0;
  while ((match = pattern.exec(text))) {
    if (match.index > last) nodes.push(text.slice(last, match.index));
    const token = match[0];
    const key = `${keyPrefix}-i${index++}`;
    if (token.startsWith('**')) nodes.push(<strong key={key}>{token.slice(2, -2)}</strong>);
    else if (token.startsWith('`')) nodes.push(<code key={key}>{token.slice(1, -1)}</code>);
    else nodes.push(<em key={key}>{token.slice(1, -1)}</em>);
    last = match.index + token.length;
  }
  if (last < text.length) nodes.push(text.slice(last));
  return nodes;
}

/** Render classroom-summary markdown as structured React nodes. */
export function MarkdownText({ source }: { source: string }) {
  const blocks = parseBlocks(source);
  return (
    <div className="markdown-body">
      {blocks.map((block, index) => {
        const key = `b${index}`;
        if (block.type === 'heading') {
          const Tag = `h${Math.min(6, Math.max(2, block.level + 1))}` as
            'h2' | 'h3' | 'h4' | 'h5' | 'h6';
          return <Tag key={key}>{renderInline(block.text, key)}</Tag>;
        }
        if (block.type === 'hr') return <hr key={key} />;
        if (block.type === 'list') {
          const ListTag = block.ordered ? 'ol' : 'ul';
          return (
            <ListTag key={key}>
              {block.items.map((item, itemIndex) => (
                <li
                  key={`${key}-${itemIndex}`}
                  className={
                    item.checked === undefined ? undefined : item.checked ? 'task checked' : 'task'
                  }
                >
                  {item.checked !== undefined && (
                    <span className="task-box" aria-hidden="true">
                      {item.checked ? '☑' : '☐'}
                    </span>
                  )}
                  {renderInline(item.text, `${key}-${itemIndex}`)}
                </li>
              ))}
            </ListTag>
          );
        }
        return (
          <p key={key}>
            {block.text.split('\n').map((line, lineIndex) => (
              <Fragment key={`${key}-l${lineIndex}`}>
                {lineIndex > 0 && <br />}
                {renderInline(line, `${key}-l${lineIndex}`)}
              </Fragment>
            ))}
          </p>
        );
      })}
    </div>
  );
}
