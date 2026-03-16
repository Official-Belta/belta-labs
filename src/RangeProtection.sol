// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {StateLibrary} from "@v4-core/libraries/StateLibrary.sol";

interface IBELTAHookRange {
    struct LPPosition {
        uint160 sqrtPriceAtEntry;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 epochStart;
        uint256 premiumOwed;
        uint256 ilClaimable;
        bool active;
    }

    function getPosition(PoolId poolId, address lp, int24 tickLower, int24 tickUpper)
        external
        view
        returns (LPPosition memory);

    function forceRemovePosition(PoolKey calldata key, address lp, int24 tickLower, int24 tickUpper) external;
}

/// @title RangeProtection
/// @notice LP 포지션이 틱 범위 경계에 근접하면 강제 청산하여 IL 손실을 최소화
/// @dev Keeper가 주기적으로 checkAndLiquidate()를 호출.
///      현재 tick이 LP 범위의 BUFFER_TICKS 이내이면 강제로 유동성 제거 + IL 정산.
///      Charm/Arrakis/Gamma 방식의 Range Protection을 BELTA 프로토콜에 적용.
contract RangeProtection {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── Errors ─────────────────────────────────────────────
    error OnlyKeeper();
    error OnlyOwner();
    error NotNearBoundary();
    error PositionNotActive();

    // ─── Events ─────────────────────────────────────────────
    event RangeLiquidation(
        PoolId indexed poolId,
        address indexed lp,
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick,
        string reason
    );

    // ─── Constants ──────────────────────────────────────────
    /// @notice 경계로부터 버퍼 틱 수 (30틱 ≈ 0.3%)
    int24 public constant BUFFER_TICKS = 30;

    // ─── State ──────────────────────────────────────────────
    IPoolManager public immutable poolManager;
    IBELTAHookRange public immutable hook;
    address public owner;
    address public keeper;

    // ─── Constructor ────────────────────────────────────────
    constructor(address _poolManager, address _hook) {
        poolManager = IPoolManager(_poolManager);
        hook = IBELTAHookRange(_hook);
        owner = msg.sender;
        keeper = msg.sender;
    }

    // ─── Modifiers ──────────────────────────────────────────
    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner) revert OnlyKeeper();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // ─── Core Logic ─────────────────────────────────────────

    /// @notice 포지션이 범위 이탈 직전인지 확인
    /// @return nearBoundary true면 강제 청산 필요
    /// @return reason 청산 사유 문자열
    function checkNearBoundary(
        PoolKey calldata key,
        address lp,
        int24 tickLower,
        int24 tickUpper
    ) public view returns (bool nearBoundary, string memory reason) {
        PoolId poolId = key.toId();

        // 포지션 활성 확인
        IBELTAHookRange.LPPosition memory pos = hook.getPosition(poolId, lp, tickLower, tickUpper);
        if (!pos.active || pos.liquidity == 0) return (false, "inactive");

        // 현재 tick 확인
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // 하단 경계 근접: currentTick <= tickLower + BUFFER
        if (currentTick <= tickLower + BUFFER_TICKS) {
            return (true, "near lower boundary");
        }

        // 상단 경계 근접: currentTick >= tickUpper - BUFFER
        if (currentTick >= tickUpper - BUFFER_TICKS) {
            return (true, "near upper boundary");
        }

        // 이미 범위 이탈 (완전히 벗어남)
        if (currentTick < tickLower || currentTick >= tickUpper) {
            return (true, "out of range");
        }

        return (false, "in range");
    }

    /// @notice 범위 이탈 직전 포지션을 강제 청산
    /// @dev Keeper가 호출. checkNearBoundary가 true인 경우에만 실행됨.
    function liquidate(
        PoolKey calldata key,
        address lp,
        int24 tickLower,
        int24 tickUpper
    ) external onlyKeeper {
        PoolId poolId = key.toId();

        // 1. 범위 이탈 직전인지 확인
        (bool nearBoundary, string memory reason) = checkNearBoundary(key, lp, tickLower, tickUpper);
        if (!nearBoundary) revert NotNearBoundary();

        // 2. 현재 tick 기록
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // 3. BELTAHook에 강제 청산 요청
        hook.forceRemovePosition(key, lp, tickLower, tickUpper);

        emit RangeLiquidation(poolId, lp, tickLower, tickUpper, currentTick, reason);
    }

    /// @notice 여러 포지션을 한번에 체크 & 청산
    function batchLiquidate(
        PoolKey calldata key,
        address[] calldata lps,
        int24[] calldata tickLowers,
        int24[] calldata tickUppers
    ) external onlyKeeper {
        require(lps.length == tickLowers.length && lps.length == tickUppers.length, "length mismatch");

        for (uint256 i = 0; i < lps.length; i++) {
            (bool nearBoundary,) = checkNearBoundary(key, lps[i], tickLowers[i], tickUppers[i]);
            if (nearBoundary) {
                PoolId poolId = key.toId();
                (, int24 currentTick,,) = poolManager.getSlot0(poolId);
                hook.forceRemovePosition(key, lps[i], tickLowers[i], tickUppers[i]);
                emit RangeLiquidation(poolId, lps[i], tickLowers[i], tickUppers[i], currentTick, "batch");
            }
        }
    }

    // ─── Admin ──────────────────────────────────────────────

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
    }
}
