// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

/// @title TreasuryModule
/// @notice Treasury buffer management + self-healing mechanism
/// @dev Phase 1-2: integrated with single UnderwriterPool
///      Phase 3+: manages Treasury/Senior split (20:80)
contract TreasuryModule {
    using SafeTransferLib for ERC20;

    // ─── Errors ─────────────────────────────────────────────
    error OnlyOwner();
    error OnlyAuthorized();
    error InsufficientBuffer();
    error BufferHealthy();
    error CooldownActive();

    // ─── Events ─────────────────────────────────────────────
    event BufferReplenished(uint256 amount);
    event FirstLossAbsorbed(uint256 amount, uint256 remainingBuffer);
    event SelfHealingTriggered(uint256 targetAmount, uint256 healedAmount);
    event ProfitDistributed(uint256 toTreasury, uint256 toSenior);

    // ─── Constants ──────────────────────────────────────────
    uint256 public constant BUFFER_RATIO_BPS = 2000; // 20% of Senior balance
    uint256 public constant BPS = 10_000;
    uint256 public constant SELF_HEAL_COOLDOWN = 1 days;
    uint256 public constant MIN_BUFFER_RATIO_BPS = 1000; // 10% — triggers self-healing

    // ─── State ──────────────────────────────────────────────
    ERC20 public immutable asset;
    address public owner;

    // Authorized callers (UnderwriterPool, EpochSettlement)
    mapping(address => bool) public authorized;

    uint256 public bufferBalance;
    uint256 public initialBuffer;
    uint256 public lastSelfHealTime;

    // For target buffer calculation
    address public underwriterPool;

    // Phase 3+ split tracking
    uint256 public seniorBalance;
    bool public dualPoolEnabled;

    // ─── Constructor ────────────────────────────────────────
    constructor(ERC20 _asset) {
        asset = _asset;
        owner = msg.sender;
    }

    // ─── Modifiers ──────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyAuthorized() {
        if (!authorized[msg.sender] && msg.sender != owner) revert OnlyAuthorized();
        _;
    }

    // ─── Buffer Management ──────────────────────────────────

    function seedBuffer(uint256 amount) external onlyOwner {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        bufferBalance += amount;
        if (initialBuffer == 0) {
            initialBuffer = amount;
        }
        emit BufferReplenished(amount);
    }

    /// @notice Absorb first-loss from IL claims
    function absorbLoss(uint256 amount) external onlyAuthorized {
        uint256 absorbed = amount > bufferBalance ? bufferBalance : amount;
        bufferBalance -= absorbed;
        emit FirstLossAbsorbed(absorbed, bufferBalance);
    }

    /// @notice Self-healing: redirect premium income to buffer when depleted
    function selfHeal(uint256 premiumAmount) external onlyAuthorized {
        if (block.timestamp < lastSelfHealTime + SELF_HEAL_COOLDOWN) revert CooldownActive();

        uint256 targetBuffer = _targetBufferSize();
        if (bufferBalance >= targetBuffer * MIN_BUFFER_RATIO_BPS / BUFFER_RATIO_BPS) {
            revert BufferHealthy();
        }

        uint256 deficit = targetBuffer - bufferBalance;
        uint256 healAmount = premiumAmount > deficit ? deficit : premiumAmount;

        asset.safeTransferFrom(msg.sender, address(this), healAmount);
        bufferBalance += healAmount;
        lastSelfHealTime = block.timestamp;

        emit SelfHealingTriggered(deficit, healAmount);
    }

    // ─── Phase 3+ Dual Pool ─────────────────────────────────

    function enableDualPool() external onlyOwner {
        dualPoolEnabled = true;
    }

    function distributeProfits(uint256 totalProfit) external onlyAuthorized {
        if (!dualPoolEnabled) return;

        uint256 toTreasury = totalProfit * BUFFER_RATIO_BPS / BPS;
        uint256 toSenior = totalProfit - toTreasury;

        bufferBalance += toTreasury;
        seniorBalance += toSenior;

        emit ProfitDistributed(toTreasury, toSenior);
    }

    // ─── Admin ──────────────────────────────────────────────

    function setAuthorized(address addr, bool isAuthorized) external onlyOwner {
        authorized[addr] = isAuthorized;
    }

    function setUnderwriterPool(address _pool) external onlyOwner {
        underwriterPool = _pool;
    }

    // ─── View Functions ─────────────────────────────────────

    function bufferHealthBps() external view returns (uint256) {
        uint256 target = _targetBufferSize();
        if (target == 0) return BPS;
        return bufferBalance * BPS / target;
    }

    function needsSelfHealing() external view returns (bool) {
        uint256 target = _targetBufferSize();
        if (target == 0) return false;
        return bufferBalance < target * MIN_BUFFER_RATIO_BPS / BUFFER_RATIO_BPS;
    }

    function _targetBufferSize() internal view returns (uint256) {
        if (underwriterPool == address(0)) return initialBuffer;
        // Use a low-level call to get totalAssets to avoid circular imports
        (bool success, bytes memory data) =
            underwriterPool.staticcall(abi.encodeWithSignature("totalAssets()"));
        uint256 poolTotal = success && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
        uint256 seniorBased = poolTotal * BUFFER_RATIO_BPS / BPS;
        return initialBuffer > seniorBased ? initialBuffer : seniorBased;
    }

    function getTargetBufferSize() external view returns (uint256) {
        return _targetBufferSize();
    }
}
