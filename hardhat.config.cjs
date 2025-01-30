/** @type import('hardhat/config').HardhatUserConfig */
require('@nomicfoundation/hardhat-toolbox');
// 添加这些新的导入
require("@nomicfoundation/hardhat-ethers");
require("@nomicfoundation/hardhat-chai-matchers");
require('dotenv').config();

module.exports = {
  solidity: {
    compilers: [
      {
        version: '0.8.0', // 用于其他需要 0.8.0 的合约
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      {
        version: '0.8.19', // 如果有需要
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      {
        version: '0.8.20', // 添加此编译器版本
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      // 删除不必要的版本，保留需要的版本即可
    ],

  },
  networks: {
    localhost: {
      url: 'http://127.0.0.1:8545',
    },
    sepolia: {
      url: process.env.INFURA_API_URL,
      accounts: [],
	  chainId: 11155111, // Sepolia 的 chainId
	  gas: 5000000,           // 增加 gas 限制
      gasPrice: 20000000000,  // 20 gwei
    },
    mainnet: {
      url: process.env.INFURA_API_URL,
      accounts: [],
      chainId: 1, // Sepolia 的 chainId
      gas: 4000000,           // 增加 gas 限制
      gasPrice: 20000000000,  // 20 gwei
    },
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY, // 通用的 Etherscan API Key
  },
};