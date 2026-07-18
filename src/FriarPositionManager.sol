// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Multi-tenant position manager: opens/closes a whole Position (N bins) as one
/// atomic unit inside a single PoolManager unlock. Anyone may open; only the position
/// owner may increase/decrease/collect/close. Every verb supports a no-swap path and a
/// swap path (swap-in on open/increase: quote -> inventory funds the ask bins; zap-out
/// on decrease/collect/close: inventory -> quote in the same unlock).
///
/// The full position definition (owner + pool key + bins) lives on-chain: an owner can
/// exit knowing only the positionId, with no dependency on any off-chain service.
///
/// Fee share: `perfFeeBps` of fees earned (v4's `feesAccrued`, reported separately from
/// principal by modifyLiquidity) is taken in-kind to the treasury whenever fees are
/// collected. Principal is never touched. The rate is immutable; the treasury address
/// (two-step transferable) is the only privileged state. `perfFeeExempt` (the house bot)
/// pays no perf fee. Payouts always go to the position owner — never a third address.
contract FriarPositionManager is IUnlockCallback {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    error NotPoolManager();
    error NotPositionOwner();
    error UnknownPosition();
    error NativeCurrencyUnsupported();
    error VenueMismatch();
    error InvalidBins();
    error LengthMismatch();
    error DecreaseExceedsLiquidity();
    error SwapInsufficientOutput();
    error PaidTooMuch();
    error ReceivedTooLittle();
    error NotTreasury();
    error NotPendingTreasury();
    error PerfFeeTooHigh();

    uint256 public constant MAX_BINS = 100;
    uint256 public constant MAX_PERF_FEE_BPS = 2_000; // hard sanity cap: 20%
    uint256 internal constant BPS = 10_000;

    IPoolManager public immutable manager;
    uint16 public immutable perfFeeBps;
    /// @notice fee-exempt accounts (house bot, partners). Treasury-controlled: a
    /// discount-only power — it can never raise fees or touch principal. Checked at
    /// operation time, so changes apply to existing positions' future collections.
    mapping(address => bool) public perfFeeExempt;
    address public treasury;
    address public pendingTreasury;

    struct Bin {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct Position {
        address owner;
        uint96 ownerIndex; // index into _ownerIds[owner]
        PoolKey key;
        Bin[] bins;
    }

    /// @dev Entry swap: spend `amountIn` of one side to fund the other before minting.
    struct SwapIn {
        bool enabled;
        PoolKey venue; // must share both currencies with the position's pool
        bool zeroForOne;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    /// @dev Exit swap: convert the whole positive credit of the input side to the other
    /// side in the same unlock. Output floor is enforced by the verb's min amounts.
    struct Zap {
        bool enabled;
        PoolKey venue; // must share both currencies with the position's pool
        bool zeroForOne;
    }

    enum Action {
        Open,
        Increase,
        Decrease,
        Collect
    }

    struct BinDelta {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    struct Op {
        Action action;
        uint256 positionId;
        address account; // position owner: sole payer and sole payout recipient
        bool exempt;
        PoolKey key;
        BinDelta[] bins;
        SwapIn swapIn;
        Zap zap;
    }

    /// @dev delta0/delta1: the owner's net cash flow (positive = received, negative = paid).
    struct OpResult {
        int256 delta0;
        int256 delta1;
        uint256 fees0;
        uint256 fees1;
        uint256 perf0;
        uint256 perf1;
    }

    mapping(uint256 => Position) internal _positions;
    mapping(address => uint256[]) internal _ownerIds;
    uint256 public nextPositionId = 1;

    event PositionOpened(
        uint256 indexed positionId,
        address indexed owner,
        bytes32 indexed poolId,
        PoolKey key,
        Bin[] bins,
        int256 delta0,
        int256 delta1
    );
    event PositionIncreased(
        uint256 indexed positionId, uint128[] liquidityDeltas, int256 delta0, int256 delta1, uint256 fees0, uint256 fees1
    );
    event PositionDecreased(
        uint256 indexed positionId,
        uint128[] liquidityDeltas,
        int256 delta0,
        int256 delta1,
        uint256 fees0,
        uint256 fees1,
        bool closed
    );
    event FeesCollected(uint256 indexed positionId, uint256 fees0, uint256 fees1, int256 delta0, int256 delta1);
    event PerfFeeCharged(uint256 indexed positionId, address indexed treasury, uint256 perf0, uint256 perf1);
    event PerfFeeExemptSet(address indexed account, bool exempt);
    event TreasuryTransferStarted(address indexed from, address indexed to);
    event TreasuryTransferred(address indexed from, address indexed to);

    constructor(IPoolManager _manager, uint16 _perfFeeBps, address _treasury, address _perfFeeExempt) {
        if (_perfFeeBps > MAX_PERF_FEE_BPS) revert PerfFeeTooHigh();
        manager = _manager;
        perfFeeBps = _perfFeeBps;
        treasury = _treasury;
        if (_perfFeeExempt != address(0)) {
            perfFeeExempt[_perfFeeExempt] = true;
            emit PerfFeeExemptSet(_perfFeeExempt, true);
        }
    }

    // ---------------------------------------------------------------- verbs

    /// @notice Mint all bins atomically and record the position. `maxPay0/1` cap what
    /// the caller can be charged. With `swapIn`, ask-side inventory is funded by an
    /// in-unlock swap and any surplus sweeps back to the caller. The pool must already
    /// be initialized — to create it and seed it in one transaction, use `openNew`.
    function open(PoolKey calldata key, Bin[] calldata bins, SwapIn calldata swapIn, uint256 maxPay0, uint256 maxPay1)
        external
        returns (uint256 positionId)
    {
        return _open(key, bins, swapIn, maxPay0, maxPay1);
    }

    /// @notice Create the pool at `sqrtPriceX96` and open the first position, atomically.
    /// Reverts (`PoolAlreadyInitialized`) if the pool exists — the chosen price is then
    /// stale, so re-quote against the live pool and call `open` instead. The first LP
    /// sets the pool price unilaterally: seed at market or be arbitrage food.
    function openNew(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        Bin[] calldata bins,
        SwapIn calldata swapIn,
        uint256 maxPay0,
        uint256 maxPay1
    ) external returns (uint256 positionId) {
        manager.initialize(key, sqrtPriceX96);
        return _open(key, bins, swapIn, maxPay0, maxPay1);
    }

    function _open(PoolKey calldata key, Bin[] calldata bins, SwapIn calldata swapIn, uint256 maxPay0, uint256 maxPay1)
        internal
        returns (uint256 positionId)
    {
        if (Currency.unwrap(key.currency0) == address(0)) revert NativeCurrencyUnsupported();
        uint256 n = bins.length;
        if (n == 0 || n > MAX_BINS) revert InvalidBins();

        positionId = nextPositionId++;
        Position storage p = _positions[positionId];
        p.owner = msg.sender;
        p.key = key;

        BinDelta[] memory deltas = new BinDelta[](n);
        for (uint256 i = 0; i < n; i++) {
            Bin calldata b = bins[i];
            if (b.liquidity == 0) revert InvalidBins();
            p.bins.push(b);
            deltas[i] = BinDelta(b.tickLower, b.tickUpper, int256(uint256(b.liquidity)), binSalt(positionId, i));
        }
        _ownerIds[msg.sender].push(positionId);
        p.ownerIndex = uint96(_ownerIds[msg.sender].length - 1);

        Zap memory noZap;
        OpResult memory r = _run(Op(Action.Open, positionId, msg.sender, _isExempt(msg.sender), key, deltas, swapIn, noZap));
        _checkPay(r, maxPay0, maxPay1);

        emit PositionOpened(positionId, msg.sender, PoolId.unwrap(key.toId()), key, bins, r.delta0, r.delta1);
        _emitPerfFee(positionId, r);
    }

    /// @notice Add liquidity to existing bins (entry per bin; 0 = leave untouched).
    /// Fees on touched bins are auto-collected by v4 and charged like any collection.
    function increase(
        uint256 positionId,
        uint128[] calldata liquidityDeltas,
        SwapIn calldata swapIn,
        uint256 maxPay0,
        uint256 maxPay1
    ) external {
        Position storage p = _requireOwner(positionId);
        uint256 n = p.bins.length;
        if (liquidityDeltas.length != n) revert LengthMismatch();

        BinDelta[] memory deltas = new BinDelta[](n);
        for (uint256 i = 0; i < n; i++) {
            uint128 d = liquidityDeltas[i];
            Bin storage b = p.bins[i];
            if (d > 0) b.liquidity += d;
            deltas[i] = BinDelta(b.tickLower, b.tickUpper, int256(uint256(d)), binSalt(positionId, i));
        }

        Zap memory noZap;
        OpResult memory r =
            _run(Op(Action.Increase, positionId, msg.sender, _isExempt(msg.sender), p.key, deltas, swapIn, noZap));
        _checkPay(r, maxPay0, maxPay1);

        emit PositionIncreased(positionId, liquidityDeltas, r.delta0, r.delta1, r.fees0, r.fees1);
        _emitPerfFee(positionId, r);
    }

    /// @notice Remove liquidity (amount per bin). Removing everything deletes the
    /// record. `minReceive0/1` floor the owner's net receipts (post-perf fee, post-zap).
    function decrease(
        uint256 positionId,
        uint128[] calldata liquidityDeltas,
        Zap calldata zap,
        uint256 minReceive0,
        uint256 minReceive1
    ) external {
        Position storage p = _requireOwner(positionId);
        uint256 n = p.bins.length;
        if (liquidityDeltas.length != n) revert LengthMismatch();
        uint128[] memory ds = new uint128[](n);
        for (uint256 i = 0; i < n; i++) {
            ds[i] = liquidityDeltas[i];
        }
        _decrease(positionId, p, ds, zap, minReceive0, minReceive1);
    }

    /// @notice Exit knowing only the positionId: removes all remaining liquidity using
    /// the on-chain record. No bins, no off-chain data, no backend required.
    function close(uint256 positionId, Zap calldata zap, uint256 minReceive0, uint256 minReceive1) external {
        Position storage p = _requireOwner(positionId);
        uint256 n = p.bins.length;
        uint128[] memory ds = new uint128[](n);
        for (uint256 i = 0; i < n; i++) {
            ds[i] = p.bins[i].liquidity;
        }
        _decrease(positionId, p, ds, zap, minReceive0, minReceive1);
    }

    /// @notice Claim fees without touching liquidity (a 0-delta poke on every bin).
    /// Fee amounts don't depend on price, so no-zap collection needs no floors; with a
    /// zap the floors guard the swap output.
    function collect(uint256 positionId, Zap calldata zap, uint256 minReceive0, uint256 minReceive1) external {
        Position storage p = _requireOwner(positionId);
        uint256 n = p.bins.length;

        BinDelta[] memory deltas = new BinDelta[](n);
        for (uint256 i = 0; i < n; i++) {
            Bin storage b = p.bins[i];
            deltas[i] = BinDelta(b.tickLower, b.tickUpper, 0, binSalt(positionId, i));
        }

        SwapIn memory noSwapIn;
        OpResult memory r =
            _run(Op(Action.Collect, positionId, msg.sender, _isExempt(msg.sender), p.key, deltas, noSwapIn, zap));
        _checkReceive(r, minReceive0, minReceive1);

        emit FeesCollected(positionId, r.fees0, r.fees1, r.delta0, r.delta1);
        _emitPerfFee(positionId, r);
    }

    // ------------------------------------------------------------- treasury

    function setTreasury(address newTreasury) external {
        if (msg.sender != treasury) revert NotTreasury();
        pendingTreasury = newTreasury;
        emit TreasuryTransferStarted(treasury, newTreasury);
    }

    function acceptTreasury() external {
        if (msg.sender != pendingTreasury) revert NotPendingTreasury();
        emit TreasuryTransferred(treasury, msg.sender);
        treasury = msg.sender;
        pendingTreasury = address(0);
    }

    /// @notice Grant or revoke perf fee exemption. Discount-only: cannot raise anyone's
    /// fees, cannot touch principal — the worst a rogue treasury does here is waive
    /// its own revenue.
    function setPerfFeeExempt(address account, bool exempt) external {
        if (msg.sender != treasury) revert NotTreasury();
        perfFeeExempt[account] = exempt;
        emit PerfFeeExemptSet(account, exempt);
    }

    // ---------------------------------------------------------------- views

    function getPosition(uint256 positionId)
        external
        view
        returns (address owner, PoolKey memory key, Bin[] memory bins)
    {
        Position storage p = _positions[positionId];
        if (p.owner == address(0)) revert UnknownPosition();
        return (p.owner, p.key, p.bins);
    }

    function positionsOf(address owner) external view returns (uint256[] memory) {
        return _ownerIds[owner];
    }

    /// @dev Salts are pure-derivable so any indexer can compute v4 position keys.
    function binSalt(uint256 positionId, uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(positionId, index));
    }

    // ------------------------------------------------------------- internal

    function _requireOwner(uint256 positionId) internal view returns (Position storage p) {
        p = _positions[positionId];
        if (p.owner == address(0)) revert UnknownPosition();
        if (p.owner != msg.sender) revert NotPositionOwner();
    }

    function _isExempt(address account) internal view returns (bool) {
        return perfFeeExempt[account];
    }

    function _decrease(
        uint256 positionId,
        Position storage p,
        uint128[] memory liquidityDeltas,
        Zap calldata zap,
        uint256 minReceive0,
        uint256 minReceive1
    ) internal {
        uint256 n = p.bins.length;
        bool anyLeft = false;
        BinDelta[] memory deltas = new BinDelta[](n);
        for (uint256 i = 0; i < n; i++) {
            uint128 d = liquidityDeltas[i];
            Bin storage b = p.bins[i];
            if (d > b.liquidity) revert DecreaseExceedsLiquidity();
            b.liquidity -= d;
            if (b.liquidity > 0) anyLeft = true;
            deltas[i] = BinDelta(b.tickLower, b.tickUpper, -int256(uint256(d)), binSalt(positionId, i));
        }

        SwapIn memory noSwapIn;
        OpResult memory r =
            _run(Op(Action.Decrease, positionId, msg.sender, _isExempt(msg.sender), p.key, deltas, noSwapIn, zap));
        _checkReceive(r, minReceive0, minReceive1);

        bool closed = !anyLeft;
        emit PositionDecreased(positionId, liquidityDeltas, r.delta0, r.delta1, r.fees0, r.fees1, closed);
        _emitPerfFee(positionId, r);
        if (closed) _remove(positionId, p);
    }

    function _remove(uint256 positionId, Position storage p) internal {
        uint256[] storage ids = _ownerIds[p.owner];
        uint256 idx = p.ownerIndex;
        uint256 last = ids[ids.length - 1];
        if (last != positionId) {
            ids[idx] = last;
            _positions[last].ownerIndex = uint96(idx);
        }
        ids.pop();
        delete _positions[positionId];
    }

    function _run(Op memory op) internal returns (OpResult memory r) {
        if (op.swapIn.enabled) _requireSameCurrencies(op.key, op.swapIn.venue);
        if (op.zap.enabled) _requireSameCurrencies(op.key, op.zap.venue);
        r = abi.decode(manager.unlock(abi.encode(op)), (OpResult));
    }

    function _requireSameCurrencies(PoolKey memory key, PoolKey memory venue) internal pure {
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(venue.currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(venue.currency1)
        ) revert VenueMismatch();
    }

    function _checkPay(OpResult memory r, uint256 maxPay0, uint256 maxPay1) internal pure {
        if (r.delta0 < 0 && uint256(-r.delta0) > maxPay0) revert PaidTooMuch();
        if (r.delta1 < 0 && uint256(-r.delta1) > maxPay1) revert PaidTooMuch();
    }

    function _checkReceive(OpResult memory r, uint256 minReceive0, uint256 minReceive1) internal pure {
        uint256 got0 = r.delta0 > 0 ? uint256(r.delta0) : 0;
        uint256 got1 = r.delta1 > 0 ? uint256(r.delta1) : 0;
        if (got0 < minReceive0 || got1 < minReceive1) revert ReceivedTooLittle();
    }

    function _emitPerfFee(uint256 positionId, OpResult memory r) internal {
        if (r.perf0 > 0 || r.perf1 > 0) emit PerfFeeCharged(positionId, treasury, r.perf0, r.perf1);
    }

    // ------------------------------------------------------------- callback

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        Op memory op = abi.decode(data, (Op));
        OpResult memory r;

        if (op.swapIn.enabled) {
            manager.swap(
                op.swapIn.venue,
                SwapParams({
                    zeroForOne: op.swapIn.zeroForOne,
                    amountSpecified: -int256(op.swapIn.amountIn),
                    sqrtPriceLimitX96: op.swapIn.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            Currency swapOut = op.swapIn.zeroForOne ? op.swapIn.venue.currency1 : op.swapIn.venue.currency0;
            if (manager.currencyDelta(address(this), swapOut) < int256(op.swapIn.minAmountOut)) {
                revert SwapInsufficientOutput();
            }
        }

        for (uint256 i = 0; i < op.bins.length; i++) {
            BinDelta memory b = op.bins[i];
            (, BalanceDelta feesAccrued) = manager.modifyLiquidity(
                op.key,
                ModifyLiquidityParams({
                    tickLower: b.tickLower,
                    tickUpper: b.tickUpper,
                    liquidityDelta: b.liquidityDelta,
                    salt: b.salt
                }),
                ""
            );
            int128 f0 = feesAccrued.amount0();
            int128 f1 = feesAccrued.amount1();
            if (f0 > 0) r.fees0 += uint256(uint128(f0));
            if (f1 > 0) r.fees1 += uint256(uint128(f1));
        }

        if (!op.exempt && perfFeeBps > 0) {
            r.perf0 = (r.fees0 * perfFeeBps) / BPS;
            r.perf1 = (r.fees1 * perfFeeBps) / BPS;
            if (r.perf0 > 0) op.key.currency0.take(manager, treasury, r.perf0, false);
            if (r.perf1 > 0) op.key.currency1.take(manager, treasury, r.perf1, false);
        }

        if (op.zap.enabled) {
            Currency zapIn = op.zap.zeroForOne ? op.zap.venue.currency0 : op.zap.venue.currency1;
            int256 credit = manager.currencyDelta(address(this), zapIn);
            if (credit > 0) {
                manager.swap(
                    op.zap.venue,
                    SwapParams({
                        zeroForOne: op.zap.zeroForOne,
                        amountSpecified: -credit,
                        sqrtPriceLimitX96: op.zap.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    }),
                    ""
                );
            }
        }

        r.delta0 = _resolve(op.key.currency0, op.account);
        r.delta1 = _resolve(op.key.currency1, op.account);
        return abi.encode(r);
    }

    /// @dev Settle what the account owes / take what the account is due. The account is
    /// always the position owner: funds can never be directed anywhere else.
    function _resolve(Currency currency, address account) internal returns (int256 delta) {
        delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            currency.settle(manager, account, uint256(-delta), false);
        } else if (delta > 0) {
            currency.take(manager, account, uint256(delta), false);
        }
    }
}
