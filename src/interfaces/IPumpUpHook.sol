// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PumpUpHook} from "../PumpUpHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

interface IPumpUpHook {
    function addLiquidity(PoolKey calldata key, PumpUpHook.LiquidityParams calldata params, address) external;
}
