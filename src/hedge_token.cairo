use starknet::ContractAddress;
use array::ArrayTrait;

#[derive(Drop, Serde)]
struct OptionToken {
    address: ContractAddress,
    amount: u256
}

#[starknet::interface]
trait IHedgeToken<TContractState> {
    fn name(self: @TContractState) -> felt252;
    fn mint_hedge_token(
        ref self: TContractState,
        to: ContractAddress,
        assigned_tokens: Array<(ContractAddress, u256)>,
        uri: felt252
    ) -> u256;

    fn burn_hedge_token(ref self: TContractState, token_id: u256);

    fn get_assigned_tokens(self: @TContractState, token_id: u256) -> Array<OptionToken>;
}

#[starknet::contract]
mod HedgeToken {
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::token::erc1155::ERC1155Component;
    use openzeppelin::token::erc1155::ERC1155HooksEmptyImpl;
    use openzeppelin::token::erc20::interface::IERC20;
    use starknet::storage::Map;
    use starknet::{ContractAddress, get_caller_address};
    use option::OptionTrait;
    use array::ArrayTrait;
    use traits::Into;
    use hoil::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use hoil::constants::HOIL;
    use super::OptionToken;

    component!(path: ERC1155Component, storage: erc1155, event: ERC1155Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl ERC1155MixinImpl = ERC1155Component::ERC1155MixinImpl<ContractState>;

    impl ERC1155InternalImpl = ERC1155Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc1155: ERC1155Component::Storage,
        option_tokens: Map::<(u256, ContractAddress), u256>,
        token_option_addresses_length: Map::<u256, u32>,
        token_option_addresses: Map::<(u256, u32), ContractAddress>,
        uris: Map::<u256, felt252>,
        next_token_id: u256,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        name: felt252
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC1155Event: ERC1155Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event
    }

    #[starknet::interface]
    trait IERC1155MetadataURI<TContractState> {
        fn uri(self: @TContractState, token_id: u256) -> felt252;
    }

    impl ERC1155MetadataURIImpl of IERC1155MetadataURI<ContractState> {
        fn uri(self: @ContractState, token_id: u256) -> felt252 {
            self.uris.read(token_id)
        }
    }


    #[abi(embed_v0)]
    impl HedgeTokenImpl of super::IHedgeToken<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            self.name.read()
        }

        fn get_assigned_tokens(self: @ContractState, token_id: u256) -> Array<OptionToken> {
            let mut result = ArrayTrait::new();
            let length = self.token_option_addresses_length.read(token_id);
            let mut i = 0_u32;
            while (i < length) {
                let address = self.token_option_addresses.read((token_id, i));
                let amount = self.option_tokens.read((token_id, address));
                if amount > 0 {
                    result.append(OptionToken { address, amount });
                }
                i += 1;
            };
            result
        }

        fn mint_hedge_token(
            ref self: ContractState,
            to: ContractAddress,
            assigned_tokens: Array<(ContractAddress, u256)>,
            uri: felt252
        ) -> u256 {
            let amount = 1;
            let caller = get_caller_address();
            // TODO assert caller is allowed to mint/burn
            // assert(caller == HOIL.try_into().unwrap(), 'Unautorized to mint');
            let token_id = self.next_token_id.read();
            self.next_token_id.write(token_id + 1);

            // Mint the new hedge token
            self.erc1155.mint_with_acceptance_check(to, token_id, amount, ArrayTrait::new().span());

            // Assign fungible tokens
            let mut assigned_tokens_span = assigned_tokens.span();
            let mut index = 0_u32;
            loop {
                match assigned_tokens_span.pop_front() {
                    Option::Some((token_address, token_amount)) => {
                        let token = IERC20Dispatcher { contract_address: *token_address };
                        assert(*token_amount > 0, 'MHT: neg.amount provided');
                        // Transfer the fungible tokens from the caller to this contract
                        token.transferFrom( caller, starknet::get_contract_address(), *token_amount);
                        // Record the assignment
                        self.option_tokens.write((token_id, *token_address), *token_amount);
                        self.token_option_addresses.write((token_id, index), *token_address);
                        index += 1;
                    },
                    Option::None => { break; },
                };
            };
            self.token_option_addresses_length.write(token_id, index);
            self.uris.write(token_id, uri);

            token_id
        }

        fn burn_hedge_token(ref self: ContractState, token_id: u256) {
            let amount = 1;
            let caller = get_caller_address();
        
            // Check if the caller has enough tokens to burn
            let caller_balance = self.erc1155.balance_of(caller, token_id);
            assert(caller_balance >= amount, 'BHT: Not an owner');

            // Get the total supply before burning
            // TODO replace with other constant
            let total_supply = 1;
            assert(total_supply >= amount, 'BHT: Amount exceeds supply');

            // Burn the hedge tokens
            self.erc1155.burn(caller, token_id, amount);

            let burn_ratio = amount / total_supply;
        
            // Return the proportional amount of option tokens
            let length = self.token_option_addresses_length.read(token_id);
            let mut i = 0_u32;
            while (i < length) {
                let option_address = self.token_option_addresses.read((token_id, i));
                let option_amount = self.option_tokens.read((token_id, option_address));
                
                if option_amount > 0 {
                    let burn_amount = (option_amount * burn_ratio);
                    let new_amount = option_amount - burn_amount;

                    if burn_amount > 0 {
                        // Transfer the tokens back to the caller
                        let token = IERC20Dispatcher { contract_address: option_address };
                        token.transfer(caller, burn_amount);
                    
                        if new_amount > 0 {
                            // Update amount
                            self.option_tokens.write((token_id, option_address), new_amount);
                        } else {
                            // Remove this token completely
                            self.option_tokens.write((token_id, option_address), 0);
                        }
                    }
                }
                i += 1;
            };
            if burn_ratio >= 1 {
                self.token_option_addresses_length.write(token_id, 0);
            }
        }
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.name.write('HoIL Token');
        self.erc1155.initializer("www.mock.url");
        self.next_token_id.write(1); // Start token IDs from 1
    }
}
