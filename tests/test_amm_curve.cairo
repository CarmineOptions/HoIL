use cubit::f128::types::fixed::{Fixed, FixedTrait};

use hoil::helpers::percent;
use hoil::amm_curve::{convert_excess, compute_portfolio_value};

#[cfg(test)]
    mod tests {
        #[test]
    fn test_convert_excess() {
        let x_at_strike = FixedTrait::from_felt(0x10c7ebc96a119c8bd); // 1.0488088481662097
        let y_at_strike = FixedTrait::from_felt(0x6253699028cfb2bd398); // 1573.2132722467607
        let x = FixedTrait::from_felt(0x100000000000000000); // 1
        let strike = FixedTrait::from_felt(0x5dc0000000000000000); // 1500
        let curr_price = FixedTrait::from_felt(0x6720000000000000000); // 1650
        let calls = false;
        let res = convert_excess(x_at_strike, y_at_strike, x, strike, curr_price, calls);
        res.print(); // 0x66e6d320524ee400704 = 1646.426544496075
    }


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
}
