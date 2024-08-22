// Only fetches median price
// Taken from protocol-cairo1
use starknet::get_block_timestamp;
use starknet::ContractAddress;
use traits::{TryInto, Into};
use option::OptionTrait;

use cubit::f128::types::fixed::{Fixed, FixedTrait};

use hoil::helpers::convert_from_int_to_Fixed;
use hoil::constants::{TOKEN_ETH_ADDRESS, TOKEN_USDC_ADDRESS, TOKEN_STRK_ADDRESS};

const PRAGMA_ORACLE_ADDRESS: felt252 =
   0x0346c57f094d641ad94e43468628d8e9c574dcb2803ec372576ccc60a40be2c4; // mainnet

const PRAGMA_ETH_USD_KEY: felt252 = 19514442401534788;

const PRAGMA_USDC_USD_KEY: felt252 = 6148332971638477636;

const PRAGMA_STRK_USD_KEY: felt252 = 6004514686061859652;



#[derive(Copy, Drop, Serde)]
struct PragmaCheckpoint {
    timestamp: felt252,
    value: felt252,
    aggregation_mode: felt252,
    num_sources_aggregated: felt252,
}

#[starknet::interface]
trait IPragmaOracle<TContractState> {
    fn get_spot_median(
        self: @TContractState, pair_id: felt252
    ) -> (felt252, felt252, felt252, felt252);
    fn get_last_spot_checkpoint_before(
        self: @TContractState, key: felt252, timestamp: felt252
    ) -> (PragmaCheckpoint, felt252);
}


fn _get_pragma_median_price(key: felt252) -> Fixed {
    let (value, decimals, last_updated_timestamp, _) =
        IPragmaOracleDispatcher {
        contract_address: PRAGMA_ORACLE_ADDRESS.try_into().expect('Pragma/_GPMP - Cant convert')
    }
        .get_spot_median(key);

    let curr_time = get_block_timestamp();
    let time_diff = if curr_time < last_updated_timestamp
        .try_into()
        .expect('Pragma/_GPMP - LUT too large') {
        0
    } else {
        curr_time - last_updated_timestamp.try_into().expect('Pragma/_GPMP - LUT too large')
    };

    assert(time_diff < 3600, 'Pragma/_GPMP - Price too old');
    assert(
        value.try_into().expect('Pragma/GPMP - Price too high') > 0_u128,
        'Pragma/-GPMP - Price <= 0'
    );

    convert_from_int_to_Fixed(value.try_into().unwrap(), decimals.try_into().unwrap())
}

// @notice Returns Pragma key identifier for spot pairs
// @param quote_token_addr: Address of quote token in given ticker
// @param base_token_addr: Address of base token in given ticker
// @return stablecoin_key: Spot pair key identifier
fn _get_ticker_key(
    quote_token_addr: ContractAddress, base_token_addr: ContractAddress
) -> felt252 {
    if base_token_addr.into() == TOKEN_ETH_ADDRESS {
        if quote_token_addr.into() == TOKEN_USDC_ADDRESS {
            PRAGMA_ETH_USD_KEY
        } else {
            0
        }
    } else if base_token_addr.into() == TOKEN_STRK_ADDRESS {
        if quote_token_addr.into() == TOKEN_USDC_ADDRESS {
            PRAGMA_STRK_USD_KEY
        } else {
            0
        }
    } else {
        0
    }
}


// @notice Returns Pragma key identifier for stablecoins
// @param quote_token_addr: Address of given stablecoin 
// @return stablecoin_key: Stablecoin key identifier
fn _get_stablecoin_key(quote_token_addr: ContractAddress) -> Option<felt252> {
    if quote_token_addr == TOKEN_USDC_ADDRESS.try_into().expect('Pragma/GSK - Failed to convert') {
        Option::Some(PRAGMA_USDC_USD_KEY)
    } else {
        Option::None(())
    }
}

// @notice Returns current Pragma median price for given key
// @dev This function accounts for stablecoin divergence
// @param quote_token_addr: Address of quote token in given ticker
// @param base_token_addr: Address of base token in given ticker
// @return median_price: Pragma current median price in Fixed
fn get_pragma_median_price(
    quote_token_addr: ContractAddress, base_token_addr: ContractAddress,
) -> Fixed {
    // STRK/ETH gets special treatment
    if base_token_addr.into() == TOKEN_ETH_ADDRESS
        && quote_token_addr.into() == TOKEN_STRK_ADDRESS {
        let eth_in_usd = _get_pragma_median_price(PRAGMA_ETH_USD_KEY);
        let strk_in_usd = _get_pragma_median_price(PRAGMA_STRK_USD_KEY);

        let eth_in_strk = eth_in_usd / strk_in_usd;

        return eth_in_strk;
    } else {
        let key = _get_ticker_key(quote_token_addr, base_token_addr);

        let res = _get_pragma_median_price(key);
        account_for_stablecoin_divergence(res, quote_token_addr)
    }
}


fn account_for_stablecoin_divergence(price: Fixed, quote_token_addr: ContractAddress) -> Fixed {
    let key = _get_stablecoin_key(quote_token_addr);

    match key {
        Option::Some(key) => {
            let stable_coin_price = _get_pragma_median_price(key);
            return price / stable_coin_price;
        },
        // If key is zero, it means that quote_token isn't stablecoin(or at least one we use)
        Option::None(_) => {
            return price;
        }
    }
}
