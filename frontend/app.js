// BELTA Labs — Dashboard Application Logic
// Uses ethers.js v6

let provider = null;
let signer = null;
let userAddress = null;

// Contract instances
let usdc, pool, treasury, hook, oracle, settlement;

// Decimals
let usdcDecimals = 6;

// ─── Initialization ──────────────────────────────────────

async function init() {
  updateStatus("Initializing...");
  setupEventListeners();
  // Try to auto-connect if previously connected
  if (window.ethereum && window.ethereum.selectedAddress) {
    await connectWallet();
  }
  updateStatus("Ready — connect wallet to begin");
}

function setupEventListeners() {
  document.getElementById("btn-connect").addEventListener("click", connectWallet);
  document.getElementById("btn-deposit").addEventListener("click", depositUSDC);
  document.getElementById("btn-request-withdraw").addEventListener("click", requestWithdrawal);
  document.getElementById("btn-withdraw").addEventListener("click", withdrawUSDC);
  document.getElementById("btn-approve").addEventListener("click", approveUSDC);
  document.getElementById("btn-claim-il").addEventListener("click", claimIL);
  document.getElementById("btn-refresh").addEventListener("click", refreshAll);

  if (window.ethereum) {
    window.ethereum.on("accountsChanged", (accounts) => {
      if (accounts.length === 0) {
        disconnectUI();
      } else {
        connectWallet();
      }
    });
    window.ethereum.on("chainChanged", () => window.location.reload());
  }
}

// ─── Wallet Connection ───────────────────────────────────

async function connectWallet() {
  if (!window.ethereum) {
    showToast("MetaMask not detected. Please install MetaMask.", "error");
    return;
  }

  try {
    updateStatus("Connecting wallet...");
    provider = new ethers.BrowserProvider(window.ethereum);

    // Request accounts
    const accounts = await provider.send("eth_requestAccounts", []);
    signer = await provider.getSigner();
    userAddress = await signer.getAddress();

    // Check network
    const network = await provider.getNetwork();
    if (Number(network.chainId) !== CHAIN_ID) {
      showToast("Please switch to Sepolia testnet", "error");
      try {
        await window.ethereum.request({
          method: "wallet_switchEthereumChain",
          params: [{ chainId: "0x" + CHAIN_ID.toString(16) }],
        });
        provider = new ethers.BrowserProvider(window.ethereum);
        signer = await provider.getSigner();
      } catch (switchErr) {
        updateStatus("Wrong network — switch to Sepolia");
        return;
      }
    }

    // Initialize contracts
    initContracts();

    // Update UI
    const short = userAddress.slice(0, 6) + "..." + userAddress.slice(-4);
    document.getElementById("btn-connect").textContent = short;
    document.getElementById("btn-connect").classList.add("connected");
    document.getElementById("wallet-address").textContent = short;
    document.getElementById("wallet-info").style.display = "flex";

    updateStatus("Connected");
    showToast("Wallet connected successfully", "success");

    // Load all data
    await refreshAll();
  } catch (err) {
    console.error("Connection error:", err);
    showToast("Failed to connect wallet: " + err.message, "error");
    updateStatus("Connection failed");
  }
}

function disconnectUI() {
  userAddress = null;
  signer = null;
  document.getElementById("btn-connect").textContent = "Connect Wallet";
  document.getElementById("btn-connect").classList.remove("connected");
  document.getElementById("wallet-info").style.display = "none";
  updateStatus("Disconnected");
}

function initContracts() {
  usdc       = new ethers.Contract(ADDRESSES.MOCK_USDC, ERC20_ABI, signer);
  pool       = new ethers.Contract(ADDRESSES.UNDERWRITER_POOL, UNDERWRITER_POOL_ABI, signer);
  treasury   = new ethers.Contract(ADDRESSES.TREASURY_MODULE, TREASURY_MODULE_ABI, provider);
  hook       = new ethers.Contract(ADDRESSES.BELTA_HOOK, BELTA_HOOK_ABI, provider);
  oracle     = new ethers.Contract(ADDRESSES.PREMIUM_ORACLE, PREMIUM_ORACLE_ABI, provider);
  settlement = new ethers.Contract(ADDRESSES.EPOCH_SETTLEMENT, EPOCH_SETTLEMENT_ABI, provider);
}

// ─── Data Loading ────────────────────────────────────────

async function refreshAll() {
  if (!provider) return;
  updateStatus("Loading data...");
  document.getElementById("btn-refresh").classList.add("spinning");

  try {
    await Promise.allSettled([
      loadProtocolStats(),
      loadUserData(),
      loadOracleData(),
      loadEpochData(),
    ]);
    updateStatus("Data loaded");
  } catch (err) {
    console.error("Refresh error:", err);
    updateStatus("Some data failed to load");
  } finally {
    document.getElementById("btn-refresh").classList.remove("spinning");
  }
}

async function loadProtocolStats() {
  try {
    // Pool stats
    const [totalAssets, totalSupply, premiumsEarned, claimsPaid, netIncome, dailyPayout, dailyLimit] =
      await Promise.all([
        pool.totalAssets(),
        pool.totalSupply(),
        pool.totalPremiumsEarned(),
        pool.totalClaimsPaid(),
        pool.netPremiumIncome(),
        pool.currentDailyPayout(),
        pool.dailyPayLimit(),
      ]);

    setVal("pool-tvl", formatUSDC(totalAssets));
    setVal("pool-shares", formatUSDC(totalSupply));
    setVal("premiums-earned", formatUSDC(premiumsEarned));
    setVal("claims-paid", formatUSDC(claimsPaid));
    setVal("net-income", formatUSDC(netIncome));
    setVal("daily-payout", `${formatUSDC(dailyPayout)} / ${formatUSDC(dailyLimit)}`);

    // Treasury stats
    const [bufferBal, bufferHealth, targetBuffer, needsHealing] = await Promise.all([
      treasury.bufferBalance(),
      treasury.bufferHealthBps(),
      treasury.getTargetBufferSize(),
      treasury.needsSelfHealing(),
    ]);

    setVal("treasury-buffer", formatUSDC(bufferBal));
    setVal("treasury-target", formatUSDC(targetBuffer));

    const healthPct = Number(bufferHealth) / 100;
    setVal("buffer-health", healthPct.toFixed(1) + "%");
    const healthBar = document.getElementById("buffer-health-bar");
    if (healthBar) {
      healthBar.style.width = Math.min(healthPct, 100) + "%";
      healthBar.className = "health-fill" +
        (healthPct >= 80 ? " healthy" : healthPct >= 50 ? " warning" : " critical");
    }
    setVal("needs-healing", needsHealing ? "YES" : "No");
    if (needsHealing) {
      document.getElementById("needs-healing").classList.add("alert");
    } else {
      document.getElementById("needs-healing").classList.remove("alert");
    }

    // Utilization — show as a ratio
    const utilizationPct = totalAssets > 0n
      ? Number((premiumsEarned * 10000n) / totalAssets) / 100
      : 0;
    setVal("utilization-rate", utilizationPct.toFixed(1) + "%");

  } catch (err) {
    console.error("Error loading protocol stats:", err);
  }
}

async function loadUserData() {
  if (!userAddress) return;

  try {
    // USDC balance
    const [usdcBal, sharesBal, canWithdraw, requestTime, cooldownPeriod] = await Promise.all([
      usdc.balanceOf(userAddress),
      pool.balanceOf(userAddress),
      pool.canWithdraw(userAddress),
      pool.withdrawalRequestTime(userAddress),
      pool.COOLDOWN_PERIOD(),
    ]);

    setVal("usdc-balance", formatUSDC(usdcBal));
    setVal("share-balance", formatUSDC(sharesBal));

    // Share value
    if (sharesBal > 0n) {
      const assetsForShares = await pool.convertToAssets(sharesBal);
      setVal("share-value", formatUSDC(assetsForShares) + " USDC");
    } else {
      setVal("share-value", "0.00 USDC");
    }

    // Cooldown status
    const cooldownEl = document.getElementById("cooldown-status");
    if (requestTime > 0n) {
      const unlockTime = Number(requestTime) + Number(cooldownPeriod);
      const now = Math.floor(Date.now() / 1000);
      if (now >= unlockTime) {
        cooldownEl.textContent = "Ready to withdraw";
        cooldownEl.className = "cooldown-ready";
      } else {
        const remaining = unlockTime - now;
        cooldownEl.textContent = formatDuration(remaining) + " remaining";
        cooldownEl.className = "cooldown-waiting";
      }
    } else {
      cooldownEl.textContent = "No request pending";
      cooldownEl.className = "cooldown-none";
    }

    // Allowance
    const allowance = await usdc.allowance(userAddress, ADDRESSES.UNDERWRITER_POOL);
    setVal("current-allowance", formatUSDC(allowance));

  } catch (err) {
    console.error("Error loading user data:", err);
  }
}

async function loadOracleData() {
  try {
    const [baseRate, kink, maxMult] = await Promise.all([
      oracle.baseRate(),
      oracle.kink(),
      oracle.maxMultiplier(),
    ]);

    setVal("oracle-base-rate", (Number(baseRate) / 100).toFixed(1) + "%");
    setVal("oracle-kink", (Number(kink) / 100).toFixed(1) + "%");
    setVal("oracle-max-mult", maxMult.toString() + "x");

    // Calculate rates at different utilization levels for the chart
    const rates = [];
    for (let u = 0; u <= 100; u += 5) {
      const utilBps = u * 100;
      const rate = await oracle.getPremiumRate(utilBps);
      rates.push({ util: u, rate: Number(rate) / 100 });
    }
    renderUtilizationChart(rates);
  } catch (err) {
    console.error("Error loading oracle data:", err);
  }
}

// ─── Epoch Data ──────────────────────────────────────────

async function loadEpochData() {
  try {
    const poolId = POOL_INFO.POOL_ID;
    const [epochData, capacity] = await Promise.all([
      hook.epochs(poolId),
      hook.poolCapacity(poolId),
    ]);

    const epochNumber = Number(epochData.epochNumber);
    const startTimestamp = Number(epochData.startTimestamp);
    const epochDuration = 1 * 24 * 3600; // 1 day
    const now = Math.floor(Date.now() / 1000);
    const endTimestamp = startTimestamp + epochDuration;
    const elapsed = now - startTimestamp;
    const progressPct = Math.min((elapsed / epochDuration) * 100, 100);

    setVal("epoch-number", epochNumber.toString());
    setVal("epoch-start", new Date(startTimestamp * 1000).toLocaleDateString());
    setVal("epoch-next", formatDuration(Math.max(endTimestamp - now, 0)));
    setVal("pool-capacity", formatUSDC(capacity));

    const bar = document.getElementById("epoch-progress-bar");
    if (bar) bar.style.width = progressPct.toFixed(1) + "%";
    setVal("epoch-progress-text", `Epoch ${progressPct.toFixed(0)}% complete — ${formatDuration(Math.max(endTimestamp - now, 0))} remaining`);
  } catch (err) {
    console.error("Error loading epoch data:", err);
  }
}

// ─── User Actions ────────────────────────────────────────

async function approveUSDC() {
  try {
    const amountStr = document.getElementById("deposit-amount").value;
    if (!amountStr || parseFloat(amountStr) <= 0) {
      showToast("Enter a valid amount first", "error");
      return;
    }
    const amount = ethers.parseUnits(amountStr, usdcDecimals);
    updateStatus("Approving USDC...");
    const tx = await usdc.approve(ADDRESSES.UNDERWRITER_POOL, amount);
    showToast("Approval tx submitted", "info");
    await tx.wait();
    showToast("USDC approved successfully", "success");
    updateStatus("Approved");
    await loadUserData();
  } catch (err) {
    console.error("Approve error:", err);
    showToast("Approval failed: " + parseError(err), "error");
    updateStatus("Approval failed");
  }
}

async function depositUSDC() {
  try {
    const amountStr = document.getElementById("deposit-amount").value;
    if (!amountStr || parseFloat(amountStr) <= 0) {
      showToast("Enter a valid amount", "error");
      return;
    }
    const amount = ethers.parseUnits(amountStr, usdcDecimals);

    // Check allowance
    const allowance = await usdc.allowance(userAddress, ADDRESSES.UNDERWRITER_POOL);
    if (allowance < amount) {
      showToast("Insufficient allowance — approve first", "error");
      return;
    }

    updateStatus("Depositing...");
    const tx = await pool.deposit(amount, userAddress);
    showToast("Deposit tx submitted", "info");
    await tx.wait();
    showToast("Deposit successful!", "success");
    updateStatus("Deposited");
    document.getElementById("deposit-amount").value = "";
    await refreshAll();
  } catch (err) {
    console.error("Deposit error:", err);
    showToast("Deposit failed: " + parseError(err), "error");
    updateStatus("Deposit failed");
  }
}

async function requestWithdrawal() {
  try {
    updateStatus("Requesting withdrawal...");
    const tx = await pool.requestWithdrawal();
    showToast("Withdrawal request tx submitted", "info");
    await tx.wait();
    showToast("Withdrawal requested — 7-day cooldown started", "success");
    updateStatus("Cooldown started");
    await loadUserData();
  } catch (err) {
    console.error("Request withdrawal error:", err);
    showToast("Request failed: " + parseError(err), "error");
    updateStatus("Request failed");
  }
}

async function withdrawUSDC() {
  try {
    const amountStr = document.getElementById("withdraw-amount").value;
    if (!amountStr || parseFloat(amountStr) <= 0) {
      showToast("Enter a valid amount", "error");
      return;
    }
    const amount = ethers.parseUnits(amountStr, usdcDecimals);

    updateStatus("Withdrawing...");
    const tx = await pool.withdraw(amount, userAddress, userAddress);
    showToast("Withdrawal tx submitted", "info");
    await tx.wait();
    showToast("Withdrawal successful!", "success");
    updateStatus("Withdrawn");
    document.getElementById("withdraw-amount").value = "";
    await refreshAll();
  } catch (err) {
    console.error("Withdraw error:", err);
    showToast("Withdrawal failed: " + parseError(err), "error");
    updateStatus("Withdrawal failed");
  }
}

async function claimIL() {
  try {
    const poolId = document.getElementById("claim-pool-id").value;
    const tickLower = parseInt(document.getElementById("claim-tick-lower").value);
    const tickUpper = parseInt(document.getElementById("claim-tick-upper").value);

    if (!poolId || isNaN(tickLower) || isNaN(tickUpper)) {
      showToast("Enter pool ID and tick range", "error");
      return;
    }

    updateStatus("Claiming IL payout...");
    const tx = await hook.connect(signer).claimILPayout(poolId, tickLower, tickUpper);
    showToast("Claim tx submitted", "info");
    await tx.wait();
    showToast("IL payout claimed!", "success");
    updateStatus("Claimed");
    await refreshAll();
  } catch (err) {
    console.error("Claim error:", err);
    showToast("Claim failed: " + parseError(err), "error");
    updateStatus("Claim failed");
  }
}

// ─── Utilization Chart (Canvas) ──────────────────────────

function renderUtilizationChart(rates) {
  const canvas = document.getElementById("util-chart");
  if (!canvas) return;
  const ctx = canvas.getContext("2d");
  const w = canvas.width = canvas.parentElement.clientWidth - 32;
  const h = canvas.height = 180;
  const pad = { top: 20, right: 20, bottom: 30, left: 50 };
  const pw = w - pad.left - pad.right;
  const ph = h - pad.top - pad.bottom;

  ctx.clearRect(0, 0, w, h);

  if (rates.length === 0) return;

  const maxRate = Math.max(...rates.map(r => r.rate), 20);

  // Grid
  ctx.strokeStyle = "rgba(255,255,255,0.06)";
  ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = pad.top + (ph * i / 4);
    ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(w - pad.right, y); ctx.stroke();
  }

  // Gradient fill
  const grad = ctx.createLinearGradient(0, pad.top, 0, h - pad.bottom);
  grad.addColorStop(0, "rgba(200, 169, 110, 0.25)");
  grad.addColorStop(1, "rgba(200, 169, 110, 0.01)");

  ctx.beginPath();
  ctx.moveTo(pad.left, h - pad.bottom);
  rates.forEach((r, i) => {
    const x = pad.left + (r.util / 100) * pw;
    const y = pad.top + ph - (r.rate / maxRate) * ph;
    if (i === 0) ctx.lineTo(x, y);
    else ctx.lineTo(x, y);
  });
  ctx.lineTo(pad.left + pw, h - pad.bottom);
  ctx.closePath();
  ctx.fillStyle = grad;
  ctx.fill();

  // Line
  ctx.beginPath();
  ctx.strokeStyle = "#c8a96e";
  ctx.lineWidth = 2.5;
  ctx.shadowColor = "#c8a96e";
  ctx.shadowBlur = 8;
  rates.forEach((r, i) => {
    const x = pad.left + (r.util / 100) * pw;
    const y = pad.top + ph - (r.rate / maxRate) * ph;
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  });
  ctx.stroke();
  ctx.shadowBlur = 0;

  // Labels
  ctx.fillStyle = "rgba(255,255,255,0.45)";
  ctx.font = "11px 'Inter', sans-serif";
  ctx.textAlign = "center";
  for (let u = 0; u <= 100; u += 20) {
    const x = pad.left + (u / 100) * pw;
    ctx.fillText(u + "%", x, h - 8);
  }
  ctx.textAlign = "right";
  for (let i = 0; i <= 4; i++) {
    const val = (maxRate * (4 - i) / 4).toFixed(0);
    const y = pad.top + (ph * i / 4) + 4;
    ctx.fillText(val + "%", pad.left - 8, y);
  }

  // Kink line
  const kinkX = pad.left + 0.8 * pw;
  ctx.strokeStyle = "rgba(255, 170, 0, 0.5)";
  ctx.lineWidth = 1;
  ctx.setLineDash([4, 4]);
  ctx.beginPath(); ctx.moveTo(kinkX, pad.top); ctx.lineTo(kinkX, h - pad.bottom); ctx.stroke();
  ctx.setLineDash([]);
  ctx.fillStyle = "rgba(255, 170, 0, 0.7)";
  ctx.textAlign = "center";
  ctx.fillText("Kink 80%", kinkX, pad.top - 5);
}

// ─── Helpers ─────────────────────────────────────────────

function formatUSDC(val) {
  const n = Number(ethers.formatUnits(val, usdcDecimals));
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(2) + "M";
  if (n >= 1_000) return (n / 1_000).toFixed(2) + "K";
  return n.toFixed(2);
}

function formatDuration(seconds) {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

function setVal(id, val) {
  const el = document.getElementById(id);
  if (el) el.textContent = val;
}

function updateStatus(msg) {
  const el = document.getElementById("status-text");
  if (el) el.textContent = msg;
}

function parseError(err) {
  if (err.reason) return err.reason;
  if (err.message && err.message.length < 100) return err.message;
  return "Transaction reverted";
}

function showToast(message, type = "info") {
  const container = document.getElementById("toast-container");
  const toast = document.createElement("div");
  toast.className = `toast toast-${type}`;
  toast.innerHTML = `
    <span class="toast-icon">${type === "success" ? "\u2713" : type === "error" ? "\u2717" : "\u2139"}</span>
    <span>${message}</span>
  `;
  container.appendChild(toast);
  setTimeout(() => toast.classList.add("show"), 10);
  setTimeout(() => {
    toast.classList.remove("show");
    setTimeout(() => toast.remove(), 300);
  }, 4000);
}

// ─── Start ──────────────────────────────────────────────

window.addEventListener("DOMContentLoaded", init);
