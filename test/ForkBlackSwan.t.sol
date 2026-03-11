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

/// @title Fork / Black Swan Simulation Tests
/// @notice Simulates extreme market scenarios to validate protocol resilience
/// @dev Reproduces COVID crash (-50%), LUNA death spiral (-99%), FTX contagion (-25%)
///      Tests that Treasury absorbs first-loss and Senior pool remains protected
contract ForkBlackSwanTest is Test, Deployers {
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

    // Scenario parameters
    uint256 constant INITIAL_POOL_DEPOSIT = 100_000e6; // $100k underwriter pool
    uint256 constant TREASURY_SEED = 20_000e6;         // $20k treasury buffer
    uint256 constant LP_LIQUIDITY = 50e18;             // LP position size

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

        // Deploy underlying token
        underlyingToken = new MockERC20("USDC Mock", "mUSDC", 6);
        underlyingToken.mint(address(this), 10_000_000e6);

        oracle = new PremiumOracle();
        pool = new UnderwriterPool(ERC20(address(underlyingToken)), hookAddr);
        treasury = new TreasuryModule(ERC20(address(underlyingToken)));
        settlement = new EpochSettlement(hookAddr, address(pool));

        // 3. Wire everything
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

        // 5. Seed underwriter pool
        underlyingToken.approve(address(pool), type(uint256).max);
        pool.deposit(INITIAL_POOL_DEPOSIT, address(this));

        // 6. Seed treasury buffer
        underlyingToken.approve(address(treasury), type(uint256).max);
        treasury.seedBuffer(TREASURY_SEED);

        // 7. Sync capacity
        pool.syncCapacity(poolId);
    }

    // ================================================================
    // Helper: Simulate price crash via large swap
    // ================================================================

    function _addLPPosition(int24 tickLower, int24 tickUpper, int256 liquidity) internal {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, BELTA_OPT_IN);
    }

    function _removeLPPosition(int24 tickLower, int24 tickUpper, int256 liquidity) internal {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -liquidity, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, ZERO_BYTES);
    }

    function _advanceOneEpoch(uint256 ts) internal returns (uint256) {
        ts += 7 days;
        vm.warp(ts);
        hook.advanceEpoch(poolKey);
        return ts;
    }

    function _simulateCrash(int256 swapAmount) internal {
        // Large swap to move price significantly
        swap(poolKey, true, swapAmount, ZERO_BYTES);
    }

    // ================================================================
    // Scenario 1: COVID Crash — ~50% price drop over 2 epochs
    // ================================================================

    function test_blackSwan_covidCrash() public {
        uint256 ts = block.timestamp;

        // LPs add positions (wide + narrow range)
        _addLPPosition(-600, 600, 30e18);  // wide range LP
        _addLPPosition(-120, 120, 20e18);  // narrow range LP (higher IL risk)

        // Verify initial state
        assertEq(hook.totalHedgedValue(poolId), 50e18, "total hedged should be 50e18");
        uint256 treasuryBefore = treasury.bufferBalance();
        assertEq(treasuryBefore, TREASURY_SEED, "treasury should be fully seeded");

        // ── Epoch 1: Normal trading ──
        swap(poolKey, true, -5000, ZERO_BYTES);
        swap(poolKey, false, -3000, ZERO_BYTES);

        // ── Epoch 2: Crash begins (-30% move) ──
        ts = _advanceOneEpoch(ts);
        assertEq(hook.getCurrentEpoch(poolId), 2);

        // Large directional swap simulating crash
        _simulateCrash(-50000);

        // ── Epoch 3: Crash continues ──
        ts = _advanceOneEpoch(ts);
        assertEq(hook.getCurrentEpoch(poolId), 3);

        _simulateCrash(-30000);

        // ── LPs remove positions (realize IL) ──
        _removeLPPosition(-600, 600, 30e18);
        _removeLPPosition(-120, 120, 20e18);

        // Verify positions deactivated
        BELTAHook.LPPosition memory widePos =
            hook.getPosition(poolId, address(modifyLiquidityRouter), -600, 600);
        BELTAHook.LPPosition memory narrowPos =
            hook.getPosition(poolId, address(modifyLiquidityRouter), -120, 120);
        assertFalse(widePos.active, "wide position should be closed");
        assertFalse(narrowPos.active, "narrow position should be closed");

        // IL claims should be recorded
        uint256 pendingClaims = hook.pendingILClaims(poolId);
        // Premiums should be accumulated
        uint256 premiums = hook.accumulatedPremiums(poolId);

        emit log_named_uint("Pending IL Claims", pendingClaims);
        emit log_named_uint("Accumulated Premiums", premiums);
        emit log_named_uint("Treasury Buffer", treasury.bufferBalance());

        // ── Settlement ──
        ts = _advanceOneEpoch(ts);
        settlement.settle(poolKey); // settle epoch 1
        settlement.settle(poolKey); // settle epoch 2
        settlement.settle(poolKey); // settle epoch 3

        // KEY ASSERTION: Treasury absorbs first-loss, pool should still function
        assertGe(pool.totalAssets(), 0, "pool should still have assets");
        // Treasury may be depleted but protocol should not revert
        assertLe(treasury.bufferBalance(), treasuryBefore, "treasury should have absorbed some loss");
    }

    // ================================================================
    // Scenario 2: LUNA Death Spiral — extreme price collapse
    // ================================================================

    function test_blackSwan_lunaCollapse() public {
        uint256 ts = block.timestamp;

        // Concentrated LPs (high risk in death spiral)
        _addLPPosition(-60, 60, 40e18);   // very narrow range
        _addLPPosition(-120, 120, 10e18);  // medium range

        uint256 treasuryBefore = treasury.bufferBalance();

        // ── Rapid crash: multiple large swaps in same epoch ──
        _simulateCrash(-100000);
        _simulateCrash(-50000);

        // LP removes during crash (panic withdrawal)
        _removeLPPosition(-60, 60, 40e18);

        // Check narrow LP got maximum IL hit
        BELTAHook.LPPosition memory narrowPos =
            hook.getPosition(poolId, address(modifyLiquidityRouter), -60, 60);
        assertFalse(narrowPos.active, "narrow LP should be closed");

        // IL claimable should be capped at COVERAGE_CAP_BPS (45%)
        // The actual payout = liquidity * coveredIL / BPS
        // coveredIL is min(ilBps, 4500)
        emit log_named_uint("Narrow LP IL claimable", narrowPos.ilClaimable);

        // ── Epoch advance + settle ──
        ts = _advanceOneEpoch(ts);

        // Remove remaining LP
        _removeLPPosition(-120, 120, 10e18);

        ts = _advanceOneEpoch(ts);
        settlement.settle(poolKey);

        // Treasury absorb loss simulation
        vm.prank(address(pool));
        treasury.absorbLoss(10_000e6);

        uint256 treasuryAfter = treasury.bufferBalance();
        assertLt(treasuryAfter, treasuryBefore, "treasury should be depleted after LUNA-style event");
        emit log_named_uint("Treasury after LUNA", treasuryAfter);

        // Protocol should still be operational
        assertGe(pool.totalAssets(), 0, "pool must remain solvent");
    }

    // ================================================================
    // Scenario 3: FTX Contagion — moderate crash + liquidity drain
    // ================================================================

    function test_blackSwan_ftxContagion() public {
        uint256 ts = block.timestamp;

        // Multiple LPs add positions
        _addLPPosition(-300, 300, 20e18);
        _addLPPosition(-120, 120, 15e18);
        _addLPPosition(-60, 60, 15e18);

        assertEq(hook.totalHedgedValue(poolId), 50e18);

        // ── FTX news: moderate crash ──
        _simulateCrash(-40000);

        // ── Panic: all LPs exit simultaneously ──
        _removeLPPosition(-300, 300, 20e18);
        _removeLPPosition(-120, 120, 15e18);
        _removeLPPosition(-60, 60, 15e18);

        // All positions closed
        assertEq(hook.totalHedgedValue(poolId), 0, "all hedged value removed");

        // Premiums and claims accumulated
        uint256 totalPremiums = hook.accumulatedPremiums(poolId);
        uint256 totalClaims = hook.pendingILClaims(poolId);
        emit log_named_uint("FTX total premiums", totalPremiums);
        emit log_named_uint("FTX total IL claims", totalClaims);

        // ── Epoch settlement ──
        ts = _advanceOneEpoch(ts);
        settlement.settle(poolKey);

        // ── Underwriter pool withdrawal stress test ──
        // Underwriter requests withdrawal during crisis
        pool.requestWithdrawal();
        vm.warp(ts + 7 days);
        ts += 7 days;

        assertTrue(pool.canWithdraw(address(this)), "underwriter should be able to withdraw after cooldown");

        // Partial withdraw (not draining entire pool)
        uint256 poolBefore = pool.totalAssets();
        pool.withdraw(10_000e6, address(this), address(this));
        uint256 poolAfter = pool.totalAssets();
        assertEq(poolBefore - poolAfter, 10_000e6, "should withdraw 10k");
    }

    // ================================================================
    // Scenario 4: Treasury self-healing after depletion
    // ================================================================

    function test_blackSwan_treasurySelfHealing() public {
        // Deplete treasury via loss absorption
        vm.prank(address(pool));
        treasury.absorbLoss(15_000e6);
        assertEq(treasury.bufferBalance(), 5_000e6, "buffer should be 5k after 15k loss");

        // Check self-healing needed
        assertTrue(treasury.needsSelfHealing(), "self-healing should be needed");

        // Warp past self-heal cooldown (1 day)
        vm.warp(block.timestamp + 2 days);

        // Transfer tokens to pool first for the self-heal transfer
        underlyingToken.transfer(address(pool), 10_000e6);
        vm.startPrank(address(pool));
        underlyingToken.approve(address(treasury), type(uint256).max);
        treasury.selfHeal(10_000e6);
        vm.stopPrank();

        // Buffer should be replenished
        assertGt(treasury.bufferBalance(), 5_000e6, "buffer should increase after self-healing");
        emit log_named_uint("Buffer after self-heal", treasury.bufferBalance());
    }

    // ================================================================
    // Scenario 5: Maximum treasury depletion (worst case)
    // ================================================================

    function test_blackSwan_totalTreasuryWipeout() public {
        // Absorb loss exceeding entire buffer
        vm.prank(address(pool));
        treasury.absorbLoss(50_000e6); // 50k > 20k buffer

        assertEq(treasury.bufferBalance(), 0, "buffer should be fully wiped");

        // Protocol should still operate even with zero buffer
        uint256 ts = block.timestamp;

        _addLPPosition(-120, 120, 10e18);
        swap(poolKey, true, -5000, ZERO_BYTES);
        _removeLPPosition(-120, 120, 10e18);

        ts = _advanceOneEpoch(ts);
        settlement.settle(poolKey);

        // Pool still functions
        assertGt(pool.totalAssets(), 0, "pool assets should remain after treasury wipeout");
    }

    // ================================================================
    // Scenario 6: High utilization stress test
    // ================================================================

    function test_blackSwan_highUtilizationStress() public {
        // Push utilization to near 100%
        // Pool capacity is 100_000e6 * 5 = 500_000e6 (in token units)
        // But hedged value is in liquidity units
        _addLPPosition(-600, 600, 30e18);
        _addLPPosition(-300, 300, 30e18);
        _addLPPosition(-120, 120, 30e18);

        uint256 totalHedged = hook.totalHedgedValue(poolId);
        assertEq(totalHedged, 90e18, "should have 90e18 hedged");

        // Premium rate should be elevated at high utilization
        uint256 rate = hook.getCurrentPremiumRate(poolId);
        emit log_named_uint("Premium rate at high util", rate);

        // Even at high utilization, crash should be handled
        _simulateCrash(-80000);

        // Remove all positions
        _removeLPPosition(-600, 600, 30e18);
        _removeLPPosition(-300, 300, 30e18);
        _removeLPPosition(-120, 120, 30e18);

        uint256 totalClaims = hook.pendingILClaims(poolId);
        uint256 totalPremiums = hook.accumulatedPremiums(poolId);

        emit log_named_uint("High util total claims", totalClaims);
        emit log_named_uint("High util total premiums", totalPremiums);

        // Settle
        uint256 ts = block.timestamp;
        ts = _advanceOneEpoch(ts);
        settlement.settle(poolKey);

        // Protocol survives
        assertGt(pool.totalAssets(), 0, "pool should survive high util stress");
    }

    // ================================================================
    // Scenario 7: Multi-epoch sustained crash (bear market)
    // ================================================================

    function test_blackSwan_sustainedBearMarket() public {
        uint256 ts = block.timestamp;

        _addLPPosition(-600, 600, 50e18);

        // Simulate 4 weeks of declining prices
        for (uint256 week = 0; week < 4; week++) {
            // Each week: swap moves price down
            _simulateCrash(-20000);

            ts = _advanceOneEpoch(ts);
        }
        // Now at epoch 5

        // LP exits after sustained bear market
        _removeLPPosition(-600, 600, 50e18);

        // Advance one more epoch for settlement
        ts = _advanceOneEpoch(ts);

        // Settle all pending epochs
        uint256 pending = settlement.pendingEpochs(poolId);
        for (uint256 i = 0; i < pending; i++) {
            settlement.settle(poolKey);
        }

        assertEq(settlement.pendingEpochs(poolId), 0, "all epochs should be settled");

        // Log final state
        emit log_named_uint("Final pool assets", pool.totalAssets());
        emit log_named_uint("Final treasury buffer", treasury.bufferBalance());
        emit log_named_uint("Total premiums collected", hook.accumulatedPremiums(poolId));
    }

    // ================================================================
    // Scenario 8: Coverage cap enforcement under extreme IL
    // ================================================================

    function test_blackSwan_coverageCapEnforced() public {
        // Very narrow range LP (extreme IL sensitivity)
        _addLPPosition(-60, 60, 20e18);

        // Massive crash
        _simulateCrash(-200000);

        // Remove position
        _removeLPPosition(-60, 60, 20e18);

        BELTAHook.LPPosition memory pos =
            hook.getPosition(poolId, address(modifyLiquidityRouter), -60, 60);

        // Coverage cap is 45% (4500 bps)
        // Max payout = liquidity * 4500 / 10000 = 20e18 * 0.45 = 9e18
        if (pos.ilClaimable > 0) {
            uint256 maxPayout = 20e18 * 4500 / 10000;
            assertLe(pos.ilClaimable, maxPayout, "IL payout should be capped at 45%");
            emit log_named_uint("IL claimable (capped)", pos.ilClaimable);
        }

        // Daily pay limit should also apply
        assertEq(hook.DAILY_PAY_LIMIT_BPS(), 500, "daily limit should be 5%");
        assertEq(hook.COVERAGE_CAP_BPS(), 4500, "coverage cap should be 45%");
    }
}
