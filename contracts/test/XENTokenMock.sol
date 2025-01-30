// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract XENTokenMock is ERC20 {
    constructor() ERC20("XEN Token Mock", "XEN") {
        _mint(msg.sender, 1_000_000_000_000 * 1e18); // 给部署者创建一定数量的代币
    }

    function mint() public {
        _mint(msg.sender, 1_000_000_000_000 * 1e18);
    }
}