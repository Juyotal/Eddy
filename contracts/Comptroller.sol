// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IUSDJ.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "hardhat/console.sol";

contract Comptroller {
    struct Account {
        uint256 collateral;
        uint256 debt;
        uint256 timeSince;
    }

    mapping(address => Account) private accounts;

    mapping(address => uint256) private liquidationFees;

    address public DaiAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public usdjAddress;
    AggregatorV3Interface public priceFeed;
    address public ETHTOUSDPRICEFEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address public UNISWAP_V2_ROUTER = 0xf164fC0Ec4E93095b804a4795bBe1e041497b92a; 

    uint256 public interestRate; // accouunt for scale

    uint256 public borrowLimit = 180; //total collateral must be 80% more than debts atleast
    uint256 public liquidLimit = 120; // liquidated if collateral is from 20% more than debts

    uint256 public constant SCALE = 10000;
    uint128 public SECONDS_IN_YEAR = 31556952; // int128 for compound interest math



    event Deposit(address indexed account, uint256 amount);
    event Removed(address indexed account, uint256 amount);
    event Borrow(
        address indexed account,
        uint256 amountBorrowed,
        uint256 totalDebt,
        uint256 collateralAmount
    );
    event Repay(
        address indexed account,
        uint256 Repaid,
        uint256 Remaining,
        uint256 collateral
    );
    event Liquidation(
        address indexed account,
        uint256 collateral,
        uint256 CollateralRatio,
        uint256 DebtOutstanding
    );

  

    constructor(
        address _usdjAddress,
        uint256 _interestRate
    ) {
        usdjAddress = _usdjAddress;
        interestRate = _interestRate;
  
    }


    // HELPER FUNCTIONS

    function _collateralRatio(address account, uint256 debt) internal returns (uint256) {
        uint256 collateral= accounts[account].collateral;

        if (collateral == 0) {
            return 0;
        } else if (debt == 0) {
            return type(uint256).max;
        }
        uint256 ethValue = ethToUsd();
        uint256 collateralValue = (collateral * ethValue) / SCALE;

        return (collateralValue * uint8(100)) / (debt);
    }

    function calcInterest(address account) public view returns (uint256 interest)
    {
        if (
            accounts[account].debt == 0 ||
            accounts[account].timeSince == 0 ||
            interestRate == 0 ||
            block.timestamp == accounts[account].timeSince
        ) {
            return 0;
        }


        uint256 secondsSinceLastInterest_ = block.timestamp - accounts[account].timeSince;
        
        uint256 yearsEquiv = secondsSinceLastInterest_ / SECONDS_IN_YEAR;

        uint256 interestRate_ = interestRate / SCALE;

        uint256 debt = accounts[account].debt;


        uint256 interest = (debt* (1 + interestRate_)**yearsEquiv) - debt;


        return interest;
    }

    function ethToUsd () public returns (uint256){
        priceFeed = AggregatorV3Interface(ETHTOUSDPRICEFEED);
        (, int256 price, , ,) = priceFeed.latestRoundData();

        return uint256(price) / 1e8;
    }



    // MAIN FUNCTIONS


    // account deposits Eth as collateral but for all ratios, values are considered in USD
    function deposit() public payable {
        uint256 amount = (msg.value / 1e18)*SCALE;
        accounts[msg.sender].collateral += amount;

        emit Deposit(msg.sender, amount);
    }

    function remove(uint256 amount) public {
        address payable _to = payable(msg.sender);

        Account storage acc = accounts[_to];

        require(acc.collateral >= amount, "amount exceeds collateral");

        uint256 interest_ = calcInterest(_to);

        acc.debt += interest_;
        acc.timeSince = block.timestamp;

        uint256 colRatio = _collateralRatio(_to, acc.debt);

        require(colRatio > borrowLimit, "account below safety ratio");

        uint256 canWithdraw;

        if (acc.debt == 0) {
            canWithdraw = acc.collateral;
        } else {
            canWithdraw= (acc.collateral / colRatio) * (colRatio - borrowLimit);
        }

        require(canWithdraw >= amount, "Nope!! amount exceeds withdrawable");

        acc.collateral -= amount;
        _to.transfer((amount * 1e8) / SCALE);

        emit Removed(msg.sender, amount);
    }
    //amount to borrow is set in terms of USDJ which is approx equal value to USD
    function borrow(uint256 amount) public {
        require(amount > 0, "Borrow: no amount set");
        Account storage acc = accounts[msg.sender];

        uint256 interest = calcInterest(msg.sender);

        require(
            _collateralRatio(msg.sender, acc.debt + interest + amount) >= borrowLimit,
            "not enough collateral"
        );

        // add interest and new debt to position
        acc.debt += (amount + interest);
        acc.timeSince = block.timestamp;

        IUSDJ(usdjAddress).mint(msg.sender, amount);

        emit Borrow(msg.sender, amount, acc.debt, acc.collateral);
    }

    // any amount repaid is in USDJ aswell!
    function repay(uint256 amount) public {
        require(amount > 0, "Repay: no amount set");

        Account storage acc = accounts[msg.sender];
        uint256 interest = calcInterest(msg.sender);

        uint256 debt = acc.debt + interest;

        if (amount >= debt) {
            require(
                IUSDJ(usdjAddress).transferFrom(msg.sender, address(this), debt),
                "repay failed"
            );
            acc.debt = 0;

        } else {
       
            require(IUSDJ(usdjAddress).transferFrom(msg.sender, address(this), amount),
                "repay failed"
            );
            acc.debt = debt - amount;
        }
        acc.timeSince = block.timestamp;
        emit Repay(msg.sender, amount, acc.debt, acc.collateral);
    }

    function liquidate(address account) public {
        Account storage acc = accounts[account];

        require(acc.collateral > 0, "no collateral");
        
        uint256 debt = acc.debt;
        uint256 interest = calcInterest(account);
        uint256 collateral = acc.collateral; 
        uint256 collateralRatio = _collateralRatio(account, (acc.debt + interest));

        require(collateralRatio < liquidLimit, "account not liquidable");

        require(IUSDJ(usdjAddress).transferFrom(msg.sender, address(this), debt),
            "repay failed"
        );

        address[] memory wethToDaiPath = new address[](2);
        wethToDaiPath[0] = DaiAddress;
        wethToDaiPath[1] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;


        // sell remaining Eth collateral for DAI Once Collateral isnt enough
        IUniswapV2Router(UNISWAP_V2_ROUTER).swapExactTokensForTokens(
            collateral,
            0,
            wethToDaiPath,
            address(this),
            block.timestamp
        );

        acc.collateral = 0;
        acc.debt = 0;

        emit Liquidation(
            account,
            collateralRatio,
            collateral,
            debt
        );

    }
}