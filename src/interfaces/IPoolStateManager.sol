// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPoolStateManager {
    struct LaunchParams {
        string name;
        string symbol;
        string tokenUri;
        uint8 transitionpercent;
        address creator;
        uint256 initialSupply;
    }

    function launchMemeCoin(LaunchParams calldata params) external returns (address);
}
