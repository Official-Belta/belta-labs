// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "@v4-core/libraries/Hooks.sol";
import {IHooks} from "@v4-core/interfaces/IHooks.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {Currency} from "@v4-core/types/Currency.sol";
import {TickMath} from "@v4-core/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BELTAHook} from "../src/BELTAHook.sol";
import {UnderwriterPool} from "../src/UnderwriterPool.sol";

/// @title InitPool
/// @notice Sepolia 테스트넷에 Uniswap V4 풀을 초기화하는 스크립트
/// @dev 이미 배포된 컨트랙트 주소를 사용하여 Mock WETH 배포 + 풀 초기화 + 용량 동기화
///
/// Usage:
///   source .env && forge script script/InitPool.s.sol:InitPool \
///     --rpc-url $SEPOLIA_RPC_URL \
///     --broadcast -vvvv
contract InitPool is Script {
    using PoolIdLibrary for PoolKey;

    // ─── 배포된 컨트랙트 주소 (최신 배포 기준) ─────────────
    address constant MOCK_USDC = 0xCc5edffA546f6B8863247b4cEAbFcdDecD6a954E;
    address constant BELTA_HOOK = 0xB54135f42212eB13c709C74F3F3EE5C4D53F5540;
    address constant UNDERWRITER_POOL = 0x9d3DEf5a86E01C2E21DFc53A62cfa40A200d3A97;

    // ─── 풀 파라미터 ───────────────────────────────────────
    uint24 constant POOL_FEE = 3000;       // 0.3% 수수료
    int24 constant TICK_SPACING = 60;       // 0.3% 풀 기본 틱 간격

    // ETH ~$2000 기준 초기 가격 틱
    // USDC(6 dec)가 token0, WETH(18 dec)가 token1일 때:
    //   price = token1_per_token0 (raw) = (1e6 / 2000) / 1e18 = 5e-16
    //   tick = log(5e-16) / log(1.0001) ≈ -202,200
    //   tickSpacing=60에 정렬 → -202,200
    // WETH가 token0이면 반대로 양수 틱 사용
    int24 constant INITIAL_TICK_USDC_IS_TOKEN0 = -202200;
    int24 constant INITIAL_TICK_WETH_IS_TOKEN0 = 202200;

    // Mock WETH 민팅 수량
    uint256 constant WETH_MINT_AMOUNT = 100 ether;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== BELTA Pool Initialization ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("PoolManager:", poolManagerAddr);

        vm.startBroadcast(deployerPrivateKey);

        IPoolManager poolManager = IPoolManager(poolManagerAddr);

        // ─── 1. Mock WETH 배포 ──────────────────────────────
        MockERC20 weth = new MockERC20("Test WETH", "tWETH", 18);
        weth.mint(deployer, WETH_MINT_AMOUNT);
        console.log("[1] Mock WETH deployed:", address(weth));
        console.log("    Minted:", WETH_MINT_AMOUNT / 1e18, "tWETH to deployer");

        // ─── 2. PoolKey 구성 (주소 정렬) ────────────────────
        // currency0은 항상 낮은 주소여야 함
        Currency currency0;
        Currency currency1;
        int24 initialTick;

        if (address(MOCK_USDC) < address(weth)) {
            // USDC가 token0, WETH가 token1
            currency0 = Currency.wrap(MOCK_USDC);
            currency1 = Currency.wrap(address(weth));
            initialTick = INITIAL_TICK_USDC_IS_TOKEN0;
            console.log("[2] Token ordering: USDC(token0) / WETH(token1)");
        } else {
            // WETH가 token0, USDC가 token1
            currency0 = Currency.wrap(address(weth));
            currency1 = Currency.wrap(MOCK_USDC);
            initialTick = INITIAL_TICK_WETH_IS_TOKEN0;
            console.log("[2] Token ordering: WETH(token0) / USDC(token1)");
        }

        // tickSpacing에 정렬 (내림)
        initialTick = (initialTick / TICK_SPACING) * TICK_SPACING;

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(BELTA_HOOK)
        });

        PoolId poolId = key.toId();
        console.log("[2] PoolKey constructed");
        console.log("    Fee:", POOL_FEE);
        console.log("    TickSpacing:", uint24(TICK_SPACING));

        // ─── 3. sqrtPriceX96 계산 및 풀 초기화 ──────────────
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(initialTick);
        console.log("[3] Initial tick:", uint256(uint24(initialTick)));
        console.log("    sqrtPriceX96:", uint256(sqrtPriceX96));

        int24 tick = poolManager.initialize(key, sqrtPriceX96);
        console.log("[3] Pool initialized at tick:", uint256(uint24(tick)));

        // ─── 4. UnderwriterPool 용량 동기화 ─────────────────
        UnderwriterPool pool = UnderwriterPool(UNDERWRITER_POOL);
        pool.syncCapacity(poolId);
        console.log("[4] Capacity synced to UnderwriterPool");

        // ─── Summary ────────────────────────────────────────
        console.log("");
        console.log("============================================");
        console.log("  BELTA Pool Initialization Complete!");
        console.log("============================================");
        console.log("  Mock WETH:       ", address(weth));
        console.log("  Mock USDC:       ", MOCK_USDC);
        console.log("  BELTAHook:       ", BELTA_HOOK);
        console.log("  UnderwriterPool: ", UNDERWRITER_POOL);
        console.log("  PoolManager:     ", poolManagerAddr);
        console.log("  Pool Fee:         0.3%");
        console.log("  Initial Price:    ~$2000 ETH/USDC");
        console.log("============================================");

        vm.stopBroadcast();
    }
}
