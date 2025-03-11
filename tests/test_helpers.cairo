#[cfg(test)]
mod tests {
    use hoil::helpers::{
        pow, convert_from_int_to_Fixed, convert_from_Fixed_to_int, percent, reverse, toU256_balance
    };
    use cubit::f128::types::fixed::{Fixed, FixedTrait};
    use array::ArrayTrait;

    #[test]
    fn test_pow() {
        assert(pow(2, 3) == 8, 'pow 2^3 should be 8');
        assert(pow(3, 2) == 9, 'pow 3^2 should be 9');
        assert(pow(5, 0) == 1, 'pow 5^0 should be 1');
        assert(pow(1, 100) == 1, 'pow 1^100 should be 1');
    }

    #[test]
    fn test_convert_from_int_to_Fixed() {
        assert(
            convert_from_int_to_Fixed(1000000000000000000, 18) == FixedTrait::ONE(), 'Should be one'
        );
        assert(
            convert_from_int_to_Fixed(1, 0) == FixedTrait::from_unscaled_felt(1),
            '1 with 0 decimals'
        );
        assert(convert_from_int_to_Fixed(100, 2) == FixedTrait::ONE(), '100 with 2 decimals');
    }

    #[test]
    fn test_convert_from_Fixed_to_int() {
        let oneeth = convert_from_Fixed_to_int(FixedTrait::ONE(), 18);
        assert(oneeth == 1000000000000000000, 'oneeth?');
        assert(
            convert_from_Fixed_to_int(FixedTrait::from_unscaled_felt(1), 0) == 1,
            '1 with 0 decimals'
        );
        assert(convert_from_Fixed_to_int(FixedTrait::ONE(), 2) == 100, '1 with 2 decimals');
    }

    #[test]
    fn test_percent() {
        assert(percent(100) == FixedTrait::ONE(), '100% should be 1');
        assert(
            percent(50) == FixedTrait::from_unscaled_felt(1) / FixedTrait::from_unscaled_felt(2),
            '50% should be 0.5'
        );
        assert(percent(0) == FixedTrait::ZERO(), '0% should be 0');
    }

    #[test]
    fn test_reverse() {
        let mut arr = ArrayTrait::new();
        arr.append(FixedTrait::from_unscaled_felt(1));
        arr.append(FixedTrait::from_unscaled_felt(2));
        arr.append(FixedTrait::from_unscaled_felt(3));
        let reversed = reverse(arr.span());
        assert(*reversed.at(0) == FixedTrait::from_unscaled_felt(3), 'First element should be 3');
        assert(*reversed.at(1) == FixedTrait::from_unscaled_felt(2), 'Second element should be 2');
        assert(*reversed.at(2) == FixedTrait::from_unscaled_felt(1), 'Third element should be 1');
    }

    #[test]
    fn test_toU256_balance() {
        let res1 = toU256_balance(FixedTrait::ONE(), 18);
        let res2 = toU256_balance(FixedTrait::from_unscaled_felt(50), 12);
        let res3 = toU256_balance(FixedTrait::from_unscaled_felt(1_000), 6);

        assert(res1 == 1000000000000000000, 'res1');
        assert(res2 == 50000000000000, 'res2');
        assert(res3 == 1000000000, 'res3');

        let res4 = toU256_balance(FixedTrait::from_felt(998496246800754098506), 18);
        let res5 = toU256_balance(FixedTrait::from_felt(20738488236427709357), 12);
        let res6 = toU256_balance(FixedTrait::from_felt(1848056986831751282079825), 6);

        assert(res4 == 54128589999999999999, 'res4'); // 1 gwei rounding error
        assert(res5 == 1124235699999, 'res5'); // also
        assert(res6 == 100183369999, 'res6'); // also
    }
}
