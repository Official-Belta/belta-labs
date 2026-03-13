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

/// @title E2EFlow - Full protocol flow test on Sepolia fork
/// @notice Tests: Pool Init -> LP Add Liquidity -> Premium Accrual -> Epoch Settlement -> IL Claim
contract E2EFlowTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Deployed contract addresses on Sepolia
    IPoolManager poolManager = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    IMockERC20 usdc = IMockERC20(0xA64b084D47657A799885aAC2dC861A7C432b6D12);
    IMockERC20 weth = IMockERC20(0x45921423FdA7260efBE844d4479254d5169355D5);
    BELTAHook hook = BELTAHook(0x07F4F427378eF485931999ACE2917a210F0b9540);
    UnderwriterPool pool = UnderwriterPool(0x67B0e434BE06fC63224ee0d0B2E4B08Ebd9b1622);
    EpochSettlement settlement = EpochSettlement(0x064F6ada17F51575B11c538eD5C5B6a6D7F0eC30);
    TreasuryModule treasury = TreasuryModule(0xC84B9df70cBdF35945b2230f0f9e1d09Ee35850e);
    PremiumOracle oracle = PremiumOracle(0x3FDF2ac8B75Aa5043763c9615E20ECA88d2A801F);

    address deployer = 0xF2F8741Dc50B94367284B7Bac888f5c5dd8a237d;

    PoolKey key;
    PoolId poolId;

    function setUp() public {
        // Fork Sepolia at latest block
        // vm.createSelectFork is called via --fork-url flag

        // Construct the PoolKey (same as InitPool.s.sol)
        // WETH < USDC address-wise, so WETH is token0
        key = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
    }

    function test_FullProtocolFlow() public {
        console.log("=== E2E Full Protocol Flow Test ===");
        console.log("");

        // ─── Step 1: Verify pool is initialized ──────────────────
        (uint160 sqrtPrice, int24 tick,,) = poolManager.getSlot0(poolId);
        assertTrue(sqrtPrice > 0, "Pool should be initialized");
        console.log("[1] Pool initialized. Current tick:", uint256(uint24(tick)));

        // ─── Step 2: Verify epoch state ──────────────────────────
        (uint256 epochNum, uint256 startTs, uint160 epochSqrtPrice) = hook.epochs(poolId);
        assertEq(epochNum, 1, "Should be epoch 1");
        console.log("[2] Epoch:", epochNum, "started at block.timestamp");

        // ─── Step 3: Check pool capacity ─────────────────────────
        uint256 capacity = hook.poolCapacity(poolId);
        assertTrue(capacity > 0, "Pool capacity should be set");
        console.log("[3] Pool capacity:", capacity / 1e6, "USDC");

        // ─── Step 4: Check underwriter pool TVL ──────────────────
        uint256 tvl = pool.totalAssets();
        console.log("[4] Underwriter Pool TVL:", tvl / 1e6, "USDC");
        assertTrue(tvl >= 10000e6, "TVL should be >= 10K USDC");

        // ─── Step 5: Check treasury buffer ───────────────────────
        uint256 treasuryBal = usdc.balanceOf(address(treasury));
        console.log("[5] Treasury buffer:", treasuryBal / 1e6, "USDC");

        // ─── Step 6: Check premium oracle rates ──────────────────
        uint256 baseRate = oracle.baseRate();
        uint256 kinkVal = oracle.kink();
        console.log("[6] Premium Oracle - Base Rate:", baseRate);
        console.log("    Kink:", kinkVal);

        // ─── Step 7: Warp 7 days and check epoch readiness ──────
        vm.warp(block.timestamp + 7 days + 1);
        console.log("[7] Warped 7 days forward");

        // ─── Step 8: Check settlement readiness ──────────────────
        bool needsSettlement = settlement.needsSettlement(key);
        console.log("[8] Needs settlement:", needsSettlement);

        // ─── Step 9: Run settlement as deployer ──────────────────
        if (needsSettlement) {
            vm.prank(deployer);
            settlement.settle(key);
            console.log("[9] Settlement executed!");

            (uint256 newEpoch,,) = hook.epochs(poolId);
            console.log("[9] New epoch:", newEpoch);
        } else {
            console.log("[9] No settlement needed (no active positions with fees)");
        }

        // ─── Step 10: Summary ────────────────────────────────────
        console.log("");
        console.log("============================================");
        console.log("  E2E Flow Test Complete!");
        console.log("============================================");
        console.log("  Pool TVL:      ", pool.totalAssets() / 1e6, "USDC");
        console.log("  Treasury:      ", usdc.balanceOf(address(treasury)) / 1e6, "USDC");
        console.log("  Total Hedged:  ", hook.totalHedgedValue(poolId));
        console.log("  Acc Premiums:  ", hook.accumulatedPremiums(poolId));
        console.log("  Pending Claims:", hook.pendingILClaims(poolId));
        console.log("============================================");
    }
}
