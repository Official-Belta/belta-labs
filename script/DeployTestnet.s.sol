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
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BELTAHook} from "../src/BELTAHook.sol";
import {UnderwriterPool} from "../src/UnderwriterPool.sol";
import {EpochSettlement} from "../src/EpochSettlement.sol";
import {PremiumOracle} from "../src/PremiumOracle.sol";
import {TreasuryModule} from "../src/TreasuryModule.sol";
import {VolatilityOracle} from "../src/VolatilityOracle.sol";
import {HedgeManager} from "../src/HedgeManager.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title DeployTestnet
/// @notice 테스트넷 전용 배포 — Mock 토큰 포함 풀 셋업까지 원스텝
/// @dev Sepolia 또는 Unichain Sepolia에서 사용
///
/// Usage:
///   source .env && forge script script/DeployTestnet.s.sol:DeployTestnet \
///     --rpc-url $SEPOLIA_RPC_URL \
///     --broadcast -vvvv
contract DeployTestnet is Script {
    using PoolIdLibrary for PoolKey;

    // Deterministic CREATE2 deployer (available on all EVM chains)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Hook 퍼미션 플래그 (Layer 1: beforeSwap 추가 for dynamic fee)
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG
    );

    // 테스트넷 시드 금액
    uint256 constant POOL_SEED = 10_000e6;     // $10k USDC
    uint256 constant TREASURY_SEED = 2_000e6;  // $2k buffer

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== BELTA Testnet Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        IPoolManager poolManager = IPoolManager(poolManagerAddr);

        // ─── 1. Deploy Mock USDC ──────────────────────────────
        MockERC20 usdc = new MockERC20("BELTA Test USDC", "tUSDC", 6);
        usdc.mint(deployer, 1_000_000e6); // 1M tUSDC
        console.log("[1] Mock USDC:", address(usdc));

        // ─── 2. Deploy PremiumOracle ──────────────────────────
        PremiumOracle oracle = new PremiumOracle();
        console.log("[2] PremiumOracle:", address(oracle));

        // ─── 3. Deploy BELTAHook (CREATE2 via deterministic deployer) ─
        bytes memory creationCode = type(BELTAHook).creationCode;
        bytes memory constructorArgs = abi.encode(poolManager);

        // Mine salt using the deterministic CREATE2 deployer address
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, creationCode, constructorArgs);

        // Deploy via deterministic CREATE2 deployer
        bytes memory initcode = abi.encodePacked(creationCode, constructorArgs);
        (bool success,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initcode));
        require(success, "CREATE2 deploy failed");

        BELTAHook hook = BELTAHook(hookAddr);
        // Verify the hook was deployed correctly
        require(hookAddr.code.length > 0, "Hook not deployed");
        console.log("[3] BELTAHook:", hookAddr);
        console.log("    Salt:", vm.toString(salt));

        // ─── 4. Deploy UnderwriterPool ────────────────────────
        UnderwriterPool pool = new UnderwriterPool(ERC20(address(usdc)), address(hook));
        console.log("[4] UnderwriterPool:", address(pool));

        // ─── 5. Deploy TreasuryModule ─────────────────────────
        TreasuryModule treasury = new TreasuryModule(ERC20(address(usdc)));
        console.log("[5] TreasuryModule:", address(treasury));

        // ─── 6. Deploy EpochSettlement ────────────────────────
        EpochSettlement settlement = new EpochSettlement(address(hook), address(pool));
        console.log("[6] EpochSettlement:", address(settlement));

        // ─── 7. Deploy VolatilityOracle (Layer 1: Dynamic Fee) ─
        VolatilityOracle volOracle = new VolatilityOracle();
        console.log("[7] VolatilityOracle:", address(volOracle));

        // ─── 8. Deploy HedgeManager (Layer 3: Perps Hedging) ─
        HedgeManager hedger = new HedgeManager(ERC20(address(usdc)));
        console.log("[8] HedgeManager:", address(hedger));

        // ─── 9. Wire contracts ────────────────────────────────
        hook.setUnderwriterPool(address(pool));
        hook.setPremiumOracle(address(oracle));
        hook.setVolatilityOracle(address(volOracle));
        hook.setEpochSettlement(address(settlement));

        pool.setTreasuryModule(address(treasury));
        pool.setEpochSettlement(address(settlement));

        treasury.setUnderwriterPool(address(pool));
        treasury.setAuthorized(address(pool), true);
        treasury.setAuthorized(address(settlement), true);

        hedger.setUnderwriterPool(address(pool));

        settlement.setTreasury(address(treasury));
        console.log("[9] Wiring complete");

        // ─── 10. Seed pool & treasury ─────────────────────────
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(POOL_SEED, deployer);
        console.log("[10] Pool seeded:", POOL_SEED / 1e6, "tUSDC");

        usdc.approve(address(treasury), type(uint256).max);
        treasury.seedBuffer(TREASURY_SEED);
        console.log("[10] Treasury seeded:", TREASURY_SEED / 1e6, "tUSDC");

        // ─── Summary ──────────────────────────────────────────
        console.log("");
        console.log("============================================");
        console.log("  BELTA Testnet Deployment Complete!");
        console.log("============================================");
        console.log("  Mock USDC:     ", address(usdc));
        console.log("  BELTAHook:     ", address(hook));
        console.log("  UnderwriterPool:", address(pool));
        console.log("  TreasuryModule: ", address(treasury));
        console.log("  PremiumOracle:  ", address(oracle));
        console.log("  EpochSettlement:", address(settlement));
        console.log("  VolatilityOracle:", address(volOracle));
        console.log("  HedgeManager:   ", address(hedger));
        console.log("============================================");
        console.log("");
        console.log("  Next: initPool() via PoolManager or front-end");
        console.log("  Hook address verified: flags match");

        vm.stopBroadcast();
    }
}
