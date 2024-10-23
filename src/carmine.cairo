use starknet::{ContractAddress, get_block_timestamp};
use option::OptionTrait;
use traits::{TryInto, Into};
use array::ArrayTrait;
use debug::PrintTrait;

use hoil::constants::{AMM_ADDR, TOKEN_ETH_ADDRESS, TOKEN_USDC_ADDRESS, TOKEN_STRK_ADDRESS};
use hoil::helpers::{convert_from_Fixed_to_int, convert_from_int_to_Fixed};
use hoil::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};

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
        self: @TContractState,
        option: CarmOption,
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
    ) -> Array<CarmOption>; 

    fn get_option_token_address(
        self: @TContractState,
        lptoken_address: ContractAddress,
        option_side: u8,
        maturity: u64,
        strike_price: Fixed,
    ) -> ContractAddress;
}

fn close_option_position(address: ContractAddress, amount: u256) {
    let token_disp = IERC20Dispatcher { contract_address: address };
    let option_type: u8 = token_disp.option_type();
    let strike_price: Fixed = token_disp.strike_price();
    let maturity: u64 = token_disp.maturity();
    let quote_token_address: ContractAddress = token_disp.quote_token_address();
    let base_token_address: ContractAddress = token_disp.base_token_address();

    let amm_disp = IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() };
    amm_disp.trade_close(
        option_type,
        strike_price,
        maturity.into(),
        0,
        amount.try_into().unwrap(),
        quote_token_address,
        base_token_address,
        convert_from_int_to_Fixed(1, 18),  // close options regardless of premia 
        (get_block_timestamp() + 42).into()
    );
}

fn settle_option_position(address: ContractAddress, amount: u256) {
    let token_disp = IERC20Dispatcher { contract_address: address };
    let option_type: u8 = token_disp.option_type();
    let strike_price: Fixed = token_disp.strike_price();
    let maturity: u64 = token_disp.maturity();
    let quote_token_address: ContractAddress = token_disp.quote_token_address();
    let base_token_address: ContractAddress = token_disp.base_token_address();

    let amm_disp = IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() };
    amm_disp.trade_settle(
        option_type,
        strike_price,
        maturity.into(),
        0,
        amount.try_into().unwrap(),
        quote_token_address,
        base_token_address
    );
}

// Helper functions
fn buy_option(
    strike: Fixed,
    notional: u128,
    expiry: u64,
    calls: bool,
    base_token_addr: ContractAddress,
    quote_token_addr: ContractAddress,
    exp_price: Option<u128>,
    quote_token_decimals: u8
) -> u128 {
    let option_type = if calls { 0 } else { 1 };
    let premia = match exp_price {
        // figure it out TODO
        Option::Some(value) => convert_from_int_to_Fixed(value * 12 / 10, quote_token_decimals),
        Option::None => convert_from_int_to_Fixed(notional / 5,  18),
    };
    // 'opt_type'.print();
    // option_type.print();
    // 'strike'.print();
    // strike.print();
    // 'maturity'.print();
    // expiry.print();
    // 'notional'.print();
    // notional.print();

    IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() }
    .trade_open(
        option_type,
        strike,
        expiry.into(),
        0,
        notional.into(),
        quote_token_addr,
        base_token_addr,
        premia,
        (get_block_timestamp() + 42).into()
    );

    notional
}

fn price_option(
    strike: Fixed, notional: u128, expiry: u64, calls: bool, base_token_addr: ContractAddress, quote_token_addr: ContractAddress) -> u128 {
    let option_type = if calls { 0 } else { 1 };
    // let lpt_addr_felt: ContractAddress = IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() }
    //     .get_lptoken_address_for_given_option(quote_token_addr.try_into().unwrap(), base_token_addr.try_into().unwrap(), option_type);

    let option = CarmOption {
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
    assert(res.len() > 0, 'Options for hedge unavail.');
    res
}
