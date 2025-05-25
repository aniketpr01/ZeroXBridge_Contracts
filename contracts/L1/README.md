# L1 Contracts

## Deployed (SEPOLIA)

- Proof Registry: [0xafac655B56B0403B6ADA6d0EF1A60257AF093d16](https://sepolia.etherscan.io/address/0xafac655B56B0403B6ADA6d0EF1A60257AF093d16#code)

- L1 Bridge: [0x8F25bFe32269632dfd8D223D51FF145414d8107b](https://sepolia.etherscan.io/address/0x8F25bFe32269632dfd8D223D51FF145414d8107b#code)

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
