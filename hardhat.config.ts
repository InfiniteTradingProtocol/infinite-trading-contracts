import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "dotenv/config";

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 10,
          },
        },
      }],
  },
  defaultNetwork: "hardhat",
  // networks: {
  //   optimism: {
  //     allowUnlimitedContractSize: true,
  //     gas: Number(process.env.GAS),
  //     url: process.env.OPTIMISM_RPC_URL,
  //     accounts: [process.env.DEPLOYER_PRIVATE_KEY as string],
  //   },
  // },
  // etherscan: {
  //   apiKey: process.env.ETHERSCAN_API_KEY,
  // },
};

export default config;


