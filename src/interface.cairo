use core::array::SpanTrait;
use starknet::ContractAddress;
use starknet::ClassHash;
use cubit::f128::types::fixed::Fixed;


#[starknet::interface]
trait IILHedge<TContractState> {
    fn hedge_open(
        ref self: TContractState,
        notional: u128,
        quote_token_addr: ContractAddress,
        base_token_addr: ContractAddress,
        expiry: u64,
        limit_price: (u128, u128),
        hedge_at_price: Option<Fixed>
    );
    fn hedge_close(
        ref self: TContractState,
        token_id: u256,
    );
    fn hedge_settle(
        ref self: TContractState,
        token_id: u256,
    );
    fn price_hedge(
        self: @TContractState,
        notional: u128,
        quote_token_addr: ContractAddress,
        base_token_addr: ContractAddress,
        expiry: u64,
        hedge_at_price: Option<Fixed>
    ) -> (u128, u128);
    fn upgrade(ref self: TContractState, impl_hash: ClassHash);
    fn get_owner(self: @TContractState) -> ContractAddress;
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
    use hoil::constants::{AMM_ADDR, TOKEN_ETH_ADDRESS, TOKEN_USDC_ADDRESS, TOKEN_STRK_ADDRESS, TOKEN_BTC_ADDRESS, HEDGE_TOKEN_ADDRESS};
    use hoil::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use hoil::carmine::{IAMMDispatcher, IAMMDispatcherTrait};
    use hoil::hedging::{
        iterate_strike_prices,
        buy_options_at_strike_to_hedge_at,
        price_options_at_strike_to_hedge_at,
        hedge_finalize
    };
    use hoil::pragma::get_pragma_median_price;
    use hoil::helpers::{convert_from_Fixed_to_int, convert_from_int_to_Fixed};
    use hoil::hedge_token::{OptionToken, IHedgeTokenDispatcher, IHedgeTokenDispatcherTrait};

    #[storage]
    struct Storage {
        owner: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        HedgeOpened: HedgeOpenedEvent,
        HedgeClosed: HedgeFinalizedEvent,
        HedgeSettled: HedgeFinalizedEvent,
    }

    #[derive(Drop, starknet::Event)]
    struct HedgeOpenedEvent {
        #[key]
        user: ContractAddress,
        hedge_token_id: u256,
        amount: u256,
        quote_token: ContractAddress,
        base_token: ContractAddress,
        maturity: u64
    }

    #[derive(Drop, starknet::Event)]
    struct HedgeFinalizedEvent {
        #[key]
        user: ContractAddress,
        hedge_token_id: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.owner.write(owner);
    }

    #[abi(embed_v0)]
    impl ILHedge of super::IILHedge<ContractState> {
        fn hedge_open(
            ref self: ContractState,
            notional: u128,
            quote_token_addr: ContractAddress,
            base_token_addr: ContractAddress,
            expiry: u64,
            limit_price: (u128, u128),
            hedge_at_price: Option<Fixed>
        ) {
            assert(quote_token_addr != TOKEN_BTC_ADDRESS.try_into().unwrap(), 'NotImplementedYet');
            
            let pricing: (u128, u128) = Self::price_hedge(
                @self, notional, quote_token_addr, base_token_addr, expiry, hedge_at_price
            );
            let (cost_quote, cost_base) = pricing;

            // check is price does not violate slippage limit
            let (limit_quote, limit_base) = limit_price;
            assert(cost_quote <= limit_quote, 'Quote cost exceeds limit');
            assert(cost_base <= limit_base, 'Base cost exceeds limit');

            let caller = get_caller_address();
            let contract_address = starknet::get_contract_address();

            let amm = IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() };
            
            // getting initial token balances
            let base_token = IERC20Dispatcher { contract_address: base_token_addr };
            let initial_base_token_balance = base_token.balanceOf(contract_address);
            let quote_token = IERC20Dispatcher { contract_address: quote_token_addr };
            let initial_quote_token_balance = quote_token.balanceOf(contract_address);

            // receive funds from caller and approve spending on Carmine Options AMM.
            base_token.transferFrom(caller, get_contract_address(), cost_base.into());
            base_token.approve(AMM_ADDR.try_into().unwrap(), cost_base.into() * 105 / 100 );
            quote_token.transferFrom(caller, get_contract_address(), cost_quote.into());
            quote_token.approve(AMM_ADDR.try_into().unwrap(), cost_quote.into() * 105 / 100);

            // Use hedge_at_price if provided, otherwise get the price from Pragma
            let curr_price = match hedge_at_price {
                Option::Some(price) => price,
                Option::None => get_pragma_median_price(quote_token_addr, base_token_addr)
            };

            let mut option_tokens: Array<OptionToken> = ArrayTrait::new();

            // get call options
            let mut strikes_calls = iterate_strike_prices(
                curr_price, quote_token_addr, base_token_addr, expiry, true
            );
            let mut already_hedged_calls: Fixed = FixedTrait::ZERO();
            loop {
                match strikes_calls.pop_front() {
                    Option::Some(strike_pair) => {
                        let (tobuy, tohedge) = *strike_pair;
                        // compute how much portf value would be at each hedged strike
                        // converts the excess to the hedge result asset (calls -> convert to eth)
                        // for each strike
                        // calculate portfolio value
                        let portf_val_calls = compute_portfolio_value(
                            curr_price, notional, true, tohedge
                        );
                        assert(portf_val_calls > FixedTrait::ZERO(), 'portf val calls < 0?');
                        assert(portf_val_calls.sign == false, 'portf val neg??');
                        // using portfolio value calculate amount to hedge,
                        // excluding loss covered by options bought in prev. iterrations.
                        let notional_fixed = convert_from_int_to_Fixed(notional, 18);
                        let amount_to_hedge = (notional_fixed - portf_val_calls) - already_hedged_calls;
                        already_hedged_calls += amount_to_hedge;
                        let amount_to_hedge_quote = amount_to_hedge * curr_price;
                        
                        // get option token balance
                        let lpt_addr: ContractAddress = amm.get_lptoken_address_for_given_option(quote_token_addr, base_token_addr, 0);
                        let option_token = amm.get_option_token_address(lpt_addr, 0, expiry, tobuy);
                        let option_token_dispatcher = IERC20Dispatcher { contract_address: option_token };
                        let initial_option_balance = option_token_dispatcher.balanceOf(contract_address);
                        // buy call option
                        buy_options_at_strike_to_hedge_at(
                            tobuy,
                            tohedge,
                            amount_to_hedge_quote,
                            expiry,
                            quote_token_addr,
                            base_token_addr,
                            true
                        );
                        let new_option_balance = option_token_dispatcher.balanceOf(contract_address);

                        // Transfer options to the user
                        // option_token_dispatcher.transfer(caller, new_option_balance - initial_option_balance);
                        let amount = new_option_balance - initial_option_balance;
                        option_tokens.append(OptionToken { address: option_token, amount: amount.into() });
                    },
                    Option::None(()) => {
                        break;
                    }
                };
            };

            // get put options
            let mut already_hedged_puts: Fixed = FixedTrait::ZERO();

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
                        // calculate portfolio value
                        let portf_val_puts = compute_portfolio_value(
                            curr_price, notional, false, tohedge
                        );
                        assert(portf_val_puts > FixedTrait::ZERO(), 'portf val puts < 0?');
                        assert(
                            portf_val_puts < (convert_from_int_to_Fixed(notional, 18) * curr_price),
                            'some loss expected'
                        ); // portf_val_puts is in quote token
                        assert(portf_val_puts.sign == false, 'portf val neg??');
                        // using portfolio value calculate amount to hedge,
                        // excluding loss covered by options bought in prev. iterrations.
                        let notional_fixed = convert_from_int_to_Fixed(notional, 18);
                        let notional_in_quote = notional_fixed * curr_price;
                        let amount_to_hedge = notional_in_quote - portf_val_puts - already_hedged_puts; // in quote token, with decimals
                        already_hedged_puts += amount_to_hedge;

                        // get option token balance
                        let lpt_addr: ContractAddress = amm.get_lptoken_address_for_given_option(quote_token_addr, base_token_addr, 1);
                        let option_token = amm.get_option_token_address(lpt_addr, 0, expiry, tobuy);
                        let option_token_dispatcher = IERC20Dispatcher { contract_address: option_token };
                        let initial_option_balance = option_token_dispatcher.balanceOf(contract_address);

                        // buy put option
                        buy_options_at_strike_to_hedge_at(
                            tobuy,
                            tohedge,
                            amount_to_hedge,
                            expiry,
                            quote_token_addr,
                            base_token_addr,
                            false
                        );

                        let new_option_balance = option_token_dispatcher.balanceOf(contract_address);

                        // Transfer options to the user
                        // option_token_dispatcher.transfer(caller, new_option_balance - initial_option_balance);
                        let amount = new_option_balance - initial_option_balance;
                        option_tokens.append(OptionToken { address: option_token, amount: amount.into() });
                    },
                    Option::None(()) => {
                        break;
                    }
                };
            };
            
            // return change 
            let new_base_token_balance = base_token.balanceOf(contract_address);
            let new_quote_token_balance = quote_token.balanceOf(contract_address); 
            
            let base_token_leftovers = new_base_token_balance - initial_base_token_balance;
            assert(base_token_leftovers >= 0, 'base token overspent');
            base_token.transfer(caller, base_token_leftovers);

            let quote_token_leftovers = new_quote_token_balance - initial_quote_token_balance;
            assert(quote_token_leftovers >= 0, 'quote token overspent');
            quote_token.transfer(caller, quote_token_leftovers);

            let hedge_token_dispatcher = IHedgeTokenDispatcher { contract_address: HEDGE_TOKEN_ADDRESS.try_into().unwrap()};
            let hedge_token_id = hedge_token_dispatcher.mint_hedge_token(caller, option_tokens, '');

            // Emit the HedgeOpened event
            self.emit(Event::HedgeOpened(HedgeOpenedEvent {
                user: caller,
                hedge_token_id: hedge_token_id,
                amount: notional.into(),
                quote_token: quote_token_addr,
                base_token: base_token_addr,
                maturity: expiry
            }));
        }

        fn hedge_close(
            ref self: ContractState,
            token_id: u256,
        ) {
            let caller: ContractAddress = hedge_finalize(token_id, true);

            // Emit the HedgeClosed event
            self.emit(Event::HedgeClosed(HedgeFinalizedEvent {
                user: caller,
                hedge_token_id: token_id,
            }));
        }

        fn hedge_settle(
            ref self: ContractState,
            token_id: u256,
        ) {
            let caller: ContractAddress = hedge_finalize(token_id, false);

             // Emit the HedgeSettled event
             self.emit(Event::HedgeSettled(HedgeFinalizedEvent {
                user: caller,
                hedge_token_id: token_id,
            }));
        }


        fn upgrade(ref self: ContractState, impl_hash: ClassHash) {
            let caller: ContractAddress = get_caller_address();
            let owner: ContractAddress = self.owner.read();
            assert(owner == caller, 'invalid caller');
            assert(!impl_hash.is_zero(), 'Class hash cannot be zero');
            replace_class_syscall(impl_hash).unwrap();
        }

        // return owner address
        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn price_hedge(
            self: @ContractState,
            notional: u128,
            quote_token_addr: ContractAddress,
            base_token_addr: ContractAddress,
            expiry: u64,
            hedge_at_price: Option<Fixed>
        ) -> (u128, u128) {
            assert(quote_token_addr != TOKEN_BTC_ADDRESS.try_into().unwrap(), 'NotImplementedYet');
            // Use hedge_at_price if provided, otherwise get the price from Pragma
            let curr_price = match hedge_at_price {
                Option::Some(price) => price,
                Option::None => get_pragma_median_price(quote_token_addr, base_token_addr)
            };
            assert(curr_price > FixedTrait::ZERO(), 'Cant hedge at price <= 0');

            // iterate available strike prices and get them into pairs of (bought strike, at which strike one should be hedged)
            let mut strikes_calls = iterate_strike_prices(
                curr_price, quote_token_addr, base_token_addr, expiry, true
            );
            let mut strikes_puts = iterate_strike_prices(
                curr_price, quote_token_addr, base_token_addr, expiry, false
            );

            let mut already_hedged_calls: Fixed = FixedTrait::ZERO();
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
                        let amount_to_hedge = (notional_fixed - portf_val_calls) - already_hedged_calls;
                        already_hedged_calls += amount_to_hedge;
                        let amount_to_hedge_quote = amount_to_hedge * curr_price;
                        cost_base +=
                            price_options_at_strike_to_hedge_at(
                                tobuy, tohedge, amount_to_hedge_quote, expiry, true, base_token_addr, quote_token_addr
                            );
                    },
                    Option::None(()) => {
                        break;
                    }
                };
            };

            let mut already_hedged_puts: Fixed = FixedTrait::ZERO();
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
                        assert(portf_val_puts.sign == false, 'portf val neg??');
                        let notional_fixed = convert_from_int_to_Fixed(notional, 18);
                        let notional_in_quote = notional_fixed * curr_price;
                        let amount_to_hedge = notional_in_quote - portf_val_puts - already_hedged_puts; // in quote token, with decimals
                        already_hedged_puts += amount_to_hedge;
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
