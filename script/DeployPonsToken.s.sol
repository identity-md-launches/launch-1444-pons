// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PonsToken} from "../src/PonsToken.sol";

/// @title Deploy script for Pons (PONS)
/// @notice The token takes no constructor arguments: the supply is a constant and it is minted to
/// whichever address deploys it. On the IdentityMD launch the ProjectFactory deploys the token from
/// its creation code and this script is not used; it exists so the deployment can be reviewed and
/// exercised locally. `run()` reads nothing from the environment: there is nothing to configure.
contract DeployPonsToken is Script {
    /// @notice Deploys the token. The caller of this function (under broadcast, the broadcasting
    /// account) becomes the holder of the whole supply.
    function deploy() public returns (PonsToken token) {
        token = new PonsToken();
    }

    function run() external returns (PonsToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
