use starknet::{ContractAddress, get_block_timestamp};
use option::OptionTrait;
use traits::{TryInto, Into};
use array::ArrayTrait;
use debug::PrintTrait;

use hoil::constants::{AMM_ADDR, TOKEN_ETH_ADDRESS, TOKEN_USDC_ADDRESS, TOKEN_STRK_ADDRESS};
use hoil::helpers::convert_from_Fixed_to_int;

use cubit::f128::types::fixed::{Fixed, FixedTrait};


#[derive(Copy, Drop, Serde, starknet::Store)]
struct Option {
    option_side: u8,
    maturity: u64,
    strike_price: Fixed,
    quote_token_address: ContractAddress,
    base_token_address: ContractAddress,
    option_type: u8
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

    fn get_total_premia(
        self: @TContractState,
        option: Option,
        position_size: u256,
        is_closing: bool,
    ) -> (Fixed, Fixed);

    fn get_lptoken_address_for_given_option(
        self: @TContractState,
        quote_token_address: ContractAddress,
        base_token_address: ContractAddress,
        option_type: u8,
    ) -> ContractAddress;

    fn get_all_options(
        self: @TContractState,
         lptoken_address: ContractAddress
    ) -> Array<Option>; 

    fn get_option_token_address(
        self: @TContractState,
        lptoken_address: ContractAddress,
        option_side: u8,
        maturity: u64,
        strike_price: Fixed,
    ) -> ContractAddress;
}

// Helper functions
fn buy_option(strike: Fixed, notional: u128, expiry: u64, calls: bool, base_token_addr: ContractAddress, quote_token_addr: ContractAddress) {
    let option_type = if calls { 0 } else { 1 };
    IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() }
    .trade_open(
        option_type,
        strike,
        expiry.into(),
        0,
        notional.into(),
        quote_token_addr,
        base_token_addr,
        (notional / 5).into(),
        (get_block_timestamp() + 42).into()
    );
}

fn price_option(
    strike: Fixed, notional: u128, expiry: u64, calls: bool, base_token_addr: ContractAddress, quote_token_addr: ContractAddress) -> u128 {
    let option_type = if calls { 0 } else { 1 };
    // let lpt_addr_felt: ContractAddress = IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() }
    //     .get_lptoken_address_for_given_option(quote_token_addr.try_into().unwrap(), base_token_addr.try_into().unwrap(), option_type);

    let option = Option {
        option_side: 0,
        maturity: expiry.into(),
        strike_price: strike,
        quote_token_address: quote_token_addr,
        base_token_address: base_token_addr,
        option_type
    };

    let (_, after_fees) = IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() }
        .get_total_premia(option, notional.into(), false);
    let res = if (quote_token_addr.into() == TOKEN_USDC_ADDRESS && !calls) {
        convert_from_Fixed_to_int(after_fees, 6).into()
    } else {
        convert_from_Fixed_to_int(after_fees, 18).into()
    };
    res
}

fn available_strikes(
    expiry: u64, quote_token_addr: ContractAddress, base_token_addr: ContractAddress, calls: bool
) -> Array<Fixed> {
    let option_type = if calls { 0 } else { 1 };
    // Get relevant lpt address
    let lpt_addr: ContractAddress = IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() }
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
        if option.maturity == expiry && option.option_type == option_type && option.option_side == 0 {  // 0 for long
            res.append(option.strike_price);
        }
        i += 1;
    };
    res
}
