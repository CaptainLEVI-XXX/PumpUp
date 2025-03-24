// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SuperAdmin2Step} from "../helpers/SuperAdmin2Step.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {exp, ln, intoUint256} from "@prb/math/src/UD60x18.sol";

import {IPoolStateManager} from "../interfaces/IPoolStateManager.sol";
import {IBondingCurveStrategy} from "../interfaces/IBondingCurveStrategy.sol";

/**
 * @title ExponentialBondingCurve
 * @notice Implements an exponential bonding curve for token trading with exact output support
 * @dev Optimized to compile without --via-ir flag
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
    string public constant STRATEGY_NAME = "Exponential";

    // Default parameters (can be overridden during initialization)
    uint256 public constant DEFAULT_INITIAL_PRICE = 0.4e18; // a = 0.4
    uint256 public constant DEFAULT_STEEPNESS = 0.000025e18; // b = 0.000025

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

    // ============ Errors ============

    error InvalidPoolId();
    error InvalidAmount();
    error InvalidParameters();
    error NotPoolStateManager();
    error InsufficientLiquidity();
    error PoolTransitioned();
    error CalculationFailed();

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
     * @notice Initializes the strategy for a new pool
     * @param poolId The ID of the pool
     * @param params The initialization parameters
     * @dev Expects encoded (initialPrice, steepness, maxPriceFactor, midpoint, totalSupply)
     */
    function initialize(bytes32 poolId, bytes calldata params) external override {
        // Only the pool state manager can initialize
        if (msg.sender != address(poolStateManager)) {
            revert NotPoolStateManager();
        }

        // Decode parameters - Use a more gas efficient way to extract what we need
        (
            uint256 initialPrice,
            uint256 steepness,
            , // maxPriceFactor not used
            , // midpoint not used
            uint256 totalSupply
        ) = abi.decode(params, (uint256, uint256, uint256, uint256, uint256));

        // Validate parameters
        if (totalSupply == 0) {
            revert InvalidParameters();
        }

        // Convert to UD60x18 format and store parameters
        curveParams[poolId] = CurveParameters({
            initialPrice: ud(initialPrice == 0 ? DEFAULT_INITIAL_PRICE : initialPrice),
            steepness: ud(steepness == 0 ? DEFAULT_STEEPNESS : steepness),
            totalSupply: totalSupply
        });

        emit StrategyInitialized(
            poolId,
            initialPrice == 0 ? DEFAULT_INITIAL_PRICE : initialPrice,
            steepness == 0 ? DEFAULT_STEEPNESS : steepness,
            totalSupply
        );
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

        // Get pool info and check pool status
        address tokenAddress;
        bool isTransitioned;
        {
            // Limit variable scope to reduce stack depth
            (
                tokenAddress,
                , // creator not used
                , // wethCollected not used
                , // lastPrice not used
                isTransitioned,
                // bondingCurveStrategy not used
            ) = poolStateManager.getPoolInfo(poolId);

            if (isTransitioned) revert PoolTransitioned();
        }

        // Get curve parameters
        CurveParameters memory params = curveParams[poolId];
        if (params.totalSupply == 0) revert InvalidPoolId();

        // Calculate circulating supply
        UD60x18 circulatingSupply;
        {
            uint256 heldByManager = IERC20(tokenAddress).balanceOf(address(poolStateManager));
            uint256 totalTokenSupply = IERC20(tokenAddress).totalSupply();
            circulatingSupply = ud(totalTokenSupply - heldByManager);
        }

        // Calculate tokens to receive
        UD60x18 wethAmountUD = ud(wethAmount);
        tokenAmount = _calculateBuyTokens(circulatingSupply, wethAmountUD, params);

        // Calculate new price after purchase
        newPrice = intoUint256(_calculatePrice(circulatingSupply.add(ud(tokenAmount)), params));

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

        // Get pool info and validate
        address tokenAddress;
        uint256 wethCollected;
        bool isTransitioned;
        {
            // Limit variable scope to reduce stack depth
            (
                tokenAddress,
                , // creator not used
                wethCollected,
                , // lastPrice not used
                isTransitioned,
                // bondingCurveStrategy not used
            ) = poolStateManager.getPoolInfo(poolId);

            if (isTransitioned) revert PoolTransitioned();
        }

        // Get curve parameters
        CurveParameters memory params = curveParams[poolId];
        if (params.totalSupply == 0) revert InvalidPoolId();

        // Calculate circulating supply
        UD60x18 circulatingSupply;
        {
            uint256 heldByManager = IERC20(tokenAddress).balanceOf(address(poolStateManager));
            uint256 totalTokenSupply = IERC20(tokenAddress).totalSupply();
            circulatingSupply = ud(totalTokenSupply - heldByManager);
        }

        // Check if selling more than available
        if (tokenAmount > intoUint256(circulatingSupply)) revert InvalidAmount();

        // Calculate WETH to return
        UD60x18 tokenAmountUD = ud(tokenAmount);
        UD60x18 wethToReturn = _calculateSellWeth(circulatingSupply, tokenAmountUD, params);

        // Check against available liquidity
        if (intoUint256(wethToReturn) > wethCollected) revert InsufficientLiquidity();

        // Calculate new price after sale
        UD60x18 newCirculatingSupply = circulatingSupply.sub(tokenAmountUD);
        newPrice = intoUint256(_calculatePrice(newCirculatingSupply, params));

        wethAmount = intoUint256(wethToReturn);

        emit TokensSold(poolId, tokenAmount, wethAmount, newPrice);
        return (wethAmount, newPrice);
    }

    /**
     * @notice NEW FUNCTION: Calculate WETH needed for exact token output
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

        // Get pool info and check pool status
        address tokenAddress;
        bool isTransitioned;
        {
            // Limit variable scope to reduce stack depth
            (
                tokenAddress,
                , // creator not used
                , // wethCollected not used
                , // lastPrice not used
                isTransitioned,
                // bondingCurveStrategy not used
            ) = poolStateManager.getPoolInfo(poolId);

            if (isTransitioned) revert PoolTransitioned();
        }

        // Get curve parameters
        CurveParameters memory params = curveParams[poolId];
        if (params.totalSupply == 0) revert InvalidPoolId();

        // Calculate circulating supply
        UD60x18 circulatingSupply;
        {
            uint256 heldByManager = IERC20(tokenAddress).balanceOf(address(poolStateManager));
            uint256 totalTokenSupply = IERC20(tokenAddress).totalSupply();
            circulatingSupply = ud(totalTokenSupply - heldByManager);
        }

        // Check if requested token amount is available
        UD60x18 maxAvailable = ud(params.totalSupply).sub(circulatingSupply);
        if (ud(exactTokenAmount).gt(maxAvailable)) revert InvalidAmount();

        // Calculate WETH needed using integral of price function
        UD60x18 totalSupplyUD = ud(params.totalSupply);

        // Calculate start and end percentages
        UD60x18 startPercentage = circulatingSupply.div(totalSupplyUD);
        UD60x18 endPercentage = circulatingSupply.add(ud(exactTokenAmount)).div(totalSupplyUD);

        // Calculate exp values
        UD60x18 expStart = exp(params.steepness.mul(startPercentage));
        UD60x18 expEnd = exp(params.steepness.mul(endPercentage));

        // Calculate area under the curve: (a/b) * (expEnd - expStart) * totalSupply * (exactTokenAmount/totalSupply)
        // This is the definite integral of the price function from startPercentage to endPercentage
        UD60x18 wethNeeded = params.initialPrice.div(params.steepness).mul(expEnd.sub(expStart)).mul(
            ud(exactTokenAmount)
        ).div(ud(params.totalSupply));

        wethAmount = intoUint256(wethNeeded);

        // Calculate new price after purchase
        newPrice = intoUint256(_calculatePrice(circulatingSupply.add(ud(exactTokenAmount)), params));

        emit ExactTokensCalculated(poolId, wethAmount, exactTokenAmount);
        return (wethAmount, newPrice);
    }

    /**
     * @notice NEW FUNCTION: Calculate tokens needed for exact WETH output
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
        address tokenAddress;
        uint256 wethCollected;
        bool isTransitioned;
        {
            // Limit variable scope to reduce stack depth
            (
                tokenAddress,
                , // creator not used
                wethCollected,
                , // lastPrice not used
                isTransitioned,
                // bondingCurveStrategy not used
            ) = poolStateManager.getPoolInfo(poolId);

            if (isTransitioned) revert PoolTransitioned();
        }

        // Verify we have enough WETH liquidity
        if (exactWethAmount > wethCollected) revert InsufficientLiquidity();

        // Get curve parameters
        CurveParameters memory params = curveParams[poolId];
        if (params.totalSupply == 0) revert InvalidPoolId();

        // Calculate circulating supply
        UD60x18 circulatingSupply;
        {
            uint256 heldByManager = IERC20(tokenAddress).balanceOf(address(poolStateManager));
            uint256 totalTokenSupply = IERC20(tokenAddress).totalSupply();
            circulatingSupply = ud(totalTokenSupply - heldByManager);
        }

        // We need to solve the inverse problem:
        // Given exactWethAmount, solve for tokenAmount where:
        // exactWethAmount = _calculateSellWeth(circulatingSupply, tokenAmount, params)

        // We'll use a binary search to find the answer since we can't directly solve this equation
        UD60x18 minTokens = ud(0);
        UD60x18 maxTokens = circulatingSupply; // Can't sell more than circulating supply
        UD60x18 targetWeth = ud(exactWethAmount);
        UD60x18 tokensToSell;

        // Use binary search with 8 iterations for precision
        for (uint8 i = 0; i < 8; i++) {
            // Calculate midpoint
            tokensToSell = minTokens.add(maxTokens.sub(minTokens).div(ud(2)));

            // Skip if too small
            if (intoUint256(tokensToSell) == 0) break;

            // Calculate WETH output for this amount of tokens
            UD60x18 wethOutput = _calculateSellWeth(circulatingSupply, tokensToSell, params);

            // If we're within 0.1% of the target, this is good enough
            if (
                wethOutput.mul(ud(999)).div(ud(1000)).lte(targetWeth)
                    && wethOutput.mul(ud(1001)).div(ud(1000)).gte(targetWeth)
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

        tokenAmount = intoUint256(tokensToSell);

        // Check if tokenAmount is valid
        if (tokenAmount == 0 || tokenAmount > intoUint256(circulatingSupply)) {
            revert CalculationFailed();
        }

        // Calculate new price after sale
        UD60x18 newCirculatingSupply = circulatingSupply.sub(ud(tokenAmount));
        newPrice = intoUint256(_calculatePrice(newCirculatingSupply, params));

        emit ExactWethCalculated(poolId, tokenAmount, exactWethAmount);
        return (tokenAmount, newPrice);
    }

    /**
     * @notice Gets the current token price based on circulating supply
     * @param poolId The ID of the pool
     * @return Current price of the token
     */
    function getCurrentPrice(bytes32 poolId) external view override returns (uint256) {
        bool isTransitioned;
        uint256 lastPrice;
        address tokenAddress;

        {
            (
                tokenAddress,
                , // creator not used
                , // wethCollected not used
                lastPrice,
                isTransitioned,
                // bondingCurveStrategy not used
            ) = poolStateManager.getPoolInfo(poolId);

            if (isTransitioned) return lastPrice;
        }

        CurveParameters memory params = curveParams[poolId];
        if (params.totalSupply == 0) revert InvalidPoolId();

        // Calculate circulating supply
        uint256 heldByManager = IERC20(tokenAddress).balanceOf(address(poolStateManager));
        uint256 totalTokenSupply = IERC20(tokenAddress).totalSupply();
        UD60x18 circulatingSupply = ud(totalTokenSupply - heldByManager);

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
     * @notice Calculate WETH amount for selling tokens
     * @param currentSupply Current circulating supply
     * @param tokenAmount Token amount to sell
     * @param params Curve parameters
     * @return wethAmount WETH amount to receive
     */
    function _calculateSellWeth(UD60x18 currentSupply, UD60x18 tokenAmount, CurveParameters memory params)
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

        // Calculate area: (a/b) * (expStart - expEnd) * tokenAmount
        return params.initialPrice.div(params.steepness).mul(expStart.sub(expEnd)).mul(tokenAmount).div(totalSupplyUD);
    }

    /**
     * @notice Calculate token amount for buying with WETH
     * @param currentSupply Current circulating supply
     * @param wethAmount WETH amount to spend
     * @param params Curve parameters
     * @return tokenAmount Token amount to receive
     */
    function _calculateBuyTokens(UD60x18 currentSupply, UD60x18 wethAmount, CurveParameters memory params)
        internal
        pure
        returns (uint256)
    {
        // Handle edge cases
        if (intoUint256(wethAmount) == 0) return 0;

        // Calculate current price and use approximation
        UD60x18 currentPrice = _calculatePrice(currentSupply, params);

        // Estimate initial tokens - use 110% of current price to account for price increase
        UD60x18 estimatedPrice = currentPrice.mul(ud(11e17)).div(ud(1e18));
        UD60x18 initialEstimate = wethAmount.div(estimatedPrice);

        // Limit to available supply
        UD60x18 maxAvailable = ud(params.totalSupply).sub(currentSupply);
        if (initialEstimate.gt(maxAvailable)) {
            initialEstimate = maxAvailable;
        }

        return intoUint256(initialEstimate);
    }
}
