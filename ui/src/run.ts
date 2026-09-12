// The committed run, results/price-path.json — emitted by script/PricePath.s.sol and kept
// current by test_PricePath_MatchesTheCommittedArtifact. Every uint256 arrives as a decimal
// string; this file is where they become numbers, and the only place that knows the units.
import committed from "../../results/price-path.json";

export type FillJson = {
  legIn: number;
  legOut: number;
  amountIn: string;
  amountOut: string;
  quotedOut: string;
  fairOut: string;
  valueIn: string;
  spreadValue: string;
  shiftBps: number;
};

export type StepJson = {
  targetHf: string;
  healthFactor: string;
  prices: string[];
  targets: string[];
  balancesBefore: string[];
  balancesAfter: string[];
  sharesAfter: string[];
  totalBefore: string;
  distanceBefore: string;
  distanceAfter: string;
  fills: FillJson[];
};

export type RunJson = {
  strategyHash: string;
  maker: string;
  taker: string;
  extruction: string;
  lens: string;
  router: string;
  aqua: string;
  pool: string;
  tokens: string[];
  symbols: string[];
  decimals: number[];
  curve: string;
  maxShiftBps: number;
  borrowed: string;
  shipped: string[];
  fills: number;
  spreadValue: string;
  startHealthFactor: string;
  finalHealthFactor: string;
  finalBalances: string[];
  /// The block the run was recorded at — the pinned fork block. A plain number: it fits.
  block: number;
  steps: StepJson[];
};

export const run: RunJson = committed as RunJson;

export const WAD = 10n ** 18n;
/// One US dollar in the extruction's value units: price (1e8) times 1e18.
export const VALUE_PER_USD = 10n ** 26n;

export const wad = (x: string | bigint): number => Number((BigInt(x) * 1_000_000n) / WAD) / 1_000_000;
/// Rounded to the cent. Sums are taken in value units FIRST and rounded once (see Frame.spreadUsd).
export const usd = (value: string | bigint): number => Number((BigInt(value) * 100n + VALUE_PER_USD / 2n) / VALUE_PER_USD) / 100;

/// Value units per wei of leg `l` at `price` (1e8): `price * 10 ** (18 - decimals)`.
export const unit = (l: number, price: string | bigint): bigint => BigInt(price) * 10n ** BigInt(18 - run.decimals[l]);

export const amount = (x: string | bigint, l: number): number => {
  const places = [4, 6, 2][l];
  const d = 10n ** BigInt(run.decimals[l] - places);
  return Number((BigInt(x) + d / 2n) / d) / 10 ** places;
};

export const fmtAmount = (x: string | bigint, l: number): string =>
  amount(x, l).toLocaleString("en-US", { minimumFractionDigits: [4, 6, 2][l], maximumFractionDigits: [4, 6, 2][l] }) +
  " " +
  run.symbols[l];

export const fmtUsd = (x: number): string => "$" + x.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
export const fmtPct = (share: number): string => (share * 100).toFixed(2) + "%";
export const fmtHf = (hf: number): string => hf.toFixed(2);

// ---------------------------------------------------------------------------------------
// The curve, decoded from the bytes the program carries (src/libs/Curve.sol, "PACKED BYTE
// LAYOUT"): uint8 m, uint8 n, then m rows of [uint64 hf][uint64 weight] * n, all WAD.
// ---------------------------------------------------------------------------------------

export type CurveRow = { hf: number; weights: number[] };

export function decodeCurve(hex: string): CurveRow[] {
  const bytes = hex.startsWith("0x") ? hex.slice(2) : hex;
  const m = parseInt(bytes.slice(0, 2), 16);
  const n = parseInt(bytes.slice(2, 4), 16);
  const rows: CurveRow[] = [];
  let at = 4;
  const u64 = () => {
    const v = BigInt("0x" + bytes.slice(at, at + 16));
    at += 16;
    return v;
  };
  for (let r = 0; r < m; r++) {
    const hf = wad(u64());
    const weights: number[] = [];
    for (let l = 0; l < n; l++) weights.push(wad(u64()));
    rows.push({ hf, weights });
  }
  return rows;
}

/// The curve's rule in floating point, for DRAWING only: clamped outside the breakpoints,
/// linear between them. The targets the page displays come from the run or the chain.
export function weightsAt(rows: CurveRow[], hf: number): number[] {
  if (hf >= rows[0].hf) return rows[0].weights;
  const last = rows[rows.length - 1];
  if (hf <= last.hf) return last.weights;
  for (let r = 0; r + 1 < rows.length; r++) {
    const hi = rows[r];
    const lo = rows[r + 1];
    if (hf <= hi.hf && hf >= lo.hf) {
      const t = (hf - lo.hf) / (hi.hf - lo.hf);
      return lo.weights.map((w, l) => w + (hi.weights[l] - w) * t);
    }
  }
  return last.weights;
}

// ---------------------------------------------------------------------------------------
// Frames: what the page shows at one instant, in either mode.
// ---------------------------------------------------------------------------------------

export type FillView = {
  legIn: number;
  legOut: number;
  amountIn: bigint;
  amountOut: bigint;
  /// What the borrower kept, value units — exact; `spreadUsd` is its display.
  spreadValue: bigint;
  spreadUsd: number;
  shiftBps: number;
  block?: number;
};

export type Frame = {
  /// Alice's health factor, as a number.
  hf: number;
  /// Target shares, 0..1, per leg.
  targets: number[];
  /// Actual shares, 0..1, per leg.
  shares: number[];
  /// Leg values in USD.
  valuesUsd: number[];
  totalUsd: number;
  /// Weighted L1 distance to target, 0..1.
  distance: number;
  /// Spread the borrower has earned so far, USD.
  spreadUsd: number;
  fills: FillView[];
  /// What just happened, for the caption.
  caption: string;
  /// Live only.
  block?: number;
};

function sharesOf(values: bigint[]): { shares: number[]; valuesUsd: number[]; totalUsd: number } {
  const total = values.reduce((a, b) => a + b, 0n);
  return {
    shares: values.map((v) => (total === 0n ? 0 : Number((v * 1_000_000n) / total) / 1_000_000)),
    valuesUsd: values.map((v) => usd(v)),
    totalUsd: usd(total),
  };
}

function distanceOf(shares: number[], targets: number[]): number {
  return shares.reduce((d, s, l) => d + Math.abs(s - targets[l]), 0) / 2;
}

/// The committed run as a sequence of frames: one as each rung is reached (the oracle moved,
/// the target slid, the basket has not yet), then one per fill.
export function replayFrames(): Frame[] {
  const frames: Frame[] = [];
  let spread = 0n;
  const fills: FillView[] = [];
  for (const step of run.steps) {
    const hf = wad(step.healthFactor);
    const targets = step.targets.map(wad);
    const units = step.prices.map((p, l) => unit(l, p));
    const balances = step.balancesBefore.map((b) => BigInt(b));
    const values = balances.map((b, l) => b * units[l]);
    let v = sharesOf(values);
    frames.push({
      hf,
      targets,
      ...v,
      distance: distanceOf(v.shares, targets),
      spreadUsd: usd(spread),
      fills: [...fills],
      caption:
        step.fills.length === 0
          ? `HF ${fmtHf(hf)} — the basket is at its target; nothing to take`
          : `HF ${fmtHf(hf)} — the oracle moved, the target slid; a taker arrives`,
    });
    for (const f of step.fills) {
      balances[f.legIn] += BigInt(f.amountIn);
      balances[f.legOut] -= BigInt(f.amountOut);
      spread += BigInt(f.spreadValue);
      const view: FillView = {
        legIn: f.legIn,
        legOut: f.legOut,
        amountIn: BigInt(f.amountIn),
        amountOut: BigInt(f.amountOut),
        spreadValue: BigInt(f.spreadValue),
        spreadUsd: usd(f.spreadValue),
        shiftBps: f.shiftBps,
      };
      fills.push(view);
      v = sharesOf(balances.map((b, l) => b * units[l]));
      frames.push({
        hf,
        targets,
        ...v,
        distance: distanceOf(v.shares, targets),
        spreadUsd: usd(spread),
        fills: [...fills],
        caption: `${fmtAmount(view.amountIn, view.legIn)} in, ${fmtAmount(view.amountOut, view.legOut)} out — the borrower keeps ${fmtUsd(view.spreadUsd)}`,
      });
    }
  }
  return frames;
}

/// A frame from a live read (see chain.ts): the lens's position plus the fills seen so far.
export function liveFrame(
  p: { healthFactor: bigint; prices: bigint[]; balances: bigint[]; targets: bigint[] },
  fills: FillView[],
  block: number,
  previous?: Frame,
): Frame {
  const hf = p.healthFactor >= 2n ** 128n ? 99 : wad(p.healthFactor);
  const targets = p.targets.map(wad);
  const values = p.balances.map((b, l) => b * unit(l, p.prices[l]));
  const v = sharesOf(values);
  const spreadUsd = usd(fills.reduce((a, f) => a + f.spreadValue, 0n));
  const last = fills[fills.length - 1];
  let caption = `block ${block.toLocaleString("en-US")} — HF ${fmtHf(hf)}`;
  if (previous && fills.length > previous.fills.length && last) {
    caption = `${fmtAmount(last.amountIn, last.legIn)} in, ${fmtAmount(last.amountOut, last.legOut)} out — the borrower keeps ${fmtUsd(last.spreadUsd)}`;
  } else if (previous && Math.abs(previous.hf - hf) > 0.005) {
    caption = `HF ${fmtHf(previous.hf)} → ${fmtHf(hf)} — the oracle moved, the target slid`;
  }
  return { hf, targets, ...v, distance: distanceOf(v.shares, targets), spreadUsd, fills, caption, block };
}
