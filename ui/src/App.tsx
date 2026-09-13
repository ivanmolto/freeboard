// Two modes, one page. REPLAY animates the committed run (results/price-path.json) and needs
// nothing running; LIVE reads a local anvil that ui/walk.sh is walking, block by block. The
// page picks live when it can reach a node with the run's lens deployed, else replays. It only
// looks for a node when served over plain http or given ?rpc= (probe.ts); the hosted https page
// replays without touching 127.0.0.1.
import { useEffect, useMemo, useRef, useState } from "react";
import { Chain, DEFAULT_RPC } from "./chain";
import { CurveChart } from "./CurveChart";
import { Badge, BasketBars, Spread } from "./Panels";
import { probesLocalNode } from "./probe";
import { HardQuestions, PairedControl, REPO, Vessel } from "./Sections";
import { liveFrame, replayFrames, run, type Frame } from "./run";

type Mode = { kind: "replay" } | { kind: "live"; chain: Chain } | { kind: "probing" };

const STEP_MS = 1400;

export function App() {
  const rpc = useMemo(() => new URLSearchParams(location.search).get("rpc") ?? DEFAULT_RPC, []);
  const probes = useMemo(() => probesLocalNode(location), []);
  const [mode, setMode] = useState<Mode>(probes ? { kind: "probing" } : { kind: "replay" });

  // Probe once; re-probe while replaying so a walk started later is picked up.
  useEffect(() => {
    if (!probes) return;
    let stop = false;
    const chain = new Chain(rpc);
    const probe = async () => {
      if (await chain.hasWalk()) {
        if (!stop) setMode({ kind: "live", chain });
        return;
      }
      if (!stop) setMode((m) => (m.kind === "probing" ? { kind: "replay" } : m));
    };
    probe();
    const t = setInterval(() => {
      if (!stop) probe();
    }, 5_000);
    return () => {
      stop = true;
      clearInterval(t);
    };
  }, [rpc, probes]);

  return (
    <div className="app">
      <header>
        <div>
          <h1>Freeboard Finance</h1>
          <p className="tagline">
            The basket's target is a function of the health factor. Watch the <b>target</b> move as HF falls — the basket follows it, and the
            borrower is paid a spread for every step.
          </p>
        </div>
        <ModeTag mode={mode} rpc={rpc} probes={probes} />
      </header>
      {mode.kind === "live" ? <Live chain={mode.chain} /> : <Replay />}
      <PairedControl />
      <HardQuestions />
      <footer>
        Strategy <code>{run.strategyHash.slice(0, 10)}…{run.strategyHash.slice(-4)}</code> on the deployed AquaSwapVMRouter{" "}
        <code>{run.router.slice(0, 8)}…</code>, mainnet fork at block {Number(run.block).toLocaleString("en-US")}. The curve drawn above is
        decoded from the program bytes the strategy commits to; the targets shown are the run's (replay) or the chain's, through{" "}
        <code>FreeboardLens</code> (live). Nothing here touches the debt. Source, tests and artifacts:{" "}
        <a href={REPO}>github.com/ivanmolto/freeboard</a>.
      </footer>
    </div>
  );
}

function ModeTag({ mode, rpc, probes }: { mode: Mode; rpc: string; probes: boolean }) {
  if (mode.kind === "live")
    return (
      <div className="mode live">
        <span className="dot" /> LIVE · anvil at {rpc.replace(/^https?:\/\//, "")}
      </div>
    );
  if (mode.kind === "replay")
    return (
      <div
        className="mode replay"
        title={
          probes
            ? "Run ui/walk.sh against a local anvil to watch it live"
            : "Run ui/walk.sh against a local anvil, then open this page with ?rpc=http://127.0.0.1:8545"
        }
      >
        REPLAY · results/price-path.json · {probes ? "connect a local anvil for live" : "add ?rpc= for a local anvil"}
      </div>
    );
  return <div className="mode probing">looking for a node…</div>;
}

function Stage({ frame }: { frame: Frame }) {
  return (
    <>
      <section className="stage">
        <div className="chart-wrap">
          <CurveChart frame={frame} />
          <div className="caption-row">
            <Vessel hf={frame.hf} />
            <div className="caption">{frame.caption}</div>
          </div>
        </div>
        <aside>
          <Badge frame={frame} />
          <Spread frame={frame} />
        </aside>
      </section>
      <section>
        <BasketBars frame={frame} />
      </section>
    </>
  );
}

function Replay() {
  const frames = useMemo(() => replayFrames(), []);
  const [i, setI] = useState(0);
  const [playing, setPlaying] = useState(true);
  useEffect(() => {
    if (!playing) return;
    const t = setInterval(() => setI((k) => (k + 1 < frames.length ? k + 1 : k)), STEP_MS);
    return () => clearInterval(t);
  }, [playing, frames.length]);
  useEffect(() => {
    if (i === frames.length - 1) setPlaying(false);
  }, [i, frames.length]);
  return (
    <>
      <Stage frame={frames[i]} />
      <div className="controls">
        <button onClick={() => setPlaying((p) => !p)}>{playing ? "pause" : i === frames.length - 1 ? "done" : "play"}</button>
        <button
          onClick={() => {
            setI(0);
            setPlaying(true);
          }}
        >
          restart
        </button>
        <input type="range" min={0} max={frames.length - 1} value={i} onChange={(e) => setI(Number(e.target.value))} />
        <span className="controls-pos">
          {i + 1} / {frames.length}
        </span>
      </div>
    </>
  );
}

function Live({ chain }: { chain: Chain }) {
  const [frame, setFrame] = useState<Frame | null>(null);
  const [error, setError] = useState<string | null>(null);
  const last = useRef<Frame | undefined>(undefined);
  useEffect(() => {
    let stop = false;
    let busy = false;
    const tick = async () => {
      if (busy) return;
      busy = true;
      try {
        const block = await chain.blockNumber();
        if (last.current?.block === block) return;
        const [p, fills] = await Promise.all([chain.position(), chain.fills()]);
        if (stop) return;
        const f = liveFrame(p, fills, block, last.current);
        last.current = f;
        setFrame(f);
        setError(null);
      } catch (e) {
        if (!stop) setError((e as Error).message);
      } finally {
        busy = false;
      }
    };
    tick();
    const t = setInterval(tick, 700);
    return () => {
      stop = true;
      clearInterval(t);
    };
  }, [chain]);
  if (!frame) return <div className="waiting">{error ?? "reading the node…"}</div>;
  return (
    <>
      <Stage frame={frame} />
      {error && <div className="error">{error}</div>}
    </>
  );
}
