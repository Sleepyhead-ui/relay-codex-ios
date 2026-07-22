export function splitMarkdownChunks(source: string): string[] {
  const normalized = source.replace(/\r\n/g, "\n");
  if (!normalized) return [""];
  const chunks: string[] = [];
  let chunkStart = 0;
  let lineStart = 0;
  let insideCodeFence = false;
  let previousNonempty = "";

  while (lineStart < normalized.length) {
    const newline = normalized.indexOf("\n", lineStart);
    const lineEnd = newline < 0 ? normalized.length : newline;
    const trimmed = normalized.slice(lineStart, lineEnd).trim();
    if (trimmed.startsWith("```")) insideCodeFence = !insideCodeFence;
    if (!trimmed && !insideCodeFence && newline >= 0) {
      const boundary = newline + 1;
      const next = nextNonemptyLine(normalized, boundary);
      if (!continuesSameList(previousNonempty, next)) {
        chunks.push(normalized.slice(chunkStart, boundary));
        chunkStart = boundary;
      }
    } else if (trimmed) {
      previousNonempty = trimmed;
    }
    if (newline < 0) break;
    lineStart = newline + 1;
  }
  if (chunkStart < normalized.length) chunks.push(normalized.slice(chunkStart));
  return chunks.length ? chunks : [normalized];
}

function nextNonemptyLine(source: string, start: number) {
  let cursor = start;
  while (cursor < source.length) {
    const newline = source.indexOf("\n", cursor);
    const end = newline < 0 ? source.length : newline;
    const value = source.slice(cursor, end).trim();
    if (value) return value;
    if (newline < 0) break;
    cursor = newline + 1;
  }
  return "";
}

function continuesSameList(previous: string, next: string) {
  return orderedListItem(previous) && orderedListItem(next)
    || unorderedListItem(previous) && unorderedListItem(next);
}

function orderedListItem(value: string) { return /^\d+\.\s+/.test(value); }
function unorderedListItem(value: string) { return /^[-+*]\s+/.test(value); }
