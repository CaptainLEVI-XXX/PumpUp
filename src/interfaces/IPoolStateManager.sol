// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolStateManager} from "../PoolStateManager.sol";

interface IPoolStateManager {
    function launchMemeCoin(PoolStateManager.LaunchParams calldata params) external returns (address);
}
