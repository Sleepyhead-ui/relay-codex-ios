export interface TechnicalTextPreview {
  text: string;
  omittedCharacters: number;
  truncated: boolean;
}

export function previewTechnicalText(source: string, maxCharacters = 32_000, maxLines = 160): TechnicalTextPreview {
  const tailStart = Math.max(0, source.length - Math.max(1, maxCharacters));
  const tail = source.slice(tailStart);
  const lines = tail.split(/\r?\n/);
  const visible = lines.slice(Math.max(0, lines.length - Math.max(1, maxLines)));
  const visibleText = visible.join("\n");
  const omittedCharacters = Math.max(0, source.length - visibleText.length);
  return {
    text: omittedCharacters > 0 ? `... 已省略较早输出（${omittedCharacters.toLocaleString()} 字符） ...\n${visibleText}` : visibleText,
    omittedCharacters,
    truncated: omittedCharacters > 0,
  };
}
