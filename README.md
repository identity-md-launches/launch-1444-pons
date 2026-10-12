# Pons (PONS)

A fixed-supply ERC-20 token for a custom token launch on Robinhood Chain (chain id 4663).

| Property        | Value                                                        |
|-----------------|--------------------------------------------------------------|
| Contract name   | `PonsToken` (`src/PonsToken.sol`)                            |
| Token name      | `Pons`                                                       |
| Token symbol    | `PONS`                                                       |
| Decimals        | 18                                                           |
| Total supply    | 1,000,000,000 PONS = `1000000000000000000000000000` minor units (1e27) |
| Constructor     | no arguments                                                 |
| Minted to       | `msg.sender` of the constructor (the deployer), once         |
| Compiler        | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` |

## Behaviour

The contract is a plain, immutable ERC-20:

- The constructor mints the whole supply to the deployer and emits one `Transfer(0x0, deployer, supply)`.
- `totalSupply()` is a constant. There is no `mint`, no `burn`, no owner, no minter role, no proxy
  and no upgrade path, so the supply can never grow or shrink after deployment.
- `transfer`, `approve` and `transferFrom` behave exactly as ERC-20 specifies. Every transfer moves
  exactly the amount requested: there is no fee, no tax, no reflection and no burn on transfer.
- There is no pause, blocklist, freeze, lock or seize. Nobody but a holder (or a spender the holder
  approved) can move a holder's balance, and nothing can stop a holder from transferring.
- Transfers to the zero address and approvals of the zero spender revert.
  Reverts use ERC-6093 custom errors (`ERC20InsufficientBalance`, `ERC20InsufficientAllowance`,
  `ERC20InvalidReceiver`, `ERC20InvalidSpender`, ...).
- An allowance of `type(uint256).max` is treated as unlimited and is not decremented.
- The contract has no `receive` or `fallback`, so it cannot hold ETH.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and the contract calls no
  other contract, ever. It depends on no external library.

## Assumptions

- The launch's ProjectFactory deploys the token from its creation code. The factory is therefore the
  deployer and receives the entire supply, which it pays out itself (10% to the launch's
  MerkleDistributor, 88% to the single-sided ETH pool, 2% to the requester's `remainderTo`
  address). The token does not know about, reserve for or send anything to any of those parties:
  it mints once to `msg.sender` and stops.
- Because the token has no fee or restriction on any transfer, it needs no exemption list and takes
  none of the launch addresses (`$factory`, `$poolManager`, `$launchNumber`) as arguments.
- The requester asked for a plain token. No governance, vesting, tax or burn was requested, so none
  is implemented. Adding any of those later would require a new token contract: this one is immutable.
- The token's `name()` is "Pons" and its `symbol()` is "PONS". The Solidity identifier recorded by
  the launch is `PonsToken` (9 characters, within the 32 allowed).

## Deployment parameters

The constructor takes no arguments. For the launch manifest (written by the manifest step, not
here):

- `token.contract`: `PonsToken`
- `token.name`: `Pons`
- `token.symbol`: `PONS`
- `token.decimals`: `18`
- `token.constructorArgs`: `[]`
- `token.totalSupply`: `1000000000000000000000000000`
- application contracts: none

Launch-decided values (chain 4663, native ETH pair, fee 12500, tick spacing 60, the requester's
economics) are the launch's and are not read, stored or needed by the token.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, sets `bytecode_hash = "none"` and `cbor_metadata = false`
so the deployed bytes are reproducible, and leaves `ffi` off with no filesystem permissions.
The only dependency is forge-std, vendored as ordinary files under `lib/forge-std` (MIT/Apache-2.0,
licences included). It is used by tests and the script only; the token imports nothing.

The test suite (`test/PonsToken.t.sol`) covers metadata and supply, the mint to a contract
deployer, exact transfers, allowance accounting including the unlimited-allowance case, every
revert path (insufficient balance, insufficient allowance, zero-address receiver and spender), the
absence of any mint, admin, pause, freeze or seize entry point from both a stranger and the
deployer, the launch-shaped split (10% / 88% / 2%) arriving whole, the bytecode scan for forbidden
opcodes, and fuzzed conservation of supply. Tests read no environment variables and do not depend
on the calling address.

## Deploy script

`script/DeployPonsToken.s.sol` exposes `deploy()`, which deploys the token and is called directly by
the tests. `run()` wraps it in a broadcast and reads nothing from the environment. On the IdentityMD
launch the factory deploys the token from its bytecode and this script is not used; it exists so a
reviewer can see and reproduce the deployment. This repository does not authorise any transaction
and holds no keys.

## Operational responsibilities

- **After launch:** nothing to configure. The token has no owner and no settable values.
- **The holder of the supply** is the deployer. At launch that is the factory, which distributes it
  per the launch policy. If the token is deployed anywhere else, whoever runs the deployment holds
  all 1,000,000,000 PONS and is responsible for distributing them.
- **No recovery path.** Tokens sent to a wrong address, or ETH sent to the contract (which
  reverts), cannot be recovered by anyone. Holders are responsible for their own keys and
  approvals; granting an unlimited allowance to a contract exposes the whole balance if that
  contract is compromised.
- **Explorer verification** of the deployed contract (`forge verify-contract` with solc 0.8.26,
  optimizer 200 runs, `bytecode_hash = none`, EVM version cancun) is the deployer's job after
  the launch.
- **Security review.** Tests passing is not an audit. The contract is small and self-contained,
  but an independent adversarial review before anything that holds other people's funds builds on
  it is still the right practice. Static analysers (Slither, Mythril) were not available in this
  environment and were not run.

## Layout

```
foundry.toml                 compiler and profile pins
remappings.txt               forge-std/ -> lib/forge-std/src/
src/PonsToken.sol            the token
script/DeployPonsToken.s.sol deploy script (deploy() is unit-tested)
test/PonsToken.t.sol         tests
lib/forge-std/               vendored forge-std (tests and script only)
```
