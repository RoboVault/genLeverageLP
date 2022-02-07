// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

contract MockPriceOracle {
    bool public constant isPriceOracle = true;
    mapping(address => uint256) public prices;

    function getUnderlyingPrice(address cToken) external view returns (uint256) {
        return prices[cToken];
    }

    function setUnderlyingPrice(address cToken, uint256 price) external {
        prices[cToken] = price;
    }
}
