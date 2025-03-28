//!
//! Sigmoid Bonding Curve for Arbitrum Stylus
//!

#![cfg_attr(not(feature = "export-abi"), no_main)]
extern crate alloc;

use alloc::{string::String, vec, vec::Vec};
use alloy_primitives::{Address, B256, U256};
use stylus_sdk::{abi::Bytes, call::RawCall, evm, msg, prelude::*};

// Constants for curve parameters
const STRATEGY_TYPE: &str = "BondingCurve";
const STRATEGY_NAME: &str = "Sigmoid";

// Default parameters (scaled by 10^18)
const DEFAULT_MAX_PRICE_FACTOR: U256 = U256::from_limbs([10_000_000_000_000_000_000u64, 0, 0, 0]); // 10.0
const DEFAULT_STEEPNESS: U256 = U256::from_limbs([10_000_000_000_000_000_000u64, 0, 0, 0]); // 10.0
const DEFAULT_MIDPOINT: U256 = U256::from_limbs([500_000_000_000_000_000u64, 0, 0, 0]); // 0.5 (50%)

// Scaling factor for fixed-point math (10^18)
const SCALE_FACTOR: U256 = U256::from_limbs([1_000_000_000_000_000_000u64, 0, 0, 0]);
const TWO: U256 = U256::from_limbs([2u64, 0, 0, 0]);
const THOUSAND: U256 = U256::from_limbs([1000u64, 0, 0, 0]);
const MILLION: U256 = U256::from_limbs([1_000_000u64, 0, 0, 0]);

// Storage structure for curve parameters
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub struct CurveParameters {
    pub initial_price: U256,
    pub max_price_factor: U256,
    pub steepness: U256,
    pub midpoint: U256,
    pub total_supply: U256,
}

// Define storage using sol_storage! macro as in the examples
sol_storage! {
    #[entrypoint]
    pub struct SigmoidBondingCurve {
        // Admin management
        address owner;

        // Pool state manager
        address pool_state_manager;

        // Curve parameters for each pool
        mapping(bytes32 => uint256) initial_prices;
        mapping(bytes32 => uint256) max_price_factors;
        mapping(bytes32 => uint256) steepness_values;
        mapping(bytes32 => uint256) midpoints;
        mapping(bytes32 => uint256) total_supplies;
    }
}

// Implementation with public keyword instead of external
#[public]
impl SigmoidBondingCurve {
    pub fn constructor(&mut self, pool_state_manager: Address) {
        self.owner.set(msg::sender());
        self.pool_state_manager.set(pool_state_manager);
    }

    // Strategy type identifier
    pub fn strategy_type(&self) -> String {
        STRATEGY_TYPE.into()
    }

    // Strategy name
    pub fn name(&self) -> String {
        STRATEGY_NAME.into()
    }

    // Initialize the strategy for a new pool
    pub fn initialize(&mut self, pool_id: B256, params: Bytes) -> Result<(), Vec<u8>> {
        // Only pool state manager can initialize
        if msg::sender() != *self.owner {
            return Err(Vec::<u8>::from("Not Pool State Manager"));
        }

        let params_bytes = params.0;

        // Parse parameters - assuming 5 U256 values packed in sequence
        if params_bytes.len() < 160 {
            // 5 * 32 bytes
            return Err(Vec::<u8>::from("Invalid Parameters - not enough data"));
        }

        // Extract U256 values from byte array
        let initial_price = extract_u256_from_bytes(&params_bytes, 0)?;
        let max_price_factor = extract_u256_from_bytes(&params_bytes, 32)?;
        let steepness = extract_u256_from_bytes(&params_bytes, 64)?;
        let midpoint = extract_u256_from_bytes(&params_bytes, 96)?;
        let total_supply = extract_u256_from_bytes(&params_bytes, 128)?;

        // Validate parameters
        if total_supply.is_zero() || initial_price.is_zero() {
            return Err(Vec::<u8>::from(
                "Invalid Parameters - zero values not allowed",
            ));
        }

        // Use default values if not provided
        let max_price_factor = if max_price_factor.is_zero() {
            DEFAULT_MAX_PRICE_FACTOR
        } else {
            max_price_factor
        };
        let steepness = if steepness.is_zero() {
            DEFAULT_STEEPNESS
        } else {
            steepness
        };
        let midpoint = if midpoint.is_zero() {
            DEFAULT_MIDPOINT
        } else {
            midpoint
        };

        // Store parameters using setters
        let mut initial_price_setter = self.initial_prices.setter(pool_id);
        initial_price_setter.set(initial_price);

        let mut max_price_factor_setter = self.max_price_factors.setter(pool_id);
        max_price_factor_setter.set(max_price_factor);

        let mut steepness_setter = self.steepness_values.setter(pool_id);
        steepness_setter.set(steepness);

        let mut midpoint_setter = self.midpoints.setter(pool_id);
        midpoint_setter.set(midpoint);

        let mut total_supply_setter = self.total_supplies.setter(pool_id);
        total_supply_setter.set(total_supply);

        // Emit event using raw_log, simplified
        let mut topics = Vec::new();
        let sig = [
            0x9b, 0xf7, 0xf4, 0xad, 0x1d, 0x0f, 0x9f, 0xa8, 0xaa, 0x5c, 0x45, 0x69, 0x13, 0xd7,
            0x2b, 0x51, 0x41, 0x0f, 0x35, 0xa7, 0xc4, 0xcd, 0xf7, 0x34, 0x94, 0xb7, 0xa8, 0x1b,
            0x53, 0x0d, 0x7e, 0x40,
        ];
        topics.push(B256::from_slice(&sig));
        topics.push(pool_id);

        let mut data = Vec::new();
        data.extend_from_slice(&initial_price.to_be_bytes::<32>());
        data.extend_from_slice(&max_price_factor.to_be_bytes::<32>());
        data.extend_from_slice(&steepness.to_be_bytes::<32>());
        data.extend_from_slice(&midpoint.to_be_bytes::<32>());
        data.extend_from_slice(&total_supply.to_be_bytes::<32>());

        evm::raw_log(&topics, &data);

        Ok(())
    }

    // Calculate token amount to receive for a given WETH amount
    pub fn calculate_buy(
        &mut self,
        pool_id: B256,
        weth_amount: U256,
    ) -> Result<(U256, U256), Vec<u8>> {
        // Get pool info
        let (
            token_address,
            _creator,
            _weth_collected,
            _last_price,
            is_transitioned,
            _bonding_curve_strategy,
        ) = self.get_pool_info(pool_id)?;

        if is_transitioned {
            return Err(Vec::<u8>::from("Pool has transitioned"));
        }

        if weth_amount.is_zero() {
            return Err(Vec::<u8>::from("Invalid Amount"));
        }

        // Get curve parameters
        let params = self.get_curve_params(pool_id)?;

        // Get current circulating supply
        let total_token_supply = self.call_total_supply(&token_address)?;
        let held_by_manager = self.call_balance_of(&token_address, *self.pool_state_manager)?;
        let circulating_supply = total_token_supply.saturating_sub(held_by_manager);

        // If no tokens have been sold yet, use a simpler calculation for the first buyer
        if circulating_supply.is_zero() {
            // For the first buyer, use the initial price directly
            let token_amount = self.divide_fixed_point(weth_amount, params.initial_price);
            let new_price = params.initial_price;

            // Emit event - Tokens Purchased
            let mut topics = Vec::new();
            let sig = [
                0xb5, 0x76, 0x4e, 0x7b, 0x82, 0xdd, 0x8f, 0x30, 0x19, 0x96, 0xd3, 0x71, 0x8c, 0xe0,
                0xa3, 0x43, 0xf4, 0x74, 0xc9, 0x37, 0x93, 0xa6, 0xd3, 0x83, 0xcb, 0x65, 0x6f, 0x91,
                0x78, 0x69, 0xaf, 0xcf,
            ];
            topics.push(B256::from_slice(&sig));
            topics.push(pool_id);

            let mut data = Vec::new();
            data.extend_from_slice(&weth_amount.to_be_bytes::<32>());
            data.extend_from_slice(&token_amount.to_be_bytes::<32>());
            data.extend_from_slice(&new_price.to_be_bytes::<32>());

            evm::raw_log(&topics, &data);

            return Ok((token_amount, new_price));
        }

        // Find token amount using binary search
        let token_amount =
            self.find_token_amount_for_weth(circulating_supply, weth_amount, &params, false);

        // Calculate new price after purchase
        let new_circulating_supply = circulating_supply + token_amount;
        let new_price = self.calculate_sigmoid_price(new_circulating_supply, &params);

        // Emit event - Tokens Purchased
        let mut topics = Vec::new();
        let sig = [
            0xb5, 0x76, 0x4e, 0x7b, 0x82, 0xdd, 0x8f, 0x30, 0x19, 0x96, 0xd3, 0x71, 0x8c, 0xe0,
            0xa3, 0x43, 0xf4, 0x74, 0xc9, 0x37, 0x93, 0xa6, 0xd3, 0x83, 0xcb, 0x65, 0x6f, 0x91,
            0x78, 0x69, 0xaf, 0xcf,
        ];
        topics.push(B256::from_slice(&sig));
        topics.push(pool_id);

        let mut data = Vec::new();
        data.extend_from_slice(&weth_amount.to_be_bytes::<32>());
        data.extend_from_slice(&token_amount.to_be_bytes::<32>());
        data.extend_from_slice(&new_price.to_be_bytes::<32>());

        evm::raw_log(&topics, &data);

        Ok((token_amount, new_price))
    }

    // Calculate WETH amount to receive for a given token amount
    pub fn calculate_sell(
        &mut self,
        pool_id: B256,
        token_amount: U256,
    ) -> Result<(U256, U256), Vec<u8>> {
        // Get pool info
        let (
            token_address,
            _creator,
            weth_collected,
            _last_price,
            is_transitioned,
            _bonding_curve_strategy,
        ) = self.get_pool_info(pool_id)?;

        if is_transitioned {
            return Err(Vec::<u8>::from("Pool has transitioned"));
        }

        if token_amount.is_zero() {
            return Err(Vec::<u8>::from("Invalid Amount"));
        }

        // Get curve parameters
        let params = self.get_curve_params(pool_id)?;

        // Get current circulating supply
        let total_token_supply = self.call_total_supply(&token_address)?;
        let held_by_manager = self.call_balance_of(&token_address, *self.pool_state_manager)?;
        let circulating_supply = total_token_supply.saturating_sub(held_by_manager);

        if token_amount > circulating_supply {
            return Err(Vec::<u8>::from("Invalid Amount"));
        }

        // Calculate WETH to return based on area under the curve
        let weth_to_return =
            self.calculate_weth_for_token_amount(circulating_supply, token_amount, &params, true);

        // Check against available liquidity
        if weth_to_return > weth_collected {
            return Err(Vec::<u8>::from("Insufficient Liquidity"));
        }

        // Calculate the new price after selling
        let new_circulating_supply = circulating_supply - token_amount;
        let new_price = self.calculate_sigmoid_price(new_circulating_supply, &params);

        // Emit event - Tokens Sold
        let mut topics = Vec::new();
        let sig = [
            0x6d, 0xfb, 0xff, 0xa4, 0x12, 0x55, 0xd2, 0x61, 0x0f, 0x46, 0xd2, 0x8a, 0x68, 0xf7,
            0xbb, 0xf0, 0xd3, 0xd0, 0x6a, 0xba, 0x0c, 0x73, 0x2c, 0x9a, 0xdb, 0x02, 0xa9, 0x1f,
            0x1b, 0xa5, 0xb7, 0x35,
        ];
        topics.push(B256::from_slice(&sig));
        topics.push(pool_id);

        let mut data = Vec::new();
        data.extend_from_slice(&token_amount.to_be_bytes::<32>());
        data.extend_from_slice(&weth_to_return.to_be_bytes::<32>());
        data.extend_from_slice(&new_price.to_be_bytes::<32>());

        evm::raw_log(&topics, &data);

        Ok((weth_to_return, new_price))
    }

    // Get current token price
    pub fn get_current_price(&self, pool_id: B256) -> Result<U256, Vec<u8>> {
        let (
            token_address,
            _creator,
            _weth_collected,
            last_price,
            is_transitioned,
            _bonding_curve_strategy,
        ) = self.get_pool_info(pool_id)?;

        if is_transitioned {
            return Ok(last_price);
        }

        let params = self.get_curve_params(pool_id)?;

        // Get current circulating supply
        let total_token_supply = self.call_total_supply(&token_address)?;
        let held_by_manager = self.call_balance_of(&token_address, *self.pool_state_manager)?;
        let circulating_supply = total_token_supply.saturating_sub(held_by_manager);

        // If no tokens have been sold yet, return the initial price
        if circulating_supply.is_zero() {
            return Ok(params.initial_price);
        }

        Ok(self.calculate_sigmoid_price(circulating_supply, &params))
    }

    // Calculate WETH needed for exact token amount
    pub fn calculate_weth_for_exact_tokens(
        &mut self,
        pool_id: B256,
        exact_token_amount: U256,
    ) -> Result<(U256, U256), Vec<u8>> {
        let (
            token_address,
            _creator,
            _weth_collected,
            _last_price,
            is_transitioned,
            _bonding_curve_strategy,
        ) = self.get_pool_info(pool_id)?;

        if is_transitioned {
            return Err(Vec::<u8>::from("Pool has transitioned"));
        }

        if exact_token_amount.is_zero() {
            return Err(Vec::<u8>::from("Invalid Amount"));
        }

        // Get curve parameters
        let params = self.get_curve_params(pool_id)?;

        // Get current circulating supply
        let total_token_supply = self.call_total_supply(&token_address)?;
        let held_by_manager = self.call_balance_of(&token_address, *self.pool_state_manager)?;
        let circulating_supply = total_token_supply.saturating_sub(held_by_manager);

        // Calculate WETH needed
        let weth_needed = self.calculate_weth_for_token_amount(
            circulating_supply,
            exact_token_amount,
            &params,
            false, // buying tokens
        );

        // Calculate new price
        let new_circulating_supply = circulating_supply + exact_token_amount;
        let new_price = self.calculate_sigmoid_price(new_circulating_supply, &params);

        Ok((weth_needed, new_price))
    }

    // Calculate tokens needed for exact WETH amount
    pub fn calculate_tokens_for_exact_weth(
        &mut self,
        pool_id: B256,
        exact_weth_amount: U256,
    ) -> Result<(U256, U256), Vec<u8>> {
        let (
            token_address,
            _creator,
            _weth_collected,
            _last_price,
            is_transitioned,
            _bonding_curve_strategy,
        ) = self.get_pool_info(pool_id)?;

        if is_transitioned {
            return Err(Vec::<u8>::from("Pool has transitioned"));
        }

        if exact_weth_amount.is_zero() {
            return Err(Vec::<u8>::from("Invalid Amount"));
        }

        // Get curve parameters
        let params = self.get_curve_params(pool_id)?;

        // Get current circulating supply
        let total_token_supply = self.call_total_supply(&token_address)?;
        let held_by_manager = self.call_balance_of(&token_address, *self.pool_state_manager)?;
        let circulating_supply = total_token_supply.saturating_sub(held_by_manager);

        // Calculate tokens needed using binary search
        let tokens_needed = self.find_token_amount_for_weth(
            circulating_supply,
            exact_weth_amount,
            &params,
            false, // buying tokens
        );

        // Calculate new price
        let new_circulating_supply = circulating_supply + tokens_needed;
        let new_price = self.calculate_sigmoid_price(new_circulating_supply, &params);

        Ok((tokens_needed, new_price))
    }

    // Get the contract owner
    pub fn owner(&self) -> Address {
        *self.owner
    }

    // Set pool state manager (only owner)
    pub fn set_pool_state_manager(
        &mut self,
        new_pool_state_manager: Address,
    ) -> Result<(), Vec<u8>> {
        self.only_owner()?;
        self.pool_state_manager.set(new_pool_state_manager);
        Ok(())
    }

    // Transfer ownership of the contract (only owner)
    pub fn transfer_ownership(&mut self, new_owner: Address) -> Result<(), Vec<u8>> {
        self.only_owner()?;

        if new_owner == Address::ZERO {
            return Err(Vec::<u8>::from("New owner cannot be the zero address"));
        }

        let previous_owner = *self.owner;
        self.owner.set(new_owner);

        // Emit event - Ownership Transferred
        let mut topics = Vec::new();
        let sig = [
            0x8b, 0xe0, 0x07, 0x9c, 0x53, 0x16, 0x59, 0x14, 0x13, 0x44, 0xcd, 0x1f, 0xd0, 0xa4,
            0xf2, 0x84, 0x19, 0x49, 0x7f, 0x97, 0x22, 0xa3, 0xda, 0xaf, 0xe3, 0xb4, 0x18, 0x6f,
            0x6b, 0x64, 0x57, 0xe0,
        ];
        topics.push(B256::from_slice(&sig));

        // Pad addresses to 32 bytes for topics
        let mut prev_owner_bytes = [0u8; 32];
        prev_owner_bytes[12..32].copy_from_slice(previous_owner.as_slice());
        topics.push(B256::from_slice(&prev_owner_bytes));

        let mut new_owner_bytes = [0u8; 32];
        new_owner_bytes[12..32].copy_from_slice(new_owner.as_slice());
        topics.push(B256::from_slice(&new_owner_bytes));

        evm::raw_log(&topics, &[]);

        Ok(())
    }
}

// Internal functions
impl SigmoidBondingCurve {
    // Helper function to get curve parameters from storage
    fn get_curve_params(&self, pool_id: B256) -> Result<CurveParameters, Vec<u8>> {
        let initial_price = self.initial_prices.get(pool_id);

        if initial_price.is_zero() {
            return Err(Vec::<u8>::from("Invalid Pool ID"));
        }

        Ok(CurveParameters {
            initial_price,
            max_price_factor: self.max_price_factors.get(pool_id),
            steepness: self.steepness_values.get(pool_id),
            midpoint: self.midpoints.get(pool_id),
            total_supply: self.total_supplies.get(pool_id),
        })
    }

    // Helper functions for ERC20 calls using RawCall
    fn call_total_supply(&self, token: &Address) -> Result<U256, Vec<u8>> {
        let selector = vec![0x18, 0x16, 0x0d, 0xdd]; // keccak256("totalSupply()")

        // Use call instead of static_call - just set read_only to true
        let result = RawCall::new()
            .call(*token, &selector)
            .map_err(|_| -> Vec<u8> { "ERC20 call failed".into() })?;

        // Parse U256 from the result
        if result.len() < 32 {
            return Err(Vec::<u8>::from("Invalid result length from ERC20 call"));
        }

        let mut bytes = [0u8; 32];
        bytes.copy_from_slice(&result[0..32]);
        Ok(U256::from_be_bytes::<32>(bytes))
    }

    fn call_balance_of(&self, token: &Address, account: Address) -> Result<U256, Vec<u8>> {
        // Create call data
        let mut call_data = Vec::with_capacity(36);
        // Function selector for balanceOf(address)
        call_data.extend_from_slice(&[0x70, 0xa0, 0x82, 0x31]); // keccak256("balanceOf(address)")
                                                                // Pad address to 32 bytes
        call_data.extend_from_slice(&[0; 12]);
        call_data.extend_from_slice(account.as_slice());

        // Use call instead of static_call - just set read_only to true
        let result = RawCall::new()
            .call(*token, &call_data)
            .map_err(|_| -> Vec<u8> { "ERC20 call failed".into() })?;

        // Parse U256 from the result
        if result.len() < 32 {
            return Err(Vec::<u8>::from("Invalid result length from ERC20 call"));
        }

        let mut bytes = [0u8; 32];
        bytes.copy_from_slice(&result[0..32]);
        Ok(U256::from_be_bytes::<32>(bytes))
    }

    // Get pool info from manager contract
    fn get_pool_info(
        &self,
        pool_id: B256,
    ) -> Result<(Address, Address, U256, U256, bool, B256), Vec<u8>> {
        // Create call data
        let mut call_data = Vec::with_capacity(36);
        // Function selector for getPoolInfo(bytes32)
        call_data.extend_from_slice(&[0x8e, 0xf3, 0xf2, 0x91]); // keccak256("getPoolInfo(bytes32)")
                                                                // Pool ID
        call_data.extend_from_slice(pool_id.as_slice());

        // Use call instead of static_call - just set read_only to true
        let result = RawCall::new()
            .call(*self.pool_state_manager, &call_data)
            .map_err(|_| -> Vec<u8> { "Pool state manager call failed".into() })?;

        // Result should be at least 6 * 32 bytes
        if result.len() < 192 {
            return Err(Vec::<u8>::from(
                "Invalid result length from pool state manager",
            ));
        }

        // Parse the result
        let token_address = Address::from_slice(&result[12..32]);
        let creator = Address::from_slice(&result[44..64]);

        let mut weth_bytes = [0u8; 32];
        weth_bytes.copy_from_slice(&result[64..96]);
        let weth_collected = U256::from_be_bytes::<32>(weth_bytes);

        let mut price_bytes = [0u8; 32];
        price_bytes.copy_from_slice(&result[96..128]);
        let last_price = U256::from_be_bytes::<32>(price_bytes);

        let is_transitioned = !result[127].eq(&0u8);
        let bonding_curve_strategy = B256::from_slice(&result[128..160]);

        Ok((
            token_address,
            creator,
            weth_collected,
            last_price,
            is_transitioned,
            bonding_curve_strategy,
        ))
    }

    // Calculate sigmoid price
    fn calculate_sigmoid_price(&self, supply: U256, params: &CurveParameters) -> U256 {
        if supply.is_zero() {
            return params.initial_price;
        }

        // Calculate percentage sold (normalized to 0-1)
        let percentage_sold = if params.total_supply.is_zero() {
            SCALE_FACTOR // 100% if total supply is zero (edge case)
        } else {
            // Multiply by SCALE_FACTOR for fixed-point division
            self.divide_fixed_point(supply.saturating_mul(SCALE_FACTOR), params.total_supply)
        };

        // Calculate max price from initial price and factor
        let max_price = self.multiply_fixed_point(params.initial_price, params.max_price_factor);

        // Calculate price range
        let price_range = max_price.saturating_sub(params.initial_price);

        // Check if percentage_sold is less than midpoint
        if percentage_sold < params.midpoint {
            // Percentage_sold < midpoint case
            let midpoint_diff = params.midpoint.saturating_sub(percentage_sold);
            let exponent_term = self.multiply_fixed_point(params.steepness, midpoint_diff);

            // Calculate e^(exponent_term) using approximation
            let exp_value = self.exp_approx(exponent_term);

            // Calculate denominator: 1 + e^(exponent_term)
            let denominator = SCALE_FACTOR.saturating_add(exp_value);

            // Calculate final price: initialPrice + priceRange / denominator
            params
                .initial_price
                .saturating_add(self.divide_fixed_point(price_range, denominator))
        } else {
            // Percentage_sold >= midpoint case
            let midpoint_diff = percentage_sold.saturating_sub(params.midpoint);
            let exponent_term = self.multiply_fixed_point(params.steepness, midpoint_diff);

            // Calculate e^(exponent_term)
            let exp_value = self.exp_approx(exponent_term);

            // Calculate denominator: (exp_value + 1) / exp_value = 1 + 1/exp_value
            // For numerical stability, use: 1 + exp_value^-1
            let denominator = if exp_value.is_zero() {
                // Handle divide by zero - rare case
                SCALE_FACTOR.saturating_mul(U256::from(1000u64)) // Large number
            } else {
                SCALE_FACTOR.saturating_add(self.divide_fixed_point(SCALE_FACTOR, exp_value))
            };

            // Calculate final price
            params
                .initial_price
                .saturating_add(self.divide_fixed_point(price_range, denominator))
        }
    }

    // Calculate WETH for token amount using trapezoid rule
    fn calculate_weth_for_token_amount(
        &self,
        current_supply: U256,
        token_amount: U256,
        params: &CurveParameters,
        is_selling: bool,
    ) -> U256 {
        // Calculate new supply based on operation
        let new_supply = if is_selling {
            current_supply.saturating_sub(token_amount)
        } else {
            current_supply.saturating_add(token_amount)
        };

        // Get prices at endpoints
        let start_price = self.calculate_sigmoid_price(current_supply, params);
        let end_price = self.calculate_sigmoid_price(new_supply, params);

        // Use trapezoid rule: (start_price + end_price) * token_amount / 2
        let sum_prices = start_price.saturating_add(end_price);
        self.multiply_fixed_point(sum_prices, token_amount) / TWO
    }

    // Find token amount for WETH using binary search
    fn find_token_amount_for_weth(
        &self,
        current_supply: U256,
        weth_amount: U256,
        params: &CurveParameters,
        is_selling: bool,
    ) -> U256 {
        let mut min_tokens = U256::ZERO;
        let mut max_tokens;

        if is_selling {
            max_tokens = current_supply; // Can't sell more than circulating supply
        } else {
            max_tokens = params.total_supply.saturating_sub(current_supply); // Can't buy more than remaining supply
        }

        // Set tolerance for comparison (0.001 * SCALE_FACTOR)
        let tolerance = SCALE_FACTOR / THOUSAND;

        // Limit iterations
        for _ in 0..100 {
            // Avoid divide by zero
            if max_tokens == min_tokens {
                return min_tokens;
            }

            let mid_tokens = min_tokens.saturating_add(max_tokens.saturating_sub(min_tokens) / TWO);

            // Calculate WETH for this many tokens
            let weth_needed = self.calculate_weth_for_token_amount(
                current_supply,
                mid_tokens,
                params,
                is_selling,
            );

            // Check if we're close enough
            let diff = if weth_needed >= weth_amount {
                weth_needed.saturating_sub(weth_amount)
            } else {
                weth_amount.saturating_sub(weth_needed)
            };

            if diff <= tolerance {
                return mid_tokens;
            }

            // Adjust search range
            if weth_needed < weth_amount {
                min_tokens = mid_tokens;
            } else {
                max_tokens = mid_tokens;
            }
        }

        // Return best approximation
        min_tokens
    }

    // Approximate exponential function using Taylor series
    fn exp_approx(&self, x: U256) -> U256 {
        // Handle the base case
        if x.is_zero() {
            return SCALE_FACTOR; // e^0 = 1
        }

        // For large values, return a large number to avoid overflow
        // This is a simplification - in a real implementation, you'd use a better approximation
        if x > U256::from(50u64).saturating_mul(SCALE_FACTOR) {
            return U256::MAX / TWO; // Very large number
        }

        let mut result = SCALE_FACTOR; // 1.0
        let mut term = SCALE_FACTOR; // Current term in series
        let mut factorial = U256::from(1u64);

        // Use Taylor series: 1 + x + x²/2! + x³/3! + ...
        for i in 1..15u64 {
            // Limit terms for performance
            factorial = factorial.saturating_mul(U256::from(i));

            // Calculate next term: x^i / i!
            // For numerical stability, we divide term by i at each step
            term = self.multiply_fixed_point(term, x) / U256::from(i);

            // Add to result
            result = result.saturating_add(term);

            // Early termination if term becomes very small
            if term < SCALE_FACTOR / MILLION {
                break;
            }
        }

        result
    }

    // Check if caller is the owner
    fn only_owner(&self) -> Result<(), Vec<u8>> {
        if msg::sender() != *self.owner {
            return Err(Vec::<u8>::from("Ownable: caller is not the owner"));
        }
        Ok(())
    }

    // Fixed point math helper functions
    fn multiply_fixed_point(&self, a: U256, b: U256) -> U256 {
        // To avoid overflow: (a * b) / SCALE_FACTOR
        // This implementation assumes a and b are already scaled by SCALE_FACTOR
        if a.is_zero() || b.is_zero() {
            return U256::ZERO;
        }

        // Check if the multiplication would overflow
        if a > U256::MAX / b {
            return U256::MAX; // Return max on overflow
        }

        a.saturating_mul(b) / SCALE_FACTOR
    }

    fn divide_fixed_point(&self, a: U256, b: U256) -> U256 {
        // To maintain precision: (a * SCALE_FACTOR) / b
        if b.is_zero() {
            return U256::ZERO; // Return 0 for division by zero
        }

        // Check if the multiplication would overflow
        if a > U256::MAX / SCALE_FACTOR {
            return a / b * SCALE_FACTOR; // Alternative calculation to avoid overflow
        }

        a.saturating_mul(SCALE_FACTOR) / b
    }
}

// Helper function to extract U256 from byte array
fn extract_u256_from_bytes(data: &[u8], offset: usize) -> Result<U256, Vec<u8>> {
    if data.len() < offset + 32 {
        return Err(Vec::<u8>::from("Insufficient data length"));
    }

    let mut bytes = [0u8; 32];
    bytes.copy_from_slice(&data[offset..offset + 32]);

    Ok(U256::from_be_bytes::<32>(bytes))
}
