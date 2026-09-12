// THE visual: the curve the borrower signed, as stacked target bands over the health factor,
// with a cursor at her health factor now. As HF falls the cursor slides right and the target is
// wherever the cursor cuts the bands — the target moves because the cursor moves along a rule.
// The basket's actual shares ride the cursor as ticks, so the gap to target is visible on the
// curve itself and closes as fills land.
import { useMemo } from "react";
import { decodeCurve, run, weightsAt, type Frame } from "./run";

const W = 920;
const H = 360;
const PAD = { l: 56, r: 24, t: 20, b: 44 };
const HF_HI = 2.1;
const HF_LO = 1.0;

export const LEG_COLORS = ["#6ea8fe", "#f5a35c", "#5cd68a"];

const x = (hf: number) => PAD.l + ((HF_HI - Math.min(HF_HI, Math.max(HF_LO, hf))) / (HF_HI - HF_LO)) * (W - PAD.l - PAD.r);
const y = (share: number) => PAD.t + (1 - share) * (H - PAD.t - PAD.b);

export function CurveChart({ frame }: { frame: Frame }) {
  const rows = useMemo(() => decodeCurve(run.curve), []);
  const n = rows[0].weights.length;

  // Bands stacked from the debt asset up: USDC at the bottom, then WBTC, WETH on top.
  const bands = useMemo(() => {
    const samples: { hf: number; cum: number[] }[] = [];
    const hfs = [HF_HI, ...rows.map((r) => r.hf), HF_LO].sort((a, b) => b - a);
    for (const hf of hfs) {
      const w = weightsAt(rows, hf);
      const cum: number[] = [];
      let acc = 0;
      for (let l = n - 1; l >= 0; l--) {
        acc += w[l];
        cum[l] = acc;
      }
      samples.push({ hf, cum });
    }
    return Array.from({ length: n }, (_, l) => {
      const top = samples.map((s) => `${x(s.hf).toFixed(1)},${y(s.cum[l]).toFixed(1)}`);
      const bottom = samples
        .slice()
        .reverse()
        .map((s) => `${x(s.hf).toFixed(1)},${y(l + 1 < n ? s.cum[l + 1] : 0).toFixed(1)}`);
      return `M ${top.join(" L ")} L ${bottom.join(" L ")} Z`;
    });
  }, [rows, n]);

  const cx = x(frame.hf);
  // Cumulative target and actual shares at the cursor, from the bottom.
  const cumT: number[] = [];
  const cumS: number[] = [];
  let at = 0;
  let as = 0;
  for (let l = n - 1; l >= 0; l--) {
    at += frame.targets[l];
    as += frame.shares[l];
    cumT[l] = at;
    cumS[l] = as;
  }

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="curve" role="img" aria-label="Target weights as a function of health factor">
      {bands.map((d, l) => (
        <path key={l} d={d} fill={LEG_COLORS[l]} opacity={0.34} />
      ))}
      {rows.map((r) => (
        <line key={r.hf} x1={x(r.hf)} x2={x(r.hf)} y1={PAD.t} y2={H - PAD.b} stroke="#ffffff" strokeOpacity={0.12} strokeDasharray="3 4" />
      ))}
      {/* the zones the badge reads */}
      <rect x={x(HF_HI)} y={H - PAD.b + 26} width={x(1.6) - x(HF_HI)} height={4} fill="#3ad07a" />
      <rect x={x(1.6)} y={H - PAD.b + 26} width={x(1.3) - x(1.6)} height={4} fill="#f2b633" />
      <rect x={x(1.3)} y={H - PAD.b + 26} width={x(HF_LO) - x(1.3)} height={4} fill="#ef5a5a" />
      {[2.0, 1.8, 1.6, 1.45, 1.3, 1.15, 1.0].map((hf) => (
        <text key={hf} x={x(hf)} y={H - PAD.b + 16} className="axis" textAnchor="middle">
          {hf.toFixed(2)}
        </text>
      ))}
      <text x={x(HF_HI)} y={H - PAD.b + 40} className="axis" textAnchor="start">
        health factor, falling → · the curve the borrower signed: target weights at each HF
      </text>
      <text x={x(1.0)} y={H - PAD.b + 40} className="axis danger" textAnchor="end">
        liquidation at 1.00
      </text>
      {[0, 0.25, 0.5, 0.75, 1].map((s) => (
        <text key={s} x={PAD.l - 8} y={y(s) + 4} className="axis" textAnchor="end">
          {Math.round(s * 100)}%
        </text>
      ))}

      {/* the cursor: Alice's health factor now */}
      <g className="cursor" style={{ transform: `translateX(${cx}px)` }}>
        <line x1={0} x2={0} y1={PAD.t - 6} y2={H - PAD.b} stroke="#ffffff" strokeWidth={2} />
        <text x={0} y={PAD.t - 10} className="cursor-label" textAnchor="middle">
          HF {frame.hf.toFixed(2)}
        </text>
        {frame.targets.map((_, l) => {
          const yT = y(cumT[l]);
          const yS = y(cumS[l]);
          return (
            <g key={l}>
              {/* target: where the cursor cuts the band */}
              <circle cx={0} cy={yT} r={6} fill={LEG_COLORS[l]} stroke="#0b0f14" strokeWidth={2} style={{ transition: "cy .6s" }} />
              {/* actual: a tick that slides onto the target as fills land */}
              <line x1={-14} x2={14} y1={yS} y2={yS} stroke={LEG_COLORS[l]} strokeWidth={3} style={{ transition: "y1 .6s, y2 .6s" }} />
              <text x={18} y={yT + 4} className="band-label" fill={LEG_COLORS[l]} style={{ transition: "y .6s" }}>
                {run.symbols[l]} {(frame.targets[l] * 100).toFixed(1)}%
              </text>
            </g>
          );
        })}
      </g>
    </svg>
  );
}
