use starknet::ContractAddress;
use option::OptionTrait;
use array::ArrayTrait;

use cubit::f128::types::fixed::{Fixed, FixedTrait};

use hoil::amm_curve::calculate_portfolio_holdings_with_constnant_product_function;
use hoil::clmm_curve::{calculate_liquidity, calculate_portfolio_holdings_from_liquidity};
use hoil::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use hoil::constants::TOKEN_USDC_ADDRESS;
use hoil::carmine::{
    CarmOptionWithSize, buy_option, IAMMDispatcher, IAMMDispatcherTrait, price_option
};
use hoil::helpers::{convert_from_Fixed_to_int, convert_from_int_to_Fixed, get_decimal};
use hoil::errors::Errors;
use hoil::hedging::{
    iterate_strike_prices, iterate_strike_prices_with_bound, OptionAmount,
    adjust_for_rounding_condition
};
use hoil::pragma::get_pragma_median_price;

use debug::PrintTrait;

fn compute_hedge_on_interval(
    tobuy: Fixed,
    tohedge: Fixed,
    base_token_addr: ContractAddress,
    quote_token_addr: ContractAddress,
    amount_x_init: Fixed,
    amount_y_init: Fixed,
    curr_price: Fixed,
    mut already_hedged: u128,
    expiry: u64,
    option_type: bool
) -> (u128, CarmOptionWithSize) { // already hedged, option to buy
    let (amount_x, amount_y) = calculate_portfolio_holdings_with_constnant_product_function(
        amount_x_init, curr_price, tohedge
    );

    let imp_loss = (amount_x_init * tohedge + amount_y_init) - (amount_x * tohedge + amount_y);

    let quantity_to_buy = if (option_type) {
        let price_0 = if tobuy >= curr_price {
            tobuy
        } else {
            curr_price
        };
        assert(tohedge > price_0, 'tohedge<=tobuy');
        imp_loss / (tohedge - price_0)
    } else {
        let price_0 = if tobuy <= curr_price {
            tobuy
        } else {
            curr_price
        };
        assert(tohedge < price_0, 'tohedge>=tobuy');
        imp_loss / (price_0 - tohedge)
    };
    let mut quantity_to_buy_u128 = convert_from_Fixed_to_int(quantity_to_buy, 18);
    if already_hedged >= quantity_to_buy_u128 {
        quantity_to_buy_u128 = 0;
    } else {
        quantity_to_buy_u128 = quantity_to_buy_u128 - already_hedged;
    }

    // adjust option quantity to align with option AMM limitations.
    let adj_quantity_to_buy = if (quote_token_addr.into() == TOKEN_USDC_ADDRESS && !option_type) {
        adjust_for_rounding_condition(
            quantity_to_buy_u128, tobuy, 18, 6
        ) // TODO use function get_decimal
    } else {
        quantity_to_buy_u128
    };
    let opt_to_buy_with_size = price_option(
        tobuy, adj_quantity_to_buy, expiry, option_type, base_token_addr, quote_token_addr
    );
    (adj_quantity_to_buy, opt_to_buy_with_size)
}

fn buy_and_approve(
    option_to_buy: CarmOptionWithSize, amm: IAMMDispatcher, pail_token_address: ContractAddress
) -> OptionAmount {
    buy_option(option_to_buy, amm);
    let lpt_addr: ContractAddress = amm
        .get_lptoken_address_for_given_option(
            option_to_buy.option.quote_token_address,
            option_to_buy.option.base_token_address,
            option_to_buy.option.option_type
        );
    let option_token = amm
        .get_option_token_address(
            lpt_addr, 0, option_to_buy.option.maturity, option_to_buy.option.strike_price
        );
    let option_token_dispatcher = IERC20Dispatcher { contract_address: option_token };

    // Transfer options to the user
    option_token_dispatcher.approve(pail_token_address, option_to_buy.size.into());
    OptionAmount { address: option_token, amount: option_to_buy.size.into() }
}


fn compute_CLMM_hedge_on_interval(
    tobuy: Fixed,
    tohedge: Fixed,
    base_token_addr: ContractAddress,
    quote_token_addr: ContractAddress,
    notional: Fixed,
    curr_price: Fixed,
    already_hedged: u128,
    expiry: u64,
    option_type: bool,
    portfolio_liquidity: Fixed,
    price_a: Fixed,
    price_b: Fixed,
    amount_x_init: Fixed,
    amount_y_init: Fixed
) -> (u128, CarmOptionWithSize) { // already hedged, opt with size and price
    let (amount_x, amount_y) = calculate_portfolio_holdings_from_liquidity(
        portfolio_liquidity, price_a, price_b, tohedge
    );
    let imp_loss = (amount_x_init * tohedge + amount_y_init) - (amount_x * tohedge + amount_y);

    let quantity_to_buy = if (option_type) {
        let price_0 = if tobuy >= curr_price {
            tobuy
        } else {
            curr_price
        };
        assert(tohedge > price_0, 'tohedge<=tobuy');
        imp_loss / (tohedge - price_0)
    } else {
        let price_0 = if tobuy <= curr_price {
            tobuy
        } else {
            curr_price
        };
        assert(tohedge < price_0, 'tohedge>=tobuy');
        imp_loss / (price_0 - tohedge)
    };
    let mut quantity_to_buy_u128 = convert_from_Fixed_to_int(quantity_to_buy, 18);
    if already_hedged >= quantity_to_buy_u128 {
        quantity_to_buy_u128 = 0;
    } else {
        quantity_to_buy_u128 = quantity_to_buy_u128 - already_hedged;
    }

    // adjust option quantity to align with option AMM limitations.
    let adj_quantity_to_buy = if (quote_token_addr.into() == TOKEN_USDC_ADDRESS && !option_type) {
        adjust_for_rounding_condition(
            quantity_to_buy_u128, tobuy, 18, 6
        ) // TODO use function get_decimal
    } else {
        quantity_to_buy_u128
    };
    let opt_to_buy_with_size = price_option(
        tobuy, adj_quantity_to_buy, expiry, option_type, base_token_addr, quote_token_addr
    );
    (adj_quantity_to_buy, opt_to_buy_with_size)
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

    // iterate available strike prices and get them into pairs of (bought strike, at which strike
    // one should be hedged)
    let mut strikes_calls = iterate_strike_prices(
        curr_price, quote_token_addr, base_token_addr, expiry, true
    );
    assert(strikes_calls.len() > 0, Errors::CALL_OPTIONS_UNAVAILABLE);
    let mut strikes_puts = iterate_strike_prices(
        curr_price, quote_token_addr, base_token_addr, expiry, false
    );
    assert(strikes_puts.len() > 0, Errors::PUT_OPTIONS_UNAVAILABLE);

    let base_token_decimals: u8 = get_decimal(base_token_addr);
    let amount_x_init = convert_from_int_to_Fixed(notional, base_token_decimals);
    let amount_y_init = amount_x_init * curr_price;

    let mut already_hedged_calls: u128 = 0;
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
                    amount_x_init,
                    amount_y_init,
                    curr_price,
                    already_hedged_calls,
                    expiry,
                    true,
                );
                if option_with_size.cost > FixedTrait::ZERO() {
                    already_hedged_calls += hedged;
                    cost_base += option_with_size.cost;
                    options_with_size.append(option_with_size);
                }
            },
            Option::None(()) => { break; }
        };
    };

    let mut already_hedged_puts: u128 = 0;
    loop {
        match strikes_puts.pop_front() {
            Option::Some(strike_pair) => {
                let (tobuy, tohedge) = *strike_pair;
                let (hedged, option_with_size) = compute_hedge_on_interval(
                    tobuy,
                    tohedge,
                    base_token_addr,
                    quote_token_addr,
                    amount_x_init,
                    amount_y_init,
                    curr_price,
                    already_hedged_puts,
                    expiry,
                    false,
                );
                if option_with_size.cost > FixedTrait::ZERO() {
                    already_hedged_puts += hedged;
                    cost_quote += option_with_size.cost;
                    options_with_size.append(option_with_size);
                }
            },
            Option::None(()) => { break; }
        };
    };

    (cost_quote, cost_base, curr_price, options_with_size)
}

fn build_concentrated_hedge(
    notional: u128,
    quote_token_addr: ContractAddress,
    base_token_addr: ContractAddress,
    expiry: u64,
    lower_bound: Fixed,
    upper_bound: Fixed,
    hedge_at_price: Fixed
) -> (Fixed, Fixed, Fixed, Fixed, Fixed, Array<CarmOptionWithSize>) {
    // Use hedge_at_price if provided, otherwise get the price from Pragma
    let curr_price = if (hedge_at_price <= FixedTrait::ZERO()) {
        get_pragma_median_price(quote_token_addr, base_token_addr)
    } else {
        hedge_at_price
    };
    assert(curr_price > FixedTrait::ZERO(), Errors::NEGATIVE_PRICE);
    assert(lower_bound < curr_price, Errors::LOWER_BOUND_TOO_HIGH);
    assert(upper_bound > curr_price, Errors::UPPER_BOUND_TOO_LOW);

    // iterate available strike prices and get them into pairs of (bought strike, at which strike
    // one should be hedged)
    let mut strikes_calls = iterate_strike_prices_with_bound(
        curr_price, quote_token_addr, base_token_addr, expiry, true, upper_bound
    );
    assert(strikes_calls.len() > 0, Errors::CALL_OPTIONS_UNAVAILABLE);
    let mut strikes_puts = iterate_strike_prices_with_bound(
        curr_price, quote_token_addr, base_token_addr, expiry, false, lower_bound
    );
    assert(strikes_puts.len() > 0, Errors::PUT_OPTIONS_UNAVAILABLE);

    let base_token_decimals: u8 = get_decimal(base_token_addr);
    let mut notional_fixed = convert_from_int_to_Fixed(notional, base_token_decimals);
    let portfolio_assumed_liquidity = calculate_liquidity(
        lower_bound, upper_bound, curr_price, notional_fixed
    );
    let (amount_x_init, amount_y_init) = calculate_portfolio_holdings_from_liquidity(
        portfolio_assumed_liquidity, lower_bound, upper_bound, curr_price
    );

    let mut already_hedged_calls: u128 = 0;
    let mut cost_quote = FixedTrait::ZERO();
    let mut cost_base = FixedTrait::ZERO();

    let mut options_with_size: Array<CarmOptionWithSize> = ArrayTrait::new();

    loop {
        match strikes_calls.pop_front() {
            Option::Some(strike_pair) => {
                let (tobuy, tohedge) = *strike_pair;
                let (hedged, option_with_size) = compute_CLMM_hedge_on_interval(
                    tobuy,
                    tohedge,
                    base_token_addr,
                    quote_token_addr,
                    notional_fixed,
                    curr_price,
                    already_hedged_calls,
                    expiry,
                    true,
                    portfolio_assumed_liquidity,
                    lower_bound,
                    upper_bound,
                    amount_x_init,
                    amount_y_init
                );
                if option_with_size.cost > FixedTrait::ZERO() {
                    already_hedged_calls += hedged;
                    cost_base += option_with_size.cost;
                    options_with_size.append(option_with_size);
                }
            },
            Option::None(()) => { break; }
        };
    };

    let mut already_hedged_puts: u128 = 0;
    loop {
        match strikes_puts.pop_front() {
            Option::Some(strike_pair) => {
                let (tobuy, tohedge) = *strike_pair;
                let (hedged, option_with_size) = compute_CLMM_hedge_on_interval(
                    tobuy,
                    tohedge,
                    base_token_addr,
                    quote_token_addr,
                    notional_fixed,
                    curr_price,
                    already_hedged_puts,
                    expiry,
                    false,
                    portfolio_assumed_liquidity,
                    lower_bound,
                    upper_bound,
                    amount_x_init,
                    amount_y_init
                );
                if option_with_size.cost > FixedTrait::ZERO() {
                    already_hedged_puts += hedged;
                    cost_quote += option_with_size.cost;
                    options_with_size.append(option_with_size);
                }
            },
            Option::None(()) => { break; }
        };
    };

    (cost_quote, cost_base, curr_price, lower_bound, upper_bound, options_with_size)
}
