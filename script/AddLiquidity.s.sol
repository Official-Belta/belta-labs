// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "@v4-core/interfaces/IHooks.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {Currency} from "@v4-core/types/Currency.sol";
import {BalanceDelta} from "@v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@v4-core/types/PoolOperation.sol";
import {TickMath} from "@v4-core/libraries/TickMath.sol";
import {StateLibrary} from "@v4-core/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolModifyLiquidityTest} from "@v4-core/test/PoolModifyLiquidityTest.sol";

/// @title AddLiquidity
/// @notice Sepolia 풀에 유동성 추가 + BELTA IL 헤지 등록
///
/// Usage:
///   source .env && forge script script/AddLiquidity.s.sol:AddLiquidity \
///     --rpc-url $SEPOLIA_RPC_URL \
///     --broadcast -vvvv
contract AddLiquidity is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── Deployed contract addresses ─────────────────────────
    address constant MOCK_USDC = 0x3A6262e69a845D93F4b518d28BbA3abb456618d6;
    address constant MOCK_WETH = 0x4ABD7D9b2D8EAb6c158F84C7b786CF82e7Aff8f2;
    address constant BELTA_HOOK = 0x1609e47BE1504F29Ed6DBb5dcdF57dEea9405540;

    // ─── Pool parameters ─────────────────────────────────────
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    // ─── LP parameters ───────────────────────────────────────
    // Current price tick ≈ -202200 (~$2000 ETH/USDC)
    // Range: ±3000 ticks ≈ $1500 ~ $2700
    int24 constant TICK_LOWER = -205200;
    int24 constant TICK_UPPER = -199200;
    int256 constant LIQUIDITY_DELTA = 1e8; // moderate liquidity (USDC 6 dec needs small values)

    // Mint amounts for LP
    uint256 constant USDC_MINT = 50_000e6;    // 50k USDC
    uint256 constant WETH_MINT = 25 ether;    // 25 WETH

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== BELTA Add Liquidity ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        IPoolManager poolManager = IPoolManager(poolManagerAddr);
        MockERC20 usdc = MockERC20(MOCK_USDC);
        MockERC20 weth = MockERC20(MOCK_WETH);

        // ─── 1. Deploy PoolModifyLiquidityTest router ────────
        PoolModifyLiquidityTest router = new PoolModifyLiquidityTest(poolManager);
        console.log("[1] Router deployed:", address(router));

        // ─── 2. Mint tokens ──────────────────────────────────
        usdc.mint(deployer, USDC_MINT);
        weth.mint(deployer, WETH_MINT);
        console.log("[2] Minted 50k tUSDC + 25 tWETH");

        // ─── 3. Approve tokens to router ─────────────────────
        usdc.approve(address(router), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        console.log("[3] Tokens approved to router");

        // ─── 4. Construct PoolKey ────────────────────────────
        // USDC < WETH by address, so USDC = currency0
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(MOCK_USDC),
            currency1: Currency.wrap(MOCK_WETH),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(BELTA_HOOK)
        });

        PoolId poolId = key.toId();

        // Verify pool exists
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);
        console.log("[4] Pool current tick:", uint256(uint24(currentTick)));
        console.log("    sqrtPriceX96:", uint256(sqrtPriceX96));

        // ─── 5. Add liquidity with BELTA opt-in ─────────────
        // hookData = 0x01 means opt-in to BELTA IL hedging
        bytes memory hookData = abi.encodePacked(bytes1(0x01));

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: LIQUIDITY_DELTA,
            salt: bytes32(0)
        });

        BalanceDelta delta = router.modifyLiquidity(key, params, hookData);

        console.log("[5] Liquidity added!");
        console.log("    tickLower:", uint256(uint24(TICK_LOWER)));
        console.log("    tickUpper:", uint256(uint24(TICK_UPPER)));
        console.log("    liquidityDelta:", uint256(LIQUIDITY_DELTA));

        // ─── Summary ────────────────────────────────────────
        console.log("");
        console.log("============================================");
        console.log("  Liquidity Added Successfully!");
        console.log("============================================");
        console.log("  Router:    ", address(router));
        console.log("  BELTA Opt-In: YES (hookData=0x01)");
        console.log("  Range:      ~$1500 - ~$2700 ETH/USDC");
        console.log("============================================");

        vm.stopBroadcast();
    }
}
