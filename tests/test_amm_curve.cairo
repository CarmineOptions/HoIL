#[cfg(test)]
mod tests {
    use cubit::f128::types::fixed::{Fixed, FixedTrait};

    use hoil::helpers::percent;
    use hoil::amm_curve::{convert_excess, compute_portfolio_value};

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
