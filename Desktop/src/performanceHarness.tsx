import { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Transcript } from "./App";
import { applyDeltaBatch } from "./transcript";
import type { TranscriptItem, TurnMetadata } from "./types";
import "./styles.css";

const liveTurnId = "turn.999";
const stableMarkdown = `${Array.from({ length: 400 }, (_, index) => `Stable paragraph ${index}. **Markdown** remains unchanged.`).join("\n\n")}\n\n`;
const initialItems: TranscriptItem[] = Array.from({ length: 1_000 }, (_, index) => ({
  id: `message.${index}`,
  turnId: `turn.${index}`,
  kind: "assistant",
  text: index === 999 ? `${stableMarkdown}Streaming answer` : `Completed answer ${index}`,
}));
const turns: Record<string, TurnMetadata> = Object.fromEntries(Array.from({ length: 1_000 }, (_, index) => [
  `turn.${index}`,
  { id: `turn.${index}`, status: index === 999 ? "inProgress" : "completed", startedAt: Date.now() / 1_000 - 5 },
]));

function Harness() {
  const [items, setItems] = useState(initialItems);
  const [complete, setComplete] = useState(false);
  const transcriptRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let updates = 0;
    let animationFrame = 0;
    let previousFrame = performance.now();
    let maximumFrameGap = 0;
    const longTasks: number[] = [];
    const startedAt = performance.now();

    const observeFrame = (now: number) => {
      maximumFrameGap = Math.max(maximumFrameGap, now - previousFrame);
      previousFrame = now;
      animationFrame = requestAnimationFrame(observeFrame);
    };
    animationFrame = requestAnimationFrame(observeFrame);

    const observer = typeof PerformanceObserver !== "undefined"
      ? new PerformanceObserver((list) => longTasks.push(...list.getEntries().map((entry) => entry.duration)))
      : undefined;
    try { observer?.observe({ type: "longtask", buffered: true }); } catch { observer?.disconnect(); }

    const timer = window.setInterval(() => {
      updates += 1;
      setItems((current) => applyDeltaBatch(current, [{
        id: "message.999",
        turnId: liveTurnId,
        kind: "assistant",
        text: ".",
        detail: "",
      }]));
      if (updates === 100) {
        window.clearInterval(timer);
        requestAnimationFrame(() => requestAnimationFrame(() => {
          const transcript = transcriptRef.current;
          const result = {
            updates,
            durationMs: performance.now() - startedAt,
            maximumFrameGapMs: maximumFrameGap,
            longTaskCount: longTasks.length,
            longestTaskMs: Math.max(0, ...longTasks),
            visibleTurnBlocks: transcript?.querySelectorAll(".turn-block").length ?? 0,
            markdownChunks: transcript?.querySelectorAll(".markdown-chunk").length ?? 0,
            scrollHeight: transcript?.scrollHeight ?? 0,
            clientHeight: transcript?.clientHeight ?? 0,
          };
          (window as any).__relayHarness = {
            ...result,
            passed: result.durationMs < 3_500
              && result.maximumFrameGapMs < 120
              && result.longTaskCount <= 5
              && result.visibleTurnBlocks === 40
              && result.markdownChunks >= 400,
          };
          setComplete(true);
        }));
      }
    }, 16);
    return () => {
      window.clearInterval(timer);
      cancelAnimationFrame(animationFrame);
      observer?.disconnect();
    };
  }, []);

  useEffect(() => {
    const transcript = transcriptRef.current;
    if (transcript) transcript.scrollTop = transcript.scrollHeight;
  }, [items]);

  return <main className="performance-harness" data-harness-status={complete ? "complete" : "running"}>
    <div className="transcript" ref={transcriptRef}>
      <Transcript
        items={items}
        turns={turns}
        activeTurnId={liveTurnId}
        olderAvailable={false}
        loadingOlder={false}
        onLoadOlder={async () => 0}
      />
    </div>
  </main>;
}

createRoot(document.getElementById("root")!).render(<Harness/>);
