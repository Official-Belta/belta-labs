// BELTA Labs — Contract ABIs (extracted from Solidity source)
// Chain: Sepolia (11155111)

const ADDRESSES = {
  MOCK_USDC:        "0xCc5edffA546f6B8863247b4cEAbFcdDecD6a954E",
  BELTA_HOOK:       "0xB54135f42212eB13c709C74F3F3EE5C4D53F5540",
  UNDERWRITER_POOL: "0x9d3DEf5a86E01C2E21DFc53A62cfa40A200d3A97",
  TREASURY_MODULE:  "0x8b0969742959C73136b6556d558Bf1e4fc97A090",
  PREMIUM_ORACLE:   "0xb813d50b990AAbDbD659a518577BA123fb9FF0a8",
  EPOCH_SETTLEMENT: "0xbC87a063377d479e344C9Ad475D2208446D235F8",
};

const CHAIN_ID = 11155111;

// V4 Pool Info (from InitPool deployment)
const POOL_INFO = {
  MOCK_WETH: "0x341009d75D39dB7bb69A9f08a41ce62b2226b7C7",
  POOL_ID: "0xb0ca1bceffce792788cb0b0b4a9cefce0e9b654331281be6b7770e1f3f4c7850",
  FEE: 3000,
  TICK_SPACING: 60,
  INITIAL_TICK: 202200,
  INITIAL_PRICE: "~$2000 ETH/USDC",
  // Token ordering: WETH(token0) / USDC(token1) — WETH has lower address
};

// ERC20 (MockUSDC)
const ERC20_ABI = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function transfer(address to, uint256 amount) returns (bool)",
];

// UnderwriterPool (ERC4626)
const UNDERWRITER_POOL_ABI = [
  // ERC4626
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function asset() view returns (address)",
  "function deposit(uint256 assets, address receiver) returns (uint256 shares)",
  "function withdraw(uint256 assets, address receiver, address owner) returns (uint256 shares)",
  "function redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
  "function convertToShares(uint256 assets) view returns (uint256)",
  "function maxDeposit(address) view returns (uint256)",
  "function maxWithdraw(address owner) view returns (uint256)",
  "function previewDeposit(uint256 assets) view returns (uint256)",
  "function previewWithdraw(uint256 assets) view returns (uint256)",
  "function previewRedeem(uint256 shares) view returns (uint256)",
  // Custom
  "function requestWithdrawal()",
  "function canWithdraw(address user) view returns (bool)",
  "function withdrawalRequestTime(address) view returns (uint256)",
  "function totalPremiumsEarned() view returns (uint256)",
  "function totalClaimsPaid() view returns (uint256)",
  "function netPremiumIncome() view returns (uint256)",
  "function currentDailyPayout() view returns (uint256)",
  "function dailyPayLimit() view returns (uint256)",
  "function COOLDOWN_PERIOD() view returns (uint256)",
  "function DAILY_PAY_LIMIT_BPS() view returns (uint256)",
  "function CAP_MULT() view returns (uint256)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  // Events
  "event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares)",
  "event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)",
  "event PremiumReceived(uint256 amount)",
  "event ILClaimPaid(address indexed lp, uint256 amount, uint256 fromTreasury, uint256 fromPool)",
  "event WithdrawalRequested(address indexed user, uint256 timestamp)",
];

// TreasuryModule
const TREASURY_MODULE_ABI = [
  "function bufferBalance() view returns (uint256)",
  "function initialBuffer() view returns (uint256)",
  "function bufferHealthBps() view returns (uint256)",
  "function needsSelfHealing() view returns (bool)",
  "function getTargetBufferSize() view returns (uint256)",
  "function seniorBalance() view returns (uint256)",
  "function dualPoolEnabled() view returns (bool)",
  "function BUFFER_RATIO_BPS() view returns (uint256)",
  "function MIN_BUFFER_RATIO_BPS() view returns (uint256)",
  "function BPS() view returns (uint256)",
];

// BELTAHook
const BELTA_HOOK_ABI = [
  "function COVERAGE_CAP_BPS() view returns (uint256)",
  "function EPOCH_DURATION() view returns (uint256)",
  "function BPS() view returns (uint256)",
  "function DAILY_PAY_LIMIT_BPS() view returns (uint256)",
  "function totalHedgedValue(bytes32 poolId) view returns (uint256)",
  "function poolCapacity(bytes32 poolId) view returns (uint256)",
  "function accumulatedPremiums(bytes32 poolId) view returns (uint256)",
  "function pendingILClaims(bytes32 poolId) view returns (uint256)",
  "function getCurrentEpoch(bytes32 poolId) view returns (uint256)",
  "function getUtilization(bytes32 poolId) view returns (uint256)",
  "function getCurrentPremiumRate(bytes32 poolId) view returns (uint256)",
  "function getPosition(bytes32 poolId, address lp, int24 tickLower, int24 tickUpper) view returns (tuple(uint160 sqrtPriceAtEntry, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 epochStart, uint256 premiumOwed, uint256 ilClaimable, bool active))",
  "function getClaimable(bytes32 poolId, address lp, int24 tickLower, int24 tickUpper) view returns (uint256)",
  "function claimILPayout(bytes32 poolId, int24 tickLower, int24 tickUpper)",
  "function epochs(bytes32 poolId) view returns (uint256 epochNumber, uint256 startTimestamp, uint160 sqrtPriceAtEpochStart)",
];

// PremiumOracle
const PREMIUM_ORACLE_ABI = [
  "function baseRate() view returns (uint256)",
  "function kink() view returns (uint256)",
  "function maxMultiplier() view returns (uint256)",
  "function getPremiumRate(uint256 utilization) view returns (uint256 rate)",
];

// EpochSettlement
const EPOCH_SETTLEMENT_ABI = [
  "function lastSettledEpoch(bytes32 poolId) view returns (uint256)",
  "function getSettlement(bytes32 poolId, uint256 epoch) view returns (tuple(uint256 epoch, uint256 timestamp, uint256 premiumsCollected, uint256 pendingClaims, bool settled))",
  "function pendingEpochs(bytes32 poolId) view returns (uint256)",
  "event SettlementExecuted(bytes32 indexed poolId, uint256 epoch, uint256 premiumsCollected, uint256 pendingClaims)",
];
