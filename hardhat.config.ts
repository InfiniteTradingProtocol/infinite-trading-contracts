import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const ETHERSCAN_API_KEY = "";
const OPTIMISM_RPC_URL = "";
const DEPLOYER_PRIVATE_KEY = "";

const config: HardhatUserConfig = {
  solidity: "0.8.24",
  // etherscan: {
  //   apiKey: ETHERSCAN_API_KEY,
  // },
  // networks: {
  //   optimism: {
  //     url: OPTIMISM_RPC_URL,
  //     accounts: [DEPLOYER_PRIVATE_KEY],
  //   },
  // },
};

export default config;


