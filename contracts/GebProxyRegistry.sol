pragma solidity >=0.6.7;

import './Proxy.sol';

// This Registry deploys new proxy instances through DSProxyFactory.build(address) and keeps a registry of owner => proxy
contract GebProxyRegistry {
    mapping(address => DSProxy) public proxies;
    DSProxyFactory factory;

    // --- Events ---
    event Build(address usr, address proxy);

    constructor(address factory_) public {
        factory = DSProxyFactory(factory_);
    }

    // deploys a new proxy instance
    // sets owner of proxy to caller
    function build() public returns (address payable proxy) {
        proxy = build(msg.sender);
        emit Build(msg.sender, proxy);
    }

    // deploys a new proxy instance
    // sets custom owner of proxy
    function build(address owner) public returns (address payable proxy) {
        require(proxies[owner] == DSProxy(0) || proxies[owner].owner() != owner); // Not allow new proxy if the user already has one and remains being the owner
        proxy = factory.build(owner);
        proxies[owner] = DSProxy(proxy);
        emit Build(owner, proxy);
    }
}