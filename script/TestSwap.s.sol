// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "@v4-core/interfaces/IHooks.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {Currency} from "@v4-core/types/Currency.sol";
import {BalanceDelta} from "@v4-core/types/BalanceDelta.sol";
import {SwapParams} from "@v4-core/types/PoolOperation.sol";
import {TickMath} from "@v4-core/libraries/TickMath.sol";
import {StateLibrary} from "@v4-core/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "@v4-core/test/PoolSwapTest.sol";

/// @title TestSwap
/// @notice Sepolia 풀에서 테스트 스왑 실행 → Hook afterSwap 트리거
///
/// Usage:
///   source .env && forge script script/TestSwap.s.sol:TestSwap \
///     --rpc-url $SEPOLIA_RPC_URL \
///     --broadcast -vvvv
contract TestSwap is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── Deployed contract addresses ─────────────────────────
    address constant MOCK_USDC = 0x3A6262e69a845D93F4b518d28BbA3abb456618d6;
    address constant MOCK_WETH = 0x4ABD7D9b2D8EAb6c158F84C7b786CF82e7Aff8f2;
    address constant BELTA_HOOK = 0x1609e47BE1504F29Ed6DBb5dcdF57dEea9405540;

    // ─── Pool parameters ─────────────────────────────────────
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    // ─── Swap parameters ─────────────────────────────────────
    uint256 constant SWAP_AMOUNT_USDC = 100e6;  // Swap 100 USDC → WETH
    uint256 constant SWAP_AMOUNT_WETH = 0.05 ether;  // Swap 0.05 WETH → USDC

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== BELTA Test Swaps ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        IPoolManager poolManager = IPoolManager(poolManagerAddr);
        MockERC20 usdc = MockERC20(MOCK_USDC);
        MockERC20 weth = MockERC20(MOCK_WETH);

        // ─── 1. Deploy PoolSwapTest router ───────────────────
        PoolSwapTest swapRouter = new PoolSwapTest(poolManager);
        console.log("[1] SwapRouter deployed:", address(swapRouter));

        // ─── 2. Mint tokens for swaps ────────────────────────
        usdc.mint(deployer, 1000e6);     // 1k USDC for swaps
        weth.mint(deployer, 1 ether);    // 1 WETH for swaps
        console.log("[2] Minted swap tokens");

        // ─── 3. Approve tokens to swap router ────────────────
        usdc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        console.log("[3] Tokens approved");

        // ─── 4. Construct PoolKey ────────────────────────────
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(MOCK_USDC),
            currency1: Currency.wrap(MOCK_WETH),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(BELTA_HOOK)
        });

        PoolId poolId = key.toId();

        // Check pool state before swaps
        (uint160 sqrtPriceBefore, int24 tickBefore,,) = poolManager.getSlot0(poolId);
        console.log("[4] Before swaps - tick:", uint256(uint24(tickBefore)));

        // ─── 5. Swap #1: USDC → WETH (zeroForOne = true) ────
        // amountSpecified < 0 means exact input
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        SwapParams memory params1 = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(SWAP_AMOUNT_USDC),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        BalanceDelta delta1 = swapRouter.swap(key, params1, settings, "");
        console.log("[5] Swap #1: 100 USDC -> WETH done");

        // Check tick after swap 1
        (, int24 tickAfter1,,) = poolManager.getSlot0(poolId);
        console.log("    Tick after:", uint256(uint24(tickAfter1)));

        // ─── 6. Swap #2: WETH → USDC (zeroForOne = false) ───
        SwapParams memory params2 = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(SWAP_AMOUNT_WETH),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta2 = swapRouter.swap(key, params2, settings, "");
        console.log("[6] Swap #2: 0.05 WETH -> USDC done");

        (, int24 tickAfter2,,) = poolManager.getSlot0(poolId);
        console.log("    Tick after:", uint256(uint24(tickAfter2)));

        // ─── Summary ────────────────────────────────────────
        console.log("");
        console.log("============================================");
        console.log("  Test Swaps Complete!");
        console.log("============================================");
        console.log("  SwapRouter:  ", address(swapRouter));
        console.log("  Swap 1: 100 USDC -> WETH (price down)");
        console.log("  Swap 2: 0.05 WETH -> USDC (price up)");
        console.log("  Hook afterSwap triggered on each swap");
        console.log("============================================");

        vm.stopBroadcast();
    }
}
