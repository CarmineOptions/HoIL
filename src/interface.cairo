use core::array::SpanTrait;
use starknet::ContractAddress;
use starknet::ClassHash;

#[starknet::interface]
trait IILHedge<TContractState> {
    fn hedge(
        ref self: TContractState,
        notional: u128,
        quote_token_addr: ContractAddress,
        base_token_addr: ContractAddress,
        expiry: u64
    );
    fn price_hedge(
        self: @TContractState,
        notional: u128,
        quote_token_addr: ContractAddress,
        base_token_addr: ContractAddress,
        expiry: u64
    ) -> (u128, u128);
    fn upgrade(ref self: TContractState, impl_hash: ClassHash);
}

#[starknet::contract]
mod ILHedge {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use traits::{Into, TryInto};

    use starknet::ContractAddress;
    use starknet::ClassHash;
    use starknet::{get_caller_address, get_contract_address};
    use starknet::syscalls::{replace_class_syscall};

    use cubit::f128::types::fixed::{Fixed, FixedTrait};

    use hoil::amm_curve::compute_portfolio_value;
    use hoil::constants::{AMM_ADDR, TOKEN_ETH_ADDRESS, TOKEN_USDC_ADDRESS, TOKEN_STRK_ADDRESS};
    use hoil::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use hoil::hedging::{
        iterate_strike_prices,
        buy_options_at_strike_to_hedge_at,
        price_options_at_strike_to_hedge_at
    };
    use hoil::pragma::get_pragma_median_price;
    use hoil::helpers::{convert_from_Fixed_to_int, convert_from_int_to_Fixed};

    #[storage]
    struct Storage {}

    #[external(v0)]
    impl ILHedge of super::IILHedge<ContractState> {
        fn hedge(
            ref self: ContractState,
            notional: u128,
            quote_token_addr: ContractAddress,
            base_token_addr: ContractAddress,
            expiry: u64
        ) {
            let pricing: (u128, u128) = Self::price_hedge(
                @self, notional, quote_token_addr, base_token_addr, expiry
            );
            let (cost_quote, cost_base) = pricing;
            let base_token = IERC20Dispatcher { contract_address: base_token_addr };
            base_token.transferFrom(get_caller_address(), get_contract_address(), cost_base.into());
            base_token.approve(AMM_ADDR.try_into().unwrap(), cost_base.into()); // approve AMM to spend

            let quote_token = IERC20Dispatcher { contract_address: quote_token_addr };
            quote_token.transferFrom(get_caller_address(), get_contract_address(), cost_quote.into());
            quote_token.approve(AMM_ADDR.try_into().unwrap(), cost_quote.into()); // approve AMM to spend

            let curr_price = get_pragma_median_price(quote_token_addr, base_token_addr);
            // iterate available strike prices and get them into pairs of (bought strike, at which strike one should be hedged)
            let mut strikes_calls = iterate_strike_prices(
                curr_price, quote_token_addr, base_token_addr, expiry, true
            );

            loop {
                match strikes_calls.pop_front() {
                    Option::Some(strike_pair) => {
                        let (tobuy, tohedge) = *strike_pair;
                        // compute how much portf value would be at each hedged strike
                        // converts the excess to the hedge result asset (calls -> convert to eth)
                        // for each strike
                        let portf_val_calls = compute_portfolio_value(
                            curr_price, notional, true, tohedge
                        ); // value of second asset is precisely as much as user put in, expecting conversion
                        assert(portf_val_calls > FixedTrait::ZERO(), 'portf val calls < 0?');
                        assert(portf_val_calls.sign == false, 'portf val neg??');
                        let notional_fixed = convert_from_int_to_Fixed(notional, 18);
                        let amount_to_hedge = notional_fixed
                            - portf_val_calls; // difference between converted and leftover amounts is how much one should be hedging against
                        // buy this much of previous strike price (fst in iterate_strike_prices())
                        buy_options_at_strike_to_hedge_at(
                            tobuy,
                            tohedge,
                            amount_to_hedge,
                            expiry,
                            quote_token_addr,
                            base_token_addr,
                            true
                        );
                    },
                    Option::None(()) => {
                        break;
                    }
                };
            };

            let mut strikes_puts = iterate_strike_prices(
                curr_price, quote_token_addr, base_token_addr, expiry, false
            );
            loop {
                match strikes_puts.pop_front() {
                    Option::Some(strike_pair) => {
                        let (tobuy, tohedge) = *strike_pair;
                        // compute how much portf value would be at each hedged strike
                        // converts the excess to the hedge result asset
                        // for each strike
                        let portf_val_puts = compute_portfolio_value(
                            curr_price, notional, false, tohedge
                        ); // value of second asset is precisely as much as user put in, expecting conversion
                        assert(portf_val_puts > FixedTrait::ZERO(), 'portf val puts < 0?');
                        assert(
                            portf_val_puts < (convert_from_int_to_Fixed(notional, 18) * curr_price),
                            'some loss expected'
                        ); // portf_val_puts is in quote token
                        assert(portf_val_puts.sign == false, 'portf val neg??');
                        let notional_fixed = if quote_token_addr == TOKEN_USDC_ADDRESS.try_into().unwrap() {
                            convert_from_int_to_Fixed(notional, 6)
                        } else {
                            convert_from_int_to_Fixed(notional, 18)
                        }; // difference between converted and premia amounts is how much one should be hedging against
                        let amount_to_hedge = notional_fixed
                            - portf_val_puts; // in quote token, with decimals
                        buy_options_at_strike_to_hedge_at(
                            tobuy,
                            tohedge,
                            amount_to_hedge,
                            expiry,
                            quote_token_addr,
                            base_token_addr,
                            false
                        );
                    },
                    Option::None(()) => {
                        break;
                    }
                };
            };    
        }

        fn upgrade(ref self: ContractState, impl_hash: ClassHash) {
            let caller: ContractAddress = get_caller_address();
            let owner: ContractAddress =
                0x001dd8e12b10592676E109C85d6050bdc1E17adf1be0573a089E081C3c260eD9
                .try_into()
                .unwrap();
            assert(owner == caller, 'invalid caller');
            replace_class_syscall(impl_hash);
        }

        fn price_hedge(
            self: @ContractState,
            notional: u128,
            quote_token_addr: ContractAddress,
            base_token_addr: ContractAddress,
            expiry: u64
        ) -> (u128, u128) {
            let curr_price = get_pragma_median_price(quote_token_addr, base_token_addr);

            // iterate available strike prices and get them into pairs of (bought strike, at which strike one should be hedged)
            let mut strikes_calls = iterate_strike_prices(
                curr_price, quote_token_addr, base_token_addr, expiry, true
            );
            let mut strikes_puts = iterate_strike_prices(
                curr_price, quote_token_addr, base_token_addr, expiry, false
            );

            let mut already_hedged: Fixed = FixedTrait::ZERO();
            let mut cost_quote = 0;
            let mut cost_base = 0;

            loop {
                match strikes_calls.pop_front() {
                    Option::Some(strike_pair) => {
                        let (tobuy, tohedge) = *strike_pair;
                        // compute how much portfolio value would be at each hedged strike
                        // converts the excess to the hedge result asset (calls -> convert to eth)
                        // for each strike
                        let portf_val_calls = compute_portfolio_value(
                            curr_price, notional, true, tohedge
                        ); // value of second asset is precisely as much as user put in, expecting conversion
                        assert(portf_val_calls > FixedTrait::ZERO(), 'portf val calls < 0?');
                        assert(portf_val_calls.sign == false, 'portf val neg??');
                        let notional_fixed = convert_from_int_to_Fixed(
                            notional, 18
                        ); // difference between converted and premia amounts is how much one should be hedging against
                        //assert((notional_fixed - portf_val_calls) > already_hedged, "amounttohedge neg??"); // can't compile with it for some reason??
                        let amount_to_hedge = (notional_fixed - portf_val_calls) - already_hedged;
                        already_hedged += amount_to_hedge;
                        cost_base +=
                            price_options_at_strike_to_hedge_at(
                                tobuy, tohedge, amount_to_hedge, expiry, true, base_token_addr, quote_token_addr
                            );
                    },
                    Option::None(()) => {
                        break;
                    }
                };
            };
            loop {
                match strikes_puts.pop_front() {
                    Option::Some(strike_pair) => {
                        let (tobuy, tohedge) = *strike_pair;
                        // compute how much portf value would be at each hedged strike
                        // converts the excess to the hedge result asset
                        // for each strike
                        let portf_val_puts = compute_portfolio_value(
                            curr_price, notional, false, tohedge
                        ); // value of second asset is precisely as much as user put in, expecting conversion
                        assert(portf_val_puts > FixedTrait::ZERO(), 'portf val puts < 0?');
                        assert(
                            portf_val_puts < (convert_from_int_to_Fixed(notional, 18) * curr_price),
                            'some loss expected'
                        ); // portf_val_puts is in quote token
                        assert(portf_val_puts.sign == false, 'portf val neg??');
                        let notional_fixed = if quote_token_addr == TOKEN_USDC_ADDRESS.try_into().unwrap() {
                            convert_from_int_to_Fixed(notional, 6)
                        } else {
                            convert_from_int_to_Fixed(notional, 18)
                        }; // difference between converted and premia amounts is how much one should be hedging against
                        let amount_to_hedge = notional_fixed
                            - portf_val_puts; // in quote token, with decimals
                        cost_quote +=
                            price_options_at_strike_to_hedge_at(
                                tobuy, tohedge, amount_to_hedge, expiry, false, base_token_addr, quote_token_addr
                            );
                    },
                    Option::None(()) => {
                        break;
                    }
                };
            };
            (cost_quote, cost_base)
        }
    }
}
