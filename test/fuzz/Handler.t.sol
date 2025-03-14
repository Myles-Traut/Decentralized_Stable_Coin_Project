// Handler is going t narrow down the way we call functions
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DecentralizedStableCoin public dsc;
    DSCEngine public dsce;

    ERC20Mock public weth;
    ERC20Mock public wbtc;

    uint256 public constant MAX_DEPOSIT_SIZE = type(uint96).max;

    address[] usersWithDepositedCollateral;

    MockV3Aggregator public ethUsdPriceFeed;

    constructor(DecentralizedStableCoin _dsc, DSCEngine _dsce) {
        dsc = _dsc;
        dsce = _dsce;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    function depositCollateral(uint256 _collateralSeed, uint256 _amount) public {
        ERC20Mock collateral = _getCollateralFromSeed(_collateralSeed);
        _amount = bound(_amount, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, _amount);
        collateral.approve(address(dsce), _amount);
        dsce.depositCollateral(address(collateral), _amount);
        vm.stopPrank();
        usersWithDepositedCollateral.push(msg.sender);
    }

    function redeemCollateral(uint256 _collateralSeed, uint256 _amount) public {
        ERC20Mock collateral = _getCollateralFromSeed(_collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(address(collateral), msg.sender);
        _amount = bound(_amount, 0, maxCollateralToRedeem);
        if (_amount == 0) {
            return;
        }
        vm.startPrank(msg.sender);
        dsce.redeemCollateral(address(collateral), _amount);
        vm.stopPrank();
    }

    function mintDsc(uint256 _amount, uint256 _addressSeed) public {
        if (usersWithDepositedCollateral.length == 0) {
            return;
        }
        address sender = usersWithDepositedCollateral[_addressSeed % usersWithDepositedCollateral.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);

        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        if (maxDscToMint < 0) {
            return;
        }
        _amount = bound(_amount, 0, uint256(maxDscToMint));
        if (_amount == 0) {
            return;
        }
        vm.startPrank(sender);
        dsce.mintDsc(_amount);
        vm.stopPrank();
    }

    /// @dev This breaks out test suite.
    /// @notice If collateral price plummets, the protocol will become worthless.
    // function updateCollateralPrice(uint96 _newPrice) public {
    //     int256 newPrice = int256(uint256(_newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPrice);
    // }

    function _getCollateralFromSeed(uint256 _collateralSeed) private view returns (ERC20Mock) {
        if (_collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
