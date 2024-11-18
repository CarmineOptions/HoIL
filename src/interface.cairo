use core::array::SpanTrait;
use starknet::ContractAddress;
use starknet::ClassHash;
use cubit::f128::types::fixed::Fixed;


#[starknet::interface]
trait IILHedge<TContractState> {
    fn name(self: @TContractState) -> felt252;
    fn hedge_open(
        ref self: TContractState,
        notional: u128,
        quote_token_addr: ContractAddress,
        base_token_addr: ContractAddress,
        expiry: u64,
        limit_price: (Fixed, Fixed),
        hedge_at_price: Fixed
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
        hedge_at_price: Fixed
    ) -> (Fixed, Fixed, Fixed);
    fn upgrade(ref self: TContractState, impl_hash: ClassHash);
    fn get_owner(self: @TContractState) -> ContractAddress;
    // fn supports_interface(self: @TContractState, interface_id: felt252) -> bool;
}

#[starknet::contract]
mod ILHedge {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use traits::{Into, TryInto};

    use starknet::{get_caller_address, get_contract_address, ClassHash, ContractAddress};
    use starknet::syscalls::{replace_class_syscall};

    use cubit::f128::types::fixed::{Fixed, FixedTrait};
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::introspection::src5::SRC5Component::InternalTrait;
    use openzeppelin::introspection::interface::{ISRC5, ISRC5_ID};
    use openzeppelin::account::interface::ISRC6_ID;

    use hoil::amm_curve::compute_portfolio_value;
    use hoil::constants::{
        AMM_ADDR, TOKEN_ETH_ADDRESS, TOKEN_USDC_ADDRESS, TOKEN_STRK_ADDRESS, TOKEN_BTC_ADDRESS, TOKEN_EKUBO_ADDRESS, HEDGE_TOKEN_ADDRESS,
        PROTOCOL_NAME
    };
    use hoil::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use hoil::carmine::{IAMMDispatcher, IAMMDispatcherTrait};
    use hoil::hedging::hedge_finalize;
    use hoil::pragma::get_pragma_median_price;
    use hoil::helpers::{convert_from_int_to_Fixed, toU256_balance, get_decimal};
    use hoil::hedge_token::{OptionAmount, IHedgeTokenDispatcher, IHedgeTokenDispatcherTrait};
    use hoil::errors::Errors;
    use hoil::utils::{build_hedge, buy_and_approve};
    
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[storage]
    struct Storage {
        owner: ContractAddress,
        name: felt252,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        HedgeOpened: HedgeOpenedEvent,
        HedgeClosed: HedgeFinalizedEvent,
        HedgeSettled: HedgeFinalizedEvent,
        #[flat]
        SRC5Event: SRC5Component::Event
    }

    #[derive(Drop, starknet::Event)]
    struct HedgeOpenedEvent {
        #[key]
        user: ContractAddress,
        hedge_token_id: u256,
        amount: u256,
        quote_token: ContractAddress,
        base_token: ContractAddress,
        maturity: u64,
        at_price: Fixed
    }

    #[derive(Drop, starknet::Event)]
    struct HedgeFinalizedEvent {
        #[key]
        user: ContractAddress,
        hedge_token_id: u256,
    }

    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.owner.write(owner);
        self.name.write(PROTOCOL_NAME);
        SRC5Component::InternalImpl::register_interface(ref self.src5, ISRC5_ID);
        SRC5Component::InternalImpl::register_interface(ref self.src5, ISRC6_ID);
    }

    #[abi(embed_v0)]
    impl ILHedge of super::IILHedge<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            self.name.read()
        }

        fn hedge_open(
            ref self: ContractState,
            notional: u128,
            quote_token_addr: ContractAddress,
            base_token_addr: ContractAddress,
            expiry: u64,
            limit_price: (Fixed, Fixed),
            hedge_at_price: Fixed
        ) {
            assert(quote_token_addr != TOKEN_BTC_ADDRESS.try_into().unwrap(), Errors::NOT_IMPLEMETED);
            let (cost_quote, cost_base, curr_price, options_to_buy) = build_hedge(
                notional, quote_token_addr, base_token_addr, expiry, hedge_at_price
            );

            // check is price does not violate slippage limit
            let (limit_quote, limit_base) = limit_price;
            assert(cost_quote <= limit_quote, Errors::QUOTE_COST_OUT_OF_LIMITS);
            assert(cost_base <= limit_base, Errors::BASE_COST_OUT_OF_LIMITS);

            let caller = get_caller_address();
            let contract_address = starknet::get_contract_address();

            let amm = IAMMDispatcher { contract_address: AMM_ADDR.try_into().unwrap() };
            
            // getting initial token balances
            let base_token = IERC20Dispatcher { contract_address: base_token_addr };
            let initial_base_token_balance = base_token.balanceOf(contract_address);
            let quote_token = IERC20Dispatcher { contract_address: quote_token_addr };
            let initial_quote_token_balance = quote_token.balanceOf(contract_address);

            let limit_base_u256: u256 = toU256_balance(limit_base, get_decimal(base_token_addr).into());
            let limit_quote_u256: u256 = toU256_balance(limit_quote, get_decimal(quote_token_addr).into());

            // receive funds from caller and approve spending on Carmine Options AMM.
            base_token.transferFrom(caller, get_contract_address(), limit_base_u256.into());
            base_token.approve(AMM_ADDR.try_into().unwrap(), limit_base_u256.into());
            quote_token.transferFrom(caller, get_contract_address(), limit_quote_u256.into());
            quote_token.approve(AMM_ADDR.try_into().unwrap(), limit_quote_u256.into());

            // // Use hedge_at_price if provided, otherwise get the price from Pragma
            // let curr_price = if (hedge_at_price <= FixedTrait::ZERO()) {
            //     get_pragma_median_price(quote_token_addr, base_token_addr)
            // } else {
            //     hedge_at_price
            // };
            // assert(curr_price > FixedTrait::ZERO(), Errors::NEGATIVE_PRICE);

            let mut purchased_tokens: Array<OptionAmount> = ArrayTrait::new();

            let mut options_to_buy_span = options_to_buy.span();
            loop {
                match options_to_buy_span.pop_front() {
                    Option::Some(option_to_buy) => {
                        let purchased_token = buy_and_approve(*option_to_buy, amm);
                        purchased_tokens.append(purchased_token)
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
            assert(base_token_leftovers >= 0, Errors::COST_EXCEEDS_LIMITS);
            base_token.transfer(caller, base_token_leftovers);

            let quote_token_leftovers = new_quote_token_balance - initial_quote_token_balance;
            assert(quote_token_leftovers >= 0, Errors::COST_EXCEEDS_LIMITS);
            quote_token.transfer(caller, quote_token_leftovers);

            let hedge_token_dispatcher = IHedgeTokenDispatcher { contract_address: HEDGE_TOKEN_ADDRESS.try_into().unwrap()};
            let hedge_token_id = hedge_token_dispatcher.mint_hedge_token(caller, purchased_tokens);

            // Emit the HedgeOpened event
            self.emit(Event::HedgeOpened(HedgeOpenedEvent {
                user: caller,
                hedge_token_id: hedge_token_id,
                amount: notional.into(),
                quote_token: quote_token_addr,
                base_token: base_token_addr,
                maturity: expiry,
                at_price: curr_price
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
            self.name.write('Protection against IL');
            SRC5Component::InternalImpl::register_interface(ref self.src5, ISRC5_ID);
            SRC5Component::InternalImpl::register_interface(ref self.src5, ISRC6_ID);

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
            hedge_at_price: Fixed
        ) -> (Fixed, Fixed, Fixed) {
            assert(quote_token_addr != TOKEN_BTC_ADDRESS.try_into().unwrap(), Errors::NOT_IMPLEMETED);
            assert(quote_token_addr != TOKEN_EKUBO_ADDRESS.try_into().unwrap(), Errors::NOT_IMPLEMETED);
            let (cost_quote, cost_base, price, _) = build_hedge(notional, quote_token_addr, base_token_addr, expiry, hedge_at_price);
            (cost_quote, cost_base, price)
        }
    }
}
