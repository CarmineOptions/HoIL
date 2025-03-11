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
    0x2a85bd616f912537c50a49a4076db02c00b29b2cdc8a197ce92ed1837fa875b; // mainnet

const PRAGMA_ETH_USD_KEY: felt252 = 19514442401534788;

const PRAGMA_USDC_USD_KEY: felt252 = 6148332971638477636;

const PRAGMA_STRK_USD_KEY: felt252 = 6004514686061859652;


#[derive(Serde, Drop, Copy)]
struct PragmaPricesResponse {
    price: u128,
    decimals: u32,
    last_updated_timestamp: u64,
    num_sources_aggregated: u32,
    expiration_timestamp: Option<u64>,
}


#[derive(Copy, Drop, Serde)]
struct PragmaCheckpoint {
    timestamp: felt252,
    value: felt252,
    aggregation_mode: felt252,
    num_sources_aggregated: felt252,
}


#[derive(Drop, Copy, Serde)]
enum DataType {
    SpotEntry: felt252,
    FutureEntry: (felt252, u64),
    GenericEntry: felt252,
}


#[derive(Serde, Drop, Copy)]
enum AggregationMode {
    Median: (),
    Mean: (),
    Error: (),
}


#[starknet::interface]
trait IPragmaOracle<TContractState> {
    fn get_data(
        self: @TContractState, data_type: DataType, aggregation_mode: AggregationMode
    ) -> PragmaPricesResponse;
}

// @notice Returns current Pragma median price for given key
// @dev This function does not account for stablecoin divergence
// @param key: Pragma key identifier
// @return median_price: Pragma current median price in Fixed
fn _get_pragma_median_price(key: felt252) -> Fixed {
    let res: PragmaPricesResponse = IPragmaOracleDispatcher {
        contract_address: PRAGMA_ORACLE_ADDRESS.try_into().expect('Pragma/_GPMP - Cant convert')
    }
        .get_data(DataType::SpotEntry(key), AggregationMode::Median(()));

    let curr_time = get_block_timestamp();
    let time_diff = if curr_time < res.last_updated_timestamp {
        0
    } else {
        curr_time - res.last_updated_timestamp
    };

    // assert(time_diff < 3600, 'Pragma/_GPMP - Price too old');

    convert_from_int_to_Fixed(
        res.price, res.decimals.try_into().expect('Pragma/_GPMP - decimals err')
    )
}

// @notice Returns Pragma key identifier for spot pairs
// @param quote_token_addr: Address of quote token in given ticker
// @param base_token_addr: Address of base token in given ticker
// @return stablecoin_key: Spot pair key identifier
fn _get_ticker_key(quote_token_addr: ContractAddress, base_token_addr: ContractAddress) -> felt252 {
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
        Option::None(_) => { return price; }
    }
}
