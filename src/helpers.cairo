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

    let denom: u128 = pow(5, decimals.into());
    let numer: u128 = pow(2, 64 - decimals.into());

    let res: u128 = (value * numer) / denom;

    FixedTrait::from_felt(res.into())
}


fn convert_from_Fixed_to_int(value: Fixed, decimals: u8) -> u128 {
    assert(value.sign == false, 'cant convert -val to uint');

    (value.mag * pow(5, decimals.into())) / pow(2, (64 - decimals).into())
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
