// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@v4-core/types/PoolId.sol";

/// @title VolatilityOracle
/// @notice Realized volatility tracker + dynamic swap fee calculator
/// @dev Feeds into BELTAHook.beforeSwap() for volatility-aware fee adjustment.
///      Low vol → low fee (attract volume), High vol → high fee (compensate LPs for IL risk).
///      Uses EWMA smoothing to prevent manipulation.
contract VolatilityOracle {
    // ─── Errors ─────────────────────────────────────────────
    error OnlyOwner();
    error OnlyKeeper();
    error InvalidParams();

    // ─── Events ─────────────────────────────────────────────
    event VolatilityUpdated(PoolId indexed poolId, uint256 realizedVol, uint256 ewmaVol);
    event DynamicFeeUpdated(PoolId indexed poolId, uint24 newFee);
    event ParamsUpdated(uint24 minFee, uint24 maxFee, uint256 volKink);

    // ─── Constants ──────────────────────────────────────────
    uint256 public constant BPS = 10_000;

    // Fee is in Uniswap's 1e6 scale (1000 = 0.1%, 3000 = 0.3%, 10000 = 1%)
    uint24 public constant FEE_UNIT = 1_000_000;

    // ─── State ──────────────────────────────────────────────
    address public owner;
    address public keeper;

    // Dynamic fee parameters
    uint24 public minFee = 500;       // 0.05% — low vol floor
    uint24 public maxFee = 10_000;    // 1.0%  — high vol ceiling
    uint24 public baseFee = 3000;     // 0.3%  — default/medium vol
    uint256 public volKink = 5000;    // 50% annualized vol — kink point

    // Per-pool volatility data
    struct VolData {
        uint256 realizedVol;     // Annualized realized vol in BPS (8000 = 80%)
        uint256 ewmaVol;         // EWMA smoothed
        uint256 lastUpdate;
        uint160 lastSqrtPrice;   // For on-chain vol estimation
    }

    mapping(PoolId => VolData) public volData;

    // ─── Constructor ────────────────────────────────────────
    constructor() {
        owner = msg.sender;
        keeper = msg.sender;
    }

    // ─── Modifiers ──────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner) revert OnlyKeeper();
        _;
    }

    // ─── Core: Dynamic Fee Calculation ──────────────────────

    /// @notice Get dynamic swap fee for a pool based on current volatility
    /// @param poolId Pool identifier
    /// @return fee Swap fee in Uniswap's 1e6 scale (3000 = 0.3%)
    function getDynamicFee(PoolId poolId) external view returns (uint24 fee) {
        VolData storage vd = volData[poolId];
        uint256 vol = vd.ewmaVol > 0 ? vd.ewmaVol : vd.realizedVol;

        // No data → return base fee
        if (vol == 0) return baseFee;

        return _calculateFee(vol);
    }

    /// @dev Fee curve:
    ///   vol < volKink:  fee = minFee + (baseFee - minFee) * vol / volKink
    ///   vol >= volKink: fee = baseFee + (maxFee - baseFee) * (vol - volKink) / (BPS - volKink)
    ///   Clamped to [minFee, maxFee]
    function _calculateFee(uint256 vol) internal view returns (uint24) {
        if (vol <= volKink) {
            // Linear: minFee → baseFee
            uint256 fee = uint256(minFee) + uint256(baseFee - minFee) * vol / volKink;
            return uint24(fee);
        }

        // Above kink: baseFee → maxFee (steeper)
        uint256 excessVol = vol - volKink;
        uint256 maxExcess = BPS - volKink;
        if (maxExcess == 0) return maxFee;

        uint256 fee = uint256(baseFee) + uint256(maxFee - baseFee) * excessVol / maxExcess;
        if (fee > uint256(maxFee)) return maxFee;
        return uint24(fee);
    }

    // ─── Keeper: Volatility Updates ─────────────────────────

    /// @notice Update realized volatility for a pool (off-chain computed)
    /// @param poolId Pool identifier
    /// @param newVol Annualized realized volatility in BPS (e.g., 8000 = 80%)
    function updateVolatility(PoolId poolId, uint256 newVol) external onlyKeeper {
        if (newVol > 50_000) revert InvalidParams(); // Cap at 500%

        VolData storage vd = volData[poolId];

        // EWMA: newEWMA = 0.3 * newVol + 0.7 * oldEWMA
        if (vd.ewmaVol == 0) {
            vd.ewmaVol = newVol;
        } else {
            vd.ewmaVol = (newVol * 3000 + vd.ewmaVol * 7000) / BPS;
        }

        vd.realizedVol = newVol;
        vd.lastUpdate = block.timestamp;

        emit VolatilityUpdated(poolId, newVol, vd.ewmaVol);
    }

    /// @notice Record price observation (called by hook in afterSwap)
    /// @dev Can be used for on-chain vol estimation in future versions
    function recordPrice(PoolId poolId, uint160 sqrtPriceX96) external onlyKeeper {
        volData[poolId].lastSqrtPrice = sqrtPriceX96;
    }

    // ─── Admin ──────────────────────────────────────────────

    function setFeeParams(uint24 _minFee, uint24 _baseFee, uint24 _maxFee, uint256 _volKink) external onlyOwner {
        if (_minFee > _baseFee || _baseFee > _maxFee) revert InvalidParams();
        if (_maxFee > FEE_UNIT) revert InvalidParams();
        if (_volKink > BPS) revert InvalidParams();

        minFee = _minFee;
        baseFee = _baseFee;
        maxFee = _maxFee;
        volKink = _volKink;

        emit ParamsUpdated(_minFee, _maxFee, _volKink);
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
    }

    // ─── View Functions ─────────────────────────────────────

    function getVolatility(PoolId poolId) external view returns (uint256 realized, uint256 ewma, uint256 lastUpdate) {
        VolData storage vd = volData[poolId];
        return (vd.realizedVol, vd.ewmaVol, vd.lastUpdate);
    }

    function isVolatilityFresh(PoolId poolId) external view returns (bool) {
        return block.timestamp - volData[poolId].lastUpdate <= 1 days;
    }
}
