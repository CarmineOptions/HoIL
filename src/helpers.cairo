use core::array::SpanTrait;
use core::traits::TryInto;
use array::ArrayTrait;
use traits::Into;
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


fn toU256_balance(x: Fixed, decimals: u128) -> u256 {
    // converts for example 1.2 ETH (as Cubit float) to int(1.2*10**18)

    // We will guide you through with an example
    // x = 1.2 * 2**64 (example input... 2**64 since it is Cubit)
    // We want to divide the number by 2**64 and multiply by 10**18 to get number in the "wei style
    // But the order is important, first multiply and then divide, otherwise the .2 would be lost.
    // (1.2 * 2**64) * 10**18 / 2**64
    // We can split the 10*18 to (2**18 * 5**18)
    // (1.2 * 2**64) * 2**18 * 5**18 / 2**64
    let five_to_dec = pow(5, decimals);

    let x_5 = x.mag * five_to_dec;
    let _64_minus_dec = 64 - decimals;

    let decreased_part = pow(2, _64_minus_dec);

    let (q, _) = integer::u128_safe_divmod(
        x_5, decreased_part.try_into().expect('toU256 - dp zero')
    );

    q.into()
}

fn gcd(mut x: u128, mut y: u128) -> u128 {
    while y != 0 {
        let temp = y;
        y = x % y;
        x = temp;
    };
    x
}

fn lcm(x: u128, y: u128) -> u128 {
    let gcd_res = gcd(x, y);
    (x * y) / gcd_res
}

fn closest_value(a: u128, b: u128, c: u128) -> u128 {
    let lcm_bc = lcm(b, c);
    
    // Find the closest multiple of LCM(b, c) to a
    let closest_x = lcm_bc * ((a + lcm_bc - 1) / lcm_bc);
    
    closest_x
}