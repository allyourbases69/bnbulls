'use client';

/**
 * DuelReplay — a settled fight, actually playing.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THE ANIMATION IS THE PROOF, NOT DECORATION.
 * ═══════════════════════════════════════════════════════════════════════
 * `/api/duel-gif` re-simulates the fight from the seed in its own
 * `DuelCompleted` event and **refuses with a 409 when the re-run disagrees with
 * the chain** (`lib/duelReplaySource.ts`). So a refusal is not a broken image,
 * it is the guard working, and this component says so in words. Nothing here
 * may ever fall back to "show something anyway" — a replay that contradicts the
 * chain would be a lie about somebody's money.
 *
 * That is also why the fetch is done by hand instead of pointing an `<img src>`
 * straight at the route: `onError` tells you nothing, while a refusal comes
 * back as JSON with a real reason and a real sentence.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * TWO SHAPES, ONE FETCH
 * ═══════════════════════════════════════════════════════════════════════
 *   `DuelReplayInline` — loads on mount and plays in place. This is the live
 *      fight: you settled it, you watch it, no click.
 *   `DuelReplayButton` — "▶ replay" on a history row, opening a modal. Nothing
 *      is requested until it is clicked, because every render costs the server
 *      a fight simulation plus a GIF encode and a fifty-row page must not fire
 *      fifty of them just by existing.
 *
 * ⚠ THIS COMPONENT DRAWS NOTHING ITSELF. The renderer is `lib/duelReplay.ts`,
 * server-side, and it is the ONLY one (`BNBULLS-BOOTSTRAP.md §5`) — the site
 * and the telegram bot pull the same URL so the two can never show different
 * winners for the same fight. Do not add a second renderer here.
 */
import { useCallback, useEffect, useRef, useState } from 'react';

// ─── the URL ──────────────────────────────────────────────────────────

/**
 * The shareable link. Paste it in telegram or on X and it plays there too, with
 * no player and no download, which is the whole point of shipping the replay as
 * a GIF rather than a canvas.
 *
 * ⚠ NO `chain` PARAM. Fefers' route takes one; ours does not — bnbulls'
 * `/api/duel-gif` reads its chain from the server env (`serverEnv.ts`), so
 * adding `&chain=` here would be a query string the route quietly ignores.
 */
export function duelReplayUrl(txHash: string, logIndex?: number | null): string {
  const q = new URLSearchParams({ tx: txHash });
  if (logIndex !== null && logIndex !== undefined) q.set('log', String(logIndex));
  return `/api/duel-gif?${q.toString()}`;
}

// ─── fetching ─────────────────────────────────────────────────────────

/**
 * Reasons worth asking again about. All three mean "this node has not caught up
 * yet", which is the normal state for a few seconds after a fight settles: your
 * wallet's rpc confirmed the transaction, ours has not necessarily seen it.
 *
 * ⚠ `mismatch` IS NOT IN HERE AND MUST NEVER BE. A 409 is a settled answer, not
 * a slow one, and retrying it would just burn the server's cpu re-proving the
 * same disagreement.
 */
const TRANSIENT_REASONS: ReadonlySet<string> = new Set(['not-found', 'no-duel', 'rpc']);
const RETRY_MS = 2_500;
/** Only the live fight retries; a history row asks once. */
const LIVE_RETRIES = 3;

/** The route's own default upscale: 200x150 logical -> 800x600. Used to cap the
 *  display width so the gif never has to be blown up past native, which is
 *  where pixel art turns to mush. */
const NATIVE_W = 800;

class ReplayRefused extends Error {
  readonly reason: string | null;
  constructor(message: string, reason: string | null) {
    super(message);
    this.name = 'ReplayRefused';
    this.reason = reason;
  }
}

async function readRefusal(res: Response): Promise<ReplayRefused> {
  let message = `the replay could not be built (http ${res.status}).`;
  let reason: string | null = null;
  try {
    const body = (await res.json()) as { error?: unknown; reason?: unknown };
    if (typeof body.error === 'string' && body.error.length > 0) message = body.error;
    if (typeof body.reason === 'string' && body.reason.length > 0) reason = body.reason;
  } catch {
    /* not json — the status code is all there is */
  }
  return new ReplayRefused(message, reason);
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(new DOMException('aborted', 'AbortError'));
      return;
    }
    const onAbort = () => {
      clearTimeout(timer);
      reject(new DOMException('aborted', 'AbortError'));
    };
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    signal.addEventListener('abort', onAbort, { once: true });
  });
}

async function fetchReplay(url: string, signal: AbortSignal, retries: number): Promise<Blob> {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(url, { signal });
    if (res.ok) return await res.blob();
    const refusal = await readRefusal(res);
    const transient = refusal.reason !== null && TRANSIENT_REASONS.has(refusal.reason);
    if (!transient || attempt >= retries) throw refusal;
    await sleep(RETRY_MS, signal);
  }
}

type ReplayState =
  | { kind: 'idle' }
  | { kind: 'loading' }
  | { kind: 'ready'; objectUrl: string }
  | { kind: 'error'; message: string; reason: string | null };

function useDuelReplayGif(shareUrl: string, retries: number) {
  const [state, setState] = useState<ReplayState>({ kind: 'idle' });
  // Held in refs as well as in state so unmount can revoke the blob and stop
  // the fetch without the effect depending on (and re-running for) either.
  const objectUrlRef = useRef<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  /** The url we have already started, so reopening a loaded replay is free. */
  const startedRef = useRef<string | null>(null);

  const release = useCallback(() => {
    if (objectUrlRef.current !== null) {
      URL.revokeObjectURL(objectUrlRef.current);
      objectUrlRef.current = null;
    }
  }, []);

  // A different fight is a different replay: drop the old blob, stop the old
  // fetch, and let the latch below arm again. Also the unmount path.
  useEffect(() => {
    startedRef.current = null;
    setState({ kind: 'idle' });
    return () => {
      abortRef.current?.abort();
      release();
    };
  }, [shareUrl, release]);

  const load = useCallback(() => {
    if (startedRef.current === shareUrl) return;
    startedRef.current = shareUrl;
    abortRef.current?.abort();
    const ctl = new AbortController();
    abortRef.current = ctl;
    setState({ kind: 'loading' });
    void (async () => {
      try {
        const blob = await fetchReplay(shareUrl, ctl.signal, retries);
        if (ctl.signal.aborted) return;
        release();
        const objectUrl = URL.createObjectURL(blob);
        objectUrlRef.current = objectUrl;
        setState({ kind: 'ready', objectUrl });
      } catch (e) {
        if (ctl.signal.aborted) return;
        // Un-latch so "try again" can actually try again.
        startedRef.current = null;
        if (e instanceof ReplayRefused) {
          setState({ kind: 'error', message: e.message, reason: e.reason });
        } else {
          setState({
            kind: 'error',
            message: e instanceof Error ? e.message : String(e),
            reason: null,
          });
        }
      }
    })();
  }, [shareUrl, retries, release]);

  return { state, load };
}

// ─── the stage ────────────────────────────────────────────────────────

function Loading() {
  return (
    <p className="py-10 text-center font-mono text-sm text-bull-text-dim">
      rebuilding the fight from its seed…
    </p>
  );
}

/**
 * A refusal, in words.
 *
 * ⚠ THE 409 GETS ITS OWN SENTENCE, and it is not an apology. It is the one
 * failure that means the system worked: the replay was re-run from the signed
 * seed, it did not match what the chain recorded, and it refused to draw a
 * fight that never happened.
 */
function Refusal({
  message,
  reason,
  onRetry,
}: {
  message: string;
  reason: string | null;
  onRetry?: () => void;
}) {
  const mismatch = reason === 'mismatch';
  return (
    <div className="space-y-2 py-6 text-center">
      <p className="bull-header text-xs uppercase tracking-wider text-bull-gold">
        {mismatch ? 'this one does not add up' : 'no replay for this one'}
      </p>
      {mismatch && (
        <p className="mx-auto max-w-md text-sm text-bull-text-dim">
          the fight was re-run from its own seed and it did not land on the same winner the
          chain recorded, so there is nothing honest to show. the animation is the receipt,
          not the decoration, and a pretty lie is worse than no picture.
        </p>
      )}
      <p className="mx-auto max-w-md break-words font-mono text-xs text-bull-text-faint">
        {message}
      </p>
      {onRetry && !mismatch && (
        <button
          type="button"
          onClick={onRetry}
          className="rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim transition hover:border-bull-gold hover:text-bull-gold"
        >
          try again
        </button>
      )}
    </div>
  );
}

function ReplayFilm({ objectUrl, shareUrl }: { objectUrl: string; shareUrl: string }) {
  return (
    <>
      {/* eslint-disable-next-line @next/next/no-img-element -- an animated gif
          must not go through next/image, which re-encodes it to a still frame.
          `.pixel` is the site-wide "never smooth pixel art" rule
          (globals.css), and the width cap keeps it at or under native size. */}
      <img
        src={objectUrl}
        alt="animated replay of the fight"
        className="pixel mx-auto block w-full"
        style={{ maxWidth: NATIVE_W }}
      />
      <p className="flex flex-wrap items-center justify-between gap-2 text-xs">
        <a
          href={shareUrl}
          target="_blank"
          rel="noreferrer"
          className="text-bull-gold hover:underline"
        >
          open the gif ↗
        </a>
        <span className="text-bull-text-faint">paste that link anywhere and it plays</span>
      </p>
    </>
  );
}

// ─── the live fight ───────────────────────────────────────────────────

/**
 * The replay, playing in place, no click. Point this at a fight the moment it
 * settles.
 *
 * ⚠ IT RETRIES THE TRANSIENT REFUSALS ON PURPOSE. The wallet's rpc confirmed
 * the transaction; the server's rpc has not necessarily seen it yet, so the
 * first ask right after settlement often comes back "no transaction". Without
 * the retry the live replay would 404 on a fight that is definitely real, which
 * looks exactly like the mismatch guard firing and is not.
 */
export function DuelReplayInline({
  txHash,
  logIndex = null,
  className = '',
  heading = 'the fight',
}: {
  txHash: string;
  logIndex?: number | null;
  className?: string;
  heading?: string;
}) {
  const shareUrl = duelReplayUrl(txHash, logIndex);
  const { state, load } = useDuelReplayGif(shareUrl, LIVE_RETRIES);

  useEffect(() => {
    load();
  }, [load]);

  return (
    <div className={`rounded border border-bull-border bg-bull-panel p-3 ${className}`}>
      <p className="bull-header mb-2 text-xs uppercase tracking-wider text-bull-gold">{heading}</p>
      {state.kind === 'loading' && <Loading />}
      {state.kind === 'error' && (
        <Refusal message={state.message} reason={state.reason} onRetry={load} />
      )}
      {state.kind === 'ready' && (
        <div className="space-y-2">
          <ReplayFilm objectUrl={state.objectUrl} shareUrl={shareUrl} />
        </div>
      )}
    </div>
  );
}

// ─── the history row ──────────────────────────────────────────────────

/** "▶ replay" on a row of fight history. Fetches nothing until it is clicked. */
export function DuelReplayButton({
  txHash,
  logIndex = null,
  compact = false,
}: {
  txHash: string;
  logIndex?: number | null;
  /** Drops the word and keeps the glyph, for tight rows. */
  compact?: boolean;
}) {
  const shareUrl = duelReplayUrl(txHash, logIndex);
  const { state, load } = useDuelReplayGif(shareUrl, 0);
  const [open, setOpen] = useState(false);

  const close = useCallback(() => setOpen(false), []);

  const openAndLoad = useCallback(() => {
    setOpen(true);
    load();
  }, [load]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, close]);

  return (
    <>
      <button
        type="button"
        onClick={openAndLoad}
        title="watch this fight"
        className="whitespace-nowrap font-mono text-xs text-bull-text-dim transition-colors hover:text-bull-gold"
      >
        ▶{compact ? '' : ' replay'}
      </button>

      {open && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-bull-bg/90 p-4"
          onClick={close}
          role="presentation"
        >
          <div
            className="w-full max-w-3xl space-y-3 rounded border border-bull-border bg-bull-panel p-4"
            onClick={(e) => e.stopPropagation()}
            role="dialog"
            aria-modal="true"
            aria-label="fight replay"
          >
            <div className="flex items-center justify-between gap-3">
              <span className="bull-header text-xs uppercase tracking-wider text-bull-gold">
                the fight
              </span>
              <button
                type="button"
                onClick={close}
                className="font-mono text-xs text-bull-text-dim hover:text-bull-gold"
              >
                close ✕
              </button>
            </div>

            {state.kind === 'loading' && <Loading />}
            {state.kind === 'error' && (
              <Refusal message={state.message} reason={state.reason} onRetry={load} />
            )}
            {state.kind === 'ready' && (
              <ReplayFilm objectUrl={state.objectUrl} shareUrl={shareUrl} />
            )}
          </div>
        </div>
      )}
    </>
  );
}
