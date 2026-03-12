// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@v4-core/types/PoolId.sol";

/// @title PremiumOracle
/// @notice Dynamic premium rate calculator using Aave-style utilization curve
/// @dev Provides premium rate based on hedging utilization
contract PremiumOracle {
    // ─── Errors ─────────────────────────────────────────────
    error OnlyOwner();
    error InvalidParams();

    // ─── Events ─────────────────────────────────────────────
    event ParamsUpdated(uint256 baseRate, uint256 kink, uint256 maxMultiplier);

    // ─── Constants ──────────────────────────────────────────
    uint256 public constant BPS = 10_000;

    // ─── State ──────────────────────────────────────────────
    address public owner;

    // Default parameters (can be updated per pool or globally)
    uint256 public baseRate = 1200; // 12% base premium rate
    uint256 public kink = 8000; // 80% utilization kink point
    uint256 public maxMultiplier = 3; // max 3x base rate at 100% utilization

    // Per-pool parameter overrides
    struct PoolParams {
        uint256 baseRate;
        uint256 kink;
        uint256 maxMultiplier;
        bool isSet;
    }

    mapping(PoolId => PoolParams) public poolParams;

    // ─── Constructor ────────────────────────────────────────
    constructor() {
        owner = msg.sender;
    }

    // ─── Modifiers ──────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // ─── Core Logic ─────────────────────────────────────────

    /// @notice Calculate dynamic premium rate based on utilization
    /// @param utilization Current utilization in BPS (0-10000)
    /// @return rate Premium rate in BPS
    function getPremiumRate(uint256 utilization) external view returns (uint256 rate) {
        return _calculate(utilization, baseRate, kink, maxMultiplier);
    }

    /// @notice Calculate dynamic premium rate for a specific pool
    /// @param poolId Pool identifier
    /// @param utilization Current utilization in BPS
    /// @return rate Premium rate in BPS
    function getPremiumRateForPool(PoolId poolId, uint256 utilization) external view returns (uint256 rate) {
        PoolParams storage pp = poolParams[poolId];
        if (pp.isSet) {
            return _calculate(utilization, pp.baseRate, pp.kink, pp.maxMultiplier);
        }
        return _calculate(utilization, baseRate, kink, maxMultiplier);
    }

    /// @dev Aave-style utilization curve:
    ///   U < kink:  rate = baseRate
    ///   U >= kink: rate = baseRate + baseRate * (maxMult - 1) * (U - kink) / (BPS - kink)
    function _calculate(uint256 utilization, uint256 _baseRate, uint256 _kink, uint256 _maxMult)
        internal
        pure
        returns (uint256)
    {
        if (utilization <= _kink) {
            return _baseRate;
        }

        uint256 excessUtil = utilization - _kink;
        uint256 maxExcess = BPS - _kink;
        if (maxExcess == 0) return _baseRate * _maxMult;

        uint256 slopeIncrease = _baseRate * (_maxMult - 1) * excessUtil / maxExcess;
        return _baseRate + slopeIncrease;
    }

    // ─── Admin ──────────────────────────────────────────────

    /// @notice Update global default parameters
    function setGlobalParams(uint256 _baseRate, uint256 _kink, uint256 _maxMultiplier) external onlyOwner {
        if (_kink > BPS || _maxMultiplier == 0) revert InvalidParams();
        baseRate = _baseRate;
        kink = _kink;
        maxMultiplier = _maxMultiplier;
        emit ParamsUpdated(_baseRate, _kink, _maxMultiplier);
    }

    /// @notice Set pool-specific parameters
    function setPoolParams(PoolId poolId, uint256 _baseRate, uint256 _kink, uint256 _maxMultiplier)
        external
        onlyOwner
    {
        if (_kink > BPS || _maxMultiplier == 0) revert InvalidParams();
        poolParams[poolId] = PoolParams({
            baseRate: _baseRate,
            kink: _kink,
            maxMultiplier: _maxMultiplier,
            isSet: true
        });
    }

    /// @notice Clear pool-specific override (fall back to global)
    function clearPoolParams(PoolId poolId) external onlyOwner {
        delete poolParams[poolId];
    }
}
