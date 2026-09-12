// Live mode: the page reads a node that is walking the price path (ui/walk.sh on anvil).
// Everything comes from the chain — the health factor, the prices, the legs and the TARGET
// through FreeboardLens (the repo's own Curve.weightsAt, not a TypeScript copy), and the fills
// from the router's Swapped events, each valued at the oracle prices of its own block.
import { createPublicClient, http, parseAbi, parseAbiItem, type PublicClient } from "viem";
import { run, unit, usd, type FillView } from "./run";

export const DEFAULT_RPC = "http://127.0.0.1:8545";

const lensAbi = parseAbi([
  "struct Position { uint256 healthFactor; uint256[] prices; uint256[] balances; uint256[] units; uint256[] values; uint256 total; uint256[] targets; uint256 distance; }",
  "function read(address maker, bytes32 strategyHash, address[] tokens, bytes curve) view returns (Position p)",
]);

// swap-vm v1.0.2 src/SwapVM.sol:54 — no indexed parameters, so the order hash is filtered here.
const swapped = parseAbiItem(
  "event Swapped(bytes32 orderHash, address maker, address taker, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)",
);

export type Position = {
  healthFactor: bigint;
  prices: bigint[];
  balances: bigint[];
  targets: bigint[];
};

export class Chain {
  readonly client: PublicClient;
  private readonly seen = new Map<string, FillView>();

  constructor(readonly rpc: string) {
    this.client = createPublicClient({ transport: http(rpc, { timeout: 4_000, retryCount: 0 }) });
  }

  /// True when the node is up, is a mainnet fork, and the lens the run pins is deployed on it —
  /// i.e. ui/walk.sh has started (or finished) a walk there.
  async hasWalk(): Promise<boolean> {
    try {
      const [chainId, code] = await Promise.all([
        this.client.getChainId(),
        this.client.getCode({ address: run.lens as `0x${string}` }),
      ]);
      return chainId === 1 && !!code && code !== "0x";
    } catch {
      return false;
    }
  }

  async blockNumber(): Promise<number> {
    return Number(await this.client.getBlockNumber());
  }

  async position(blockNumber?: bigint): Promise<Position> {
    const p = await this.client.readContract({
      address: run.lens as `0x${string}`,
      abi: lensAbi,
      functionName: "read",
      args: [run.maker as `0x${string}`, run.strategyHash as `0x${string}`, run.tokens as `0x${string}`[], run.curve as `0x${string}`],
      blockNumber,
    });
    return { healthFactor: p.healthFactor, prices: [...p.prices], balances: [...p.balances], targets: [...p.targets] };
  }

  /// Every fill of the run's strategy so far, oldest first, each priced at its own block.
  async fills(): Promise<FillView[]> {
    const logs = await this.client.getLogs({
      address: run.router as `0x${string}`,
      event: swapped,
      fromBlock: BigInt(run.block),
      toBlock: "latest",
    });
    const mine = logs.filter((l) => l.args.orderHash?.toLowerCase() === run.strategyHash.toLowerCase());
    for (const l of mine) {
      const key = `${l.transactionHash}:${l.logIndex}`;
      if (this.seen.has(key)) continue;
      const legIn = run.tokens.findIndex((t) => t.toLowerCase() === l.args.tokenIn!.toLowerCase());
      const legOut = run.tokens.findIndex((t) => t.toLowerCase() === l.args.tokenOut!.toLowerCase());
      const at = await this.position(l.blockNumber);
      const valueIn = l.args.amountIn! * unit(legIn, at.prices[legIn]);
      const valueOut = l.args.amountOut! * unit(legOut, at.prices[legOut]);
      const total = at.balances.reduce((a, b, i) => a + b * unit(i, at.prices[i]), 0n);
      // The basket the fill was priced against is the one BEFORE it: add the fill back.
      const before = total - l.args.amountIn! * unit(legIn, at.prices[legIn]) + l.args.amountOut! * unit(legOut, at.prices[legOut]);
      this.seen.set(key, {
        legIn,
        legOut,
        amountIn: l.args.amountIn!,
        amountOut: l.args.amountOut!,
        spreadValue: valueIn > valueOut ? valueIn - valueOut : 0n,
        spreadUsd: valueIn > valueOut ? usd(valueIn - valueOut) : 0,
        shiftBps: before === 0n ? 0 : Number((valueIn * 10_000n + before - 1n) / before),
        block: Number(l.blockNumber),
      });
    }
    return [...this.seen.values()].sort((a, b) => a.block! - b.block!);
  }
}
