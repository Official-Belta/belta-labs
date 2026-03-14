// BELTA Labs — Contract ABIs (extracted from Solidity source)
// Chain: Sepolia (11155111)

const ADDRESSES = {
  MOCK_USDC:        "0x3A6262e69a845D93F4b518d28BbA3abb456618d6",
  BELTA_HOOK:       "0x1609e47BE1504F29Ed6DBb5dcdF57dEea9405540",
  UNDERWRITER_POOL: "0x4296A225D8077b614DAf25862Bc9F780aFDea5DD",
  TREASURY_MODULE:  "0xa0b315d9bab3fcaf21f750bd3c8b9d0fc5bd51f3",
  PREMIUM_ORACLE:   "0x2d11850a62aac9dc10bc67bb2056685e4cf1bf58",
  EPOCH_SETTLEMENT: "0x693DB559c3bCc243470D31025E7BF5B7f08EE9a1",
};

const CHAIN_ID = 11155111;

// V4 Pool Info (from InitPool deployment)
const POOL_INFO = {
  MOCK_WETH: "0x4ABD7D9b2D8EAb6c158F84C7b786CF82e7Aff8f2",
  POOL_ID: "0x1010163c169fbe97dbced857983e8e0f1d3d44042f78430ee1bc5815e9865551",
  FEE: 3000,
  TICK_SPACING: 60,
  INITIAL_TICK: -202200,
  INITIAL_PRICE: "~$2000 ETH/USDC",
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
