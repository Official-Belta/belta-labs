// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "@v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "@v4-core/libraries/Hooks.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@v4-core/libraries/StateLibrary.sol";
import {TickMath} from "@v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@v4-core/types/PoolOperation.sol";

import {PremiumOracle} from "./PremiumOracle.sol";

interface IUnderwriterPool {
    function receivePremium(uint256 amount) external;
    function payILClaim(address lp, uint256 amount) external;
}

/// @title BELTAHook
/// @notice Uniswap V4 Hook for IL measurement and premium collection
/// @dev Core hook contract for BELTA Labs IL hedging protocol.
///      Hook callbacks only perform accounting. Actual token transfers
///      happen via claimILPayout() and collectPremiums() outside hook context.
contract BELTAHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    // ─── Errors ─────────────────────────────────────────────
    error OnlyPoolManager();
    error EpochNotReady();
    error PositionNotFound();
    error NothingToClaim();
    error OnlyOwner();
    error OnlySettlement();

    // ─── Events ─────────────────────────────────────────────
    event PositionRegistered(
        PoolId indexed poolId, address indexed lp, int24 tickLower, int24 tickUpper, uint160 sqrtPriceAtEntry
    );
    event PositionRemoved(PoolId indexed poolId, address indexed lp, int24 tickLower, int24 tickUpper);
    event PremiumAccrued(PoolId indexed poolId, address indexed lp, uint256 amount);
    event ILCalculated(PoolId indexed poolId, address indexed lp, uint256 ilBps, uint256 payout);
    event ILClaimed(PoolId indexed poolId, address indexed lp, uint256 amount);
    event PremiumsCollected(PoolId indexed poolId, uint256 amount);
    event EpochAdvanced(PoolId indexed poolId, uint256 epoch, uint256 timestamp);

    // ─── Constants ──────────────────────────────────────────
    uint256 public constant COVERAGE_CAP_BPS = 3500; // 35% max IL coverage
    uint256 public constant EPOCH_DURATION = 7 days;
    uint256 public constant BPS = 10_000;
    uint256 public constant DAILY_PAY_LIMIT_BPS = 500; // 5% of pool per day

    // ─── State ──────────────────────────────────────────────
    IPoolManager public immutable poolManager;
    address public owner;

    struct LPPosition {
        uint160 sqrtPriceAtEntry;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 epochStart;
        uint256 premiumOwed; // accumulated premium owed (not yet collected)
        uint256 ilClaimable; // pending IL payout claimable by LP
        bool active;
    }

    struct EpochState {
        uint256 epochNumber;
        uint256 startTimestamp;
        uint160 sqrtPriceAtEpochStart;
    }

    mapping(PoolId => mapping(address => mapping(bytes32 => LPPosition))) public positions;
    mapping(PoolId => EpochState) public epochs;
    mapping(PoolId => uint256) public totalHedgedValue;
    mapping(PoolId => uint256) public poolCapacity;

    // Accounting: accumulated but not-yet-transferred premiums
    mapping(PoolId => uint256) public accumulatedPremiums;
    // Accounting: accumulated but not-yet-paid IL claims
    mapping(PoolId => uint256) public pendingILClaims;

    // Connected contracts
    IUnderwriterPool public underwriterPool;
    PremiumOracle public premiumOracle;
    address public epochSettlement;

    // ─── Modifiers ──────────────────────────────────────────
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // ─── Constructor ────────────────────────────────────────
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        // tx.origin ensures the EOA deployer is owner even when deployed via CREATE2 proxy
        owner = tx.origin;
    }

    // ─── Hook Permissions ───────────────────────────────────
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Hook Implementations ───────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert("not implemented");
    }

    function afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        epochs[poolId] = EpochState({epochNumber: 1, startTimestamp: block.timestamp, sqrtPriceAtEpochStart: sqrtPriceX96});
        emit EpochAdvanced(poolId, 1, block.timestamp);
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("not implemented");
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        if (hookData.length > 0 && _decodeBeltaOptIn(hookData)) {
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

            bytes32 posKey = _positionKey(params.tickLower, params.tickUpper);
            LPPosition storage pos = positions[poolId][sender][posKey];

            if (pos.active) {
                pos.liquidity += uint128(uint256(int256(params.liquidityDelta)));
            } else {
                positions[poolId][sender][posKey] = LPPosition({
                    sqrtPriceAtEntry: sqrtPriceX96,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidity: uint128(uint256(int256(params.liquidityDelta))),
                    epochStart: epochs[poolId].epochNumber,
                    premiumOwed: 0,
                    ilClaimable: 0,
                    active: true
                });
                totalHedgedValue[poolId] += uint256(int256(params.liquidityDelta));
            }

            emit PositionRegistered(poolId, sender, params.tickLower, params.tickUpper, sqrtPriceX96);
        }

        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("not implemented");
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        _settlePosition(poolId, sender, params.tickLower, params.tickUpper, params.liquidityDelta, feesAccrued);
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _settlePosition(
        PoolId poolId,
        address lp,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        BalanceDelta feesAccrued
    ) internal {
        bytes32 posKey = _positionKey(tickLower, tickUpper);
        LPPosition storage pos = positions[poolId][lp][posKey];
        if (!pos.active) return;

        _accruePremiuAndIL(poolId, lp, pos, feesAccrued);
        _updatePositionLiquidity(poolId, lp, pos, tickLower, tickUpper, liquidityDelta);
    }

    function _accruePremiuAndIL(PoolId poolId, address lp, LPPosition storage pos, BalanceDelta feesAccrued)
        internal
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        uint256 ilBps = _calculateIL(pos.sqrtPriceAtEntry, sqrtPriceX96, pos.tickLower, pos.tickUpper);
        uint256 coveredIL = ilBps > COVERAGE_CAP_BPS ? COVERAGE_CAP_BPS : ilBps;

        // Accrue premium (accounting only — no token transfer in hook)
        uint256 premiumRate = _getDynamicPremiumRate(poolId);
        uint256 premium = _absDelta(feesAccrued) * premiumRate / BPS;
        pos.premiumOwed += premium;
        accumulatedPremiums[poolId] += premium;
        emit PremiumAccrued(poolId, lp, premium);

        // Calculate IL payout (accounting only)
        if (coveredIL > 0) {
            uint256 payout = uint256(pos.liquidity) * coveredIL / BPS;
            pos.ilClaimable += payout;
            pendingILClaims[poolId] += payout;
            emit ILCalculated(poolId, lp, ilBps, payout);
        }
    }

    function _updatePositionLiquidity(
        PoolId poolId,
        address lp,
        LPPosition storage pos,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) internal {
        uint256 removedLiquidity = uint256(-liquidityDelta);
        if (removedLiquidity >= uint256(pos.liquidity)) {
            totalHedgedValue[poolId] -= uint256(pos.liquidity);
            pos.active = false;
            pos.liquidity = 0;
            emit PositionRemoved(poolId, lp, tickLower, tickUpper);
        } else {
            totalHedgedValue[poolId] -= removedLiquidity;
            pos.liquidity -= uint128(removedLiquidity);
        }
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert("not implemented");
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        EpochState storage epoch = epochs[poolId];
        if (block.timestamp >= epoch.startTimestamp + EPOCH_DURATION) {
            _advanceEpoch(key, poolId);
        }
        return (IHooks.afterSwap.selector, int128(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("not implemented");
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("not implemented");
    }

    // ─── External Settlement Functions (outside hook context) ─

    /// @notice LP claims their IL payout from UnderwriterPool
    function claimILPayout(PoolId poolId, int24 tickLower, int24 tickUpper) external {
        bytes32 posKey = _positionKey(tickLower, tickUpper);
        LPPosition storage pos = positions[poolId][msg.sender][posKey];

        uint256 claimable = pos.ilClaimable;
        if (claimable == 0) revert NothingToClaim();

        pos.ilClaimable = 0;
        pendingILClaims[poolId] -= claimable;

        // Actual token transfer: UnderwriterPool → LP
        underwriterPool.payILClaim(msg.sender, claimable);
        emit ILClaimed(poolId, msg.sender, claimable);
    }

    /// @notice Settlement contract collects accumulated premiums → UnderwriterPool
    /// @dev Called by EpochSettlement during epoch settlement
    function collectPremiums(PoolId poolId) external returns (uint256 collected) {
        if (msg.sender != epochSettlement && msg.sender != owner) revert OnlySettlement();

        collected = accumulatedPremiums[poolId];
        if (collected == 0) return 0;

        accumulatedPremiums[poolId] = 0;

        // Actual token transfer: premiums → UnderwriterPool
        // Note: In Phase 1, premiums are tracked as accounting entries.
        // The EpochSettlement contract handles the actual fund routing.
        emit PremiumsCollected(poolId, collected);
    }

    // ─── IL Calculation ─────────────────────────────────────

    function _calculateIL(uint160 sqrtPriceStart, uint160 sqrtPriceEnd, int24 tickLower, int24 tickUpper)
        internal
        pure
        returns (uint256 ilBps)
    {
        if (sqrtPriceStart == sqrtPriceEnd) return 0;

        uint256 sqrtStart = uint256(sqrtPriceStart);
        uint256 sqrtEnd = uint256(sqrtPriceEnd);

        uint256 sqrtR;
        if (sqrtEnd >= sqrtStart) {
            sqrtR = sqrtEnd * 1e18 / sqrtStart;
        } else {
            sqrtR = sqrtStart * 1e18 / sqrtEnd;
        }

        uint256 r = sqrtR * sqrtR / 1e18;
        uint256 numerator = 2 * sqrtR;
        uint256 denominator = 1e18 + r;
        uint256 ratio = numerator * 1e18 / denominator;

        uint256 ilV2;
        if (ratio >= 1e18) {
            ilV2 = 0;
        } else {
            ilV2 = 1e18 - ratio;
        }

        uint160 sqrtPaX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPbX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 sqrtPaOverPb = uint256(sqrtPaX96) * 1e18 / uint256(sqrtPbX96);

        if (sqrtPaOverPb >= 1e18) {
            return COVERAGE_CAP_BPS;
        }
        uint256 correction = 1e18 * 1e18 / (1e18 - sqrtPaOverPb);
        uint256 ilV3 = ilV2 * correction / 1e18;
        ilBps = ilV3 * BPS / 1e18;
    }

    // ─── Dynamic Premium ────────────────────────────────────

    function _getDynamicPremiumRate(PoolId poolId) internal view returns (uint256) {
        // Use PremiumOracle if connected, otherwise fallback
        if (address(premiumOracle) != address(0)) {
            uint256 utilization = _getUtilization(poolId);
            return premiumOracle.getPremiumRateForPool(poolId, utilization);
        }
        return _fallbackPremiumRate(poolId);
    }

    function _getUtilization(PoolId poolId) internal view returns (uint256) {
        uint256 capacity = poolCapacity[poolId];
        if (capacity == 0) return 0;
        return totalHedgedValue[poolId] * BPS / capacity;
    }

    function _fallbackPremiumRate(PoolId poolId) internal view returns (uint256) {
        uint256 utilization = _getUtilization(poolId);
        if (utilization <= 8000) return 1200; // 12% base
        uint256 excessUtil = utilization - 8000;
        return 1200 + (1200 * 2 * excessUtil / 2000); // up to 3x
    }

    // ─── Epoch Management ───────────────────────────────────

    function _advanceEpoch(PoolKey calldata, PoolId poolId) internal {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        EpochState storage epoch = epochs[poolId];
        epoch.epochNumber += 1;
        epoch.startTimestamp = block.timestamp;
        epoch.sqrtPriceAtEpochStart = sqrtPriceX96;
        emit EpochAdvanced(poolId, epoch.epochNumber, block.timestamp);
    }

    function advanceEpoch(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        EpochState storage epoch = epochs[poolId];
        if (block.timestamp < epoch.startTimestamp + EPOCH_DURATION) revert EpochNotReady();
        _advanceEpoch(key, poolId);
    }

    // ─── Admin Functions ────────────────────────────────────

    function setUnderwriterPool(address _pool) external onlyOwner {
        underwriterPool = IUnderwriterPool(_pool);
    }

    function setPremiumOracle(address _oracle) external onlyOwner {
        premiumOracle = PremiumOracle(_oracle);
    }

    function setEpochSettlement(address _settlement) external onlyOwner {
        epochSettlement = _settlement;
    }

    function setPoolCapacity(PoolId poolId, uint256 capacity) external {
        require(msg.sender == address(underwriterPool) || msg.sender == owner, "unauthorized");
        poolCapacity[poolId] = capacity;
    }

    // ─── View Functions ─────────────────────────────────────

    function getPosition(PoolId poolId, address lp, int24 tickLower, int24 tickUpper)
        external
        view
        returns (LPPosition memory)
    {
        return positions[poolId][lp][_positionKey(tickLower, tickUpper)];
    }

    function getCurrentEpoch(PoolId poolId) external view returns (uint256) {
        return epochs[poolId].epochNumber;
    }

    function getUtilization(PoolId poolId) external view returns (uint256) {
        return _getUtilization(poolId);
    }

    function getCurrentPremiumRate(PoolId poolId) external view returns (uint256) {
        return _getDynamicPremiumRate(poolId);
    }

    function getClaimable(PoolId poolId, address lp, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256)
    {
        return positions[poolId][lp][_positionKey(tickLower, tickUpper)].ilClaimable;
    }

    // ─── Internal Helpers ───────────────────────────────────

    function _positionKey(int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tickLower, tickUpper));
    }

    function _decodeBeltaOptIn(bytes calldata hookData) internal pure returns (bool) {
        return hookData[0] == 0x01;
    }

    function _absDelta(BalanceDelta delta) internal pure returns (uint256) {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        uint256 abs0 = a0 >= 0 ? uint256(int256(a0)) : uint256(int256(-a0));
        uint256 abs1 = a1 >= 0 ? uint256(int256(a1)) : uint256(int256(-a1));
        return abs0 + abs1;
    }
}
