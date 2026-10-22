export type Block =
  | { type: 'heading'; level: number; text: string }
  | { type: 'hr' }
  | {
      type: 'list';
      ordered: boolean;
      items: { text: string; checked?: boolean }[];
    }
  | { type: 'paragraph'; text: string };

/** Unwrap a single surrounding ``` / ```markdown fence if the model boxed the whole answer. */
export function unwrapFence(markdown: string): string {
  const text = markdown.replace(/\r\n?/g, '\n').trim();
  const match = /^```(?:markdown|md)?\s*\n([\s\S]*?)\n?```$/i.exec(text);
  return match ? match[1].trim() : text;
}

export function parseBlocks(markdown: string): Block[] {
  const blocks: Block[] = [];
  const lines = unwrapFence(markdown).split('\n');
  let paragraph: string[] = [];
  let list: {
    ordered: boolean;
    items: { text: string; checked?: boolean }[];
  } | null = null;

  const flushParagraph = () => {
    if (!paragraph.length) return;
    blocks.push({ type: 'paragraph', text: paragraph.join('\n') });
    paragraph = [];
  };
  const flushList = () => {
    if (!list) return;
    blocks.push({ type: 'list', ordered: list.ordered, items: list.items });
    list = null;
  };

  for (const raw of lines) {
    const line = raw.trimEnd();
    if (!line.trim()) {
      flushParagraph();
      flushList();
      continue;
    }
    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      flushParagraph();
      flushList();
      blocks.push({
        type: 'heading',
        level: heading[1].length,
        text: heading[2].trim(),
      });
      continue;
    }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(line.trim())) {
      flushParagraph();
      flushList();
      blocks.push({ type: 'hr' });
      continue;
    }
    const bullet = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(line);
    if (bullet) {
      flushParagraph();
      const ordered = /\d/.test(bullet[2]);
      const body = bullet[3];
      const task = /^\[([ xX])\]\s+(.*)$/.exec(body);
      const item = task
        ? { text: task[2], checked: task[1].toLowerCase() === 'x' }
        : { text: body };
      if (!list || list.ordered !== ordered) {
        flushList();
        list = { ordered, items: [] };
      }
      list.items.push(item);
      continue;
    }
    flushList();
    paragraph.push(line.trim());
  }
  flushParagraph();
  flushList();
  return blocks;
}

function stripInline(text: string): string {
  return text
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/\*([^*]+)\*/g, '$1')
    .replace(/_([^_]+)_/g, '$1')
    .replace(/`([^`]+)`/g, '$1');
}

/** Flatten markdown to readable plain text for txt/Word export. */
export function markdownToPlainText(markdown: string): string {
  return parseBlocks(markdown)
    .map((block) => {
      if (block.type === 'heading') return stripInline(block.text);
      if (block.type === 'hr') return '────────';
      if (block.type === 'list') {
        return block.items
          .map((item, index) => {
            const mark =
              item.checked === undefined
                ? block.ordered
                  ? `${index + 1}.`
                  : '•'
                : item.checked
                  ? '☑'
                  : '☐';
            return `${mark} ${stripInline(item.text)}`;
          })
          .join('\n');
      }
      return stripInline(block.text);
    })
    .filter(Boolean)
    .join('\n\n');
}
