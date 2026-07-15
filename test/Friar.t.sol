// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

import {Friar} from "../src/Friar.sol";
import {FriarMath} from "../src/FriarMath.sol";

contract FriarHookTest is Test, Deployers {
    bytes32 constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    uint16 constant BASE_FACTOR = 5000;
    uint16 constant FILTER_PERIOD = 30;
    uint16 constant DECAY_PERIOD = 600;
    uint16 constant REDUCTION_FACTOR = 5000;
    uint24 constant VARIABLE_FEE_CONTROL = 40_000;
    uint24 constant MAX_VOL_ACC = 350_000;

    // tickSpacing 60 -> base fee = 5000 * 60 * 1e10 = 3e15 = 0.3% = 3000 pips
    int24 constant TICK_SPACING = 60;
    uint24 constant BASE_FEE_PIPS = 3000;

    Friar friar;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address flags = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo(
            "Friar.sol:Friar",
            abi.encode(
                manager, BASE_FACTOR, FILTER_PERIOD, DECAY_PERIOD, REDUCTION_FACTOR, VARIABLE_FEE_CONTROL, MAX_VOL_ACC
            ),
            flags
        );
        friar = Friar(flags);

        (key,) = initPool(
            currency0, currency1, IHooks(address(friar)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, SQRT_PRICE_1_1
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100e18, salt: 0}),
            ZERO_BYTES
        );
    }

    function _swapAndGetFee(bool zeroForOne, int256 amountSpecified) internal returns (uint24 fee) {
        vm.recordLogs();
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, uint24 eventFee) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return eventFee;
            }
        }
        revert("Swap event not found");
    }

    function test_initialization_seedsState() public view {
        FriarMath.VolatilityState memory s = friar.volatilityState(key.toId());
        assertEq(s.volatilityAccumulator, 0);
        assertEq(s.volatilityReference, 0);
        assertEq(s.bucketReference, 0);
        assertEq(s.lastUpdate, uint40(block.timestamp));
    }

    function test_initReverts_onStaticFeePool() public {
        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(friar)), 3000, TICK_SPACING, SQRT_PRICE_1_1);
    }

    function test_constructorReverts_onInvalidParams() public {
        vm.expectRevert(Friar.InvalidParameters.selector);
        new Friar(manager, 5000, 700, 600, 5000, 40_000, 350_000); // filter > decay
    }

    function test_calmSwap_paysBaseFee() public {
        uint24 fee = _swapAndGetFee(true, -1e15);
        assertEq(fee, BASE_FEE_PIPS);
    }

    function test_previewFee_matchesChargedFee() public {
        uint24 previewed = friar.previewFee(key);
        uint24 charged = _swapAndGetFee(true, -1e15);
        assertEq(previewed, charged);
    }

    function test_bigMove_surgesNextSwapFee() public {
        uint24 first = _swapAndGetFee(true, -10e18);
        assertEq(first, BASE_FEE_PIPS); // pre-swap measurement: the mover pays base (D8)

        FriarMath.VolatilityState memory s0 = friar.volatilityState(key.toId());
        assertEq(s0.volatilityAccumulator, 0); // movement not yet observed

        uint24 second = _swapAndGetFee(true, -1e15);
        assertGt(second, BASE_FEE_PIPS);

        FriarMath.VolatilityState memory s1 = friar.volatilityState(key.toId());
        assertGt(s1.volatilityAccumulator, 0);
    }

    function test_surge_decaysBackToBase() public {
        _swapAndGetFee(true, -10e18);
        uint24 surged = _swapAndGetFee(true, -1e15);
        assertGt(surged, BASE_FEE_PIPS);

        vm.warp(block.timestamp + DECAY_PERIOD + 1);
        uint24 calm = _swapAndGetFee(true, -1e14);
        assertEq(calm, BASE_FEE_PIPS);

        FriarMath.VolatilityState memory s = friar.volatilityState(key.toId());
        assertEq(s.volatilityAccumulator, 0);
    }

    function test_surge_partialDecay_withinDecayWindow() public {
        _swapAndGetFee(true, -10e18);
        _swapAndGetFee(true, -1e15);
        FriarMath.VolatilityState memory s1 = friar.volatilityState(key.toId());

        vm.warp(block.timestamp + FILTER_PERIOD + 10); // inside decay window
        _swapAndGetFee(true, -1e14);
        FriarMath.VolatilityState memory s2 = friar.volatilityState(key.toId());

        // reference re-anchored, accumulator reduced by reductionFactor but not zeroed
        assertGt(s2.volatilityAccumulator, 0);
        assertLt(s2.volatilityAccumulator, s1.volatilityAccumulator);
    }

    function test_feeNeverExceedsCap_afterViolentMove() public {
        _swapAndGetFee(true, -30e18);
        uint24 fee = _swapAndGetFee(true, -1e15);
        assertLe(fee, 100_000);
    }

    function test_twoPools_isolatedState() public {
        (PoolKey memory keyB,) = initPool(
            currency0, currency1, IHooks(address(friar)), LPFeeLibrary.DYNAMIC_FEE_FLAG, int24(200), SQRT_PRICE_1_1
        );
        modifyLiquidityRouter.modifyLiquidity(
            keyB,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100e18, salt: 0}),
            ZERO_BYTES
        );

        // Violence in pool A...
        _swapAndGetFee(true, -10e18);
        _swapAndGetFee(true, -1e15);
        assertGt(friar.volatilityState(key.toId()).volatilityAccumulator, 0);

        // ...leaves pool B calm at its own base fee (5000 * 200 * 1e10 -> 10_000 pips).
        assertEq(friar.volatilityState(keyB.toId()).volatilityAccumulator, 0);
        assertEq(friar.previewFee(keyB), 10_000);
    }

    function test_hookPermissions_minimalSurface() public view {
        Hooks.Permissions memory p = friar.getHookPermissions();
        assertTrue(p.afterInitialize);
        assertTrue(p.beforeSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }
}
