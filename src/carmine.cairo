use starknet::{ContractAddress, get_block_timestamp};
use option::OptionTrait;
use traits::{TryInto, Into};
use array::ArrayTrait;
use debug::PrintTrait;

use hoil::constants::{AMM_ADDR, TOKEN_ETH_ADDRESS, TOKEN_USDC_ADDRESS, TOKEN_STRK_ADDRESS};
use hoil::helpers::{convert_from_Fixed_to_int, convert_from_int_to_Fixed};
use hoil::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use hoil::errors::Errors;

use cubit::f128::types::fixed::{Fixed, FixedTrait};


#[derive(Copy, Drop, Serde, starknet::Store)]
struct CarmOption {
    option_side: u8,
    maturity: u64,
    strike_price: Fixed,
    quote_token_address: ContractAddress,
    base_token_address: ContractAddress,
    option_type: u8
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct CarmOptionWithSize {
    option: CarmOption,
    cost: Fixed,
    size: u128
}

type LegacyStrike = felt252;

// AMM interface
#[starknet::interface]
trait IAMM<TContractState> {
    fn trade_open(
        ref self: TContractState,
        option_type: u8,
        strike_price: Fixed,
        maturity: u64,
        option_side: u8,
        option_size: u128,
        quote_token_address: ContractAddress,
        base_token_address: ContractAddress,
        limit_total_premia: Fixed,
        tx_deadline: u64,
    ) -> Fixed;

    fn trade_close(
        ref self: TContractState,
        option_type: u8,
        strike_price: Fixed,
        maturity: u64,
        option_side: u8,
        option_size: u128,
        quote_token_address: ContractAddress,
        base_token_address: ContractAddress,
        limit_total_premia: Fixed,
        tx_deadline: u64,
    ) -> Fixed;

    fn trade_settle(
        ref self: TContractState,
        option_type: u8,
        strike_price: Fixed,
        maturity: u64,
        option_side: u8,
        option_size: u128,
        quote_token_address: ContractAddress,
        base_token_address: ContractAddress,
    );

    fn get_total_premia(
        self: @TContractState, option: CarmOption, position_size: u256, is_closing: bool,
    ) -> (Fixed, Fixed);

    fn get_lptoken_address_for_given_option(
        self: @TContractState,
        quote_token_address: ContractAddress,
        base_token_address: ContractAddress,
        option_type: u8,
    ) -> ContractAddress;

    fn get_all_options(
        self: @TContractState, lptoken_address: ContractAddress
    ) -> Array<CarmOption>;

    fn get_option_token_address(
        self: @TContractState,
        lptoken_address: ContractAddress,
        option_side: u8,
        maturity: u64,
        strike_price: Fixed,
    ) -> ContractAddress;
}

/// @notice Closes an option position before expiry
/// @dev Calls the AMM's trade_close function with a max slippage parameter to ensure execution
/// @param address The contract address of the option token
/// @param amount The amount of option tokens to close
fn close_option_position(address: ContractAddress, amount: u256) {
    let token_disp = IERC20Dispatcher { contract_address: address };
    let option_type: u8 = token_disp.option_type();
    let strike_price: Fixed = token_disp.strike_price();
    let maturity: u64 = token_disp.maturity();
    let quote_token_address: ContractAddress = token_disp.quote_token_address();
    let base_token_address: ContractAddress = token_disp.base_token_address();

    let amm_disp = IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() };
    amm_disp
        .trade_close(
            option_type,
            strike_price,
            maturity.into(),
            0,
            amount.try_into().unwrap(),
            quote_token_address,
            base_token_address,
            convert_from_int_to_Fixed(1, 18), // close options regardless of premia 
            (get_block_timestamp() + 42).into()
        );
}

/// @notice Settles an option position at or after expiry
/// @dev Calls the AMM's trade_settle function to claim settlement value
/// @param address The contract address of the option token
/// @param amount The amount of option tokens to settle
fn settle_option_position(address: ContractAddress, amount: u256) {
    let token_disp = IERC20Dispatcher { contract_address: address };
    let option_type: u8 = token_disp.option_type();
    let strike_price: Fixed = token_disp.strike_price();
    let maturity: u64 = token_disp.maturity();
    let quote_token_address: ContractAddress = token_disp.quote_token_address();
    let base_token_address: ContractAddress = token_disp.base_token_address();

    let amm_disp = IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() };
    amm_disp
        .trade_settle(
            option_type,
            strike_price,
            maturity.into(),
            0,
            amount.try_into().unwrap(),
            quote_token_address,
            base_token_address
        );
}

/// @notice Purchases an option from the AMM
/// @dev Executes a trade_open call to the AMM with effectively no slippage protection.
/// @param option_with_size A struct containing option parameters and size
/// @param option_amm The AMM dispatcher to execute the trade against
fn buy_option(option_with_size: CarmOptionWithSize, option_amm: IAMMDispatcher) {
    option_amm
        .trade_open(
            option_with_size.option.option_type,
            option_with_size.option.strike_price,
            option_with_size.option.maturity,
            option_with_size.option.option_side,
            option_with_size.size,
            option_with_size.option.quote_token_address,
            option_with_size.option.base_token_address,
            option_with_size.cost * FixedTrait::from_unscaled_felt(2),
            (get_block_timestamp() + 60).into()
        );
}

/// @notice Prices an option with given parameters and returns a CarmOptionWithSize struct
/// @dev Queries the AMM for the current premium of the specified option
/// @param strike The strike price of the option
/// @param notional The notional amount of the option
/// @param expiry The expiry timestamp of the option
/// @param calls Boolean flag - true for call options, false for put options
/// @param base_token_addr The address of the base token
/// @param quote_token_addr The address of the quote token
/// @return A CarmOptionWithSize struct containing the option parameters, cost, and size
fn price_option(
    strike: Fixed,
    notional: u128,
    expiry: u64,
    calls: bool,
    base_token_addr: ContractAddress,
    quote_token_addr: ContractAddress
) -> CarmOptionWithSize {
    let option_type = if calls {
        0
    } else {
        1
    };

    let option = CarmOption {
        option_side: 0,
        maturity: expiry.into(),
        strike_price: strike,
        quote_token_address: quote_token_addr,
        base_token_address: base_token_addr,
        option_type
    };

    let (_, cost) = IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() }
        .get_total_premia(option, notional.into(), false);

    CarmOptionWithSize { option: option, cost: cost, size: notional }
}

/// @notice Retrieves available strike prices for options with specified parameters
/// @dev Queries the AMM for all available options and filters by expiry, option type, and side
/// @param expiry The expiry timestamp to filter options by
/// @param quote_token_addr The address of the quote token
/// @param base_token_addr The address of the base token
/// @param calls Boolean flag - true for call options, false for put options
/// @return An array of Fixed values representing available strike prices
/// @custom:throws CALL_OPTIONS_UNAVAILABLE if no options are available with the specified parameters
fn available_strikes(
    expiry: u64, quote_token_addr: ContractAddress, base_token_addr: ContractAddress, calls: bool
) -> Array<Fixed> {
    let option_type = if calls {
        0
    } else {
        1
    };
    // Get relevant lpt address
    let lpt_addr: ContractAddress = IAMMDispatcher {
        contract_address: AMM_ADDR.try_into().unwrap()
    }
        .get_lptoken_address_for_given_option(quote_token_addr, base_token_addr, option_type);
    // Get list of options
    let all_options = IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() }
        .get_all_options(lpt_addr);

    let mut res = ArrayTrait::new();

    // Iterate through all options and filter based on maturity and option type
    let mut i: usize = 0;
    loop {
        if i >= all_options.len() {
            break;
        }
        let option = *all_options.at(i);
        if option.maturity == expiry
            && option.option_type == option_type
            && option.option_side == 0 { // 0 for long
            res.append(option.strike_price);
        }
        i += 1;
    };
    assert(res.len() > 0, Errors::CALL_OPTIONS_UNAVAILABLE);
    res
}
