use starknet::ContractAddress;
use cubit::f128::types::fixed::{Fixed, FixedTrait};

#[starknet::interface]
trait IERC20<TContractState> {
    fn name(self: @TContractState) -> felt252;
    fn symbol(self: @TContractState) -> felt252;
    fn decimals(self: @TContractState) -> u8;
    fn totalSupply(self: @TContractState) -> u256;
    fn mint(ref self: TContractState, to: ContractAddress, amount: u256);
    fn burn(ref self: TContractState, account: ContractAddress, amount: u256);
    fn balanceOf(self: @TContractState, account: ContractAddress) -> u256;
    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transferFrom(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;

    // option token specific functions
    fn quote_token_address(self: @TContractState) -> ContractAddress;
    fn base_token_address(self: @TContractState) -> ContractAddress;
    fn option_type(self: @TContractState) -> u8;
    fn strike_price(self: @TContractState) -> Fixed;
    fn maturity(self: @TContractState) -> u64;
    fn side(self: @TContractState) -> u8;
}
