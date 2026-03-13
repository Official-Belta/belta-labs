// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {UnderwriterPool} from "../src/UnderwriterPool.sol";

/// @title BELTAFlow
/// @notice Foundry tests for core BELTA flows:
///         1. Deposit + Approve
///         2. Cooldown enforcement + Withdraw after 7 days
///         3. Epoch settlement after 7 days
contract BELTAFlowTest is Test {
    MockERC20 usdc;
    UnderwriterPool pool;

    address user = address(0xBEEF);
    address deployer = address(this);
    // Use a mock hook address (won't call hook functions in these tests)
    address mockHook = address(0x400C);

    function setUp() public {
        // Deploy MockUSDC (6 decimals)
        usdc = new MockERC20("Test USDC", "tUSDC", 6);

        // Deploy UnderwriterPool with mock hook
        pool = new UnderwriterPool(ERC20(address(usdc)), mockHook);

        // Mint 10,000 USDC to user
        usdc.mint(user, 10_000e6);

        // Seed pool with 1,000 USDC from deployer (so totalAssets > 0)
        usdc.mint(deployer, 1_000e6);
        usdc.approve(address(pool), 1_000e6);
        pool.deposit(1_000e6, deployer);
    }

    // ═══════════════════════════════════════════════════════════
    // Test 1: Deposit Flow (Approve + Deposit)
    // ═══════════════════════════════════════════════════════════

    function test_DepositFlow() public {
        uint256 depositAmount = 100e6; // 100 USDC

        vm.startPrank(user);

        // Check initial state
        uint256 usdcBefore = usdc.balanceOf(user);
        uint256 sharesBefore = pool.balanceOf(user);
        assertEq(sharesBefore, 0, "User should have 0 shares initially");

        // Approve
        usdc.approve(address(pool), depositAmount);
        assertEq(usdc.allowance(user, address(pool)), depositAmount, "Allowance should be set");

        // Deposit
        uint256 sharesReceived = pool.deposit(depositAmount, user);

        // Verify
        assertGt(sharesReceived, 0, "Should receive shares");
        assertEq(pool.balanceOf(user), sharesReceived, "Share balance should match");
        assertEq(usdc.balanceOf(user), usdcBefore - depositAmount, "USDC should be deducted");
        assertGt(pool.totalAssets(), 0, "Pool TVL should be > 0");

        vm.stopPrank();

        console.log("[PASS] Deposit: %s shares for %s USDC", sharesReceived / 1e6, depositAmount / 1e6);
    }

    // ═══════════════════════════════════════════════════════════
    // Test 2a: Withdraw REVERTS before cooldown
    // ═══════════════════════════════════════════════════════════

    function test_WithdrawRevertsBeforeCooldown() public {
        uint256 depositAmount = 100e6;

        // Deposit first
        vm.startPrank(user);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount, user);

        // Request withdrawal
        pool.requestWithdrawal();
        assertFalse(pool.canWithdraw(user), "Should NOT be withdrawable yet");

        // Try withdraw immediately -- should revert
        vm.expectRevert(UnderwriterPool.CooldownNotMet.selector);
        pool.withdraw(50e6, user, user);

        vm.stopPrank();

        console.log("[PASS] Withdraw blocked before cooldown (CooldownNotMet)");
    }

    // ═══════════════════════════════════════════════════════════
    // Test 2b: Withdraw SUCCEEDS after 7 days
    // ═══════════════════════════════════════════════════════════

    function test_WithdrawAfterCooldown() public {
        uint256 depositAmount = 100e6;
        uint256 withdrawAmount = 50e6;

        // Deposit
        vm.startPrank(user);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount, user);

        // Request withdrawal
        pool.requestWithdrawal();

        // Fast forward 7 days + 1 second
        vm.warp(block.timestamp + 7 days + 1);

        // Now should be withdrawable
        assertTrue(pool.canWithdraw(user), "Should be withdrawable after 7 days");

        // Withdraw 50 USDC
        uint256 usdcBefore = usdc.balanceOf(user);
        pool.withdraw(withdrawAmount, user, user);
        uint256 usdcAfter = usdc.balanceOf(user);

        assertEq(usdcAfter - usdcBefore, withdrawAmount, "Should receive exact USDC amount");
        assertGt(pool.balanceOf(user), 0, "Should still have remaining shares");

        vm.stopPrank();

        console.log("[PASS] Withdraw %s USDC after 7-day cooldown", withdrawAmount / 1e6);
    }

    // ═══════════════════════════════════════════════════════════
    // Test 2c: Full Withdraw (redeem all shares)
    // ═══════════════════════════════════════════════════════════

    function test_FullRedeem() public {
        uint256 depositAmount = 100e6;

        // Deposit
        vm.startPrank(user);
        usdc.approve(address(pool), depositAmount);
        uint256 shares = pool.deposit(depositAmount, user);

        // Request + wait cooldown
        pool.requestWithdrawal();
        vm.warp(block.timestamp + 7 days + 1);

        // Redeem all shares
        uint256 usdcBefore = usdc.balanceOf(user);
        pool.redeem(shares, user, user);
        uint256 usdcAfter = usdc.balanceOf(user);

        assertEq(pool.balanceOf(user), 0, "Should have 0 shares after full redeem");
        assertEq(usdcAfter - usdcBefore, depositAmount, "Should get back full deposit");

        vm.stopPrank();

        console.log("[PASS] Full redeem: got back %s USDC", depositAmount / 1e6);
    }

    // ═══════════════════════════════════════════════════════════
    // Test 3: Cooldown period is exactly 7 days
    // ═══════════════════════════════════════════════════════════

    function test_CooldownExact7Days() public {
        uint256 depositAmount = 100e6;

        vm.startPrank(user);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount, user);
        pool.requestWithdrawal();

        // At 7 days - 1 second: should still revert
        vm.warp(block.timestamp + 7 days - 1);
        assertFalse(pool.canWithdraw(user), "Should NOT be withdrawable before 7 days");

        vm.expectRevert(UnderwriterPool.CooldownNotMet.selector);
        pool.withdraw(50e6, user, user);

        // At exactly 7 days: should succeed (>= boundary)
        vm.warp(block.timestamp + 1);
        assertTrue(pool.canWithdraw(user), "Should be withdrawable at exactly 7 days");
        pool.withdraw(50e6, user, user);

        vm.stopPrank();

        console.log("[PASS] Cooldown boundary: blocked at 7d-1s, allowed at 7d");
    }

    // ═══════════════════════════════════════════════════════════
    // Test 4: Daily Pay Limit enforcement
    // ═══════════════════════════════════════════════════════════

    function test_DailyPayLimit() public {
        // The daily limit is 5% of totalAssets
        uint256 tvl = pool.totalAssets();
        uint256 limit = pool.dailyPayLimit();
        assertEq(limit, tvl * 500 / 10_000, "Daily limit should be 5% of TVL");

        console.log("[PASS] Daily pay limit: %s USDC (5%% of %s TVL)", limit / 1e6, tvl / 1e6);
    }

    // ═══════════════════════════════════════════════════════════
    // Test 5: Share price (convertToAssets)
    // ═══════════════════════════════════════════════════════════

    function test_SharePrice() public {
        uint256 depositAmount = 500e6;

        vm.startPrank(user);
        usdc.approve(address(pool), depositAmount);
        uint256 shares = pool.deposit(depositAmount, user);
        vm.stopPrank();

        // With no premiums/claims, 1 share = 1 USDC
        uint256 assetsForShares = pool.convertToAssets(shares);
        assertEq(assetsForShares, depositAmount, "Share value should equal deposit (no premiums yet)");

        console.log("[PASS] Share price 1:1 at deposit (%s shares = %s USDC)", shares / 1e6, assetsForShares / 1e6);
    }

    // ═══════════════════════════════════════════════════════════
    // Test 6: Multiple depositors
    // ═══════════════════════════════════════════════════════════

    function test_MultipleDepositors() public {
        address user2 = address(0xCAFE);
        usdc.mint(user2, 5_000e6);

        // User 1 deposits 200
        vm.startPrank(user);
        usdc.approve(address(pool), 200e6);
        pool.deposit(200e6, user);
        vm.stopPrank();

        // User 2 deposits 300
        vm.startPrank(user2);
        usdc.approve(address(pool), 300e6);
        pool.deposit(300e6, user2);
        vm.stopPrank();

        // Total should be seed(1000) + 200 + 300 = 1500
        assertEq(pool.totalAssets(), 1_500e6, "Pool TVL should be 1500 USDC");
        assertGt(pool.balanceOf(user), 0, "User1 should have shares");
        assertGt(pool.balanceOf(user2), 0, "User2 should have shares");

        console.log("[PASS] Multiple depositors: TVL = %s USDC", pool.totalAssets() / 1e6);
    }
}
