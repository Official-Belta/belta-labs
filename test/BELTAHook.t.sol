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
import {Deployers} from "../../lib/v4-periphery/lib/v4-core/test/utils/Deployers.sol";

import {BELTAHook} from "../src/BELTAHook.sol";

contract BELTAHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    BELTAHook hook;
    PoolKey poolKey;
    PoolId poolId;

    bytes constant BELTA_OPT_IN = hex"01";
    bytes constant BELTA_OPT_OUT = hex"00";

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );

        address hookAddr = address(flags);
        deployCodeTo("BELTAHook.sol:BELTAHook", abi.encode(manager), hookAddr);
        hook = BELTAHook(hookAddr);

        (poolKey,) = initPool(currency0, currency1, IHooks(hookAddr), 3000, 60, SQRT_PRICE_1_1);
        poolId = poolKey.toId();

        hook.setPoolCapacity(poolId, 100e18);
    }

    // ─── Epoch Tests ────────────────────────────────────────

    function test_afterInitialize_setsEpoch() public view {
        assertEq(hook.getCurrentEpoch(poolId), 1);
    }

    function test_afterInitialize_setsEpochTimestamp() public view {
        (uint256 epochNumber, uint256 startTimestamp, uint160 sqrtPrice) = hook.epochs(poolId);
        assertEq(epochNumber, 1);
        assertEq(startTimestamp, block.timestamp);
        assertGt(sqrtPrice, 0);
    }

    // ─── Position Registration Tests ────────────────────────

    function test_afterAddLiquidity_registersPosition() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, BELTA_OPT_IN);

        BELTAHook.LPPosition memory pos =
            hook.getPosition(poolId, address(modifyLiquidityRouter), int24(-120), int24(120));
        assertTrue(pos.active);
        assertEq(pos.liquidity, 1e18);
        assertEq(pos.epochStart, 1);
        assertGt(pos.sqrtPriceAtEntry, 0);
    }

    function test_afterAddLiquidity_noOptIn_doesNotRegister() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, BELTA_OPT_OUT);

        BELTAHook.LPPosition memory pos =
            hook.getPosition(poolId, address(modifyLiquidityRouter), int24(-120), int24(120));
        assertFalse(pos.active);
    }

    function test_afterAddLiquidity_emptyHookData_doesNotRegister() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, ZERO_BYTES);

        BELTAHook.LPPosition memory pos =
            hook.getPosition(poolId, address(modifyLiquidityRouter), int24(-120), int24(120));
        assertFalse(pos.active);
    }

    function test_afterAddLiquidity_incrementsHedgedValue() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, BELTA_OPT_IN);

        assertEq(hook.totalHedgedValue(poolId), 1e18);
    }

    // ─── Position Removal Tests ─────────────────────────────

    function test_afterRemoveLiquidity_deactivatesPosition() public {
        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, addParams, BELTA_OPT_IN);

        ModifyLiquidityParams memory removeParams =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -1e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, removeParams, ZERO_BYTES);

        BELTAHook.LPPosition memory pos =
            hook.getPosition(poolId, address(modifyLiquidityRouter), int24(-120), int24(120));
        assertFalse(pos.active);
        assertEq(pos.liquidity, 0);
    }

    function test_afterRemoveLiquidity_partialRemoval() public {
        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 2e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, addParams, BELTA_OPT_IN);

        ModifyLiquidityParams memory removeParams =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -1e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, removeParams, ZERO_BYTES);

        BELTAHook.LPPosition memory pos =
            hook.getPosition(poolId, address(modifyLiquidityRouter), int24(-120), int24(120));
        assertTrue(pos.active);
        assertEq(pos.liquidity, 1e18);
    }

    function test_afterRemoveLiquidity_reducesHedgedValue() public {
        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 2e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, addParams, BELTA_OPT_IN);

        ModifyLiquidityParams memory removeParams =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -1e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, removeParams, ZERO_BYTES);

        assertEq(hook.totalHedgedValue(poolId), 1e18);
    }

    // ─── IL Calculation Tests ───────────────────────────────

    function test_calculateIL_noPriceChange_zeroIL() public {
        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, addParams, BELTA_OPT_IN);

        ModifyLiquidityParams memory removeParams =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -1e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, removeParams, ZERO_BYTES);

        BELTAHook.LPPosition memory pos =
            hook.getPosition(poolId, address(modifyLiquidityRouter), int24(-120), int24(120));
        assertFalse(pos.active);
        // No IL claim should be pending (price didn't change)
        assertEq(pos.ilClaimable, 0);
    }

    // ─── Swap & Epoch Tests ─────────────────────────────────

    function test_afterSwap_doesNotAdvanceEpochEarly() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, BELTA_OPT_IN);

        swap(poolKey, true, -100, ZERO_BYTES);
        assertEq(hook.getCurrentEpoch(poolId), 1);
    }

    function test_afterSwap_advancesEpochAfter7Days() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, BELTA_OPT_IN);

        vm.warp(block.timestamp + 7 days);
        swap(poolKey, true, -100, ZERO_BYTES);
        assertEq(hook.getCurrentEpoch(poolId), 2);
    }

    function test_advanceEpoch_manual() public {
        vm.warp(block.timestamp + 7 days);
        hook.advanceEpoch(poolKey);
        assertEq(hook.getCurrentEpoch(poolId), 2);
    }

    function test_advanceEpoch_reverts_ifNotReady() public {
        vm.expectRevert(BELTAHook.EpochNotReady.selector);
        hook.advanceEpoch(poolKey);
    }

    // ─── Dynamic Premium Tests ──────────────────────────────

    function test_premiumRate_belowKink_fallback() public view {
        uint256 rate = hook.getCurrentPremiumRate(poolId);
        assertEq(rate, 1200); // 12% base with fallback
    }

    function test_premiumRate_aboveKink() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 90e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, BELTA_OPT_IN);

        uint256 rate = hook.getCurrentPremiumRate(poolId);
        assertGt(rate, 1200); // above base rate
    }

    function test_utilization_calculation() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 50e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, BELTA_OPT_IN);

        assertEq(hook.getUtilization(poolId), 5000);
    }

    // ─── Integration Wiring Tests ───────────────────────────

    function test_setUnderwriterPool() public {
        address newPool = makeAddr("underwriter");
        hook.setUnderwriterPool(newPool);
        assertEq(address(hook.underwriterPool()), newPool);
    }

    function test_setPremiumOracle() public {
        address oracle = makeAddr("oracle");
        hook.setPremiumOracle(oracle);
        assertEq(address(hook.premiumOracle()), oracle);
    }

    function test_setEpochSettlement() public {
        address settlement = makeAddr("settlement");
        hook.setEpochSettlement(settlement);
        assertEq(hook.epochSettlement(), settlement);
    }

    function test_setPoolCapacity_byOwner() public {
        hook.setPoolCapacity(poolId, 500e18);
        assertEq(hook.poolCapacity(poolId), 500e18);
    }

    function test_setPoolCapacity_reverts_unauthorized() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert("unauthorized");
        hook.setPoolCapacity(poolId, 999e18);
    }

    // ─── Claimable IL Tests ─────────────────────────────────

    function test_claimable_zeroWithNoPriceChange() public {
        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(poolKey, addParams, BELTA_OPT_IN);

        uint256 claimable = hook.getClaimable(poolId, address(modifyLiquidityRouter), -120, 120);
        assertEq(claimable, 0);
    }

    function test_claimILPayout_reverts_nothingToClaim() public {
        vm.expectRevert(BELTAHook.NothingToClaim.selector);
        hook.claimILPayout(poolId, -120, 120);
    }

    // ─── Constants Tests ────────────────────────────────────

    function test_constants() public view {
        assertEq(hook.COVERAGE_CAP_BPS(), 4500);
        assertEq(hook.EPOCH_DURATION(), 7 days);
        assertEq(hook.DAILY_PAY_LIMIT_BPS(), 500);
    }
}
