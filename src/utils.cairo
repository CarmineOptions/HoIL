use starknet::ContractAddress;
use option::OptionTrait;
use array::ArrayTrait;

use cubit::f128::types::fixed::{Fixed, FixedTrait};

use hoil::amm_curve::compute_portfolio_value;
use hoil::hedging::price_options_at_strike_to_hedge_at;
use hoil::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use hoil::constants::HEDGE_TOKEN_ADDRESS;
use hoil::carmine::{CarmOptionWithSize, buy_option, IAMMDispatcher, IAMMDispatcherTrait};
use hoil::helpers::{convert_from_Fixed_to_int, convert_from_int_to_Fixed, get_decimal};
use hoil::errors::Errors;
use hoil::hedging::{iterate_strike_prices, iterate_strike_prices_with_bound, OptionAmount};
use hoil::pragma::get_pragma_median_price;


use debug::PrintTrait;

fn compute_hedge_on_interval(
    tobuy: Fixed,
    tohedge: Fixed,
    base_token_addr: ContractAddress,
    quote_token_addr: ContractAddress,
    notional: u128,
    curr_price: Fixed,
    mut already_hedged: Fixed,
    expiry: u64,
    option_type: bool
) -> (Fixed, CarmOptionWithSize) {  // cost , already hedged
    // compute how much portfolio value would be at each hedged strike
    // converts the excess to the hedge result asset (calls -> convert to eth)
    // for each strike
    let portf_val = compute_portfolio_value(
        curr_price, notional, option_type, tohedge
    ); // value of second asset is precisely as much as user put in, expecting conversion
    assert(portf_val > FixedTrait::ZERO(), 'portf val calls < 0?');
    assert(portf_val.sign == false, 'portf val neg??');

    let base_token_decimals: u8 = get_decimal(base_token_addr);
    let mut notional_fixed = convert_from_int_to_Fixed(notional, base_token_decimals); // difference between converted and premia amounts is how much one should be hedging against
    //assert((notional_fixed - portf_val_calls) > already_hedged, "amounttohedge neg??"); // can't compile with it for some reason??
    // TODO add notional in quote cond
    if !option_type {
        notional_fixed = notional_fixed * curr_price;
    }
    let mut amount_to_hedge = notional_fixed - portf_val - already_hedged;
    already_hedged += amount_to_hedge;
    if option_type {
        amount_to_hedge = amount_to_hedge * curr_price;
    }
    let option_with_size = price_options_at_strike_to_hedge_at(
        tobuy, tohedge, amount_to_hedge, expiry, option_type, base_token_addr, quote_token_addr
    );
    (already_hedged, option_with_size)
}

fn buy_and_approve(
    option_to_buy: CarmOptionWithSize,
    amm: IAMMDispatcher
) -> OptionAmount {
    buy_option(option_to_buy, amm);
    let lpt_addr: ContractAddress = amm.get_lptoken_address_for_given_option(
        option_to_buy.option.quote_token_address,
        option_to_buy.option.base_token_address, 
        option_to_buy.option.option_type
    );
    // '1'.print();
    // option_to_buy.cost.mag.print();
    let option_token = amm.get_option_token_address(lpt_addr, 0, option_to_buy.option.maturity, option_to_buy.option.strike_price);
    let option_token_dispatcher = IERC20Dispatcher { contract_address: option_token };

    // Transfer options to the user
    option_token_dispatcher.approve(HEDGE_TOKEN_ADDRESS.try_into().unwrap(), option_to_buy.size.into());
    OptionAmount { address: option_token, amount: option_to_buy.size.into() }
}

fn build_hedge(
    notional: u128,
    quote_token_addr: ContractAddress,
    base_token_addr: ContractAddress,
    expiry: u64,
    hedge_at_price: Fixed
) -> (Fixed, Fixed, Fixed, Array<CarmOptionWithSize>) {
    // Use hedge_at_price if provided, otherwise get the price from Pragma
    let curr_price = if (hedge_at_price <= FixedTrait::ZERO()) {
        get_pragma_median_price(quote_token_addr, base_token_addr)
    } else {
        hedge_at_price
    };
    assert(curr_price > FixedTrait::ZERO(), Errors::NEGATIVE_PRICE);

    // iterate available strike prices and get them into pairs of (bought strike, at which strike one should be hedged)
    let mut strikes_calls = iterate_strike_prices(
        curr_price, quote_token_addr, base_token_addr, expiry, true
    );
    assert(strikes_calls.len() > 0, Errors::CALL_OPTIONS_UNAVAILABLE);
    let mut strikes_puts = iterate_strike_prices(
        curr_price, quote_token_addr, base_token_addr, expiry, false
    );
    assert(strikes_puts.len() > 0, Errors::PUT_OPTIONS_UNAVAILABLE);

    let mut already_hedged_calls: Fixed = FixedTrait::ZERO();
    let mut cost_quote = FixedTrait::ZERO();
    let mut cost_base = FixedTrait::ZERO();

    let mut options_with_size: Array<CarmOptionWithSize> = ArrayTrait::new();

    loop {
        match strikes_calls.pop_front() {
            Option::Some(strike_pair) => {
                let (tobuy, tohedge) = *strike_pair;
                let (hedged, option_with_size) = compute_hedge_on_interval(
                    tobuy,
                    tohedge,
                    base_token_addr,
                    quote_token_addr,
                    notional,
                    curr_price,
                    already_hedged_calls,
                    expiry,
                    true
                );
                // '7'.print();
                // option_with_size.cost.mag.print();
                if option_with_size.cost > FixedTrait::ZERO() {
                    already_hedged_calls = hedged;
                    cost_base += option_with_size.cost;
                    options_with_size.append(option_with_size);
                }
            },
            Option::None(()) => {
                break;
            }
        };
    };

    let mut already_hedged_puts: Fixed = FixedTrait::ZERO();
    loop {
        match strikes_puts.pop_front() {
            Option::Some(strike_pair) => {
                let (tobuy, tohedge) = *strike_pair;
                let (hedged, option_with_size) = compute_hedge_on_interval(
                    tobuy,
                    tohedge,
                    base_token_addr,
                    quote_token_addr,
                    notional,
                    curr_price,
                    already_hedged_puts,
                    expiry,
                    false
                );
                // '6'.print();
                // option_with_size.cost.mag.print();
                if option_with_size.cost > FixedTrait::ZERO() {
                    already_hedged_puts = hedged;
                    cost_quote += option_with_size.cost;
                    options_with_size.append(option_with_size);
                }
            },
            Option::None(()) => {
                break;
            }
        };
    };
    (cost_quote, cost_base, curr_price, options_with_size)
}

fn build_concentrated_hedge(
    notional: u128,
    quote_token_addr: ContractAddress,
    base_token_addr: ContractAddress,
    expiry: u64,
    tick_lower_bound: Fixed,
    tick_upper_bound: Fixed,
    hedge_at_price: Fixed
) -> (Fixed, Fixed, Fixed, Fixed, Fixed, Array<CarmOptionWithSize>) {
    // Use hedge_at_price if provided, otherwise get the price from Pragma
    let curr_price = if (hedge_at_price <= FixedTrait::ZERO()) {
        get_pragma_median_price(quote_token_addr, base_token_addr)
    } else {
        hedge_at_price
    };
    assert(curr_price > FixedTrait::ZERO(), Errors::NEGATIVE_PRICE);
    assert(tick_lower_bound < curr_price, Errors::LOWER_TICK_TOO_HIGH);
    assert(tick_upper_bound > curr_price, Errors::UPPER_TICK_TOO_LOW);

    // iterate available strike prices and get them into pairs of (bought strike, at which strike one should be hedged)
    let mut strikes_calls = iterate_strike_prices_with_bound(
        curr_price, quote_token_addr, base_token_addr, expiry, true, tick_upper_bound
    );
    assert(strikes_calls.len() > 0, Errors::CALL_OPTIONS_UNAVAILABLE);
    let mut strikes_puts = iterate_strike_prices_with_bound(
        curr_price, quote_token_addr, base_token_addr, expiry, false, tick_lower_bound
    );
    assert(strikes_puts.len() > 0, Errors::PUT_OPTIONS_UNAVAILABLE);

    let mut already_hedged_calls: Fixed = FixedTrait::ZERO();
    let mut cost_quote = FixedTrait::ZERO();
    let mut cost_base = FixedTrait::ZERO();

    let mut options_with_size: Array<CarmOptionWithSize> = ArrayTrait::new();

    loop {
        match strikes_calls.pop_front() {
            Option::Some(strike_pair) => {
                let (tobuy, tohedge) = *strike_pair;
                let (hedged, option_with_size) = compute_hedge_on_interval(
                    tobuy,
                    tohedge,
                    base_token_addr,
                    quote_token_addr,
                    notional,
                    curr_price,
                    already_hedged_calls,
                    expiry,
                    true
                );
                // '7'.print();
                // option_with_size.cost.mag.print();
                if option_with_size.cost > FixedTrait::ZERO() {
                    already_hedged_calls = hedged;
                    cost_base += option_with_size.cost;
                    options_with_size.append(option_with_size);
                }
            },
            Option::None(()) => {
                break;
            }
        };
    };

    let mut already_hedged_puts: Fixed = FixedTrait::ZERO();
    loop {
        match strikes_puts.pop_front() {
            Option::Some(strike_pair) => {
                let (tobuy, tohedge) = *strike_pair;
                let (hedged, option_with_size) = compute_hedge_on_interval(
                    tobuy,
                    tohedge,
                    base_token_addr,
                    quote_token_addr,
                    notional,
                    curr_price,
                    already_hedged_puts,
                    expiry,
                    false
                );
                // '6'.print();
                // option_with_size.cost.mag.print();
                if option_with_size.cost > FixedTrait::ZERO() {
                    already_hedged_puts = hedged;
                    cost_quote += option_with_size.cost;
                    options_with_size.append(option_with_size);
                }
            },
            Option::None(()) => {
                break;
            }
        };
    };

    (cost_quote, cost_base, curr_price, tick_lower_bound, tick_upper_bound, options_with_size)
}
