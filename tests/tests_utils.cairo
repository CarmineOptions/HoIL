use starknet::ContractAddress;
use cubit::f128::types::fixed::{Fixed, FixedTrait};
use hoil::helpers::get_erc20_dispatcher;

use hoil::testing::test_utils::{
    deploy, approve_fixed, ETH, USDC, STRK, OWNER, USER, ONE_ETH, ONE_USDC, ONE_STRK, fund_eth,
    fund_usdc, fund_strk, pail_disp, pail_token_factory_disp
};
use hoil::utils::{build_hedge, build_concentrated_hedge};
use hoil::constants::{TOKEN_ETH_ADDRESS, TOKEN_USDC_ADDRESS, TOKEN_STRK_ADDRESS};
use hoil::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use hoil::interface::{IILHedge, IILHedgeDispatcher, IILHedgeDispatcherTrait};
use hoil::errors::Errors;

use snforge_std::{start_prank, stop_prank, CheatTarget};

use debug::PrintTrait;


#[test]
#[fork("MAINNET")]
fn test_build_hedge_eth_usdc_no_price() {
    let notional: u128 = 10_000_000_000_000_000_000;
    let quote_token_addr = TOKEN_USDC_ADDRESS.try_into().unwrap();
    let base_token_addr = TOKEN_ETH_ADDRESS.try_into().unwrap();
    let expiry: u64 = 1743119999_u64;

    let (quote_cost, base_cost, price, options_to_buy) = build_hedge(
        notional, quote_token_addr, base_token_addr, expiry.into(), FixedTrait::ZERO()
    );

    // Assert quote_cost
    assert(quote_cost == FixedTrait::from_felt(1703348360846268348195), 'Quote cost wrong'); // ~92

    // Assert base_cost
    assert(base_cost == FixedTrait::from_felt(375366250716248262), 'Base wrong'); // ~0.02

    // Assert price
    assert(price == FixedTrait::from_felt(35823009596556862087645), 'Wrong price'); // ~1940

    // Check that options_to_buy array is not empty
    assert(!options_to_buy.is_empty(), 'Should have options to buy');

    // Assert on the length of options_to_buy
    assert(options_to_buy.len() == 9, 'wrong num of options');
}


#[test]
#[fork("MAINNET")]
fn test_build_hedge_eth_usdc_with_price() {
    let notional: u128 = 10_000_000_000_000_000_000;
    let quote_token_addr = TOKEN_USDC_ADDRESS.try_into().unwrap();
    let base_token_addr = TOKEN_ETH_ADDRESS.try_into().unwrap();
    let expiry: u64 = 1743119999_u64;
    let price_at = FixedTrait::from_unscaled_felt(2000);

    let (quote_cost, base_cost, price, options_to_buy) = build_hedge(
        notional, quote_token_addr, base_token_addr, expiry.into(), price_at
    );

    // Assert quote_cost
    assert(quote_cost == FixedTrait::from_felt(2080741972888088674159), 'Quote cost wrong');

    // Assert base_cost
    assert(base_cost == FixedTrait::from_felt(266222840438109755), 'Base wrong');

    // Assert price
    assert(price == FixedTrait::from_unscaled_felt(2000), 'Wrong price');

    // Check that options_to_buy array is not empty
    assert(!options_to_buy.is_empty(), 'Should have options to buy');

    // Assert on the length of options_to_buy \
    assert(options_to_buy.len() == 9, 'Should have 10 options');
}


#[test]
#[fork("MAINNET")]
fn test_build_hedge_strk_usdc_no_price() {
    let notional: u128 = 100_000_000_000_000_000_000;
    let quote_token_addr = TOKEN_USDC_ADDRESS.try_into().unwrap();
    let base_token_addr = TOKEN_STRK_ADDRESS.try_into().unwrap();
    let expiry: u64 = 1743119999_u64;

    let (quote_cost, base_cost, price, options_to_buy) = build_hedge(
        notional, quote_token_addr, base_token_addr, expiry.into(), FixedTrait::ZERO()
    );

    // Assert quote_cost
    assert(quote_cost == FixedTrait::from_felt(3357173251261765045), 'Quote cost wrong');

    // Assert base_cost
    assert(base_cost == FixedTrait::from_felt(60895351026458263479), 'Base wrong');

    // Assert price
    assert(price == FixedTrait::from_felt(3199065173968850831), 'Wrong price');

    // Check that options_to_buy array is not empty
    assert(!options_to_buy.is_empty(), 'Should have options to buy');

    // Assert on the length of options_to_buy
    assert(options_to_buy.len() == 9, 'wrong num of options');
}

#[test]
#[fork("MAINNET")]
fn test_build_hedge_strk_usdc_with_price() {
    let notional: u128 = 100_000_000_000_000_000_000;
    let quote_token_addr = TOKEN_USDC_ADDRESS.try_into().unwrap();
    let base_token_addr = TOKEN_STRK_ADDRESS.try_into().unwrap();
    let expiry: u64 = 1743119999_u64;
    let price_at = FixedTrait::from_unscaled_felt(22) / FixedTrait::from_unscaled_felt(100);

    let (quote_cost, base_cost, price, options_to_buy) = build_hedge(
        notional, quote_token_addr, base_token_addr, expiry.into(), price_at
    );

    // Assert quote_cost
    assert(quote_cost == FixedTrait::from_felt(11085621241815808610), 'Quote cost wrong');

    // Assert base_cost
    assert(base_cost == FixedTrait::from_felt(51267857178254275653), 'Base wrong');

    // Assert price
    assert(price == price_at, 'Wrong price');

    // Check that options_to_buy array is not empty
    assert(!options_to_buy.is_empty(), 'Should have options to buy');

    // Assert on the length of options_to_buy
    assert(options_to_buy.len() == 10, 'wrong num of options');
}

#[test]
#[should_panic(expected: ('tohedge>=tobuy',))]
#[fork("MAINNET")]
fn test_build_hedge_put_options_unavailable() {
    let notional: u128 = 100_000_000_000_000_000_000;
    let quote_token_addr = TOKEN_USDC_ADDRESS.try_into().unwrap();
    let base_token_addr = TOKEN_STRK_ADDRESS.try_into().unwrap();
    let expiry: u64 = 1743119999_u64;
    let price_at = FixedTrait::from_unscaled_felt(5) / FixedTrait::from_unscaled_felt(100);

    let (_, _, _, _) = build_hedge(
        notional, quote_token_addr, base_token_addr, expiry.into(), price_at
    );
}

#[test]
#[should_panic(expected: ('tohedge<=tobuy',))]
#[fork("MAINNET")]
fn test_build_hedge_call_options_unavailable() {
    let notional: u128 = 100_000_000_000_000_000_000;
    let quote_token_addr = TOKEN_USDC_ADDRESS.try_into().unwrap();
    let base_token_addr = TOKEN_STRK_ADDRESS.try_into().unwrap();
    let expiry: u64 = 1743119999_u64;
    let price_at = FixedTrait::from_unscaled_felt(2);

    let (_, _, _, _) = build_hedge(
        notional, quote_token_addr, base_token_addr, expiry.into(), price_at
    );
}

#[test]
#[fork("MAINNET")]
fn test_build_concentrated_hedge_strk_usdc() {
    let notional: u128 = 100_000_000_000_000_000_000;
    let quote_token_addr = TOKEN_USDC_ADDRESS.try_into().unwrap();
    let base_token_addr = TOKEN_STRK_ADDRESS.try_into().unwrap();
    let expiry: u64 = 1743119999_u64;
    let lower_b = FixedTrait::from_unscaled_felt(15) / FixedTrait::from_unscaled_felt(100);
    let upper_b = FixedTrait::from_unscaled_felt(35) / FixedTrait::from_unscaled_felt(100);
    let price_at = FixedTrait::from_unscaled_felt(22) / FixedTrait::from_unscaled_felt(100);

    let (quote_cost, base_cost, price, lower_bound, upper_bound, options_to_buy) =
        build_concentrated_hedge(
        notional, quote_token_addr, base_token_addr, expiry.into(), lower_b, upper_b, price_at
    );

    // Assert quote_cost
    assert(quote_cost == FixedTrait::from_felt(46122354311094518718), 'Quote cost wrong');

    // Assert base_cost
    assert(base_cost == FixedTrait::from_felt(5213025365092067730), 'Base wrong');

    // Assert price
    assert(price == price_at, 'Wrong price');

    // Assert bounds
    assert(lower_b == lower_bound, 'Wrong lower b');
    assert(upper_b == upper_bound, 'Wrong upper b');

    // Check that options_to_buy array is not empty
    assert(!options_to_buy.is_empty(), 'Should have options to buy');

    // Assert on the length of options_to_buy
    assert(options_to_buy.len() == 5, 'wrong num of options');
}


#[test]
#[should_panic(expected: ('Lower bound too high',))]
#[fork("MAINNET")]
fn test_build_concentrated_hedge_wrong_lower_bound() {
    let notional: u128 = 100_000_000_000_000_000_000;
    let quote_token_addr = TOKEN_USDC_ADDRESS.try_into().unwrap();
    let base_token_addr = TOKEN_STRK_ADDRESS.try_into().unwrap();
    let expiry: u64 = 1743119999_u64;
    let lower_b = FixedTrait::from_unscaled_felt(20) / FixedTrait::from_unscaled_felt(100);
    let upper_b = FixedTrait::from_unscaled_felt(35) / FixedTrait::from_unscaled_felt(100);

    let (_, _, _, _, _, _) = build_concentrated_hedge(
        notional,
        quote_token_addr,
        base_token_addr,
        expiry.into(),
        lower_b,
        upper_b,
        FixedTrait::ZERO()
    );
}

#[test]
#[should_panic(expected: ('Upper bound too low',))]
#[fork("MAINNET")]
fn test_build_concentrated_hedge_wrong_upper_bound() {
    let notional: u128 = 100_000_000_000_000_000_000;
    let quote_token_addr = TOKEN_USDC_ADDRESS.try_into().unwrap();
    let base_token_addr = TOKEN_STRK_ADDRESS.try_into().unwrap();
    let expiry: u64 = 1743119999_u64;
    let lower_b = FixedTrait::from_unscaled_felt(10) / FixedTrait::from_unscaled_felt(100);
    let upper_b = FixedTrait::from_unscaled_felt(15) / FixedTrait::from_unscaled_felt(100);

    let (_, _, _, _, _, _) = build_concentrated_hedge(
        notional,
        quote_token_addr,
        base_token_addr,
        expiry.into(),
        lower_b,
        upper_b,
        FixedTrait::ZERO()
    );
}
