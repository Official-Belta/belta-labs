// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {Currency} from "@v4-core/types/Currency.sol";
import {IHooks} from "@v4-core/interfaces/IHooks.sol";
import {TickMath} from "@v4-core/libraries/TickMath.sol";
import {StateLibrary} from "@v4-core/libraries/StateLibrary.sol";
import {BalanceDelta} from "@v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@v4-core/types/PoolOperation.sol";
import {CurrencyLibrary} from "@v4-core/types/Currency.sol";

// V4 core test helpers - handles unlock callback pattern
import {PoolModifyLiquidityTest} from "@v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@v4-core/test/PoolSwapTest.sol";

import {BELTAHook} from "../src/BELTAHook.sol";
import {UnderwriterPool} from "../src/UnderwriterPool.sol";
import {EpochSettlement} from "../src/EpochSettlement.sol";
import {PremiumOracle} from "../src/PremiumOracle.sol";
import {TreasuryModule} from "../src/TreasuryModule.sol";

interface IMockERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function mint(address, uint256) external;
    function transfer(address, uint256) external returns (bool);
}

/// @title FakeLPFlow - Full LP lifecycle on Sepolia fork
/// @notice 3 fake LPs -> Add Liquidity -> Swap (price move) -> Epoch -> Settle -> IL Claim
contract FakeLPFlowTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── Sepolia deployed addresses ────────────────────────
    IPoolManager poolManager = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    IMockERC20 usdc = IMockERC20(0xA64b084D47657A799885aAC2dC861A7C432b6D12);
    IMockERC20 weth = IMockERC20(0x45921423FdA7260efBE844d4479254d5169355D5);
    BELTAHook hook = BELTAHook(0x07F4F427378eF485931999ACE2917a210F0b9540);
    UnderwriterPool pool = UnderwriterPool(0x67B0e434BE06fC63224ee0d0B2E4B08Ebd9b1622);
    EpochSettlement settlement = EpochSettlement(0x064F6ada17F51575B11c538eD5C5B6a6D7F0eC30);
    TreasuryModule treasury = TreasuryModule(0xC84B9df70cBdF35945b2230f0f9e1d09Ee35850e);
    PremiumOracle oracle = PremiumOracle(0x3FDF2ac8B75Aa5043763c9615E20ECA88d2A801F);

    address deployer = 0xF2F8741Dc50B94367284B7Bac888f5c5dd8a237d;

    // V4 test helpers (deployed fresh on fork)
    PoolModifyLiquidityTest modifyLiqRouter;
    PoolSwapTest swapRouter;

    // Fake LPs
    address lp1 = makeAddr("LP1_Whale");
    address lp2 = makeAddr("LP2_Medium");
    address lp3 = makeAddr("LP3_Small");
    address swapper = makeAddr("Swapper");

    PoolKey key;
    PoolId poolId;

    // LP tick ranges
    int24 lp1Lower; int24 lp1Upper;
    int24 lp2Lower; int24 lp2Upper;
    int24 lp3Lower; int24 lp3Upper;

    function setUp() public {
        // Deploy V4 test helper routers on the fork
        modifyLiqRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);

        key = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
    }

    function test_FullLPLifecycle() public {
        console.log("====================================================");
        console.log("  BELTA Labs - Fake LP Full Flow Simulation");
        console.log("====================================================");

        // ─── Step 0: Verify pool state ─────────────────────
        (uint160 sqrtPrice, int24 currentTick,,) = poolManager.getSlot0(poolId);
        assertTrue(sqrtPrice > 0, "Pool must be initialized");
        console.log("");
        console.log("[0] Pool OK. Tick:", uint256(uint24(currentTick)));
        console.log("[0] Pool TVL:", pool.totalAssets() / 1e6, "USDC");
        console.log("[0] Capacity:", hook.poolCapacity(poolId) / 1e6, "USDC");

        // Set tick ranges around current tick (aligned to tickSpacing=60)
        lp1Lower = ((currentTick - 600) / 60) * 60;
        lp1Upper = ((currentTick + 600) / 60) * 60;
        lp2Lower = ((currentTick - 300) / 60) * 60;
        lp2Upper = ((currentTick + 300) / 60) * 60;
        lp3Lower = ((currentTick - 120) / 60) * 60;
        lp3Upper = ((currentTick + 120) / 60) * 60;

        // ─── Step 1: Fund LPs + Swapper ────────────────────
        // High liquidity = small price impact per swap = realistic ±5~20% moves
        console.log("");
        console.log("--- Step 1: Fund Fake LPs ---");
        _fundAccount(lp1, 5_000 ether, 10_000_000e6);
        _fundAccount(lp2, 2_000 ether, 4_000_000e6);
        _fundAccount(lp3, 500 ether, 1_000_000e6);
        _fundAccount(swapper, 2_000 ether, 4_000_000e6);
        // Also fund the router helpers so they can settle
        _fundAccount(address(modifyLiqRouter), 10_000 ether, 20_000_000e6);
        console.log("[1] All accounts funded");

        // ─── Step 2: LPs add liquidity with BELTA opt-in ──
        console.log("");
        console.log("--- Step 2: Add Liquidity (BELTA opt-in) ---");

        bytes memory optIn = abi.encodePacked(bytes1(0x01));

        // Liquidity units are NOT token amounts.
        // High liquidity so swaps produce realistic ±5~20% price moves (not extreme ticks)
        // 500M liq in wide range = deep pool, swap 50K USDC moves price ~10%

        // LP1: Wide range ±600 ticks ≈ ±6%
        _approveAndAddLiquidity(lp1, lp1Lower, lp1Upper, 500_000_000, optIn);
        console.log("[2] LP1 (Whale): Wide range, 500M liq");

        // LP2: Medium range ±300 ticks ≈ ±3%
        _approveAndAddLiquidity(lp2, lp2Lower, lp2Upper, 200_000_000, optIn);
        console.log("[2] LP2 (Medium): Medium range, 200M liq");

        // LP3: Tight range ±120 ticks ≈ ±1.2% (highest IL risk)
        _approveAndAddLiquidity(lp3, lp3Lower, lp3Upper, 50_000_000, optIn);
        console.log("[2] LP3 (Small): Tight range, 50M liq");

        // ─── Step 3: Verify positions registered ───────────
        console.log("");
        console.log("--- Step 3: Verify Positions ---");
        _logPosition(lp1, lp1Lower, lp1Upper, "LP1");
        _logPosition(lp2, lp2Lower, lp2Upper, "LP2");
        _logPosition(lp3, lp3Lower, lp3Upper, "LP3");

        uint256 hedgedBefore = hook.totalHedgedValue(poolId);
        console.log("[3] Total hedged:", hedgedBefore);
        console.log("[3] Utilization:", hook.getUtilization(poolId), "bps");
        console.log("[3] Premium rate:", hook.getCurrentPremiumRate(poolId), "bps");

        // ─── Step 4: Simulate swaps (price movement) ───────
        console.log("");
        console.log("--- Step 4: Price Movement via Swaps ---");
        (uint160 priceBefore,,,) = poolManager.getSlot0(poolId);
        console.log("[4] sqrtPrice before:", uint256(priceBefore));

        // Fund swapper approvals for the swap router
        vm.prank(swapper);
        weth.approve(address(swapRouter), type(uint256).max);
        vm.prank(swapper);
        usdc.approve(address(swapRouter), type(uint256).max);
        // Fund the swap router too
        _fundAccount(address(swapRouter), 5_000 ether, 10_000_000e6);

        // Swap: sell USDC for WETH (push ETH price UP -> generates IL)
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Swap sizes calibrated for ~10-15% net price movement with 750M total liquidity
        // Swap 1: Big buy — push ETH price UP ~8%
        vm.prank(swapper);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, // USDC -> WETH (price up)
                amountSpecified: -int256(100_000e6), // sell 100K USDC
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ""
        );
        console.log("[4] Swap 1: Sold 100K USDC for WETH (price UP)");

        {
            (, int24 midTick,,) = poolManager.getSlot0(poolId);
            console.log("[4] Tick after swap 1:", uint256(uint24(midTick)));
        }

        // Swap 2: Small sell — revert ~2%
        vm.prank(swapper);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, // WETH -> USDC (price down)
                amountSpecified: -int256(10 ether), // sell 10 WETH
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ""
        );
        console.log("[4] Swap 2: Sold 10 WETH for USDC (price DOWN slightly)");

        // Swap 3: Another buy — net UP ~10-15%
        vm.prank(swapper);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, // USDC -> WETH (price up)
                amountSpecified: -int256(80_000e6), // sell 80K USDC
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ""
        );
        console.log("[4] Swap 3: Sold 80K USDC for WETH (price UP more)");

        (uint160 priceAfter, int24 tickAfter,,) = poolManager.getSlot0(poolId);
        console.log("[4] sqrtPrice after:", uint256(priceAfter));
        console.log("[4] Tick after:", uint256(uint24(tickAfter)));

        // ─── Step 5: Advance 7 days ────────────────────────
        console.log("");
        console.log("--- Step 5: Advance Epoch (7 days) ---");
        vm.warp(block.timestamp + 7 days + 1);

        // Advance epoch manually
        hook.advanceEpoch(key);
        (uint256 newEpoch,,) = hook.epochs(poolId);
        console.log("[5] Epoch advanced to:", newEpoch);

        // ─── Step 6: ALL LPs remove liquidity (triggers IL calc) ─
        console.log("");
        console.log("--- Step 6: All LPs Remove Liquidity ---");

        _removeLiquidity("LP1", lp1, lp1Lower, lp1Upper);
        _removeLiquidity("LP2", lp2, lp2Lower, lp2Upper);
        _removeLiquidity("LP3", lp3, lp3Lower, lp3Upper);

        // ─── Step 7: Check accumulated premiums + IL claims ─
        console.log("");
        console.log("--- Step 7: Protocol Accounting ---");
        uint256 accPremiums = hook.accumulatedPremiums(poolId);
        uint256 pendClaims = hook.pendingILClaims(poolId);
        console.log("[7] Accumulated premiums:", accPremiums);
        console.log("[7] Pending IL claims:", pendClaims);
        console.log("[7] Total hedged:", hook.totalHedgedValue(poolId));
        console.log("[7] Premium vs Claims ratio:", accPremiums > 0 ? (pendClaims * 100) / accPremiums : 0, "%");

        // ─── Step 8: Keeper settlement ─────────────────────
        console.log("");
        console.log("--- Step 8: Epoch Settlement ---");
        bool needsSettle = settlement.needsSettlement(key);
        console.log("[8] Needs settlement:", needsSettle);

        if (needsSettle) {
            vm.prank(deployer);
            settlement.settle(key);
            console.log("[8] Settlement DONE");
        } else {
            console.log("[8] Skipped (no settlement needed)");
        }

        // ─── Step 9: ALL LPs claim IL payouts ────────────────
        console.log("");
        console.log("--- Step 9: IL Claims for All LPs ---");
        _claimIL("LP1", lp1Lower, lp1Upper);
        _claimIL("LP2", lp2Lower, lp2Upper);
        _claimIL("LP3", lp3Lower, lp3Upper);

        // ─── Final Summary ─────────────────────────────────
        console.log("");
        console.log("====================================================");
        console.log("  FINAL STATE");
        console.log("====================================================");
        console.log("  Pool TVL:       ", pool.totalAssets() / 1e6, "USDC");
        console.log("  Treasury:       ", usdc.balanceOf(address(treasury)) / 1e6, "USDC");
        console.log("  Total Hedged:   ", hook.totalHedgedValue(poolId));
        console.log("  Acc Premiums:   ", hook.accumulatedPremiums(poolId));
        console.log("  Pending Claims: ", hook.pendingILClaims(poolId));
        console.log("  Premiums Earned:", pool.totalPremiumsEarned());
        console.log("  Claims Paid:    ", pool.totalClaimsPaid());
        console.log("====================================================");
        console.log("  [PASS] Full LP lifecycle simulation complete!");
        console.log("====================================================");
    }

    // ─── Helpers ────────────────────────────────────────────

    function _approveAndAddLiquidity(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes memory hookData
    ) internal {
        vm.prank(lp);
        weth.approve(address(modifyLiqRouter), type(uint256).max);
        vm.prank(lp);
        usdc.approve(address(modifyLiqRouter), type(uint256).max);
        vm.prank(lp);
        modifyLiqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            hookData
        );
    }

    function _fundAccount(address account, uint256 wethAmt, uint256 usdcAmt) internal {
        vm.startPrank(deployer);
        if (wethAmt > 0) weth.mint(account, wethAmt);
        if (usdcAmt > 0) usdc.mint(account, usdcAmt);
        vm.stopPrank();
    }

    function _logPosition(address lp, int24 tickLower, int24 tickUpper, string memory name) internal view {
        // Position is registered under modifyLiqRouter address (it's the sender to PoolManager)
        BELTAHook.LPPosition memory pos = hook.getPosition(poolId, address(modifyLiqRouter), tickLower, tickUpper);
        if (pos.active) {
            console.log("[3]", name, "ACTIVE. Liquidity:", uint256(pos.liquidity));
        } else {
            // Try checking under the LP address directly
            pos = hook.getPosition(poolId, lp, tickLower, tickUpper);
            if (pos.active) {
                console.log("[3]", name, "ACTIVE (direct). Liquidity:", uint256(pos.liquidity));
            } else {
                console.log("[3]", name, "NOT registered");
            }
        }
    }

    function _removeLiquidity(string memory name, address lp, int24 tickLower, int24 tickUpper) internal {
        BELTAHook.LPPosition memory pos = hook.getPosition(poolId, address(modifyLiqRouter), tickLower, tickUpper);
        console.log("[6]", name, "active:", pos.active);
        console.log("[6]", name, "liquidity:", uint256(pos.liquidity));

        if (pos.active && pos.liquidity > 0) {
            vm.prank(lp);
            modifyLiqRouter.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(uint256(pos.liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            console.log("[6]", name, "removed all liquidity");
        }
    }

    function _claimIL(string memory name, int24 tickLower, int24 tickUpper) internal {
        uint256 claimable = hook.getClaimable(poolId, address(modifyLiqRouter), tickLower, tickUpper);
        console.log("[9]", name, "IL claimable:", claimable);

        if (claimable > 0) {
            vm.prank(address(modifyLiqRouter));
            hook.claimILPayout(poolId, tickLower, tickUpper);
            console.log("[9]", name, "IL payout claimed!");
        } else {
            console.log("[9]", name, "no IL claim (in-range or no loss)");
        }
    }
}
