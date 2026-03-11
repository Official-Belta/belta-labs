// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";

interface IBELTAHookSettlement {
    function getCurrentEpoch(PoolId poolId) external view returns (uint256);
    function accumulatedPremiums(PoolId poolId) external view returns (uint256);
    function collectPremiums(PoolId poolId) external returns (uint256);
    function pendingILClaims(PoolId poolId) external view returns (uint256);
}

interface IUnderwriterPoolSettlement {
    function syncCapacity(PoolId poolId) external;
    function receivePremium(uint256 amount) external;
    function totalAssets() external view returns (uint256);
}

interface ITreasuryModuleSettlement {
    function needsSelfHealing() external view returns (bool);
    function distributeProfits(uint256 totalProfit) external;
}

/// @title EpochSettlement
/// @notice Manages 7-day epoch IL settlement cycles
/// @dev Coordinates actual fund flows between BELTAHook, UnderwriterPool, and TreasuryModule
contract EpochSettlement {
    using PoolIdLibrary for PoolKey;

    // ─── Errors ─────────────────────────────────────────────
    error OnlyKeeper();
    error EpochNotFinalized();
    error AlreadySettled();
    error OnlyOwner();

    // ─── Events ─────────────────────────────────────────────
    event SettlementExecuted(
        PoolId indexed poolId, uint256 epoch, uint256 premiumsCollected, uint256 pendingClaims
    );
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);

    // ─── State ──────────────────────────────────────────────
    IBELTAHookSettlement public immutable hook;
    IUnderwriterPoolSettlement public immutable pool;
    ITreasuryModuleSettlement public treasury;
    address public owner;
    address public keeper;

    struct Settlement {
        uint256 epoch;
        uint256 timestamp;
        uint256 premiumsCollected;
        uint256 pendingClaims;
        bool settled;
    }

    mapping(PoolId => mapping(uint256 => Settlement)) public settlements;
    mapping(PoolId => uint256) public lastSettledEpoch;

    // ─── Constructor ────────────────────────────────────────
    constructor(address _hook, address _pool) {
        hook = IBELTAHookSettlement(_hook);
        pool = IUnderwriterPoolSettlement(_pool);
        owner = msg.sender;
        keeper = msg.sender;
    }

    // ─── Modifiers ──────────────────────────────────────────
    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner) revert OnlyKeeper();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // ─── Settlement ─────────────────────────────────────────

    /// @notice Execute epoch settlement for a pool
    /// @dev Called by keeper at end of each epoch. Coordinates:
    ///      1. Collect premiums from Hook → Pool
    ///      2. Record pending IL claims
    ///      3. Sync pool capacity
    ///      4. Distribute profits if dual-pool enabled
    function settle(PoolKey calldata poolKey) external onlyKeeper {
        PoolId poolId = poolKey.toId();

        uint256 currentEpoch = hook.getCurrentEpoch(poolId);
        uint256 epochToSettle = lastSettledEpoch[poolId] + 1;

        if (epochToSettle >= currentEpoch) revert EpochNotFinalized();

        Settlement storage s = settlements[poolId][epochToSettle];
        if (s.settled) revert AlreadySettled();

        // 1. Collect accumulated premiums from hook
        uint256 premiums = hook.collectPremiums(poolId);

        // 2. Read pending IL claims
        uint256 pending = hook.pendingILClaims(poolId);

        // 3. Record settlement
        s.epoch = epochToSettle;
        s.timestamp = block.timestamp;
        s.premiumsCollected = premiums;
        s.pendingClaims = pending;
        s.settled = true;
        lastSettledEpoch[poolId] = epochToSettle;

        // 4. Sync pool capacity with hook
        pool.syncCapacity(poolId);

        // 5. Distribute profits if treasury module connected and there's net profit
        if (address(treasury) != address(0) && premiums > pending) {
            uint256 netProfit = premiums - pending;
            treasury.distributeProfits(netProfit);
        }

        emit SettlementExecuted(poolId, epochToSettle, premiums, pending);
    }

    /// @notice Check if settlement is needed (for keeper automation)
    function needsSettlement(PoolKey calldata poolKey) external view returns (bool) {
        PoolId poolId = poolKey.toId();
        uint256 currentEpoch = hook.getCurrentEpoch(poolId);
        return lastSettledEpoch[poolId] + 1 < currentEpoch;
    }

    // ─── Admin ──────────────────────────────────────────────

    function setKeeper(address _keeper) external onlyOwner {
        emit KeeperUpdated(keeper, _keeper);
        keeper = _keeper;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = ITreasuryModuleSettlement(_treasury);
    }

    // ─── View Functions ─────────────────────────────────────

    function getSettlement(PoolId poolId, uint256 epoch) external view returns (Settlement memory) {
        return settlements[poolId][epoch];
    }

    function pendingEpochs(PoolId poolId) external view returns (uint256) {
        uint256 currentEpoch = hook.getCurrentEpoch(poolId);
        uint256 lastSettled = lastSettledEpoch[poolId];
        if (currentEpoch <= lastSettled + 1) return 0;
        return currentEpoch - lastSettled - 1;
    }
}
