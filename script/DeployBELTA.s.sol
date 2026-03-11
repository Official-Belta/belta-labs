// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "@v4-core/libraries/Hooks.sol";
import {IHooks} from "@v4-core/interfaces/IHooks.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {Currency} from "@v4-core/types/Currency.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {BELTAHook} from "../src/BELTAHook.sol";
import {UnderwriterPool} from "../src/UnderwriterPool.sol";
import {EpochSettlement} from "../src/EpochSettlement.sol";
import {PremiumOracle} from "../src/PremiumOracle.sol";
import {TreasuryModule} from "../src/TreasuryModule.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title DeployBELTA
/// @notice Deployment script for BELTA Labs protocol
/// @dev Deploys all contracts and wires them together.
///      Uses CREATE2 salt mining for hook address flag matching.
///
/// Usage:
///   # Unichain Sepolia
///   forge script script/DeployBELTA.s.sol:DeployBELTA \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC \
///     --broadcast --verify -vvvv
///
///   # Sepolia
///   forge script script/DeployBELTA.s.sol:DeployBELTA \
///     --rpc-url $SEPOLIA_RPC \
///     --broadcast --verify -vvvv
contract DeployBELTA is Script {
    // ─── Known PoolManager Addresses ─────────────────────────
    // Uniswap V4 PoolManager (공식 배포 주소)
    address constant POOL_MANAGER_SEPOLIA = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant POOL_MANAGER_UNICHAIN_SEPOLIA = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant POOL_MANAGER_ETHEREUM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POOL_MANAGER_UNICHAIN = 0x1F98400000000000000000000000000000000004;

    // ─── Hook Permission Flags ───────────────────────────────
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    function run() external {
        // ─── Load env vars ───────────────────────────────────
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address underlyingAsset = vm.envAddress("UNDERLYING_ASSET");

        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);
        console.log("PoolManager:", poolManagerAddr);
        console.log("Underlying Asset:", underlyingAsset);

        vm.startBroadcast(deployerPrivateKey);

        IPoolManager poolManager = IPoolManager(poolManagerAddr);
        ERC20 asset = ERC20(underlyingAsset);

        // ─── Step 1: Deploy PremiumOracle ─────────────────────
        PremiumOracle oracle = new PremiumOracle();
        console.log("[1/5] PremiumOracle:", address(oracle));

        // ─── Step 2: Deploy BELTAHook via CREATE2 ─────────────
        // Salt mining: 주소 하위 비트가 퍼미션 플래그와 일치해야 함
        bytes memory creationCode = type(BELTAHook).creationCode;
        bytes memory constructorArgs = abi.encode(poolManager);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(deployer, HOOK_FLAGS, creationCode, constructorArgs);
        console.log("[2/5] BELTAHook target address:", hookAddress);

        BELTAHook hook = new BELTAHook{salt: salt}(poolManager);
        require(address(hook) == hookAddress, "Hook address mismatch after CREATE2");
        console.log("[2/5] BELTAHook deployed:", address(hook));

        // Verify hook address flags
        require(
            uint160(address(hook)) & uint160(0x3FFF) == HOOK_FLAGS & uint160(0x3FFF),
            "Hook address flags mismatch!"
        );

        // ─── Step 3: Deploy UnderwriterPool ───────────────────
        UnderwriterPool pool = new UnderwriterPool(asset, address(hook));
        console.log("[3/5] UnderwriterPool:", address(pool));

        // ─── Step 4: Deploy TreasuryModule ────────────────────
        TreasuryModule treasury = new TreasuryModule(asset);
        console.log("[4/5] TreasuryModule:", address(treasury));

        // ─── Step 5: Deploy EpochSettlement ───────────────────
        EpochSettlement settlement = new EpochSettlement(address(hook), address(pool));
        console.log("[5/5] EpochSettlement:", address(settlement));

        // ─── Step 6: Wire contracts ───────────────────────────
        _wireContracts(hook, pool, treasury, settlement, oracle);

        // ─── Summary ──────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log("  BELTA Protocol Deployed Successfully");
        console.log("========================================");
        console.log("Hook:       ", address(hook));
        console.log("Pool:       ", address(pool));
        console.log("Treasury:   ", address(treasury));
        console.log("Oracle:     ", address(oracle));
        console.log("Settlement: ", address(settlement));
        console.log("========================================");
        console.log("");
        console.log("Next steps:");
        console.log("  1. USDC approve -> treasury.seedBuffer(amount)");
        console.log("  2. USDC approve -> pool.deposit(amount, deployer)");
        console.log("  3. initPool() via PoolManager");
        console.log("  4. pool.syncCapacity(poolId)");
        console.log("  5. settlement.setKeeper(keeperAddr)");

        vm.stopBroadcast();
    }

    function _wireContracts(
        BELTAHook hook,
        UnderwriterPool pool,
        TreasuryModule treasury,
        EpochSettlement settlement,
        PremiumOracle oracle
    ) internal {
        // Hook -> 외부 컨트랙트 연결
        hook.setUnderwriterPool(address(pool));
        hook.setPremiumOracle(address(oracle));
        hook.setEpochSettlement(address(settlement));

        // Pool -> Treasury, Settlement 연결
        pool.setTreasuryModule(address(treasury));
        pool.setEpochSettlement(address(settlement));

        // Treasury -> Pool, 권한 설정
        treasury.setUnderwriterPool(address(pool));
        treasury.setAuthorized(address(pool), true);
        treasury.setAuthorized(address(settlement), true);

        // Settlement -> Treasury 연결
        settlement.setTreasury(address(treasury));

        console.log("[Wiring] All contracts connected");
    }
}
