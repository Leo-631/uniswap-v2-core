# Uniswap V2

[![Actions Status](https://github.com/Uniswap/uniswap-v2-core/workflows/CI/badge.svg)](https://github.com/Uniswap/uniswap-v2-core/actions)
[![Version](https://img.shields.io/npm/v/@uniswap/v2-core)](https://www.npmjs.com/package/@uniswap/v2-core)

In-depth documentation on Uniswap V2 is available at [uniswap.org](https://uniswap.org/docs).

The built contract artifacts can be browsed via [unpkg.com](https://unpkg.com/browse/@uniswap/v2-core@latest/).

# Local Development

The following assumes the use of `node@>=10`.

## Install Dependencies

`yarn`

## Compile Contracts

`yarn compile`

## Run Tests

`yarn test`


1.所有合约版本为solidity >=0.5.0，编译器版本为0.5.16。
2.使用0xD108EeD153aD2090f6258aF270d53CB944DA7A3c部署了WETH9合约,合约地址为0x41Eb84726359d868Cc8d7df57954eFbc7134e534。
3.使用0x9Cb1F7DF5eCBaCEe5a404CaC978045e3C6c01314部署了工厂合约，合约地址为0x60329d3092226f69D45684707Ca413B56685e468。
4.使用0x6c9E567A01E36c9EA736B21Be11c28aFE6460c8F部署了路由合约，合约地址为0xA9E4c63bAC2Ca4f782894F1556D4c7b282D0b623
4.使用0x6b91Bf5e032d4c22D1edDE6B96285d958Cd8EB5d部署了XTM币，合约地址为0xA6a3C92a3E6F65666eFA2ec78098D54c3b778c98
