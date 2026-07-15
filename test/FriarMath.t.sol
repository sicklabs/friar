// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FriarMath} from "../src/FriarMath.sol";

contract FriarMathTest is Test {
    using FriarMath for FriarMath.VolatilityState;

    function _params() internal pure returns (FriarMath.Params memory) {
        return FriarMath.Params({
            baseFactor: 5000,
            filterPeriod: 30,
            decayPeriod: 600,
            reductionFactor: 5000,
            variableFeeControl: 40_000,
            maxVolatilityAccumulator: 350_000
        });
    }

    function _state() internal pure returns (FriarMath.VolatilityState memory) {
        return FriarMath.VolatilityState({
            volatilityAccumulator: 0,
            volatilityReference: 0,
            bucketReference: 0,
            lastUpdate: 1000
        });
    }

    function test_baseFee_matchesLBFormula() public pure {
        // LB: baseFactor(bps) * binStep(bps) * 1e10 -> 5000 * 200 * 1e10 = 1e16 = 1%
        assertEq(FriarMath.baseFee1e18(_params(), 200), 1e16);
        // 5000 * 60 * 1e10 = 3e15 = 0.3%
        assertEq(FriarMath.baseFee1e18(_params(), 60), 3e15);
    }

    function test_variableFee_matchesLBFormula() public pure {
        // prod = 10_000 * 200 = 2e6; prod^2 = 4e12; * 40_000 = 1.6e17; ceil(/100) = 1.6e15
        assertEq(FriarMath.variableFee1e18(_params(), 10_000, 200), 1.6e15);
    }

    function test_variableFee_zeroControlIsZero() public pure {
        FriarMath.Params memory p = _params();
        p.variableFeeControl = 0;
        assertEq(FriarMath.variableFee1e18(p, 350_000, 200), 0);
    }

    function test_variableFee_roundsUp() public pure {
        FriarMath.Params memory p = _params();
        p.variableFeeControl = 1;
        // prod = 1 * 1 = 1; prod^2 * 1 = 1; ceil(1/100) = 1 wei of fee, not 0
        assertEq(FriarMath.variableFee1e18(p, 1, 1), 1);
    }

    function test_totalFeePips_baseOnly() public pure {
        // 1e16 / 1e12 = 10_000 pips = 1%
        assertEq(FriarMath.totalFeePips(_params(), 0, 200), 10_000);
        // 3e15 / 1e12 = 3_000 pips = 0.3%
        assertEq(FriarMath.totalFeePips(_params(), 0, 60), 3_000);
    }

    function test_totalFeePips_baseAndVariable() public pure {
        // base 1e16 + variable 1.6e15 = 1.16e16 -> 11_600 pips
        assertEq(FriarMath.totalFeePips(_params(), 10_000, 200), 11_600);
    }

    function test_totalFeePips_capsAtTenPercent() public pure {
        // At the accumulator cap: prod = 350_000 * 200 = 7e7; fee = 1.96e18 >> 0.1e18
        assertEq(FriarMath.totalFeePips(_params(), 350_000, 200), 100_000);
        assertEq(uint256(FriarMath.MAX_FEE_PIPS), 100_000);
    }

    function test_updateReferences_withinFilterPeriod_onlyTimestamps() public pure {
        FriarMath.VolatilityState memory s = _state();
        s.volatilityAccumulator = 100_000;
        s.volatilityReference = 77;
        s.bucketReference = 42;

        s.updateReferences(_params(), 999, 1010); // dt = 10 < filterPeriod 30

        assertEq(s.bucketReference, 42);
        assertEq(s.volatilityReference, 77);
        assertEq(s.lastUpdate, 1010);
    }

    function test_updateReferences_betweenFilterAndDecay_reducesReference() public pure {
        FriarMath.VolatilityState memory s = _state();
        s.volatilityAccumulator = 100_000;

        s.updateReferences(_params(), 7, 1100); // dt = 100, filter <= dt < decay

        assertEq(s.bucketReference, 7);
        // volRef = 100_000 * 5000 / 10_000 = 50_000
        assertEq(s.volatilityReference, 50_000);
        assertEq(s.lastUpdate, 1100);
    }

    function test_updateReferences_pastDecay_zeroesReference() public pure {
        FriarMath.VolatilityState memory s = _state();
        s.volatilityAccumulator = 100_000;

        s.updateReferences(_params(), 7, 1700); // dt = 700 >= decay 600

        assertEq(s.bucketReference, 7);
        assertEq(s.volatilityReference, 0);
    }

    function test_updateVolatilityAccumulator_countsBuckets() public pure {
        FriarMath.VolatilityState memory s = _state();
        s.bucketReference = 100;
        s.volatilityReference = 5_000;

        s.updateVolatilityAccumulator(_params(), 105);
        // 5_000 + 5 * 10_000
        assertEq(s.volatilityAccumulator, 55_000);

        s.updateVolatilityAccumulator(_params(), 95);
        assertEq(s.volatilityAccumulator, 55_000);
    }

    function test_updateVolatilityAccumulator_caps() public pure {
        FriarMath.VolatilityState memory s = _state();
        s.bucketReference = 0;

        s.updateVolatilityAccumulator(_params(), 1000); // 10_000_000 raw
        assertEq(s.volatilityAccumulator, 350_000);
    }

    function test_update_fullSequence_mirrorsLB() public pure {
        FriarMath.Params memory p = _params();
        FriarMath.VolatilityState memory s = _state();

        // t=1000: burst begins, price jumps 3 buckets. dt=0 < filter: reference kept.
        s.update(p, 3, 1000);
        assertEq(s.volatilityAccumulator, 30_000);

        // t=1005 (dt=5 < filter): 2 more buckets, still measured from bucketReference 0.
        s.update(p, 5, 1005);
        assertEq(s.volatilityAccumulator, 50_000);

        // t=1100 (filter <= dt=95 < decay): reference re-anchors to bucket 5,
        // volRef = 50_000 / 2; no further movement.
        s.update(p, 5, 1100);
        assertEq(s.volatilityReference, 25_000);
        assertEq(s.volatilityAccumulator, 25_000);

        // t=2000 (dt=900 >= decay): fully decayed, calm swap pays base fee.
        s.update(p, 5, 2000);
        assertEq(s.volatilityAccumulator, 0);
    }

    function test_bucketOf_floorsTowardNegativeInfinity() public pure {
        assertEq(FriarMath.bucketOf(0, 60), 0);
        assertEq(FriarMath.bucketOf(59, 60), 0);
        assertEq(FriarMath.bucketOf(60, 60), 1);
        assertEq(FriarMath.bucketOf(120, 60), 2);
        assertEq(FriarMath.bucketOf(-1, 60), -1);
        assertEq(FriarMath.bucketOf(-60, 60), -1);
        assertEq(FriarMath.bucketOf(-61, 60), -2);
        assertEq(FriarMath.bucketOf(-120, 60), -2);
    }

    function testFuzz_totalFee_neverExceedsCap(uint24 volAcc, uint16 binStep) public pure {
        volAcc = uint24(bound(volAcc, 0, 1_048_575));
        binStep = uint16(bound(binStep, 1, 32_767));
        assertLe(FriarMath.totalFeePips(_params(), volAcc, binStep), 100_000);
    }

    function testFuzz_accumulator_neverExceedsMax(int24 refBucket, int24 bucket, uint24 volRef) public pure {
        FriarMath.Params memory p = _params();
        FriarMath.VolatilityState memory s = _state();
        s.bucketReference = refBucket;
        s.volatilityReference = uint24(bound(volRef, 0, 1_048_575));

        s.updateVolatilityAccumulator(p, bucket);
        assertLe(s.volatilityAccumulator, p.maxVolatilityAccumulator);
    }
}
