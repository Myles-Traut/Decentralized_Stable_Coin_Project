// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Events
// Type declarations
// State variables
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity 0.8.23;
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
* @title Decentralized Stable Coin Engine
* @author Myles Traut
* The sytem is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg with USD at all times
*
* This stablecoing has the following properties:
* Exogenus Collateral
* Algorithmicly Stable
* Dollar Pegged
*
* Our DSC system should always be 'overcollateralized'. 
* At no point should the value of all collateral be less than or equal to the dollar value of all DSC.
*
* It is similar in design to DAI if DAI had no governance or fees and was only backed by WETH and WBTC
*
* This contracts is the CORE of the DSC system. It handles all logic for the minting and redemption of DSC
* and the depositing and withdrawal of collateral.
*
* This contract is VERY loosly based on the MakerDAO DSS (DAI) system.
**/

contract DSCEngine is ReentrancyGuard {
    /*----------- ERRORS -----------*/
    error DSCEngine__ZeroAddress();
    error DSCEngine__AmountMustBeMoreThanZero();
    error DSCEngine__CollateralAddressesAndPriceFeedAddressesLengthsMustBeTheSame();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOkay();
    error DSCEngine__HealthFactorNotImproved();

    /*----------- EVENTS -----------*/
    event CollateralDeposited(address indexed user, address indexed collateralToken, uint256 indexed amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed collateralTokenAddress, uint256 amountCollateral);

    /*----------- STATE VARIABLES -----------*/
    mapping(address token => address priceFeed) private s_tokenToPriceFeeds;
    mapping(address user => mapping(address collateralToken => uint256 depositedAmount)) private s_userCollateralDeposited;
    mapping(address user => uint256 amountDSCMinted) private s_userDscMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% Bonus
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    /*----------- MODIFIERS -----------*/

    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__AmountMustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        if (s_tokenToPriceFeeds[_token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /*----------- FUNCTIONS -----------*/

    constructor(address[] memory _collateralAddresses, address[] memory _pricefeedAddresses, address _dscAddress) {
        if (_collateralAddresses.length != _pricefeedAddresses.length) {
            revert DSCEngine__CollateralAddressesAndPriceFeedAddressesLengthsMustBeTheSame();
        }
        for (uint256 i = 0; i < _collateralAddresses.length; i++) {
            s_tokenToPriceFeeds[_collateralAddresses[i]] = _pricefeedAddresses[i];
            s_collateralTokens.push(_collateralAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(_dscAddress);
    }

    /*----------- PUBLIC AND EXTERNAL FUNCTIONS -----------*/

    function depositCollateralAndMintDsc(
        address _collateralTokenAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint
        ) external {
        depositCollateral(_collateralTokenAddress, _amountCollateral);
        mintDsc(_amountDscToMint);
    }
    
    /**
    * @param _collateralTokenAddress: The address of the collateral token to deposit
    * @param _amountCollateral: The amount of collateral to deposit
    **/
    function depositCollateral(
        address _collateralTokenAddress, 
        uint256 _amountCollateral
    ) public 
    moreThanZero(_amountCollateral) 
    isAllowedToken(_collateralTokenAddress)
    nonReentrant
    {
        s_userCollateralDeposited[msg.sender][_collateralTokenAddress] += _amountCollateral;
        emit CollateralDeposited(msg.sender, _collateralTokenAddress, _amountCollateral);

        bool success = IERC20(_collateralTokenAddress).transferFrom(msg.sender, address(this), _amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
    * @param _collateralTokenAddress: The address of the collateral token to redeem
    * @param _amountCollateral: The amount of collateral to redeem
    * @param _amountDscToBurn: The amount of DSC to burn
    * This function will redeem your collateral and burn your DSC in one transaction
    **/
    function redeemCollteralForDsc(
        address _collateralTokenAddress, 
        uint256 _amountCollateral,
        uint256 _amountDscToBurn
    ) public {
        burnDsc(_amountDscToBurn);
        redeemCollateral(_collateralTokenAddress, _amountCollateral);
        // redeemCollateral already checks healthfactor
    }

    /**
    * @param _collateralTokenAddress: The address of the collateral token to redeem
    * @param _amountCollateral: The amount of collateral to redeem
    * @notice User can only withdraw if their health factor is more than 1
    **/
    function redeemCollateral(
        address _collateralTokenAddress, 
        uint256 _amountCollateral
    ) public 
    moreThanZero(_amountCollateral) 
    nonReentrant 
    {
        _redeemCollateral(_collateralTokenAddress, _amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
    * @param _amountDscToMint: The amount of DSC to mint
    * @notice users must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 _amountDscToMint) public moreThanZero(_amountDscToMint) nonReentrant {
        s_userDscMinted[msg.sender] += _amountDscToMint;
        
        // check if they have enough collateral eg($ collateral > $ DSC)
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if(!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 _amount) public moreThanZero(_amount) {
        _burnDsc(_amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param _collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param _user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param _debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
    * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this
    to work.
    * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate
    anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address _collateral, address _user, uint256 _debtToCover) 
    public 
    moreThanZero(_debtToCover) 
    isAllowedToken(_collateral)
    nonReentrant
    {
        if (_user == address(0)) {
            revert DSCEngine__ZeroAddress();
        }

        uint256 startingUserHealthFactor = _healthFactor(_user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOkay();
        }
        // We want to burn their DSC "debt"
        // And take their collateral
        // Bad User: $140 ETH, $100 DSC
        // Debt to cover = $100
        // Therefore $100 DSC = ?? ETH
        // $100 DSC = ?? ETH

        uint256 tokenAmountForDebtCovered = getCollateralAmountFromUsd(_collateral, _debtToCover);

        // Give liquidator 10% bonus
        // We give the liquidator $110 weth for $100 DSC
        // We should implement a feature to liquidate should the protocol become insolvent
        // And sweep extra amounts in a treasury

        // Caluculate Bonus
        uint256 bonusCollateral = (tokenAmountForDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; 
        uint256 totalCollateralToRedeem = tokenAmountForDebtCovered + bonusCollateral;

        // Redeem Collateral for the user being liquidated
        // Burn the msg.sender's DSC
        _redeemCollateral(_collateral, totalCollateralToRedeem, msg.sender, _user);
        _burnDsc(_debtToCover, _user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(_user);

        if(endingHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        // revert if callers health factor breaks
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address _user) public view returns(uint256) {
        return _healthFactor(_user);
    }

    /*----------- INTERNAL AND PRIVATE FUNCTIONS -----------*/

    /**
    * @dev Low level internal burn function. Do not call unless function calling it is checking health factor.
     */
    function _burnDsc(uint256 _amountDscToBurn, address _onBehalfOf, address _dscFrom) private {
        s_userDscMinted[_onBehalfOf] -= _amountDscToBurn;
        bool success = i_dsc.transferFrom(_dscFrom, address(this), _amountDscToBurn);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(_amountDscToBurn);
    }
    function _redeemCollateral(
        address _collateralTokenAddress,
        uint256 _amountCollateral,
        address _to,
        address _from
    ) private {
        s_userCollateralDeposited[_from][_collateralTokenAddress] -= _amountCollateral;
        emit CollateralRedeemed(_from, _to, _collateralTokenAddress, _amountCollateral);

        bool success = IERC20(_collateralTokenAddress).transfer(_to, _amountCollateral);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address _user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
        totalDscMinted = s_userDscMinted[_user];
        collateralValueInUsd = getAccountCollateralValue(_user);
    }

    /**
    * Returns how close to liquidation the user is
    * If a user goes below 1 they can get liquidated
    **/
    function _healthFactor(address _user) internal view returns(uint256) {
        // total dsc minted
        // total collateral value $$
        (uint256 totalDscMinted, uint256 totalCollateralValueInUSD) = _getAccountInformation(_user);
        uint256 collateralAdjustedForThreshold = (totalCollateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        // $1000 ETH * 50 = 50 000 /100 = (500 / 100) = 5 -> good
        // totalCollateralValueInUSD: 500 / totalDscMinted: 100

        // $150 ETH * 50 = 7500 / 100 = (75 / 100) = 0.75 -> bad
        // totalCollateralValueInUSD: 75 / totalDscMinted: 100
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    // check health factor of user
        // revert if bad
    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);
        if(userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
        
    }

    /*----------- PUBLIC AND EXTERNAL VIEW FUNCTIONS -----------*/

    function getCollateralAmountFromUsd(address _collateralToken, uint256 _usdAmountInWei) public view returns(uint256) {
        // price of ETH (token)
        // $ / ETH ETH?
        // $2000 per ETH. How much ETH is $1000 worth?
        // $1000 / $2000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeeds[_collateralToken]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        // Multiply before dividing.
        // price has 8 decimals, so we need to scale up by 1e10
        // ($10 e18 * 1e18) / ($2000 e8 * 1e10) = 0.005 ETH
        return (_usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address _user) public view returns(uint256 totalCollateralValueInUSD) {
        for(uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_userCollateralDeposited[_user][token];
            totalCollateralValueInUSD += getUsdValue(token, amount);
        }
        return totalCollateralValueInUSD;
    }

    function getUsdValue(address _token, uint256 _amount) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeeds[_token]);
        // PRICE has 1e8 decimals. Needs to be scaled up to match _amount's 1e18 decimals
        (, int256 price,,,) = priceFeed.latestRoundData();

        // Scale up and then back down
        return((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) / PRECISION;

    }
}
