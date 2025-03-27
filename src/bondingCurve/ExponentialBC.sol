// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SuperAdmin2Step} from "../helpers/SuperAdmin2Step.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {exp, ln, intoUint256} from "@prb/math/src/UD60x18.sol";

import {IPoolStateManager} from "../interfaces/IPoolStateManager.sol";
import {IBondingCurveStrategy} from "../interfaces/IBondingCurveStrategy.sol";
import {console} from "forge-std/console.sol";

/**
 * @title ImprovedExponentialBondingCurve
 * @notice Implements an exponential bonding curve for token trading with improved precision handling
 */
contract ExponentialBondingCurve is IBondingCurveStrategy, SuperAdmin2Step {
    using CustomRevert for bytes4;

    // ============ Structs ============

    struct CurveParameters {
        UD60x18 initialPrice; // Coefficient 'a' in the formula a * e^(b * y)
        UD60x18 steepness; // Coefficient 'b' in the formula
        uint256 totalSupply; // Total token supply for reference
    }

    // ============ Constants ============

    string public constant STRATEGY_TYPE = "BondingCurve";
    string public constant STRATEGY_NAME = "ImprovedExponential";

    // Default parameters (adjusted for better precision)
    uint256 public constant DEFAULT_INITIAL_PRICE = 0.0001e18; // Lower initial price (0.0001 WETH per token)
    uint256 public constant DEFAULT_STEEPNESS = 0.00001e18; // Less steep curve for smoother price progression

    // Minimum purchase to prevent dust attacks, set to a very small value (e.g., 0.000001 tokens)
    uint256 public constant MIN_TOKEN_PURCHASE = 1e12; // 0.000001 tokens (assuming 18 decimals)

    // ============ State Variables ============

    // The pool state manager contract
    IPoolStateManager public poolStateManager;

    // Curve parameters for each pool
    mapping(bytes32 => CurveParameters) public curveParams;

    // ============ Events ============

    event StrategyInitialized(bytes32 indexed poolId, uint256 initialPrice, uint256 steepness, uint256 totalSupply);
    event TokensPurchased(bytes32 indexed poolId, uint256 wethAmount, uint256 tokenAmount, uint256 newPrice);
    event TokensSold(bytes32 indexed poolId, uint256 tokenAmount, uint256 wethAmount, uint256 newPrice);
    event ExactTokensCalculated(bytes32 indexed poolId, uint256 wethAmount, uint256 tokenAmount);
    event ExactWethCalculated(bytes32 indexed poolId, uint256 tokenAmount, uint256 wethAmount);
    event InitialDeposit(bytes32 indexed poolId, uint256 wethDeposit, uint256 initialTokenAmount, uint256 initialPrice);

    // ============ Errors ============

    error InvalidPoolId();
    error InvalidAmount();
    error InvalidParameters();
    error NotPoolStateManager();
    error InsufficientLiquidity();
    error PoolTransitioned();
    error CalculationFailed();
    error AmountTooSmall();

    // ============ Constructor ============

    constructor(address _poolStateManager, address _admin) {
        poolStateManager = IPoolStateManager(_poolStateManager);
        _setSuperAdmin(_admin);
    }

    // ============ External Functions ============

    /**
     * @notice Returns the strategy type identifier
     * @return The strategy type as a string
     */
    function strategyType() external pure override returns (string memory) {
        return STRATEGY_TYPE;
    }

    /**
     * @notice Returns the strategy name
     * @return The strategy name as a string
     */
    function name() external pure override returns (string memory) {
        return STRATEGY_NAME;
    }

    /**
     * @notice Initializes the strategy for a new pool with initial price based on WETH deposit
     * @param poolId The ID of the pool
     * @param params The initialization parameters
     * @dev Expects encoded (initialWethDeposit, initialTokenAmount, steepness, wethPriceUSD, totalSupply)
     */
    function initialize(bytes32 poolId, bytes calldata params) external override {
        // Only the pool state manager can initialize
        if (msg.sender != address(poolStateManager)) {
            revert NotPoolStateManager();
        }

        // Decode parameters
        (
            uint256 initialWethDeposit, // Amount of WETH deposited to create the pool
            uint256 initialTokenAmount, // Initial token amount to be sold/distributed
            uint256 steepness, // Steepness factor 'b'
            uint256 wethPriceUSD, // Current WETH price in USD (optional)
            uint256 totalSupply // Total token supply
        ) = abi.decode(params, (uint256, uint256, uint256, uint256, uint256));

        // Validate parameters
        if (initialWethDeposit == 0 || initialTokenAmount == 0 || totalSupply == 0) {
            revert InvalidParameters();
        }

        // Calculate initial price 'a' based on WETH deposit and initial tokens
        // This represents how much 1 token costs in WETH at the very beginning
        UD60x18 initialPrice = ud(initialWethDeposit).div(ud(initialTokenAmount));

        // Ensure steepness is reasonable - use default if too low or not provided
        UD60x18 curvesteepness = steepness == 0 ? ud(DEFAULT_STEEPNESS) : ud(steepness);

        // Log initialization parameters
        // console.log("Initializing pool with parameters:");
        // console.log("- Initial WETH deposit:", initialWethDeposit);
        // console.log("- Initial token amount:", initialTokenAmount);
        // console.log("- Initial price (WETH per token):", intoUint256(initialPrice));
        // console.log("- Steepness:", intoUint256(curvesteepness));
        // console.log("- Total supply:", totalSupply);

        // Store the curve parameters
        curveParams[poolId] =
            CurveParameters({initialPrice: initialPrice, steepness: curvesteepness, totalSupply: totalSupply});

        emit StrategyInitialized(poolId, intoUint256(initialPrice), intoUint256(curvesteepness), totalSupply);

        emit InitialDeposit(poolId, initialWethDeposit, initialTokenAmount, intoUint256(initialPrice));
    }

    /**
     * @notice Calculates token amount to receive for a given WETH amount
     * @param poolId The ID of the pool
     * @param wethAmount Amount of WETH to spend
     * @return tokenAmount Amount of tokens to receive
     * @return newPrice New token price after the purchase
     */
    function calculateBuy(bytes32 poolId, uint256 wethAmount)
        external
        override
        returns (uint256 tokenAmount, uint256 newPrice)
    {
        // Check inputs first
        if (wethAmount == 0) revert InvalidAmount();

        // Get pool info
        (
            address tokenAddress,
            address bondingCurveImplementation,
            uint256 currentCirculatingSupply,
            uint256 currentWethCollected,
            uint256 currentPrice
        ) = poolStateManager.getInfoForHook(poolId);

        // Get curve parameters
        CurveParameters memory params = curveParams[poolId];
        if (params.totalSupply == 0) revert InvalidPoolId();

        // Calculate circulating supply
        UD60x18 circulatingSupply = ud(currentCirculatingSupply);

        // Calculate current price
        UD60x18 curPrice = _calculatePrice(circulatingSupply, params);
        // console.log("Current price (WETH per token):", intoUint256(curPrice));

        // If WETH amount is very small, use direct price calculation for better precision
        if (wethAmount < 0.001e18) {
            // For very small purchases, calculate based on current price with small buffer
            UD60x18 wethAmountUD = ud(wethAmount);
            UD60x18 bufferPrice = curPrice.mul(ud(1.02e18)).div(ud(1e18)); // 2% buffer
            UD60x18 tokensToReturn = wethAmountUD.div(bufferPrice);

            // Ensure minimum purchase
            tokenAmount = intoUint256(tokensToReturn);
            if (tokenAmount < MIN_TOKEN_PURCHASE && tokenAmount > 0) {
                tokenAmount = MIN_TOKEN_PURCHASE;
            }

            // Verify against available supply
            uint256 availableSupply = params.totalSupply - intoUint256(circulatingSupply);
            if (tokenAmount > availableSupply) {
                tokenAmount = availableSupply;
            }
        } else {
            // For larger purchases, use the integral method for better accuracy
            tokenAmount = _calculateBuyTokensIntegral(circulatingSupply, ud(wethAmount), params);
        }

        // console.log("WETH amount:", wethAmount);
        // console.log("Calculated token amount:", tokenAmount);

        // Ensure we're returning at least some tokens if the purchase amount is non-zero
        if (tokenAmount == 0 && wethAmount > 0) {
            // If calculation resulted in zero but WETH is non-zero, return minimum amount
            tokenAmount = MIN_TOKEN_PURCHASE;
            // console.log("Adjusted to minimum token amount:", tokenAmount);
        }

        // Calculate new price after purchase
        UD60x18 newCirculatingSupply = circulatingSupply.add(ud(tokenAmount));
        newPrice = intoUint256(_calculatePrice(newCirculatingSupply, params));
        // console.log("New price after purchase:", newPrice);

        emit TokensPurchased(poolId, wethAmount, tokenAmount, newPrice);
        return (tokenAmount, newPrice);
    }

    /**
     * @notice Calculates WETH amount to receive for a given token amount
     * @param poolId The ID of the pool
     * @param tokenAmount Amount of tokens to sell
     * @return wethAmount Amount of WETH to receive
     * @return newPrice New token price after the sale
     */
    function calculateSell(bytes32 poolId, uint256 tokenAmount)
        external
        override
        returns (uint256 wethAmount, uint256 newPrice)
    {
        // Check inputs first
        if (tokenAmount == 0) revert InvalidAmount();
        if (tokenAmount < MIN_TOKEN_PURCHASE) revert AmountTooSmall();

        // Get pool info and validate
        (
            address tokenAddress,
            address bondingCurveImplementation,
            uint256 currentCirculatingSupply,
            uint256 currentWethCollected,
            uint256 currentPrice
        ) = poolStateManager.getInfoForHook(poolId);

        // Get curve parameters
        CurveParameters memory params = curveParams[poolId];
        if (params.totalSupply == 0) revert InvalidPoolId();

        // Calculate circulating supply
        UD60x18 circulatingSupply = ud(currentCirculatingSupply);

        // Check if selling more than available
        if (tokenAmount > intoUint256(circulatingSupply)) revert InvalidAmount();

        // Calculate WETH to return using integral method
        UD60x18 wethToReturn = _calculateSellWethIntegral(circulatingSupply, ud(tokenAmount), params);

        // Check against available liquidity
        if (intoUint256(wethToReturn) > currentWethCollected) revert InsufficientLiquidity();

        // Calculate new price after sale
        UD60x18 newCirculatingSupply = circulatingSupply.sub(ud(tokenAmount));
        newPrice = intoUint256(_calculatePrice(newCirculatingSupply, params));

        wethAmount = intoUint256(wethToReturn);

        // console.log("Token amount to sell:", tokenAmount);
        // console.log("Calculated WETH return:", wethAmount);
        // console.log("New price after sale:", newPrice);

        emit TokensSold(poolId, tokenAmount, wethAmount, newPrice);
        return (wethAmount, newPrice);
    }

    /**
     * @notice Calculate WETH needed for exact token output
     * @param poolId The ID of the pool
     * @param exactTokenAmount Exact amount of tokens the user wants to receive
     * @return wethAmount Amount of WETH needed to spend
     * @return newPrice New token price after the purchase
     */
    function calculateWethForExactTokens(bytes32 poolId, uint256 exactTokenAmount)
        external
        returns (uint256 wethAmount, uint256 newPrice)
    {
        // Check inputs first
        if (exactTokenAmount == 0) revert InvalidAmount();
        if (exactTokenAmount < MIN_TOKEN_PURCHASE) revert AmountTooSmall();

        // Get pool info
        (
            address tokenAddress,
            address bondingCurveImplementation,
            uint256 currentCirculatingSupply,
            uint256 currentWethCollected,
            uint256 currentPrice
        ) = poolStateManager.getInfoForHook(poolId);

        // Get curve parameters
        CurveParameters memory params = curveParams[poolId];
        if (params.totalSupply == 0) revert InvalidPoolId();

        // Calculate circulating supply
        UD60x18 circulatingSupply = ud(currentCirculatingSupply);

        // Check if requested token amount is available
        uint256 availableSupply = params.totalSupply - intoUint256(circulatingSupply);
        if (exactTokenAmount > availableSupply) revert InvalidAmount();

        // Calculate WETH needed using integral of price function
        UD60x18 totalSupplyUD = ud(params.totalSupply);

        // Calculate start and end percentages
        UD60x18 startPercentage = circulatingSupply.div(totalSupplyUD);
        UD60x18 endPercentage = circulatingSupply.add(ud(exactTokenAmount)).div(totalSupplyUD);

        // Calculate exp values
        UD60x18 expStart = exp(params.steepness.mul(startPercentage));
        UD60x18 expEnd = exp(params.steepness.mul(endPercentage));

        // Calculate area under the curve: (a/b) * (expEnd - expStart) * totalSupply * (exactTokenAmount/totalSupply)
        UD60x18 wethNeeded = params.initialPrice.div(params.steepness).mul(expEnd.sub(expStart));

        // Scale by token ratio for better precision
        wethNeeded = wethNeeded.mul(ud(exactTokenAmount)).div(totalSupplyUD);

        wethAmount = intoUint256(wethNeeded);

        // Calculate new price after purchase
        newPrice = intoUint256(_calculatePrice(circulatingSupply.add(ud(exactTokenAmount)), params));

        // console.log("Exact token amount requested:", exactTokenAmount);
        // console.log("WETH needed:", wethAmount);
        // console.log("New price after purchase:", newPrice);

        emit ExactTokensCalculated(poolId, wethAmount, exactTokenAmount);
        return (wethAmount, newPrice);
    }

    /**
     * @notice Calculate tokens needed for exact WETH output
     * @param poolId The ID of the pool
     * @param exactWethAmount Exact amount of WETH the user wants to receive
     * @return tokenAmount Amount of tokens needed to sell
     * @return newPrice New token price after the sale
     */
    function calculateTokensForExactWeth(bytes32 poolId, uint256 exactWethAmount)
        external
        returns (uint256 tokenAmount, uint256 newPrice)
    {
        // Check inputs first
        if (exactWethAmount == 0) revert InvalidAmount();

        // Get pool info and validate
        (
            address tokenAddress,
            address bondingCurveImplementation,
            uint256 currentCirculatingSupply,
            uint256 currentWethCollected,
            uint256 currentPrice
        ) = poolStateManager.getInfoForHook(poolId);

        // Verify we have enough WETH liquidity
        if (exactWethAmount > currentWethCollected) revert InsufficientLiquidity();

        // Get curve parameters
        CurveParameters memory params = curveParams[poolId];
        if (params.totalSupply == 0) revert InvalidPoolId();

        // Calculate circulating supply
        UD60x18 circulatingSupply = ud(currentCirculatingSupply);

        // Use binary search with more iterations for better precision
        UD60x18 minTokens = ud(MIN_TOKEN_PURCHASE);
        UD60x18 maxTokens = circulatingSupply; // Can't sell more than circulating supply
        UD60x18 targetWeth = ud(exactWethAmount);
        UD60x18 tokensToSell = ud(0);
        UD60x18 wethOutput = ud(0);

        // Use binary search with more iterations for better precision
        for (uint8 i = 0; i < 16; i++) {
            // Calculate midpoint
            tokensToSell = minTokens.add(maxTokens.sub(minTokens).div(ud(2)));

            // Calculate WETH output for this amount of tokens
            wethOutput = _calculateSellWethIntegral(circulatingSupply, tokensToSell, params);

            // If we're within 0.05% of the target, this is good enough
            if (
                wethOutput.mul(ud(9995)).div(ud(10000)).lte(targetWeth)
                    && wethOutput.mul(ud(10005)).div(ud(10000)).gte(targetWeth)
            ) {
                break;
            }

            // Adjust our search range
            if (wethOutput.lt(targetWeth)) {
                // Need to sell more tokens
                minTokens = tokensToSell;
            } else {
                // Need to sell fewer tokens
                maxTokens = tokensToSell;
            }
        }

        // After binary search, make a final adjustment if needed
        if (wethOutput.lt(targetWeth)) {
            // Increase tokens slightly to ensure we meet or exceed target WETH
            tokensToSell = tokensToSell.mul(ud(1005)).div(ud(1000)); // Add 0.5%
        }

        tokenAmount = intoUint256(tokensToSell);

        // Ensure minimum token amount
        if (tokenAmount < MIN_TOKEN_PURCHASE) {
            tokenAmount = MIN_TOKEN_PURCHASE;
        }

        // Check if tokenAmount is valid and within available supply
        if (tokenAmount > intoUint256(circulatingSupply)) {
            tokenAmount = intoUint256(circulatingSupply);
        }

        // Calculate new price after sale
        UD60x18 newCirculatingSupply = circulatingSupply.sub(ud(tokenAmount));
        newPrice = intoUint256(_calculatePrice(newCirculatingSupply, params));

        // console.log("Exact WETH amount requested:", exactWethAmount);
        // console.log("Tokens needed to sell:", tokenAmount);
        // console.log("WETH output from calculation:", intoUint256(wethOutput));
        // console.log("New price after sale:", newPrice);

        emit ExactWethCalculated(poolId, tokenAmount, exactWethAmount);
        return (tokenAmount, newPrice);
    }

    /**
     * @notice Gets the current token price based on circulating supply
     * @param poolId The ID of the pool
     * @return Current price of the token
     */
    function getCurrentPrice(bytes32 poolId) external view override returns (uint256) {
        (
            address tokenAddress,
            address bondingCurveImplementation,
            uint256 currentCirculatingSupply,
            uint256 currentWethCollected,
            uint256 currentPrice
        ) = poolStateManager.getInfoForHook(poolId);

        CurveParameters memory params = curveParams[poolId];
        if (params.totalSupply == 0) revert InvalidPoolId();

        // Calculate price based on current circulating supply
        UD60x18 circulatingSupply = ud(currentCirculatingSupply);
        return intoUint256(_calculatePrice(circulatingSupply, params));
    }

    /**
     * @notice Update the pool state manager address (only admin)
     * @param _poolStateManager New pool state manager address
     */
    function setPoolStateManager(address _poolStateManager) external onlySuperAdmin {
        poolStateManager = IPoolStateManager(_poolStateManager);
    }

    // ============ Internal Functions ============

    /**
     * @notice Calculate price based on exponential curve
     * @param supply Current circulating supply
     * @param params Curve parameters
     * @return price Token price
     */
    function _calculatePrice(UD60x18 supply, CurveParameters memory params) internal pure returns (UD60x18) {
        if (intoUint256(supply) == 0) {
            return params.initialPrice;
        }

        // Calculate price = a * e^(b * percentageSold)
        UD60x18 percentageSold = supply.div(ud(params.totalSupply));
        return params.initialPrice.mul(exp(params.steepness.mul(percentageSold)));
    }

    /**
     * @notice Calculate WETH amount for selling tokens using integral method
     * @param currentSupply Current circulating supply
     * @param tokenAmount Token amount to sell
     * @param params Curve parameters
     * @return wethAmount WETH amount to receive
     */
    function _calculateSellWethIntegral(UD60x18 currentSupply, UD60x18 tokenAmount, CurveParameters memory params)
        internal
        pure
        returns (UD60x18)
    {
        // Handle edge cases
        if (intoUint256(tokenAmount) == 0) return ud(0);
        if (intoUint256(currentSupply) == 0) return ud(0);

        UD60x18 totalSupplyUD = ud(params.totalSupply);

        // Calculate start and end percentages
        UD60x18 startPercentage = currentSupply.div(totalSupplyUD);
        UD60x18 endPercentage = currentSupply.sub(tokenAmount).div(totalSupplyUD);

        // Calculate exp values
        UD60x18 expStart = exp(params.steepness.mul(startPercentage));
        UD60x18 expEnd = exp(params.steepness.mul(endPercentage));

        // Calculate area under the curve
        return params.initialPrice.div(params.steepness).mul(expStart.sub(expEnd)).mul(tokenAmount).div(totalSupplyUD);
    }

    /**
     * @notice Calculate token amount for buying with WETH using integral method
     * @param currentSupply Current circulating supply
     * @param wethAmount WETH amount to spend
     * @param params Curve parameters
     * @return tokenAmount Token amount to receive
     */
    function _calculateBuyTokensIntegral(UD60x18 currentSupply, UD60x18 wethAmount, CurveParameters memory params)
        internal
        pure
        returns (uint256)
    {
        // Handle edge cases
        if (intoUint256(wethAmount) == 0) return 0;

        // Available supply check
        UD60x18 maxAvailable = ud(params.totalSupply).sub(currentSupply);
        if (intoUint256(maxAvailable) == 0) return 0;

        UD60x18 totalSupplyUD = ud(params.totalSupply);
        UD60x18 currentPercentage = currentSupply.div(totalSupplyUD);

        // Calculate target percentage using binary search
        UD60x18 minPercentage = currentPercentage;
        UD60x18 maxPercentage = ud(1); // 100%
        UD60x18 targetPercentage = minPercentage;

        // Use binary search to find the target percentage
        for (uint8 i = 0; i < 16; i++) {
            targetPercentage = minPercentage.add(maxPercentage.sub(minPercentage).div(ud(2)));

            // Calculate the area under the curve for this percentage range
            UD60x18 expStart = exp(params.steepness.mul(currentPercentage));
            UD60x18 expEnd = exp(params.steepness.mul(targetPercentage));

            // Calculate WETH needed for this percentage change
            UD60x18 wethNeeded = params.initialPrice.div(params.steepness).mul(expEnd.sub(expStart)).mul(
                targetPercentage.sub(currentPercentage).mul(totalSupplyUD)
            );

            // Adjust search range
            if (wethNeeded.lt(wethAmount)) {
                minPercentage = targetPercentage;
            } else {
                maxPercentage = targetPercentage;
            }

            // If we're close enough, break
            if (
                wethNeeded.mul(ud(995)).div(ud(1000)).lte(wethAmount)
                    && wethNeeded.mul(ud(1005)).div(ud(1000)).gte(wethAmount)
            ) {
                break;
            }
        }

        // Calculate token amount based on the found percentage
        UD60x18 tokenAmount = (targetPercentage.sub(currentPercentage)).mul(totalSupplyUD);

        // Limit to available supply
        if (tokenAmount.gt(maxAvailable)) {
            tokenAmount = maxAvailable;
        }

        // Convert to uint256
        uint256 result = intoUint256(tokenAmount);

        // Ensure minimum token amount if non-zero
        if (result == 0 && intoUint256(wethAmount) > 0 && intoUint256(maxAvailable) > 0) {
            result = MIN_TOKEN_PURCHASE;
        }

        return result;
    }
}
