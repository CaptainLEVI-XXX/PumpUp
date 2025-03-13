### 1: Build a StrategyManager.sol Contract.[Easy-Pesy]
- Maintains a registry of curator-provided strategies
- Handles strategy verification and compatibility checks
- Manager curator reputation and registration.
- probably a count (how much a particular strategy has been used).
### 2: Meme-Coin Factory.sol: [Easy-Pesy] 
- Create a deterministics deployment of memecoin .
- Standardizes token creation ans compatability checks
- track token and its choosen strategy
- take input params like transition percentage ,name ,symbol,uri etc. total supply 

### 3: IStrategy.sol [need-to-think]
- Define common interfaces for all strategy types.
- Ensures consistent interaction pattern across strategies.
- Can use AVS for calculation stuff.
- Can use Stylus contract for deployment.

### 3: BondingCurve.sol [sigmoid curve/ exponential Curve] [need-to-research]
- Implements core bonding curve functionality.
- Make sure it should follow the standard define in IStrategy.sol

### 4:  BaseFeeStrategy.sol[need-to-research]

- Implements fee distribution and collection logic
- Provides framework for specific fee models

### 5 : StrategyExecutorHook.sol[easy-pesy]

- Primary Uniswap v4 hook that orchestrates all strategies
- Manages pool lifecycle and state transitions
- Enforces permissions and execution order

### 6 :PoolStateManager.sol[easy-pesy]

- Maintains state for all pools
- Provides storage for strategy-specific data
- Ensures proper isolation between pools
