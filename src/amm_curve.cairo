use hoil::helpers::convert_from_int_to_Fixed;

use cubit::f128::types::fixed::{Fixed, FixedTrait};


// Computes the portfolio value if it moved from current (fetched from Empiric) to the specific strike
fn compute_portfolio_value(curr_price: Fixed, notional: u128, calls: bool, strike: Fixed) -> Fixed {
    let x = convert_from_int_to_Fixed(notional, 18);
    let y = x * curr_price;
    let k = x * y;
    
    let y_at_strike = k.sqrt() * strike.sqrt();
    let x_at_strike = k.sqrt() / strike.sqrt();
    
    convert_excess(x_at_strike, y_at_strike, x, strike, curr_price, calls)
}

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
        assert(strike > entry_price, 'strike<=entry price');
        assert(call_asset < notional, 'hedging at odd strikes, warning');
        let extra_put_asset = if ((notional * entry_price) > put_asset) {
            (notional * entry_price) - put_asset
        } else {
            put_asset - (notional * entry_price)
        };
        let res: Fixed = (extra_put_asset / strike) + call_asset;
        res
    } else {
        assert(strike < entry_price, 'strike>=entry price');
        let extra_call_asset = if (call_asset > notional) {
            call_asset - notional
        } else {
            notional - call_asset
        };
        let res: Fixed = (extra_call_asset * strike) + put_asset;
        res
    }
}
