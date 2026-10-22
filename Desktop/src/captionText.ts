export const hasUnclear = (text: string) => /\[\s*unclear\b[^\]]*\]/i.test(text);
export const stripAnnotations = (text: string) =>
  hasUnclear(text)
    ? ''
    : text
        .replace(/\[[^\]]*\]|【[^】]*】/g, '')
        .replace(
          /[（(]\s*(?:(?:(?:upbeat|soft|gentle|dramatic|background|instrumental|classical|cheerful|loud|sad|ominous|slow|fast)\s+)*(?:music|applause|laughter|noise|silence|inaudible|video playback|static|audio out|blank_audio|no_speech)(?:\s+(?:playing|continues|fades|swells))?|(?:(?:欢快|轻柔|舒缓|背景|悲伤|激昂|古典)的?)?(?:音乐|掌声|笑声|噪声|静音)(?:响起|继续|渐弱)?)\s*[)）]/gi,
          '',
        )
        .replace(/\s+/g, ' ')
        .trim();
export function sanitizeCaption<T extends { original: string; translated: string }>(
  caption: T,
): T | null {
  const original = stripAnnotations(caption.original);
  if (!original) return null;
  return {
    ...caption,
    original,
    translated: stripAnnotations(caption.translated),
  };
}
