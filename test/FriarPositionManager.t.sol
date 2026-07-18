// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Friar} from "../src/Friar.sol";
import {FriarPositionManager} from "../src/FriarPositionManager.sol";

contract FriarPositionManagerTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    Friar friar;
    FriarPositionManager fpm;

    address treasury = makeAddr("treasury");
    address bot = makeAddr("bot"); // fee-exempt
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    MockERC20 t0;
    MockERC20 t1;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        address flags = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo(
            "Friar.sol:Friar",
            abi.encode(manager, uint16(5000), uint16(10), uint16(600), uint16(5000), uint24(40_000), uint24(350_000)),
            flags
        );
        friar = Friar(flags);
        (key,) = initPool(currency0, currency1, IHooks(address(friar)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 100, SQRT_PRICE_1_1);
        // background book so zaps have liquidity after our bins burn
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -30_000, tickUpper: 30_000, liquidityDelta: 500e18, salt: 0}), ZERO_BYTES
        );

        fpm = new FriarPositionManager(manager, 1000, treasury, bot); // 10% perf fee

        t0 = MockERC20(Currency.unwrap(currency0));
        t1 = MockERC20(Currency.unwrap(currency1));
        _fund(alice);
        _fund(bob);
        _fund(bot);
    }

    function _fund(address who) internal {
        t0.mint(who, 1_000e18);
        t1.mint(who, 1_000e18);
        vm.startPrank(who);
        t0.approve(address(fpm), type(uint256).max);
        t1.approve(address(fpm), type(uint256).max);
        vm.stopPrank();
    }

    function _threeBinBids() internal pure returns (FriarPositionManager.Bin[] memory bins) {
        bins = new FriarPositionManager.Bin[](3);
        bins[0] = FriarPositionManager.Bin(-100, 0, 10e18);
        bins[1] = FriarPositionManager.Bin(-200, -100, 20e18);
        bins[2] = FriarPositionManager.Bin(-300, -200, 30e18);
    }

    function _noSwapIn() internal pure returns (FriarPositionManager.SwapIn memory s) {}

    function _noZap() internal pure returns (FriarPositionManager.Zap memory z) {}

    function _zap(bool zeroForOne) internal view returns (FriarPositionManager.Zap memory) {
        return FriarPositionManager.Zap({enabled: true, venue: key, zeroForOne: zeroForOne});
    }

    function _open(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = fpm.open(key, _threeBinBids(), _noSwapIn(), type(uint256).max, type(uint256).max);
    }

    // ------------------------------------------------------------ lifecycle

    function test_open_recordsPosition() public {
        uint256 id = _open(alice);

        (address owner,, FriarPositionManager.Bin[] memory bins) = fpm.getPosition(id);
        assertEq(owner, alice);
        assertEq(bins.length, 3);
        assertEq(bins[1].liquidity, 20e18);

        uint256[] memory ids = fpm.positionsOf(alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], id);

        // liquidity actually minted in the PoolManager under the derived salt
        uint128 liq = manager.getPositionLiquidity(
            key.toId(), Position.calculatePositionKey(address(fpm), -200, -100, fpm.binSalt(id, 1))
        );
        assertEq(liq, 20e18);
    }

    function test_open_maxPayGuard_reverts() public {
        FriarPositionManager.Bin[] memory bins = _threeBinBids();
        vm.prank(alice);
        vm.expectRevert(FriarPositionManager.PaidTooMuch.selector);
        fpm.open(key, bins, _noSwapIn(), type(uint256).max, 0); // bids cost token1; cap of 0 must revert
    }

    function test_close_byIdOnly_noBackendData() public {
        uint256 id = _open(alice);
        swap(key, true, -50e18, ZERO_BYTES); // fill some bins

        uint256 t0Before = t0.balanceOf(alice);
        uint256 t1Before = t1.balanceOf(alice);

        vm.prank(alice);
        fpm.close(id, _noZap(), 0, 0); // knows ONLY the id

        assertGt(t0.balanceOf(alice) - t0Before + (t1.balanceOf(alice) - t1Before), 0);
        vm.expectRevert(FriarPositionManager.UnknownPosition.selector);
        fpm.getPosition(id);
        assertEq(fpm.positionsOf(alice).length, 0);
    }

    function test_closeZap_returnsOnlyQuote() public {
        uint256 id = _open(alice);
        swap(key, true, -50e18, ZERO_BYTES); // dump through the bids

        uint256 t0Before = t0.balanceOf(alice);
        uint256 t1Before = t1.balanceOf(alice);

        vm.prank(alice);
        fpm.close(id, _zap(true), 0, 1); // zap inventory -> token1, expect some quote

        assertEq(t0.balanceOf(alice) - t0Before, 0, "zap should leave no token0");
        assertGt(t1.balanceOf(alice) - t1Before, 0, "should receive quote");
    }

    function test_close_minReceive_reverts() public {
        uint256 id = _open(alice);
        swap(key, true, -50e18, ZERO_BYTES);

        vm.prank(alice);
        vm.expectRevert(FriarPositionManager.ReceivedTooLittle.selector);
        fpm.close(id, _zap(true), 0, type(uint128).max);
    }

    function test_partialDecrease_keepsPositionOpen() public {
        uint256 id = _open(alice);

        uint128[] memory ds = new uint128[](3);
        ds[0] = 5e18; // half of bin 0
        vm.prank(alice);
        fpm.decrease(id, ds, _noZap(), 0, 0);

        (,, FriarPositionManager.Bin[] memory bins) = fpm.getPosition(id);
        assertEq(bins[0].liquidity, 5e18);
        assertEq(bins[1].liquidity, 20e18);

        vm.prank(alice);
        fpm.close(id, _noZap(), 0, 0);
        assertEq(fpm.positionsOf(alice).length, 0);
    }

    function test_decrease_tooMuch_reverts() public {
        uint256 id = _open(alice);
        uint128[] memory ds = new uint128[](3);
        ds[0] = 11e18; // bin 0 only has 10e18
        vm.prank(alice);
        vm.expectRevert(FriarPositionManager.DecreaseExceedsLiquidity.selector);
        fpm.decrease(id, ds, _noZap(), 0, 0);
    }

    function test_increase_growsBins() public {
        uint256 id = _open(alice);

        uint128[] memory ds = new uint128[](3);
        ds[2] = 30e18; // double bin 2
        vm.prank(alice);
        fpm.increase(id, ds, _noSwapIn(), type(uint256).max, type(uint256).max);

        (,, FriarPositionManager.Bin[] memory bins) = fpm.getPosition(id);
        assertEq(bins[2].liquidity, 60e18);
        uint128 liq = manager.getPositionLiquidity(
            key.toId(), Position.calculatePositionKey(address(fpm), -300, -200, fpm.binSalt(id, 2))
        );
        assertEq(liq, 60e18);
    }

    function test_openSwapIn_asksFundedBySwap() public {
        FriarPositionManager.Bin[] memory bins = new FriarPositionManager.Bin[](4);
        bins[0] = FriarPositionManager.Bin(-100, 0, 10e18); // bids
        bins[1] = FriarPositionManager.Bin(-200, -100, 20e18);
        bins[2] = FriarPositionManager.Bin(100, 200, 10e18); // asks
        bins[3] = FriarPositionManager.Bin(200, 300, 20e18);

        uint256 t0Before = t0.balanceOf(alice);
        vm.prank(alice);
        fpm.open(
            key,
            bins,
            FriarPositionManager.SwapIn({enabled: true, venue: key, zeroForOne: false, amountIn: 1e18, minAmountOut: 1e17}),
            type(uint256).max,
            type(uint256).max
        );

        // asks funded by the in-unlock swap, not alice's token0; surplus sweeps back
        assertGe(t0.balanceOf(alice), t0Before);
    }

    function test_swapIn_minOut_reverts() public {
        FriarPositionManager.Bin[] memory bins = new FriarPositionManager.Bin[](1);
        bins[0] = FriarPositionManager.Bin(100, 200, 1e18);
        vm.prank(alice);
        vm.expectRevert(FriarPositionManager.SwapInsufficientOutput.selector);
        fpm.open(
            key,
            bins,
            FriarPositionManager.SwapIn({
                enabled: true,
                venue: key,
                zeroForOne: false,
                amountIn: 1e18,
                minAmountOut: type(uint128).max
            }),
            type(uint256).max,
            type(uint256).max
        );
    }

    // ----------------------------------------------------------------- perf fee

    /// Collect returns fees only (no principal), so the split is exactly observable:
    /// treasury gets floor(10%), owner gets the rest.
    function test_collect_chargesTenPercentToTreasury() public {
        uint256 id = _open(alice);
        swap(key, true, -20e18, ZERO_BYTES); // trade through the bids -> token0 fees
        swap(key, false, -20e18, ZERO_BYTES); // and back -> token1 fees

        uint256 a0 = t0.balanceOf(alice);
        uint256 a1 = t1.balanceOf(alice);
        uint256 tr0 = t0.balanceOf(treasury);
        uint256 tr1 = t1.balanceOf(treasury);

        vm.prank(alice);
        fpm.collect(id, _noZap(), 0, 0);

        uint256 got0 = t0.balanceOf(alice) - a0;
        uint256 got1 = t1.balanceOf(alice) - a1;
        uint256 perf0 = t0.balanceOf(treasury) - tr0;
        uint256 perf1 = t1.balanceOf(treasury) - tr1;

        assertGt(got0 + got1, 0, "no fees earned");
        // perf fee = floor(fees * 10%), owner got fees - perf fee => owner ~= 9x perf fee (rounding <= 9 wei)
        if (perf0 > 0) assertApproxEqAbs(got0, perf0 * 9, 9, "token0 split not 90/10");
        if (perf1 > 0) assertApproxEqAbs(got1, perf1 * 9, 9, "token1 split not 90/10");
        assertGt(perf0 + perf1, 0, "treasury got nothing");
    }

    function test_collect_secondCollectYieldsNothing() public {
        uint256 id = _open(alice);
        swap(key, true, -20e18, ZERO_BYTES);

        vm.prank(alice);
        fpm.collect(id, _noZap(), 0, 0);

        uint256 a0 = t0.balanceOf(alice);
        uint256 a1 = t1.balanceOf(alice);
        vm.prank(alice);
        fpm.collect(id, _noZap(), 0, 0);
        assertEq(t0.balanceOf(alice), a0);
        assertEq(t1.balanceOf(alice), a1);
    }

    function test_perfFeeExempt_botPaysNoFee() public {
        vm.prank(bot);
        uint256 id = fpm.open(key, _threeBinBids(), _noSwapIn(), type(uint256).max, type(uint256).max);
        swap(key, true, -20e18, ZERO_BYTES);

        uint256 tr0 = t0.balanceOf(treasury);
        uint256 tr1 = t1.balanceOf(treasury);
        vm.prank(bot);
        fpm.collect(id, _noZap(), 0, 0);
        assertEq(t0.balanceOf(treasury), tr0, "exempt op must not perf fee");
        assertEq(t1.balanceOf(treasury), tr1, "exempt op must not perf fee");
    }

    function test_closeAfterFees_chargesOnClose() public {
        uint256 id = _open(alice);
        swap(key, true, -20e18, ZERO_BYTES);

        uint256 tr0 = t0.balanceOf(treasury);
        vm.prank(alice);
        fpm.close(id, _noZap(), 0, 0);
        assertGt(t0.balanceOf(treasury), tr0, "close must perf fee accrued fees");
    }

    // ------------------------------------------------------------ isolation

    function test_multiTenant_strangersCannotTouch() public {
        uint256 id = _open(alice);

        uint128[] memory ds = new uint128[](3);
        vm.startPrank(bob);
        vm.expectRevert(FriarPositionManager.NotPositionOwner.selector);
        fpm.close(id, _noZap(), 0, 0);
        vm.expectRevert(FriarPositionManager.NotPositionOwner.selector);
        fpm.decrease(id, ds, _noZap(), 0, 0);
        vm.expectRevert(FriarPositionManager.NotPositionOwner.selector);
        fpm.collect(id, _noZap(), 0, 0);
        vm.expectRevert(FriarPositionManager.NotPositionOwner.selector);
        fpm.increase(id, ds, _noSwapIn(), 0, 0);
        vm.stopPrank();

        // and bob CAN open his own — ungated multi-tenancy
        vm.prank(bob);
        uint256 bobId = fpm.open(key, _threeBinBids(), _noSwapIn(), type(uint256).max, type(uint256).max);
        assertEq(fpm.positionsOf(bob).length, 1);
        assertTrue(bobId != id);
    }

    function test_ownerEnumeration_swapPopOnClose() public {
        uint256 id1 = _open(alice);
        uint256 id2 = _open(alice);
        uint256 id3 = _open(alice);

        vm.prank(alice);
        fpm.close(id1, _noZap(), 0, 0);

        uint256[] memory ids = fpm.positionsOf(alice);
        assertEq(ids.length, 2);
        // id3 swapped into id1's slot; both survivors still resolvable
        assertEq(ids[0], id3);
        assertEq(ids[1], id2);
        (address o,,) = fpm.getPosition(id3);
        assertEq(o, alice);
    }

    // ------------------------------------------------------- pool creation

    function _freshKey() internal view returns (PoolKey memory k) {
        // same pair + same Friar hook, different tickSpacing => distinct, uninitialized pool
        k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(friar)));
    }

    function _bidsFor60() internal pure returns (FriarPositionManager.Bin[] memory bins) {
        bins = new FriarPositionManager.Bin[](2);
        bins[0] = FriarPositionManager.Bin(-120, -60, 10e18);
        bins[1] = FriarPositionManager.Bin(-240, -120, 20e18);
    }

    function test_openNew_createsPoolAndSeedsAtomically() public {
        PoolKey memory k = _freshKey();

        vm.prank(alice);
        uint256 id = fpm.openNew(k, SQRT_PRICE_1_1, _bidsFor60(), _noSwapIn(), type(uint256).max, type(uint256).max);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(k.toId());
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1, "pool initialized at chosen price");
        (address owner,,) = fpm.getPosition(id);
        assertEq(owner, alice);
    }

    function test_openNew_existingPool_reverts() public {
        vm.prank(alice);
        vm.expectRevert(); // core's Pool.PoolAlreadyInitialized — chosen price is stale
        fpm.openNew(key, SQRT_PRICE_1_1, _threeBinBids(), _noSwapIn(), type(uint256).max, type(uint256).max);
    }

    function test_open_uninitializedPool_reverts() public {
        vm.prank(alice);
        vm.expectRevert(); // core's PoolNotInitialized — use openNew for first liquidity
        fpm.open(_freshKey(), _bidsFor60(), _noSwapIn(), type(uint256).max, type(uint256).max);
    }

    // ------------------------------------------------------------ guards

    function test_nativeCurrency_reverts() public {
        PoolKey memory nativeKey = key;
        nativeKey.currency0 = Currency.wrap(address(0));
        vm.prank(alice);
        vm.expectRevert(FriarPositionManager.NativeCurrencyUnsupported.selector);
        fpm.open(nativeKey, _threeBinBids(), _noSwapIn(), type(uint256).max, type(uint256).max);
    }

    function test_venueMismatch_reverts() public {
        uint256 id = _open(alice);
        PoolKey memory foreign = key;
        foreign.currency0 = Currency.wrap(address(0xDEAD));
        vm.prank(alice);
        vm.expectRevert(FriarPositionManager.VenueMismatch.selector);
        fpm.close(id, FriarPositionManager.Zap({enabled: true, venue: foreign, zeroForOne: true}), 0, 0);
    }

    function test_constructor_perfFeeCap() public {
        vm.expectRevert(FriarPositionManager.PerfFeeTooHigh.selector);
        new FriarPositionManager(manager, 2001, treasury, bot);
    }

    function test_setPerfFeeExempt_treasuryGated() public {
        vm.expectRevert(FriarPositionManager.NotTreasury.selector);
        fpm.setPerfFeeExempt(alice, true);

        vm.prank(treasury);
        fpm.setPerfFeeExempt(alice, true);
        assertTrue(fpm.perfFeeExempt(alice));

        vm.prank(treasury);
        fpm.setPerfFeeExempt(alice, false);
        assertFalse(fpm.perfFeeExempt(alice));
    }

    function test_setPerfFeeExempt_appliesToExistingPosition() public {
        uint256 id = _open(alice); // opened while NOT exempt
        swap(key, true, -20e18, ZERO_BYTES);

        vm.prank(treasury);
        fpm.setPerfFeeExempt(alice, true); // comp granted mid-life

        uint256 tr0 = t0.balanceOf(treasury);
        vm.prank(alice);
        fpm.collect(id, _noZap(), 0, 0);
        assertEq(t0.balanceOf(treasury), tr0, "exemption must apply to future collections");

        // revoke, accrue more fees, collect again: fee flows again
        vm.prank(treasury);
        fpm.setPerfFeeExempt(alice, false);
        swap(key, false, -20e18, ZERO_BYTES);
        swap(key, true, -20e18, ZERO_BYTES);
        vm.prank(alice);
        fpm.collect(id, _noZap(), 0, 0);
        assertGt(t0.balanceOf(treasury) + t1.balanceOf(treasury), tr0, "revocation must restore the fee");
    }

    function test_treasury_twoStepTransfer() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectRevert(FriarPositionManager.NotTreasury.selector);
        fpm.setTreasury(newTreasury);

        vm.prank(treasury);
        fpm.setTreasury(newTreasury);
        assertEq(fpm.treasury(), treasury, "no change before accept");

        vm.expectRevert(FriarPositionManager.NotPendingTreasury.selector);
        fpm.acceptTreasury();

        vm.prank(newTreasury);
        fpm.acceptTreasury();
        assertEq(fpm.treasury(), newTreasury);
        assertEq(fpm.pendingTreasury(), address(0));
    }
}
