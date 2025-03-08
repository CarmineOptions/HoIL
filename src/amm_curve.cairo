use cubit::f128::types::fixed::{Fixed, FixedTrait};

/// Calculates new portfolio holdings using constant product formula when price changes
/// This implements x * y = k (constant product) formula where the product of holdings remains
/// constant
///
/// # Arguments
/// * `x_initial_holdings` - Initial holdings of token X
/// * `initial_price` - Initial price of token Y in terms of token X
/// * `new_price` - New price of token Y in terms of token X
///
/// # Returns
/// * Tuple of (x_amount, y_amount) representing updated portfolio holdings
///
/// # Panics
/// * If initial_price is zero or negative
/// * If new_price is zero or negative
/// * If x_initial_holdings is zero or negative
fn calculate_portfolio_holdings_with_constnant_product_function(
    x_initial_holdings: Fixed, initial_price: Fixed, new_price: Fixed
) -> (Fixed, Fixed) {
    assert(initial_price > FixedTrait::ZERO(), 'Invalid initial price');
    assert(x_initial_holdings > FixedTrait::ZERO(), 'Invalid initial holdings');
    assert(new_price > FixedTrait::ZERO(), 'Invalid new price');

    let price_change = initial_price / new_price;
    let x_amount = price_change.sqrt() * x_initial_holdings;

    let y_amount = x_amount * new_price;

    (x_amount, y_amount)
}


#[cfg(test)]
mod tests {
    use cubit::f128::types::fixed::{Fixed, FixedTrait};

    #[test]
    fn test_calculate_portfolio_holdings_with_constnant_product_function() {
        // Test case 1: Price increases
        let x_initial_holdings = FixedTrait::from_unscaled_felt(100);
        let initial_price = FixedTrait::from_unscaled_felt(2000);
        let new_price = FixedTrait::from_unscaled_felt(3000);

        let (x_amount, y_amount) =
            super::calculate_portfolio_holdings_with_constnant_product_function(
            x_initial_holdings, initial_price, new_price
        );

        // Expected values:
        // price_change = 2000/3000 = 2/3
        // x_amount = sqrt(2/3) * 100 = 100 * 0.816496... = 81.6496...
        // y_amount = 81.6496... * 3000 = 244948.8...
        let expected_x = FixedTrait::from_felt(1506170346379883315200); // ~81.6496
        let expected_y = FixedTrait::from_felt(4518511039139649945600000); // ~244948.8

        assert((x_amount - expected_x).abs() < FixedTrait::from_felt(1), 'wrong x when price increases');
        assert((y_amount - expected_y).abs() < FixedTrait::from_felt(1), 'wrong y when price increases');

        // Test case 2: Price decreases
        let initial_price = FixedTrait::from_unscaled_felt(2000);
        let new_price = FixedTrait::from_unscaled_felt(1000);

        let (x_amount, y_amount) =
            super::calculate_portfolio_holdings_with_constnant_product_function(
            x_initial_holdings, initial_price, new_price
        );

        // Expected values:
        // price_change = 2000/1000 = 2
        // x_amount = sqrt(2) * 100 = 100 * 1.414213... = 141.4213...
        // y_amount = 141.4213... * 1000 = 141421.3...
        let expected_x = FixedTrait::from_felt(2608763564657632870400); // ~141.4213
        let expected_y = FixedTrait::from_felt(2608763564657632870400000); // ~141421.3

        assert((x_amount - expected_x).abs() < FixedTrait::from_felt(1), 'wrong x when price decreases');
        assert((y_amount - expected_y).abs() < FixedTrait::from_felt(1), 'wrong y when price decreases');

        // Test case 3: No price change
        let initial_price = FixedTrait::from_unscaled_felt(2000);
        let new_price = FixedTrait::from_unscaled_felt(2000);

        let (x_amount, y_amount) =
            super::calculate_portfolio_holdings_with_constnant_product_function(
            x_initial_holdings, initial_price, new_price
        );

        // Expected values:
        // price_change = 2000/2000 = 1
        // x_amount = sqrt(1) * 100 = 100 * 1 = 100
        // y_amount = 100 * 2000 = 200000
        let expected_x = FixedTrait::from_unscaled_felt(100);
        let expected_y = FixedTrait::from_unscaled_felt(200000);

        assert(x_amount == expected_x, 'wrong x with no price change');
        assert(y_amount == expected_y, 'wrong y with no price change');

        // Test case 4: Fractional values
        let x_initial_holdings = FixedTrait::from_felt(9223372036854775808); // ~0.5
        let initial_price = FixedTrait::from_felt(73786976294838206464); // ~4
        let new_price = FixedTrait::from_felt(36893488147419103232); // ~2

        let (x_amount, y_amount) =
            super::calculate_portfolio_holdings_with_constnant_product_function(
            x_initial_holdings, initial_price, new_price
        );

        // Expected values:
        // price_change = 4/2 = 2
        // x_amount = sqrt(2) * 0.5 = 0.5 * 1.414213... = 0.7071...
        // y_amount = 0.7071... * 2 = 1.4142...
        let expected_x = FixedTrait::from_felt(13043817823288164352); // ~0.707
        let expected_y = FixedTrait::from_felt(26087635646576328704); // ~1.414

        assert((x_amount - expected_x).abs() < FixedTrait::from_felt(1), 'wrong x with frac val');
        assert((y_amount - expected_y).abs() < FixedTrait::from_felt(1), 'wrong y with frac val');

        // Test case 5: Large values
        let x_initial_holdings = FixedTrait::from_unscaled_felt(1000000);
        let initial_price = FixedTrait::from_unscaled_felt(5000);
        let new_price = FixedTrait::from_unscaled_felt(6000);

        let (x_amount, y_amount) =
            super::calculate_portfolio_holdings_with_constnant_product_function(
            x_initial_holdings, initial_price, new_price
        );

        // Expected values:
        // price_change = 5000/6000 = 0.833...
        // x_amount = sqrt(0.833...) * 1000000 = 1000000 * 0.912871... = 912871...
        // y_amount = 912871... * 6000 = 5477226...
        let expected_x = FixedTrait::from_felt(16839496401636294656000000); // ~912871
        let expected_y = FixedTrait::from_felt(101036978409817767936000000000); // ~5477226000

        assert((x_amount - expected_x).abs() < FixedTrait::from_felt(1), 'wrong x with large values');
        assert((y_amount - expected_y).abs() < FixedTrait::from_felt(1), 'wrong y with large values');
    }

    #[test]
    #[should_panic(expected: ('Invalid initial price',))]
    fn test_calculate_portfolio_holdings_zero_initial_price() {
        let x_initial_holdings = FixedTrait::from_unscaled_felt(100);
        let initial_price = FixedTrait::ZERO();
        let new_price = FixedTrait::from_unscaled_felt(2000);

        let (_x_amount, _y_amount) =
            super::calculate_portfolio_holdings_with_constnant_product_function(
            x_initial_holdings, initial_price, new_price
        );
    }

    #[test]
    #[should_panic(expected: ('Invalid initial price',))]
    fn test_calculate_portfolio_holdings_negative_initial_price() {
        let x_initial_holdings = FixedTrait::from_unscaled_felt(100);
        let initial_price = FixedTrait::from_unscaled_felt(-10);
        let new_price = FixedTrait::from_unscaled_felt(2000);

        let (_x_amount, _y_amount) =
            super::calculate_portfolio_holdings_with_constnant_product_function(
            x_initial_holdings, initial_price, new_price
        );
    }

    #[test]
    #[should_panic(expected: ('Invalid new price',))]
    fn test_calculate_portfolio_holdings_zero_new_price() {
        let x_initial_holdings = FixedTrait::from_unscaled_felt(100);
        let initial_price = FixedTrait::from_unscaled_felt(2000);
        let new_price = FixedTrait::ZERO();

        let (_x_amount, _y_amount) =
            super::calculate_portfolio_holdings_with_constnant_product_function(
            x_initial_holdings, initial_price, new_price
        );
    }

    #[test]
    #[should_panic(expected: ('Invalid new price',))]
    fn test_calculate_portfolio_holdings_negative_new_price() {
        let x_initial_holdings = FixedTrait::from_unscaled_felt(100);
        let initial_price = FixedTrait::from_unscaled_felt(2000);
        let new_price = FixedTrait::from_unscaled_felt(-500);

        let (_x_amount, _y_amount) =
            super::calculate_portfolio_holdings_with_constnant_product_function(
            x_initial_holdings, initial_price, new_price
        );
    }

    #[test]
    #[should_panic(expected: ('Invalid initial holdings',))]
    fn test_calculate_portfolio_holdings_zero_initial_holdings() {
        let x_initial_holdings = FixedTrait::ZERO();
        let initial_price = FixedTrait::from_unscaled_felt(2000);
        let new_price = FixedTrait::from_unscaled_felt(3000);

        let (_x_amount, _y_amount) =
            super::calculate_portfolio_holdings_with_constnant_product_function(
            x_initial_holdings, initial_price, new_price
        );
    }

    #[test]
    #[should_panic(expected: ('Invalid initial holdings',))]
    fn test_calculate_portfolio_holdings_negative_initial_holdings() {
        let x_initial_holdings = FixedTrait::from_unscaled_felt(-50);
        let initial_price = FixedTrait::from_unscaled_felt(2000);
        let new_price = FixedTrait::from_unscaled_felt(3000);

        let (_x_amount, _y_amount) =
            super::calculate_portfolio_holdings_with_constnant_product_function(
            x_initial_holdings, initial_price, new_price
        );
    }
}
