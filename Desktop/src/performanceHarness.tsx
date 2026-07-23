import { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Transcript } from "./App";
import { applyDeltaBatch, mergeSessionPatch } from "./transcript";
import type { TranscriptItem, TurnMetadata } from "./types";
import "./styles.css";

const liveTurnId = "turn.999";
const stableMarkdown = `${Array.from({ length: 400 }, (_, index) => `Stable paragraph ${index}. **Markdown** remains unchanged.`).join("\n\n")}\n\n`;
const largeCommandOutput = `${"old output\n".repeat(1_000_000)}latest line`;
const testImage = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAFUlEQVR4nGP8z8AARAwMjDAGCjAFAH4ABf4ZRaQAAAAASUVORK5CYII=";

(window as any).relayDesktop = {
  readImage: async () => testImage,
  showFile: async () => true,
};

const initialItems: TranscriptItem[] = [
  ...Array.from({ length: 999 }, (_, index) => ({
    id: `message.${index}`,
    turnId: `turn.${index}`,
    kind: "assistant" as const,
    text: `Completed answer ${index}`,
  })),
  {
    id: "prompt.999",
    turnId: liveTurnId,
    kind: "user" as const,
    text: "Inspect the attached image and continue streaming.",
    imagePaths: ["C:\\Relay\\performance-image.png"],
  },
  {
    id: "command.999",
    turnId: liveTurnId,
    kind: "command" as const,
    text: "generate-large-output",
    detail: largeCommandOutput,
    status: "completed",
  },
  {
    id: "message.999",
    turnId: liveTurnId,
    kind: "assistant" as const,
    text: `${stableMarkdown}Streaming answer`,
  },
];

const turns: Record<string, TurnMetadata> = Object.fromEntries(Array.from({ length: 1_000 }, (_, index) => [
  `turn.${index}`,
  { id: `turn.${index}`, status: index === 999 ? "inProgress" : "completed", startedAt: Date.now() / 1_000 - 5 },
]));

const nextFrame = () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));

async function settleFrames(count = 2) {
  for (let index = 0; index < count; index += 1) await nextFrame();
}

function Harness() {
  const [items, setItems] = useState(initialItems);
  const [complete, setComplete] = useState(false);
  const transcriptRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const transcript = transcriptRef.current;
    if (!transcript) return;
    transcript.scrollTop = transcript.scrollHeight;

    const stableTurn = document.getElementById("relay-transcript-turn.turn.960");
    const stableMarkdownChunk = document
      .getElementById("relay-transcript-turn.turn.999")
      ?.querySelector(".markdown-chunk") ?? null;
    let stableTurnMutations = 0;
    let stableMarkdownMutations = 0;
    const stableTurnObserver = new MutationObserver((records) => { stableTurnMutations += records.length; });
    const stableMarkdownObserver = new MutationObserver((records) => { stableMarkdownMutations += records.length; });
    if (stableTurn) stableTurnObserver.observe(stableTurn, { childList: true, characterData: true, subtree: true });
    if (stableMarkdownChunk) stableMarkdownObserver.observe(stableMarkdownChunk, { childList: true, characterData: true, subtree: true });

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

    const performanceObserver = typeof PerformanceObserver !== "undefined"
      ? new PerformanceObserver((list) => longTasks.push(...list.getEntries().map((entry) => entry.duration)))
      : undefined;
    try { performanceObserver?.observe({ type: "longtask" }); } catch { performanceObserver?.disconnect(); }

    const finish = async () => {
      await settleFrames();
      const durationMs = performance.now() - startedAt;
      const visibleTurnBlocks = transcript.querySelectorAll(".turn-block").length;
      const markdownChunks = transcript.querySelectorAll(".markdown-chunk").length;
      const bottomDistance = Math.abs(transcript.scrollHeight - transcript.clientHeight - transcript.scrollTop);
      const retainedStableTurn = stableTurn === document.getElementById("relay-transcript-turn.turn.960");
      const retainedStableMarkdown = stableMarkdownChunk === document
        .getElementById("relay-transcript-turn.turn.999")
        ?.querySelector(".markdown-chunk");

      transcript.scrollTop = Math.min(420, Math.max(0, transcript.scrollHeight - transcript.clientHeight));
      const anchor = document.getElementById("relay-transcript-turn.turn.960");
      const anchorTop = anchor?.getBoundingClientRect().top;
      transcript.querySelector<HTMLButtonElement>(".load-older")?.click();
      await settleFrames(3);
      const restoredAnchor = document.getElementById("relay-transcript-turn.turn.960");
      const anchorDrift = anchorTop == null || !restoredAnchor ? Number.POSITIVE_INFINITY : Math.abs(restoredAnchor.getBoundingClientRect().top - anchorTop);

      const image = transcript.querySelector<HTMLImageElement>(".user-image img");
      try { await image?.decode(); } catch { /* The fixed frame still proves layout stability if decoding is unavailable. */ }
      const imageBefore = image?.getBoundingClientRect();
      transcript.querySelector<HTMLButtonElement>(".tool-row button")?.click();
      await settleFrames(3);
      const imageAfter = image?.getBoundingClientRect();
      const commandPreview = transcript.querySelector<HTMLElement>(".tool-row pre")?.textContent || "";
      const imageSizeStable = Boolean(imageBefore && imageAfter
        && imageBefore.width >= 100
        && Math.abs(imageBefore.width - imageAfter.width) <= 0.5
        && Math.abs(imageBefore.height - imageAfter.height) <= 0.5);

      stableTurnObserver.disconnect();
      stableMarkdownObserver.disconnect();
      performanceObserver?.disconnect();
      cancelAnimationFrame(animationFrame);

      const result = {
        complete: true,
        updates,
        durationMs,
        maximumFrameGapMs: maximumFrameGap,
        longTaskCount: longTasks.length,
        longestTaskMs: Math.max(0, ...longTasks),
        visibleTurnBlocks,
        markdownChunks,
        bottomDistance,
        retainedStableTurn,
        retainedStableMarkdown,
        stableTurnMutations,
        stableMarkdownMutations,
        anchorDrift,
        commandPreviewCharacters: commandPreview.length,
        commandPreviewIncludesTail: commandPreview.includes("latest line"),
        imageSizeStable,
      };
      (window as any).__relayHarness = {
        ...result,
        passed: result.durationMs < 2_500
          && result.maximumFrameGapMs < 120
          && result.longTaskCount <= 5
          && result.longestTaskMs < 120
          && result.visibleTurnBlocks === 40
          && result.markdownChunks >= 400
          && result.bottomDistance <= 2
          && result.retainedStableTurn
          && result.retainedStableMarkdown
          && result.stableTurnMutations === 0
          && result.stableMarkdownMutations === 0
          && result.anchorDrift <= 2
          && result.commandPreviewCharacters > 0
          && result.commandPreviewCharacters < 40_000
          && result.commandPreviewIncludesTail
          && result.imageSizeStable,
      };
      setComplete(true);
    };

    const timer = window.setInterval(() => {
      updates += 1;
      setItems((current) => {
        if (updates % 2 === 1) return applyDeltaBatch(current, [{
          id: "message.999",
          turnId: liveTurnId,
          kind: "assistant",
          text: ".",
          detail: "",
        }]);
        const live = current.at(-1)!;
        return mergeSessionPatch(current, [{ ...live, text: `${live.text}.` }], [], liveTurnId);
      });
      transcript.scrollTop = transcript.scrollHeight;
      if (updates === 100) {
        window.clearInterval(timer);
        void finish().catch((error) => {
          (window as any).__relayHarness = {
            complete: true,
            passed: false,
            error: error instanceof Error ? error.stack || error.message : String(error),
          };
          setComplete(true);
        });
      }
    }, 10);

    return () => {
      window.clearInterval(timer);
      cancelAnimationFrame(animationFrame);
      stableTurnObserver.disconnect();
      stableMarkdownObserver.disconnect();
      performanceObserver?.disconnect();
    };
  }, []);

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
