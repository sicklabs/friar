# Friar — technical specification

**Friar** is a Uniswap v4 dynamic-fee hook for Robinhood Chain (chain ID 4663). It
sets a pool's LP fee per swap using the Liquidity Book volatility-accumulator
mechanism (Trader Joe / LFJ `joe-v2`, MIT — the same fee model behind Meteora's
DLMM dynamic fees on Solana): a low base fee in calm markets that surges with
recent price movement and decays back after configurable windows.

## Trust profile

- Permission bits: `AFTER_INITIALIZE` + `BEFORE_SWAP` only. The hook cannot take
  swap deltas, own liquidity, or touch user funds — its address proves it.
- No owner, no admin functions, no upgradeability. All parameters immutable;
  a different configuration is a new deployment.
- No protocol fee. The fee set here is the LP fee, paid entirely to the pool's
  liquidity providers.
- Total fee hard-capped at 10% (Liquidity Book `MAX_FEE`), enforced at pool
  initialization and on every swap.
- Pool creation, swapping, and liquidity provision are all unrestricted.

## Fee mechanism (port of LB `PairParameterHelper`, MIT)

Reference: `lfj-gg/joe-v2` `src/libraries/PairParameterHelper.sol`. Unit mapping:
LB bin id → tick bucket = `floor(tick / tickSpacing)`; LB bin step (bps) →
`tickSpacing` (1 tick = 1 basis point); LB 1e18 fee fraction → v4 pips (`/1e12`).

### Per-pool state

`volatilityAccumulator` (uint24), `volatilityReference` (uint24),
`bucketReference` (int24), `lastUpdate` (uint40) — one storage slot.

### Immutable parameters

`baseFactor`, `filterPeriod`, `decayPeriod`, `reductionFactor`,
`variableFeeControl`, `maxVolatilityAccumulator` — validated in the constructor
with Liquidity Book's bounds (`filterPeriod ≤ decayPeriod`, `decayPeriod ≤ 4095`,
`reductionFactor ≤ 10_000`, `maxVolatilityAccumulator ≤ 2^20−1`).

### Per-swap computation (`beforeSwap`)

With `dt = now − lastUpdate` and `bucket = floor(tick/tickSpacing)` (pre-swap tick):

1. If `dt ≥ filterPeriod`: `bucketReference = bucket`;
   `volatilityReference = dt < decayPeriod ? volatilityAccumulator × reductionFactor / 10_000 : 0`.
   Always `lastUpdate = now`.
2. `Δ = |bucket − bucketReference|`;
   `volatilityAccumulator = min(volatilityReference + Δ × 10_000, maxVolatilityAccumulator)`.
3. `baseFee₁ₑ₁₈ = baseFactor × tickSpacing × 1e10`;
   `variableFee₁ₑ₁₈ = ceil((volatilityAccumulator × tickSpacing)² × variableFeeControl / 100)`;
   `fee = min(base + variable, 0.1e18)` → returned as pips with `OVERRIDE_FEE_FLAG`.

`previewFee(PoolKey)` exposes the same computation as a view.

### Known deviation from Liquidity Book

LB escalates the fee per bin crossed within a single swap; a `beforeSwap` hook
prices each swap from movement observed up to that swap. Movement caused by a
swap raises the fee charged to subsequent swaps inside the filter/decay windows
(one-swap lag). Within the filter window the reference does not re-anchor, so
the lag does not lose the movement — it delays pricing it by one swap.

## Deployment (chain 4663)

| Contract | Address |
|---|---|
| PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| PositionManager | `0x58daec3116aae6d93017baaea7749052e8a04fa7` |
| Universal Router | `0x8876789976decbfcbbbe364623c63652db8c0904` |
| V4Quoter | `0x8dc178efb8111bb0973dd9d722ebeff267c98f94` |
| StateView | `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |

Hook addresses encode permissions in their low bits; `script/DeployFriar.s.sol`
mines the CREATE2 salt (HookMiner) for `AFTER_INITIALIZE | BEFORE_SWAP` and
deploys via the canonical CREATE2 deployer. Pools must be created with
`DYNAMIC_FEE_FLAG`; static-fee pools are rejected at initialization, as are
configurations whose base fee exceeds the 10% cap for the pool's tick spacing.

Default parameters (tuned on live Robinhood Chain flow, July 2026), targeting
tickSpacing-100 pools (0.50% base): `baseFactor 5000, filterPeriod 10,
decayPeriod 600, reductionFactor 5000, variableFeeControl 40000,
maxVolatilityAccumulator 350000`. Override via environment variables (see script).

## Tests

- `test/FriarMath.t.sol` — exact-vector unit tests for every formula against
  hand-computed Liquidity Book values; fuzz tests for the fee cap and
  accumulator cap.
- `test/Friar.t.sol` — integration against a real PoolManager: dynamic-flag
  enforcement, base fee in calm, surge after movement, decay back to base,
  partial decay inside the window, per-pool state isolation, minimal
  permission surface.

## Lineage & licensing

- Fee mechanism: [lfj-gg/joe-v2](https://github.com/lfj-gg/joe-v2) (MIT) —
  `PairParameterHelper.sol`, `Constants.sol` (`MAX_FEE = 0.1e18`).
- Built directly on [Uniswap v4-core / v4-periphery](https://github.com/Uniswap/v4-periphery)
  interfaces and test utilities.
- This repository: MIT (see LICENSE).
