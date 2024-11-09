use array::{ArrayTrait, SpanTrait};
use core::traits::Into;
use debug::PrintTrait;
use integer::u256_as_non_zero;
use option::OptionTrait;

use alexandria_sorting::merge_sort::merge;
use cubit::f128::types::fixed::{Fixed, FixedTrait};

use hoil::carmine::{available_strikes, buy_option, price_option, close_option_position, settle_option_position, CarmOptionWithSize};
use hoil::helpers::{convert_from_Fixed_to_int, convert_from_int_to_Fixed, reverse, pow, toU256_balance, closest_value};
use hoil::constants::{AMM_ADDR, TOKEN_ETH_ADDRESS, TOKEN_USDC_ADDRESS, TOKEN_STRK_ADDRESS, TOKEN_BTC_ADDRESS, HEDGE_TOKEN_ADDRESS};
use hoil::hedge_token::{OptionAmount, IHedgeTokenDispatcher, IHedgeTokenDispatcherTrait};
use hoil::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};

use starknet::{ContractAddress, get_caller_address};


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
    let (_, rem) = integer::U256DivRem::div_rem(strike_price_u256, 10_000);
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
// fn buy_options_at_strike_to_hedge_at(
//     to_buy_strike: Fixed,
//     to_hedge_strike: Fixed,
//     payoff: Fixed,
//     expiry: u64,
//     quote_token_addr: ContractAddress,
//     base_token_addr: ContractAddress,
//     calls: bool
// ) -> u128 {
//     let notional = how_many_options_at_strike_to_hedge_at(
//         to_buy_strike, to_hedge_strike, payoff, calls
//     );
//     let option_recieved = if (quote_token_addr.into() == TOKEN_USDC_ADDRESS && !calls) {
//         let adj_notional = adjust_for_rounding_condition(notional, to_buy_strike, 18, 6);
//         let exp_price = price_option(to_buy_strike, adj_notional, expiry, calls, base_token_addr, quote_token_addr);
//         if exp_price != 0 {
//             buy_option(to_buy_strike, adj_notional, expiry, calls, base_token_addr, quote_token_addr, Option::Some(exp_price), 6)
//         } else {0}
//     } else if !calls {
//         let exp_price = price_option(to_buy_strike, notional, expiry, calls, base_token_addr, quote_token_addr);
//         if exp_price != 0 {
//             buy_option(to_buy_strike, notional, expiry, calls, base_token_addr, quote_token_addr, Option::Some(exp_price), 18)
//         } else {0}
//     } else {
//         buy_option(to_buy_strike, notional, expiry, calls, base_token_addr, quote_token_addr, Option::None, 18)
//     };

//     option_recieved
// }

fn price_options_at_strike_to_hedge_at(
    to_buy_strike: Fixed,
    to_hedge_strike: Fixed, 
    payoff: Fixed, 
    expiry: u64, 
    calls: bool, 
    base_token_addr: ContractAddress, 
    quote_token_addr: ContractAddress
) -> CarmOptionWithSize {
    let notional = how_many_options_at_strike_to_hedge_at(
        to_buy_strike, to_hedge_strike, payoff, calls
    );
    if (quote_token_addr.into() == TOKEN_USDC_ADDRESS && !calls) {
        let adj_notional = adjust_for_rounding_condition(notional, to_buy_strike, 18, 6);  // TODO use function get_decimal
        price_option(to_buy_strike, adj_notional, expiry, calls, base_token_addr, quote_token_addr)
    } else {
        price_option(to_buy_strike, notional, expiry, calls, base_token_addr, quote_token_addr)
    }
}

fn hedge_finalize(
    token_id: u256,
    close_option_position: bool
) -> ContractAddress {
    let caller = get_caller_address();
    let contract_address = starknet::get_contract_address();
    let hedge_token_dispatcher = IHedgeTokenDispatcher { contract_address: HEDGE_TOKEN_ADDRESS.try_into().unwrap()};

    // Transfer the hedge token from caller to this contract
    hedge_token_dispatcher.safe_transfer_from(caller, contract_address, token_id,  ArrayTrait::new().span());

    // Get addresses of each token in hedged pair
    let base_token_address = hedge_token_dispatcher.base_token_address(token_id);
    let quote_token_address = hedge_token_dispatcher.quote_token_address(token_id);

    // Record intial balance of tokens before closing option contract
    let base_token_disp = IERC20Dispatcher { contract_address: base_token_address };
    let quote_token_disp = IERC20Dispatcher { contract_address: quote_token_address };
    let initial_base_token_balance = base_token_disp.balanceOf(contract_address);
    let initial_quote_token_balance = quote_token_disp.balanceOf(contract_address);

    // execute hedge token burn, that will result in transfering all assigned option tokens to current contract
    let options_to_close: Array<OptionAmount> = hedge_token_dispatcher.burn_hedge_token(token_id);

    let mut options_to_close_span = options_to_close.span();
    let mut index = 0_u32;
    loop {
        match options_to_close_span.pop_front() {
            Option::Some(option_token) => {
                if close_option_position {
                    close_option_position(*option_token.address, *option_token.amount);
                } else {
                    settle_option_position(*option_token.address, *option_token.amount);
                }
                index += 1;
            },
            Option::None => { break; },
        };
    };
    // Get new balances of base and quote tokens after closing option contract
    let final_base_token_balance = base_token_disp.balanceOf(contract_address);
    let final_quote_token_balance = quote_token_disp.balanceOf(contract_address);
    // Implemet computation of token amounts and transfer it to  caller. 
    let base_token_payout = final_base_token_balance - initial_base_token_balance;
    let quote_token_payout = final_quote_token_balance - initial_quote_token_balance;
    base_token_disp.transfer(caller, base_token_payout);
    quote_token_disp.transfer(caller, quote_token_payout);

    caller
}
