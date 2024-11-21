mod Errors {
    const CALL_OPTIONS_UNAVAILABLE: felt252 = 'No call opt. for hedge';  // Option AMM doesnot have call options for requested hedge
    const PUT_OPTIONS_UNAVAILABLE: felt252 = 'No put opt. for hedge';  // Option AMM doesnot have put options for requested hedge
    const INVALID_TOKEN_ADDRESS: felt252 = 'Invalid token address';
    const WEIRD_DECIMALS: felt252 = 'Token has decimals = 0';
    const NOT_IMPLEMETED: felt252 = 'Not Implemented yet!';
    const QUOTE_COST_OUT_OF_LIMITS: felt252 = 'Quote cost exceeds limit';
    const BASE_COST_OUT_OF_LIMITS: felt252 = 'Base cost exceeds limit';
    const NEGATIVE_PRICE: felt252 = 'Price cant be negative';
    const COST_EXCEEDS_LIMITS: felt252 = 'Cost out of slippage bounds';
    const LOWER_TICK_TOO_HIGH: felt252 = 'Lower tick too high';
    const UPPER_TICK_TOO_LOW: felt252 = 'Upper tick too low';
}
