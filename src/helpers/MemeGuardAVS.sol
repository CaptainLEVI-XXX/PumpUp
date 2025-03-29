// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMemeGuardServiceManager} from "../interfaces/IMemeGuardServiceManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/**
 * @title MemeGuardAVS
 * @notice Abstract contract providing easy integration with MemeGuard AVS
 * @dev Only includes read calls for risk assessment to be used across protocol components
 */
abstract contract MemeGuardAVS {
    using CustomRevert for bytes4;
    // ============ State Variables ============

    /// @notice The address of the MemeGuard AVS contract
    IMemeGuardServiceManager public memeGuardServiceManager;

    /// @notice Whether risk assessment is enabled
    bool public riskAssessmentEnabled = false;

    ///  @notice Risk thresholds (configurable)
    uint8 public maxStrategyRiskThreshold = 70; // 0-100 scale
    uint8 public maxTokenRiskThreshold = 60; // 0-100 scale
    uint8 public maxTransitionRiskThreshold = 80; // 0-100 scale

    // ============ Events ============

    /// @notice Emitted when risk assessment is enabled/disabled
    event RiskAssessmentStatusChanged(bool enabled);

    /// @notice Emitted when the MemeGuard AVS address is updated
    event MemeGuardAddressUpdated(address indexed oldAddress, address indexed newAddress);

    /// @notice Emitted when risk thresholds are updated
    event RiskThresholdsUpdated(uint8 strategyRiskThreshold, uint8 tokenRiskThreshold, uint8 transitionRiskThreshold);

    // ============ Errors ============

    /// @notice Invalid address provided
    error InvalidAddress();

    /// @notice Strategy failed risk assessment
    error StrategyRiskCheckFailed(bytes32 strategyId, uint8 riskScore, bool isCritical);

    /// @notice Token failed risk assessment
    error TokenRiskCheckFailed(bytes32 poolId, uint8 riskScore, bool isSuspicious);

    /// @notice Transition failed risk assessment
    error TransitionRiskCheckFailed(bytes32 poolId, uint8 riskScore, bool isReady);

    error HealthFactorNotPassed();

    /**
     * @notice Constructor setting initial values
     * @param _memeGuardAddress The address of MemeGuard AVS
     */
    constructor(address _memeGuardAddress) {
        if (_memeGuardAddress == address(0)) InvalidAddress.selector.revertWith();

        memeGuardServiceManager = IMemeGuardServiceManager(_memeGuardAddress);
    }

    // ============ View Functions ============

    /**
     * @notice Check if a strategy passes risk assessment
     * @param strategyId The ID of the strategy to check
     * @return allowed Whether the strategy is allowed based on risk assessment
     * @return assessed Whether the strategy has been assessed
     * @return riskScore The risk score if assessed (0-100)
     * @return isCritical Whether critical vulnerabilities were found
     */
    function checkStrategyRisk(bytes32 strategyId)
        public
        view
        returns (bool allowed, bool assessed, uint8 riskScore, bool isCritical)
    {
        // Skip check if risk assessment is disabled
        if (!riskAssessmentEnabled || address(memeGuardServiceManager) == address(0)) {
            return (true, false, 0, false);
        }

        // Call the MemeGuard AVS
        (assessed, riskScore, isCritical) = memeGuardServiceManager.checkStrategySafety(strategyId);

        // If assessment is required but not completed, fail check
        if (!assessed) {
            return (false, false, 0, false);
        }

        // If assessed, check against thresholds
        if (assessed) {
            allowed = !isCritical && riskScore <= maxStrategyRiskThreshold;
            return (allowed, assessed, riskScore, isCritical);
        }

        // If not assessed and assessment not required, pass check
        return (true, false, 0, false);
    }

    /**
     * @notice Check if a token passes risk assessment
     * @param poolId The pool ID associated with the token
     * @return allowed Whether the token is allowed based on risk assessment
     * @return assessed Whether the token has been assessed
     * @return riskScore The risk score if assessed (0-100)
     * @return isSuspicious Whether suspicious activity was detected
     */
    function checkTokenRisk(bytes32 poolId)
        public
        view
        returns (bool allowed, bool assessed, uint8 riskScore, bool isSuspicious)
    {
        // Skip check if risk assessment is disabled
        if (!riskAssessmentEnabled || address(memeGuardServiceManager) == address(0)) {
            return (true, false, 0, false);
        }

        // Call the MemeGuard AVS
        (assessed, riskScore, isSuspicious) = memeGuardServiceManager.checkTokenSafety(poolId);

        // If assessment is required but not completed, fail check
        if (!assessed) {
            return (false, false, 0, false);
        }

        // If assessed, check against thresholds
        if (assessed) {
            allowed = !isSuspicious && riskScore <= maxTokenRiskThreshold;
            return (allowed, assessed, riskScore, isSuspicious);
        }

        // If not assessed and assessment not required, pass check
        return (true, false, 0, false);
    }

    /**
     * @notice Check if a pool is ready for transition
     * @param poolId The pool ID to check
     * @return allowed Whether the transition is allowed based on risk assessment
     * @return assessed Whether the transition has been assessed
     * @return riskScore The risk score if assessed (0-100)
     * @return isReady Whether the pool is deemed ready for transition
     */
    function checkTransitionRisk(bytes32 poolId)
        public
        view
        returns (bool allowed, bool assessed, uint8 riskScore, bool isReady)
    {
        // Skip check if risk assessment is disabled
        if (!riskAssessmentEnabled || address(memeGuardServiceManager) == address(0)) {
            return (false, false, 0, false);
        }

        // Call the MemeGuard AVS
        (assessed, riskScore, isReady) = memeGuardServiceManager.checkTransitionReadiness(poolId);

        // If assessment is required but not completed, fail check
        if (!assessed) {
            return (false, false, 0, false);
        }

        // If assessed, check transition readiness and risk score
        if (assessed) {
            allowed = isReady && riskScore <= maxTransitionRiskThreshold;

            return (allowed, assessed, riskScore, isReady);
        }

        // If not assessed and assessment not required, pass check
        return (true, false, 0, false);
    }

    /**
     * @notice Get full strategy risk details for UI display
     * @param strategyId The strategy ID to check
     * @return assessed Whether the strategy has been assessed
     * @return riskScore The risk score if assessed (0-100)
     * @return isCritical Whether critical vulnerabilities were found
     * @return passesThreshold Whether the risk score passes the threshold
     */
    function getStrategyRiskInfo(bytes32 strategyId)
        external
        view
        returns (bool assessed, uint8 riskScore, bool isCritical, bool passesThreshold)
    {
        if (!riskAssessmentEnabled || address(memeGuardServiceManager) == address(0)) {
            return (false, 0, false, true);
        }

        (assessed, riskScore, isCritical) = memeGuardServiceManager.checkStrategySafety(strategyId);
        passesThreshold = assessed ? (!isCritical && riskScore <= maxStrategyRiskThreshold) : true;

        return (assessed, riskScore, isCritical, passesThreshold);
    }

    /**
     * @notice Get full token risk details for UI display
     * @param poolId The pool ID to check
     * @return assessed Whether the token has been assessed
     * @return riskScore The risk score if assessed (0-100)
     * @return isSuspicious Whether suspicious activity was detected
     * @return passesThreshold Whether the risk score passes the threshold
     */
    function getTokenRiskInfo(bytes32 poolId)
        external
        view
        returns (bool assessed, uint8 riskScore, bool isSuspicious, bool passesThreshold)
    {
        if (!riskAssessmentEnabled || address(memeGuardServiceManager) == address(0)) {
            return (false, 0, false, true);
        }

        (assessed, riskScore, isSuspicious) = memeGuardServiceManager.checkTokenSafety(poolId);
        passesThreshold = assessed ? (!isSuspicious && riskScore <= maxTokenRiskThreshold) : true;

        return (assessed, riskScore, isSuspicious, passesThreshold);
    }

    /**
     * @notice Get full transition risk details for UI display
     * @param poolId The pool ID to check
     * @return assessed Whether the transition has been assessed
     * @return riskScore The risk score if assessed (0-100)
     * @return isReady Whether the pool is ready for transition
     * @return passesThreshold Whether the risk score passes the threshold
     */
    function getTransitionRiskInfo(bytes32 poolId)
        public
        view
        returns (bool assessed, uint8 riskScore, bool isReady, bool passesThreshold)
    {
        if (!riskAssessmentEnabled || address(memeGuardServiceManager) == address(0)) {
            return (false, 0, false, true);
        }

        (assessed, riskScore, isReady) =
            IMemeGuardServiceManager(memeGuardServiceManager).checkTransitionReadiness(poolId);

        passesThreshold = assessed ? (isReady && riskScore <= maxTransitionRiskThreshold) : true;

        return (assessed, riskScore, isReady, passesThreshold);
    }

    // ============ Configuration Functions ============
    // These should be implemented in the inheriting contract with appropriate access control

    /**
     * @notice Abstract function to set risk thresholds
     * @param _strategyRiskThreshold Maximum allowed strategy risk score
     * @param _tokenRiskThreshold Maximum allowed token risk score
     * @param _transitionRiskThreshold Maximum allowed transition risk score
     */
    function setRiskThresholds(uint8 _strategyRiskThreshold, uint8 _tokenRiskThreshold, uint8 _transitionRiskThreshold)
        public
        virtual
    {
        maxStrategyRiskThreshold = _strategyRiskThreshold; // 0-100 scale
        maxTokenRiskThreshold = _tokenRiskThreshold; // 0-100 scale
        maxTransitionRiskThreshold = _transitionRiskThreshold; // 0-100 scale
    }
}
