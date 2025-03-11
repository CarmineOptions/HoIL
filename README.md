# ILHedge - Protection against Impermanent Loss Smart Contract

## Overview

ILHedge is a smart contract built on StarkNet that provides protection against impermanent loss (IL) for liquidity providers. ILHedge utilizes Carmine Options to create hedge positions. The contract allows users to hedge their liquidity positions in Automated Market Makers (AMMs) by creating option-based hedging positions that offset potential losses due to price divergence.

For a detailed explanation of how ILHedge works, check out our [Medium article on Impermanent Loss Protection](https://medium.com/@carminefinanceinfo/hedging-impermanent-loss-part-1-52c51846f3da)

## Deployment Guide

ILHedge consists of two smart contracts that need to be deployed and properly linked:
1. **HedgeToken Contract**: Manages the NFT tokens that represent hedge positions
2. **ILHedge Contract**: Main contract that implements the impermanent loss protection logic

### Prerequisites

- [Starkli](https://book.starkli.rs/installation) installed and configured
- Starknet account setup (with sufficient ETH for deployment)

### Deployment Steps

1. **Set Environment Variables**

```bash
# Set your owner address
export OWNER_ADDRESS=0x...your_owner_address_here...
```

2. **Declare Contracts**

```bash
# Declare HedgeToken contract
starkli declare  ./target/dev/hoil_HedgeToken.contract_class.json --compiler-version=2.7.1

# Declare ILHedge contract
starkli declare  ./target/dev/hoil_ILHedge.contract_class.json --compiler-version=2.7.1
```

3. **Deploy HedgeToken Contract**

```bash
# Deploy HedgeToken passing owner address as constructor argument
starkli deploy $HEDGE_TOKEN_HASH $OWNER_ADDRESS
```

4. **Deploy ILHedge Contract**

```bash
# Deploy ILHedge passing owner address and HedgeToken address as constructor arguments
starkli deploy $IL_HEDGE_HASH $OWNER_ADDRESS $HEDGE_TOKEN_ADDRESS
```

5. **Link Contracts Together**

The HedgeToken contract needs to know the address of the ILHedge contract:

```bash
# Call set_pail_contract_address on the HedgeToken contract
starkli invoke $HEDGE_TOKEN_ADDRESS set_pail_contract_address $IL_HEDGE_ADDRESS
```

6. **Verify Configuration**

```bash
# Verify HedgeToken has correct ILHedge address
starkli call $HEDGE_TOKEN_ADDRESS get_pail_contract_address

# Verify ILHedge has correct HedgeToken address
starkli call $IL_HEDGE_ADDRESS get_pail_token_address
```

### Important Notes

- Both contracts must be correctly linked for the protocol to function properly
- Only the owner can set the contract addresses
- If you redeploy either contract, you must update the reference in the other contract


## Contract Methods

### Basic Information

#### `name()`
- **Description**: Retrieves the contract name
- **Returns**: `felt252` - The name of the contract

#### `get_owner()`
- **Description**: Returns the contract owner's address
- **Returns**: `ContractAddress` - The address of the contract owner

#### `get_pail_token_address()`
- **Description**: Returns the address of the Pail token used for hedge management
- **Returns**: `ContractAddress` - The address of the Pail token contract

### Creating Hedge Positions

#### `hedge_open(notional, quote_token_addr, base_token_addr, expiry, limit_price, hedge_at_price)`
- **Description**: Opens a new hedge against impermanent loss for an AMM liquidity position
- **Parameters**:
  - `notional: u128` - Amount of base asset to hedge
  - `quote_token_addr: ContractAddress` - Address of the quote token (e.g., USDC)
  - `base_token_addr: ContractAddress` - Address of the base token (e.g., ETH)
  - `expiry: u64` - UNIX timestamp for position expiration
  - `limit_price: (Fixed, Fixed)` - Tuple of (quote_limit, base_limit) for maximum costs
  - `hedge_at_price: Fixed` - Price of base token in quote token when liquidity position for protection was opened. If provided zero, current price from Pragma Oracle is applied.
- **Events**: Emits `HedgeOpenedEvent` upon successful creation

#### `clmm_hedge_open(notional, quote_token_addr, base_token_addr, expiry, limit_price, lower_bound, upper_bound, hedge_at_price)`
- **Description**: Opens a new hedge against impermanent loss for a Concentrated Liquidity Market Maker (CLMM) position
- **Parameters**:
  - `notional: u128` - Amount of base asset to hedge
  - `quote_token_addr: ContractAddress` - Address of the quote token (e.g., USDC)
  - `base_token_addr: ContractAddress` - Address of the base token (e.g., ETH)
  - `expiry: u64` - UNIX timestamp for position expiration
  - `limit_price: (Fixed, Fixed)` - Tuple of (quote_limit, base_limit) for maximum costs
  - `lower_bound: Fixed` - Lower bound of price range of liquidity position
  - `upper_bound: Fixed` - Upper bound of price range of liquidity position
  - `hedge_at_price: Fixed` - Price of base token in quote token when liquidity position for protection was opened. If provided zero, current price from Pragma Oracle is applied.
- **Events**: Emits `HedgeOpenedEvent` upon successful creation

### Managing Hedge Positions

#### `hedge_close(token_id)`
- **Description**: Closes an existing hedge position before expiry
- **Parameters**:
  - `token_id: u256` - The token ID of the hedge position to close
- **Events**: Emits `HedgeFinalizedEvent` upon successful closure

#### `hedge_settle(token_id)`
- **Description**: Settles an expired hedge position
- **Parameters**:
  - `token_id: u256` - The token ID of the hedge position to settle
- **Events**: Emits `HedgeFinalizedEvent` upon successful settlement

### Price Calculation Functions

#### `price_hedge(notional, quote_token_addr, base_token_addr, expiry, hedge_at_price)`
- **Description**: Calculates the cost for a new hedge against impermanent loss for an AMM liquidity position
- **Parameters**:
  - `notional: u128` - Amount of base asset to hedge
  - `quote_token_addr: ContractAddress` - Address of the quote token (e.g., USDC)
  - `base_token_addr: ContractAddress` - Address of the base token (e.g., ETH)
  - `expiry: u64` - UNIX timestamp for position expiration
  - `hedge_at_price: Fixed` - Price of base token in quote token when liquidity position for protection was opened. If provided zero, current price from Pragma Oracle is applied.
- **Returns**: `(Fixed, Fixed, Fixed)` - A tuple containing:
  - `cost_quote` - Total cost in quote tokens (including fees)
  - `cost_base` - Total cost in base tokens (including fees)
  - `price` - Market price of base/quote pair used for hedge calculation

#### `price_concentrated_hedge(notional, quote_token_addr, base_token_addr, expiry, lower_bound, upper_bound, hedge_at_price)`
- **Description**: Calculates the cost for a new hedge against impermanent loss for a CLMM liquidity position
- **Parameters**:
  - `notional: u128` - Amount of base asset to hedge
  - `quote_token_addr: ContractAddress` - Address of the quote token (e.g., USDC)
  - `base_token_addr: ContractAddress` - Address of the base token (e.g., ETH)
  - `expiry: u64` - UNIX timestamp for position expiration
  - `lower_bound: Fixed` - Lower bound of price range of liquidity position
  - `upper_bound: Fixed` - Upper bound of price range of liquidity position
  - `hedge_at_price: Fixed` - Price of base token in quote token when liquidity position for protection was opened. If provided zero, current price from Pragma Oracle is applied.
- **Returns**: `(Fixed, Fixed, Fixed, Fixed, Fixed)` - A tuple containing:
  - `cost_quote` - Total cost in quote tokens (including fees)
  - `cost_base` - Total cost in base tokens (including fees)
  - `price` - Market price of base/quote pair used for hedge calculation
  - `adjusted_lower_bound` - Potentially adjusted lower bound value
  - `adjusted_upper_bound` - Potentially adjusted upper bound value

### Contract Administration

#### `upgrade(impl_hash)`
- **Description**: Upgrades the contract to a new implementation
- **Parameters**:
  - `impl_hash: ClassHash` - The class hash of the new implementation
- **Access Control**: Only callable by the contract owner

#### `set_pail_token_address(pail_token_address)`
- **Description**: Sets the address of the Pail token used for hedge management
- **Parameters**:
  - `pail_token_address: ContractAddress` - The new Pail token contract address
- **Access Control**: Only callable by the contract owner

## Notes

- The contract uses Carmine Options AMM for option purchases
- A protocol fee is added to hedge costs (defined by `PROTOCOL_FEE` constant)
- Hedges are represented by NFTs managed by the Pail token contract
- Currently, hedging is not implemented for BTC or Ekubo tokens
- The contract implements SRC5 and SRC6 interfaces