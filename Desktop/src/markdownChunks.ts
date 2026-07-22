export function splitMarkdownChunks(source: string): string[] {
  return splitMarkdownChunkResult(source).chunks;
}

export class IncrementalMarkdownChunks {
  private source = "";
  private stableLength = 0;
  private stableChunks: string[] = [];
  processedCharacters = 0;

  update(nextSource: string) {
    const normalized = nextSource.replace(/\r\n/g, "\n");
    if (!normalized.startsWith(this.source)) {
      this.source = "";
      this.stableLength = 0;
      this.stableChunks = [];
    }
    const tail = normalized.slice(this.stableLength);
    this.processedCharacters += tail.length;
    const result = splitMarkdownChunkResult(tail);
    if (result.stableCount > 0) {
      const promoted = result.chunks.slice(0, result.stableCount);
      this.stableChunks.push(...promoted);
      this.stableLength += promoted.reduce((total, chunk) => total + chunk.length, 0);
    }
    const unstable = result.chunks.slice(result.stableCount);
    this.source = normalized;
    return [...this.stableChunks, ...unstable];
  }
}

function splitMarkdownChunkResult(source: string): { chunks: string[]; stableCount: number } {
  const normalized = source.replace(/\r\n/g, "\n");
  if (!normalized) return { chunks: [], stableCount: 0 };
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
  const endedAtBoundary = chunkStart === normalized.length;
  if (!endedAtBoundary) chunks.push(normalized.slice(chunkStart));
  if (!chunks.length) chunks.push(normalized);
  return { chunks, stableCount: endedAtBoundary ? chunks.length : Math.max(0, chunks.length - 1) };
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
