// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626} from "solmate/src/mixins/ERC4626.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {PoolId} from "@v4-core/types/PoolId.sol";

interface IBELTAHook {
    function setPoolCapacity(PoolId poolId, uint256 capacity) external;
}

interface ITreasuryModule {
    function absorbLoss(uint256 amount) external;
    function needsSelfHealing() external view returns (bool);
    function selfHeal(uint256 premiumAmount) external;
    function bufferBalance() external view returns (uint256);
}

/// @title UnderwriterPool
/// @notice ERC-4626 vault for BELTA IL hedging underwriters (Phase 1-2: single pool)
/// @dev Receives premiums from BELTAHook, pays IL claims to LPs.
///      Integrates with TreasuryModule for first-loss absorption.
contract UnderwriterPool is ERC4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    // ─── Errors ─────────────────────────────────────────────
    error OnlyHook();
    error OnlyOwner();
    error OnlySettlement();
    error CooldownNotMet();
    error DailyPayLimitExceeded();
    error InsufficientAssets();

    // ─── Events ─────────────────────────────────────────────
    event PremiumReceived(uint256 amount);
    event ILClaimPaid(address indexed lp, uint256 amount, uint256 fromTreasury, uint256 fromPool);
    event WithdrawalRequested(address indexed user, uint256 timestamp);
    event CapacityUpdated(PoolId indexed poolId, uint256 capacity);
    event TreasuryModuleSet(address indexed treasury);

    // ─── Constants ──────────────────────────────────────────
    uint256 public constant COOLDOWN_PERIOD = 7 days;
    uint256 public constant DAILY_PAY_LIMIT_BPS = 500; // 5% of pool per day
    uint256 public constant BPS = 10_000;
    uint256 public constant CAP_MULT = 5; // Phase 1-2: 5x max cover multiplier

    // ─── State ──────────────────────────────────────────────
    IBELTAHook public immutable hook;
    address public owner;

    // Connected contracts
    ITreasuryModule public treasuryModule;
    address public epochSettlement;

    // Withdrawal cooldown tracking
    mapping(address => uint256) public withdrawalRequestTime;

    // Daily payout tracking
    uint256 public lastPayoutDay;
    uint256 public dailyPayoutTotal;

    // Total premiums earned (for APY tracking)
    uint256 public totalPremiumsEarned;
    uint256 public totalClaimsPaid;

    // ─── Constructor ────────────────────────────────────────
    constructor(ERC20 _asset, address _hook) ERC4626(_asset, "BELTA Underwriter Pool", "bUW") {
        hook = IBELTAHook(_hook);
        owner = msg.sender;
    }

    // ─── Modifiers ──────────────────────────────────────────
    modifier onlyHook() {
        if (msg.sender != address(hook)) revert OnlyHook();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyHookOrSettlement() {
        if (msg.sender != address(hook) && msg.sender != epochSettlement) revert OnlyHook();
        _;
    }

    // ─── Premium & Claims ───────────────────────────────────

    /// @notice Receive premium payment (called during epoch settlement)
    function receivePremium(uint256 amount) external onlyHookOrSettlement {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        totalPremiumsEarned += amount;

        // Check if treasury needs self-healing
        if (address(treasuryModule) != address(0) && treasuryModule.needsSelfHealing()) {
            uint256 healAmount = amount / 5; // redirect 20% of premium to treasury healing
            if (healAmount > 0) {
                asset.safeApprove(address(treasuryModule), healAmount);
                treasuryModule.selfHeal(healAmount);
            }
        }

        emit PremiumReceived(amount);
    }

    /// @notice Pay IL claim to LP
    /// @dev First tries to absorb from treasury buffer, then from pool assets
    function payILClaim(address lp, uint256 amount) external onlyHookOrSettlement {
        _checkDailyLimit(amount);

        uint256 fromTreasury = 0;
        uint256 fromPool = amount;

        // Try treasury first-loss absorption
        if (address(treasuryModule) != address(0)) {
            uint256 treasuryBal = treasuryModule.bufferBalance();
            if (treasuryBal > 0) {
                fromTreasury = amount > treasuryBal ? treasuryBal : amount;
                treasuryModule.absorbLoss(fromTreasury);
                fromPool = amount - fromTreasury;
            }
        }

        // Pay remaining from pool assets
        if (fromPool > 0) {
            if (fromPool > totalAssets()) revert InsufficientAssets();
            asset.safeTransfer(lp, fromPool);
        }

        totalClaimsPaid += amount;
        emit ILClaimPaid(lp, amount, fromTreasury, fromPool);
    }

    // ─── Withdrawal Cooldown ────────────────────────────────

    function requestWithdrawal() external {
        withdrawalRequestTime[msg.sender] = block.timestamp;
        emit WithdrawalRequested(msg.sender, block.timestamp);
    }

    function withdraw(uint256 assets, address receiver, address ownerAddr)
        public
        override
        returns (uint256 shares)
    {
        _checkCooldown(ownerAddr);
        shares = super.withdraw(assets, receiver, ownerAddr);
        withdrawalRequestTime[ownerAddr] = 0;
    }

    function redeem(uint256 shares, address receiver, address ownerAddr)
        public
        override
        returns (uint256 assets)
    {
        _checkCooldown(ownerAddr);
        assets = super.redeem(shares, receiver, ownerAddr);
        withdrawalRequestTime[ownerAddr] = 0;
    }

    // ─── Capacity Management ────────────────────────────────

    function syncCapacity(PoolId poolId) external {
        uint256 capacity = totalAssets() * CAP_MULT;
        hook.setPoolCapacity(poolId, capacity);
        emit CapacityUpdated(poolId, capacity);
    }

    // ─── Admin ──────────────────────────────────────────────

    function setTreasuryModule(address _treasury) external onlyOwner {
        treasuryModule = ITreasuryModule(_treasury);
        emit TreasuryModuleSet(_treasury);
    }

    function setEpochSettlement(address _settlement) external onlyOwner {
        epochSettlement = _settlement;
    }

    // ─── View Functions ─────────────────────────────────────

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function canWithdraw(address user) external view returns (bool) {
        uint256 requestTime = withdrawalRequestTime[user];
        if (requestTime == 0) return false;
        return block.timestamp >= requestTime + COOLDOWN_PERIOD;
    }

    function currentDailyPayout() external view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        if (today != lastPayoutDay) return 0;
        return dailyPayoutTotal;
    }

    function dailyPayLimit() public view returns (uint256) {
        return totalAssets() * DAILY_PAY_LIMIT_BPS / BPS;
    }

    function netPremiumIncome() external view returns (uint256) {
        if (totalPremiumsEarned > totalClaimsPaid) {
            return totalPremiumsEarned - totalClaimsPaid;
        }
        return 0;
    }

    // ─── Internal ───────────────────────────────────────────

    function _checkCooldown(address user) internal view {
        uint256 requestTime = withdrawalRequestTime[user];
        if (requestTime == 0 || block.timestamp < requestTime + COOLDOWN_PERIOD) {
            revert CooldownNotMet();
        }
    }

    function _checkDailyLimit(uint256 amount) internal {
        uint256 today = block.timestamp / 1 days;
        if (today != lastPayoutDay) {
            lastPayoutDay = today;
            dailyPayoutTotal = 0;
        }
        uint256 limit = dailyPayLimit();
        if (dailyPayoutTotal + amount > limit) revert DailyPayLimitExceeded();
        dailyPayoutTotal += amount;
    }
}
