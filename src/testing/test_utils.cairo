use cubit::f128::types::fixed::{Fixed, FixedTrait};

use snforge_std::{
    declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget,
    start_mock_call
};
use starknet::{ContractAddress, contract_address_const};
use core::result::ResultTrait;

use hoil::constants::{
    TOKEN_ETH_ADDRESS, TOKEN_USDC_ADDRESS, TOKEN_STRK_ADDRESS, TOKEN_BTC_ADDRESS,
    TOKEN_EKUBO_ADDRESS
};
use hoil::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use hoil::interface::{IILHedge, IILHedgeDispatcher, IILHedgeDispatcherTrait};
use hoil::hedge_token::{IHedgeTokenDispatcher, IHedgeTokenDispatcherTrait};
use hoil::helpers::{toU256_balance, get_erc20_dispatcher};

use debug::PrintTrait;

const ONE_ETH: u256 = 1_000_000_000_000_000_000;
const ONE_STRK: u256 = 1_000_000_000_000_000_000;
const ONE_USDC: u256 = 1_000_000;


fn ETH() -> ContractAddress {
    TOKEN_ETH_ADDRESS.try_into().unwrap()
}

fn STRK() -> ContractAddress {
    TOKEN_STRK_ADDRESS.try_into().unwrap()
}

fn USDC() -> ContractAddress {
    TOKEN_USDC_ADDRESS.try_into().unwrap()
}

fn OWNER() -> ContractAddress {
    contract_address_const::<'OWNER'>()
}

fn USER() -> ContractAddress {
    // contract_address_const::<'USER'>()
    0x06c59d2244250f2540a2694472e3c31262e887ff02582ef864bf0e76c34e1298.try_into().unwrap()
}

fn ANOTHER_USER() -> ContractAddress {
    contract_address_const::<'ANOTHER_USER'>()
}

fn ETH_WHALE() -> ContractAddress {
    0x0213c67ed78bc280887234fe5ed5e77272465317978ae86c25a71531d9332a2d.try_into().unwrap()
}

fn USDC_WHALE() -> ContractAddress {
    0x0782897323eb2eeea09bd4c9dd0c6cc559b9452cdddde4dd26b9bbe564411703.try_into().unwrap()
}

fn STRK_WHALE() -> ContractAddress {
    0x00ca1702e64c81d9a07b86bd2c540188d92a2c73cf5cc0e508d949015e7e84a7.try_into().unwrap()
}

fn HEDGE_TOKEN_TEST_FACTORY() -> ContractAddress {
    0x055344336af7d3d881567528a4485fb45b3eda199c3b90ef163e6b96e6551f0f.try_into().unwrap()
}

fn deploy() -> (ContractAddress, ContractAddress) {
    'a'.print();
    let pail_token = declare("HedgeToken");
    let mut token_depl_args = ArrayTrait::<felt252>::new();
    token_depl_args.append(OWNER().into());
    'b'.print();
    let token_factory_addr = pail_token.deploy(@token_depl_args).unwrap();
    'c'.print();
    let pail = declare("ILHedge");
    let mut pail_depl_args = ArrayTrait::<felt252>::new();
    pail_depl_args.append(OWNER().into());
    pail_depl_args.append(token_factory_addr.into());
    'd'.print();

    let pail_addr = pail.deploy(@pail_depl_args).unwrap();
    'E'.print();
    // set pail address
    let token_factory = pail_token_factory_disp(token_factory_addr);
    start_prank(CheatTarget::One(token_factory_addr), OWNER());
    token_factory.set_pail_contract_address(pail_addr);
    stop_prank(CheatTarget::One(token_factory_addr));

    let pail_contract_address_in_token_contract = token_factory.get_pail_contract_address();
    assert(pail_addr == pail_contract_address_in_token_contract, 'wrong PaIL address');
    let pail_contract = pail_disp(pail_addr);
    let token_factory_address_in_pail = pail_contract.get_pail_token_address();
    assert(token_factory_addr == token_factory_address_in_pail, 'wrong token addr in pail');
    token_factory_addr.print();
    pail_addr.print();
    (token_factory_addr, pail_addr)
}

fn pail_disp(addr: ContractAddress) -> IILHedgeDispatcher {
    IILHedgeDispatcher { contract_address: addr }
}

fn pail_token_factory_disp(addr: ContractAddress) -> IHedgeTokenDispatcher {
    IHedgeTokenDispatcher { contract_address: addr }
}

fn fund_eth(addr: ContractAddress, amount: u256) {
    start_prank(CheatTarget::One(ETH()), ETH_WHALE());
    let eth = get_erc20_dispatcher(ETH());
    eth.transfer(addr, amount);
    stop_prank(CheatTarget::One(ETH()));
}

fn fund_usdc(addr: ContractAddress, amount: u256) {
    start_prank(CheatTarget::One(USDC()), USDC_WHALE());
    let usdc = get_erc20_dispatcher(USDC());
    usdc.transfer(addr, amount);
    stop_prank(CheatTarget::One(USDC()));
}

fn fund_strk(addr: ContractAddress, amount: u256) {
    start_prank(CheatTarget::One(STRK()), STRK_WHALE());
    let strk = get_erc20_dispatcher(STRK());
    strk.transfer(addr, amount);

    stop_prank(CheatTarget::One(STRK()));
}

fn approve(token: ContractAddress, user: ContractAddress, spender: ContractAddress, amount: u256) {
    start_prank(CheatTarget::One(token), user);
    let dsp = get_erc20_dispatcher(token);
    dsp.approve(spender, amount);

    stop_prank(CheatTarget::One(token));
}

fn approve_fixed(
    token: ContractAddress, user: ContractAddress, spender: ContractAddress, amount: Fixed
) {
    let dsp = get_erc20_dispatcher(token);
    let amount_u256 = toU256_balance(amount, dsp.decimals().into());

    start_prank(CheatTarget::One(token), user);
    dsp.approve(spender, amount_u256);

    stop_prank(CheatTarget::One(token));
}
