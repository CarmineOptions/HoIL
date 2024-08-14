use core::array::SpanTrait;
use core::traits::TryInto;
use array::ArrayTrait;
use traits::Into;
use option::OptionTrait;
use integer::u128_safe_divmod;
use debug::PrintTrait;

use cubit::f128::types::fixed::{Fixed, FixedTrait};

fn pow(a: u128, b: u128) -> u128 {
    let mut x: u128 = a;
    let mut n = b;

    if n == 0 {
        return 1;
    }

    let mut y = 1;
    let two = integer::u128_as_non_zero(2);

    loop {
        if n <= 1 {
            break;
        }

        let (div, rem) = integer::u128_safe_divmod(n, two);

        if rem == 1 {
            y = x * y;
        }

        x = x * x;
        n = div;
    };
    x * y
}

fn convert_from_int_to_Fixed(value: u128, decimals: u8) -> Fixed {
    // Overflows (fails) when converting approx 1 million ETH, would need to use u256 for that, different code path needed.
    // TODO test that it indeed overflows.

    let denom: u128 = pow(5, decimals.into());
    let numer: u128 = pow(2, 64 - decimals.into());

    let res: u128 = (value * numer) / denom;

    FixedTrait::from_felt(res.into())
}


fn convert_from_Fixed_to_int(value: Fixed, decimals: u8) -> u128 {
    assert(value.sign == false, 'cant convert -val to uint');

    (value.mag * pow(5, decimals.into())) / pow(2, (64 - decimals).into())
}


type Math64x61_ = felt252;

trait FixedHelpersTrait {
    fn assert_nn_not_zero(self: Fixed, msg: felt252);
    fn assert_nn(self: Fixed, errmsg: felt252);
    fn to_legacyMath(self: Fixed) -> Math64x61_;
    fn from_legacyMath(num: Math64x61_) -> Fixed;
}

impl FixedHelpersImpl of FixedHelpersTrait {
    fn assert_nn_not_zero(self: Fixed, msg: felt252) {
        assert(self > FixedTrait::ZERO(), msg);
    }

    fn assert_nn(self: Fixed, errmsg: felt252) {
        assert(self >= FixedTrait::ZERO(), errmsg)
    }

    fn to_legacyMath(self: Fixed) -> Math64x61_ {
        // TODO: Find better way to do this, this is just wrong
        // Fixed is 8 times the old math
        let new: felt252 = (self / FixedTrait::from_unscaled_felt(8)).into();
        new
    }

    fn from_legacyMath(num: Math64x61_) -> Fixed {
        // 2**61 is 8 times smaller than 2**64
        // so we can just multiply old legacy math number by 8 to get cubit
        FixedTrait::from_felt(num * 8)
    }
}

fn percent<T, impl TInto: Into<T, felt252>>(inp: T) -> Fixed {
    FixedTrait::from_unscaled_felt(inp.into()) / FixedTrait::from_unscaled_felt(100)
}

fn reverse(inp: Span<Fixed>) -> Span<Fixed> {
    let mut res = ArrayTrait::<Fixed>::new();
    let mut i = inp.len() - 1;
    loop {
        if (i == 0) {
            res.append(*(inp.at(i)));
            break;
        }
        res.append(*(inp.at(i)));
        i -= 1;
    };
    res.span()
}


#[cfg(test)]
mod tests {
    use super::{pow, convert_from_int_to_Fixed, convert_from_Fixed_to_int, percent, reverse};
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
        assert(convert_from_int_to_Fixed(1000000000000000000, 18) == FixedTrait::ONE(), 'Should be one');
        assert(convert_from_int_to_Fixed(1, 0) == FixedTrait::from_unscaled_felt(1), '1 with 0 decimals');
        assert(convert_from_int_to_Fixed(100, 2) == FixedTrait::ONE(), '100 with 2 decimals');
    }

    #[test]
    fn test_convert_from_Fixed_to_int() {
        let oneeth = convert_from_Fixed_to_int(FixedTrait::ONE(), 18);
        assert(oneeth == 1000000000000000000, 'oneeth?');
        assert(convert_from_Fixed_to_int(FixedTrait::from_unscaled_felt(1), 0) == 1, '1 with 0 decimals');
        assert(convert_from_Fixed_to_int(FixedTrait::ONE(), 2) == 100, '1 with 2 decimals');
    }

    #[test]
    fn test_percent() {
        assert(percent(100) == FixedTrait::ONE(), '100% should be 1');
        assert(percent(50) == FixedTrait::from_unscaled_felt(1) / FixedTrait::from_unscaled_felt(2), '50% should be 0.5');
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
}
