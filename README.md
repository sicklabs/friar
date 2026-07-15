# Tuck

**Friar** (`src/Friar.sol`) is a Uniswap v4 dynamic-fee hook for Robinhood Chain:
the Liquidity Book volatility-accumulator fee model (LFJ `joe-v2`, MIT — the same
mechanism behind Meteora's DLMM dynamic fees) on standard v4 pools. Low base fee
in calm markets, surging fee during volatility, decaying back after. Fee-override
permission bits only: no custody, no owner, no upgradeability, no protocol fee.

See `docs/SPEC.md` for the mechanism, deviations from Liquidity Book, and
deployment details.

> Every pool has a Friar; the Friar always eats.

```
src/FriarMath.sol          LB fee math, ported to v4 units
src/Friar.sol              the hook (afterInitialize + beforeSwap only)
test/                      unit vectors + PoolManager integration tests
script/DeployFriar.s.sol   CREATE2/HookMiner deployment
```

## Setup

Dependencies are gitignored; clone them into `lib/`:

```bash
git clone --depth 1 --recursive --shallow-submodules \
  https://github.com/Uniswap/v4-periphery lib/v4-periphery
git clone --depth 1 https://github.com/foundry-rs/forge-std lib/forge-std
forge test
```

## License

MIT — fee mechanism ported from [Liquidity Book](https://github.com/lfj-gg/joe-v2) (MIT).
