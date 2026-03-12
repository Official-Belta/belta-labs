// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {PoolId} from "@v4-core/types/PoolId.sol";

/// @notice Minimal interface for perpetual futures protocol (dYdX, GMX, Hyperliquid)
/// @dev Actual implementation depends on target chain perps protocol.
///      This interface abstracts the core operations needed for delta-hedging.
interface IPerpsAdapter {
    /// @notice Open or increase a short position
    /// @param size Notional size in USD (6 decimals for USDC)
    /// @param collateral Collateral amount
    function openShort(uint256 size, uint256 collateral) external;

    /// @notice Close or reduce a short position
    /// @param size Notional size to close
    function closeShort(uint256 size) external;

    /// @notice Get current position PnL
    /// @return pnl Signed PnL (positive = profit, negative = loss)
    function getPositionPnL() external view returns (int256 pnl);

    /// @notice Get current short position size
    /// @return size Current notional short size
    function getShortSize() external view returns (uint256 size);

    /// @notice Withdraw realized PnL to address
    function withdrawPnL(address to) external returns (uint256 amount);
}

/// @title HedgeManager — Layer 3: Perps Delta-Hedging
/// @notice Manages short perpetual futures positions to offset IL claim exposure
/// @dev The UnderwriterPool's IL liability increases when ETH price moves.
///      This contract shorts ETH via perps to create an offsetting position.
///
///      Strategy:
///      - Target hedge ratio: 50% of total hedged LP value (delta ≈ 0.5 for LP)
///      - Rebalance when actual hedge deviates > 10% from target
///      - Keeper calls rebalance() periodically or when threshold is met
///
///      PnL Flow:
///      - ETH drops → IL claims increase → but short profits offset
///      - ETH rises → IL claims decrease → short losses absorbed by reduced claims
contract HedgeManager {
    using SafeTransferLib for ERC20;

    // ─── Errors ─────────────────────────────────────────────
    error OnlyOwner();
    error OnlyKeeper();
    error OnlyAuthorized();
    error AdapterNotSet();
    error HedgingDisabled();
    error RebalanceNotNeeded();

    // ─── Events ─────────────────────────────────────────────
    event HedgeOpened(PoolId indexed poolId, uint256 shortSize, uint256 collateral);
    event HedgeClosed(PoolId indexed poolId, uint256 shortSize);
    event HedgeRebalanced(PoolId indexed poolId, uint256 oldSize, uint256 newSize);
    event HedgePnLRealized(PoolId indexed poolId, int256 pnl);
    event AdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    // ─── Constants ──────────────────────────────────────────
    uint256 public constant BPS = 10_000;
    uint256 public constant TARGET_HEDGE_RATIO_BPS = 5000;  // 50% of hedged value
    uint256 public constant REBALANCE_THRESHOLD_BPS = 1000; // Rebalance if >10% off target
    uint256 public constant MAX_LEVERAGE = 3;               // Max 3x leverage on perps
    uint256 public constant MIN_REBALANCE_INTERVAL = 4 hours;

    // ─── State ──────────────────────────────────────────────
    ERC20 public immutable collateralAsset; // USDC
    address public owner;
    address public keeper;

    // Perps protocol adapter
    IPerpsAdapter public perpsAdapter;
    bool public hedgingEnabled;

    // Per-pool hedge tracking
    struct HedgeState {
        uint256 targetShortSize;    // Desired short notional
        uint256 actualShortSize;    // Current short notional
        uint256 collateralDeployed; // Collateral locked in perps
        uint256 lastRebalanceTime;
        int256 cumulativePnL;       // Total realized PnL
    }

    mapping(PoolId => HedgeState) public hedgeStates;

    // Connected contracts
    address public underwriterPool;

    // ─── Constructor ────────────────────────────────────────
    constructor(ERC20 _collateral) {
        collateralAsset = _collateral;
        owner = msg.sender;
        keeper = msg.sender;
    }

    // ─── Modifiers ──────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner) revert OnlyKeeper();
        _;
    }

    // ─── Core: Hedge Management ─────────────────────────────

    /// @notice Update target hedge size based on current hedged LP value
    /// @param poolId Pool being hedged
    /// @param totalHedgedValue Total value of hedged LP positions (from BELTAHook)
    function updateTargetHedge(PoolId poolId, uint256 totalHedgedValue) external onlyKeeper {
        HedgeState storage hs = hedgeStates[poolId];

        // Target: hedge 50% of total hedged LP value
        hs.targetShortSize = totalHedgedValue * TARGET_HEDGE_RATIO_BPS / BPS;
    }

    /// @notice Rebalance hedge position to match target
    /// @dev Opens/closes shorts to bring actual position in line with target
    function rebalance(PoolId poolId) external onlyKeeper {
        if (!hedgingEnabled) revert HedgingDisabled();
        if (address(perpsAdapter) == address(0)) revert AdapterNotSet();

        HedgeState storage hs = hedgeStates[poolId];

        if (block.timestamp < hs.lastRebalanceTime + MIN_REBALANCE_INTERVAL) {
            revert RebalanceNotNeeded();
        }

        uint256 oldSize = hs.actualShortSize;
        uint256 targetSize = hs.targetShortSize;

        // Check if rebalance threshold is met
        uint256 deviation;
        if (oldSize > targetSize) {
            deviation = (oldSize - targetSize) * BPS / (targetSize > 0 ? targetSize : 1);
        } else {
            deviation = (targetSize - oldSize) * BPS / (targetSize > 0 ? targetSize : 1);
        }

        if (deviation < REBALANCE_THRESHOLD_BPS && oldSize > 0) {
            revert RebalanceNotNeeded();
        }

        if (targetSize > oldSize) {
            // Need to increase short
            uint256 increaseSize = targetSize - oldSize;
            uint256 collateral = increaseSize / MAX_LEVERAGE;

            // Transfer collateral to adapter
            collateralAsset.safeTransfer(address(perpsAdapter), collateral);
            perpsAdapter.openShort(increaseSize, collateral);

            hs.collateralDeployed += collateral;
            emit HedgeOpened(poolId, increaseSize, collateral);

        } else if (targetSize < oldSize) {
            // Need to decrease short
            uint256 decreaseSize = oldSize - targetSize;
            perpsAdapter.closeShort(decreaseSize);
            emit HedgeClosed(poolId, decreaseSize);
        }

        hs.actualShortSize = targetSize;
        hs.lastRebalanceTime = block.timestamp;

        emit HedgeRebalanced(poolId, oldSize, targetSize);
    }

    /// @notice Realize PnL from hedge and return to underwriter pool
    function realizePnL(PoolId poolId) external onlyKeeper {
        if (address(perpsAdapter) == address(0)) revert AdapterNotSet();

        int256 pnl = perpsAdapter.getPositionPnL();
        hedgeStates[poolId].cumulativePnL += pnl;

        if (pnl > 0) {
            // Withdraw profits to underwriter pool
            uint256 profit = perpsAdapter.withdrawPnL(underwriterPool);
            emit HedgePnLRealized(poolId, int256(profit));
        } else {
            emit HedgePnLRealized(poolId, pnl);
        }
    }

    /// @notice Emergency: close all hedge positions
    function emergencyClose(PoolId poolId) external onlyOwner {
        HedgeState storage hs = hedgeStates[poolId];
        if (hs.actualShortSize > 0 && address(perpsAdapter) != address(0)) {
            perpsAdapter.closeShort(hs.actualShortSize);
            hs.actualShortSize = 0;
            hs.targetShortSize = 0;
            emit HedgeClosed(poolId, hs.actualShortSize);
        }
    }

    // ─── View Functions ─────────────────────────────────────

    /// @notice Check if rebalance is needed for a pool
    function needsRebalance(PoolId poolId) external view returns (bool) {
        HedgeState storage hs = hedgeStates[poolId];

        if (!hedgingEnabled || hs.targetShortSize == 0) return false;
        if (block.timestamp < hs.lastRebalanceTime + MIN_REBALANCE_INTERVAL) return false;

        uint256 target = hs.targetShortSize;
        uint256 actual = hs.actualShortSize;

        uint256 deviation;
        if (actual > target) {
            deviation = (actual - target) * BPS / target;
        } else {
            deviation = (target - actual) * BPS / (target > 0 ? target : 1);
        }

        return deviation >= REBALANCE_THRESHOLD_BPS;
    }

    /// @notice Get current hedge effectiveness
    /// @return hedgeRatioBps Actual hedge as % of target (10000 = perfectly hedged)
    function getHedgeRatio(PoolId poolId) external view returns (uint256 hedgeRatioBps) {
        HedgeState storage hs = hedgeStates[poolId];
        if (hs.targetShortSize == 0) return 0;
        return hs.actualShortSize * BPS / hs.targetShortSize;
    }

    /// @notice Get current unrealized PnL
    function getUnrealizedPnL() external view returns (int256) {
        if (address(perpsAdapter) == address(0)) return 0;
        return perpsAdapter.getPositionPnL();
    }

    function getHedgeState(PoolId poolId) external view returns (HedgeState memory) {
        return hedgeStates[poolId];
    }

    // ─── Admin ──────────────────────────────────────────────

    function setPerpsAdapter(address _adapter) external onlyOwner {
        emit AdapterUpdated(address(perpsAdapter), _adapter);
        perpsAdapter = IPerpsAdapter(_adapter);
    }

    function setHedgingEnabled(bool _enabled) external onlyOwner {
        hedgingEnabled = _enabled;
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
    }

    function setUnderwriterPool(address _pool) external onlyOwner {
        underwriterPool = _pool;
    }

    /// @notice Fund the hedge manager with collateral
    function fundCollateral(uint256 amount) external {
        collateralAsset.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw unused collateral
    function withdrawCollateral(uint256 amount, address to) external onlyOwner {
        collateralAsset.safeTransfer(to, amount);
    }
}
