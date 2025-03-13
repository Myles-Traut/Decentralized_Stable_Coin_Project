// // SPDX-License-Identifier: MIT

// // Have our invariants aka properties

// // What are our invariants?

// // 1. The total supply of the DSC should be less than the total collateral
// // 2. Getter functions should never revert

// pragma solidity 0.8.23;

// import {Test} from "forge-std/Test.sol";
// import {console} from "forge-std/console.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantTests is StdInvariant, Test {
//     DeployDSC public deployer;
//     DecentralizedStableCoin public dsc;
//     DSCEngine public dsce;
//     HelperConfig public helperConfig;

//     address public weth;
//     address public wbtc;
//     address public ethUsdPriceFeed;
//     address public btcUsdPriceFeed;
 
//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dsce, helperConfig) = deployer.run();
//         (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();
        
//         // For open invariant testing, we need to:
//         // 1. Target the contract we want to test
//         targetContract(address(dsce));
//     }
    
//     function invariant_ProtocolMustHaveMoreValueThanTotalSupply() public view {
//         console.log("Running ProtocolMustHaveMoreValueThanTotalSupply invariant test");
//         // get the value of all the collateral in the protocol
//         // compare it to all the debt (dsc)

//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

//         console.log("Total WETH deposited:", totalWethDeposited);
//         console.log("Total WBTC deposited:", totalWbtcDeposited);
//         console.log("Total DSC supply:", totalSupply);
        
//         uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);
        
//         assert(wethValue + wbtcValue >= totalSupply);
//     }
// }