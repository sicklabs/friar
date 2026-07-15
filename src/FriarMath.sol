// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FriarMath — Liquidity Book volatility-accumulator fee math, ported for Uniswap v4
/// @notice Faithful port of the dynamic fee mechanism from Trader Joe / LFJ Liquidity Book
/// (`lfj-gg/joe-v2`, MIT: `src/libraries/PairParameterHelper.sol`), adapted to v4 units:
/// - LB "bin id" -> tick bucket, i.e. floor(tick / tickSpacing)
/// - LB "bin step" (basis points) -> tickSpacing (1 tick = 1 basis point of price)
/// - LB 1e18 fee fraction -> v4 pips (hundredths of a bip; 1_000_000 = 100%)
/// The accumulator rises with buckets crossed between swaps and decays by reduction
/// factor (within the decay window) or to zero (past it). Total fee = base + variable,
/// hard-capped at 10% exactly like LB's `Constants.MAX_FEE = 0.1e18`.
library FriarMath {
    uint256 internal constant BASIS_POINT_MAX = 10_000;
    /// @dev LB Constants.MAX_FEE — 10%, expressed as an 1e18 fraction
    uint256 internal constant MAX_FEE_1E18 = 0.1e18;
    /// @dev 1e18 fee fraction -> v4 pips divisor (1e18 / 1_000_000)
    uint256 internal constant PIPS_DIVISOR = 1e12;
    uint24 internal constant MAX_FEE_PIPS = uint24(MAX_FEE_1E18 / PIPS_DIVISOR);

    struct Params {
        uint16 baseFactor;
        uint16 filterPeriod;
        uint16 decayPeriod;
        uint16 reductionFactor;
        uint24 variableFeeControl;
        uint24 maxVolatilityAccumulator;
    }

    struct VolatilityState {
        uint24 volatilityAccumulator;
        uint24 volatilityReference;
        int24 bucketReference;
        uint40 lastUpdate;
    }

    /// @notice LB `updateReferences`: refresh bucket/volatility references once the
    /// filter period has elapsed, then stamp the update time.
    function updateReferences(VolatilityState memory s, Params memory p, int24 bucket, uint256 timestamp)
        internal
        pure
    {
        uint256 dt = timestamp - s.lastUpdate;

        if (dt >= p.filterPeriod) {
            s.bucketReference = bucket;
            s.volatilityReference = dt < p.decayPeriod
                ? uint24((uint256(s.volatilityAccumulator) * p.reductionFactor) / BASIS_POINT_MAX)
                : 0;
        }

        s.lastUpdate = uint40(timestamp);
    }

    /// @notice LB `updateVolatilityAccumulator`: accumulator = reference + buckets moved
    /// since the reference, in basis-point units, capped.
    function updateVolatilityAccumulator(VolatilityState memory s, Params memory p, int24 bucket) internal pure {
        uint256 delta = bucket > s.bucketReference
            ? uint256(int256(bucket) - int256(s.bucketReference))
            : uint256(int256(s.bucketReference) - int256(bucket));

        uint256 volAcc = uint256(s.volatilityReference) + delta * BASIS_POINT_MAX;
        uint256 maxVolAcc = p.maxVolatilityAccumulator;

        s.volatilityAccumulator = uint24(volAcc > maxVolAcc ? maxVolAcc : volAcc);
    }

    /// @notice LB `updateVolatilityParameters`: both steps, in LB's order.
    function update(VolatilityState memory s, Params memory p, int24 bucket, uint256 timestamp) internal pure {
        updateReferences(s, p, bucket, timestamp);
        updateVolatilityAccumulator(s, p, bucket);
    }

    /// @notice LB `getBaseFee`: baseFactor (bps) x binStep (bps) as an 1e18 fraction.
    function baseFee1e18(Params memory p, uint16 binStep) internal pure returns (uint256) {
        unchecked {
            return uint256(p.baseFactor) * binStep * 1e10;
        }
    }

    /// @notice LB `getVariableFee`: ceil((volAcc x binStep)^2 x variableFeeControl / 100),
    /// as an 1e18 fraction.
    function variableFee1e18(Params memory p, uint24 volatilityAccumulator, uint16 binStep)
        internal
        pure
        returns (uint256 variableFee)
    {
        if (p.variableFeeControl != 0) {
            unchecked {
                uint256 prod = uint256(volatilityAccumulator) * binStep;
                variableFee = (prod * prod * p.variableFeeControl + 99) / 100;
            }
        }
    }

    /// @notice Total fee in v4 pips, capped at 10% (LB MAX_FEE).
    function totalFeePips(Params memory p, uint24 volatilityAccumulator, uint16 binStep)
        internal
        pure
        returns (uint24)
    {
        uint256 fee = baseFee1e18(p, binStep) + variableFee1e18(p, volatilityAccumulator, binStep);
        if (fee > MAX_FEE_1E18) fee = MAX_FEE_1E18;
        return uint24(fee / PIPS_DIVISOR);
    }

    /// @notice Floor division of tick into its bucket (the LB "bin id" analogue).
    function bucketOf(int24 tick, int24 tickSpacing) internal pure returns (int24 bucket) {
        bucket = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) bucket--;
    }
}
