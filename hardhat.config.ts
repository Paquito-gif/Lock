import { defineConfig, configVariable } from "hardhat/config";
import hardhatToolboxViem from "@nomicfoundation/hardhat-toolbox-viem";

export default defineConfig({
  plugins: [hardhatToolboxViem],
  solidity: {
    profiles: {
      default: {
        version: "0.8.28",
        settings: {
          // Elysium supports PUSH0 (Shanghai). Stay on Shanghai to avoid opcodes the chain may not have.
          evmVersion: "shanghai",
          optimizer: { enabled: true, runs: 200 },
        },
      },
    },
  },
  test: {
    solidity: {
      fuzz: { runs: 1000 },
    },
  },
  networks: {
    elysium: {
      type: "http",
      chainType: "l1",
      chainId: 99901,
      url: "https://rpc.elyscan.live",
      // Stored encrypted on your machine with: npx hardhat keystore set ELYSIUM_PRIVATE_KEY
      accounts: [configVariable("ELYSIUM_PRIVATE_KEY")],
    },
  },
});
