// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

/**
 * @title IMemeGuardServiceManager
 * @notice Interface for the MemeGuard service
 */
interface IMemeGuardServiceManager {
    // View functions
    function checkStrategySafety(bytes32 strategyId)
        external
        view
        returns (bool assessed, uint8 riskScore, bool isCritical);

    function checkTokenSafety(bytes32 poolId)
        external
        view
        returns (bool assessed, uint8 riskScore, bool isSuspicious);

    function checkTransitionReadiness(bytes32 poolId)
        external
        view
        returns (bool assessed, uint8 riskScore, bool isReady);
}
