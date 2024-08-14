use hoil::helpers::convert_from_int_to_Fixed;

use cubit::f128::types::fixed::{Fixed, FixedTrait};

use debug::PrintTrait;

// Computes the portfolio value if it moved from current (fetched from Empiric) to the specific strike
// Notional is in ETH, it's the amount of ETH that needs to be hedged.
// Also converts the excess to the hedge result asset
// Result is USDC in case of puts, ETH in case of calls.
fn compute_portfolio_value(curr_price: Fixed, notional: u128, calls: bool, strike: Fixed) -> Fixed {
    let x = convert_from_int_to_Fixed(notional, 18); // in ETH
    let y = x * curr_price;
    let k = x * y;

    // price = y / x
    // k = x * y
    // 1500 = 3000 / 2
    let y_at_strike = k.sqrt() * strike.sqrt();
    let x_at_strike = k.sqrt() / strike.sqrt(); // actually sqrt is a hint so basically free.
    convert_excess(x_at_strike, y_at_strike, x, strike, curr_price, calls)
}

fn compute_portfolio_value_strk_eth(
    curr_price_eth_usd: Fixed,
    curr_price_strk_usd: Fixed,
    notional_eth: u128,
    notional_strk: u128,
    new_price_eth_usd: Fixed,
    new_price_strk_usd: Fixed
) -> Fixed {
    // Convert notionals to Fixed
    let x_eth = convert_from_int_to_Fixed(notional_eth, 18); // ETH amount
    let x_strk = convert_from_int_to_Fixed(notional_strk, 18); // STRK amount

    // Calculate initial values in USD
    let initial_value_eth_usd = x_eth * curr_price_eth_usd;
    let initial_value_strk_usd = x_strk * curr_price_strk_usd;
    let initial_total_value_usd = initial_value_eth_usd + initial_value_strk_usd;

    // Calculate the constant product k
    let k = x_eth * x_strk;

    // Calculate new amounts based on constant product formula
    let new_x_eth = k.sqrt() / (new_price_strk_usd / new_price_eth_usd).sqrt();
    let new_x_strk = k / new_x_eth;

    // Calculate new values in USD
    let new_value_eth_usd = new_x_eth * new_price_eth_usd;
    let new_value_strk_usd = new_x_strk * new_price_strk_usd;
    let new_total_value_usd = new_value_eth_usd + new_value_strk_usd;

    // Return the ratio of new value to initial value
    new_total_value_usd / initial_total_value_usd
}

use ilhedge::helpers::percent;
#[cfg(test)]
fn test_compute_portfolio_value() {
    // k = 1500, initial price 1500.
    // price being considered 1700.
    let ONEETH = 1000000000000000000;
    let res = compute_portfolio_value(
        FixedTrait::from_unscaled_felt(1500), ONEETH, true, FixedTrait::from_unscaled_felt(1700)
    );
    assert(res < FixedTrait::ONE(), 'loss must happen due to IL');
    assert(res > percent(95), 'loss weirdly high');

    // k = 1500, initial price 1500.
    // price being considered 1300.
    let res = compute_portfolio_value(
        FixedTrait::from_unscaled_felt(1500), ONEETH, false, FixedTrait::from_unscaled_felt(1300)
    );
    assert(res < FixedTrait::from_unscaled_felt(1500), 'loss must happen');
    assert(res > FixedTrait::from_unscaled_felt(1492), 'loss too high');

    // repro attempt
    let res = compute_portfolio_value(
        FixedTrait::from_unscaled_felt(1650), ONEETH, true, FixedTrait::from_unscaled_felt(1800)
    );
    assert(res < FixedTrait::ONE(), 'loss must happen due to IL');
    assert(res > percent(97), 'loss weirdly high');
}


// TODO FIGURE IT OUT
// converts the excess to the hedge result asset (calls -> convert to eth)
// ensures the call asset / put assset (based on calls bool) is equal to notional (or equivalent amount in puts)
// returns amount of asset that isn't fixed
fn convert_excess(
    call_asset: Fixed,
    put_asset: Fixed,
    notional: Fixed,
    strike: Fixed,
    entry_price: Fixed,
    calls: bool
) -> Fixed {
    if calls {
        assert(strike > entry_price, 'certainly calls?');
        assert(call_asset < notional, 'hedging at odd strikes, warning');
        let extra_put_asset = if ((notional * entry_price) > put_asset) { // TODO understand
            (notional * entry_price) - put_asset
        } else {
            put_asset - (notional * entry_price)
        };

        (extra_put_asset / strike) + call_asset
    } else { // DEBUG CURRENTLY HERE
        assert(strike < entry_price, 'certainly puts?');
        let extra_call_asset = if (call_asset > notional) { // I don't fucking get this.
            call_asset - notional
        } else {
            notional - call_asset
        };
        (extra_call_asset * strike) + put_asset
    }
}

#[cfg(test)]
fn test_convert_excess() {
    let x_at_strike = FixedTrait::from_felt(0x10c7ebc96a119c8bd); // 1.0488088481662097
    let y_at_strike = FixedTrait::from_felt(0x6253699028cfb2bd398); // 1573.2132722467607
    let x = FixedTrait::from_felt(0x100000000000000000); // 1
    let strike = FixedTrait::from_felt(0x5dc0000000000000000); // 1500
    let curr_price = FixedTrait::from_felt(0x6720000000000000000); // 1650
    let calls = false;
    let res = convert_excess(x_at_strike, y_at_strike, x, strike, curr_price, calls);
    'res'.print();
    res.print(); // 0x66e6d320524ee400704 = 1646.426544496075
}
