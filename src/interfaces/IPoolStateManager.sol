// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolStateManager} from "../PoolStateManager.sol";

interface IPoolStateManager {
    function launchMemeCoin(PoolStateManager.LaunchParams calldata params) external returns (address);
    function checkTransitionConditions(bytes32 poolId) external view returns (bool);
    function isPoolTransitioned(bytes32 poolId) external view returns (bool);
    function getPoolInfo(bytes32 poolId)
        external
        view
        returns (
            address tokenAddress,
            address creator,
            uint256 wethCollected,
            uint256 lastPrice,
            bool isTransitioned,
            bytes32 bondingCurveStrategy
        );

    function getExtendedPoolInfo(bytes32 poolId)
        external
        view
        returns (
            uint256 nftId,
            uint256 creationTimestamp,
            uint256 circulatingSupply,
            uint256 totalSupply,
            uint256 transitionPrice
        );

    function updatePoolState(bytes32 poolId, uint256 circulatingSupply, uint256 wethCollected, uint256 lastPrice)
        external;
}
