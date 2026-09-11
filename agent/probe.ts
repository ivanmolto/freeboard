// Tool probe: exercises the keeper's three tools against the staged anvil world WITHOUT a
// model, so the plumbing is proven before an API call is made. It is not a keeper and makes no
// decisions: it reads the position, quotes, sends one fill the router must refuse by name, and
// one it must settle — the two outcomes the LLM run is judged on.
//
//   FREEBOARD_SECRETS_CMD='cat keeper.env' npm run probe

import { makeKeeper } from './keeper.ts'
import { readFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const here = path.dirname(fileURLToPath(import.meta.url))

// The same secrets path as the keeper; the probe never reads the API key.
const command = process.env.FREEBOARD_SECRETS_CMD ?? 'wallet-cli ring decrypt --key freeboard-keeper < keeper.env.ring'
const run = spawnSync('bash', ['-c', command], { cwd: here, encoding: 'utf8', env: process.env })
if (run.status !== 0) throw new Error(`secrets command failed: ${run.stderr}`)
const kv = Object.fromEntries(
  run.stdout
    .split('\n')
    .map(l => /^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/.exec(l))
    .filter((m): m is RegExpExecArray => m !== null)
    .map(m => [m[1]!, m[2]!]),
)
const world = JSON.parse(readFileSync(path.join(here, 'world.json'), 'utf8'))
const keeper = makeKeeper(world, {
  rpcUrl: kv.RPC_URL!,
  takerPrivateKey: kv.TAKER_PRIVATE_KEY as `0x${string}`,
  anthropicApiKey: 'unused-by-the-probe',
})

const show = (label: string, x: unknown) => console.log(`\n== ${label}\n${JSON.stringify(x, null, 2)}`)

const position = await keeper.impl.readPosition()
show('readPosition', position)

// The whole USDC gap in one fill: what "all of it" means, and what the cap refuses.
const legs = (position as { legs: Array<{ symbol: string; gapUsd: string; priceUsd: string }> }).legs
const usdcGap = legs.find(l => l.symbol === 'USDC')!.gapUsd.replace(/[+,]/g, '')
show('quote: the whole gap', await keeper.impl.quote({ tokenIn: 'USDC', tokenOut: 'WETH', amountIn: usdcGap }))
show('fill: the whole gap (must be refused by name)', await keeper.impl.fill({ tokenIn: 'USDC', tokenOut: 'WETH', amountIn: usdcGap }))

// Under the cap: 4% of the basket's value in USDC, toward target (USDC under, WETH over).
const total = Number((position as { totalValueUsd: string }).totalValueUsd)
const small = (total * 0.04).toFixed(2)
show('quote: under the cap', await keeper.impl.quote({ tokenIn: 'USDC', tokenOut: 'WETH', amountIn: small }))
show('fill: under the cap (must settle, equal to quote)', await keeper.impl.fill({ tokenIn: 'USDC', tokenOut: 'WETH', amountIn: small }))
show('readPosition after', await keeper.impl.readPosition())
