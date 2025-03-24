// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PumpUpHook} from "../src/PumpUpHook.sol";
import {PoolStateManager} from "../src/PoolStateManager.sol";
import {StrategyManager} from "../src/StrategyManager.sol";
import {IPumpUp} from "../src/interfaces/IPumpUp.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ExponentialBondingCurve} from "../src/bondingCurve/ExponentialBC.sol";

contract TestHelper is Test, Deployers {
    function deployProtocol() public {
        deployFreshManagerAndRouters();

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            )
        );
    }

    function deployPoolStateManager() internal {}

    function deployPumpUpHook() internal {}

    function deployBondingCurve() internal {}

    function depoyStrategyManager() internal {}
}
