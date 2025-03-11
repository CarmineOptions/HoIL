use cubit::f128::types::fixed::{Fixed, FixedTrait};


/// Calculates the liquidity (L) for user position in CLMM pool.
/// Can not be caculated for price above upper bound of price range,
/// as holdings of base token is zero and corresponding amount of quote token holdings can't be
/// estimated.
/// @param price_a: Lower bound price
/// @param price_b: Upper bound price
/// @param curr_price: Current price
/// @param amount_x: Amount of token X (notional)
/// @return Fixed: Liquidity value
fn calculate_liquidity(
    price_a: Fixed, price_b: Fixed, curr_price: Fixed, amount_x: Fixed,
) -> Fixed {
    // Validate inputs
    assert(price_a < price_b, 'Invalid price bounds');
    assert(curr_price > FixedTrait::ZERO(), 'Invalid current price');
    assert(amount_x > FixedTrait::ZERO(), 'Invalid amount');
    assert(curr_price < price_b, 'No base token holdings');
    // Calculate liquidity based on current price position
    if curr_price <= price_a {
        // All liquidity is in token X
        return amount_x * (price_a.sqrt() * price_b.sqrt()) / (price_b.sqrt() - price_a.sqrt());
    } else {
        // Price is within range, liquidity split between X and Y
        return amount_x * curr_price.sqrt() * price_b.sqrt() / (price_b.sqrt() - curr_price.sqrt());
    }
}


/// Calculates the portfolio holdings for a given liquidity position
/// @param liquidity: Position liquidity
/// @param price_a: Lower bound price
/// @param price_b: Upper bound price
/// @param curr_price: Current price
/// @return (Fixed, Fixed): Amount of token X and token Y in position
fn calculate_portfolio_holdings_from_liquidity(
    liquidity: Fixed, price_a: Fixed, price_b: Fixed, curr_price: Fixed,
) -> (Fixed, Fixed) {
    assert(liquidity > FixedTrait::ZERO(), 'Invalid liquidity');
    assert(price_a < price_b, 'Invalid price bounds');
    assert(curr_price > FixedTrait::ZERO(), 'Invalid current price');

    let mut amount_x = FixedTrait::ZERO();
    let mut amount_y = FixedTrait::ZERO();

    if curr_price <= price_a {
        // All value in token X
        amount_x = liquidity
            * (price_b.sqrt() - price_a.sqrt())
            / (price_a.sqrt() * price_b.sqrt());
    } else if curr_price >= price_b {
        // All value in token Y
        amount_y = liquidity * (price_b.sqrt() - price_a.sqrt());
    } else {
        // Split between X and Y
        amount_x = liquidity
            * (price_b.sqrt() - curr_price.sqrt())
            / (curr_price.sqrt() * price_b.sqrt());
        amount_y = liquidity * (curr_price.sqrt() - price_a.sqrt());
    }

    (amount_x, amount_y)
}

#[cfg(test)]
mod tests {
    use cubit::f128::types::fixed::{Fixed, FixedTrait};

    #[test]
    fn test_calculate_liquidity() {
        // Test case 1: Current price within range
        let price_a = FixedTrait::from_unscaled_felt(1500);
        let price_b = FixedTrait::from_unscaled_felt(2500);
        let curr_price = FixedTrait::from_unscaled_felt(2000);
        let amount_x = FixedTrait::from_unscaled_felt(10);
        let expected_liquidity = FixedTrait::from_felt(78141661856348471208709);
        let result = super::calculate_liquidity(price_a, price_b, curr_price, amount_x);
        assert(result == expected_liquidity, 'wrong liquidity, case 1');

        // Test case 2: Current price is below lower bound
        let curr_price_below = FixedTrait::from_unscaled_felt(1000);
        let result_below = super::calculate_liquidity(price_a, price_b, curr_price_below, amount_x);
        let expected_liquidity_case2 = FixedTrait::from_felt(31696041202474895019129);
        assert(result_below == expected_liquidity_case2, 'wrong liquidity, case 2');

        // Test case 3: Current price is below lower bound
        let curr_price_below = FixedTrait::from_unscaled_felt(1500);
        let result_below = super::calculate_liquidity(price_a, price_b, curr_price_below, amount_x);
        let expected_liquidity_case3 = FixedTrait::from_felt(31696041202474895019129);
        assert(result_below == expected_liquidity_case3, 'wrong liquidity, case 3');

        // Test case 4: Current price within range
        let price_a = FixedTrait::from_unscaled_felt(1600);
        let price_b = FixedTrait::from_unscaled_felt(3600);
        let curr_price = FixedTrait::from_unscaled_felt(2500);
        let amount_x = FixedTrait::from_unscaled_felt(5);
        let expected_liquidity_case4 = FixedTrait::from_unscaled_felt(1500);
        let result = super::calculate_liquidity(price_a, price_b, curr_price, amount_x);
        assert(result == expected_liquidity_case4, 'wrong liquidity, case 4');
    }


    #[test]
    #[should_panic(expected: ('Invalid price bounds',))]
    fn test_calculate_liquidity_wrong_range() {
        // Test case 1: Current price within range
        let price_a = FixedTrait::from_unscaled_felt(3500);
        let price_b = FixedTrait::from_unscaled_felt(2500);
        let curr_price = FixedTrait::from_unscaled_felt(2000);
        let amount_x = FixedTrait::from_unscaled_felt(10);

        let result = super::calculate_liquidity(price_a, price_b, curr_price, amount_x);
    }

    #[test]
    #[should_panic(expected: ('No base token holdings',))]
    fn test_calculate_liquidity_price_above_range() {
        // Test case 1: Current price within range
        let price_a = FixedTrait::from_unscaled_felt(1500);
        let price_b = FixedTrait::from_unscaled_felt(2500);
        let curr_price = FixedTrait::from_unscaled_felt(3000);
        let amount_x = FixedTrait::from_unscaled_felt(10);

        let result = super::calculate_liquidity(price_a, price_b, curr_price, amount_x);
    }

    /////////////////////
    #[test]
    fn test_calculate_portfolio_holdings_from_liquidity() {
        // Test case 1: Current price within range
        let price_a = FixedTrait::from_unscaled_felt(1500);
        let price_b = FixedTrait::from_unscaled_felt(2500);
        let curr_price = FixedTrait::from_unscaled_felt(2000);
        let liquidity = FixedTrait::from_felt(78141661856348471208709);

        let (amount_x, amount_y) = super::calculate_portfolio_holdings_from_liquidity(
            liquidity, price_a, price_b, curr_price
        );

        // Expected values calculated based on the liquidity formula
        let expected_x = FixedTrait::from_felt(184467440737095516159); // ~ 10
        let expected_y = FixedTrait::from_felt(468187805552140277251378); // ~ 25380
        assert(amount_x == expected_x, 'wrong amount x within range');
        assert(amount_y == expected_y, 'wrong amount y within range');

        // Test case 2: Current price below range (all in X)
        let curr_price_below = FixedTrait::from_unscaled_felt(1000);
        let liquidity_below = FixedTrait::from_felt(31696041202474895019129);

        let (amount_x_below, amount_y_below) = super::calculate_portfolio_holdings_from_liquidity(
            liquidity_below, price_a, price_b, curr_price_below
        );

        let expected_x_below = FixedTrait::from_felt(184467440737095516159); // ~ 10
        let expected_y_below = FixedTrait::ZERO();

        assert(amount_x_below == expected_x_below, 'wrong amount x below range');
        assert(amount_y_below == expected_y_below, 'wrong amount y below range');

        // Test case 3: Current price above range (all in Y)
        let curr_price_above = FixedTrait::from_unscaled_felt(3000);
        let liquidity_above = FixedTrait::from_felt(31696041202474895019129);

        let (amount_x_above, amount_y_above) = super::calculate_portfolio_holdings_from_liquidity(
            liquidity_above, price_a, price_b, curr_price_above
        );

        let expected_x_above = FixedTrait::ZERO();
        let expected_y_above = FixedTrait::from_felt(357219662945847345151999); // ~19364

        assert(amount_x_above == expected_x_above, 'wrong amount x above range');
        assert(amount_y_above == expected_y_above, 'wrong amount y above range');
    }

    #[test]
    #[should_panic(expected: ('Invalid liquidity',))]
    fn test_calculate_portfolio_holdings_invalid_liquidity() {
        let price_a = FixedTrait::from_unscaled_felt(1500);
        let price_b = FixedTrait::from_unscaled_felt(2500);
        let curr_price = FixedTrait::from_unscaled_felt(2000);
        let liquidity = FixedTrait::ZERO(); // liquidity cant be zero

        let (_amount_x, _amount_y) = super::calculate_portfolio_holdings_from_liquidity(
            liquidity, price_a, price_b, curr_price
        );
    }

    #[test]
    #[should_panic(expected: ('Invalid price bounds',))]
    fn test_calculate_portfolio_holdings_invalid_bounds() {
        let price_a = FixedTrait::from_unscaled_felt(2500);
        let price_b = FixedTrait::from_unscaled_felt(1500); // price_b < price_a
        let curr_price = FixedTrait::from_unscaled_felt(2000);
        let liquidity = FixedTrait::from_unscaled_felt(1000);

        let (_amount_x, _amount_y) = super::calculate_portfolio_holdings_from_liquidity(
            liquidity, price_a, price_b, curr_price
        );
    }
}
