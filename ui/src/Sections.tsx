// The vessel, the money table and the hard questions — the parts of the page that are not the
// animation. The table is parsed from results/paired-control.txt at build time, so the page shows
// the committed artifact's rows, not a copy of them; it goes stale only if the artifact does,
// and test_PairedControl_MatchesTheCommittedArtifact keeps the artifact current.
import { useState } from "react";
import pairedControl from "../../results/paired-control.txt?raw";
import { zone } from "./Panels";

export const REPO = "https://github.com/ivanmolto/freeboard";

/// The brand's four states: the waterline rises toward the deck as the health factor falls.
/// Which one shows follows the badge's zones — the curve's rows, not levels of its own — with
/// the green zone split at 1.80 so the top of the path and the first drop read differently.
export function vesselState(hf: number): "200" | "160" | "130" | "115" {
  const z = zone(hf);
  if (z === "green") return hf >= 1.8 - 1e-6 ? "200" : "160";
  return z === "amber" ? "130" : "115";
}

export function Vessel({ hf }: { hf: number }) {
  const state = vesselState(hf);
  return (
    <div className="vessel" title={`Freeboard at HF ${hf > 50 ? "∞" : hf.toFixed(2)}`}>
      {(["200", "160", "130", "115"] as const).map((s) => (
        <img key={s} src={`/brand/freeboard-state-hf-${s}.svg`} alt="" className={s === state ? "on" : ""} width={64} height={64} />
      ))}
    </div>
  );
}

// ---------------------------------------------------------------------------------------
// The money table
// ---------------------------------------------------------------------------------------

type Row = { label: string; unguarded: string; freeboard: string; indent: boolean };

function parseTable(text: string): Row[] {
  return text
    .split("\n")
    .filter((l) => l.startsWith("|") && !l.startsWith("|--") && !l.includes("Unguarded"))
    .map((l) => {
      const cells = l.split("|").slice(1, -1);
      return {
        label: cells[0].trim(),
        unguarded: cells[1].trim(),
        freeboard: cells[2].trim(),
        indent: cells[0].startsWith("   "),
      };
    });
}

/// The rows a visitor needs, in the artifact's order and wording. The two "same number twice"
/// rows stay in so the table cannot be read as a health-factor claim.
const SHOWN = [
  "Final health factor",
  "Liquidated",
  "Spread earned on the way down",
  "Realized price vs oracle, over all fills",
  "Basket value at the bottom",
  "vs holding the shipped basket untouched",
  "Basket at the bottom: USDC (the debt asset)",
  "She repays her USDC debt with the basket's USDC",
  "health factor after",
];

export function PairedControl() {
  const rows = parseTable(pairedControl).filter((r) => SHOWN.includes(r.label));
  const money = (s: string) => (s.startsWith("-") ? "neg" : s.startsWith("+") ? "pos" : "");
  return (
    <section className="table-wrap">
      <h2>Same path, one instruction of difference</h2>
      <p className="lede">
        Same wallet, same Aave position, same oracle path HF 2.00 → 1.10, same taker, the same $80,000 through the deployed Aqua and
        router. One instruction in the shipped program differs: swap-vm's stock constant-product swap, or Freeboard Finance's curve. The stock
        basket buys the falling asset and pays its takers to do it; Freeboard Finance arrives at the bottom holding the debt asset, paid on the
        way. Neither arm touches the debt, so the first two rows are the same number twice — the basket is not Aave collateral.
      </p>
      <table>
        <thead>
          <tr>
            <th></th>
            <th>Unguarded (stock swap)</th>
            <th>Freeboard Finance</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.label} className={r.indent ? "indent" : ""}>
              <td>{r.label}</td>
              <td className={money(r.unguarded)}>{r.unguarded}</td>
              <td className={money(r.freeboard)}>{r.freeboard}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="source">
        From{" "}
        <a href={`${REPO}/blob/main/results/paired-control.txt`}>
          <code>results/paired-control.txt</code>
        </a>
        , emitted by <code>script/PairedControl.s.sol</code> on the mainnet fork; every stock fill replayed against swap-vm's own
        <code> XYCSwap.sol</code> to the wei. The last two rows are her own action, taken identically in both arms — Freeboard Finance never
        repays; it puts the USDC in her hand.
      </p>
    </section>
  );
}

// ---------------------------------------------------------------------------------------
// Hard questions — the README's short form
// ---------------------------------------------------------------------------------------

const QUESTIONS: { q: string; a: string; test?: string }[] = [
  {
    q: "The curve is public. Isn't it front-runnable?",
    a: "Front-running a rule needs a moment worth waiting for, and a continuous curve has none: the basket sells a little at every health factor, so there is no cliff to wait at. The health factor cannot be pushed — it moves with Aave's oracle and the borrower's own debt. Front-running another taker's fill hurts that taker, not the borrower. And no fill ever beats the oracle, so there is no price below fair to drain at. A public curve means more takers compete for the same fill, which is what protects the borrower.",
  },
  {
    q: "What if the health factor is wrong?",
    a: "One fill moves at most maxShiftBps of the basket's value, whatever the cause — checked after pricing, on the amounts that settle, in any direction.",
    test: "test_AWrongHealthFactor_CannotRestructureTheBasketInOneFill · testFuzz_EveryFillInAnySequence_IsWithinTheCap",
  },
  {
    q: "Isn't this a stop-loss?",
    a: "A price floor stops you trading at the moment you most need to trade — the same cliff as a liquidation trigger. Freeboard Finance has no level at which it refuses; it re-prices, so the deleveraging direction gets progressively cheaper as the health factor falls.",
    test: "test_AsHealthFactorFalls_TheDeleveragingFillBecomesTheCheapOne",
  },
  {
    q: "Why no keeper or enclave in the pricing path?",
    a: "Each is a liveness dependency on a liquidation guard. Freeboard Finance has no writer: move the oracle and the next fill prices against the new target with nobody having written anything in between.",
    test: "test_EndToEnd_TheNextFillPricesAgainstTheNewTarget_WithNobodyWritingInBetween",
  },
  {
    q: "Can a taker drain the basket over many small fills?",
    a: "Not below fair value, and not into an arbitrary composition: no fill beats the oracle, and the cap applies to each fill against the live basket. Splitting a fill buys at most 0.9 bps of the first slice, and only across a target crossing — measured on the deployed router, and the single fill is the one that overcharges.",
    test: "testFuzz_ASplitFill_PaysAtLeastTheSingleFill_AndAtMostTheBoundMore · test_Additivity_TheGapIsTheSpreadTheSingleFillsModelDropped",
  },
  {
    q: "Does it touch my debt?",
    a: "Never. No supply, borrow or repay, and the Aave position itself is untouched — only what the basket beside the loan is made of.",
  },
];

export function HardQuestions() {
  const [open, setOpen] = useState<number | null>(0);
  return (
    <section className="questions">
      <h2>Hard questions</h2>
      <p className="lede">
        Answered against the tests rather than asserted. The full set — including what is honestly open — is in{" "}
        <a href={`${REPO}/blob/main/docs/hard-questions.md`}>
          <code>docs/hard-questions.md</code>
        </a>
        .
      </p>
      <dl>
        {QUESTIONS.map((item, i) => (
          <div key={item.q} className={open === i ? "qa open" : "qa"}>
            <dt>
              <button onClick={() => setOpen(open === i ? null : i)} aria-expanded={open === i}>
                {item.q}
              </button>
            </dt>
            <dd hidden={open !== i}>
              <p>{item.a}</p>
              {item.test && <code className="test">{item.test}</code>}
            </dd>
          </div>
        ))}
      </dl>
    </section>
  );
}
