use starknet::{ContractAddress, ClassHash};
use array::ArrayTrait;

#[derive(Drop, Serde, Copy)]
struct OptionToken {
    address: ContractAddress,
    amount: u256
}

#[starknet::interface]
trait IHedgeToken<TContractState> {
    fn name(self: @TContractState) -> felt252;
    fn safe_transfer_single_token(
        ref self: TContractState,
        from: ContractAddress,
        to: ContractAddress,
        token_id: u256
    );
    fn mint_hedge_token(
        ref self: TContractState,
        to: ContractAddress,
        assigned_tokens: Array<OptionToken>
    ) -> u256;

    fn burn_hedge_token(ref self: TContractState, token_id: u256) -> Array<OptionToken>;

    fn get_assigned_tokens(self: @TContractState, token_id: u256) -> Array<OptionToken>;
    fn quote_token_address(self: @TContractState, token_id: u256) -> ContractAddress;
    fn base_token_address(self: @TContractState, token_id: u256) -> ContractAddress;
    fn maturity(self: @TContractState, token_id: u256) -> u64;
    fn upgrade(ref self: TContractState, impl_hash: ClassHash);
}

#[starknet::contract]
mod HedgeToken {
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::token::erc1155::ERC1155Component;
    use openzeppelin::token::erc1155::ERC1155HooksEmptyImpl;
    use openzeppelin::token::erc20::interface::IERC20;
    use openzeppelin::token::erc1155::interface::ERC1155ABI;
    use openzeppelin::introspection::src5::SRC5Component::SRC5Impl;

    use starknet::storage::Map;
    use starknet::{ContractAddress, ClassHash, get_caller_address};
    use starknet::syscalls::{replace_class_syscall};
    use option::OptionTrait;
    use array::ArrayTrait;
    use traits::Into;

    use hoil::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use hoil::constants::HOIL;
    use super::OptionToken;

    component!(path: ERC1155Component, storage: erc1155, event: ERC1155Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    // #[abi(embed_v0)]
    // impl ERC1155MixinImpl = ERC1155Component::ERC1155MixinImpl<ContractState>;

    impl ERC1155InternalImpl = ERC1155Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc1155: ERC1155Component::Storage,
        option_tokens: Map::<(u256, ContractAddress), u256>,
        token_option_addresses_length: Map::<u256, u32>,
        token_option_addresses: Map::<(u256, u32), ContractAddress>,
        next_token_id: u256,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        name: felt252,
        owner: ContractAddress
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC1155Event: ERC1155Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event
    }

    #[abi(embed_v0)]
    impl ERC1155MixinImpl of ERC1155ABI<ContractState> {
        fn safe_transfer_from(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256,
            data: Span<felt252>
        ) {
            self.erc1155.safe_transfer_from(from, to, token_id, 1_u256, data)
        }

        // Rest of ERC1155Mixin functions - delegate to erc1155 component
        fn balance_of(self: @ContractState, account: ContractAddress, token_id: u256) -> u256 {
            self.erc1155.balance_of(account, token_id)
        }

        fn balance_of_batch(
            self: @ContractState,
            accounts: Span<ContractAddress>,
            token_ids: Span<u256>
        ) -> Span<u256> {
            self.erc1155.balance_of_batch(accounts, token_ids)
        }

        fn is_approved_for_all(
            self: @ContractState, 
            owner: ContractAddress, 
            operator: ContractAddress
        ) -> bool {
            self.erc1155.is_approved_for_all(owner, operator)
        }

        fn set_approval_for_all(
            ref self: ContractState, 
            operator: ContractAddress, 
            approved: bool
        ) {
            self.erc1155.set_approval_for_all(operator, approved)
        }

        fn safe_batch_transfer_from(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_ids: Span<u256>,
            values: Span<u256>,
            data: Span<felt252>
        ) {
            self.erc1155.safe_batch_transfer_from(from, to, token_ids, values, data)
        }

        // ISRC5 functions
        fn supports_interface(self: @ContractState, interface_id: felt252) -> bool {
            self.src5.supports_interface(interface_id)
        }

        // URI function
        fn uri(self: @ContractState, token_id: u256) -> ByteArray {
            self.erc1155.uri(token_id)
        }

        // Camel case versions
        fn balanceOf(self: @ContractState, account: ContractAddress, tokenId: u256) -> u256 {
            self.balance_of(account, tokenId)
        }

        fn balanceOfBatch(
            self: @ContractState,
            accounts: Span<ContractAddress>,
            tokenIds: Span<u256>
        ) -> Span<u256> {
            self.balance_of_batch(accounts, tokenIds)
        }

        fn setApprovalForAll(ref self: ContractState, operator: ContractAddress, approved: bool) {
            self.set_approval_for_all(operator, approved)
        }

        fn isApprovedForAll(
            self: @ContractState,
            owner: ContractAddress,
            operator: ContractAddress
        ) -> bool {
            self.is_approved_for_all(owner, operator)
        }

        fn safeTransferFrom(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            tokenId: u256,
            value: u256,
            data: Span<felt252>
        ) {
            self.safe_transfer_from(from, to, tokenId, value, data)
        }

        fn safeBatchTransferFrom(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            tokenIds: Span<u256>,
            values: Span<u256>,
            data: Span<felt252>
        ) {
            self.safe_batch_transfer_from(from, to, tokenIds, values, data)
        }
    }

    #[abi(embed_v0)]
    impl HedgeTokenImpl of super::IHedgeToken<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            self.name.read()
        }

        fn upgrade(ref self: ContractState, impl_hash: ClassHash) {
            let caller: ContractAddress = get_caller_address();
            let owner: ContractAddress = self.owner.read();
            // self.erc1155.initializer("www.mock.url/{id}");
            assert(owner == caller, 'invalid caller');
            assert(!impl_hash.is_zero(), 'Class hash cannot be zero');
            replace_class_syscall(impl_hash).unwrap();
        }


        fn safe_transfer_single_token(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256
        ) {
            self.erc1155.safe_transfer_from(from, to, token_id, 1, ArrayTrait::new().span())
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

        fn maturity(self: @ContractState, token_id: u256) -> u64 {
            let option_tokens: Array<OptionToken> = self.get_assigned_tokens(token_id);
            let option_token: OptionToken = *option_tokens.at(0);
            IERC20Dispatcher { contract_address: option_token.address}.maturity()
        }

        fn base_token_address(self: @ContractState, token_id: u256) -> ContractAddress {
            let option_tokens: Array<OptionToken> = self.get_assigned_tokens(token_id);
            let option_token: OptionToken = *option_tokens.at(0);
            IERC20Dispatcher { contract_address: option_token.address}.base_token_address()
        }

        fn quote_token_address(self: @ContractState, token_id: u256) -> ContractAddress {
            let option_tokens: Array<OptionToken> = self.get_assigned_tokens(token_id);
            let option_token: OptionToken = *option_tokens.at(0);
            IERC20Dispatcher { contract_address: option_token.address}.quote_token_address()
        }

        fn mint_hedge_token(
            ref self: ContractState,
            to: ContractAddress,
            assigned_tokens: Array<OptionToken>
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
                    Option::Some(option_token) => {
                        let token = IERC20Dispatcher { contract_address: *option_token.address };
                        assert(*option_token.amount > 0, 'MHT: neg.amount provided');
                        // Transfer the fungible tokens from the caller to this contract
                        token.transferFrom( caller, starknet::get_contract_address(), *option_token.amount);
                        // Record the assignment
                        self.option_tokens.write((token_id, *option_token.address), *option_token.amount);
                        self.token_option_addresses.write((token_id, index), *option_token.address);
                        index += 1;
                    },
                    Option::None => { break; },
                };
            };
            self.token_option_addresses_length.write(token_id, index);
            // self.uris.write(token_id, uri);

            token_id
        }

        fn burn_hedge_token(ref self: ContractState, token_id: u256) -> Array<OptionToken> {
            let caller = get_caller_address();
            // assert(caller == HOIL.try_into().unwrap(), 'Unautorized to burn');
            let mut returned_tokens: Array<OptionToken> = ArrayTrait::new();
        
            // Check if the caller has enough tokens to burn
            let caller_balance = self.erc1155.balance_of(caller, token_id);
            assert(caller_balance >= 1, 'BHT: Not an owner');

            // Burn the hedge tokens
            self.erc1155.burn(caller, token_id, 1);
        
            // Return the proportional amount of option tokens
            let length = self.token_option_addresses_length.read(token_id);
            let mut i = 0_u32;
            while (i < length) {
                let option_address = self.token_option_addresses.read((token_id, i));
                let option_amount = self.option_tokens.read((token_id, option_address));
                let token = IERC20Dispatcher { contract_address: option_address };
                token.transfer(caller, option_amount);
                self.option_tokens.write((token_id, option_address), 0);
                self.token_option_addresses_length.write(token_id, 0);
                returned_tokens.append( OptionToken { address: option_address, amount: option_amount});
                i += 1;
            };
            returned_tokens
        }
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.name.write('PAIL Token');
        self.owner.write(owner);
        self.erc1155.initializer("api.carmine.finance/api/v1/mainnet/hedge?token_id={id}");
        // self.base_uri.write(ByteArray::from_string("www.mock.url/"));
        self.next_token_id.write(1); // Start token IDs from 1
    }
}
