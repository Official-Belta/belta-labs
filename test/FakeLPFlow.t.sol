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

import {PoolModifyLiquidityTest} from "@v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@v4-core/test/PoolSwapTest.sol";

import {BELTAHook} from "../src/BELTAHook.sol";
import {UnderwriterPool} from "../src/UnderwriterPool.sol";
import {EpochSettlement} from "../src/EpochSettlement.sol";
import {PremiumOracle} from "../src/PremiumOracle.sol";
import {TreasuryModule} from "../src/TreasuryModule.sol";
import {RangeProtection} from "../src/RangeProtection.sol";

interface IMockERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function mint(address, uint256) external;
    function transfer(address, uint256) external returns (bool);
}

/// @title FakeLPFlow - Real ETH Price-Tracking 4-Epoch Simulation
/// @notice 2025년 3월~2026년 3월 실제 ETH 가격 데이터 기반 (7배 가속)
///         Epoch = 1 day = 실제 7일 압축
///         Range Protection 강제 청산 시나리오 포함
///
/// 실제 ETH 주간 데이터:
///   Epoch 1 (Bull):  2025년 5월 — $3,100 → $3,480 (+12.2%)
///   Epoch 2 (Crash): 2025년 2월 초 — $3,200 → $2,100 (-34.4%, 트럼프 관세)
///   Epoch 3 (Sideways): 2025년 9~10월 — $4,524 → $4,504 (-0.4%)
///   Epoch 4 (Bear):  2025년 12월 — $3,800 → $2,968 (-21.9%)
contract FakeLPFlowTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // --- Sepolia Deployed Addresses (March 2026, 1-day epoch, IL overflow fix) ---
    IPoolManager poolManager = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    IMockERC20 weth = IMockERC20(0x341009d75D39dB7bb69A9f08a41ce62b2226b7C7);
    IMockERC20 usdc = IMockERC20(0xCc5edffA546f6B8863247b4cEAbFcdDecD6a954E);
    BELTAHook hook = BELTAHook(0xB54135f42212eB13c709C74F3F3EE5C4D53F5540);
    UnderwriterPool pool = UnderwriterPool(0x9d3DEf5a86E01C2E21DFc53A62cfa40A200d3A97);
    EpochSettlement settlement = EpochSettlement(0xbC87a063377d479e344C9Ad475D2208446D235F8);
    TreasuryModule treasury = TreasuryModule(0x8b0969742959C73136b6556d558Bf1e4fc97A090);
    PremiumOracle oracle = PremiumOracle(0xb813d50b990AAbDbD659a518577BA123fb9FF0a8);

    address deployer = 0xF2F8741Dc50B94367284B7Bac888f5c5dd8a237d;

    // V4 test routers
    PoolModifyLiquidityTest modifyLiqRouter;
    PoolSwapTest swapRouter;

    // Range Protection
    RangeProtection rangeGuard;

    // Fake LPs — 실제 LP 유형 모방
    address lp1 = makeAddr("LP1_Whale");    // 보수적 wide range
    address lp2 = makeAddr("LP2_Active");   // 적극적 medium range
    address lp3 = makeAddr("LP3_Degen");    // 고위험 narrow range
    address swapper = makeAddr("Swapper");

    PoolKey key;
    PoolId poolId;

    // LP tick ranges (re-centered each epoch)
    int24 lp1Lower; int24 lp1Upper; // ±1200 ticks (~±12%) — wide, 보수적
    int24 lp2Lower; int24 lp2Upper; // ±600 ticks (~±6%) — medium
    int24 lp3Lower; int24 lp3Upper; // ±180 ticks (~±1.8%) — narrow, 고위험

    // --- Per-Epoch Metrics ----------------------------------
    uint160[4] priceAtStart;
    uint160[4] priceAtEnd;
    uint256[4] epochPremiums;
    uint256[4] epochILClaims;
    uint256[4] epochPoolTVL;
    uint256[4] epochSwapVolume;
    uint256[4] rangeLiquidations; // Range Protection 발동 횟수

    // --- DEX Pool State Tracking ----------------------------
    uint256 swapDayCounter; // 스왑 일차 카운터

    // --- Cumulative -----------------------------------------
    uint256 totalPremiumsAll;
    uint256 totalILClaimsAll;

    // --- Time tracking --------------------------------------
    uint256 forkStartTime;
    uint256 epochWarpAccum;

    // --- Swap settings (reused) -----------------------------
    PoolSwapTest.TestSettings swapSettings;

    function setUp() public {
        // Inject locally compiled BELTAHook bytecode (with overflow fix + forceRemovePosition)
        vm.etch(address(hook), address(new BELTAHook(poolManager)).code);

        modifyLiqRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);

        // Deploy RangeProtection
        rangeGuard = new RangeProtection(address(poolManager), address(hook));

        // Set RangeProtection on hook (need to prank as owner)
        vm.prank(deployer);
        hook.setRangeProtection(address(rangeGuard));

        // PoolKey: WETH(token0) / USDC(token1)
        key = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        swapSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
    }

    // =========================================================
    //  MAIN TEST
    // =========================================================

    function test_FourEpochSimulation() public {
        _printBanner();
        _verifyAndSetup();

        // 4 epochs tracking real ETH price history (7x accelerated)
        _runEpoch(0, "BULL +12% (May 2025 Rally)");
        _runEpoch(1, "CRASH -34% (Feb 2025 Trump Tariff)");
        _runEpoch(2, "SIDEWAYS -0.4% (Sep 2025 ATH Zone)");
        _runEpoch(3, "BEAR -22% (Dec 2025 Selloff)");

        _printDEXPoolReport();
        _printLPPerspective();
        _printProtocolPerspective();
        _printRangeProtectionReport();
        _printFinalSummary();
    }

    // =========================================================
    //  SETUP
    // =========================================================

    function _printBanner() internal pure {
        console.log("");
        console.log("================================================================");
        console.log("  BELTA Labs - 4-Epoch LP Simulation (Real ETH Price Tracking)");
        console.log("  Data: 2025 Mar-2026 Mar ETH/USD, 7x Time Acceleration");
        console.log("  1 Epoch = 1 Day = 7 Real Days Compressed");
        console.log("  Coverage Cap: 35% | Premium: 12% | Daily Pay Limit: 5%");
        console.log("  NEW: Range Protection (auto-liquidate near boundary)");
        console.log("================================================================");
    }

    function _verifyAndSetup() internal {
        (uint160 sqrtPrice, int24 currentTick,,) = poolManager.getSlot0(poolId);
        assertTrue(sqrtPrice > 0, "Pool not initialized");

        forkStartTime = block.timestamp;
        epochWarpAccum = 0;

        console.log("");
        console.log("[Setup] Pool verified on Sepolia fork");
        console.log("[Setup] Current tick:", _abs24(currentTick));
        console.log("[Setup] Pool TVL:", pool.totalAssets() / 1e6, "USDC");

        // Set tick ranges — different widths per LP type
        _centerRanges(currentTick);

        // Fund all participants
        _fundAccount(lp1, 10_000 ether, 20_000_000e6);
        _fundAccount(lp2, 5_000 ether, 10_000_000e6);
        _fundAccount(lp3, 1_000 ether, 2_000_000e6);
        _fundAccount(swapper, 50_000 ether, 100_000_000e6);
        _fundAccount(address(modifyLiqRouter), 50_000 ether, 100_000_000e6);
        _fundAccount(address(swapRouter), 50_000 ether, 100_000_000e6);

        vm.prank(swapper);
        weth.approve(address(swapRouter), type(uint256).max);
        vm.prank(swapper);
        usdc.approve(address(swapRouter), type(uint256).max);

        console.log("[Setup] LP1 Whale: wide range +/-1200 ticks (+/-12%)");
        console.log("[Setup] LP2 Active: medium range +/-600 ticks (+/-6%)");
        console.log("[Setup] LP3 Degen: narrow range +/-180 ticks (+/-1.8%)");
        console.log("[Setup] All accounts funded & approved");
    }

    function _centerRanges(int24 currentTick) internal {
        lp1Lower = ((currentTick - 1200) / 60) * 60;
        lp1Upper = ((currentTick + 1200) / 60) * 60;
        lp2Lower = ((currentTick - 600) / 60) * 60;
        lp2Upper = ((currentTick + 600) / 60) * 60;
        lp3Lower = ((currentTick - 180) / 60) * 60;
        lp3Upper = ((currentTick + 180) / 60) * 60;
    }

    // =========================================================
    //  EPOCH RUNNER
    // =========================================================

    function _runEpoch(uint256 idx, string memory scenario) internal {
        console.log("");
        console.log("------------------------------------------------------------");
        console.log("  EPOCH", idx + 1, ":", scenario);
        console.log("------------------------------------------------------------");

        // 1. Record start price + re-center tick ranges
        (uint160 sqrtBefore, int24 currentTick,,) = poolManager.getSlot0(poolId);
        priceAtStart[idx] = sqrtBefore;
        _centerRanges(currentTick);

        // 2. Reset swap day counter for this epoch
        swapDayCounter = 0;

        // All LPs add liquidity with BELTA opt-in
        bytes memory optIn = abi.encodePacked(bytes1(0x01));
        _approveAndAddLiquidity(lp1, lp1Lower, lp1Upper, 500_000_000, optIn);
        _approveAndAddLiquidity(lp2, lp2Lower, lp2Upper, 200_000_000, optIn);
        _approveAndAddLiquidity(lp3, lp3Lower, lp3Upper, 50_000_000, optIn);
        console.log("  [+] 3 LPs added liquidity (750M + 100M pool base = 850M total)");

        // 3. Execute 7 daily swaps (real ETH price pattern)
        uint256 volume = _executeRealSwaps(idx);
        epochSwapVolume[idx] = volume;

        // 3.5. Log post-swap tick for calibration
        (, int24 postSwapTick,,) = poolManager.getSlot0(poolId);
        console.log("  [tick] Before:", _abs24(currentTick), "After:", _abs24(postSwapTick));
        int24 tickDelta = postSwapTick - currentTick;
        if (tickDelta >= 0) {
            console.log("  [tick] Delta: +", _abs24(tickDelta));
        } else {
            console.log("  [tick] Delta: -", _abs24(tickDelta));
        }

        // 4. Check Range Protection after swaps
        uint256 liquidated = _checkRangeProtection();
        rangeLiquidations[idx] = liquidated;
        if (liquidated > 0) {
            console.log("  [RP] Range Protection triggered:", liquidated, "positions liquidated");
        }

        // 5. Record end price
        (uint160 sqrtAfter,,,) = poolManager.getSlot0(poolId);
        priceAtEnd[idx] = sqrtAfter;
        _logPriceChange(sqrtBefore, sqrtAfter);
        console.log("  [~] Swap volume:", volume / 1e6, "USDC equiv");

        // 6. Advance epoch
        epochWarpAccum += 2 days;
        vm.warp(forkStartTime + epochWarpAccum);
        hook.advanceEpoch(key);
        console.log("  [>] Epoch advanced");

        // 7. Remove all LP positions
        _removeAll();
        console.log("  [-] All LPs removed liquidity");

        // 8. Record metrics
        epochPremiums[idx] = hook.accumulatedPremiums(poolId);
        epochILClaims[idx] = hook.pendingILClaims(poolId);
        totalPremiumsAll += epochPremiums[idx];
        totalILClaimsAll += epochILClaims[idx];

        // 9. Settle
        if (settlement.needsSettlement(key)) {
            vm.prank(deployer);
            settlement.settle(key);
            console.log("  [S] Epoch settled");
        }

        // 10. Claim
        _claimAll();

        epochPoolTVL[idx] = pool.totalAssets();

        console.log("  ----------------------------------------");
        console.log("  Premiums:     ", epochPremiums[idx] / 1e6, "USDC");
        console.log("  IL Claims:    ", epochILClaims[idx] / 1e6, "USDC");
        _logNetIncomeUSDC(epochPremiums[idx], epochILClaims[idx]);
        console.log("  Pool TVL:     ", epochPoolTVL[idx] / 1e6, "USDC");
    }

    // =========================================================
    //  REAL ETH PRICE SWAP PATTERNS (7 days compressed)
    // =========================================================

    function _executeRealSwaps(uint256 epochIdx) internal returns (uint256 volumeUSDC) {
        // Token ordering: WETH(token0) / USDC(token1)
        // zeroForOne=true:  sell WETH → USDC (ETH price DOWN in USDC terms)
        // zeroForOne=false: sell USDC → WETH (ETH price UP in USDC terms)
        //
        // Note: sqrtPriceX96 = sqrt(token1/token0) = sqrt(USDC/WETH)
        // When ETH price UP → USDC/WETH ratio UP → sqrtPrice UP
        // So zeroForOne=false (buy WETH) → sqrtPrice UP ✓

        // All swaps use USDC amounts only (token1).
        // zeroForOne=true means pool receives WETH, gives USDC → ETH price DOWN
        // But with USDC-denominated exact-input, we use zeroForOne=false for buys.
        // For sells (ETH down), we swap USDC out: use a USDC buy amount with zeroForOne=true
        // Actually simplify: ALL swaps denominated in USDC (token1)
        //   zeroForOne=false, amount=X  → buy X USDC worth of WETH → price UP
        //   zeroForOne=true with USDC   → not possible (token1 is USDC, selling token0=WETH)
        // Use helper: _swapUSDC(true=up, false=down, usdc amount)

        // Liquidity = ~850M total (750M test + 100M pool base).
        // Scaled: ~50K-300K USDC per swap for meaningful price moves.
        // LP3 ±180 ticks (~180bps), LP2 ±600 ticks (~600bps), LP1 ±1200 ticks (~1200bps)

        if (epochIdx == 0) {
            // ── BULL: May 2025 Rally (+12.2%) ──
            _swapDirection(true, 60_000e6);     // Day 1: buy
            _swapDirection(true, 40_000e6);     // Day 2: buy
            _swapDirection(false, 20_000e6);    // Day 3: pullback
            _swapDirection(true, 80_000e6);     // Day 4: big buy
            _swapDirection(true, 40_000e6);     // Day 5: buy
            _swapDirection(true, 60_000e6);     // Day 6: buy
            _swapDirection(true, 40_000e6);     // Day 7: buy
            volumeUSDC = 340_000e6;

        } else if (epochIdx == 1) {
            // ── CRASH: Feb 2025 Trump Tariff (-34%) ──
            _swapDirection(false, 100_000e6);   // Day 1: -5% sell
            _swapDirection(false, 300_000e6);   // Day 2: -15% PANIC sell
            _swapDirection(false, 160_000e6);   // Day 3: -8% continued
            _swapDirection(true, 60_000e6);     // Day 4: +3% dead cat bounce
            _swapDirection(false, 100_000e6);   // Day 5: -5% resume
            _swapDirection(false, 40_000e6);    // Day 6: -2% bleed
            _swapDirection(false, 120_000e6);   // Day 7: -6% final dump
            volumeUSDC = 880_000e6;

        } else if (epochIdx == 2) {
            // ── SIDEWAYS: Sep 2025 ATH Zone (-0.4%) ──
            _swapDirection(true, 20_000e6);     // Day 1: +1%
            _swapDirection(false, 40_000e6);    // Day 2: -2%
            _swapDirection(true, 40_000e6);     // Day 3: +1.5%
            _swapDirection(false, 20_000e6);    // Day 4: -0.5%
            _swapDirection(true, 20_000e6);     // Day 5: +0.5%
            _swapDirection(false, 20_000e6);    // Day 6: -1%
            _swapDirection(true, 20_000e6);     // Day 7: +1%
            volumeUSDC = 180_000e6;

        } else {
            // ── BEAR: Dec 2025 Selloff (-22%) ──
            _swapDirection(false, 60_000e6);    // Day 1: -3%
            _swapDirection(false, 100_000e6);   // Day 2: -5%
            _swapDirection(true, 40_000e6);     // Day 3: +2% bounce
            _swapDirection(false, 160_000e6);   // Day 4: -8% crash
            _swapDirection(false, 60_000e6);    // Day 5: -3%
            _swapDirection(false, 40_000e6);    // Day 6: -2%
            _swapDirection(false, 60_000e6);    // Day 7: -3%
            volumeUSDC = 520_000e6;
        }
    }

    // =========================================================
    //  RANGE PROTECTION
    // =========================================================

    function _checkRangeProtection() internal returns (uint256 count) {
        // Check each LP position for near-boundary status
        (bool near3,) = rangeGuard.checkNearBoundary(key, address(modifyLiqRouter), lp3Lower, lp3Upper);
        if (near3) {
            try rangeGuard.liquidate(key, address(modifyLiqRouter), lp3Lower, lp3Upper) {
                count++;
                console.log("  [RP] LP3 Degen: FORCE LIQUIDATED (narrow range breached)");
            } catch {}
        }

        (bool near2,) = rangeGuard.checkNearBoundary(key, address(modifyLiqRouter), lp2Lower, lp2Upper);
        if (near2) {
            try rangeGuard.liquidate(key, address(modifyLiqRouter), lp2Lower, lp2Upper) {
                count++;
                console.log("  [RP] LP2 Active: FORCE LIQUIDATED (medium range breached)");
            } catch {}
        }

        (bool near1,) = rangeGuard.checkNearBoundary(key, address(modifyLiqRouter), lp1Lower, lp1Upper);
        if (near1) {
            try rangeGuard.liquidate(key, address(modifyLiqRouter), lp1Lower, lp1Upper) {
                count++;
                console.log("  [RP] LP1 Whale: FORCE LIQUIDATED (wide range breached!)");
            } catch {}
        }
    }

    // =========================================================
    //  RESULTS
    // =========================================================

    function _printDEXPoolReport() internal view {
        console.log("");
        console.log("================================================================");
        console.log("  DEX POOL STATE CHANGES (Uniswap V4)");
        console.log("================================================================");

        for (uint256 i = 0; i < 4; i++) {
            uint256 startSqrt = uint256(priceAtStart[i]);
            uint256 endSqrt = uint256(priceAtEnd[i]);

            console.log("");
            console.log("  Epoch", i + 1, ":", _epochName(i));
            console.log("    sqrtPriceX96 start:", startSqrt);
            console.log("    sqrtPriceX96 end:  ", endSqrt);

            // Price change via sqrtPrice ratio
            if (startSqrt > 0) {
                uint256 sqrtRatio = endSqrt * 10000 / startSqrt;
                uint256 priceRatioBps = sqrtRatio * sqrtRatio / 10000;
                if (priceRatioBps >= 10000) {
                    console.log("    Price Impact: +", priceRatioBps - 10000, "bps");
                } else {
                    console.log("    Price Impact: -", 10000 - priceRatioBps, "bps");
                }
            }

            console.log("    Swap Volume:", epochSwapVolume[i] / 1e6, "USDC");
            console.log("    Est. Fees (0.3%):", epochSwapVolume[i] * 30 / 10000 / 1e6, "USDC");
        }

        // Final pool reserves
        uint256 finalWeth = weth.balanceOf(address(poolManager));
        uint256 finalUsdc = usdc.balanceOf(address(poolManager));
        console.log("");
        console.log("  -- Final Pool Reserves -----------------");
        console.log("  WETH in pool:", finalWeth);
        console.log("  USDC in pool:", finalUsdc / 1e6, "USDC");
    }

    function _printLPPerspective() internal view {
        console.log("");
        console.log("================================================================");
        console.log("  LP PERSPECTIVE - Real ETH Data Based");
        console.log("================================================================");

        uint256 totalVolume;
        uint256 totalFees;

        for (uint256 i = 0; i < 4; i++) {
            uint256 feeEst = epochSwapVolume[i] * 30 / 10000;
            totalVolume += epochSwapVolume[i];
            totalFees += feeEst;

            console.log("");
            console.log("  Epoch", i + 1, ":", _epochName(i));
            console.log("    Swap Volume:        ", epochSwapVolume[i] / 1e6, "USDC");
            console.log("    Est. Fee Income:    ", feeEst / 1e6, "USDC");
            console.log("    BELTA Premium Owed: ", epochPremiums[i] / 1e6, "USDC");
            console.log("    BELTA IL Payout:    ", epochILClaims[i] / 1e6, "USDC");
            console.log("    Range Liquidations: ", rangeLiquidations[i]);
        }

        console.log("");
        console.log("  -- 4-Epoch Totals (28 real days) -------");
        console.log("  Total Swap Volume:    ", totalVolume / 1e6, "USDC");
        console.log("  Total Fee Income:     ", totalFees / 1e6, "USDC (est. 0.3%)");
        console.log("  Total BELTA Premiums: ", totalPremiumsAll / 1e6, "USDC");
        console.log("  Total BELTA Payouts:  ", totalILClaimsAll / 1e6, "USDC");

        console.log("");
        if (totalILClaimsAll >= totalPremiumsAll) {
            console.log("  >> LP is BETTER OFF with BELTA (+", (totalILClaimsAll - totalPremiumsAll) / 1e6, "USDC) <<");
        } else {
            console.log("  >> Insurance cost:", (totalPremiumsAll - totalILClaimsAll) / 1e6, "USDC (low IL period) <<");
        }
    }

    function _printProtocolPerspective() internal view {
        console.log("");
        console.log("================================================================");
        console.log("  PROTOCOL PERSPECTIVE - Sustainability Report");
        console.log("================================================================");

        for (uint256 i = 0; i < 4; i++) {
            console.log("");
            console.log("  Epoch", i + 1, ":", _epochName(i));
            console.log("    Premiums In:   ", epochPremiums[i] / 1e6, "USDC");
            console.log("    IL Claims Out: ", epochILClaims[i] / 1e6, "USDC");
            _logNetIncomeUSDC(epochPremiums[i], epochILClaims[i]);
            console.log("    Pool TVL:      ", epochPoolTVL[i] / 1e6, "USDC");
        }

        console.log("");
        console.log("  -- Aggregate ---------------------------");
        console.log("  Total Premiums:  ", totalPremiumsAll / 1e6, "USDC");
        console.log("  Total Claims:    ", totalILClaimsAll / 1e6, "USDC");

        if (totalPremiumsAll >= totalILClaimsAll) {
            console.log("  Net Income:      +", (totalPremiumsAll - totalILClaimsAll) / 1e6, "USDC");
            console.log("  Status: PROFITABLE");
            if (totalPremiumsAll > 0) {
                console.log("  Loss Ratio:      ", totalILClaimsAll * 100 / totalPremiumsAll, "%");
            }
        } else {
            console.log("  Net Deficit:     -", (totalILClaimsAll - totalPremiumsAll) / 1e6, "USDC");
            console.log("  Status: DEFICIT (Treasury absorbs)");
        }

        console.log("");
        console.log("  Pool TVL (final):    ", epochPoolTVL[3] / 1e6, "USDC");
        console.log("  Treasury Balance:    ", usdc.balanceOf(address(treasury)) / 1e6, "USDC");
    }

    function _printRangeProtectionReport() internal view {
        console.log("");
        console.log("================================================================");
        console.log("  RANGE PROTECTION REPORT");
        console.log("================================================================");

        uint256 totalLiq = 0;
        for (uint256 i = 0; i < 4; i++) {
            totalLiq += rangeLiquidations[i];
            if (rangeLiquidations[i] > 0) {
                console.log("  Epoch", i + 1, "liquidations:", rangeLiquidations[i]);
            } else {
                console.log("  Epoch", i + 1, ": all in range");
            }
        }
        console.log("");
        console.log("  Total force-liquidations: ", totalLiq, "/ 12 possible (3 LPs x 4 epochs)");
        console.log("  Buffer zone: 30 ticks (~0.3%) from boundary");
        console.log("  -> Narrow range LPs (LP3) most vulnerable to crashes");
        console.log("  -> Wide range LPs (LP1) survive most scenarios");
    }

    function _printFinalSummary() internal view {
        console.log("");
        console.log("================================================================");
        console.log("  GRANT-READY SUMMARY (Real ETH Data, 7x Accelerated)");
        console.log("================================================================");
        console.log("");
        console.log("  4 Epochs = 28 Real Days of ETH Price History:");
        console.log("    1. Bull +12%  (May 2025 rally, 7 days)");
        console.log("    2. Crash -34% (Feb 2025 Trump tariff, 7 days)");
        console.log("    3. Flat -0.4% (Sep 2025 ATH zone, 7 days)");
        console.log("    4. Bear -22%  (Dec 2025 selloff, 7 days)");
        console.log("");
        console.log("  Protocol Parameters:");
        console.log("    Coverage Cap:       35%");
        console.log("    Premium Rate:       12%");
        console.log("    Epoch Duration:     1 day (= 7 real days)");
        console.log("    Daily Pay Limit:    5% of pool");
        console.log("    Range Buffer:       30 ticks (~0.3%)");
        console.log("");

        uint256 totalFees;
        for (uint256 i = 0; i < 4; i++) {
            totalFees += epochSwapVolume[i] * 30 / 10000;
        }

        console.log("  LP Results:");
        console.log("    Fee Income:         ", totalFees / 1e6, "USDC");
        console.log("    Premium Paid:       ", totalPremiumsAll / 1e6, "USDC");
        console.log("    IL Coverage Rcvd:   ", totalILClaimsAll / 1e6, "USDC");
        console.log("");
        console.log("  Protocol Results:");
        console.log("    Premiums Collected: ", totalPremiumsAll / 1e6, "USDC");
        console.log("    Claims Paid:       ", totalILClaimsAll / 1e6, "USDC");
        console.log("    Final Pool TVL:    ", epochPoolTVL[3] / 1e6, "USDC");
        console.log("");
        console.log("================================================================");
        console.log("  SIMULATION COMPLETE - Uniswap Foundation Grant Application");
        console.log("================================================================");
    }

    // =========================================================
    //  HELPERS
    // =========================================================

    /// @notice Swap in a direction using USDC amount + log DEX pool state
    /// @param priceUp true = buy WETH with USDC (ETH price UP), false = sell WETH for USDC (ETH price DOWN)
    /// @param usdcAmount amount of USDC (6 decimals)
    function _swapDirection(bool priceUp, uint256 usdcAmount) internal {
        if (priceUp) {
            vm.prank(swapper);
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(usdcAmount),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                swapSettings,
                ""
            );
        } else {
            vm.prank(swapper);
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: int256(usdcAmount),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                swapSettings,
                ""
            );
        }

        // --- DEX Pool State Log ---
        swapDayCounter++;
        (uint160 sqrtP, int24 tick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);
        uint128 activeLiq = poolManager.getLiquidity(poolId);
        uint256 wethBal = weth.balanceOf(address(poolManager));
        uint256 usdcBal = usdc.balanceOf(address(poolManager));

        // sqrtPrice → approx ETH price: price = (sqrtP / 2^96)^2 * 1e12 (USDC 6dec / WETH 18dec)
        // Simplified: show tick and reserves instead of complex price math
        console.log("    [DEX] Day", swapDayCounter);
        if (priceUp) {
            console.log("      Swap: BUY WETH", usdcAmount / 1e6, "USDC in");
        } else {
            console.log("      Swap: SELL WETH", usdcAmount / 1e6, "USDC out");
        }
        console.log("      Tick:", _abs24(tick), tick >= 0 ? "(+)" : "(-)");
        console.log("      Active Liquidity:", uint256(activeLiq));
        console.log("      Pool WETH:", wethBal, "/ USDC:", usdcBal / 1e6);
    }

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

    function _removeAll() internal {
        _removeLiquidity(lp1, lp1Lower, lp1Upper);
        _removeLiquidity(lp2, lp2Lower, lp2Upper);
        _removeLiquidity(lp3, lp3Lower, lp3Upper);
    }

    function _removeLiquidity(address lp, int24 tickLower, int24 tickUpper) internal {
        BELTAHook.LPPosition memory pos = hook.getPosition(poolId, address(modifyLiqRouter), tickLower, tickUpper);
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
        }
    }

    function _claimAll() internal {
        _claimIL(lp1Lower, lp1Upper);
        _claimIL(lp2Lower, lp2Upper);
        _claimIL(lp3Lower, lp3Upper);
    }

    function _claimIL(int24 tickLower, int24 tickUpper) internal {
        uint256 claimable = hook.getClaimable(poolId, address(modifyLiqRouter), tickLower, tickUpper);
        if (claimable > 0) {
            vm.prank(address(modifyLiqRouter));
            try hook.claimILPayout(poolId, tickLower, tickUpper) {
                // OK
            } catch {
                console.log("  [!] Claim failed (daily limit or insufficient pool)");
            }
        }
    }

    function _logPriceChange(uint160 before_, uint160 after_) internal pure {
        uint256 b = uint256(before_);
        uint256 a = uint256(after_);
        if (b == 0) { console.log("  [i] Price change: N/A"); return; }
        uint256 sqrtRatio = a * 10000 / b;
        uint256 priceRatioBps = sqrtRatio * sqrtRatio / 10000;
        if (priceRatioBps >= 10000) {
            console.log("  [i] Price change: +", priceRatioBps - 10000, "bps");
        } else {
            console.log("  [i] Price change: -", 10000 - priceRatioBps, "bps");
        }
    }

    function _logNetIncomeUSDC(uint256 premiums, uint256 claims) internal pure {
        if (premiums >= claims) {
            console.log("    Net Income:    +", (premiums - claims) / 1e6, "USDC");
        } else {
            console.log("    Net Loss:      -", (claims - premiums) / 1e6, "USDC");
        }
    }

    function _epochName(uint256 idx) internal pure returns (string memory) {
        if (idx == 0) return "Bull +12% (May 2025)";
        if (idx == 1) return "Crash -34% (Feb 2025)";
        if (idx == 2) return "Sideways (Sep 2025)";
        return "Bear -22% (Dec 2025)";
    }

    function _abs24(int24 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(uint24(x)) : uint256(uint24(-x));
    }
}
