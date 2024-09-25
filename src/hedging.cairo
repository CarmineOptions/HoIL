use core::traits::Into;
use array::{ArrayTrait, SpanTrait};
use integer::u256_as_non_zero;

use alexandria_sorting::merge_sort::merge;
use cubit::f128::types::fixed::{Fixed, FixedTrait};
use debug::PrintTrait;

use hoil::carmine::{available_strikes, buy_option, price_option};
use hoil::helpers::{convert_from_Fixed_to_int, convert_from_int_to_Fixed, reverse, pow, toU256_balance, closest_value};
use hoil::constants::{AMM_ADDR, TOKEN_ETH_ADDRESS, TOKEN_USDC_ADDRESS, TOKEN_STRK_ADDRESS, TOKEN_BTC_ADDRESS};

use starknet::ContractAddress;


fn iterate_strike_prices(
    curr_price: Fixed,
    quote_token_addr: ContractAddress,
    base_token_addr: ContractAddress,
    expiry: u64,
    calls: bool
) -> Span<(Fixed, Fixed)> {
    let interval = if base_token_addr.into() == TOKEN_ETH_ADDRESS {
        if quote_token_addr.into() == TOKEN_USDC_ADDRESS {
            FixedTrait::from_unscaled_felt(200)
        } else {
            FixedTrait::from_unscaled_felt(300)
        }
    } else {
        FixedTrait::from_unscaled_felt(5) / FixedTrait::from_unscaled_felt(100)
    };
    
    let mut strike_prices_arr = available_strikes(expiry, quote_token_addr, base_token_addr, calls);
    let mut res = ArrayTrait::<(Fixed, Fixed)>::new();
    let mut strike_prices = merge(strike_prices_arr).span();
    if (!calls) {
        strike_prices = reverse(strike_prices);
    }
    let mut i = 0;
    loop {
        // If last available strike - we pair with constant
        if (i + 1 == strike_prices.len()) {
            res
                .append(
                    (*strike_prices.at(i), if (calls) {
                        *strike_prices.at(i) + interval
                    } else {
                        *strike_prices.at(i) - interval
                    })
                );
            break;
        }
        // If both strikes are above (in case of puts) or below (in case of calls) current price, no point – so throw away.
        // This is handled by the other type of the options.
        let tobuy = *strike_prices.at(i);
        let tohedge = *strike_prices.at(i + 1);
        if (calls && (tobuy > curr_price || tohedge > curr_price)) {
            let pair: (Fixed, Fixed) = (tobuy, tohedge);
            res.append(pair);
        } else if (!calls && (tobuy < curr_price || tohedge < curr_price)) {
            let pair: (Fixed, Fixed) = (tobuy, tohedge);
            res.append(pair);
        }

        i += 1;
    };
    res.span()
}


// Calculates how much to buy at buystrike to get specified payoff at hedgestrike. Payoff is in quote token for puts, base token for calls.
fn how_many_options_at_strike_to_hedge_at(
    to_buy_strike: Fixed, to_hedge_strike: Fixed, payoff: Fixed, calls: bool
) -> u128 {
    if (calls) {
        assert(to_hedge_strike > to_buy_strike, 'tohedge<=tobuy');
        let res = payoff / (to_hedge_strike - to_buy_strike);
        convert_from_Fixed_to_int(res, 18)
    } else {
        assert(to_hedge_strike < to_buy_strike, 'tohedge>=tobuy');
        let res = payoff / (to_buy_strike - to_hedge_strike);
        convert_from_Fixed_to_int(res, 18)
    }
}

fn simple_cast_u256_to_u128(value: u256) -> u128 {
    value.low.into()
}

// Currently Carmine Option AMM checks for rounding error when pricing put options.
// following function adjust notional to allow trade to pass all conditions in AMM.
fn adjust_for_rounding_condition(amount: u128, strike_price: Fixed, base_token_decimals: u8, quote_token_decimals: u8) -> u128 {
    // Convert strike_price to u256
    let strike_price_u256: u256 = toU256_balance(strike_price, quote_token_decimals.into()).into();
    let (quot, rem) = integer::U256DivRem::div_rem(strike_price_u256, 10_000);
    if rem == 0 {
        let strike_price_u128: u128 = simple_cast_u256_to_u128(strike_price_u256);
        closest_value(amount, strike_price_u128, pow(10, (base_token_decimals - 4).into()))
    } else {
        let (quot, rem) = integer::U128DivRem::div_rem(amount, 1_000_000_000_000_000_000);
        if rem == 0 {
            amount
        } else {
            (quot + 1) * 1_000_000_000_000_000_000
        }
    }
}

// Calculates how much to buy at buystrike to get specified payoff at hedgestrike.
// And buys via carmine module.
fn buy_options_at_strike_to_hedge_at(
    to_buy_strike: Fixed,
    to_hedge_strike: Fixed,
    payoff: Fixed,
    expiry: u64,
    quote_token_addr: ContractAddress,
    base_token_addr: ContractAddress,
    calls: bool
) {
    let notional = how_many_options_at_strike_to_hedge_at(
        to_buy_strike, to_hedge_strike, payoff, calls
    );
    if (quote_token_addr.into() == TOKEN_USDC_ADDRESS && !calls) {
        let adj_notional = adjust_for_rounding_condition(notional, to_buy_strike, 18, 6);
        // if notional is lesser then 10^14 - trade is likely to end up failing on `prem incl fees is 0` on AMM side
        if adj_notional > 100_000_000_000_000 {
            buy_option(to_buy_strike, adj_notional, expiry, calls, base_token_addr, quote_token_addr);
        }

    } else {
        buy_option(to_buy_strike, notional, expiry, calls, base_token_addr, quote_token_addr);
    }
}

fn price_options_at_strike_to_hedge_at(
    to_buy_strike: Fixed,
    to_hedge_strike: Fixed, 
    payoff: Fixed, 
    expiry: u64, 
    calls: bool, 
    base_token_addr: ContractAddress, 
    quote_token_addr: ContractAddress
) -> u128 {
    let notional = how_many_options_at_strike_to_hedge_at(
        to_buy_strike, to_hedge_strike, payoff, calls
    );
    if (quote_token_addr.into() == TOKEN_USDC_ADDRESS && !calls) {
        let adj_notional = adjust_for_rounding_condition(notional, to_buy_strike, 18, 6);
        price_option(to_buy_strike, adj_notional, expiry, calls, base_token_addr, quote_token_addr)
    } else {
        price_option(to_buy_strike, notional, expiry, calls, base_token_addr, quote_token_addr)
    }
}
