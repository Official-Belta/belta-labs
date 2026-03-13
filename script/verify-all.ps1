## BELTA Labs - Etherscan Sepolia Verify All Contracts
## Usage: cd C:\Users\dusti\Desktop\belta-labs && powershell -ExecutionPolicy Bypass -File script\verify-all.ps1

Set-Location "C:\Users\dusti\Desktop\belta-labs"

$FORGE = "$env:USERPROFILE\.foundry\bin\forge.exe"
$CAST = "$env:USERPROFILE\.foundry\bin\cast.exe"
$ETHERSCAN_KEY = "9Z8X1SBH25FYZ2JVTDUDSI5EFGCBTZI119"
$CHAIN_ID = "11155111"

# Contract addresses
$MOCK_USDC = "0xa64b084d47657a799885aac2dc861a7c432b6d12"
$BELTA_HOOK = "0x07f4f427378ef485931999ace2917a210f0b9540"
$UNDERWRITER_POOL = "0x67b0e434be06fc63224ee0d0b2e4b08ebd9b1622"
$TREASURY_MODULE = "0xc84b9df70cbdf35945b2230f0f9e1d09ee35850e"
$PREMIUM_ORACLE = "0x3fdf2ac8b75aa5043763c9615e20eca88d2a801f"
$EPOCH_SETTLEMENT = "0x064f6ada17f51575b11c538ed5c5b6a6d7f0ec30"
$POOL_MANAGER = "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543"

Write-Host "============================================"
Write-Host "  BELTA Labs - Etherscan Verify"
Write-Host "============================================"

# 1. PremiumOracle (no constructor args)
Write-Host "`n[1/6] PremiumOracle..."
& $FORGE verify-contract $PREMIUM_ORACLE src/PremiumOracle.sol:PremiumOracle --chain-id $CHAIN_ID --etherscan-api-key $ETHERSCAN_KEY --compiler-version "0.8.26" --watch

# 2. TreasuryModule (constructor: address asset)
$args2 = & $CAST abi-encode "constructor(address)" $MOCK_USDC
Write-Host "`n[2/6] TreasuryModule..."
& $FORGE verify-contract $TREASURY_MODULE src/TreasuryModule.sol:TreasuryModule --chain-id $CHAIN_ID --etherscan-api-key $ETHERSCAN_KEY --compiler-version "0.8.26" --constructor-args $args2 --watch

# 3. UnderwriterPool (constructor: address asset, address hook)
$args3 = & $CAST abi-encode "constructor(address,address)" $MOCK_USDC $BELTA_HOOK
Write-Host "`n[3/6] UnderwriterPool..."
& $FORGE verify-contract $UNDERWRITER_POOL src/UnderwriterPool.sol:UnderwriterPool --chain-id $CHAIN_ID --etherscan-api-key $ETHERSCAN_KEY --compiler-version "0.8.26" --constructor-args $args3 --watch

# 4. BELTAHook (constructor: address poolManager)
$args4 = & $CAST abi-encode "constructor(address)" $POOL_MANAGER
Write-Host "`n[4/6] BELTAHook..."
& $FORGE verify-contract $BELTA_HOOK src/BELTAHook.sol:BELTAHook --chain-id $CHAIN_ID --etherscan-api-key $ETHERSCAN_KEY --compiler-version "0.8.26" --constructor-args $args4 --watch

# 5. EpochSettlement (constructor: address hook, address pool)
$args5 = & $CAST abi-encode "constructor(address,address)" $BELTA_HOOK $UNDERWRITER_POOL
Write-Host "`n[5/6] EpochSettlement..."
& $FORGE verify-contract $EPOCH_SETTLEMENT src/EpochSettlement.sol:EpochSettlement --chain-id $CHAIN_ID --etherscan-api-key $ETHERSCAN_KEY --compiler-version "0.8.26" --constructor-args $args5 --watch

# 6. MockUSDC
$args6 = & $CAST abi-encode "constructor(string,string,uint8)" "BELTA Test USDC" "tUSDC" 6
Write-Host "`n[6/6] MockUSDC..."
& $FORGE verify-contract $MOCK_USDC lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20 --chain-id $CHAIN_ID --etherscan-api-key $ETHERSCAN_KEY --compiler-version "0.8.26" --constructor-args $args6 --watch

Write-Host "`n============================================"
Write-Host "  Done! Check Sepolia Etherscan"
Write-Host "============================================"
