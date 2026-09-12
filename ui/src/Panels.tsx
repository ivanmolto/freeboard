import { LEG_COLORS } from "./CurveChart";
import { fmtAmount, fmtHf, fmtPct, fmtUsd, run, type Frame } from "./run";

/// Green at or above the curve's 1.60 row, amber down to 1.30, red below: the badge reads the
/// curve's own breakpoints, not levels of its own.
export function zone(hf: number): "green" | "amber" | "red" {
  // The pool lands a rung a few parts in 1e12 under it (Aave's 1e8 grid); 1.5999999999 is 1.60.
  const eps = 1e-6;
  return hf >= 1.6 - eps ? "green" : hf >= 1.3 - eps ? "amber" : "red";
}

export function Badge({ frame }: { frame: Frame }) {
  const z = zone(frame.hf);
  const word = z === "green" ? "freeboard" : z === "amber" ? "taking water" : "deleveraging";
  return (
    <div className={`badge ${z}`}>
      <div className="badge-hf">{frame.hf > 50 ? "∞" : fmtHf(frame.hf)}</div>
      <div className="badge-text">
        <div className="badge-word">{word}</div>
        <div className="badge-sub">health factor · Aave v3</div>
      </div>
    </div>
  );
}

/// Basket against target: a ghost bar at the target share behind a solid bar at the actual
/// share, per leg. Both slide; the ghost slides when the oracle moves, the solid when a fill lands.
export function BasketBars({ frame }: { frame: Frame }) {
  return (
    <div className="bars">
      {run.symbols.map((sym, l) => {
        const actual = frame.shares[l];
        const target = frame.targets[l];
        const gap = actual - target;
        return (
          <div className="bar-row" key={sym}>
            <div className="bar-sym" style={{ color: LEG_COLORS[l] }}>
              {sym}
            </div>
            <div className="bar-track">
              <div className="bar-ghost" style={{ width: `${target * 100}%`, borderColor: LEG_COLORS[l] }} />
              <div className="bar-solid" style={{ width: `${actual * 100}%`, background: LEG_COLORS[l] }} />
              <div className="bar-target-tick" style={{ left: `${target * 100}%` }} />
            </div>
            <div className="bar-nums">
              <span className="bar-actual">{fmtPct(actual)}</span>
              <span className="bar-vs">of target {fmtPct(target)}</span>
              <span className={`bar-gap ${Math.abs(gap) < 0.0005 ? "ok" : gap > 0 ? "over" : "under"}`}>
                {Math.abs(gap) < 0.0005 ? "at target" : `${gap > 0 ? "+" : "−"}${(Math.abs(gap) * 100).toFixed(2)} pts`}
              </span>
            </div>
          </div>
        );
      })}
      <div className="bars-foot">
        basket {fmtUsd(frame.totalUsd)} · distance to target {fmtPct(frame.distance)}
      </div>
    </div>
  );
}

export function Spread({ frame }: { frame: Frame }) {
  const recent = frame.fills.slice(-6).reverse();
  return (
    <div className="spread">
      <div className="spread-head">
        <div className="spread-usd">{fmtUsd(frame.spreadUsd)}</div>
        <div className="spread-sub">
          spread earned by the borrower · {frame.fills.length} {frame.fills.length === 1 ? "fill" : "fills"}
        </div>
      </div>
      <ol className="fills">
        {recent.map((f, i) => (
          <li key={frame.fills.length - i} className={i === 0 ? "fill new" : "fill"}>
            <span className="fill-in" style={{ color: LEG_COLORS[f.legIn] }}>
              {fmtAmount(f.amountIn, f.legIn)}
            </span>
            <span className="fill-arrow">→</span>
            <span className="fill-out" style={{ color: LEG_COLORS[f.legOut] }}>
              {fmtAmount(f.amountOut, f.legOut)}
            </span>
            <span className="fill-spread">+{fmtUsd(f.spreadUsd)}</span>
            <span className="fill-shift">{f.shiftBps} bps of {run.maxShiftBps}</span>
          </li>
        ))}
        {recent.length === 0 && <li className="fill none">no fills yet — at the top row the basket is the target</li>}
      </ol>
    </div>
  );
}
