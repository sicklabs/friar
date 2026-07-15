// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {FriarMath} from "./FriarMath.sol";

/// @title Friar — a volatility-responsive dynamic LP fee hook (Tuck protocol)
/// @notice Sets a Uniswap v4 pool's LP fee per swap using the Liquidity Book
/// volatility-accumulator mechanism (Trader Joe / LFJ `lfj-gg/joe-v2`, MIT — the same
/// fee model Meteora's DLMM uses on Solana): a low base fee in calm markets that
/// surges with recent price movement and decays back after the configured windows.
///
/// Trust profile, by construction:
/// - Permission bits: AFTER_INITIALIZE + BEFORE_SWAP only. The hook's address proves
///   it can never take swap deltas, own liquidity, or touch user funds.
/// - No owner, no admin functions, no upgradeability. All parameters are immutable;
///   a different configuration means deploying a new Friar.
/// - No protocol fee of any kind is taken. The fee set here is the LP fee, paid
///   entirely to the pool's liquidity providers.
/// - Total fee is hard-capped at 10% (LB `MAX_FEE`), enforced both at pool
///   initialization (base fee sanity) and on every swap.
///
/// Known deviation from Liquidity Book: LB escalates the fee per bin crossed within
/// a single swap; a beforeSwap hook prices each swap from movement observed up to
/// that swap. Movement caused by a swap raises the fee charged to subsequent swaps
/// inside the filter/decay windows (one-swap lag).
contract Friar is IHooks {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using FriarMath for FriarMath.VolatilityState;

    error NotPoolManager();
    error HookNotImplemented();
    error NotDynamicFeePool();
    error InvalidParameters();
    error BaseFeeExceedsCap();

    IPoolManager public immutable poolManager;

    uint16 public immutable baseFactor;
    uint16 public immutable filterPeriod;
    uint16 public immutable decayPeriod;
    uint16 public immutable reductionFactor;
    uint24 public immutable variableFeeControl;
    uint24 public immutable maxVolatilityAccumulator;

    mapping(PoolId => FriarMath.VolatilityState) internal _volatility;

    constructor(
        IPoolManager _poolManager,
        uint16 _baseFactor,
        uint16 _filterPeriod,
        uint16 _decayPeriod,
        uint16 _reductionFactor,
        uint24 _variableFeeControl,
        uint24 _maxVolatilityAccumulator
    ) {
        // Same bounds LB enforces in `setStaticFeeParameters` (uint12/uint14/uint20 encodings).
        if (
            _filterPeriod > _decayPeriod || _decayPeriod > 4095 || _reductionFactor > FriarMath.BASIS_POINT_MAX
                || _maxVolatilityAccumulator > 1_048_575
        ) revert InvalidParameters();

        poolManager = _poolManager;
        baseFactor = _baseFactor;
        filterPeriod = _filterPeriod;
        decayPeriod = _decayPeriod;
        reductionFactor = _reductionFactor;
        variableFeeControl = _variableFeeControl;
        maxVolatilityAccumulator = _maxVolatilityAccumulator;

        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function params() public view returns (FriarMath.Params memory) {
        return FriarMath.Params({
            baseFactor: baseFactor,
            filterPeriod: filterPeriod,
            decayPeriod: decayPeriod,
            reductionFactor: reductionFactor,
            variableFeeControl: variableFeeControl,
            maxVolatilityAccumulator: maxVolatilityAccumulator
        });
    }

    /// @notice Current stored volatility state for a pool (as of its last swap).
    function volatilityState(PoolId poolId) external view returns (FriarMath.VolatilityState memory) {
        return _volatility[poolId];
    }

    /// @notice The fee (in pips) a swap would pay right now — the LB `getSwapIn/Out`
    /// analogue for off-chain quoting and the operator bot.
    function previewFee(PoolKey calldata key) external view returns (uint24) {
        PoolId poolId = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(poolId);

        FriarMath.VolatilityState memory vol = _volatility[poolId];
        FriarMath.Params memory p = params();
        vol.update(p, FriarMath.bucketOf(tick, key.tickSpacing), block.timestamp);

        return FriarMath.totalFeePips(p, vol.volatilityAccumulator, _binStep(key.tickSpacing));
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFeePool();
        if (FriarMath.baseFee1e18(params(), _binStep(key.tickSpacing)) > FriarMath.MAX_FEE_1E18) {
            revert BaseFeeExceedsCap();
        }

        _volatility[key.toId()] = FriarMath.VolatilityState({
            volatilityAccumulator: 0,
            volatilityReference: 0,
            bucketReference: FriarMath.bucketOf(tick, key.tickSpacing),
            lastUpdate: uint40(block.timestamp)
        });

        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(poolId);

        FriarMath.VolatilityState memory vol = _volatility[poolId];
        FriarMath.Params memory p = params();
        vol.update(p, FriarMath.bucketOf(tick, key.tickSpacing), block.timestamp);
        _volatility[poolId] = vol;

        uint24 fee = FriarMath.totalFeePips(p, vol.volatilityAccumulator, _binStep(key.tickSpacing));

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _binStep(int24 tickSpacing) internal pure returns (uint16) {
        // MAX_TICK_SPACING is 32767, so the cast is always safe.
        return uint16(uint24(tickSpacing));
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
