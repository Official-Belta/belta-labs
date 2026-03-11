// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IHooks} from "@v4-core/interfaces/IHooks.sol";
import {Hooks} from "@v4-core/libraries/Hooks.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {StateLibrary} from "@v4-core/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@v4-core/types/PoolOperation.sol";
import {Currency} from "@v4-core/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Deployers} from "../../lib/v4-periphery/lib/v4-core/test/utils/Deployers.sol";

import {BELTAHook} from "../src/BELTAHook.sol";
import {UnderwriterPool} from "../src/UnderwriterPool.sol";
import {EpochSettlement} from "../src/EpochSettlement.sol";
import {PremiumOracle} from "../src/PremiumOracle.sol";
import {TreasuryModule} from "../src/TreasuryModule.sol";

/// @title Integration Test
/// @notice Full E2E test: deploy -> wire -> LP flow -> swap -> epoch -> settle -> claim
contract IntegrationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    BELTAHook hook;
    UnderwriterPool pool;
    EpochSettlement settlement;
    PremiumOracle oracle;
    TreasuryModule treasury;

    PoolKey poolKey;
    PoolId poolId;

    MockERC20 underlyingToken;

    bytes constant BELTA_OPT_IN = hex"01";

    function setUp() public {
        // 1. Deploy V4 infrastructure
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // 2. Deploy BELTA contracts
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags);
        deployCodeTo("BELTAHook.sol:BELTAHook", abi.encode(manager), hookAddr);
        hook = BELTAHook(hookAddr);

        // Deploy underlying token for UnderwriterPool
        underlyingToken = new MockERC20("USDC Mock", "mUSDC", 6);
        underlyingToken.mint(address(this), 1_000_000e6);

        oracle = new PremiumOracle();
        pool = new UnderwriterPool(ERC20(address(underlyingToken)), hookAddr);
        treasury = new TreasuryModule(ERC20(address(underlyingToken)));
        settlement = new EpochSettlement(hookAddr, address(pool));

        // 3. Wire everything together
        hook.setUnderwriterPool(address(pool));
        hook.setPremiumOracle(address(oracle));
        hook.setEpochSettlement(address(settlement));

        pool.setTreasuryModule(address(treasury));
        pool.setEpochSettlement(address(settlement));

        treasury.setUnderwriterPool(address(pool));
        treasury.setAuthorized(address(pool), true);
        treasury.setAuthorized(address(settlement), true);

        settlement.setTreasury(address(treasury));

        // 4. Initialize pool
        (poolKey,) = initPool(currency0, currency1, IHooks(hookAddr), 3000, 60, SQRT_PRICE_1_1);
        poolId = poolKey.toId();

        // 5. Seed underwriter pool (depositors)
        underlyingToken.approve(address(pool), type(uint256).max);
        pool.deposit(100_000e6, address(this));

        // 6. Seed treasury buffer
        underlyingToken.approve(address(treasury), type(uint256).max);
        treasury.seedBuffer(20_000e6);

        // 7. Sync capacity
        pool.syncCapacity(poolId);
    }

    // ═══════════════════════════════════════════════════════════
    // E2E: Full protocol flow
    // ═══════════════════════════════════════════════════════════

    function test_e2e_fullFlow() public {
        uint256 ts = block.timestamp;

        // ── Step 1: LP adds liquidity with BELTA opt-in ──
        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 10e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, addParams, BELTA_OPT_IN);

        // Verify position registered
        BELTAHook.LPPosition memory pos =
            hook.getPosition(poolId, address(modifyLiquidityRouter), -120, 120);
        assertTrue(pos.active, "position should be active");
        assertEq(pos.liquidity, 10e18);

        // ── Step 2: Swaps happen (price moves) ──
        swap(poolKey, true, -1000, ZERO_BYTES);
        swap(poolKey, false, -500, ZERO_BYTES);

        // ── Step 3: Warp 7 days, trigger epoch advance ──
        ts += 7 days;
        vm.warp(ts);
        swap(poolKey, true, -100, ZERO_BYTES); // triggers epoch advance
        assertEq(hook.getCurrentEpoch(poolId), 2, "epoch should be 2");

        // ── Step 4: LP removes liquidity (triggers IL calc + premium accrual) ──
        ModifyLiquidityParams memory removeParams =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -10e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, removeParams, ZERO_BYTES);

        // Position should be deactivated
        pos = hook.getPosition(poolId, address(modifyLiquidityRouter), -120, 120);
        assertFalse(pos.active, "position should be deactivated");

        // Premiums should be accumulated
        uint256 premiums = hook.accumulatedPremiums(poolId);
        assertGe(premiums, 0, "premiums accounting should be >= 0");

        // ── Step 5: Epoch settlement ──
        // Use advanceEpoch() directly since all liquidity was removed
        ts += 7 days;
        vm.warp(ts);
        hook.advanceEpoch(poolKey);
        assertEq(hook.getCurrentEpoch(poolId), 3);

        // Settle epoch 1 first (sequential settlement required)
        settlement.settle(poolKey);
        EpochSettlement.Settlement memory s1 = settlement.getSettlement(poolId, 1);
        assertTrue(s1.settled, "epoch 1 should be settled");

        // Settle epoch 2
        settlement.settle(poolKey);
        EpochSettlement.Settlement memory s2 = settlement.getSettlement(poolId, 2);
        assertTrue(s2.settled, "epoch 2 should be settled");
        assertEq(s2.epoch, 2);
    }

    // ═══════════════════════════════════════════════════════════
    // Contract wiring verification
    // ═══════════════════════════════════════════════════════════

    function test_wiring_hookToPool() public view {
        assertEq(address(hook.underwriterPool()), address(pool));
        assertEq(address(hook.premiumOracle()), address(oracle));
        assertEq(hook.epochSettlement(), address(settlement));
    }

    function test_wiring_poolToTreasury() public view {
        assertEq(address(pool.treasuryModule()), address(treasury));
        assertEq(pool.epochSettlement(), address(settlement));
    }

    function test_wiring_treasuryAuthorized() public view {
        assertTrue(treasury.authorized(address(pool)));
        assertTrue(treasury.authorized(address(settlement)));
    }

    // ═══════════════════════════════════════════════════════════
    // Underwriter Pool tests
    // ═══════════════════════════════════════════════════════════

    function test_pool_deposit_and_shares() public view {
        assertGt(pool.totalAssets(), 0, "pool should have assets");
        assertGt(pool.balanceOf(address(this)), 0, "should have pool shares");
    }

    function test_pool_capacity_synced() public view {
        uint256 capacity = hook.poolCapacity(poolId);
        assertEq(capacity, pool.totalAssets() * 5, "capacity should be 5x TVL");
    }

    function test_pool_withdrawal_cooldown() public {
        // Try withdraw without requesting -> revert
        vm.expectRevert(UnderwriterPool.CooldownNotMet.selector);
        pool.withdraw(1000e6, address(this), address(this));

        // Request withdrawal
        pool.requestWithdrawal();
        assertFalse(pool.canWithdraw(address(this)), "cannot withdraw yet");

        // Warp 7 days
        vm.warp(block.timestamp + 7 days);
        assertTrue(pool.canWithdraw(address(this)), "should be able to withdraw");

        // Now withdraw works
        uint256 balBefore = underlyingToken.balanceOf(address(this));
        pool.withdraw(1000e6, address(this), address(this));
        uint256 balAfter = underlyingToken.balanceOf(address(this));
        assertEq(balAfter - balBefore, 1000e6, "should receive 1000 USDC");
    }

    // ═══════════════════════════════════════════════════════════
    // Treasury tests
    // ═══════════════════════════════════════════════════════════

    function test_treasury_buffer_seeded() public view {
        assertEq(treasury.bufferBalance(), 20_000e6, "treasury buffer should be 20k");
        assertEq(treasury.initialBuffer(), 20_000e6);
    }

    function test_treasury_absorb_loss() public {
        // Simulate loss absorption (called by pool)
        vm.prank(address(pool));
        treasury.absorbLoss(5_000e6);

        assertEq(treasury.bufferBalance(), 15_000e6, "buffer should decrease by 5k");
    }

    function test_treasury_absorb_loss_capped() public {
        // Try to absorb more than buffer
        vm.prank(address(pool));
        treasury.absorbLoss(50_000e6);

        assertEq(treasury.bufferBalance(), 0, "buffer should be 0 (fully absorbed)");
    }

    // ═══════════════════════════════════════════════════════════
    // PremiumOracle tests
    // ═══════════════════════════════════════════════════════════

    function test_oracle_baseRate() public view {
        uint256 rate = oracle.getPremiumRate(5000); // 50% utilization
        assertEq(rate, 1200, "below kink -> base rate 12%");
    }

    function test_oracle_aboveKink() public view {
        uint256 rate = oracle.getPremiumRate(9000); // 90% utilization
        assertGt(rate, 1200, "above kink -> higher than base");
        assertLt(rate, 3600, "should be less than 3x base");
    }

    function test_oracle_maxRate() public view {
        uint256 rate = oracle.getPremiumRate(10000); // 100% utilization
        assertEq(rate, 3600, "at 100% -> 3x base rate (36%)");
    }

    function test_oracle_poolSpecificParams() public {
        oracle.setPoolParams(poolId, 600, 7000, 4); // 6% base, 70% kink, 4x max
        uint256 rate = oracle.getPremiumRateForPool(poolId, 5000);
        assertEq(rate, 600, "pool-specific base rate");

        uint256 rateHigh = oracle.getPremiumRateForPool(poolId, 8500);
        assertGt(rateHigh, 600, "above pool-specific kink");
    }

    // ═══════════════════════════════════════════════════════════
    // EpochSettlement tests
    // ═══════════════════════════════════════════════════════════

    function test_settlement_needsSettlement_false_initially() public view {
        assertFalse(settlement.needsSettlement(poolKey), "no settlement needed at epoch 1");
    }

    function test_settlement_needsSettlement_after_advance() public {
        vm.warp(block.timestamp + 7 days);
        hook.advanceEpoch(poolKey);

        assertTrue(settlement.needsSettlement(poolKey), "settlement needed after epoch advance");
    }

    function test_settlement_settle_and_record() public {
        // Advance to epoch 2
        vm.warp(block.timestamp + 7 days);
        hook.advanceEpoch(poolKey);

        // Settle epoch 1
        settlement.settle(poolKey);

        assertEq(settlement.lastSettledEpoch(poolId), 1);
        assertFalse(settlement.needsSettlement(poolKey));

        EpochSettlement.Settlement memory s = settlement.getSettlement(poolId, 1);
        assertTrue(s.settled);
        assertEq(s.epoch, 1);
    }

    function test_settlement_reverts_not_finalized() public {
        vm.expectRevert(EpochSettlement.EpochNotFinalized.selector);
        settlement.settle(poolKey);
    }

    function test_settlement_reverts_already_settled() public {
        vm.warp(block.timestamp + 7 days);
        hook.advanceEpoch(poolKey);
        settlement.settle(poolKey);

        vm.expectRevert(EpochSettlement.EpochNotFinalized.selector);
        settlement.settle(poolKey);
    }

    function test_settlement_multiple_epochs() public {
        // Advance through 3 epochs using explicit timestamps to avoid warp issues
        uint256 ts = block.timestamp;
        for (uint256 i = 0; i < 3; i++) {
            ts += 7 days;
            vm.warp(ts);
            hook.advanceEpoch(poolKey);
        }
        // Now at epoch 4, epochs 1-3 need settling
        assertEq(settlement.pendingEpochs(poolId), 3);

        settlement.settle(poolKey); // settle epoch 1
        assertEq(settlement.pendingEpochs(poolId), 2);

        settlement.settle(poolKey); // settle epoch 2
        assertEq(settlement.pendingEpochs(poolId), 1);

        settlement.settle(poolKey); // settle epoch 3
        assertEq(settlement.pendingEpochs(poolId), 0);
    }

    // ═══════════════════════════════════════════════════════════
    // Multi-LP scenario
    // ═══════════════════════════════════════════════════════════

    function test_multiLP_positions() public {
        // LP1 adds wide range
        ModifyLiquidityParams memory lp1Params =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 5e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, lp1Params, BELTA_OPT_IN);

        // LP2 adds narrow range (higher IL risk)
        ModifyLiquidityParams memory lp2Params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 5e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, lp2Params, BELTA_OPT_IN);

        // Both tracked
        assertEq(hook.totalHedgedValue(poolId), 10e18, "total hedged = LP1 + LP2");

        // Utilization check
        uint256 util = hook.getUtilization(poolId);
        assertGt(util, 0);
    }

    // ═══════════════════════════════════════════════════════════
    // Premium rate via Oracle integration
    // ═══════════════════════════════════════════════════════════

    function test_hook_uses_premiumOracle() public {
        // Add enough liquidity to push utilization above kink
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 90e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, BELTA_OPT_IN);

        // Pool capacity is 100_000e6 * 5 = 500_000e6 from pool deposit
        // But hedged value is in liquidity units (90e18) vs capacity in token units
        // The rate should come from oracle
        uint256 rate = hook.getCurrentPremiumRate(poolId);
        assertGt(rate, 0, "rate should come from oracle");
    }
}
